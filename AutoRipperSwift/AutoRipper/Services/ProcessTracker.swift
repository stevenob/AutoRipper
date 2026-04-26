import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "process")

/// Tracks running child processes and terminates them on app quit or abort.
///
/// Uses an array (not a dict) so insertion order is preserved — `terminateLatest`
/// genuinely picks the most-recently-registered running process.
final class ProcessTracker: @unchecked Sendable {
    static let shared = ProcessTracker()

    private var processes: [Process] = []
    private let lock = NSLock()

    func register(_ process: Process) {
        lock.lock()
        processes.append(process)
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }

    /// Terminate the most recently registered running process (for abort).
    func terminateLatest() {
        lock.lock()
        let latest = processes.reversed().first { $0.isRunning }
        lock.unlock()

        if let latest {
            log.info("Aborting process \(latest.processIdentifier)")
            latest.terminate()
            // SIGTERM-then-SIGKILL: if the child ignores SIGTERM, escalate after 2s.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak latest] in
                if let p = latest, p.isRunning {
                    log.warning("Process \(p.processIdentifier) ignored SIGTERM, sending SIGKILL")
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Terminate every running tracked child process (used by abort and on app quit).
    func terminateAll() {
        lock.lock()
        let running = processes.filter { $0.isRunning }
        lock.unlock()

        for proc in running {
            log.info("Terminating child process \(proc.processIdentifier)")
            proc.terminate()
        }
        // SIGKILL escalation after 2s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for p in running where p.isRunning {
                log.warning("Process \(p.processIdentifier) ignored SIGTERM, sending SIGKILL")
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }
}
