import SwiftUI
import AppKit

/// Loads the durable failed-disc list off the `FailedDiscRegistry` actor and
/// keeps it in sync with the `.failedDiscsChanged` notification (so the view
/// updates live when a rip fails while this tab is open).
@MainActor
final class FailedDiscsViewModel: ObservableObject {
    @Published private(set) var entries: [(key: String, entry: FailedDiscEntry)] = []

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .failedDiscsChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        Task { @MainActor in
            entries = await FailedDiscRegistry.shared.all()
        }
    }

    func remove(key: String) {
        Task { await FailedDiscRegistry.shared.forget(key: key) }
    }

    func clearAll() {
        Task { await FailedDiscRegistry.shared.clear() }
    }

    func copyTitles() {
        Task {
            let text = await FailedDiscRegistry.shared.titlesText()
            await MainActor.run { Self.copyToClipboard(text) }
        }
    }

    func copyTmdbIds() {
        Task {
            let text = await FailedDiscRegistry.shared.tmdbIdsText()
            await MainActor.run { Self.copyToClipboard(text) }
        }
    }

    func revealExports() {
        Task {
            let dir = await FailedDiscRegistry.shared.exportDirectory()
            await MainActor.run {
                let csv = dir.appendingPathComponent("failed-discs.csv")
                if FileManager.default.fileExists(atPath: csv.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([csv])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        }
    }

    private static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// "Failed" tab: discs that aborted during the rip stage (disc unreadable /
/// hard read error). These never become queue jobs, so this is the only place
/// they're surfaced. Lets the user copy/export the list to find the titles
/// in Radarr/Sonarr or another source.
struct FailedDiscsView: View {
    @StateObject private var vm = FailedDiscsViewModel()
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [(key: String, entry: FailedDiscEntry)] {
        guard !search.isEmpty else { return vm.entries }
        return vm.entries.filter {
            $0.entry.displayName.localizedCaseInsensitiveContains(search)
                || $0.entry.volumeLabel.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if vm.entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered, id: \.key) { item in
                        FailedDiscRow(entry: item.entry) { vm.remove(key: item.key) }
                    }
                }
            }
        }
        .navigationTitle("Failed Discs")
        .onAppear { vm.reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Failed Discs")
                .font(.headline)
            if !vm.entries.isEmpty {
                Text("\(vm.entries.count)")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.red.opacity(0.18))
                    .clipShape(Capsule())
            }
            Spacer()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Menu("Copy") {
                Button("Titles — \"Title (Year)\"") { vm.copyTitles() }
                Button("TMDb IDs") { vm.copyTmdbIds() }
            }
            .disabled(vm.entries.isEmpty)
            .frame(width: 80)
            Button("Reveal Exports") { vm.revealExports() }
                .disabled(vm.entries.isEmpty)
            Button(role: .destructive) { confirmClear = true } label: { Text("Clear All") }
                .disabled(vm.entries.isEmpty)
                .confirmationDialog("Clear the entire failed-disc list?",
                                    isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear All", role: .destructive) { vm.clearAll() }
                    Button("Cancel", role: .cancel) {}
                }
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No failed discs")
                .font(.headline)
            Text("Discs that abort during the rip stage will be listed here,\nready to look up in Radarr/Sonarr.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedDiscRow: View {
    let entry: FailedDiscEntry
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName).font(.body).bold()
                    if let mt = entry.mediaType {
                        Text(mt == "tv" ? "TV" : "Movie")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if let id = entry.tmdbId {
                        Text("TMDb \(id)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if entry.title != nil, !entry.volumeLabel.isEmpty {
                    Text(entry.volumeLabel)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(entry.reason)
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    if entry.readErrors > 0 { Text("\(entry.readErrors) read err") }
                    if entry.corruptionEvents > 0 { Text("\(entry.corruptionEvents) corruption") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from list")
        }
        .padding(.vertical, 4)
    }
}
