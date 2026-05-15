import Foundation

/// v3.11.9: pure aggregator over completed `Job`s that surfaces a
/// drive-health verdict for the user.
///
/// **Why this exists.** v3.11.5 + v3.11.7 added per-rip counters for
/// drive-side read errors (MSG:2003) and disc-side corruption events
/// (MSG:2002/2017/2018). Those are great when you're looking at a
/// single problem rip, but they don't answer the question users
/// actually ask after a problem rip: *"Is something wrong with my
/// drive?"*
///
/// `DriveHealthAnalyzer` looks at the History as a whole. If a high
/// fraction of recent rips show errors, the verdict tips toward
/// `.driveSuspect`. If most rips are clean and only a few discs have
/// issues, that's `.someIssues` (probably damaged discs, not the
/// drive). All-clean is `.healthy`.
///
/// The analyzer is intentionally *pure* and *thresholds-only*:
///   - No filesystem access, no MakeMKV calls, no state.
///   - Verdict thresholds are simple percentages and hand-tuned. We
///     could plug in more sophisticated heuristics later (offset
///     clustering, time-trend analysis) without changing the call
///     site.
enum DriveHealthAnalyzer {

    /// Snapshot summary across a set of `Job`s.
    struct Report: Sendable, Equatable {
        /// Number of jobs the report was computed from.
        let analyzedCount: Int
        /// Jobs with `ripReadErrors > 0`.
        let ripsWithReadErrors: Int
        /// Jobs with `ripCorruptionEvents > 0`.
        let ripsWithCorruption: Int
        /// Jobs with EITHER counter > 0 (de-duplicated when a job has both).
        let ripsWithAnyIssue: Int
        /// Sum of `ripReadErrors` across all jobs.
        let totalReadErrors: Int
        /// Sum of `ripCorruptionEvents` across all jobs.
        let totalCorruptionEvents: Int
        /// Overall verdict — see `Verdict` for thresholds.
        let verdict: Verdict

        /// Percentage of analyzed jobs with ANY issue (0...100).
        /// Convenience for the UI — returns 0 if analyzedCount == 0.
        var anyIssuePercent: Int {
            guard analyzedCount > 0 else { return 0 }
            return Int((Double(ripsWithAnyIssue) / Double(analyzedCount)) * 100.0)
        }
    }

    /// High-level health verdict. Drives the UI color + headline.
    enum Verdict: Sendable, Equatable {
        /// 0 jobs with any issue. Drive looks fine.
        case healthy
        /// Some jobs with issues, but the majority are clean. Most
        /// likely a few damaged discs rather than a drive problem.
        case someIssues
        /// Many jobs with issues — pattern is consistent enough that
        /// the drive itself is the likely culprit.
        case driveSuspect
        /// Not enough data to make a judgement (zero analyzed jobs).
        case insufficientData
    }

    /// Threshold above which the verdict tips to `.driveSuspect`.
    /// Percentage of analyzed jobs with any issue. Hand-tuned: at
    /// 40%+ the failure rate is unreasonable for a normal disc
    /// collection (most home libraries have < 10% damaged-disc rate),
    /// so the drive is the more parsimonious explanation.
    static let suspectThresholdPercent = 40

    /// Minimum number of jobs the analyzer needs before it'll emit a
    /// non-`.insufficientData` verdict. Single rips don't generalize.
    static let minimumSampleSize = 3

    /// Compute the report for a set of jobs. Pass the completed-only
    /// subset of `QueueViewModel.jobs` (in-flight jobs would skew the
    /// counters with zero values).
    static func analyze(jobs: [Job]) -> Report {
        let count = jobs.count
        var readErrJobs = 0
        var corruptJobs = 0
        var anyIssueJobs = 0
        var totalRead = 0
        var totalCorrupt = 0
        for j in jobs {
            let hadRead = j.ripReadErrors > 0
            let hadCorrupt = j.ripCorruptionEvents > 0
            if hadRead { readErrJobs += 1 }
            if hadCorrupt { corruptJobs += 1 }
            if hadRead || hadCorrupt { anyIssueJobs += 1 }
            totalRead += j.ripReadErrors
            totalCorrupt += j.ripCorruptionEvents
        }
        let verdict: Verdict
        if count < minimumSampleSize {
            verdict = .insufficientData
        } else if anyIssueJobs == 0 {
            verdict = .healthy
        } else {
            let pct = Int((Double(anyIssueJobs) / Double(count)) * 100.0)
            verdict = pct >= suspectThresholdPercent ? .driveSuspect : .someIssues
        }
        return Report(
            analyzedCount: count,
            ripsWithReadErrors: readErrJobs,
            ripsWithCorruption: corruptJobs,
            ripsWithAnyIssue: anyIssueJobs,
            totalReadErrors: totalRead,
            totalCorruptionEvents: totalCorrupt,
            verdict: verdict
        )
    }

