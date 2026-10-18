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
            mic.onLevel = { [weak self] v in DispatchQueue.main.async { self?.level = v } }
            do {
                try await recognizer.start(
                    direction: direction, vocabulary: glossary.vocabulary(for: direction),
                    input: { [mic] format in try mic.start(device: device, format: format) },
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
        mic.stop()
        Task { await recognizer.stop() }
    }

    func switchDirection() { setDirection(direction.reversed) }

    func setDirection(_ d: Direction) {
        guard d != direction else { return }
        let wasListening = isListening
        if wasListening {
            isListening = false
            mic.stop()
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

    func newSession() {
        if isListening { stop() }
        speaker.stop()
        session = Session(direction: direction)
        partial = ""; draft = ""; speakingID = nil
        started = Date()
    }

    func speakingChanged(_ on: Bool) { if !on { speaker.stop() } }

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
                let spoken = speaker.speak(tr, language: d.targetVoiceLanguage,
                                           voiceID: defaults.string(forKey: voiceKey),
                                           outputUID: defaults.string(forKey: Pref.outputUID),
                                           onStart: { [weak self] in self?.speakingID = id })
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
