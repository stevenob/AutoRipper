import SwiftUI

/// v4.0.14: extracted from `ContentView.swift` (Phase 3a cleanup). The titles
/// table is structurally an independent concern — it reads selected titles,
/// per-title intent/edition/override state, and rip status, and renders the
/// SwiftUI `Table` plus its row cells. Splitting it lets `ContentView` focus
/// on app layout / toolbars / state machine.
///
/// All state lives on `RipViewModel` and `AppConfig`. This view is a pure
/// projection — no `@State` of its own.
struct TitlesTableView: View {
    @ObservedObject var ripVM: RipViewModel
    @ObservedObject var config: AppConfig
    let info: DiscInfo

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        let filtered = info.titles.filter { $0.durationSeconds >= config.minDuration }
        HStack(spacing: 8) {
            Text("Titles").font(.headline)
            Text("\(filtered.count) of \(info.titles.count) · \(ripVM.selectedTitles.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !ripVM.isRipping {
                Button("Select All") { ripVM.selectedTitles = Set(filtered.map(\.id)) }
                    .controlSize(.small)
                Button("Deselect All") { ripVM.selectedTitles = [] }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Table

    @ViewBuilder
    private var table: some View {
        let filteredTitles = info.titles.filter { $0.durationSeconds >= config.minDuration }
        if filteredTitles.isEmpty {
            // Filter-too-strict mini-state inside the table area.
            VStack(spacing: 8) {
                Image(systemName: "ruler").font(.title).foregroundStyle(.tertiary)
                Text("No titles match your filter").font(.caption).foregroundStyle(.secondary)
                Text("Found \(info.titles.count) titles, but none ≥ \(config.minDuration / 60) min.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button("Lower to 30 sec") { config.minDuration = 30 }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(filteredTitles) {
                TableColumn("") { title in
                    Button {
                        if ripVM.selectedTitles.contains(title.id) {
                            ripVM.selectedTitles.remove(title.id)
                        } else {
                            ripVM.selectedTitles.insert(title.id)
                        }
                    } label: {
                        Image(systemName: ripVM.selectedTitles.contains(title.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(ripVM.selectedTitles.contains(title.id) ? .accentColor : .gray)
                    }
                    .buttonStyle(.plain)
                    .disabled(ripVM.isRipping)
                    .opacity(ripVM.isRipping ? 0.4 : 1.0)
                }
                .width(28)

                TableColumn("Type") { title in
                    VStack(alignment: .leading, spacing: 1) {
                        if !title.label.isEmpty {
                            Text(title.label).font(.caption)
                        }
                        // v4.0.7: when this title has a TV episode
                        // assignment (set by TVEpisodePicker → Apply),
                        // surface SxxExx right next to the category so
                        // it's obvious which titles got mapped where.
                        if let assn = ripVM.titleEpisodeAssignments[title.id] {
                            Text(String(format: "S%02dE%02d", assn.season, assn.episode))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.purple)
                        }
                    }
                }
                .width(110)

                TableColumn("Title") { title in
                    // v4.0.7: when a TV episode assignment exists,
                    // show the SxxExx + episode title as the primary
                    // label (purple) and keep the MakeMKV title name
                    // as a secondary caption — so the user gets
                    // immediate visual confirmation that Apply took
                    // effect, without losing the disc-side metadata.
                    if let assn = ripVM.titleEpisodeAssignments[title.id], !assn.title.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(assn.title)
                                .fontWeight(.medium)
                                .foregroundStyle(.purple)
                            Text(title.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if let assn = ripVM.titleEpisodeAssignments[title.id] {
                        // Assignment exists but TMDb episode name is
                        // blank (sequential fallback). Show "Episode N"
                        // so the user still sees feedback.
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Episode \(assn.episode)")
                                .fontWeight(.medium)
                                .foregroundStyle(.purple)
                            Text(title.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(title.name).fontWeight(.medium)
                    }
                }

                TableColumn("Duration") { title in
                    Text(title.duration).monospacedDigit()
                }
                .width(70)

                TableColumn("Size") { title in
                    Text(title.humanSize).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(80)

                TableColumn("Res") { title in
                    if !title.resolutionLabel.isEmpty {
                        Text(title.resolutionLabel)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
                .width(60)

                TableColumn("Intent") { title in
                    if ripVM.isRipping {
                        ripStatusCell(for: title)
                    } else {
                        intentControls(for: title)
                    }
                }
                .width(220)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: - Row cells

    /// Per-title status row used during ripping. Reads from
    /// `ripVM.titleRipStatuses` to show queued/ripping%/done/failed glyphs.
    @ViewBuilder
    private func ripStatusCell(for title: TitleInfo) -> some View {
        let status = ripVM.titleRipStatuses[title.id]
        HStack(spacing: 6) {
            switch status {
            case .ripping(let pct):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Ripping \(pct)%").font(.caption).monospacedDigit()
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Done").font(.caption)
            case .failed(let msg):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            case .none:
                Text(ripVM.selectedTitles.contains(title.id) ? "" : "—")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func intentControls(for title: TitleInfo) -> some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { ripVM.intent(for: title.id) },
                set: { ripVM.titleIntents[title.id] = $0 }
            )) {
                Text("Movie").tag(JobIntent.movie)
                Text("Episode").tag(JobIntent.episode)
                Text("Edition").tag(JobIntent.edition)
                Text("Extra").tag(JobIntent.extra)
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small)
            .frame(width: 88)

            switch ripVM.intent(for: title.id) {
            case .edition:
                Picker("", selection: Binding(
                    get: { ripVM.editionLabel(for: title.id) },
                    set: { ripVM.titleEditionLabels[title.id] = $0 }
                )) {
                    Text("—").tag("")
                    Text("Theatrical").tag("Theatrical")
                    Text("Unrated").tag("Unrated")
                    Text("Director's Cut").tag("Director's Cut")
                    Text("Extended").tag("Extended")
                    Text("Final Cut").tag("Final Cut")
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .frame(width: 110)
            case .movie:
                TextField("Override (optional)", text: Binding(
                    get: { ripVM.nameOverride(for: title.id) },
                    set: { ripVM.titleNameOverrides[title.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .frame(width: 120)
            default: EmptyView()
            }
        }
    }
}
