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
    private let mic = Microphone()
    private let recognizer = Recognizer()
    let translator = Translator()
    private let speaker = Speaker()
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
    }

    // MARK: listening

    func toggle() { isListening ? stop() : start() }

    func start() {
        guard !isListening, !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                message = "Interpreto needs the microphone. Allow it in System Settings → Privacy & Security → Microphone."
                return
            }
            if session.items.isEmpty { session = Session(direction: direction); started = Date() }
            else if session.direction != direction { newSession(); started = Date() }
            let device = AudioDevices.id(forUID: defaults.string(forKey: Pref.micUID), input: true)
            // Voice on the normal speakers: play it through the microphone's engine so Apple's
            // echo cancellation removes it from what the mic hears, and the speaker can keep
            // talking. With headphones or a virtual cable chosen, there's no echo to cancel.
            let echo = defaults.bool(forKey: Pref.speak) && (defaults.string(forKey: Pref.outputUID) ?? "").isEmpty
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
            do {
                try await recognizer.start(
                    direction: direction, vocabulary: glossary.vocabulary(for: direction),
                    input: { [mic] format in
                        Diagnostics.event("listening: \(self.direction.label), echo cancellation \(echo), recognizer format \(format)")
                        return Diagnostics.tap(try mic.start(device: device, format: format, echoCancellation: echo), format: format)
                    },
                    onPartial: { [weak self] in self?.partialChanged($0) },
                    onCommit: { [weak self] id, text, start, end in self?.committed(id, text, start, end) },
                    onRevise: { [weak self] id, text in self?.revised(id, text) },
                    onError: { [weak self] e in self?.message = e.localizedDescription; self?.stop() })
                isListening = true
                listeningSince = Date()
            } catch {
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
        guard isListening else { return }
        isListening = false
        mic.stop()
        Task {
            await recognizer.stop()
            start()
        }
    }

    // MARK: recognition events

    private var now: Double { Date().timeIntervalSince(started) }

    private func partialChanged(_ text: String) {
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
            let t = try? await translator.translate(text, d, glossary: glossary)
            if !partial.isEmpty, let t { draft = t }
            draftTask = nil
            if let next = draftPending { draftPending = nil; if !partial.isEmpty { runDraft(next) } }
        }
    }

    /// A new sentence: translate it at once, then speak it if enabled.
    private func committed(_ id: UUID, _ text: String, _ start: Double, _ end: Double) {
        Diagnostics.event(String(format: "SENTENCE %.2f–%.2fs: %@", start, end, text))
        let offset = (listeningSince ?? started).timeIntervalSince(started)
        session.items.append(Utterance(id: id, source: text, start: offset + start, end: offset + end))
        draftPending = nil
        let d = direction
        Task {
            let t0 = Date()
            let tr = await translate(text, d)
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
    private func revised(_ id: UUID, _ text: String) {
        update(id) { $0.source = text }
        let d = direction
        Task {
            let tr = await translate(text, d)
            update(id) { $0.translation = tr; $0.isTranslating = false }
            scheduleSave()
        }
    }

    private func translate(_ text: String, _ d: Direction) async -> String {
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
