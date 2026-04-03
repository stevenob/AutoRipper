import SwiftUI

struct QueueView: View {
    @ObservedObject var vm: QueueViewModel

    var body: some View {
        VStack(spacing: 12) {
            if vm.jobs.isEmpty {
                Spacer()
                Text("No jobs in queue")
                    .foregroundStyle(.secondary)
                Text("Ripped files will appear here for post-processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(vm.jobs) {
                    TableColumn("") { job in
                        statusIcon(for: job.status)
                    }
                    .width(24)

                    TableColumn("Title") { job in
                        Text(job.discName)
                    }

                    TableColumn("Step") { job in
                        Text(job.progressText)
                            .foregroundStyle(.secondary)
                    }
                    .width(200)

                    TableColumn("Progress") { job in
                        if job.status == .done || job.status == .failed {
                            Text(job.status == .done ? "100%" : "—")
                        } else {
                            Text("\(job.progress)%")
                        }
                    }
                    .width(60)
                }
            }

            Divider()

            HStack {
                Button("Abort Current") { vm.abortCurrent() }
                    .disabled(vm.jobs.allSatisfy { $0.status == .done || $0.status == .failed || $0.status == .queued })

                Spacer()

                Text(vm.statusLabel)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusIcon(for status: JobStatus) -> some View {
        switch status {
        case .queued:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .encoding:
            Image(systemName: "film")
                .foregroundColor(.blue)
        case .organizing:
            Image(systemName: "folder")
                .foregroundColor(.orange)
        case .scraping:
            Image(systemName: "photo")
                .foregroundColor(.purple)
        case .uploading:
            Image(systemName: "icloud.and.arrow.up")
                .foregroundColor(.cyan)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}
