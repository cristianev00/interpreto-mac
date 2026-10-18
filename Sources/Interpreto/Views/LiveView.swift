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
            &+ live.partial.count &* 7 &+ live.draft.count
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
                            if u.id != live.session.items.last?.id || !live.partial.isEmpty { Divider() }
                        }
                        if !live.partial.isEmpty {
                            InProgressRow(size: size, showOriginal: showOriginal)
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 130)
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

            VStack(spacing: 10) {
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
                Toggle(isOn: $speak) {
                    Label("Speak Translation", systemImage: speak ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
                .help(speak ? "Speaking the translation aloud" : "Speak the translation aloud")
                .onChange(of: speak) { _, on in live.speakingChanged(on) }

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

/// The sentence being spoken right now (last line of the transcript), with its live translation.
private struct InProgressRow: View {
    @Environment(LiveController.self) private var live
    let size: Double
    let showOriginal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showOriginal {
                Text(live.partial).font(.system(size: size * 0.6)).foregroundStyle(.secondary)
            }
            Group {
                if live.draft.isEmpty {
                    Text("…").foregroundStyle(.tertiary)
                } else {
                    Text(live.draft).foregroundStyle(.tint.opacity(0.75))
                }
            }
            .font(.system(size: size, weight: .medium))
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: live.draft)
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
                        Text("\(live.direction.label) · \(clock(live.elapsed))")
                    }
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    Text(live.direction.label).font(.subheadline).foregroundStyle(.secondary)
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
