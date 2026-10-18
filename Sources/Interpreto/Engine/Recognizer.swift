import AVFoundation
import CoreMedia
import Speech

/// Apple's on-device speech recognition (SpeechAnalyzer), tuned for live translation.
///
/// Apple confirms ("finalizes") a sentence only when it has heard more context, which in practice
/// is often when the *next* sentence ends: 5–15 s late. Interpreto doesn't wait: when the speaker
/// pauses, it commits the words heard so far (split by their timestamps) as a sentence, so it can be
/// translated at once. When Apple's confirmed text arrives later, the sentence is quietly revised
/// if any word changed.
@MainActor
final class Recognizer {
    struct Word { let text: String; let start: Double; let end: Double }

    /// A sentence that was committed at a pause and is waiting for Apple's confirmed text.
    private struct Pending {
        let id: UUID; let start: Double; let end: Double; let text: String
        var confirmed: [Word] = []        // Apple may confirm one sentence in several pieces
    }

    nonisolated static let pauseSeconds = 0.5             // a pause after a finished sentence (. ? ! 。)
    nonisolated static let longPauseSeconds = 1.0         // a pause that ends a sentence regardless
    nonisolated static let debug = ProcessInfo.processInfo.environment["INTERPRETO_DEBUG"] != nil

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var words: [Word] = []                       // latest volatile words
    private var volatileEnd = 0.0                        // audio time the volatile result covers
    private var committedThrough = 0.0                   // words starting before this are taken
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
               input: (AVAudioFormat) throws -> AsyncStream<AnalyzerInput>,
               onPartial: @escaping (String) -> Void,
               onCommit: @escaping (UUID, String, Double, Double) -> Void,
               onRevise: @escaping (UUID, String) -> Void,
               onError: @escaping (Error) -> Void) async throws {
        self.onPartial = onPartial
        self.onCommit = onCommit
        self.onRevise = onRevise
        words = []; volatileEnd = 0; committedThrough = 0; pending = []; pauseAt = nil

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
        let stream = Self.withPauseDetection(try input(format)) { [weak self] speechEnd in
            Task { @MainActor in self?.paused(at: speechEnd.0, long: speechEnd.1) }
        }

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let ws = Self.words(r.text)
                    let line = String(format: "%@ %.2f–%.2fs: %@", r.isFinal ? "FINAL" : "volatile",
                                      r.range.start.seconds, r.range.end.seconds, String(r.text.characters))
                    if Self.debug { print("  [\(line)") }
                    Diagnostics.event("recognizer " + line)
                    if r.isFinal { self.confirmed(ws, through: r.range.end.seconds) }
                    else { self.heard(ws, through: r.range.end.seconds) }
                }
            } catch is CancellationError {
            } catch { onError(error) }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Finishes the current audio (so the last sentence is confirmed) and stops.
    func stop() async {
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        commitHeard(upTo: .infinity)
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

    /// Volatile result: everything heard since Apple's last confirmed text.
    private func heard(_ ws: [Word], through end: Double) {
        words = ws
        volatileEnd = end
        if let p = pauseAt, end >= p {
            if pauseIsLong || endsSentence(upTo: p + 0.25) { commitHeard(upTo: p + 0.25) }
        }
        // Apple has processed well past the last word without hearing a new one: a pause, even
        // if the room is too noisy for the level-based detector.
        else if let last = ws.last(where: { $0.start >= committedThrough - 0.05 }) {
            let gap = end - last.end
            if gap >= Self.longPauseSeconds + 0.2 || (gap >= Self.pauseSeconds + 0.2 && endsSentence(upTo: last.end + 0.05)) {
                commitHeard(upTo: last.end + 0.05)
            }
        }
        onPartial(Self.join(ws.filter { $0.start >= committedThrough - 0.05 }))
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
            if long || endsSentence(upTo: speechEnd + 0.25) { commitHeard(upTo: speechEnd + 0.25) }
            return
        }
        pauseAt = speechEnd
        pauseIsLong = long
        pauseDeadline?.cancel()
        pauseDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled, let p = self.pauseAt else { return }
            if self.pauseIsLong || self.endsSentence(upTo: p + 0.25) { self.commitHeard(upTo: p + 0.25) }
        }
    }

    private func endsSentence(upTo limit: Double) -> Bool {
        let text = Self.join(words.filter { $0.start >= committedThrough - 0.05 && $0.start < limit })
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return ".?!。？！…".contains(last)
    }

    private func commitHeard(upTo limit: Double) {
        pauseAt = nil
        pauseDeadline?.cancel()
        let ws = words.filter { $0.start >= committedThrough - 0.05 && $0.start < limit }
        let text = Self.join(ws)
        guard !text.isEmpty, let first = ws.first, let last = ws.last else { return }
        let id = UUID()
        pending.append(Pending(id: id, start: first.start, end: last.end, text: text))
        committedThrough = last.end
        onCommit(id, text, first.start, last.end)
        onPartial(Self.join(words.filter { $0.start >= committedThrough - 0.05 }))
    }

    /// Apple's confirmed text through `end`: revise committed sentences that changed, and commit
    /// any confirmed words that no pause has claimed yet.
    private func confirmed(_ ws: [Word], through end: Double) {
        var claimed = Set<Int>()
        for i in pending.indices where pending[i].start < end {
            let p = pending[i]
            let next = pending.first { $0.start > p.start }?.start ?? .infinity
            let mine = ws.enumerated().filter {
                $0.element.start >= p.start - 0.3 && $0.element.start < next - 0.05 && $0.element.start < p.end + 0.3
            }
            claimed.formUnion(mine.map(\.offset))
            pending[i].confirmed += mine.map(\.element)
        }
        // Sentences Apple has now confirmed completely: show the confirmed wording if it differs.
        for p in pending where p.end <= end + 0.05 {
            let text = Self.join(p.confirmed)
            if !text.isEmpty, Self.normalized(text) != Self.normalized(p.text) { onRevise(p.id, text) }
        }
        pending.removeAll { $0.end <= end + 0.05 }
        let rest = ws.enumerated()
            .filter { !claimed.contains($0.offset) && $0.element.start >= committedThrough - 0.05 }
            .map(\.element)
        if let first = rest.first, let last = rest.last {
            let text = Self.join(rest)
            if !text.isEmpty {
                committedThrough = last.end
                onCommit(UUID(), text, first.start, last.end)
            }
        }
        committedThrough = max(committedThrough, end)
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

    static func join(_ ws: [Word]) -> String {
        var s = tidy(ws.map(\.text).joined())
        while let f = s.first, ",.，。、;；:：".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Passes the audio through unchanged, calling `onPause(endOfSpeech)` when speech is followed
    /// by a pause. Speech is energy well above an adaptive noise floor.
    nonisolated static func withPauseDetection(_ input: AsyncStream<AnalyzerInput>,
                                               onPause: @escaping @Sendable ((Double, Bool)) -> Void) -> AsyncStream<AnalyzerInput> {
        AsyncStream { cont in
            let task = Task.detached {
                var t = 0.0, lastSpeech: Double?, reported = 0      // pauses reported for lastSpeech: 0, 1 (short), 2 (long)
                var recent: [Double] = []                  // frame levels over the last ~4 s
                for await item in input {
                    cont.yield(item)
                    let buf = item.buffer
                    guard buf.frameLength > 0 else { continue }
                    let n = Int(buf.frameLength)
                    var sum = 0.0
                    if let f = buf.floatChannelData?[0] {
                        for i in 0..<n { sum += Double(f[i] * f[i]) }
                    } else if let p = buf.int16ChannelData?[0] {
                        for i in 0..<n { let v = Double(p[i]) / 32768; sum += v * v }
                    }
                    let rms = (sum / Double(n)).squareRoot()
                    t += Double(n) / buf.format.sampleRate
                    // Noise floor: the typical quiet level of the last few seconds (20th percentile),
                    // not the single quietest moment, which echo cancellation can push near zero.
                    let frames = max(20, Int(4.0 * buf.format.sampleRate / Double(n)))
                    recent.append(rms)
                    if recent.count > frames { recent.removeFirst(recent.count - frames) }
                    let floor = recent.count < 10 ? 0.001 : recent.sorted()[recent.count / 5]
                    if rms > max(floor * 3, 0.0015) {
                        lastSpeech = t
                        reported = 0
                    } else if let s = lastSpeech {
                        if reported < 1, t - s >= pauseSeconds { onPause((s, false)); reported = 1 }
                        if reported < 2, t - s >= longPauseSeconds { onPause((s, true)); reported = 2; lastSpeech = nil }
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
