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
/// ends with . ? ! 。 ？ ！; a long pause ends it regardless; very long speech is cut at 20 s.
@MainActor
final class ModelRecognizer: SpeechRecognizing {
    static let rate = 16_000.0
    static let partialEvery = 0.5          // seconds of new audio between live updates
    static let maxUtterance = 20.0         // seconds; longer speech is committed in parts
    static let preRoll = 0.5               // seconds kept before speech starts

    let engine: SpeechEngine
    private var model: UtteranceModel?
    private var feedTask: Task<Void, Never>?

    private var samples: [Float] = []      // the utterance so far (from just before speech began)
    private var startTime = 0.0            // audio time of samples[0]
    private var time = 0.0                 // audio time fed so far
    private var speaking = false
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
                case .started(let t): self?.speechStarted(at: t)
                case .paused(let end, let long): await self?.paused(at: end, long: long)
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
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
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
            await commit(upTo: time)
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
        guard !speaking else { return }
        speaking = true
        trace(String(format: "speech starts at %.2f", t))
    }

    private func paused(at speechEnd: Double, long: Bool) async {
        Diagnostics.event(String(format: "pause (%@): speech ended %.2fs", long ? "long" : "short", speechEnd))
        trace(String(format: "pause (%@) at %.2f, speaking %@, utterance from %.2f", long ? "long" : "short", speechEnd, speaking ? "yes" : "no", startTime))
        guard speaking else { return }
        if long { await commit(upTo: speechEnd + 0.25); return }
        // Short pause: commit only a finished sentence.
        guard let model else { return }
        let cut = min(samples.count, Int((speechEnd + 0.25 - startTime) * Self.rate))
        guard cut > 0 else { return }
        let text = Self.clean((try? await model.transcribe(Array(samples[..<cut]))) ?? "")
        trace("short-pause text: \(text)")
        if Recognizer.endsSentence(text) { await commit(upTo: speechEnd + 0.25, text: text) }
    }

    /// Commits the utterance up to audio time `end` as a sentence (transcribing it unless `text`
    /// is given) and keeps any audio after it for the next sentence.
    private func commit(upTo end: Double, text known: String? = nil) async {
        guard speaking, let model else { return }
        let cut = max(0, min(samples.count, Int((end - startTime) * Self.rate)))
        let head = Array(samples[..<cut])
        let text: String
        if let known { text = known } else {
            text = Self.clean((try? await model.transcribe(head)) ?? "")
        }
        let start = startTime
        samples.removeFirst(min(cut, samples.count))
        startTime = start + Double(cut) / Self.rate
        speaking = false            // the next "speech started" event begins the next sentence
        trace(String(format: "commit %.2f–%.2f, %d samples left, speaking %@: %@", start, end, samples.count, speaking ? "yes" : "no", text))
        lastPartial = ""
        lastPartialAt = time
        onPartial("")
        if !text.isEmpty {
            Diagnostics.event(String(format: "SENTENCE (%@) %.2f–%.2fs: %@", engine.rawValue, start, end, text))
            onCommit(UUID(), text, start, end)
        }
    }

    static func clean(_ s: String) -> String { Recognizer.clean(s) }

    private func trace(_ t: String) {
        if Recognizer.debug { print(String(format: "  [%.2fs] ", time) + t) }
    }
}
