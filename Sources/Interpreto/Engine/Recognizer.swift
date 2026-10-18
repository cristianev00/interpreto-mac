import AVFoundation
import CoreMedia
import Speech

/// Audio as it flows between the microphone, pause detection and the speech engines.
typealias AudioStream = AsyncStream<AVAudioPCMBuffer>

/// Apple's on-device speech recognition (SpeechAnalyzer), tuned for live translation.
///
/// Apple confirms ("finalizes") a sentence only when it has heard more context, which in practice
/// is often when the *next* sentence ends: 5–15 s late. Interpreto doesn't wait: when the speaker
/// pauses, it commits the live (unconfirmed) text heard so far as a sentence, so it can be
/// translated at once. When Apple's confirmed text arrives later, the sentence is quietly revised
/// if any word changed.
///
/// Apple's live text comes as one block with no per-word timing (only confirmed text has word
/// times), so committed words are tracked by text: `taken` counts the letters and digits of the
/// live text already committed, and only what follows is shown as the sentence in progress.
@MainActor
final class Recognizer {
    struct Word { let text: String; let start: Double; let end: Double }

    /// A sentence committed at a pause, waiting for Apple's confirmed wording. `from`/`to` are its
    /// position in the live text, counted in letters and digits.
    private struct Pending {
        let id: UUID; let text: String; var from: Int; var to: Int
        var confirmed: [String] = []      // Apple may confirm one sentence in several pieces
    }

    nonisolated static let pauseSeconds = 0.5             // a pause after a finished sentence (. ? ! 。)
    nonisolated static let longPauseSeconds = 1.0         // a pause that ends a sentence regardless
    nonisolated static let debug = ProcessInfo.processInfo.environment["INTERPRETO_DEBUG"] != nil

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var live = ""                                // Apple's current unconfirmed text
    private var taken = 0                                // letters/digits of `live` already committed
    private var volatileEnd = 0.0                        // audio time the live text covers
    private var segmentStart = 0.0                       // audio time the live text starts
    private var lastChange = 0.0                         // audio time the live text last changed
    private var lastCommitEnd = 0.0
    private var pending: [Pending] = []
    private var pauseAt: Double?                         // speech ended here; commit once heard
    private var pauseIsLong = false
    private var pauseDeadline: Task<Void, Never>?

    private var onPartial: (String) -> Void = { _ in }
    private var onCommit: (UUID, String, Double, Double) -> Void = { _, _, _, _ in }
    private var onRevise: (UUID, String) -> Void = { _, _ in }

