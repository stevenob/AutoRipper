import SwiftUI

struct RipView: View {
    @ObservedObject var vm: RipViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Toolbar
            HStack {
                Button { vm.scanDisc() } label: {
                    Label("Scan Disc", systemImage: "opticaldisc")
                }
                .disabled(vm.isScanning || vm.isRipping)

                Button { vm.fullAuto() } label: {
                    Label("Full Auto", systemImage: "bolt.fill")
                }
                .disabled(vm.isScanning || vm.isRipping)

                Button { vm.ejectDisc() } label: {
                    Label("Eject", systemImage: "eject.fill")
                }

                Spacer()

                Text("Min duration: \(vm.minDuration)s")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal)

            Divider()

            // Titles table
            if let info = vm.discInfo {
                Text(info.name)
                    .font(.headline)

                Table(info.titles, selection: $vm.selectedTitles) {
                    TableColumn("") { title in
                        Image(systemName: vm.selectedTitles.contains(title.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(vm.selectedTitles.contains(title.id) ? .accentColor : .secondary)
                    }
                    .width(24)

                    TableColumn("ID") { title in
                        Text("\(title.id)")
                    }
                    .width(30)

                    TableColumn("Name") { title in
                        Text(title.name)
                    }

                    TableColumn("Duration") { title in
                        Text(title.duration)
                    }
                    .width(70)

                    TableColumn("Size") { title in
                        Text(title.humanSize)
                    }
                    .width(70)

                    TableColumn("Res") { title in
                        Text(title.resolutionLabel)
                    }
                    .width(50)

                    TableColumn("Ch") { title in
                        Text("\(title.chapters)")
                    }
                    .width(30)
                }
            } else {
                Spacer()
                if vm.isScanning {
                    ProgressView("Scanning…")
                } else {
                    Text("Insert a disc and click Scan")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Progress
            if vm.isRipping || vm.ripProgress > 0 {
                ProgressView(value: vm.ripProgress)
                    .padding(.horizontal)
            }

            // Actions + status
            HStack {
                Button("Rip Selected") { vm.ripSelected() }
                    .disabled(vm.selectedTitles.isEmpty || vm.isRipping || vm.isScanning)

                Button("Abort") { vm.abort() }
                    .disabled(!vm.isScanning && !vm.isRipping)

                Spacer()

                Text(vm.statusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal)

            // Log area
            DisclosureGroup("Log") {
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
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onChange(of: vm.logLines.count) {
                        if let last = vm.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}
