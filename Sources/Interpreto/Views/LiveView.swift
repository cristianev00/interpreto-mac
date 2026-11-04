import SwiftUI

struct LiveView: View {
    @Environment(LiveController.self) private var live
    @AppStorage(Pref.textSize) private var size = 24.0
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    @AppStorage(Pref.speak) private var speak = false

    private var isEmpty: Bool { live.session.items.isEmpty && live.partial.isEmpty }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    /// Follow new text to the bottom, unless the user has scrolled up to reread.
    @State private var following = true

    /// Changes whenever the transcript grows: a new sentence, more translation, more live text.
    private var growth: Int {
        live.session.items.count &* 7919 &+ (live.session.items.last?.translation.count ?? 0) &* 31
            &+ (live.session.items.last?.source.count ?? 0)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isEmpty {
                EmptyLive()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(live.session.items) { u in
                            UtteranceRow(u: u, size: size, showOriginal: showOriginal,
                                         speaking: live.speakingID == u.id)
                            if u.id != live.session.items.last?.id { Divider() }
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 240)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
                } action: { _, bottom in atBottom = bottom }
                .onScrollPhaseChange { old, new in
                    // Only the user's own scrolling changes whether we follow.
                    if new == .idle, old == .interacting || old == .decelerating { following = atBottom }
                }
                .onChange(of: growth) {
                    guard following else { return }
                    withAnimation(.easeOut(duration: 0.18)) { position.scrollTo(edge: .bottom) }
                }
            }

            VStack(spacing: 12) {
                LiveNow(size: size, showOriginal: showOriginal)
                if !following && !isEmpty {
                    Button {
                        following = true
                        withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.glass)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                RecordCapsule()
            }
            .animation(.easeOut(duration: 0.2), value: following)
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .padding(.top, 36)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color(nsColor: .textBackgroundColor)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: live.session.id) { following = true }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                InputMenu()
                OutputMenu()

                Button { SubtitlePanel.shared.toggle(live) } label: {
                    Label("Subtitles", systemImage: "pip")
                }
                .help("Floating subtitles above every app (⌘⇧S)")

                Menu {
                    ForEach(ExportFormat.allCases) { f in
                        Button(f.title + "…") { Exporter.export(live.session, as: f) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(live.session.items.isEmpty)
                .help("Export this session")

                Button { live.newSession() } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("New session (⌘N)")

                SettingsButton(tab: .audio, title: "Settings", icon: "gearshape")
                    .help("Settings (⌘,)")
            }
        }
    }
}

private struct EmptyLive: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 68, height: 68)
                .background(.tint.opacity(0.12), in: Circle())
                .padding(.bottom, 6)
            Text("Ready to Translate").font(.title2.weight(.semibold))
            Text("Press the record button or ⌘R and start speaking.\nEach sentence is translated the moment you finish it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 120)
    }
}