    /// v3.11.11: filter helper used by the "Mark all affected for re-rip"
    /// bulk action on the Drive Health pane. Returns the jobs that have
    /// EITHER counter > 0 AND a non-empty discFingerprint (without one
    /// the dup-suppression logic in `RipViewModel` can't recognize the
    /// disc on re-insert, so re-ripping it does nothing useful).
    static func affectedJobsWithFingerprint(_ jobs: [Job]) -> [Job] {
        jobs.filter { job in
            guard let fp = job.discFingerprint, !fp.isEmpty else { return false }
            return job.ripReadErrors > 0 || job.ripCorruptionEvents > 0
        }
    }

    /// v3.11.12: cluster analysis result over the read-error offsets
    /// recorded by past rips. Surfaces in the Drive Health UI when
    /// errors on different physical discs all fire at similar offsets —
    /// the parsimonious explanation is a drive laser-tracking fault at
    /// the corresponding radial position.
    struct OffsetCluster: Sendable, Equatable {
        /// Number of offsets analysed across all jobs.
        let sampleSize: Int
        /// Number of distinct jobs (= discs) contributing offsets.
        let distinctJobs: Int
        /// Median offset in bytes. nil when sampleSize == 0.
        let medianBytes: Int64?
        /// Min / max offset in bytes. nil when sampleSize == 0.
        let minBytes: Int64?
        let maxBytes: Int64?
        /// True when the cluster is "tight" enough across multiple
        /// distinct discs to suggest a drive issue. See
        /// `analyzeOffsetClustering(_:)` for the heuristic.
        let isCluster: Bool
    }

    /// Maximum spread (max - min, in bytes) below which offsets across
    /// multiple discs are considered clustered. 500 MiB is wide enough
    /// to forgive small variation in disc layout while still flagging
    /// genuine radial-position faults.
    static let clusterSpreadThresholdBytes: Int64 = 500 * 1024 * 1024

    /// Minimum number of DISTINCT jobs (= discs) the analyzer needs
    /// before it will flag a cluster. With only one disc contributing
    /// offsets, clustering tells you nothing about the drive (the disc
    /// could be locally damaged in one spot). The phenomenon worth
    /// surfacing is "different physical discs failing at the same disc-
    /// radius position", which requires ≥ 2 distinct discs.
    static let clusterMinDistinctJobs = 2

    /// Aggregate read-error offsets across the supplied jobs and
    /// determine whether they cluster.
    static func analyzeOffsetClustering(_ jobs: [Job]) -> OffsetCluster {
        var distinctJobs = 0
        var allOffsets: [Int64] = []
        for job in jobs where !job.readErrorOffsets.isEmpty {
            distinctJobs += 1
            allOffsets.append(contentsOf: job.readErrorOffsets)
        }
        guard !allOffsets.isEmpty else {
            return OffsetCluster(sampleSize: 0, distinctJobs: 0,
                                 medianBytes: nil, minBytes: nil, maxBytes: nil,
                                 isCluster: false)
        }
        let sorted = allOffsets.sorted()
        let minB = sorted.first!
        let maxB = sorted.last!
        let median = sorted[sorted.count / 2]
        let spread = maxB - minB
        let cluster = distinctJobs >= clusterMinDistinctJobs
            && spread <= clusterSpreadThresholdBytes
        return OffsetCluster(sampleSize: allOffsets.count,
                             distinctJobs: distinctJobs,
                             medianBytes: median,
                             minBytes: minB,
                             maxBytes: maxB,
                             isCluster: cluster)
    }
}

extension DriveHealthAnalyzer.Verdict {
    /// User-facing label for the verdict. Kept short so it works as a
    /// section header or badge.
    var headline: String {
        switch self {
        case .healthy:           return "Drive looks healthy"
        case .someIssues:        return "Some discs had issues"
        case .driveSuspect:      return "Drive may be at fault"
        case .insufficientData:  return "Not enough data yet"
        }
    }

    /// Plain-English explainer. Adapts to which signals fired so the
    /// user has a starting point for whatever next action makes sense.
    func explanation(report: DriveHealthAnalyzer.Report) -> String {
        switch self {
        case .insufficientData:
            return "Rip a few more discs and check back — patterns only become visible across multiple rips."
        case .healthy:
            return "All \(report.analyzedCount) recent rips completed without MakeMKV reporting read errors or content-corruption events. Drive + discs look fine."
        case .someIssues:
            let pct = report.anyIssuePercent
            return "\(report.ripsWithAnyIssue) of \(report.analyzedCount) recent rips (\(pct)%) had errors. Below the threshold where the drive itself would be the most likely cause — usually points at a handful of damaged discs. Clean the affected discs and re-rip; check History → Disc health for the per-disc breakdown."
        case .driveSuspect:
            let pct = report.anyIssuePercent
            return "\(report.ripsWithAnyIssue) of \(report.analyzedCount) recent rips (\(pct)%) had errors. That's high enough that the drive is the more likely culprit than the discs. Try ripping a brand-new disc — if it also throws errors, the drive is bad and worth returning. Otherwise check the lens and try the Quiet (4×) drive speed in Settings."
        }
    }

    /// Asset name / system symbol for the section header glyph.
    var sfSymbol: String {
        switch self {
        case .healthy:           return "checkmark.seal.fill"
        case .someIssues:        return "exclamationmark.triangle.fill"
        case .driveSuspect:      return "exclamationmark.octagon.fill"
        case .insufficientData:  return "questionmark.circle"
        }
    }
}
