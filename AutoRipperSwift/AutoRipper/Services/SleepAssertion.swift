import Foundation
import IOKit.pwr_mgt
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "sleep")

/// Wraps `IOPMAssertionCreateWithName` so the Mac doesn't go to sleep mid-rip
/// or mid-encode. Multi-hour Bluray rips otherwise get interrupted at the OS
/// level if the system idles into sleep.
///
/// Idempotent: multiple `acquire(reason:)` calls just bump a refcount; the
/// assertion is released when the refcount returns to zero.
final class SleepAssertion: @unchecked Sendable {
    static let shared = SleepAssertion()

    private let lock = NSLock()
    private var assertionId: IOPMAssertionID = 0
    private var refcount: Int = 0

    /// Acquire (or refcount-increment) a "system stays awake" assertion.
    /// `reason` is shown in `pmset -g assertions` for debugging.
    func acquire(reason: String) {
        lock.lock(); defer { lock.unlock() }
        refcount += 1
        if refcount == 1 {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionId
            )
            if result == kIOReturnSuccess {
                log.info("Acquired sleep assertion (\(reason, privacy: .public))")
            } else {
                log.error("Failed to acquire sleep assertion: \(result)")
                refcount -= 1
            }
        }
    }

    /// Release one refcount; releases the OS assertion when it hits zero.
    func release() {
        lock.lock(); defer { lock.unlock() }
        guard refcount > 0 else { return }
        refcount -= 1
        if refcount == 0 && assertionId != 0 {
            let result = IOPMAssertionRelease(assertionId)
            if result == kIOReturnSuccess {
                log.info("Released sleep assertion")
            } else {
                log.error("Failed to release sleep assertion: \(result)")
            }
            assertionId = 0
        }
    }
}