private struct UtteranceRow: View {
    let u: Utterance
    let size: Double
    let showOriginal: Bool
    let speaking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showOriginal {
                Text(u.source + (u.notSpoken ? "  · not spoken (catching up)" : ""))
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
            Group {
                if u.isTranslating && u.translation.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(u.translation)
                }
            }
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(speaking ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .textSelection(.enabled)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// The words being spoken right now, floating above the record button, with their live
/// translation. When the sentence ends it moves into the list. If the recognizer's live text is
/// briefly empty without a sentence ending, the last words stay up instead of blinking out.
private struct LiveNow: View {
    @Environment(LiveController.self) private var live
    let size: Double
    let showOriginal: Bool
    @State private var shownSource = ""
    @State private var shownDraft = ""
    @State private var clearTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            if showOriginal, !shownSource.isEmpty {
                Text(shownSource).font(.system(size: size * 0.6)).foregroundStyle(.secondary)
            }
            if !shownDraft.isEmpty {
                Text(shownDraft).font(.system(size: size, weight: .medium)).foregroundStyle(.tint.opacity(0.85))
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .frame(maxWidth: 860)
        .animation(.easeOut(duration: 0.15), value: shownDraft)
        .onChange(of: live.partial) { _, text in
            if !text.isEmpty {
                clearTask?.cancel()
                shownSource = text
                shownDraft = live.draft
            } else {
                // Sentence finished (it's now in the list): clear at once. Otherwise hold briefly.
                let finished = live.session.items.last.map { $0.source.hasSuffix(shownSource.suffix(6)) } ?? false
                clearTask?.cancel()
                clearTask = Task {
                    if !finished { try? await Task.sleep(for: .seconds(1.2)) }
                    guard !Task.isCancelled, live.partial.isEmpty else { return }
                    shownSource = ""; shownDraft = ""
                }
            }
        }
        .onChange(of: live.draft) { _, d in if !d.isEmpty || live.partial.isEmpty { shownDraft = d.isEmpty ? shownDraft : d } }
        .onChange(of: live.session.items.count) {
            if live.partial.isEmpty { clearTask?.cancel(); shownSource = ""; shownDraft = "" }
        }
    }
}

struct RecordCapsule: View {
    @Environment(LiveController.self) private var live

    var body: some View {
        HStack(spacing: 14) {
            Button { live.toggle() } label: {
                ZStack {
                    Circle()
                        .stroke(.red.opacity(live.isListening ? 0.45 : 0), lineWidth: 3)
                        .frame(width: 60, height: 60)
                        .scaleEffect(1 + CGFloat(min(1, live.level * 10)) * 0.2)
                        .animation(.linear(duration: 0.08), value: live.level)
                    Circle().fill(.red).frame(width: 52, height: 52)
                    if live.isStarting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: live.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 60, height: 60)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(live.isListening ? "Stop (⌘R)" : "Start listening (⌘R)")

            VStack(alignment: .leading, spacing: 1) {
                Text(live.isListening ? "Listening…" : "Start Listening").font(.headline)
                if live.isListening {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(live.direction.label) · \(live.sourceName) · \(clock(live.elapsed))")
                    }
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    Text("\(live.direction.label) · \(live.sourceName)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 150, alignment: .leading)
        }
        .padding(6)
        .padding(.trailing, 18)
        .glassEffect(.regular, in: .capsule)
    }

    private func clock(_ s: Double) -> String {
        String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

/// "Listen to": the microphone, all sound on this Mac, or one app (Zoom, Teams, a browser…).
/// Toolbar: what Interpreto listens to (a microphone, all Mac sound, or one app).
struct InputMenu: View {
    @Environment(LiveController.self) private var live
    private var devices: DeviceMonitor { .shared }

    private var selection: Binding<String> {
        Binding(get: { live.source == .microphone ? "mic:" + live.micUID : live.source.raw },
                set: { token in
                    if token.hasPrefix("mic:") { live.listen(to: .microphone, mic: String(token.dropFirst(4))) }
                    else { live.listen(to: ListenSource(token)) }
                })
    }

    var body: some View {
        let apps = SystemAudio.apps()
        Menu {
            Picker("Microphone", selection: selection) {
                Label("Default — \(devices.name(devices.defaultInput, input: true) ?? "None")", systemImage: "mic")
                    .tag("mic:")
                ForEach(devices.inputs) { d in
                    Label(d.name, systemImage: AudioDevices.kind(d).icon).tag("mic:" + d.uid)
                }
                if let missing = live.missingMic {
                    Label("\(missing) — not connected", systemImage: "exclamationmark.circle").tag("mic:" + live.micUID)
                }
            }
            .pickerStyle(.inline)
            Picker("This Mac’s Sound", selection: selection) {
                Label("All Sound on This Mac", systemImage: "macbook").tag("all")
                ForEach(apps) { app in
                    Label(app.name, systemImage: app.playing ? "speaker.wave.2.fill" : "app").tag("app:" + app.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsButton(tab: .audio, title: "Audio Settings…")
        } label: {
            Label(live.inputName, systemImage: live.source == .microphone ? "mic.fill" : "speaker.wave.2.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Listening to \(live.inputName). Click to choose a microphone or this Mac’s sound.")
    }
}

/// Toolbar: speak the translation, and where. Clicking toggles the voice; the arrow opens the menu.
struct OutputMenu: View {
    @Environment(LiveController.self) private var live
    @AppStorage(Pref.speak) private var speak = false
    @AppStorage(Pref.voiceZH) private var voiceZH = ""
    @AppStorage(Pref.voiceEN) private var voiceEN = ""
    private var devices: DeviceMonitor { .shared }

    var body: some View {
        let zh = live.direction.targetVoiceLanguage == "zh-CN"
        Menu {
            Toggle("Speak the Translation", isOn: $speak)
            Picker("Play On", selection: Binding(get: { live.outputUID }, set: { live.setOutput($0) })) {
                Label("Default — \(devices.name(devices.defaultOutput, input: false) ?? "None")", systemImage: "speaker.wave.2")
                    .tag("")
                ForEach(devices.outputs) { d in
                    Label(d.name, systemImage: AudioDevices.kind(d).icon).tag(d.uid)
                }
                if let missing = live.missingOutput {
                    Label("\(missing) — not connected", systemImage: "exclamationmark.circle").tag(live.outputUID)
                }
            }
            .pickerStyle(.inline)
            .disabled(!speak)
            Picker(zh ? "Chinese Voice" : "English Voice", selection: zh ? $voiceZH : $voiceEN) {
                Text("Automatic").tag("")
                if zh {
                    Text("Matcha (natural)").tag("neural:matcha")
                } else {
                    ForEach(VoicePack.paradeeVoices.indices, id: \.self) { Text("\(VoicePack.paradeeVoices[$0].1) (natural)").tag("neural:paradee:\($0)") }
                }
                Divider()
                ForEach(Speaker.voices(for: live.direction.targetVoiceLanguage), id: \.identifier) {
                    Text(Speaker.label($0)).tag($0.identifier)
                }
            }
            .disabled(!speak)
            Divider()
            SettingsButton(tab: .audio, title: "Audio Settings…")
        } label: {
            Label(speak ? live.outputName : "Voice Off",
                  systemImage: speak ? "speaker.wave.2.fill" : "speaker.slash")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            speak.toggle()
        }
        .fixedSize()
        .help(speak ? "Speaking on \(live.outputName). Click to turn the voice off." : "Click to speak the translation aloud.")
        .onChange(of: speak) { _, on in live.speakingChanged(on) }
        .onChange(of: voiceZH) { _, v in if v.hasPrefix("neural:"), !VoicePack.matcha.isInstalled { ModelStore.shared.download(.matcha) } }
        .onChange(of: voiceEN) { _, v in if v.hasPrefix("neural:"), !VoicePack.paradee.isInstalled { ModelStore.shared.download(.paradee) } }
    }
}

/// Opens the Settings window on a given tab.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = SettingsTab.speech
    var tab: SettingsTab
    var title = "Settings…"
    var icon: String?

    var body: some View {
        Button {
            settingsTab = tab
            openSettings()
        } label: {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
        }
    }
}
