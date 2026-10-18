import AppKit
import SwiftUI

/// Floating subtitles: a translucent panel above every app and on every Space, including
/// full-screen presentations and video calls. Drag it anywhere; hover for size and close.
@MainActor
final class SubtitlePanel {
    static let shared = SubtitlePanel()
    private var panel: NSPanel?

    func toggle(_ live: LiveController) {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        if panel == nil { panel = make(live) }
        panel?.orderFrontRegardless()
    }

    func close() { panel?.orderOut(nil) }

    private func make(_ live: LiveController) -> NSPanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 170),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: 360, height: 100)
        p.contentView = NSHostingView(rootView: SubtitleView().environment(live))
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - 450, y: screen.minY + 60))
        }
        p.setFrameAutosaveName("InterpretoSubtitles")
        return p
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct SubtitleView: View {
    @Environment(LiveController.self) private var live
    @AppStorage("subtitleSize") private var size = 30.0
    @AppStorage(Pref.showOriginal) private var showOriginal = true
    @State private var hovering = false

    var body: some View {
        let last = live.session.items.last
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            if showOriginal, let src = live.partial.isEmpty ? last?.source : live.partial {
                Text(src).font(.system(size: size * 0.55)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
            }
            if !live.partial.isEmpty, !live.draft.isEmpty {
                Text(live.draft).font(.system(size: size, weight: .semibold)).foregroundStyle(.mint.opacity(0.75)).lineLimit(2)
            } else {
                Text(last?.translation ?? "Waiting for speech…")
                    .font(.system(size: size, weight: .semibold)).foregroundStyle(.mint).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.black.opacity(0.72), in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                tool("textformat.size.smaller") { size = max(18, size - 3) }
                tool("textformat.size.larger") { size = min(64, size + 3) }
                tool("xmark") { SubtitlePanel.shared.close() }
            }
            .padding(10)
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .environment(\.colorScheme, .dark)
    }

    private func tool(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(.white.opacity(0.14), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
