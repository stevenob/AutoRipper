import SwiftUI

struct EncodeView: View {
    @ObservedObject var vm: EncodeViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Input file section
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button("Choose File…") {
                                    let panel = NSOpenPanel()
                                    panel.allowedContentTypes = [.movie, .mpeg4Movie, .avi]
                                    panel.allowsMultipleSelection = false
                                    if panel.runModal() == .OK {
                                        vm.inputFile = panel.url
                                    }
                                }

                                if let file = vm.inputFile {
                                    Image(systemName: "doc.fill")
                                        .foregroundStyle(.secondary)
                                    Text(file.lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text("No file selected")
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()
                            }

                            Divider()

                            HStack {
                                Text("Preset:")
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $vm.selectedPreset) {
                                    ForEach(vm.presets, id: \.self) { preset in
                                        Text(preset).tag(preset)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 350)
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Input", systemImage: "film")
                    }
                    .padding(.horizontal, 16)

                    // Track selection
                    if !vm.audioTracks.isEmpty || !vm.subtitleTracks.isEmpty {
                        HStack(alignment: .top, spacing: 16) {
                            if !vm.audioTracks.isEmpty {
                                GroupBox {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(vm.audioTracks) { track in
                                            Toggle(isOn: Binding(
                                                get: { vm.selectedAudioTracks.contains(track.index) },
                                                set: { selected in
                                                    if selected {
                                                        vm.selectedAudioTracks.insert(track.index)
                                                    } else {
                                                        vm.selectedAudioTracks.remove(track.index)
                                                    }
                                                }
                                            )) {
                                                Text("\(track.index): \(track.description)")
                                                    .font(.caption)
                                            }
                                            .toggleStyle(.checkbox)
                                        }
                                    }
                                    .padding(2)
                                } label: {
                                    Label("Audio Tracks", systemImage: "speaker.wave.2")
                                }
                            }

                            if !vm.subtitleTracks.isEmpty {
                                GroupBox {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(vm.subtitleTracks) { track in
                                            Toggle(isOn: Binding(
                                                get: { vm.selectedSubtitleTracks.contains(track.index) },
                                                set: { selected in
                                                    if selected {
                                                        vm.selectedSubtitleTracks.insert(track.index)
                                                    } else {
                                                        vm.selectedSubtitleTracks.remove(track.index)
                                                    }
                                                }
                                            )) {
                                                Text("\(track.index): \(track.language) (\(track.type))")
                                                    .font(.caption)
                                            }
                                            .toggleStyle(.checkbox)
                                        }
                                    }
                                    .padding(2)
                                } label: {
                                    Label("Subtitle Tracks", systemImage: "captions.bubble")
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    } else if vm.isScanning {
                        ProgressView("Scanning tracks…")
                            .padding()
                    }

                    // Progress
                    if vm.isEncoding || vm.progress > 0 {
                        GroupBox {
                            VStack(spacing: 6) {
                                ProgressView(value: vm.progress)
                                Text(vm.progressText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(4)
                        } label: {
                            Label("Progress", systemImage: "gauge.medium")
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                Button("Encode") { vm.encode() }
                    .disabled(vm.inputFile == nil || vm.isEncoding)
                    .buttonStyle(.borderedProminent)

                Button("Abort") { vm.abort() }
                    .disabled(!vm.isEncoding)

                Spacer()

                Text(vm.statusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear { vm.loadPresets() }
        .onChange(of: vm.inputFile) {
            vm.scanTracks()
        }
    }
}
