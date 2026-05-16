import Foundation

/// v3.14.0: user-defined rules that override the default scan/rip
/// behavior for matching discs.
///
/// **What this solves.** Users with a varied library hit pain points
/// that a single global default can't handle:
///   * A box of TV-on-DVD discs that all want `.episode` intent
///   * Anime BDs that want a different preset than live-action
///   * Specific older discs that want a slower (more careful) rip
///
/// **Design.** A rule is a list of optional match conditions ANDed
/// together + a list of optional actions. Empty / default-valued
/// fields don't participate (in either matching or action). The first
/// enabled rule that matches wins — earlier rules take precedence so
/// the user can put more-specific rules above more-general ones.
///
/// Stored as JSON on `AppConfig.discRules`. Applied by `RipViewModel`
/// right after a successful scan, before the duplicate-rip banner is
/// computed (so rule-driven preset / intent changes show in the UI
/// from the first frame).
struct DiscRule: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var enabled: Bool
    // MARK: Match conditions (all non-empty fields must match)
    /// Case-insensitive substring match against the disc name OR the
    /// TMDb-resolved media title. Empty = no constraint.
    var nameContains: String
    /// Filter by media type. "movie" / "tv" / "" (= no constraint).
    var mediaTypeFilter: String
    /// Filter by disc type. "dvd" / "bluray" / "" (= no constraint).
    var discTypeFilter: String
    // MARK: Actions (applied in order, empty = no-op)
    /// HandBrake preset name to use instead of `config.defaultPreset`.
    /// Empty = leave preset alone.
    var presetOverride: String
    /// Override intent for all selected titles. "" / "movie" / "episode"
    /// / "edition" / "extra".
    var intentOverride: String
    /// MakeMKV drive read speed override (4 = Quiet, 8 = balanced, etc.)
    /// 0 = no override (leave at app default).
    var driveSpeedOverride: Int

    init(id: UUID = UUID(),
         name: String = "New rule",
         enabled: Bool = true,
         nameContains: String = "",
         mediaTypeFilter: String = "",
         discTypeFilter: String = "",
         presetOverride: String = "",
         intentOverride: String = "",
         driveSpeedOverride: Int = 0) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.nameContains = nameContains
        self.mediaTypeFilter = mediaTypeFilter
        self.discTypeFilter = discTypeFilter
        self.presetOverride = presetOverride
        self.intentOverride = intentOverride
        self.driveSpeedOverride = driveSpeedOverride
    }

    /// True when this rule defines at least one match constraint.
    /// A rule with NO constraints would match every disc — almost
    /// certainly user error — so callers can use this to validate
    /// before applying.
    var hasAnyMatch: Bool {
        !nameContains.isEmpty || !mediaTypeFilter.isEmpty || !discTypeFilter.isEmpty
    }

    /// True when this rule defines at least one action. Without any
    /// action a matching rule is a no-op — also probably user error.
    var hasAnyAction: Bool {
        !presetOverride.isEmpty || !intentOverride.isEmpty || driveSpeedOverride > 0
    }

    /// Check whether this rule matches the given disc context. Returns
    /// false for disabled rules and for rules with no constraints (to
    /// avoid an empty rule matching everything by accident).
    func matches(discName: String, mediaTitle: String, mediaType: String, discType: String) -> Bool {
        guard enabled, hasAnyMatch else { return false }
        if !nameContains.isEmpty {
            // MakeMKV's disc names typically use underscores (`STAR_WARS_DVD`)
            // while the user types human-readable strings in the rule field
            // (`Star Wars`). Normalize underscores to spaces on the haystack
            // so the natural match works without forcing the user to escape.
            let needle = nameContains.lowercased()
            let haystackDisc = discName.lowercased().replacingOccurrences(of: "_", with: " ")
            let haystackTitle = mediaTitle.lowercased()
            let nameMatch = haystackDisc.contains(needle)
            let titleMatch = haystackTitle.contains(needle)
            guard nameMatch || titleMatch else { return false }
        }
        if !mediaTypeFilter.isEmpty, mediaType.lowercased() != mediaTypeFilter.lowercased() {
            return false
        }
        if !discTypeFilter.isEmpty, discType.lowercased() != discTypeFilter.lowercased() {
            return false
        }
        return true
    }
}

/// Helper for `RipViewModel` — finds the first enabled rule that
/// matches the supplied disc context. Pure / unit-testable.
enum DiscRuleMatcher {
    static func firstMatch(in rules: [DiscRule],
                           discName: String,
                           mediaTitle: String,
                           mediaType: String,
                           discType: String) -> DiscRule? {
        rules.first { $0.matches(discName: discName,
                                 mediaTitle: mediaTitle,
                                 mediaType: mediaType,
                                 discType: discType) }
    }
}
