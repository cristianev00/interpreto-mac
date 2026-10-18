import AVFoundation
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Speech", systemImage: "person.wave.2") { EngineSettings() }
            Tab("Audio", systemImage: "waveform") { AudioSettings() }
            Tab("Display", systemImage: "textformat.size") { DisplaySettings() }
            Tab("Glossary", systemImage: "character.book.closed") { GlossarySettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct AudioSettings: View {
    @AppStorage(Pref.micUID) private var micUID = ""
    @AppStorage(Pref.speak) private var speak = false
    @AppStorage(Pref.voiceZH) private var voiceZH = ""
    @AppStorage(Pref.voiceEN) private var voiceEN = ""
    @AppStorage(Pref.outputUID) private var outputUID = ""
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $micUID) {
                    Text("System Default").tag("")
                    ForEach(inputs) { Text($0.name).tag($0.uid) }
                }
            }
            Section {
                Toggle("Speak the translation aloud", isOn: $speak)
                Group {
                    Picker("Chinese voice", selection: $voiceZH) {
                        Text("Automatic").tag("")
                        ForEach(Speaker.voices(for: "zh-CN"), id: \.identifier) { Text(Speaker.label($0)).tag($0.identifier) }
                    }
                    Picker("English voice", selection: $voiceEN) {
                        Text("Automatic").tag("")
                        ForEach(Speaker.voices(for: "en-US"), id: \.identifier) { Text(Speaker.label($0)).tag($0.identifier) }
                    }
                    Picker("Play on", selection: $outputUID) {
                        Text("System Default").tag("")
                        ForEach(outputs) { Text($0.name).tag($0.uid) }
                    }
                }
                .disabled(!speak)
            } header: {
                Text("Spoken Translation")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use headphones so the microphone doesn’t hear the voice. To send it into Zoom or Teams, choose a virtual cable such as BlackHole.")
                    HStack(alignment: .firstTextBaseline) {
                        Text("For a much more natural voice, download a free Premium or Enhanced voice (for Chinese: Lili or Tingting; for English: Ava, Zoe or Evan). Interpreto picks it up automatically.")
                        Button("Get Voices…") { openVoiceSettings() }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            inputs = AudioDevices.list(input: true)
            outputs = AudioDevices.list(input: false)
        }
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
                Text("One term per line: English = 中文. Works in both directions: the recognizer listens for these words and the translation always uses your wording. \(Glossary(text: glossary).pairs.count) terms.")
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
        LabeledContent(e == .parakeet ? "Parakeet model" : "SenseVoice model") {
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
