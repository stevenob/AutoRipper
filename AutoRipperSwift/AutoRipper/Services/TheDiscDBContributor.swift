import Foundation

/// Write client for TheDiscDB's "Engram" contribution REST API. When the user
/// opts in, AutoRipper submits the fingerprint + title layout of a scanned disc
/// that TheDiscDB doesn't yet know about, so the community database grows to
/// cover discs AutoRipper currently has to guess at.
///
/// Important properties of this path (verified against TheDiscDb/web source):
///   * `POST /api/engram/disc` is an idempotent UPSERT keyed by `content_hash`.
///   * Submissions land in a human-reviewed staging queue — they do NOT appear
///     in the live database automatically, so contributing never immediately
///     changes a future scan's result.
///   * The endpoint is currently unauthenticated, with a server-side TODO to add
///     API-key auth. We deliberately don't ship an API-key field yet: the auth
///     scheme and key-issuance flow aren't published. When they are, add a
///     Keychain-stored credential here.
///
/// Everything is best-effort and non-fatal: a failure is logged and swallowed,
/// never surfaced into the scan/rip flow.
struct TheDiscDBContributor {
    private let session = URLSession.shared
    private let baseURL = "https://thediscdb.com"

    // MARK: - Engram wire payload (snake_case via convertToSnakeCase)

    struct Submission: Encodable, Equatable {
        let engramVersion: String
        let exportVersion: String
        let contributionTier: Int
        let upc: String?
        let disc: Disc
        let identification: Identification?
        let titles: [Title]
    }

    struct Disc: Encodable, Equatable {
        let contentHash: String
        let volumeLabel: String
        let contentType: String
        let discNumber: Int
    }

    struct Identification: Encodable, Equatable {
        let tmdbId: Int?
        let detectedTitle: String?
    }

    struct Title: Encodable, Equatable {
        let index: Int
        let sourceFilename: String?
        let durationSeconds: Int
        let sizeBytes: Int64
        let chapterCount: Int
        let titleType: String
        let season: Int?
        let episode: Int?
    }

    // MARK: - Pure payload builder (unit-testable, no network)

    /// Build an Engram submission from a scanned disc and AutoRipper's heuristic
    /// classification. Pure — takes a snapshot of everything it needs so the
    /// caller can build it once, before any network await, and revalidate
    /// ownership afterwards.
    static func buildSubmission(
        info: DiscInfo,
        contentHash: String,
        tmdbId: Int?,
        detectedTitle: String?,
        episodeAssignments: [Int: TitleEpisodeAssignment]
    ) -> Submission {
        let titles: [Title] = info.titles.map { t in
            let assignment = episodeAssignments[t.id]
            let type = engramTitleType(for: t.category)
            // Season/episode only ride along for episode-typed titles that
            // actually carry an assignment — never invented.
            let isEpisode = type == "Episode" && assignment != nil
            return Title(
                index: t.id,
                sourceFilename: t.fileOutput.isEmpty ? nil : t.fileOutput,
                durationSeconds: t.durationSeconds,
                sizeBytes: t.sizeBytes,
                chapterCount: t.chapters,
                titleType: type,
                season: isEpisode ? assignment?.season : nil,
                episode: isEpisode ? assignment?.episode : nil
            )
        }

        let detected = detectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identification: Identification?
        if tmdbId != nil || (detected?.isEmpty == false) {
            identification = Identification(
                tmdbId: tmdbId,
                detectedTitle: (detected?.isEmpty == false) ? detected : nil
            )
        } else {
            identification = nil
        }

        return Submission(
            engramVersion: "1.0.0",
            exportVersion: "1",
            contributionTier: 1,
            upc: nil,
            disc: Disc(
                contentHash: contentHash.uppercased(),
                volumeLabel: info.name,
                contentType: engramContentType(for: info.type),
                discNumber: 1
            ),
            identification: identification,
            titles: titles
        )
    }

