import AVFoundation
import Observation
import SwiftUI

/// Runs a live session: microphone → speech recognition → translation → (optional) voice.
@MainActor
@Observable
final class LiveController {
    var direction: Direction {
        didSet { UserDefaults.standard.set(direction.rawValue, forKey: Pref.direction) }
    }
    private(set) var isListening = false
    private(set) var isStarting = false
    private(set) var level: Float = 0
    private(set) var session: Session
    /// The sentence being spoken right now, and its live translation.
    private(set) var partial = ""
    private(set) var draft = ""
    private(set) var speakingID: UUID?
    private(set) var lastDelay: Double?
    private(set) var listeningSince: Date?
    var elapsed: Double { Date().timeIntervalSince(listeningSince ?? Date()) }
    var message: String?

    let history: HistoryStore
    let mic = Microphone()
    private let appleRecognizer = Recognizer()
    private var modelRecognizers: [SpeechEngine: ModelRecognizer] = [:]
    private var recognizer: SpeechRecognizing
    /// The speech engine actually in use (Apple if the chosen model isn't downloaded).
    private(set) var activeEngine: SpeechEngine = .apple

    /// The engine chosen in Settings for the spoken language, if its model is installed.
    private func recognizer(for d: Direction) -> SpeechRecognizing {
        let e = SpeechEngine.chosen(for: d)
        guard e != .apple, ModelStore.isInstalled(e) else { activeEngine = .apple; return appleRecognizer }
        activeEngine = e
        if let r = modelRecognizers[e] { return r }
        let r = ModelRecognizer(engine: e)
        modelRecognizers[e] = r
        return r
    }

