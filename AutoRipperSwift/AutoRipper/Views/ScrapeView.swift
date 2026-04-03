import SwiftUI

struct ScrapeView: View {
    @ObservedObject var vm: ScrapeViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Form
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Disc Name:")
                            .frame(width: 80, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("e.g. THE_MATRIX", text: $vm.discName)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Dest Dir:")
                            .frame(width: 80, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("/path/to/output", text: $vm.destDir)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                vm.destDir = url.path
                            }
                        }
                    }

                    HStack {
                        Spacer()
                            .frame(width: 80)
                        Button { vm.scrape() } label: {
                            Label("Scrape", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.discName.isEmpty || vm.destDir.isEmpty || vm.isScraping)

                        if vm.isScraping {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .padding(4)
            } label: {
                Label("TMDb Scrape", systemImage: "magnifyingglass")
            }
            .padding(16)

            Divider()

            // Log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: vm.logLines.count) {
                    if let last = vm.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}
