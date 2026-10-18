import os
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
        // Menus ask on every redraw; the installed voices rarely change.
        if let cached = voiceCache.withLock({ $0[language] }) { return cached }
        let list = findVoices(for: language)
        voiceCache.withLock { $0[language] = list }
        return list
    }
    private static let voiceCache = OSAllocatedUnfairLock(initialState: [String: [AVSpeechSynthesisVoice]]())

    private static func findVoices(for language: String) -> [AVSpeechSynthesisVoice] {
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
        let chosen = (voiceID?.isEmpty ?? true) ? Self.automaticVoice(language) : voiceID
        if let spec = VoicePack.spec(for: chosen), VoicePack.pack(of: spec).isInstalled {
            speakNeural(text, spec, onStart: onStart)
            return true
        }
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
        PlaybackState.shared.stopped()
        generation += 1
        neuralChain?.cancel()
        neuralChain = nil
        synth.stopSpeaking(at: .immediate)
        player.stop()
        backlog = 0
    }

    // MARK: natural (neural) voices

    private var neuralChain: Task<Void, Never>?
    private var generation = 0

    /// "Automatic": the natural voice when it's downloaded, otherwise Apple's best.
    static func automaticVoice(_ language: String) -> String? {
        if language.hasPrefix("zh") { return VoicePack.matcha.isInstalled ? "neural:matcha" : nil }
        return VoicePack.supertonic.isInstalled ? "neural:supertonic:0" : nil
    }

    /// Synthesizes clause by clause, in order, so the first words play as soon as they're ready.
    private func speakNeural(_ text: String, _ spec: NeuralVoiceSpec, onStart: @escaping () -> Void) {
        let gen = generation
        let previous = neuralChain
        neuralChain = Task { @MainActor [weak self] in
            await previous?.value
            var started = false
            for clause in Self.clauses(text) {
                guard let self, gen == self.generation else { return }
                guard let out = await VoiceEngine.shared.synthesize(clause, spec) else { continue }
                guard gen == self.generation, let pcm = Self.buffer(out.samples, rate: out.rate) else { return }
                if !started { started = true; onStart() }
                self.enqueue(pcm)
            }
        }
    }

    /// Splits at clause punctuation, joining very short pieces so the speech isn't choppy.
    static func clauses(_ text: String) -> [String] {
        var pieces: [String] = [], current = ""
        for ch in text {
            current.append(ch)
            if "，。！？；：,.!?;:".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { pieces.append(t) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { pieces.append(rest) }
        var out: [String] = [], pending = ""
        for p in pieces {
            pending = pending.isEmpty ? p : pending + (p.first?.isASCII == true ? " " : "") + p
            if pending.filter({ $0.isLetter || $0.isNumber }).count >= 8 { out.append(pending); pending = "" }
        }
        if !pending.isEmpty {
            if let last = out.popLast() { out.append(last + (pending.first?.isASCII == true ? " " : "") + pending) }
            else { out.append(pending) }
        }
        return out
    }

    private static func buffer(_ samples: [Float], rate: Int) -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buf
    }

    private func setOutput(_ uid: String?) {
        guard engine === ownEngine else { return }   // the shared engine plays on the default output
        // The chosen output if it's connected, otherwise the Mac's current default.
        let device = AudioDevices.id(forUID: uid, input: false).map { _ in uid }
            ?? AudioDevices.defaultUID(input: false)
        // Compare with the device the engine really uses: macOS moves it back to the default
        // output when echo cancellation starts on the microphone.
        let id = AudioDevices.id(forUID: device, input: false)
        guard id != AudioDevices.current(engine.outputNode) || !engine.isRunning else { return }
        if engine.isRunning { engine.stop() }
        deviceUID = device
        AudioDevices.route(engine.outputNode, to: id)
        Diagnostics.event("voice: plays on \(device ?? "-")")
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
        PlaybackState.shared.playing(remaining: backlog)
        player.scheduleBuffer(pcm) { [weak self] in
            DispatchQueue.main.async { self.map { $0.backlog = max(0, $0.backlog - seconds) } }
        }
        if !player.isPlaying { player.play() }
    }
}
