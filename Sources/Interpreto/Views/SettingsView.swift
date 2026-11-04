import AVFoundation
import SwiftUI

enum SettingsTab: String {
    case speech, audio, display, glossary
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.speech

    var body: some View {
        TabView(selection: $tab) {
            Tab("Speech", systemImage: "person.wave.2", value: .speech) { EngineSettings() }
            Tab("Audio", systemImage: "waveform", value: .audio) { AudioSettings() }
            Tab("Display", systemImage: "textformat.size", value: .display) { DisplaySettings() }
            Tab("Glossary", systemImage: "character.book.closed", value: .glossary) { GlossarySettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct AudioSettings: View {
    @Environment(LiveController.self) private var live
    @AppStorage(Pref.speak) private var speak = false
    @AppStorage(Pref.voiceZH) private var voiceZH = ""
    @AppStorage(Pref.voiceEN) private var voiceEN = ""
    private var store: ModelStore { .shared }
    private var devices: DeviceMonitor { .shared }

    @ViewBuilder
    private func packRow(_ pack: VoicePack) -> some View {
        LabeledContent(pack.title) {
            switch store.state(pack) {
            case .installed:
                HStack {
                    Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Remove") { store.remove(pack) }.buttonStyle(.borderless)
                }
            case .downloading(let p): ProgressView(value: p).frame(width: 140)
            case .notInstalled: Button("Download (\(pack.size))") { store.download(pack) }
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.red).lineLimit(1)
                    Button("Try Again") { store.download(pack) }
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Listen to", selection: Binding(
                    get: { live.source == .microphone ? "mic" : "mac" },
                    set: { live.listen(to: $0 == "mic" ? .microphone : .allApps) })) {
                    Label("Microphone", systemImage: "mic").tag("mic")
                    Label("This Mac’s sound", systemImage: "macbook").tag("mac")
                }
                .pickerStyle(.segmented)
                if live.source == .microphone {
                    Picker("Microphone", selection: Binding(get: { live.micUID }, set: { live.listen(to: .microphone, mic: $0) })) {
                        Label("Default (\(devices.name(devices.defaultInput, input: true) ?? "none"))", systemImage: "mic").tag("")
                        ForEach(devices.inputs) { Label($0.name, systemImage: AudioDevices.kind($0).icon).tag($0.uid) }
                        if let missing = live.missingMic {
                            Label("\(missing) (not connected)", systemImage: "exclamationmark.circle").tag(live.micUID)
                        }
                    }
                    LabeledContent("Level") {
                        if live.isListening { LevelMeter(level: live.level) }
                        else { Text("Shown while listening").foregroundStyle(.secondary) }
                    }
                } else {
                    LabeledContent("Listening to", value: live.sourceName)
                }
            } header: {
                Text("Input")
            } footer: {
                Text(live.missingMic != nil
                     ? "\(live.missingMic!) isn’t connected, so the default microphone is used. Interpreto switches back as soon as it connects."
                     : "Changes apply immediately, even while listening.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Speak the translation aloud", isOn: $speak)
                    .onChange(of: speak) { _, on in live.speakingChanged(on) }
                Group {
                    Picker("Play on", selection: Binding(get: { live.outputUID }, set: { live.setOutput($0) })) {
                        Label("Default (\(devices.name(devices.defaultOutput, input: false) ?? "none"))", systemImage: "speaker.wave.2").tag("")
                        ForEach(devices.outputs) { Label($0.name, systemImage: AudioDevices.kind($0).icon).tag($0.uid) }
                        if let missing = live.missingOutput {
                            Label("\(missing) (not connected)", systemImage: "exclamationmark.circle").tag(live.outputUID)
                        }
                    }
                    LabeledContent("Echo protection", value: echoText)
                    Picker("Chinese voice", selection: $voiceZH) {
                        Text("Automatic").tag("")
                        Section("Natural") { Text("Matcha").tag("neural:matcha") }
                        Section("Apple") {
                            ForEach(Speaker.voices(for: "zh-CN"), id: \.identifier) { Text(Speaker.label($0)).tag($0.identifier) }
                        }
                    }
                    .onChange(of: voiceZH) { _, v in if v.hasPrefix("neural:"), !VoicePack.matcha.isInstalled { store.download(.matcha) } }
                    Picker("English voice", selection: $voiceEN) {
                        Text("Automatic").tag("")
                        Section("Natural") {
                            ForEach(VoicePack.paradeeVoices.indices, id: \.self) { Text(VoicePack.paradeeVoices[$0].1).tag("neural:paradee:\($0)") }
                        }
                        Section("Apple") {
                            ForEach(Speaker.voices(for: "en-US"), id: \.identifier) { Text(Speaker.label($0)).tag($0.identifier) }
                        }
                    }
                    .onChange(of: voiceEN) { _, v in if v.hasPrefix("neural:"), !VoicePack.paradee.isInstalled { store.download(.paradee) } }
                    ForEach(VoicePack.allCases) { pack in packRow(pack) }
                }
                .disabled(!speak)
            } header: {
                Text("Spoken Translation")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Natural voices run on this Mac and sound much more human than Apple’s standard voices. “Automatic” uses them once downloaded.")
                    Text("Use headphones so the microphone doesn’t hear the voice. To send it into Zoom or Teams, choose a virtual cable such as BlackHole.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices.refresh() }
    }

    /// How the microphone is kept from hearing the voice, in words.
    private var echoText: String {
        let p = live.audioPlan()
        if p.source != .microphone { return "Not needed (Interpreto’s voice isn’t captured)" }
        if !p.protection { return "Not needed (headphones or headset)" }
        return p.echo ? "Echo cancellation" : "Microphone pauses while the voice speaks"
    }
}

/// A small live input level bar.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        // Speech is roughly 0.01–0.1 RMS: show it on a log-like scale.
        let v = min(1, max(0, (log10(Double(max(level, 0.0005))) + 3.3) / 2.5))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(v > 0.85 ? .orange : .green).frame(width: g.size.width * v)
            }
        }
        .frame(width: 160, height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct DisplaySettings: View {
    @AppStorage(Pref.textSize) private var size = 24.0
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    @AppStorage(Pref.livePreview) private var livePreview = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Text size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: $size, in: 16...44).frame(width: 180)
                        Image(systemName: "textformat.size.larger")
                    }
                }
                Toggle("Show the original sentence", isOn: $showOriginal)
                Toggle("Translate while I’m still speaking", isOn: $livePreview)
            } footer: {
                Text("Interpreto follows your Mac’s Light or Dark appearance.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GlossarySettings: View {
    @AppStorage(Pref.glossary) private var glossary = ""

    /// Adds the lines of `extra` whose English term isn't in the glossary yet.
    static func merge(_ current: String, _ extra: String) -> String {
        let have = Set(Glossary(text: current).pairs.map { $0.en.lowercased() })
        let new = extra.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let en = Glossary(text: line).pairs.first?.en.lowercased() else { return false }
                return !have.contains(en)
            }
        guard !new.isEmpty else { return current }
        let base = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "" : base + "\n") + new.joined(separator: "\n")
    }

    private func importGlossary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        glossary = Self.merge(glossary, text.replacingOccurrences(of: ",", with: " = "))
    }

    private func exportGlossary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Interpreto glossary.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? glossary.write(to: url, atomically: true, encoding: .utf8)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $glossary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if glossary.isEmpty {
                            Text("pointer = 指针\nmemory leak = 内存泄漏\nInterpreto = Interpreto")
                                .font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Terms")
            } footer: {
                Text("One term per line: English = 中文. Works in both directions: terms heard as sound-alikes are corrected (“a bugger overflow” → “a buffer overflow”, 指真 → 指针), and the translation always uses your wording. \(Glossary(text: glossary).pairs.count) terms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Add C Programming Terms") { glossary = Self.merge(glossary, TermPacks.cProgramming) }
                    Spacer()
                    Button("Import…") { importGlossary() }
                    Button("Export…") { exportGlossary() }.disabled(glossary.isEmpty)
                }
            } footer: {
                Text("Import and export plain text files with one “English = 中文” pair per line, to share a glossary with students or colleagues.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// System Settings → Accessibility → Spoken Content, where Apple's voices are downloaded.
@MainActor
func openVoiceSettings() {
    let urls = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"]
    for u in urls {
        if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
    }
}

/// Which engine recognizes each spoken language: Apple's (built in) or a downloaded model.
private struct EngineSettings: View {
    @Environment(LiveController.self) private var live
    @AppStorage(Pref.engineEN) private var english = SpeechEngine.apple.rawValue
    @AppStorage(Pref.engineZH) private var chinese = SpeechEngine.apple.rawValue
    private var store: ModelStore { .shared }

    var body: some View {
        Form {
            section("When English is spoken", direction: .enToZh, selection: $english,
                    note: "Parakeet made about 30% fewer mistakes than Apple on English spoken with 22 different accents, at the same speed.")
            section("When Chinese is spoken", direction: .zhToEn, selection: $chinese,
                    note: "SenseVoice made about 25% fewer mistakes than Apple on Mandarin, and is trained on many regional accents.")
            Section {
            } footer: {
                Text("Models run entirely on this Mac. If a model isn’t downloaded yet, Apple’s engine is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }

    @ViewBuilder
    private func section(_ title: String, direction: Direction, selection: Binding<String>, note: String) -> some View {
        Section {
            Picker("Speech engine", selection: selection) {
                ForEach(SpeechEngine.options(for: direction)) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: selection.wrappedValue) { _, value in
                if let e = SpeechEngine(rawValue: value), e != .apple, store.state(e) != .installed { store.download(e) }
                live.preloadEngine()
            }
            ForEach(SpeechEngine.options(for: direction).filter { $0 != .apple }) { e in
                modelRow(e)
            }
        } header: {
            Text(title)
        } footer: {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func modelRow(_ e: SpeechEngine) -> some View {
        LabeledContent(e.modelName) {
            switch store.state(e) {
            case .installed:
                HStack {
                    Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Remove") { store.remove(e) }.buttonStyle(.borderless)
                }
            case .downloading(let p):
                ProgressView(value: p).frame(width: 160)
            case .notInstalled:
                Button("Download (\(e.downloadSize))") { store.download(e) }
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.red).lineLimit(1)
                    Button("Try Again") { store.download(e) }
                }
            }
        }
    }
}
