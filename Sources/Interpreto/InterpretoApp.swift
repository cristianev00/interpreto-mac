import SwiftUI


struct InterpretoApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var history: HistoryStore
    @State private var live: LiveController
    @State private var readiness = Readiness()

    init() {
        Pref.register()
        let h = HistoryStore()
        _history = State(initialValue: h)
        _live = State(initialValue: LiveController(history: h))
    }

    var body: some Scene {
        Window("Interpreto", id: "main") {
            ContentView()
                .environment(live)
                .environment(history)
                .environment(readiness)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { live.newSession() }.keyboardShortcut("n")
            }
            CommandGroup(after: .help) {
                Button("Record Diagnostics (30 s)") { live.recordDiagnostics() }
            }
            CommandMenu("Translate") {
                Button(live.isListening ? "Stop Listening" : "Start Listening") { live.toggle() }
                    .keyboardShortcut("r")
                Button("Switch Direction") { live.switchDirection() }
                    .keyboardShortcut("d")
                Divider()
                Button("Show Subtitles") { SubtitlePanel.shared.toggle(live) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(live)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case live, text, history
    var id: String { rawValue }
    var title: String { ["live": "Live", "text": "Text", "history": "History"][rawValue]! }
    var icon: String { ["live": "waveform", "text": "character.bubble", "history": "clock"][rawValue]! }
}

struct ContentView: View {
    @Environment(LiveController.self) private var live
    @Environment(Readiness.self) private var readiness
    @State private var pane: Pane = .live

    var body: some View {
        Group {
            if !readiness.checked {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !readiness.ready {
                SetupView()
            } else {
                NavigationSplitView {
                    List(selection: $pane) {
                        ForEach(Pane.allCases) { p in
                            Label(p.title, systemImage: p.icon).tag(p)
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
                    .safeAreaInset(edge: .bottom) { StatusFooter() }
                } detail: {
                    Group {
                        switch pane {
                        case .live: LiveView()
                        case .text: TextTranslateView()
                        case .history: HistoryView()
                        }
                    }
                    .toolbar {
                        if pane != .history {
                            ToolbarItem(placement: .principal) { DirectionPicker() }
                        }
                    }
                }
            }
        }
        .task {
            await readiness.check()
            if CommandLine.arguments.contains("--diagnose") { live.recordDiagnostics() }
        }
        .alert("Interpreto", isPresented: Binding(get: { live.message != nil }, set: { if !$0 { live.message = nil } })) {
            Button("OK") { live.message = nil }
        } message: {
            Text(live.message ?? "")
        }
    }
}

struct DirectionPicker: View {
    @Environment(LiveController.self) private var live

    var body: some View {
        Picker("Direction", selection: Binding(get: { live.direction }, set: { live.setDirection($0) })) {
            ForEach(Direction.allCases) { d in
                Text(d.label).tag(d)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch direction (⌘D)")
    }
}

struct StatusFooter: View {
    @Environment(LiveController.self) private var live

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(live.isListening ? "Listening" : "Ready")
            } icon: {
                Circle().fill(live.isListening ? .red : .green).frame(width: 7, height: 7)
            }
            if let d = live.lastDelay {
                Label(String(format: "Translated in %.2f s", d), systemImage: "bolt.fill")
                    .foregroundStyle(.secondary)
            }
            Label("Runs entirely on this Mac", systemImage: "lock.fill")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}
