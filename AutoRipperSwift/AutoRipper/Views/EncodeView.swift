import SwiftUI

struct EncodeView: View {
    @ObservedObject var vm: EncodeViewModel

    var body: some View {
        VStack(spacing: 16) {
            // File picker + preset
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
                    Text(file.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No file selected")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Preset:", selection: $vm.selectedPreset) {
                    ForEach(vm.presets, id: \.self) { preset in
                        Text(preset).tag(preset)
                    }
                }
                .frame(maxWidth: 300)
            }
            .padding(.horizontal)

            Divider()

            // Track selection
            if !vm.audioTracks.isEmpty || !vm.subtitleTracks.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    // Audio tracks
                    if !vm.audioTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Audio Tracks")
                                .font(.headline)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
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
                            }
                            .frame(maxHeight: 100)
                        }
                    }

                    // Subtitle tracks
                    if !vm.subtitleTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Subtitle Tracks")
                                .font(.headline)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
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
                            }
                            .frame(maxHeight: 100)
                        }
                    }
                }
                .padding(.horizontal)
            } else if vm.isScanning {
                ProgressView("Scanning tracks…")
                    .padding()
            }

            Spacer()

            // Progress
            if vm.isEncoding || vm.progress > 0 {
                VStack(spacing: 8) {
                    ProgressView(value: vm.progress)
                    Text(vm.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 40)
            }

            Spacer()

            // Actions
            HStack {
                Button("Encode") { vm.encode() }
                    .disabled(vm.inputFile == nil || vm.isEncoding)

                Button("Abort") { vm.abort() }
                    .disabled(!vm.isEncoding)

                Spacer()

                Text(vm.statusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .onAppear { vm.loadPresets() }
        .onChange(of: vm.inputFile) {
            vm.scanTracks()
        }
    }
}
