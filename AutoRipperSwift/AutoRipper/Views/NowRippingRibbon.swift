import SwiftUI

/// Apple-Music-style persistent ribbon that surfaces an active rip or encode
/// regardless of which sidebar tab the user is on. Click to jump to the most
/// relevant tab (Disc while ripping, Queue while encoding).
struct NowRippingRibbon: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject var queueVM: QueueViewModel
    @Binding var selectedTab: AppTab

    private var activeJob: Job? {
        queueVM.activeJobs.first {
            $0.status == .encoding || $0.status == .organizing
                || $0.status == .scraping || $0.status == .uploading
        }
    }

    var body: some View {
        if ripVM.isRipping {
            ribbonContent(
                title: ripVM.cachedMediaResult?.displayTitle ?? ripVM.detectedDiscName,
                subtitle: ripVM.statusText,
                progress: ripVM.ripProgress,
                posterPath: ripVM.cachedMediaResult?.posterPath,
                target: .disc
            )
        } else if let job = activeJob {
            ribbonContent(
                title: job.mediaResult?.displayTitle ?? job.discName,
                subtitle: job.progressText,
                progress: Double(job.progress) / 100.0,
                posterPath: job.mediaResult?.posterPath,
                target: .queue
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func ribbonContent(title: String, subtitle: String, progress: Double, posterPath: String?, target: AppTab) -> some View {
        Button {
            selectedTab = target
        } label: {
            HStack(spacing: 10) {
                poster(posterPath: posterPath)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? "Working…" : title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: max(0, min(progress, 1)))
                        .progressViewStyle(.linear)
                        .frame(height: 3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(.bar)
    }

    @ViewBuilder
    private func poster(posterPath: String?) -> some View {
        Group {
            if let path = posterPath,
               let url = URL(string: "https://image.tmdb.org/t/p/w92\(path)") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(2/3, contentMode: .fill)
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 24, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.25)
            Image(systemName: "film").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
