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
    }
}
