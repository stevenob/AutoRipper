import SwiftUI

struct ScrapeView: View {
    @ObservedObject var vm: ScrapeViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Inputs
            HStack {
                Text("Disc Name:")
                TextField("e.g. THE_MATRIX", text: $vm.discName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            HStack {
                Text("Dest Dir:")
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
            .padding(.horizontal)

            HStack {
                Button("Scrape") { vm.scrape() }
                    .disabled(vm.discName.isEmpty || vm.destDir.isEmpty || vm.isScraping)

                if vm.isScraping {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }
            .padding(.horizontal)

            Divider()

            // Log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onChange(of: vm.logLines.count) {
                    if let last = vm.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}
