import AVFoundation

/// Speaks translations with Apple's voices on any output device (headphones, a speaker, or a
/// virtual cable into Zoom). Sentences are skipped when the voice falls too far behind.
@MainActor
final class Speaker {
    static let maxBacklog = 6.0          // seconds of unplayed voice before a sentence is skipped

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var converters: [String: AVAudioConverter] = [:]
    private var deviceUID: String?
    private var backlog = 0.0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Voices for a language, best quality first.
    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) && (prefix != "zh" || $0.language == "zh-CN") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let q = v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : ""
        return "\(v.name)\(q) · \(v.language)"
    }

    /// Returns false if the sentence was skipped to catch up with the speaker.
    @discardableResult
    func speak(_ text: String, language: String, voiceID: String?, outputUID: String?, onStart: @escaping () -> Void) -> Bool {
        guard backlog < Self.maxBacklog else { return false }
        setOutput(outputUID)
        let u = AVSpeechUtterance(string: text)
        u.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.voices(for: language).first
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.08
        var started = false
        synth.write(u) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if !started { started = true; onStart() }
                self.enqueue(pcm)
            }
        }
        return true
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player.stop()
        backlog = 0
    }

    private func setOutput(_ uid: String?) {
        let uid = (uid?.isEmpty ?? true) ? nil : uid
        guard uid != deviceUID || !engine.isRunning else { return }
        if engine.isRunning { engine.stop() }
        deviceUID = uid
        AudioDevices.route(engine.outputNode, to: AudioDevices.id(forUID: uid, input: false))
    }

    private func enqueue(_ pcm: AVAudioPCMBuffer) {
        let key = pcm.format.description
        if converters[key] == nil { converters[key] = AVAudioConverter(from: pcm.format, to: format) }
        guard let conv = converters[key],
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * format.sampleRate / pcm.format.sampleRate) + 64)
        else { return }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return pcm
        }
        guard error == nil, out.frameLength > 0 else { return }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return }
        }
        let seconds = Double(out.frameLength) / format.sampleRate
        backlog += seconds
        player.scheduleBuffer(out) { [weak self] in
            DispatchQueue.main.async { self.map { $0.backlog = max(0, $0.backlog - seconds) } }
        }
        if !player.isPlaying { player.play() }
    }
}
