import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    // Application
                    Section("Application") {
                        HStack {
                            TextField("Output Directory:", text: $vm.outputDir)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse…") { browseFolder(binding: $vm.outputDir) }
                        }

                        TextField("TMDb API Key:", text: $vm.tmdbApiKey)
                            .textFieldStyle(.roundedBorder)

                        TextField("MakeMKV Path:", text: $vm.makemkvPath)
                            .textFieldStyle(.roundedBorder)

                        TextField("HandBrake CLI Path:", text: $vm.handbrakePath)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            TextField("Discord Webhook:", text: $vm.discordWebhook)
                                .textFieldStyle(.roundedBorder)
                            Button("Test") { vm.testDiscord() }
                                .disabled(vm.discordWebhook.isEmpty)
                        }
                    }

                    // NAS Upload
                    Section("NAS Upload") {
                        Toggle("Enable NAS Upload", isOn: $vm.nasUploadEnabled)

                        HStack {
                            TextField("Movies Path:", text: $vm.nasMoviesPath)
                                .textFieldStyle(.roundedBorder)
                                .disabled(!vm.nasUploadEnabled)
                            Button("Browse…") { browseFolder(binding: $vm.nasMoviesPath) }
                                .disabled(!vm.nasUploadEnabled)
                        }

                        HStack {
                            TextField("TV Path:", text: $vm.nasTvPath)
                                .textFieldStyle(.roundedBorder)
                                .disabled(!vm.nasUploadEnabled)
                            Button("Browse…") { browseFolder(binding: $vm.nasTvPath) }
                                .disabled(!vm.nasUploadEnabled)
                        }
                    }

                    // Preferences
                    Section("Preferences") {
                        HStack {
                            Text("Min Duration (seconds):")
                            TextField("", value: $vm.minDuration, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }

                        Toggle("Auto-Eject After Rip", isOn: $vm.autoEject)

                        TextField("Default Preset:", text: $vm.defaultPreset)
                            .textFieldStyle(.roundedBorder)

                        Picker("Default Media Type:", selection: $vm.defaultMediaType) {
                            Text("Movie").tag("movie")
                            Text("TV Show").tag("tvshow")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                    }
                }
                .formStyle(.grouped)
                .padding()
            }

            // Footer
            HStack {
                Button("Save Settings") { vm.save() }
                    .keyboardShortcut("s", modifiers: .command)

                if !vm.statusText.isEmpty {
                    Text(vm.statusText)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
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
