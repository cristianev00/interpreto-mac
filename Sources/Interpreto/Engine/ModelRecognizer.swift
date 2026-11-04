import AVFoundation
import Speech

/// The interface the live session uses, whichever engine recognizes the speech.
@MainActor
protocol SpeechRecognizing: AnyObject {
    func start(direction d: Direction, vocabulary: [String],
               input: (AVAudioFormat) throws -> AudioStream,
               onPartial: @escaping (String) -> Void,
               onCommit: @escaping (UUID, String, Double, Double) -> Void,
               onRevise: @escaping (UUID, String) -> Void,
               onError: @escaping (Error) -> Void) async throws
    func stop() async
    func cancel() async
}

extension Recognizer: SpeechRecognizing {}

/// Live recognition with a model that transcribes whole utterances (Parakeet, SenseVoice).
///
/// The sentence in progress is re-transcribed about twice a second for the live words; when the
/// speaker pauses it is transcribed once more and committed. A short pause ends a sentence that
/// ends with . ? ! 。 ？ ！; a long pause ends it regardless. Speech without pauses (a livestream,
/// a fast talker) is cut after 6–10 s at its quietest moment, so a word is never split (7 s split
/// ordinary long English sentences; 10 s keeps them whole). At 20 s,
/// a recording of nonstop Mandarin waited ~20 s per piece plus ~6 s to translate 100 characters.
@MainActor
final class ModelRecognizer: SpeechRecognizing {
    static let rate = 16_000.0
    static let partialEvery = 0.5          // seconds of new audio between live updates
    static let maxUtterance = 10.0         // seconds; longer speech is committed in parts…
    static let cutSearch = 4.0             // …cut at the quietest moment of its last 4 s
    static let preRoll = 0.5               // seconds kept before speech starts

    let engine: SpeechEngine
    private var model: UtteranceModel?
    private var feedTask: Task<Void, Never>?

    private var samples: [Float] = []      // the utterance so far (from just before speech began)
    private var startTime = 0.0            // audio time of samples[0]
    private var time = 0.0                 // audio time fed so far
    private var speaking = false
    /// The voice-activity detector currently hears speech (updated as events arrive, even while
    /// a sentence is still being committed).
    private var vadActive = false
    private var loudness = 0.0             // loudest stretch of speech in the current sentence
    private let gate = LoudnessGate()
    private var lastPartialAt = 0.0
    private var busy = false               // a transcription is running
    private var lastPartial = ""

    private var onPartial: (String) -> Void = { _ in }
    private var onCommit: (UUID, String, Double, Double) -> Void = { _, _, _, _ in }
    private var onError: (Error) -> Void = { _ in }

    init(engine: SpeechEngine) { self.engine = engine }

    /// Loads the model (once); the first load compiles it, which can take a few seconds.
    func prepare() async throws {
        if model != nil { return }
        switch engine {
        case .parakeet: model = try await ParakeetModel.load()
        case .sensevoice: model = try await Task.detached { try SenseVoiceModel.load() }.value
        case .apple: break
        }
    }

    func start(direction d: Direction, vocabulary: [String],
               input: (AVAudioFormat) throws -> AudioStream,
               onPartial: @escaping (String) -> Void,
               onCommit: @escaping (UUID, String, Double, Double) -> Void,
               onRevise: @escaping (UUID, String) -> Void,
               onError: @escaping (Error) -> Void) async throws {
        self.onPartial = onPartial
        self.onCommit = onCommit
        self.onError = onError
        samples = []; startTime = 0; time = 0; speaking = false; lastPartialAt = 0; lastPartial = ""
        try await prepare()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        let stream = Recognizer.withPauseDetection(try input(format)) { [weak self] event in
            Task { @MainActor in
                switch event {
                case .started(let t):
                    self?.vadActive = true
                    if self?.speaking == false { self?.loudness = 0 }   // a new stretch of speech: its own loudness
                    self?.speechStarted(at: t)
                case .paused(let end, let long, let loudness):
                    if !long { self?.vadActive = false }
                    if let self { self.loudness = max(self.loudness, loudness) }
                    await self?.paused(at: end, long: long)
                }
            }
        }
        Diagnostics.event("speech engine: \(engine.rawValue)")
        feedTask = Task { @MainActor [weak self] in
            for await item in stream {
                guard let self else { return }
                await self.feed(item)
            }
        }
    }

