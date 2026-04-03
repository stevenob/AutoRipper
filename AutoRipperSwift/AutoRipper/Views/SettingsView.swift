import SwiftUI
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "settings")

struct SettingsView: View {
    @ObservedObject var config: AppConfig
    @State private var statusText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Output Directory:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.outputDir)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse…") { browseFolder(binding: $config.outputDir) }
                            }
                            HStack {
                                Text("TMDb API Key:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.tmdbApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("MakeMKV Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.makemkvPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("HandBrake CLI Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.handbrakePath)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("Discord Webhook:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.discordWebhook)
                                    .textFieldStyle(.roundedBorder)
                                Button("Test") { testDiscord() }
                                    .disabled(config.discordWebhook.isEmpty)
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Application", systemImage: "app.badge")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Enable NAS Upload", isOn: $config.nasUploadEnabled)

                            HStack {
                                Text("Movies Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.nasMoviesPath)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(!config.nasUploadEnabled)
                                Button("Browse…") { browseFolder(binding: $config.nasMoviesPath) }
                                    .disabled(!config.nasUploadEnabled)
                            }
                            HStack {
                                Text("TV Path:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.nasTvPath)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(!config.nasUploadEnabled)
                                Button("Browse…") { browseFolder(binding: $config.nasTvPath) }
                                    .disabled(!config.nasUploadEnabled)
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
                                Stepper(value: $config.minDuration, in: 0...7200, step: 30) {
                                    TextField("", value: $config.minDuration, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                                Spacer()
                            }

                            HStack {
                                Text("")
                                    .frame(width: 140)
                                Toggle("Auto-Eject After Rip", isOn: $config.autoEject)
                                Spacer()
                            }

                            HStack {
                                Text("Default Preset:")
                                    .frame(width: 140, alignment: .trailing)
                                TextField("", text: $config.defaultPreset)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                Text("Media Type:")
                                    .frame(width: 140, alignment: .trailing)
                                Picker("", selection: $config.defaultMediaType) {
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
                if !statusText.isEmpty {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Spacer()

                Text("All changes save instantly")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func testDiscord() {
        Task {
            let discord = DiscordService(config: config)
            let card = JobCard(discName: "Test Disc", nasEnabled: false, discord: discord)
            await card.start("rip")
            await card.finish("rip", detail: "0m 1s")
            await card.complete(footer: "This is a test notification")
            statusText = "Test notification sent ✓"
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
