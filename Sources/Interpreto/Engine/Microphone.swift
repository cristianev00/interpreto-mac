import AVFoundation
import Speech

/// Captures a microphone and streams it, converted to the speech model's format, as analyzer input.
///
/// With echo cancellation on, the spoken translation plays through this same engine, and Apple's
/// voice processing (as in FaceTime) removes it from what the microphone hears. So the speaker can
/// keep talking while the translation is spoken, without it being heard as speech.
final class Microphone {
    private(set) var engine = AVAudioEngine()
    private var continuation: AudioStream.Continuation?
    private var tapped = false
    private var target: AVAudioFormat?
    private var device: AudioDeviceID?
    private var configObserver: NSObjectProtocol?
    /// Buffers received since the last start (to detect a microphone that delivers nothing).
    private(set) var buffersReceived = 0

    /// When the translation plays on loudspeakers without echo cancellation, hand the recognizer
    /// silence while it plays, so the microphone can't pick up the voice and translate it again.
    var muteWhileSpeaking = false
    /// True when Apple's echo cancellation is active (then muting isn't needed).
    private(set) var echoCancelled = false

    /// Called on the audio thread with the input level (RMS, 0…1).
    var onLevel: ((Float) -> Void)?

    init() { observe() }

    /// macOS rebuilds the audio setup when voice processing starts, and when devices change
    /// (AirPods connect, a display with speakers is plugged in…), and then stops the engine.
    /// Reconnect the microphone in its new format and carry on.
    private func observe() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.reconnect()
        }
    }

    /// A new engine for a new listening session, so it reads the devices' current formats
    /// (a reused engine can keep a stale one, e.g. AirPods switching to their microphone mode).
    /// Call before handing `engine` to the speaker.
    func freshEngine() {
        guard !engine.isRunning else { return }
        engine = AVAudioEngine()
        observe()
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// - uid: the chosen microphone (nil: system default).
    /// - echoCancellation: the translation plays on the speakers through this engine, so Apple's
    ///   voice processing can remove it. Otherwise the microphone is recorded with
    ///   AVCaptureSession, which works with any device (the audio engine can't start when the
    ///   microphone and the speakers run at different rates, e.g. AirPods' mic + MacBook speakers).
    func start(uid: String?, format target: AVAudioFormat, echoCancellation: Bool,
               source: ListenSource = .microphone) throws -> AudioStream {
        self.target = target
        echoCancelled = false
        if source != .microphone { return try startSystem(source) }
        if !echoCancellation { return try startCapture(uid: uid) }
        let device = AudioDevices.id(forUID: uid, input: true)
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
        self.device = device
        AudioDevices.route(input, to: device)          // once; not on reconnects (it can trigger another one)
        let (stream, cont) = AudioStream.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        buffersReceived = 0
        guard Self.isValid(input.outputFormat(forBus: 0)) else {
            throw NSError(domain: "Interpreto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This microphone can’t be used. Choose another one in Settings."])
        }
        installTap()
        Diagnostics.event("mic: tap installed, input \(input.outputFormat(forBus: 0)), engine running \(engine.isRunning)")
        // Bluetooth microphones take a moment to switch into recording mode: retry briefly.
        var attempt = 0
        while !engine.isRunning {
            do {
                engine.prepare()
                try engine.start()
            } catch {
                attempt += 1
                Diagnostics.event("mic: start attempt \(attempt) failed: \(error)")
                if attempt >= 3 {
                    // The engine can't run this device combination: record without echo
                    // cancellation rather than not at all.
                    input.removeTap(onBus: 0); tapped = false
                    try? input.setVoiceProcessingEnabled(false)
                    continuation?.finish(); continuation = nil
                    Diagnostics.event("mic: falling back to AVCaptureSession (no echo cancellation)")
                    return try startCapture(uid: uid)
                }
                input.removeTap(onBus: 0); tapped = false
                engine.reset()
                Thread.sleep(forTimeInterval: 0.3)
                installTap()
            }
        }
        echoCancelled = input.isVoiceProcessingEnabled
        Diagnostics.event("mic: engine started, running \(engine.isRunning)")
        return stream
    }

    private static func isValid(_ f: AVAudioFormat) -> Bool { f.sampleRate > 0 && f.channelCount > 0 }

    /// Taps the microphone without naming a format (the engine supplies its current one, so the
    /// tap can never mismatch it), takes the first channel as mono, and converts to the model's
    /// format; the converter is rebuilt whenever the microphone's sample rate changes.
    private func installTap() {
        guard let target, let cont = continuation else { return }
        let input = engine.inputNode
        if tapped { input.removeTap(onBus: 0); tapped = false }
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] raw, _ in
            self?.process(raw, cont)
        }
        tapped = true
    }

    // Conversion state, used from one audio thread at a time (engine tap or capture queue).
    private var converter: AVAudioConverter?
    private var mono: AVAudioFormat?

    /// First channel as mono, converted to the model's format (rebuilt when the rate changes).
    private func process(_ raw: AVAudioPCMBuffer, _ cont: AudioStream.Continuation) {
        guard let target, let ch = raw.floatChannelData?[0], raw.frameLength > 0 else { return }
        let rate = raw.format.sampleRate
        if mono?.sampleRate != rate {
            mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = mono.flatMap { AVAudioConverter(from: $0, to: target) }
        }
        guard let mono, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: raw.frameLength),
              let dst = buffer.floatChannelData?[0] else { return }
        let n = Int(raw.frameLength)
        buffersReceived += 1
        buffer.frameLength = raw.frameLength
        let stride = raw.format.isInterleaved ? Int(raw.format.channelCount) : 1
        if muteWhileSpeaking, !echoCancelled, PlaybackState.shared.isActive {
            dst.update(repeating: 0, count: n)            // the voice is playing: hear nothing
        } else if stride == 1 {
            dst.update(from: ch, count: n)
        } else {
            for i in 0..<n { dst[i] = ch[i * stride] }    // interleaved (Mac sound): first channel
        }
        var sum: Float = 0
        for i in 0..<n { sum += dst[i] * dst[i] }
        onLevel?(sqrt(sum / Float(max(1, n))))
        let capacity = AVAudioFrameCount(Double(n) * target.sampleRate / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { cont.yield(out) }
    }

    // MARK: recording with AVCaptureSession (no echo cancellation)

    private var session: AVCaptureSession?
    private var captureDelegate: CaptureDelegate?
    private let captureQueue = DispatchQueue(label: "interpreto.microphone")

    private func startCapture(uid: String?) throws -> AudioStream {
        let device = uid.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else {
            throw NSError(domain: "Interpreto", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found."])
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Mono 32-bit float at the device's own rate; converted to the model's format here.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: true,
                                AVNumberOfChannelsKey: 1]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "Interpreto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This microphone can’t be used. Choose another one in Settings."])
        }
        session.addInput(input)
        session.addOutput(output)
        let (stream, cont) = AudioStream.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        buffersReceived = 0
        let delegate = CaptureDelegate { [weak self] pcm in self?.process(pcm, cont) }
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        captureDelegate = delegate
        session.startRunning()
        self.session = session
        Diagnostics.event("mic: recording \(device.localizedName) with AVCaptureSession")
        return stream
    }

    // MARK: the Mac's own sound

    private var system: SystemAudio?

    private func startSystem(_ source: ListenSource) throws -> AudioStream {
        let (stream, cont) = AudioStream.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        buffersReceived = 0
        let system = SystemAudio()
        try system.start(source) { [weak self] buffer in self?.process(buffer, cont) }
        self.system = system
        Diagnostics.event("listening to the Mac's sound: \(source.raw)")
        return stream
    }

    private var reconnectGeneration = 0

    /// The audio setup changed under us (voice processing starting, a device appearing or going
    /// away). Wait until the microphone reports a valid format again, then reattach and restart.
    private func reconnect(attempt: Int = 0) {
        if attempt == 0 {
            Diagnostics.event("audio configuration changed (engine running \(engine.isRunning)); reconnecting the microphone")
            reconnectGeneration += 1
        }
        let generation = reconnectGeneration
        guard continuation != nil else { return }      // not listening
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, generation == self.reconnectGeneration, self.continuation != nil else { return }
            guard Self.isValid(self.engine.inputNode.outputFormat(forBus: 0)) else {
                if attempt < 20 { self.reconnect(attempt: attempt + 1) }
                else { Diagnostics.event("reconnect: the microphone stayed unavailable") }
                return
            }
            self.installTap()
            if !self.engine.isRunning {
                self.engine.prepare()
                do { try self.engine.start() } catch { Diagnostics.event("reconnect failed: \(error)") }
            }
            Diagnostics.event("mic reconnected, input \(self.engine.inputNode.outputFormat(forBus: 0)), running \(self.engine.isRunning)")
        }
    }

    /// Stops listening. With `keepEngine`, the engine keeps running so a translation still being
    /// spoken through it can finish; call `stopEngine()` afterwards.
    func stop(keepEngine: Bool = false) {
        system?.stop()
        system = nil
        if let session {
            session.stopRunning()
            self.session = nil
            captureDelegate = nil
        }
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

/// Receives AVCaptureSession audio and hands it on as PCM buffers.
private final class CaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let handler: (AVAudioPCMBuffer) -> Void
    init(_ handler: @escaping (AVAudioPCMBuffer) -> Void) { self.handler = handler }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                          into: pcm.mutableAudioBufferList) == noErr else { return }
        handler(pcm)
    }
}