    /// Frees the model's memory; it reloads on the next start.
    func unload() { model = nil }

    func stop() async {
        feedTask?.cancel()
        feedTask = nil
        await commit(upTo: time)
    }

    func cancel() async {
        feedTask?.cancel()
        feedTask = nil
        samples = []
    }

    // MARK: audio

    private func feed(_ buf: AVAudioPCMBuffer) async {
        // A device that's being reconfigured can hand over a buffer without memory.
        // Read the samples from the buffer list itself, never past its real size.
        let list = buf.audioBufferList.pointee.mBuffers
        guard buf.format.commonFormat == .pcmFormatFloat32, let data = list.mData else { return }
        let n = min(Int(buf.frameLength), Int(list.mDataByteSize) / MemoryLayout<Float>.size)
        guard n > 0 else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n))
        time += Double(n) / Self.rate
        if !speaking {
            // Before speech: keep only a short pre-roll.
            let keep = Int(Self.preRoll * Self.rate)
            if samples.count > keep { samples.removeFirst(samples.count - keep) }
            startTime = time - Double(samples.count) / Self.rate
            return
        }
        let length = time - startTime
        if length >= Self.maxUtterance {
            let from = Int((length - Self.cutSearch) * Self.rate), to = samples.count - Int(0.3 * Self.rate)
            let cut = Self.quietestPoint(samples, from: from, to: to)
            Diagnostics.event(String(format: "no pause for %.1fs: cut at %.2fs", length, startTime + Double(cut) / Self.rate))
            await commit(upTo: startTime + Double(cut) / Self.rate)
        } else if time - lastPartialAt >= Self.partialEvery, !busy {
            lastPartialAt = time
            await updatePartial()
        }
    }

    private static func level(_ p: UnsafeMutablePointer<Float>, _ n: Int) -> Float {
        var s: Float = 0
        for i in 0..<n { s += p[i] * p[i] }
        return (s / Float(max(1, n))).squareRoot()
    }

    private func updatePartial() async {
        guard let model, !samples.isEmpty else { return }
        busy = true
        let text = (try? await model.transcribe(samples)).map(Self.clean) ?? ""
        busy = false
        if !text.isEmpty, speaking {
            lastPartial = text
            onPartial(text)
        }
    }

    // MARK: sentences

    /// The voice-activity detector heard speech begin (it reports it a moment late).
    private func speechStarted(at t: Double) {
        trace(String(format: "event: speech started at %.2f (speaking already: %@)", t, speaking ? "yes" : "no"))
        guard !speaking else { return }
        speaking = true
        trace(String(format: "speech starts at %.2f", t))
    }

    /// Sentence work runs one step at a time, in order: a slow second pass must not let a later
    /// pause commit the same audio again.
    private var queue: Task<Void, Never>?

    private func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        await task.value
    }

    private func paused(at speechEnd: Double, long: Bool) async {
        await serially { [weak self] in await self?.handlePause(at: speechEnd, long: long) }
    }

    private func handlePause(at speechEnd: Double, long: Bool) async {
        Diagnostics.event(String(format: "pause (%@): speech ended %.2fs", long ? "long" : "short", speechEnd))
        trace(String(format: "pause (%@) at %.2f, speaking %@, utterance from %.2f", long ? "long" : "short", speechEnd, speaking ? "yes" : "no", startTime))
        guard speaking else { return }
        if long { await commitNow(upTo: speechEnd + 0.25); return }
        // Short pause: commit only a finished sentence.
        guard let model else { return }
        let cut = min(samples.count, Int((speechEnd + 0.25 - startTime) * Self.rate))
        guard cut > 0 else { return }
        let text = Self.clean((try? await model.transcribe(Array(samples[..<cut]))) ?? "")
        trace("short-pause text: \(text)")
        if Recognizer.endsSentence(text) { await commitNow(upTo: speechEnd + 0.25, liveText: text) }
    }

    private func commit(upTo end: Double) async {
        await serially { [weak self] in await self?.commitNow(upTo: end) }
    }

    /// Commits the utterance up to audio time `end` as a sentence and keeps any audio after it for
    /// the next sentence. The audio is taken first, then transcribed. With a second-pass model the
    /// sentence is transcribed again by it, unless that clearly dropped words the live model heard.
    private func commitNow(upTo end: Double, liveText: String? = nil) async {
        guard speaking, let model else { return }
        let cut = max(0, min(samples.count, Int((end - startTime) * Self.rate)))
        let head = Array(samples[..<cut])
        let start = startTime
        samples.removeFirst(min(cut, samples.count))
        startTime = start + Double(cut) / Self.rate
        // If the speaker already went on talking while this was being handled, keep listening:
        // otherwise the next "speech started" event begins the next sentence.
        speaking = vadActive
        lastPartial = ""
        lastPartialAt = time
        onPartial("")

        var text = liveText ?? ""
        if liveText == nil { text = Self.clean((try? await model.transcribe(head)) ?? "") }
        trace(String(format: "commit %.2f–%.2f, %d samples left: %@", start, end, samples.count, text))
        let heard = Self.speechLoudness(head)
        loudness = 0
        trace(String(format: "loudness %.4f for: %@", heard, text))
        if !text.isEmpty, !gate.accept(heard) {           // quiet background voices: not for us
            Diagnostics.event(String(format: "ignored background speech (%.4f): %@", heard, text))
            trace("ignored background speech: \(text)")
            return
        }
        if !text.isEmpty {
            Diagnostics.event(String(format: "SENTENCE (%@) %.2f–%.2fs: %@", engine.rawValue, start, end, text))
            onCommit(UUID(), text, start, end)
        }
    }

    static func clean(_ s: String) -> String { Recognizer.clean(s) }

    /// The sample index in `from..<to` at the middle of the quietest 200 ms (10 frames of 20 ms):
    /// the gap between two words, where cutting loses nothing.
    nonisolated static func quietestPoint(_ samples: [Float], from: Int, to: Int) -> Int {
        let frame = 320, window = 10
        let lo = max(0, from), hi = min(samples.count, to)
        guard hi - lo >= frame * window else { return hi }
        var energy: [Float] = []
        var i = lo
        while i + frame <= hi {
            var e: Float = 0
            for j in i..<(i + frame) { e += samples[j] * samples[j] }
            energy.append(e)
            i += frame
        }
        var sum = energy[0..<window].reduce(0, +), best = sum, bestAt = 0
        for k in window..<energy.count {
            sum += energy[k] - energy[k - window]
            if sum < best { best = sum; bestAt = k - window + 1 }
        }
        return lo + (bestAt + window / 2) * frame
    }

    /// How loud the speech in `samples` is: the level of its loudest 20 ms stretches (90th
    /// percentile), so pauses don't lower it and a stretch containing the main speaker counts
    /// as the main speaker's.
    static func speechLoudness(_ samples: [Float]) -> Double {
        let frame = 320
        guard samples.count >= frame else { return 0 }
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            levels.append(Double((sum / Float(frame)).squareRoot()))
            i += frame
        }
        levels.sort()
        return levels[min(levels.count - 1, levels.count * 9 / 10)]
    }

    private func trace(_ t: String) {
        if Recognizer.debug { print(String(format: "  [%.2fs] ", time) + t) }
    }
}
