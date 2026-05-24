import SwiftUI

/// v4.0.15: prompts the user to apply a curated known-disc episode map
/// (e.g. the BBC slipcover Bluey BDs where on-disc title order is shuffled
/// and one title per disc is a French-only duplicate). Shown when
/// `RipViewModel.pendingKnownDiscMap != nil`. The user picks Apply (calls
/// `applyKnownDiscMap`) or Skip (calls `declineKnownDiscMap` and records
/// the decline so re-scans of the same fingerprint don't re-prompt).
///
/// Coverage summary is computed locally from the map + the current
/// `discInfo` so the user can see at a glance what will happen.
struct KnownDiscBanner: View {
    @ObservedObject var ripVM: RipViewModel
    let map: KnownDiscMap

    private var plan: KnownDiscApplyPlan? {
        guard let info = ripVM.discInfo else { return nil }
        return KnownDiscRegistry.resolve(for: info, map: map)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Known disc recognized")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(map.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let plan {
                summaryChips(for: plan)
                Text("Applies curated episode numbers and titles, fixing the shuffled on-disc order. Any titles outside the map (bonus content, menus) keep their auto-categorization.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    ripVM.applyKnownDiscMap(map)
                } label: {
                    Label("Apply map", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Skip") {
                    ripVM.declineKnownDiscMap()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func summaryChips(for plan: KnownDiscApplyPlan) -> some View {
        HStack(spacing: 6) {
            chip(label: "\(plan.assignments.count) episodes", color: .blue)
            if !plan.deselectedTitleIds.isEmpty {
                chip(label: "\(plan.deselectedTitleIds.count) skip", color: .secondary)
            }
            if !plan.unmappedTitleIds.isEmpty {
                chip(label: "\(plan.unmappedTitleIds.count) extras", color: .gray)
            }
            if !plan.missingTitleIds.isEmpty {
                chip(label: "\(plan.missingTitleIds.count) missing", color: .orange)
            }
            Spacer()
        }
    }

    private func chip(label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
