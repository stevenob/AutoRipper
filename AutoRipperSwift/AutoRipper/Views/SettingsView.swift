import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Output Directory:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.outputDir)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse…") { browseFolder(binding: $vm.outputDir) }
                            }
                            HStack {
                                Text("TMDb API Key:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.tmdbApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("MakeMKV Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.makemkvPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("HandBrake CLI Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.handbrakePath)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("Discord Webhook:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.discordWebhook)
                                    .textFieldStyle(.roundedBorder)
                                Button("Test") { vm.testDiscord() }
                                    .disabled(vm.discordWebhook.isEmpty)
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Application", systemImage: "app.badge")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Enable NAS Upload", isOn: $vm.nasUploadEnabled)

                            HStack {
                                Text("Movies Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.nasMoviesPath)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(!vm.nasUploadEnabled)
                                Button("Browse…") { browseFolder(binding: $vm.nasMoviesPath) }
                                    .disabled(!vm.nasUploadEnabled)
                            }
                            HStack {
                                Text("TV Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.nasTvPath)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(!vm.nasUploadEnabled)
                                Button("Browse…") { browseFolder(binding: $vm.nasTvPath) }
                                    .disabled(!vm.nasUploadEnabled)
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("NAS Upload", systemImage: "externaldrive.connected.to.line.below")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Min Duration (sec):")
                                    .frame(width: 140, alignment: .trailing)
                                Stepper(value: $vm.minDuration, in: 0...7200, step: 30) {
                                    TextField("", value: $vm.minDuration, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                                Spacer()
                            }

                            HStack {
                                Text("")
                                    .frame(width: 140)
                                Toggle("Auto-Eject After Rip", isOn: $vm.autoEject)
                                Spacer()
                            }

                            HStack {
                                Text("Default Preset:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $vm.defaultPreset)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                Text("Media Type:")
                                    .frame(width: 140, alignment: .trailing)
                                Picker("", selection: $vm.defaultMediaType) {
                                    Text("Movie").tag("movie")
                                    Text("TV Show").tag("tvshow")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 200)
                                Spacer()
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Preferences", systemImage: "slider.horizontal.3")
                    }
                }
                .padding(16)
            }

            // Footer
            HStack {
                Button("Save Settings") { vm.save(quiet: false) }
                    .keyboardShortcut("s", modifiers: .command)

                if !vm.statusText.isEmpty {
                    Text(vm.statusText)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .transition(.opacity)
                }

                Spacer()

                Text("Settings auto-save on change")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func browseFolder(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}
