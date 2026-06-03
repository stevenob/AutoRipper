import SwiftUI
import AppKit

/// Drives the Library catalog search tab.
@MainActor
final class LibraryCatalogViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var discsOnly: Bool = true
    @Published private(set) var results: [CatalogResult] = []
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSearched: Bool = false

    private var searchTask: Task<Void, Never>?
    private var generation = 0

    /// Results after applying the discs-only filter.
    var visibleResults: [CatalogResult] {
        discsOnly ? results.filter { $0.isVideoDisc } : results
    }

    /// Total fetched records, regardless of the discs-only filter.
    var totalFetched: Int { results.count }

    func search(config: AppConfig = .shared) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        generation += 1
        let gen = generation
        searchTask?.cancel()
        searchTask = Task { await runSearch(term: term, config: config, gen: gen) }
    }

    private func runSearch(term: String, config: AppConfig, gen: Int) async {
        isSearching = true
        errorMessage = nil
        let service = LoudounCatalogService(config: config)
        do {
            let found = try await service.search(term: term, limit: 30)
            guard gen == generation else { return }
            results = found
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            results = []
            errorMessage = error.localizedDescription
        }
        // Only the most recent search owns the terminal UI state.
        guard gen == generation else { return }
        isSearching = false
        hasSearched = true
    }

    /// Pre-fill and run a search for a known title (used by "search this disc").
    func search(for title: String) {
        query = title
        search()
    }
}

/// In-app search of the configured public library catalog (TLC CARL•Connect
/// Discovery). Lets the user find a film and see whether it's on the shelf to
/// borrow and rip.
struct LibraryCatalogView: View {
    @ObservedObject var config: AppConfig
    @StateObject private var vm = LibraryCatalogViewModel()
    @State private var showSource = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the library catalog by title…", text: $vm.query)
                    .textFieldStyle(.plain)
                    .onSubmit { vm.search(config: config) }
                if !vm.query.isEmpty {
                    Button { vm.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button("Search") { vm.search(config: config) }
                    .disabled(vm.query.trimmingCharacters(in: .whitespaces).isEmpty || vm.isSearching)
                Button { showSource.toggle() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Change which library catalog is searched")
                .popover(isPresented: $showSource, arrowEdge: .bottom) {
                    sourceEditor
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Toggle("Discs only (DVD / Blu-ray)", isOn: $vm.discsOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                if vm.isSearching {
                    ProgressView().controlSize(.small)
                } else if vm.hasSearched {
                    Text("\(vm.visibleResults.count) result\(vm.visibleResults.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.errorMessage {
            centeredMessage(icon: "exclamationmark.triangle", title: "Search failed", subtitle: error)
        } else if vm.isSearching && vm.visibleResults.isEmpty {
            centeredMessage(icon: "hourglass", title: "Searching…", subtitle: nil)
        } else if !vm.hasSearched {
            centeredMessage(icon: "books.vertical",
                            title: "Search your library catalog",
                            subtitle: "Find a film and see whether it's on the shelf to borrow and rip.")
        } else if vm.visibleResults.isEmpty {
            if vm.discsOnly && vm.totalFetched > 0 {
                VStack(spacing: 10) {
                    Image(systemName: "opticaldiscdrive").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No discs found").font(.headline).foregroundStyle(.secondary)
                    Text("\(vm.totalFetched) other record\(vm.totalFetched == 1 ? "" : "s") matched (eBooks, print, etc.).")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Button("Show all results") { vm.discsOnly = false }
                }
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                centeredMessage(icon: "magnifyingglass",
                                title: "No results",
                                subtitle: "No catalog records matched your search.")
            }
        } else {
            List(vm.visibleResults) { result in
                CatalogRow(result: result)
                    .listRowSeparator(.visible)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func centeredMessage(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library catalog URL").font(.caption).fontWeight(.semibold)
            TextField("https://catalog.example.gov", text: $config.libraryCatalogBaseURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            Text("Only works with libraries running the TLC CARL•Connect Discovery catalog platform.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
        }
        .padding(12)
    }
}

/// One catalog result row: title, format, and availability.
private struct CatalogRow: View {
    let result: CatalogResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            formatBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(result.displayTitle)
                    .font(.body).fontWeight(.medium)
                    .lineLimit(2)
                if !result.author.isEmpty {
                    Text(result.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                availabilityLine
            }
            Spacer()
            if let url = result.detailURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open this record on the library website")
            }
        }
        .padding(.vertical, 4)
    }

    private var formatBadge: some View {
        Text(result.format.isEmpty ? "—" : result.format)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(result.isVideoDisc ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(width: 64, alignment: .center)
    }

    @ViewBuilder
    private var availabilityLine: some View {
        if result.copyCount == 0 {
            Label("No physical copies", systemImage: "circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if result.availableCount > 0 {
            let branches = result.availableBranches
            let branchText = branches.count <= 2
                ? branches.joined(separator: ", ")
                : "\(branches.prefix(2).joined(separator: ", ")) +\(branches.count - 2) more"
            Label("\(result.availableCount) of \(result.copyCount) on shelf — \(branchText)",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("All \(result.copyCount) copies checked out", systemImage: "clock")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
