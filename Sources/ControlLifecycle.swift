import Foundation

enum ReconnectReadiness: Equatable {
    case inactive, waitingForRelease, confirmingRelease, ready, conflictingApp, releaseTimedOut
}

// The user's switch intent survives sleep and a temporary connection outage.
// Hardware/authentication faults remain latched off; reconnects never request installation.
struct ControlLifecycle {
    private(set) var requested = false
    private(set) var sleeping = false
    private(set) var retryAt: Double?
    private(set) var failureCount = 0
    private var healthySince: Double?
    private var releaseWaitSince: Double?
    private var autoSince: Double?

    private mutating func resetReleaseWait() { releaseWaitSince = nil; autoSince = nil }

    mutating func enable() {
        requested = true; retryAt = nil; failureCount = 0; healthySince = nil
        resetReleaseWait()
    }

    mutating func disable() {
        requested = false; retryAt = nil; failureCount = 0; healthySince = nil
        resetReleaseWait()
    }

    mutating func sleep() {
        sleeping = true; retryAt = nil; healthySince = nil
        resetReleaseWait()
    }

    mutating func wake(now: Double) {
        sleeping = false
        if requested { retryAt = now + 2 }
    }

    mutating func failed(now: Double, retryable: Bool) {
        healthySince = nil
        resetReleaseWait()
        guard requested, !sleeping else { return }
        guard retryable else {
            requested = false; retryAt = nil
            return
        }
        failureCount = min(failureCount + 1, 4)
        // Give the original session's 8-second watchdog time to restore Auto.
        // Bound retry frequency, not the user's enabled intent. Slow recovery can
        // last longer than three attempts without becoming a hardware fault.
        retryAt = now + [10.0, 20.0, 40.0, 60.0][failureCount - 1]
    }

    mutating func connected(now: Double) {
        retryAt = nil
        resetReleaseWait()
        if let since = healthySince {
            if now - since >= 60 { failureCount = 0 }
        } else {
            healthySince = now
        }
    }

    func shouldReconnect(now: Double) -> Bool {
        requested && !sleeping && retryAt.map { now >= $0 } == true
    }

    // This gate only observes; it must never write Auto to a fan of unknown ownership.
    // A lost reply does not imply the previous helper has finished releasing hardware.
    mutating func reconnectReadiness(now: Double, fans: [FanReading]?, conflictingApp: Bool) -> ReconnectReadiness {
        guard shouldReconnect(now: now) else { return .inactive }
        if conflictingApp { return .conflictingApp }
        guard let fans, !fans.isEmpty else { autoSince = nil; return .inactive }
        if fans.allSatisfy({ $0.mode == 0 }) {
            if let since = autoSince, now - since >= 2 { return .ready }
            if autoSince == nil { autoSince = now }
            return .confirmingRelease
        }
        autoSince = nil
        if releaseWaitSince == nil { releaseWaitSince = now }
        return now - releaseWaitSince! >= 30 ? .releaseTimedOut : .waitingForRelease
    }
}
