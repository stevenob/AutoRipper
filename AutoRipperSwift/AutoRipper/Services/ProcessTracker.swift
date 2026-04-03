import Foundation
import os

private let log = Logger(subsystem: "com.autoripper.app", category: "process")

/// Tracks running child processes and terminates them on app quit.
final class ProcessTracker: @unchecked Sendable {
    static let shared = ProcessTracker()

    private var processes: [Int32: Process] = [:]
    private let lock = NSLock()

    func register(_ process: Process) {
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: process.processIdentifier)
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let running = processes.values.filter { $0.isRunning }
        lock.unlock()

        for proc in running {
            log.info("Terminating child process \(proc.processIdentifier)")
            proc.terminate()
        }
    }
}
