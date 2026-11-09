import Foundation
import Darwin

enum TranscriptionWatchdog {
    static func shouldRestart(pid: Int32, launched: Date, modified: Date?, request: [String: Double]?, now: Date = Date()) -> Bool {
        let idle = now.timeIntervalSince(max(modified ?? launched, launched))
        let requested = request?["pid"] == Double(pid) && (request?["requested_at"] ?? 0) >= launched.timeIntervalSince1970
        return idle >= 900 || (requested && idle >= 600)
    }
    // This API accepts the live child handle, never a PID loaded from disk.
    static func stopOwned(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
        }
        process.waitUntilExit()
    }
}
