import SwiftUI

struct RipView: View {
    @ObservedObject var vm: RipViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { vm.fullAutoEnabled },
                    set: { vm.fullAutoEnabled = $0 }
                )) {
                    Label("Full Auto", systemImage: "bolt.fill")
                }
                .toggleStyle(.checkbox)
                .disabled(vm.isScanning || vm.isRipping)

                Spacer()

                Text("Min duration: \(vm.minDuration)s")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                Button { vm.ejectDisc() } label: {
                    Label("Eject", systemImage: "eject.fill")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Content
            if let info = vm.discInfo {
                VStack(spacing: 0) {
                    // Disc header
                    HStack {
                        Image(systemName: info.type == "bluray" ? "opticaldisc.fill" : "opticaldisc")
                            .foregroundStyle(.secondary)
                        if !info.mediaTitle.isEmpty {
                            Text(info.mediaTitle)
                                .font(.headline)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(info.name)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(info.name)
                                .font(.headline)
                        }
                        Text("·")
                            .foregroundStyle(.tertiary)
                        let filtered = info.titles.filter { $0.durationSeconds >= vm.minDuration }
                        Text("\(filtered.count) of \(info.titles.count) titles")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // Titles table — only show titles meeting min duration
                    let filteredTitles = info.titles.filter { $0.durationSeconds >= vm.minDuration }
                    Table(filteredTitles) {
                        TableColumn("") { title in
                            Button {
                                if vm.selectedTitles.contains(title.id) {
                                    vm.selectedTitles.remove(title.id)
                                } else {
                                    vm.selectedTitles.insert(title.id)
                                }
                            } label: {
                                Image(systemName: vm.selectedTitles.contains(title.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(vm.selectedTitles.contains(title.id) ? .accentColor : .gray)
                                    .font(.body)
                            }
                            .buttonStyle(.plain)
                        }
                        .width(28)

                        TableColumn("Type") { title in
                            if !title.label.isEmpty {
                                Text(title.label)
                                    .font(.caption)
                            }
                        }
                        .width(110)

                        TableColumn("Title") { title in
                            Text(title.name)
                                .fontWeight(title.durationSeconds >= vm.minDuration ? .medium : .regular)
                                .foregroundStyle(title.durationSeconds >= vm.minDuration ? .primary : .tertiary)
                        }

                        TableColumn("Duration") { title in
                            Text(title.duration)
                                .monospacedDigit()
                                .foregroundStyle(title.durationSeconds >= vm.minDuration ? .primary : .tertiary)
                        }
                        .width(70)

                        TableColumn("Size") { title in
                            Text(title.humanSize)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .width(80)

                        TableColumn("Res") { title in
                            if !title.resolutionLabel.isEmpty {
                                Text(title.resolutionLabel)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                        .width(60)

                        TableColumn("Ch") { title in
                            Text("\(title.chapters)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .width(30)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                }
            } else {
                Spacer()
                if vm.isScanning {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Scanning disc…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        if vm.fullAutoEnabled {
                            vm.fullAuto()
                        } else {
                            vm.scanDisc()
                        }
                    } label: {
                        VStack(spacing: 16) {
                            Image(systemName: "opticaldisc.fill")
                                .font(.system(size: 64))
                            Text(vm.fullAutoEnabled ? "Full Auto" : "Scan Disc")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .frame(width: 180, height: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Spacer()
            }

            // Progress bar
            if vm.isRipping || vm.ripProgress > 0 {
                Divider()
                VStack(spacing: 4) {
                    ProgressView(value: vm.ripProgress)
                    Text(vm.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                if let info = vm.discInfo {
                    let filtered = info.titles.filter { $0.durationSeconds >= vm.minDuration }
                    Button("Select All") {
                        vm.selectedTitles = Set(filtered.map(\.id))
                    }
                    .disabled(vm.isRipping)

                    Button("Deselect All") {
                        vm.selectedTitles = []
                    }
                    .disabled(vm.isRipping)
                }

                if !vm.isRipping {
                    Text(vm.statusText)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }

                Spacer()

                if vm.isScanning || vm.isRipping {
                    Button("Abort") { vm.abort() }
                }

                if vm.discInfo != nil {
                    Button(vm.fullAutoEnabled ? "Rip & Encode" : "Rip") {
                        vm.ripSelected()
                    }
                    .disabled(vm.selectedTitles.isEmpty || vm.isRipping || vm.isScanning)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            // Log
            DisclosureGroup("Log") {
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
                        .padding(6)
                    }
                    .frame(height: 100)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onChange(of: vm.logLines.count) {
                        if let last = vm.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}
