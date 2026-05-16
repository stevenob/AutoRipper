import SwiftUI

/// v3.11.16: standalone cleaning-guide pane. Shows concrete step-by-step
/// instructions for cleaning a disc (when corruption events suggest
/// disc damage) and the drive lens (when read errors / offset clustering
/// suggest a drive issue).
///
/// Separated from the Drive Health and Disc Health views so the user
/// can read the steps once, dismiss the modal, and come back to them
/// from a known place when they need to clean another disc. Linked
/// from the scan-time health banner and the Drive Health pane via
/// soft-tone hints rather than aggressive modals.
struct CleaningGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                discCleaningSection
                Divider()
                lensCleaningSection
                Divider()
                whenToReplaceSection
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Cleaning guide")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            Text("Most read errors and content-corruption events come down to a dirty or damaged disc, or — more rarely — a smudged drive lens. These are the steps the community has converged on; do them in order, gentlest first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var discCleaningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "opticaldisc")
                    .foregroundStyle(.orange)
                Text("Cleaning the disc")
                    .font(.headline)
            }
            Text("Reach for this first when corruption events fire on a single disc — bit-rot, smudges, and fingerprints are by far the most common cause.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            stepRow(n: 1, "Inspect the data side under a bright light. Look for visible smudges, fingerprints, hairline scratches, or hazy patches.")
            stepRow(n: 2, "Use a clean microfiber cloth (the same kind you'd use on a camera lens). Cotton, paper towels, or shirts will scratch.")
            stepRow(n: 3, "Add a couple of drops of 70%+ isopropyl alcohol to the cloth — not the disc directly. Distilled water works in a pinch if you don't have IPA.")
            stepRow(n: 4, "Wipe **radially** — from the center hole straight outward to the edge. Do NOT wipe in circles; circular scratches break error correction in a way the drive can't recover from.")
            stepRow(n: 5, "Let the disc air-dry for 30 seconds, then re-insert and try the rip again.")
            calloutRow(
                icon: "lightbulb.fill",
                color: .yellow,
                text: "For deep scratches that survive cleaning, a drop of car polish (very mild, non-abrasive) or a commercial disc-repair kit can rebuild the protective layer enough for the drive to read past the damage."
            )
        }
    }

    @ViewBuilder
    private var lensCleaningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "circle.grid.cross.fill")
                    .foregroundStyle(.purple)
                Text("Cleaning the drive lens")
                    .font(.headline)
            }
            Text("Reach for this when read errors fire on multiple different discs — especially if AutoRipper's offset-cluster finding is suggesting a drive issue. Dust and condensation accumulate on the laser lens over months of use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            stepRow(n: 1, "Buy a CD/DVD/BD lens-cleaning disc (about $10 on Amazon). They have a tiny brush on the bottom that sweeps the lens as the disc spins.")
            stepRow(n: 2, "Insert the cleaning disc and let it run its program (usually 30–60 seconds).")
            stepRow(n: 3, "Eject the cleaning disc, then re-rip a problem disc. Read errors usually drop noticeably if the lens was the issue.")
            calloutRow(
                icon: "exclamationmark.shield",
                color: .red,
                text: "Don't open the drive to manually swab the lens unless you're comfortable losing the warranty. The optical pickup head is delicate and easy to misalign."
            )
        }
    }

    @ViewBuilder
    private var whenToReplaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.green)
                Text("When to replace the drive (or disc)")
                    .font(.headline)
            }
            Text("If both cleaning steps fail and errors persist:")
                .font(.callout)
                .foregroundStyle(.secondary)
            stepRow(n: 1, "**Replace the disc** if the problem follows a single disc to a different drive (or a friend's player). Bit-rot is rare on first-print pressings but very real on home-burned DVDs and discs older than ~15 years.")
            stepRow(n: 2, "**Replace the drive** if AutoRipper's Drive Health shows the cluster finding — errors across multiple different discs at similar byte offsets — or if the verdict has been `driveSuspect` for more than a few rips. New drives are commodity ($90–150 for a quality Blu-ray drive).")
            stepRow(n: 3, "**Try a different drive brand** as the last resort. Some media authoring quirks affect specific drive firmware. The community favorites are LG (WH16NS60), Pioneer (BDR-XS07), and ASUS (BW-16D1HT).")
        }
    }

    private func stepRow(n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).")
                .font(.callout)
                .fontWeight(.semibold)
                .frame(width: 18, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func calloutRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