    /// Three minutes after listening stops (and nothing is being spoken), free the optional
    /// models' memory (speech models and natural voices: up to ~1 GB). They reload in about
    /// a second when listening starts again.
    private var idleTask: Task<Void, Never>?
    static let idleSeconds = 180.0

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard let self, !Task.isCancelled else { return }
            while self.speaker.isSpeaking { try? await Task.sleep(for: .seconds(5)) }
            guard !self.isListening, !Task.isCancelled else { return }
            for r in self.modelRecognizers.values { r.unload() }
            await VoiceEngine.shared.unload()
            Diagnostics.event("idle: optional models unloaded")
        }
    }

    /// What Interpreto listens to: the microphone, all Mac sound, or one app.
    var source: ListenSource {
        get { _ = sourceVersion; return ListenSource(defaults.string(forKey: Pref.listenSource)) }
        set { listen(to: newValue) }
    }
    private(set) var sourceVersion = 0        // lets views refresh when the source changes

    /// The microphone chosen in the toolbar or Settings ("" = the Mac's default).
    var micUID: String { _ = sourceVersion; return defaults.string(forKey: Pref.micUID) ?? "" }
    /// Where the spoken translation plays ("" = the Mac's default output).
    var outputUID: String { _ = sourceVersion; return defaults.string(forKey: Pref.outputUID) ?? "" }

    /// Listen to a source (and, for the microphone, a specific one), switching at once if listening.
    func listen(to source: ListenSource, mic uid: String? = nil) {
        if let uid {
            defaults.set(uid, forKey: Pref.micUID)
            // Remember the name, to show it while the device (AirPods…) isn't connected.
            defaults.set(DeviceMonitor.shared.name(uid, input: true), forKey: "micName")
        }
        if source != self.source { defaults.set(source.raw, forKey: Pref.listenSource) }
        sourceVersion += 1
        devicesChanged()
    }

    func setOutput(_ uid: String) {
        defaults.set(uid, forKey: Pref.outputUID)
        defaults.set(DeviceMonitor.shared.name(uid, input: false), forKey: "outputName")
        sourceVersion += 1
        devicesChanged()
    }

    /// A chosen device that isn't connected now (its name), while the default is used instead.
    var missingMic: String? {
        _ = sourceVersion
        let uid = micUID, d = DeviceMonitor.shared
        return uid.isEmpty || d.inputs.contains { $0.uid == uid } ? nil : defaults.string(forKey: "micName") ?? "Microphone"
    }
    var missingOutput: String? {
        _ = sourceVersion
        let uid = outputUID, d = DeviceMonitor.shared
        return uid.isEmpty || d.outputs.contains { $0.uid == uid } ? nil : defaults.string(forKey: "outputName") ?? "Speaker"
    }

    /// The device names the toolbar shows.
    var inputName: String {
        guard source == .microphone else { return sourceName }
        let p = audioPlan()
        return DeviceMonitor.shared.name(p.mic, input: true).map(Self.short) ?? "Microphone"
    }
    var outputName: String {
        DeviceMonitor.shared.name(audioPlan().output, input: false).map(Self.short) ?? "Speakers"
    }
    /// "MacBook Pro Microphone" → "MacBook Pro", "Ever’s iPhone Microphone" → "Ever’s iPhone".
    static func short(_ name: String) -> String {
        var n = name
        for suffix in [" Microphone", " Speakers", " Speaker"] where n.hasSuffix(suffix) && n.count > suffix.count {
            n = String(n.dropLast(suffix.count))
        }
        return n
    }

    /// Which devices a session uses, and how the microphone is kept from hearing the voice.
    struct AudioPlan: Equatable {
        var source: ListenSource
        var chosenMic: String?        // nil = default input
        var mic: String?              // the device actually used
        var output: String?
        var protection: Bool          // the voice plays where the microphone can hear it
        var echo: Bool                // ...and Apple's echo cancellation can remove it
    }
    private(set) var activePlan: AudioPlan?

    func audioPlan() -> AudioPlan {
        let monitor = DeviceMonitor.shared
        // A chosen device that isn't connected right now falls back to the default.
        let chosenMic = micUID.isEmpty || !monitor.inputs.contains { $0.uid == micUID } ? nil : micUID
        let chosenOut = outputUID.isEmpty || !monitor.outputs.contains { $0.uid == outputUID } ? nil : outputUID
        let defaultIn = monitor.defaultInput, defaultOut = monitor.defaultOutput
        let mic = chosenMic ?? defaultIn, out = chosenOut ?? defaultOut
        // Listening to the Mac's sound: Interpreto's own voice is excluded from the capture.
        // On loudspeakers with a microphone that isn't a headset, the mic would hear the voice:
        // Apple's echo cancellation removes it when both are the system defaults; otherwise the
        // microphone is muted while the voice plays.
        let protection = source == .microphone && defaults.bool(forKey: Pref.speak)
            && AudioDevices.isLoudspeaker(out) && !AudioDevices.isHeadset(mic)
        return AudioPlan(source: source, chosenMic: chosenMic, mic: mic, output: out, protection: protection,
                         echo: protection && mic == defaultIn && out == defaultOut)
    }

    /// Devices were chosen, connected or removed: if the session would now use different
    /// devices, restart listening with them (a fraction of a second; the session continues).
    func devicesChanged() {
        guard isListening, let active = activePlan else { return }
        let plan = audioPlan()
        guard plan != active else { return }
        Diagnostics.event("devices changed while listening: restarting")
        restart()
    }

    /// Stops and starts listening again in the same session.
    private func restart() {
        guard isListening else { return }
        isListening = false
        stopMic()
        Task {
            await recognizer.stop()
            try? await Task.sleep(for: .milliseconds(150))
            start()
        }
    }

    /// Short name of the source, for the record button.
    var sourceName: String {
        _ = sourceVersion
        switch source {
        case .microphone: return "Microphone"
        case .allApps: return "Mac sound"
        case .app(let id): return SystemAudio.apps().first { $0.id == id }?.name
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { $0.deletingPathExtension().lastPathComponent } ?? id
        }
    }

    /// Name of the speech engine for the current direction (what the sidebar shows).
    var engineName: String {
        let e = SpeechEngine.chosen(for: direction)
        let use = (e != .apple && ModelStore.shared.state(e) == .installed) ? e : .apple
        return ["apple": "Apple", "parakeet": "Parakeet", "sensevoice": "SenseVoice"][use.rawValue]!
    }

    /// Loads the chosen model ahead of time, so pressing record starts at once.
    func preloadEngine() {
        guard let r = recognizer(for: direction) as? ModelRecognizer else { return }
        Task { try? await r.prepare() }
    }
    let translator = Translator()
    let speaker = Speaker()
    private var started = Date()
    private var draftTask: Task<Void, Never>?
    private var draftPending: String?
    private var saveTask: Task<Void, Never>?

    private var defaults: UserDefaults { .standard }
    var glossary: Glossary { Glossary(text: defaults.string(forKey: Pref.glossary) ?? "") }

    init(history: HistoryStore) {
        self.history = history
        let d = Direction(rawValue: UserDefaults.standard.string(forKey: Pref.direction) ?? "") ?? .enToZh
        direction = d
        session = Session(direction: d)
        recognizer = appleRecognizer
        DeviceMonitor.shared.onChange = { [weak self] in self?.devicesChanged() }
    }

    // MARK: listening

    func toggle() { isListening ? stop() : start() }

    func start() {
        guard !isListening, !isStarting else { return }
        idleTask?.cancel()
        isStarting = true
        Task {
            defer { isStarting = false }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                message = "Interpreto needs the microphone. Allow it in System Settings → Privacy & Security → Microphone."
                return
            }
            if session.items.isEmpty { session = Session(direction: direction); started = Date() }
            else if session.direction != direction { newSession(); started = Date() }
            let plan = audioPlan()
            activePlan = plan
            let echo = plan.echo
            mic.muteWhileSpeaking = plan.protection
            Diagnostics.event("devices: mic \(plan.mic ?? "-"), output \(plan.output ?? "-"); protection \(plan.protection), echo cancellation \(echo)")
            mic.freshEngine()
            speaker.use(engine: echo ? mic.engine : nil)
            var lastLevelLog = Date.distantPast
            mic.onLevel = { [weak self] v in
                DispatchQueue.main.async {
                    self?.level = v
                    if Diagnostics.isRecording, Date().timeIntervalSince(lastLevelLog) > 0.25 {
                        lastLevelLog = Date()
                        Diagnostics.event(String(format: "mic level %.4f%@", v, self?.speaker.isSpeaking == true ? "  (voice playing)" : ""))
                    }
                }
            }
            recognizer = recognizer(for: direction)
            do {
                try await recognizer.start(
                    direction: direction, vocabulary: glossary.vocabulary(for: direction),
                    input: { [mic] format in
                        // Echo cancellation runs on the default devices and mustn't be pointed at a device.
                        Diagnostics.event("listening: \(self.direction.label), echo cancellation \(echo), recognizer format \(format)")
                        return Diagnostics.tap(try mic.start(uid: echo ? nil : plan.mic, format: format, echoCancellation: echo, source: plan.source), format: format)
                    },
                    onPartial: { [weak self] in self?.partialChanged($0) },
                    onCommit: { [weak self] id, text, start, end in self?.committed(id, text, start, end) },
                    onRevise: { [weak self] id, text in self?.revised(id, text) },
                    onError: { [weak self] e in self?.message = e.localizedDescription; self?.stop() })
                // Echo cancellation takes about a second to warm up: show "Starting…" until the
                // microphone really delivers, so the first words aren't lost.
                if plan.source == .microphone {
                    let t0 = Date()
                    while mic.buffersReceived < 12, Date().timeIntervalSince(t0) < 3 {
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    Diagnostics.event(String(format: "mic: sound flowing after %.2f s (%d buffers)", Date().timeIntervalSince(t0), mic.buffersReceived))
                }
                isListening = true
                listeningSince = Date()
            } catch {
                Diagnostics.event("start failed: \(error) — \((error as NSError).domain) \((error as NSError).code)")
                mic.stop()
                await recognizer.cancel()
                message = error.localizedDescription
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        level = 0
        scheduleIdleUnload()
        stopMic()
        Task { await recognizer.stop() }
    }

    func switchDirection() { setDirection(direction.reversed) }

    func setDirection(_ d: Direction) {
        guard d != direction else { return }
        let wasListening = isListening
        if wasListening {
            isListening = false
            stopMic()
            Task {
                await recognizer.cancel()
                partial = ""; draft = ""
                direction = d
                start()
            }
        } else {
            direction = d
            preloadEngine()
        }
    }

    /// Stops the microphone; if a translation is still being spoken through its engine, lets it
    /// finish first.
    private func stopMic() {
        guard speaker.isSpeaking else { mic.stop(); return }
        mic.stop(keepEngine: true)
        Task {
            while speaker.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
            if !isListening { mic.stopEngine() }
        }
    }

    /// Help → Record Diagnostics: listen for 30 s while recording what the recognizer hears.
    func recordDiagnostics() {
        guard !Diagnostics.isRecording else { return }
        if isListening { stop() }
        Diagnostics.begin()
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            start()
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                let input = mic.engine.inputNode
                Diagnostics.event("mic health: \(mic.buffersReceived) buffers, engine running \(mic.engine.isRunning), echo cancellation \(input.isVoiceProcessingEnabled), listening \(isListening), starting \(isStarting), input \(input.outputFormat(forBus: 0))")
            }
            stop()
            try? await Task.sleep(for: .seconds(2))
            Diagnostics.end()
            if let f = Diagnostics.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            message = "Diagnostics saved in “Interpreto Diagnostics” on your Desktop."
        }
    }

    func newSession() {
        if isListening { stop() }
        speaker.stop()
        session = Session(direction: direction)
        partial = ""; draft = ""; speakingID = nil
        started = Date()
    }

    /// The voice was turned on or off: switch echo cancellation to match (a quick restart of the
    /// microphone; the session continues).
    func speakingChanged(_ on: Bool) {
        if !on { speaker.stop() }
        sourceVersion += 1
        devicesChanged()
    }

    // MARK: recognition events

    private var now: Double { Date().timeIntervalSince(started) }

    private func partialChanged(_ text: String) {
        if text != partial { Diagnostics.event("live text: \(text)") }
        partial = text
        if text.isEmpty { draft = ""; return }
        guard defaults.bool(forKey: Pref.livePreview) else { draft = ""; return }
        // Translate the sentence in progress; if a translation is running, translate the latest
        // text as soon as it finishes (Apple's translation takes ~50 ms).
        if draftTask != nil { draftPending = text; return }
        runDraft(text)
    }

    private func runDraft(_ text: String) {
        let d = direction
        draftTask = Task {
            let t = try? await translator.translate(text, d, glossary: glossary, quick: true)
            if !partial.isEmpty, let t { draft = t }
            draftTask = nil
            if let next = draftPending { draftPending = nil; if !partial.isEmpty { runDraft(next) } }
        }
    }

    /// A new sentence: translate it at once, then speak it if enabled.
    /// Glossary terms the engine heard as sound-alikes are corrected ("a bugger overflow" →
    /// "a buffer overflow", 指真 → 指针) before the sentence is shown and translated.
    private func fixTerms(_ text: String, _ d: Direction) -> String {
        let fixed = TermFixer.fix(text, terms: glossary.vocabulary(for: d), chinese: d == .zhToEn)
        if fixed != text { Diagnostics.event("terms fixed: \(text) → \(fixed)") }
        return fixed
    }

    private func committed(_ id: UUID, _ heard: String, _ start: Double, _ end: Double) {
        let text = fixTerms(heard, direction)
        Diagnostics.event(String(format: "SENTENCE %.2f–%.2fs: %@", start, end, text))
        let offset = (listeningSince ?? started).timeIntervalSince(started)
        session.items.append(Utterance(id: id, source: text, start: offset + start, end: offset + end))
        draftPending = nil
        let d = direction
        Task {
            let t0 = Date()
            let tr = await translate(text, d, before: id)
            lastDelay = Date().timeIntervalSince(t0)
            update(id) { $0.translation = tr; $0.isTranslating = false }
            if defaults.bool(forKey: Pref.speak), !tr.isEmpty {
                let voiceKey = d == .enToZh ? Pref.voiceZH : Pref.voiceEN
                Diagnostics.event("voice queued: \(tr)")
                let spoken = speaker.speak(tr, language: d.targetVoiceLanguage,
                                           voiceID: defaults.string(forKey: voiceKey),
                                           outputUID: defaults.string(forKey: Pref.outputUID),
                                           onStart: { [weak self] in self?.speakingID = id; Diagnostics.event("voice starts playing") })
                if !spoken { update(id) { $0.notSpoken = true } }
            }
            scheduleSave()
        }
    }

    /// Apple confirmed different wording for a sentence: show it and re-translate (not re-spoken).
    private func revised(_ id: UUID, _ heard: String) {
        let d = direction
        let text = fixTerms(heard, d)
        update(id) { $0.source = text }
        Task {
            let tr = await translate(text, d, before: id)
            update(id) { $0.translation = tr; $0.isTranslating = false }
            scheduleSave()
        }
    }

    /// Translates a finished sentence.
    private func translate(_ text: String, _ d: Direction, before id: UUID) async -> String {
        do { return try await translator.translate(text, d, glossary: glossary) }
        catch { message = "Translation failed: \(error.localizedDescription)"; return "" }
    }

    private func update(_ id: UUID, _ change: (inout Utterance) -> Void) {
        guard let i = session.items.firstIndex(where: { $0.id == id }) else { return }
        change(&session.items[i])
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            history.save(session)
        }
    }
}
