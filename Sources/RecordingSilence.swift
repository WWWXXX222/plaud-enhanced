import Foundation

struct RecordingSilenceReminder: Equatable, Identifiable {
    let id: UUID
    let quietSeconds: Double
}

// Uses the capture host clock, never wall-clock time, subtitles, or a network service.
// An alert is advisory: only an explicit user response may end a recording.
struct RecordingSilenceWatchdog {
    static let interval: Double = 5 * 60
    static let activityDecibels: Float = -50
    private var lastActivity: Double?
    private var lastAcknowledged: Double?
    private(set) var reminder: RecordingSilenceReminder?

    mutating func start(at now: Double) {
        lastActivity = now; lastAcknowledged = now; reminder = nil
    }

    mutating func stop() {
        lastActivity = nil; lastAcknowledged = nil; reminder = nil
    }

    mutating func update(at now: Double, microphonePower: Float?, systemActivity: Double?) {
        guard now.isFinite, let previousActivity = lastActivity else { return }
        var latest = previousActivity
        if let power = microphonePower, power.isFinite, power >= Self.activityDecibels {
            latest = now
        }
        if let systemActivity, systemActivity.isFinite, systemActivity <= now {
            latest = max(latest, systemActivity)
        }
        if latest > previousActivity {
            lastActivity = latest
            // Sound resumed while the question was open: remove the stale question.
            // A severely delayed old buffer is not evidence of sound resuming now.
            if now - latest < Self.interval { reminder = nil }
        }
        let quiet = now - max(latest, lastAcknowledged ?? latest)
        if reminder == nil, quiet >= Self.interval {
            reminder = RecordingSilenceReminder(id: UUID(), quietSeconds: quiet)
        }
    }

    // A previous meeting's dialog, double click, or resumed sound cannot stop a session.
    @discardableResult mutating func acknowledge(_ id: UUID, at now: Double) -> Bool {
        guard reminder?.id == id else { return false }
        lastAcknowledged = now; reminder = nil
        return true
    }
}

// The file writer publishes only an activity timestamp, not audio or a growing queue.
// Reading this on the UI thread never waits on audio conversion or disk writes.
final class RecordingSoundActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Double?
    func observe(meanSquare: Double, at hostTime: Double) {
        // -50 dBFS RMS. Tiny floating-point noise and digital silence do not reset the timer.
        guard meanSquare.isFinite, meanSquare >= 0.00001, hostTime.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        latest = max(latest ?? hostTime, hostTime)
    }
    var lastActiveHostTime: Double? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}
