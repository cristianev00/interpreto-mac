import AVFoundation
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
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
                Text("Use headphones so the microphone doesn’t hear the voice. To send it into Zoom or Teams, choose a virtual cable such as BlackHole. More natural voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
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
