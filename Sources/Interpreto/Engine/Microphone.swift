import AVFoundation
import Speech

/// Captures a microphone and streams it, converted to the speech model's format, as analyzer input.
///
/// With echo cancellation on, the spoken translation plays through this same engine, and Apple's
/// voice processing (as in FaceTime) removes it from what the microphone hears. So the speaker can
/// keep talking while the translation is spoken, without it being heard as speech.
final class Microphone {
    let engine = AVAudioEngine()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapped = false
    private var target: AVAudioFormat?
    private var device: AudioDeviceID?
    private var configObserver: NSObjectProtocol?
    /// Buffers received since the last start (to detect a microphone that delivers nothing).
    private(set) var buffersReceived = 0

    /// Called on the audio thread with the input level (RMS, 0…1).
    var onLevel: ((Float) -> Void)?

    init() {
        // macOS rebuilds the audio setup when voice processing starts, and when devices change
        // (AirPods connect, a display with speakers is plugged in…), and then stops the engine.
        // Reconnect the microphone in its new format and carry on.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.reconnect()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func start(device: AudioDeviceID?, format target: AVAudioFormat, echoCancellation: Bool) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != echoCancellation {
            if engine.isRunning { engine.stop() }
            try input.setVoiceProcessingEnabled(echoCancellation)
        }
        if echoCancellation {
            // Don't turn down other apps (a video being translated, a call) while listening.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            input.isVoiceProcessingAGCEnabled = true
        }
        self.target = target
        self.device = device
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        buffersReceived = 0
        try installTap()
        Diagnostics.event("mic: tap installed, input \(input.outputFormat(forBus: 0)), engine running \(engine.isRunning)")
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        Diagnostics.event("mic: engine started, running \(engine.isRunning)")
        return stream
    }

    private func installTap() throws {
        guard let target, let cont = continuation else { return }
        let input = engine.inputNode
        if tapped { input.removeTap(onBus: 0); tapped = false }
        AudioDevices.route(input, to: device)
        let source = input.outputFormat(forBus: 0)
        // Microphones (and voice processing, which reports 7–9 identical channels) can be
        // multichannel: take the first channel as mono, then convert to the model's format.
        guard source.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: target) else {
            throw NSError(domain: "Interpreto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This microphone can’t be used. Choose another one in Settings."])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] raw, _ in
            guard let self, let ch = raw.floatChannelData?[0],
                  let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: raw.frameLength),
                  let dst = buffer.floatChannelData?[0] else { return }
            let n = Int(raw.frameLength)
            self.buffersReceived += 1
            buffer.frameLength = raw.frameLength
            dst.update(from: ch, count: n)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            self.onLevel?(sqrt(sum / Float(max(1, n))))
            let capacity = AVAudioFrameCount(Double(n) * target.sampleRate / source.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
        }
        tapped = true
    }

    /// The audio setup changed under us: reinstall the tap for the new format and restart.
    private func reconnect() {
        Diagnostics.event("audio configuration changed (engine running \(engine.isRunning)); reconnecting the microphone")
        guard continuation != nil else { return }      // not listening
        do {
            try installTap()
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            Diagnostics.event("reconnect failed: \(error)")
        }
    }

    /// Stops listening. With `keepEngine`, the engine keeps running so a translation still being
    /// spoken through it can finish; call `stopEngine()` afterwards.
    func stop(keepEngine: Bool = false) {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        continuation?.finish()
        continuation = nil
        if !keepEngine { stopEngine() }
    }

    func stopEngine() {
        guard !tapped else { return }
        Diagnostics.event("mic: engine stopped")
        engine.stop()
    }
}
