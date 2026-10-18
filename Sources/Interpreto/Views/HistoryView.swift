import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @State private var selection: Session.ID?

    private var selected: Session? { history.sessions.first { $0.id == selection } ?? history.sessions.first }

    var body: some View {
        if history.sessions.isEmpty {
            ContentUnavailableView("No Sessions Yet", systemImage: "clock",
                                   description: Text("Everything you translate live is kept here."))
        } else {
            HSplitView {
                List(selection: $selection) {
                    ForEach(history.sessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.started.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(s.direction.label) · \(s.items.count) sentence\(s.items.count == 1 ? "" : "s")")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(s.items.first?.source ?? "").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .tag(s.id)
                        .contextMenu { actions(s) }
                    }
                }
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)

                if let s = selected {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(s.items) { u in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(u.source).foregroundStyle(.secondary)
                                    Text(u.translation).font(.title3.weight(.medium))
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .padding(28)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(minWidth: 360)
                    .background(Color(nsColor: .textBackgroundColor))
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Menu { actions(s, deleting: false) } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) { delete(s) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ s: Session, deleting: Bool = true) -> some View {
        ForEach(ExportFormat.allCases) { f in
            Button("Export as \(f.title)…") { Exporter.export(s, as: f) }
        }
        if deleting {
            Divider()
            Button("Move to Trash", role: .destructive) { delete(s) }
        }
    }

    private func delete(_ s: Session) {
        history.delete(s)
        if selection == s.id { selection = nil }
    }
}
