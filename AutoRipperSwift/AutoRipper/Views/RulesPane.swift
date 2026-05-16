import SwiftUI

/// v3.14.0: Settings tab for managing per-disc rip rules.
///
/// **What this solves.** Users with mixed libraries need different
/// defaults per disc: TV box sets want `.episode` intent, anime BDs
/// want a custom preset, older discs want a slower drive speed. A
/// single global default can't cover everything.
///
/// **UX shape.** List of rules at the top, with an Add / Delete affordance,
/// and an inline editor below showing the fields of the selected rule.
/// Order matters — earlier rules take precedence when multiple match
/// the same disc.
struct RulesPane: View {
    @ObservedObject var config: AppConfig
    @State private var selectedRuleId: UUID?

    private var selectedRuleBinding: Binding<DiscRule>? {
        guard let id = selectedRuleId,
              let idx = config.discRules.firstIndex(where: { $0.id == id })
        else { return nil }
        return Binding(
            get: { config.discRules[idx] },
            set: { config.discRules[idx] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                rulesList
                    .frame(minWidth: 220, idealWidth: 260)
                editorPane
                    .frame(minWidth: 300)
            }
        }
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            Text("Per-disc rules")
                .font(.headline)
            Spacer()
            Button {
                let new = DiscRule()
                config.discRules.append(new)
                selectedRuleId = new.id
            } label: {
                Label("Add rule", systemImage: "plus.circle")
            }
            .controlSize(.small)
            if let id = selectedRuleId {
                Button(role: .destructive) {
                    config.discRules.removeAll { $0.id == id }
                    selectedRuleId = nil
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var rulesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if config.discRules.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "list.bullet.indent")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No rules yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Add a rule to override the default preset, intent, or drive speed for matching discs.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedRuleId) {
                    ForEach(config.discRules) { rule in
                        ruleRow(rule)
                            .tag(rule.id)
                    }
                    .onMove { from, to in
                        config.discRules.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func ruleRow(_ rule: DiscRule) -> some View {
        HStack(spacing: 6) {
            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(rule.enabled ? Color.green : Color.gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name.isEmpty ? "(unnamed)" : rule.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(ruleSummary(rule))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func ruleSummary(_ rule: DiscRule) -> String {
        var parts: [String] = []
        if !rule.nameContains.isEmpty { parts.append("name~'\(rule.nameContains)'") }
        if !rule.mediaTypeFilter.isEmpty { parts.append("type=\(rule.mediaTypeFilter)") }
        if !rule.discTypeFilter.isEmpty { parts.append("disc=\(rule.discTypeFilter)") }
        if parts.isEmpty { return "(no constraints — matches everything)" }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var editorPane: some View {
        if let binding = selectedRuleBinding {
            Form {
                Section("Identity") {
                    TextField("Rule name", text: binding.name)
                    Toggle("Enabled", isOn: binding.enabled)
                }
                Section("Match (all non-empty fields must match)") {
                    TextField("Name contains (case-insensitive)", text: binding.nameContains)
                    Picker("Media type", selection: binding.mediaTypeFilter) {
                        Text("Any").tag("")
                        Text("Movie").tag("movie")
                        Text("TV").tag("tv")
                    }
                    Picker("Disc type", selection: binding.discTypeFilter) {
                        Text("Any").tag("")
                        Text("DVD").tag("dvd")
                        Text("Blu-ray").tag("bluray")
                    }
                }
                Section("Actions (non-default fields are applied)") {
                    TextField("Preset override", text: binding.presetOverride,
                              prompt: Text("Leave empty to keep default"))
                    Picker("Intent override", selection: binding.intentOverride) {
                        Text("No override").tag("")
                        Text("Movie").tag("movie")
                        Text("Episode").tag("episode")
                        Text("Edition").tag("edition")
                        Text("Extra (skip encode)").tag("extra")
                    }
                    HStack {
                        Text("Drive speed override:")
                        Stepper(value: binding.driveSpeedOverride, in: 0...32, step: 1) {
                            Text(binding.wrappedValue.driveSpeedOverride == 0
                                 ? "No override"
                                 : "\(binding.wrappedValue.driveSpeedOverride)×")
                        }
                    }
                }
                if !binding.wrappedValue.hasAnyMatch {
                    Section {
                        Label("This rule has no match constraints — it would not apply to any disc. Add at least one match field above.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
                if !binding.wrappedValue.hasAnyAction {
                    Section {
                        Label("This rule has no actions — matching a disc would be a no-op. Set at least one action above.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("Select a rule to edit it, or click Add rule.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
