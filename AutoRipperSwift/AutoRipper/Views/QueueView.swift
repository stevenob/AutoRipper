import SwiftUI

struct QueueView: View {
    @ObservedObject var vm: QueueViewModel
    @State private var selectedJobId: String?

    private var selectedJob: Job? {
        guard let id = selectedJobId else { return nil }
        return vm.jobs.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.jobs.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.quaternary)
                    Text("No jobs in queue")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Ripped files will appear here for encoding, organizing, and scraping.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                Table(vm.jobs, selection: $selectedJobId) {
                    TableColumn("") { job in
                        statusIcon(for: job.status)
                    }
                    .width(24)

                    TableColumn("Title") { job in
                        Text(job.discName)
                            .fontWeight(.medium)
                    }

                    TableColumn("Step") { job in
                        Text(job.progressText)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .width(220)

                    TableColumn("Progress") { job in
                        if job.status == .done {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if job.status == .failed {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        } else if job.status == .queued {
                            Text("Waiting")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView(value: Double(job.progress) / 100.0)
                                    .frame(width: 60)
                                Text("\(job.progress)%")
                                    .monospacedDigit()
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))

                // Detail panel
                if let job = selectedJob {
                    Divider()
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            detailRow("Title:", job.discName)
                            detailRow("Status:", job.status.rawValue.capitalized)
                            detailRow("Step:", job.progressText)
                            detailRow("Ripped File:", job.rippedFile.path)
                            if let encoded = job.encodedFile {
                                detailRow("Encoded File:", encoded.path)
                            }
                            if let organized = job.organizedFile {
                                detailRow("Organized File:", organized.path)
                            }
                            if !job.error.isEmpty {
                                detailRow("Error:", job.error)
                            }
                            if job.ripElapsed > 0 {
                                let mins = Int(job.ripElapsed) / 60
                                let secs = Int(job.ripElapsed) % 60
                                detailRow("Rip Time:", "\(mins)m \(secs)s")
                            }
                        }
                        .padding(4)
                        .font(.caption)
                    } label: {
                        Label("Job Details", systemImage: "info.circle")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                Text(vm.statusLabel)
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Spacer()

                if vm.jobs.contains(where: { $0.status != .done && $0.status != .failed && $0.status != .queued }) {
                    Button("Abort Current") { vm.abortCurrent() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
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
                .symbolEffect(.pulse)
        case .organizing:
            Image(systemName: "folder")
                .foregroundColor(.orange)
                .symbolEffect(.pulse)
        case .scraping:
            Image(systemName: "photo")
                .foregroundColor(.purple)
                .symbolEffect(.pulse)
        case .uploading:
            Image(systemName: "icloud.and.arrow.up")
                .foregroundColor(.cyan)
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}