    func transcriber(for d: Direction) -> SpeechTranscriber {
        SpeechTranscriber(locale: d.speechLocale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }

    /// Starts recognizing `input`; returns once the analyzer is running.
    /// - onCommit(id, text, start, end): a new sentence (audio times in seconds)
    /// - onRevise(id, text): Apple's confirmed wording for an earlier sentence differs
    func start(direction d: Direction, vocabulary: [String],
               input: (AVAudioFormat) throws -> AudioStream,
               onPartial: @escaping (String) -> Void,
               onCommit: @escaping (UUID, String, Double, Double) -> Void,
               onRevise: @escaping (UUID, String) -> Void,
               onError: @escaping (Error) -> Void) async throws {
        self.onPartial = onPartial
        self.onCommit = onCommit
        self.onRevise = onRevise
        live = ""; taken = 0; volatileEnd = 0; segmentStart = 0; lastChange = 0; lastCommitEnd = 0
        pending = []; pauseAt = nil

        let transcriber = transcriber(for: d)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Interpreto", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn’t available for \(d.sourceName)."])
        }
        try await analyzer.prepareToAnalyze(in: format)
        let stream = Self.withPauseDetection(try input(format)) { [weak self] event in
            if case .paused(let end, let long) = event { Task { @MainActor in self?.paused(at: end, long: long) } }
        }

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let text = String(r.text.characters)
                    let line = String(format: "%@ %.2f–%.2fs: %@", r.isFinal ? "FINAL" : "volatile",
                                      r.range.start.seconds, r.range.end.seconds, text)
                    if Self.debug { print("  [\(line)") }
                    Diagnostics.event("recognizer " + line)
                    if r.isFinal { self.confirmed(Self.words(r.text)) }
                    else { self.heard(text, from: r.range.start.seconds, through: r.range.end.seconds) }
                }
            } catch is CancellationError {
            } catch { onError(error) }
        }
        // Apple's analyzer takes its own input type (only in its own audio format).
        let analyzerInput = AsyncStream<AnalyzerInput> { cont in
            let task = Task.detached {
                for await buffer in stream { cont.yield(AnalyzerInput(buffer: buffer)) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
        try await analyzer.start(inputSequence: analyzerInput)
    }

    /// Finishes the current audio (so the last sentence is confirmed) and stops.
    func stop() async {
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        commitLive(endingAt: volatileEnd)
        analyzer = nil
        resultsTask = nil
    }

    func cancel() async {
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        resultsTask = nil
    }

    // MARK: results

    /// The part of the live text not yet committed as a sentence.
    private var unclaimed: String { Self.clean(Self.split(live, after: taken).rest) }

    /// Live (unconfirmed) result: everything heard since Apple's last confirmed text.
    private func heard(_ text: String, from start: Double, through end: Double) {
        if text != live { lastChange = end }
        live = text
        segmentStart = start
        volatileEnd = end
        if let p = pauseAt, end >= p {
            if pauseIsLong || Self.endsSentence(unclaimed) { commitLive(endingAt: p) }
        } else if !unclaimed.isEmpty {
            // Apple has processed well past its last change without hearing a new word: a pause,
            // even if the room is too noisy for the level-based detector.
            let gap = end - lastChange
            if gap >= Self.longPauseSeconds + 0.2 || (gap >= Self.pauseSeconds + 0.2 && Self.endsSentence(unclaimed)) {
                commitLive(endingAt: lastChange)
            }
        }
        if Self.debug { print("    live (taken \(taken)): \(unclaimed)") }
        onPartial(unclaimed)
    }

    /// The speaker paused. Commit the sentence once the recognizer has caught up with the pause
    /// (its live results trail the audio by a fraction of a second), or after 0.8 s at the latest.
    /// A short pause commits a sentence only if it is finished (ends with . ? ! 。 ？ ！), so a
    /// breath mid-sentence doesn't split it; a long pause commits whatever was said.
    private func paused(at speechEnd: Double, long: Bool) {
        let line = String(format: "pause (%@): speech ended %.2fs (recognizer heard through %.2fs)",
                          long ? "long" : "short", speechEnd, volatileEnd)
        if Self.debug { print("  [\(line)]") }
        Diagnostics.event(line)
        if volatileEnd >= speechEnd {
            if long || Self.endsSentence(unclaimed) { commitLive(endingAt: speechEnd) }
            return
        }
        pauseAt = speechEnd
        pauseIsLong = long
        pauseDeadline?.cancel()
        pauseDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled, let p = self.pauseAt else { return }
            if self.pauseIsLong || Self.endsSentence(self.unclaimed) { self.commitLive(endingAt: p) }
        }
    }

    /// Commits the unclaimed live text as a sentence.
    private func commitLive(endingAt end: Double) {
        pauseAt = nil
        pauseDeadline?.cancel()
        let text = unclaimed
        guard !text.isEmpty else { return }
        let n = Self.normalized(text).count
        let id = UUID()
        pending.append(Pending(id: id, text: text, from: taken, to: taken + n))
        taken += n
        let start = max(lastCommitEnd, segmentStart)
        let stop = max(end, start + 0.3)
        lastCommitEnd = stop
        onCommit(id, text, start, stop)
        onPartial(unclaimed)
    }

    /// Apple's confirmed text (the start of the live text): revise committed sentences whose
    /// wording changed, and commit confirmed words that no pause has claimed yet.
    private func confirmed(_ ws: [Word]) {
        var pos = 0
        var rest: [Word] = []
        for w in ws {
            let n = Self.normalized(w.text).count
            if pos < taken, let i = pending.lastIndex(where: { $0.from <= pos }) ?? pending.indices.first {
                pending[i].confirmed.append(w.text)
            } else if n > 0 || !rest.isEmpty {
                rest.append(w)
            }
            pos += n
        }
        let confirmedChars = pos
        // Sentences Apple has now confirmed completely: show the confirmed wording if it differs.
        for p in pending where p.to <= confirmedChars + 1 {
            let text = Self.clean(p.confirmed.joined())
            if !text.isEmpty, Self.normalized(text) != Self.normalized(p.text) { onRevise(p.id, text) }
        }
        pending.removeAll { $0.to <= confirmedChars + 1 }
        if let first = rest.first, let last = rest.last {
            let text = Self.clean(rest.map(\.text).joined())
            if !text.isEmpty {
                lastCommitEnd = last.end
                onCommit(UUID(), text, first.start, last.end)
            }
        }
        // What Apple confirmed is no longer part of the live text.
        live = Self.split(live, after: confirmedChars).rest
        taken = max(0, taken - confirmedChars)
        for i in pending.indices {
            pending[i].from = max(0, pending[i].from - confirmedChars)
            pending[i].to = max(0, pending[i].to - confirmedChars)
        }
        onPartial(unclaimed)
    }

    // MARK: helpers

    static func words(_ s: AttributedString) -> [Word] {
        var out: [Word] = []
        for run in s.runs {
            let text = String(s[run.range].characters)
            if let r = run.audioTimeRange {
                out.append(Word(text: text, start: r.start.seconds, end: r.end.seconds))
            } else if let last = out.popLast() {          // punctuation and spaces: attach to the word before
                out.append(Word(text: last.text + text, start: last.start, end: last.end))
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Word(text: text, start: 0, end: 0))
            }
        }
        return out
    }

    /// Tidies a piece of recognized text for display: no leading punctuation, capitalized.
    static func clean(_ text: String) -> String {
        var s = tidy(text)
        while let f = s.first, ",.，。、;；:：".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }

    /// Splits `text` after its first `n` letters and digits. If that lands inside a word (Apple
    /// revised a word to be longer), the rest of that word stays with the first part.
    static func split(_ text: String, after n: Int) -> (head: String, rest: String) {
        guard n > 0 else { return ("", text) }
        var count = 0
        var idx = text.startIndex
        while idx < text.endIndex, count < n {
            let c = text[idx]
            if c.isLetter || c.isNumber { count += 1 }
            idx = text.index(after: idx)
        }
        while idx < text.endIndex, idx > text.startIndex,
              text[idx].isLetter, text[text.index(before: idx)].isLetter, !text[idx].isCJK {
            idx = text.index(after: idx)
        }
        return (String(text[..<idx]), String(text[idx...]))
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return ".?!。？！…".contains(last)
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private extension Character {
    var isCJK: Bool { unicodeScalars.first.map { (0x3400...0x9FFF).contains($0.value) } ?? false }
}

extension Recognizer {

    /// Speech starting and pausing, as heard by the voice-activity detector.
    enum SpeechEvent: Sendable {
        case started(Double)                 // audio time speech began
        case paused(Double, long: Bool)      // audio time speech ended; short (0.5 s) or long (1 s) pause
    }

    /// Passes the audio through unchanged, reporting when speech starts and pauses. Uses Silero VAD
    /// (a small neural voice-activity model, bundled), which tells speech from silence and noise
    /// reliably, including during long uninterrupted speech; falls back to an energy detector.
    nonisolated static func withPauseDetection(_ input: AudioStream,
                                               onEvent: @escaping @Sendable (SpeechEvent) -> Void) -> AudioStream {
        AsyncStream { cont in
            let task = Task.detached {
                let vad = VoiceActivity.make()
                var t = 0.0, lastSpeech: Double?, reported = 0, inSpeech = false
                var recent: [Double] = []            // energy fallback: frame levels over the last ~4 s
                for await buf in input {
                    cont.yield(buf)
                    guard buf.frameLength > 0 else { continue }
                    let n = Int(buf.frameLength)
                    var samples = [Float](repeating: 0, count: n)
                    if let f = buf.floatChannelData?[0] {
                        for i in 0..<n { samples[i] = f[i] }
                    } else if let p = buf.int16ChannelData?[0] {
                        for i in 0..<n { samples[i] = Float(p[i]) / 32768 }
                    }
                    let start = t
                    t += Double(n) / buf.format.sampleRate
                    let speech: Bool
                    if let vad, buf.format.sampleRate == 16_000 {
                        speech = vad.isSpeech(samples)
                    } else {
                        let rms = Double((samples.reduce(0) { $0 + $1 * $1 } / Float(n)).squareRoot())
                        let frames = max(20, Int(4.0 * buf.format.sampleRate / Double(n)))
                        recent.append(rms)
                        if recent.count > frames { recent.removeFirst(recent.count - frames) }
                        let floor = recent.count < 10 ? 0.001 : recent.sorted()[recent.count / 5]
                        speech = rms > max(floor * 3, 0.0015)
                    }
                    if speech {
                        if !inSpeech { inSpeech = true; onEvent(.started(max(0, start - VoiceActivity.lag))) }
                        lastSpeech = t
                        reported = 0
                    } else if let s = lastSpeech {
                        // The detector holds "speech" a little past its end; measure from the true end.
                        let end = vad == nil ? s : max(0, s - VoiceActivity.lag)
                        if reported < 1, t - end >= pauseSeconds {
                            onEvent(.paused(end, long: false)); reported = 1
                            inSpeech = false                 // speaking again reports a new start
                        }
                        if reported < 2, t - end >= longPauseSeconds {
                            onEvent(.paused(end, long: true)); reported = 2; lastSpeech = nil; inSpeech = false
                        }
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Silero VAD through sherpa-onnx (model bundled in the app's Resources).
final class VoiceActivity {
    static let lag = 0.15                    // minimum silence the detector waits before "not speech"
    private let vad: SherpaOnnxVoiceActivityDetectorWrapper

    private init(_ vad: SherpaOnnxVoiceActivityDetectorWrapper) { self.vad = vad }

    static var modelPath: String? {
        if let url = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") { return url.path }
        // Development builds run from .build: use the project's copy.
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()      // Engine
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/silero_vad.onnx").path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    static func make() -> VoiceActivity? {
        guard let path = modelPath else { return nil }
        let silero = sherpaOnnxSileroVadModelConfig(model: path, threshold: 0.5, minSilenceDuration: Float(lag),
                                                    minSpeechDuration: 0.15, windowSize: 512, maxSpeechDuration: 60)
        var config = sherpaOnnxVadModelConfig(sileroVad: silero, sampleRate: 16_000, numThreads: 1)
        return VoiceActivity(SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 30))
    }

    /// Feeds 16 kHz samples; true while the detector considers the speaker to be talking.
    func isSpeech(_ samples: [Float]) -> Bool {
        vad.acceptWaveform(samples: samples)
        while !vad.isEmpty() { vad.pop() }            // we only need the live state, not segments
        return vad.isSpeechDetected()
    }
}
