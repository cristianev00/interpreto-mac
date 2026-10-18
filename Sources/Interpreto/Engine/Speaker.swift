import AVFoundation

/// Speaks translations with Apple's voices on any output device (headphones, a speaker, or a
/// virtual cable into Zoom). Sentences are skipped when the voice falls too far behind.
@MainActor
final class Speaker {
    static let maxBacklog = 6.0          // seconds of unplayed voice before a sentence is skipped

    private let synth = AVSpeechSynthesizer()
    private let ownEngine = AVAudioEngine()
    private var engine: AVAudioEngine            // ownEngine, or the microphone's (echo cancellation)
    private let player = AVAudioPlayerNode()
    /// The player runs in the voice's own format; the engine's mixer converts it to the device
    /// smoothly. (Converting each small buffer separately leaves a click at every seam.)
    private var format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    private var deviceUID: String?
    private var backlog = 0.0

    init() {
        engine = ownEngine
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// True while a translation is still being spoken.
    var isSpeaking: Bool { backlog > 0.05 }

    /// Play through `shared` (the microphone's echo-cancelling engine) or, with nil, through
    /// Interpreto's own engine on the chosen output device.
    func use(engine shared: AVAudioEngine?) {
        let target = shared ?? ownEngine
        Diagnostics.event("voice: use \(shared == nil ? "own engine" : "microphone engine") (changing \(target !== engine))")
        guard target !== engine else { return }
        player.stop()
        backlog = 0
        engine.detach(player)
        engine = target
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Voices for a language, best first: Apple's neural (Siri-quality) voices, then premium and
    /// enhanced ones, then the standard ones. Novelty and character voices are left out.
    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { v in
                v.language.hasPrefix(prefix) && (prefix != "zh" || v.language == "zh-CN")
                    && !v.voiceTraits.contains(.isNoveltyVoice) && !v.voiceTraits.contains(.isPersonalVoice)
                    && !v.identifier.contains(".eloquence.") && !v.identifier.contains(".speech.synthesis.")
            }
            .sorted { (score($0), $0.name) > (score($1), $1.name) }
    }

    private static func score(_ v: AVSpeechSynthesisVoice) -> Int {
        var s = v.quality.rawValue * 10
        if v.identifier.contains("neural") { s += 100 }
        if v.identifier.contains("super-compact") { s -= 5 }
        if v.language == "en-US" || v.language == "zh-CN" { s += 3 }
        return s
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        if v.identifier.contains("neural") { return "Natural (Siri quality) · \(v.language)" }
        let q = v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)"
            : v.identifier.contains("super-compact") ? " (Basic)" : ""
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
        guard engine === ownEngine else { return }   // the shared engine plays on the default output
        let uid = (uid?.isEmpty ?? true) ? nil : uid
        guard uid != deviceUID || !engine.isRunning else { return }
        if engine.isRunning { engine.stop() }
        deviceUID = uid
        AudioDevices.route(engine.outputNode, to: AudioDevices.id(forUID: uid, input: false))
    }

    private func enqueue(_ pcm: AVAudioPCMBuffer) {
        let f = pcm.format
        if f.sampleRate != format.sampleRate || f.channelCount != format.channelCount || f.commonFormat != format.commonFormat {
            player.stop()
            engine.disconnectNodeOutput(player)
            format = f
            engine.connect(player, to: engine.mainMixerNode, format: f)
        }
        if !engine.isRunning {
            if engine !== ownEngine { use(engine: nil) }   // listening stopped: back to our own engine
            engine.prepare()
            do { try engine.start() } catch { return }
        }
        let seconds = Double(pcm.frameLength) / f.sampleRate
        backlog += seconds
        player.scheduleBuffer(pcm) { [weak self] in
            DispatchQueue.main.async { self.map { $0.backlog = max(0, $0.backlog - seconds) } }
        }
        if !player.isPlaying { player.play() }
    }
}
