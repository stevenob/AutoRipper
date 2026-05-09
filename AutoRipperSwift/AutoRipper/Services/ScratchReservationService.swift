import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "scratch-reservation")

/// Global ledger of in-flight scratch-space reservations, used so the
/// pre-flight free-space check accounts for *concurrent* jobs sharing the
/// same scratch volume — not just the bytes a single job needs.
///
/// In Full Auto + Batch, the rip for disc N+1 starts while disc N is
/// encoding. Without this, both jobs could pass their own pre-flight check
/// independently and *together* blow the disk budget.
///
/// Reservations are keyed by `jobId` so a job can update or release them as
/// it transitions phases. A typical movie's lifecycle:
///   * rip start            → reserve(jobId, sourceSize)
///   * encode start         → still holds rip reservation; total claimed = source + estimated encoded
///   * publish complete     → release(jobId) — scratch is reclaimed
///
/// Backed by a simple actor; reads and writes are async but cheap.
actor ScratchReservationService {
    static let shared = ScratchReservationService()

    /// jobId -> bytes reserved on the scratch volume.
    private var reservations: [String: Int64] = [:]

    /// Reserve `bytes` for `jobId`. Replaces any prior reservation for that
    /// job (so callers don't have to track and subtract their previous claim
    /// when transitioning rip → encode → publish).
    func reserve(jobId: String, bytes: Int64) {
        reservations[jobId] = bytes
        log.info("reserve \(jobId, privacy: .public) = \(bytes) (total \(self.totalReserved))")
    }

    /// Drop the reservation for `jobId`. No-op if it wasn't reserved.
    func release(jobId: String) {
        if reservations.removeValue(forKey: jobId) != nil {
            log.info("release \(jobId, privacy: .public) (total \(self.totalReserved))")
        }
    }

    /// Sum of all current reservations. Subtracted from raw free-space to get
    /// the budget pre-flight checks should compare against.
    var totalReserved: Int64 {
        reservations.values.reduce(0, +)
    }

    /// True if a hypothetical new reservation of `additionalBytes` at `path`
    /// would still leave free-space ≥ `safetyMargin`. Returns false (and the
    /// shortfall) if it would not.
    ///
    /// Free-space is queried via `StagingService.freeBytes` which uses
    /// `volumeAvailableCapacityForImportantUsageKey`.
    func canReserve(
        atPath path: String,
        additionalBytes: Int64,
        safetyMargin: Int64 = 1_073_741_824   // 1 GB default headroom
    ) -> (ok: Bool, available: Int64, shortfallBytes: Int64) {
        let raw = StagingService.freeBytes(at: path) ?? 0
        let usable = raw - totalReserved - safetyMargin
        if usable >= additionalBytes {
            return (true, usable, 0)
        }
        return (false, usable, additionalBytes - usable)
    }

    /// Test-only: clear all reservations. Used by unit tests so multiple
    /// tests don't leak state into each other through the shared instance.
    func _testReset() {
        reservations.removeAll()
    }
}