    /// Map AutoRipper's `DiscInfo.type` ("dvd" | "bluray") onto Engram's
    /// `content_type`. AutoRipper doesn't distinguish UHD from Blu-ray on the
    /// disc model, so a 4K disc is reported as "blu-ray" (reviewers can correct
    /// the format during approval).
    static func engramContentType(for discType: String) -> String {
        discType.lowercased().contains("dvd") ? "dvd" : "blu-ray"
    }

    /// Map AutoRipper's heuristic `TitleCategory` onto Engram's `title_type`.
    /// Deliberately conservative: only the single largest main feature becomes
    /// `MainMovie`; alternate cuts / commentary tracks map to `Other` rather
    /// than risk seeding a second `MainMovie` into the review queue.
    static func engramTitleType(for category: TitleCategory) -> String {
        switch category {
        case .mainFeature:    return "MainMovie"
        case .episode:        return "Episode"
        case .trailer:        return "Trailer"
        case .featurette:     return "Featurette"
        case .shortExtra:     return "Short"
        case .extra, .bonusFeature: return "Extra"
        case .alternateCut, .alternateAudio: return "Other"
        case .unknown:        return "Other"
        }
    }

    // MARK: - Network

    /// POST a disc submission. Returns `true` on a 2xx response. Best-effort;
    /// logs and swallows every failure.
    func submitDisc(_ submission: Submission) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/engram/disc") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(submission) else {
            FileLogger.shared.warn("thediscdb", "engram: failed to encode submission")
            return false
        }
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200...299).contains(http.statusCode) else {
                FileLogger.shared.warn("thediscdb",
                    "engram: submitDisc HTTP \(http.statusCode) for \(submission.disc.contentHash)")
                return false
            }
            FileLogger.shared.info("thediscdb",
                "engram: submitted disc \(submission.disc.contentHash) (\(submission.titles.count) titles)")
            return true
        } catch {
            FileLogger.shared.warn("thediscdb",
                "engram: submitDisc failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Upload the raw MakeMKV scan log for a disc that has already been
    /// submitted (the endpoint 404s otherwise). `text/plain`. Best-effort.
    func uploadScanLog(contentHash: String, log: String) async -> Bool {
        let hash = contentHash.uppercased()
        guard !log.isEmpty,
              let url = URL(string: "\(baseURL)/api/engram/disc/\(hash)/logs/scan") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        request.httpBody = Data(log.utf8)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                FileLogger.shared.warn("thediscdb", "engram: uploadScanLog non-2xx for \(hash)")
                return false
            }
            FileLogger.shared.info("thediscdb", "engram: uploaded scan log for \(hash)")
            return true
        } catch {
            FileLogger.shared.warn("thediscdb",
                "engram: uploadScanLog failed: \(error.localizedDescription)")
            return false
        }
    }
}

/// Local record of which disc fingerprints AutoRipper has already contributed,
/// so the same unknown disc isn't re-submitted on every re-scan. Engram is an
/// idempotent upsert, but its review queue is invisible to us — a contributed
/// disc keeps looking "not found" until a maintainer approves it, so without
/// this throttle a frequently-scanned unknown disc would generate review noise
/// indefinitely.
struct DiscDBContributionLedger {
    private let defaults: UserDefaults
    private let storageKey = "discDbContributionLedger"
    /// Don't re-submit the same fingerprint within this window.
    private let throttle: TimeInterval = 30 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `true` when this hash has never been submitted, or was last submitted
    /// longer ago than the throttle window.
    func shouldSubmit(contentHash: String, now: Date = Date()) -> Bool {
        let map = stored()
        guard let last = map[contentHash.uppercased()] else { return true }
        return now.timeIntervalSince1970 - last >= throttle
    }

    /// Record a successful submission timestamp for `contentHash`.
    func record(contentHash: String, now: Date = Date()) {
        var map = stored()
        map[contentHash.uppercased()] = now.timeIntervalSince1970
        defaults.set(map, forKey: storageKey)
    }

    private func stored() -> [String: Double] {
        (defaults.dictionary(forKey: storageKey) as? [String: Double]) ?? [:]
    }
}
