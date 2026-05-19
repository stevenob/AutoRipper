import SwiftUI

/// v4.0.14: extracted from `DiscInfoColumn.swift` (Phase 3b cleanup).
/// The disc-tab banner family — scan health, read errors, already-ripped,
/// TMDb runtime mismatch — lives here as a set of small, focused views.
///
/// Each banner is a leaf View struct that observes `RipViewModel` (and
/// `AppConfig` when needed). Mutations route through the same vm methods
/// that the original DiscInfoColumn-private banners used.
///
/// Phase 4 (Mockup C "findings drawer") will consume these as the
/// expandable banner family.

// MARK: - Scan health (v3.11.15)

/// Surfaced when MakeMKV's scan phase reported read errors or corruption
/// events. Pre-rip equivalent of the during-rip pills inside `rippingHeroBlock`.
/// Gives the user a chance to clean the disc or abort BEFORE committing to a
/// long rip that will likely fail the same way.
struct DiscScanHealthBanner: View {
    @ObservedObject var ripVM: RipViewModel
    let onShowCleaningGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.orange)
                Text("Scan reported disc issues")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            HStack(spacing: 10) {
                if ripVM.readErrorCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("\(ripVM.readErrorCount) read \(ripVM.readErrorCount == 1 ? "error" : "errors")")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
                }
                if ripVM.corruptionEventCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.caption2)
                        Text("\(ripVM.corruptionEventCount) corrupt")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .clipShape(Capsule())
                }
                Spacer()
            }
            Text("MakeMKV hit these problems while reading the disc structure. The rip itself is likely to compound them — consider cleaning the disc (radial wipe with isopropyl) and rescanning before committing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onShowCleaningGuide) {
                Label("Show cleaning steps", systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Read errors (v3.11.5)

/// Surfaced once read errors cross the threshold during a rip. Suggests a
/// slower drive speed — usually helps with scratched/smudged/warped discs.
/// Lingers post-rip until next scan so the user has time to act.
struct DiscReadErrorBanner: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject var config: AppConfig

    var body: some View {
        let current = config.makemkvReadSpeed
        // Step the suggested speed down: from 0/auto or 8+ → 4 (Quiet).
        // If already at 4, suggest 2 (very slow but max-careful) as the
        // last-ditch retry option.
        let suggested = (current == 0 || current >= 8) ? 4 : (current == 4 ? 2 : max(current / 2, 2))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .foregroundStyle(.orange)
                Text("Read errors detected")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("Dismiss") { ripVM.suggestLowerDriveSpeed = false }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Text("\(ripVM.readErrorCount) read \(ripVM.readErrorCount == 1 ? "error" : "errors") so far. A slower drive speed often helps with scratched, smudged, or warped discs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    config.makemkvReadSpeed = suggested
                    ripVM.suggestLowerDriveSpeed = false
                } label: {
                    Label("Set drive to \(suggested)× and try again next rip", systemImage: "tortoise.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("Currently: \(current == 0 ? "Auto" : "\(current)×")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }
}

// MARK: - Already-ripped (v3.7.1)

/// Surfaced when the inserted disc's fingerprint matches a previously
/// published rip. Lets the user dismiss (re-rip, overwriting) or back
/// off and skip the duplicate work.
struct DiscAlreadyRippedBanner: View {
    @ObservedObject var ripVM: RipViewModel
    let prior: RippedDiscEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Already ripped")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("Dismiss") { ripVM.previousRipMatch = nil }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Text("This disc was published \(prior.date, formatter: Self.relativeDateFormatter) (\(prior.discName))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !prior.publishedPath.isEmpty {
                Text(prior.publishedPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Re-ripping will overwrite the existing same-name file in the library.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

// MARK: - Main feature / TMDb runtime mismatch (v4.0.6)

/// Surfaced when the size-based main-feature pick is far from TMDb's
/// known movie runtime. The user can:
///   * Click "Use closer match" to swap categories (picked →
///     .alternateCut, suggested → .mainFeature)
///   * Click "Keep" to dismiss (Extended-Edition cases where the
///     longer cut on the disc IS the main feature)
struct DiscMainFeatureMismatchBanner: View {
    @ObservedObject var ripVM: RipViewModel
    let mismatch: MainFeatureMismatch

    var body: some View {
        let pickedMin = mismatch.pickedRuntimeSeconds / 60
        let suggestedMin = mismatch.suggestedRuntimeSeconds / 60
        let tmdbMin = mismatch.tmdbRuntimeSeconds / 60
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.blue)
                Text("TMDb runtime mismatch")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("Keep") { ripVM.dismissMainFeatureMismatch() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Text("Main feature picked is \(pickedMin) min, but TMDb says this movie is \(tmdbMin) min. A \(suggestedMin)-min title on this disc is closer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Use \(suggestedMin)-min title as main") {
                    ripVM.acceptMainFeatureMismatchSuggestion()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            Text("Tip: dismiss if this is an Extended / Director's / Unrated Edition disc — TMDb only knows the theatrical runtime.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.blue.opacity(0.30), lineWidth: 1)
        )
    }
}
