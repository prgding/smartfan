import Foundation
import Darwin

private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAILED: \(message)") }
}
private func snapshot(primary: Double? = 30, battery: Double = 34, cpu: Double = 60,
                      actual: Double = 1200, target: Double = 1200, mode: Int = 0,
                      pressure: Int = 0, maximum: Double = 7200,
                      secondary: Double? = nil, charging: Bool? = false) -> ThermalSnapshot {
    var temperatures = ["TB0T": battery, "Tp2a": cpu]
    temperatures["Ts1P"] = primary
    temperatures["Ts0P"] = secondary
    return ThermalSnapshot(timestamp: Date(), temperatures: temperatures,
        fans: [FanReading(index: 0, minimum: 1200, maximum: maximum, actual: actual, target: target, mode: mode)],
        powerSource: "AC Power", isCharging: charging, thermalPressure: pressure)
}

private func checkBodyComfort() throws {
    var warmPolicy = ControlPolicy()
    for (index, cpu) in [75.0, 60, 55, 70, 50].enumerated() {
        let decision = try warmPolicy.targets(snapshot: snapshot(primary: 29, battery: 33.9, cpu: cpu,
            actual: 4732, secondary: 32, charging: true), mode: .automatic, manualRPM: 3000, now: Double(index * 2))
        expect(decision.values[0] == 5000 && warmPolicy.bodyCooling && !decision.standby,
               "the reported warm palm-rest state keeps 5000 RPM as the CPU cools")
        expect(decision.reason.contains("机身积热"), "the UI attributes the warm-state target to body cooling rather than CPU heat")
    }
    for warmSnapshot in [snapshot(primary: 27, battery: 33, cpu: 45, actual: 5000, secondary: 29),
                         snapshot(primary: 30, battery: 30, cpu: 45, actual: 5000, secondary: 29),
                         snapshot(primary: 28, battery: 31, cpu: 45, actual: 5000, secondary: 31.5)] {
        var policy = ControlPolicy()
        let decision = try policy.targets(snapshot: warmSnapshot, mode: .automatic, manualRPM: 3000, now: 0)
        expect(policy.bodyCooling && decision.values[0] == 5000,
               "each body reference independently sustains cooling without a hot CPU")
    }
    var uncharged = ControlPolicy(), charged = ControlPolicy(), unknownCharge = ControlPolicy()
    var unchargedTarget = 0.0, chargedTarget = 0.0, unknownTarget = 0.0
    for tick in 0...10 {
        unchargedTarget = try uncharged.targets(snapshot: snapshot(primary: 27.5, battery: 32.5, cpu: 45, secondary: 29),
            mode: .automatic, manualRPM: 3000, now: Double(tick * 2)).values[0]!
        chargedTarget = try charged.targets(snapshot: snapshot(primary: 27.5, battery: 32.5, cpu: 45, secondary: 29, charging: true),
            mode: .automatic, manualRPM: 3000, now: Double(tick * 2)).values[0]!
        unknownTarget = try unknownCharge.targets(snapshot: snapshot(primary: 27.5, battery: 32.5, cpu: 45, secondary: 29, charging: nil),
            mode: .automatic, manualRPM: 3000, now: Double(tick * 2)).values[0]!
    }
    expect(unchargedTarget == 4500 && chargedTarget == 5000,
           "charging reaches the daily ceiling half a degree earlier than the battery curve alone")
    expect(unknownTarget == unchargedTarget, "missing charging status leaves the base body-temperature control intact")

    var hold = ControlPolicy()
    _ = try hold.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, actual: 5000, secondary: 32),
                          mode: .automatic, manualRPM: 3000, now: 0)
    for now in stride(from: 2.0, through: 120.0, by: 2) {
        let decision = try hold.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 30),
                                         mode: .automatic, manualRPM: 3000, now: now)
        expect(decision.values[0] == 5000 && hold.bodyCooling,
               "body cooling requires two minutes of cool references before reducing airflow")
    }
    _ = try hold.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 31.2),
                          mode: .automatic, manualRPM: 3000, now: 122)
    for now in stride(from: 124.0, through: 242.0, by: 2) {
        let decision = try hold.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 30),
                                         mode: .automatic, manualRPM: 3000, now: now)
        expect(decision.values[0] == 5000 && hold.bodyCooling,
               "an unsettled body reference resets the full two-minute confirmation")
    }
    let released = try hold.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 30),
                                    mode: .automatic, manualRPM: 3000, now: 244)
    expect(!hold.bodyCooling && released.values[0] == 5000, "stable body cooling releases the hold without an immediate RPM drop")
    var previous = 5000.0
    for now in stride(from: 246.0, through: 280.0, by: 2) {
        let target = try hold.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 30),
                                      mode: .automatic, manualRPM: 3000, now: now).values[0]!
        expect(previous - target <= 400 && target <= previous, "body-cooling release uses the normal gradual descent")
        previous = target
    }
    expect(previous == 2200, "lower body temperatures eventually return to their lower curve target")

    var gap = ControlPolicy()
    _ = try gap.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, actual: 5000, secondary: 32),
                         mode: .automatic, manualRPM: 3000, now: 0)
    _ = try gap.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 30),
                         mode: .automatic, manualRPM: 3000, now: 2)
    let delayed = try gap.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 30),
                                  mode: .automatic, manualRPM: 3000, now: 130)
    expect(delayed.values[0] == 5000 && gap.bodyCooling, "a sampling gap cannot be mistaken for completed body cooling")
    let manual = try gap.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, secondary: 32),
                                 mode: .manual, manualRPM: 2400, now: 132)
    expect(manual.values[0] == 2400, "body-comfort cooling is automatic behavior and respects explicit manual control")
    let automatic = try gap.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 50, actual: 2400, secondary: 32),
                                    mode: .automatic, manualRPM: 2400, now: 134)
    expect(automatic.values[0]! > 2400 && gap.bodyCooling, "returning to automatic resumes body-based cooling")

    var chargingWake = ControlPolicy()
    for tick in 0...10 {
        _ = try chargingWake.targets(snapshot: snapshot(primary: 27, battery: 30.5, cpu: 50, secondary: 29, charging: true),
                                      mode: .automatic, manualRPM: 3000, now: Double(tick * 2))
    }
    let wake = try chargingWake.targets(snapshot: snapshot(primary: 27, battery: 30.6, cpu: 50, secondary: 29, charging: true),
                                        mode: .automatic, manualRPM: 3000, now: 22)
    expect(!wake.standby && !wake.values.isEmpty, "charging warms out of standby before the former 32-degree battery threshold")
}

private func checkEmergencyRecovery() throws {
    var policy = ControlPolicy()
    for tick in 0...9 {
        let decision = try policy.targets(snapshot: snapshot(cpu: tick % 2 == 0 ? 92.4 : 91.5),
                                           mode: .automatic, manualRPM: 3000, now: Double(tick * 2))
        expect(decision.values[0] == 7200 && policy.coolingPhase == .emergency,
               "repeated 92-degree crossings keep protective cooling instead of alternating with 5000 RPM")
    }
    for now in stride(from: 20.0, through: 26.0, by: 2) {
        _ = try policy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: now)
    }
    let interrupted = try policy.targets(snapshot: snapshot(cpu: 87), mode: .automatic, manualRPM: 3000, now: 28)
    expect(interrupted.values[0] == 7200, "warming above the exit threshold cancels stable-cooling confirmation")
    for now in stride(from: 30.0, through: 44.0, by: 2) {
        let decision = try policy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: now)
        expect(decision.values[0] == 7200, "less than 15 seconds at or below 86 degrees cannot release full speed")
    }
    let descending = try policy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: 46)
    expect(descending.values[0] == 6900 && policy.coolingPhase == .recovery,
           "stable cooling begins a limited descent instead of jumping to the daily ceiling")
    let rebound = try policy.targets(snapshot: snapshot(cpu: 88), mode: .automatic, manualRPM: 3000, now: 48)
    expect(rebound.values[0] == 6900 && policy.coolingPhase == .recovery,
           "a moderate temperature rebound pauses recovery without another jump to full speed")
    let fairPressure = try policy.targets(snapshot: snapshot(cpu: 80, pressure: 1), mode: .automatic, manualRPM: 3000, now: 50)
    expect(fairPressure.values[0] == 6900, "non-nominal thermal pressure pauses recovery descent")
    let resumed = try policy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: 52)
    expect(resumed.values[0] == 6600, "descent resumes when the rebound clears")
    let switched = try policy.targets(snapshot: snapshot(cpu: 60), mode: .manual, manualRPM: 1200, now: 54)
    expect(switched.values[0] == 6300 && policy.coolingPhase == .recovery,
           "switching to manual cannot reset protective recovery or cause an abrupt RPM drop")
    let adjusted = try policy.targets(snapshot: snapshot(cpu: 60), mode: .manual, manualRPM: 5000, now: 56)
    expect(adjusted.values[0] == 6000, "manual adjustment preserves the recovery ramp")
    let retriggered = try policy.targets(snapshot: snapshot(cpu: 92), mode: .manual, manualRPM: 1200, now: 58)
    expect(retriggered.values[0] == 7200 && policy.coolingPhase == .emergency,
           "a fresh emergency immediately interrupts recovery even in manual mode")
    let pressureEmergency = try policy.targets(snapshot: snapshot(cpu: 60, pressure: 2), mode: .manual, manualRPM: 1200, now: 60)
    expect(pressureEmergency.values[0] == 7200, "severe thermal pressure retains immediate full-speed protection")
    for now in stride(from: 62.0, through: 80.0, by: 2) {
        let decision = try policy.targets(snapshot: snapshot(cpu: 86, pressure: 1), mode: .manual, manualRPM: 1200, now: now)
        expect(decision.values[0] == 7200, "full-speed release requires nominal thermal pressure as well as a cooler CPU")
    }
    for now in stride(from: 82.0, through: 96.0, by: 2) {
        _ = try policy.targets(snapshot: snapshot(cpu: 86), mode: .manual, manualRPM: 1200, now: now)
    }
    var previous = 7200.0
    for now in stride(from: 98.0, through: 112.0, by: 2) {
        let decision = try policy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: now)
        let target = decision.values[0]!
        expect(target <= previous && previous - target <= 300 && target >= 5000,
               "the complete recovery is monotonic and drops at most 150 RPM per second")
        previous = target
    }
    expect(previous == 5000 && policy.coolingPhase == .normal, "recovery ends at the daily ceiling and restores normal control")
    let nextNormal = try policy.targets(snapshot: snapshot(cpu: 90), mode: .automatic, manualRPM: 3000, now: 114)
    expect(nextNormal.values[0] == 5000, "CPU protection below 92 degrees again respects the daily ceiling after recovery")

    var gapPolicy = ControlPolicy()
    _ = try gapPolicy.targets(snapshot: snapshot(cpu: 92), mode: .automatic, manualRPM: 3000, now: 0)
    _ = try gapPolicy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: 2)
    let afterGap = try gapPolicy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: 30)
    expect(afterGap.values[0] == 7200 && gapPolicy.coolingPhase == .emergency,
           "a monitoring gap does not count as sustained cooling")
    for now in stride(from: 32.0, through: 44.0, by: 2) {
        _ = try gapPolicy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: now)
    }
    let recoveredGap = try gapPolicy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: 46)
    expect(recoveredGap.values[0] == 6900, "fresh continuous readings after a gap can begin gradual recovery")
    let delayedRecovery = try gapPolicy.targets(snapshot: snapshot(cpu: 86), mode: .automatic, manualRPM: 3000, now: 60)
    expect(delayedRecovery.values[0] == 6900, "a delayed recovery tick cannot cause a large descent step")

    var coldPolicy = ControlPolicy()
    for tick in 0...26 {
        let decision = try coldPolicy.targets(snapshot: snapshot(primary: 27, battery: 29, cpu: tick == 0 ? 92 : 60),
                                               mode: .automatic, manualRPM: 3000, now: Double(tick * 2))
        expect(!decision.standby, "cold palm readings do not bypass protective recovery or its subsequent standby confirmation")
    }
    let eventualStandby = try coldPolicy.targets(snapshot: snapshot(primary: 27, battery: 29, cpu: 60),
                                                  mode: .automatic, manualRPM: 3000, now: 54)
    expect(eventualStandby.standby, "normal low-temperature standby remains available after protective cooling finishes")
}

private final class MockHardware: FanHardware {
    var mode: Double = 0
    var target: Double = 1200
    var failTarget = false
    var restoreFailures = 0
    var delayReads = 0
    var modePending: (Double, Int)?
    var targetPending: (Double, Int)?
    var writes: [(String, Double)] = []
    func set(index: Int, suffix: String, value: Double) throws {
        writes.append((suffix, value))
        if suffix == "Tg" && failTarget { throw SamplingError("simulated target failure") }
        if suffix == "Md", value == 0, restoreFailures > 0 {
            restoreFailures -= 1; throw SamplingError("simulated restore failure")
        }
        if delayReads > 0 {
            if suffix == "Md" { modePending = (value, delayReads) } else { targetPending = (value, delayReads) }
        } else if suffix == "Md" { mode = value } else { target = value }
    }
    func value(index: Int, suffix: String) -> Double? {
        if suffix == "Md", let pending = modePending {
            if pending.1 == 0 { mode = pending.0; modePending = nil }
            else { modePending = (pending.0, pending.1 - 1) }
        }
        if suffix == "Tg", let pending = targetPending {
            if pending.1 == 0 { target = pending.0; targetPending = nil }
            else { targetPending = (pending.0, pending.1 - 1) }
        }
        return suffix == "Md" ? mode : target
    }
}

private final class MockSessionProcess: ControlSessionProcess {
    var isRunning = true
    var stopRequests = 0
    func requestStop() { stopRequests += 1 }
    func stop() { isRunning = false }
}

private final class VirtualClock {
    var time = 0.0
    func advance(_ seconds: Double) { time += seconds }
}

private final class TimedModeHardware: FanHardware {
    let clock: VirtualClock
    var mode = 0.0
    var target = 0.0
    var modeDelay: Double
    var failRestore = false
    var readyAt: Double?
    var targetWrites = 0
    init(clock: VirtualClock, modeDelay: Double) { self.clock = clock; self.modeDelay = modeDelay }
    func set(index: Int, suffix: String, value: Double) throws {
        if suffix == "Md" {
            if value == 1 { readyAt = clock.time + modeDelay }
            else {
                if failRestore { throw SamplingError("simulated rollback failure") }
                readyAt = nil; mode = 0
            }
        } else {
            guard mode == 1 else { throw SamplingError("target written before mode was confirmed") }
            targetWrites += 1; target = value
        }
    }
    func value(index: Int, suffix: String) -> Double? {
        if suffix == "Md", let readyAt, clock.time >= readyAt { mode = 1; self.readyAt = nil }
        return suffix == "Md" ? mode : target
    }
}

@main enum Tests {
    static func main() throws {
        var lifecycle = ControlLifecycle()
        lifecycle.sleep(); lifecycle.wake(now: 0)
        expect(!lifecycle.requested && !lifecycle.shouldReconnect(now: 10), "sleep never enables a switch the user left off")
        lifecycle.enable(); lifecycle.connected(now: 10)
        lifecycle.sleep()
        expect(lifecycle.requested && !lifecycle.shouldReconnect(now: 100), "sleep preserves enabled intent without reconnecting asleep")
        lifecycle.wake(now: 100)
        expect(!lifecycle.shouldReconnect(now: 101) && lifecycle.shouldReconnect(now: 102), "wake waits briefly then restores control automatically")
        lifecycle.connected(now: 102)
        expect(lifecycle.requested && lifecycle.retryAt == nil, "successful wake clears the pending reconnect")
        lifecycle.failed(now: 110, retryable: true)
        expect(lifecycle.requested && !lifecycle.shouldReconnect(now: 119) && lifecycle.shouldReconnect(now: 120),
               "transport outage preserves intent and respects the original session watchdog")
        lifecycle.disable()
        expect(!lifecycle.shouldReconnect(now: 500), "explicit disable cancels a queued reconnect")
        lifecycle.enable()
        for now in [0.0, 20.0, 60.0] {
            lifecycle.failed(now: now, retryable: true)
            expect(lifecycle.requested, "transient outages retain enabled intent")
            lifecycle.connected(now: now + 10)
        }
        lifecycle.failed(now: 120, retryable: true)
        expect(lifecycle.requested && lifecycle.retryAt == 180, "fourth transient failure keeps the switch on with a 60-second backoff")
        for now in stride(from: 180.0, through: 1380.0, by: 60) {
            expect(lifecycle.shouldReconnect(now: now), "long outage still permits scheduled recovery")
            lifecycle.failed(now: now, retryable: true)
            expect(lifecycle.requested && lifecycle.retryAt == now + 60 && lifecycle.failureCount == 4,
                   "long outages cap retry frequency and counter, not enabled intent")
        }
        lifecycle.disable()
        expect(!lifecycle.shouldReconnect(now: 2000), "user can cancel recovery even after a long outage")
        lifecycle.enable(); lifecycle.failed(now: 0, retryable: true)
        lifecycle.connected(now: 10); lifecycle.connected(now: 71)
        expect(lifecycle.failureCount == 0, "sustained healthy control resets the retry budget")
        lifecycle.failed(now: 75, retryable: false)
        expect(!lifecycle.requested && lifecycle.retryAt == nil, "hardware and signature faults do not automatically retry")

        // Replay the observed incident: a forced-mode reading at reconnect, Auto four seconds later.
        var releaseLifecycle = ControlLifecycle()
        releaseLifecycle.enable(); releaseLifecycle.failed(now: 0, retryable: true)
        expect(releaseLifecycle.reconnectReadiness(now: 10, fans: snapshot(mode: 1).fans, conflictingApp: false) == .waitingForRelease,
               "lingering forced mode waits instead of being labelled an external app")
        expect(releaseLifecycle.requested && releaseLifecycle.failureCount == 1, "waiting preserves the switch and retry budget")
        expect(releaseLifecycle.reconnectReadiness(now: 14, fans: snapshot(mode: 0).fans, conflictingApp: false) == .confirmingRelease,
               "one Auto reading does not immediately seize control")
        expect(releaseLifecycle.reconnectReadiness(now: 16, fans: snapshot(mode: 0).fans, conflictingApp: false) == .ready,
               "a delayed release automatically permits reconnection")
        releaseLifecycle.connected(now: 16)
        expect(releaseLifecycle.requested && releaseLifecycle.retryAt == nil, "recovery completes with switch still enabled")

        releaseLifecycle.failed(now: 20, retryable: true)
        expect(releaseLifecycle.reconnectReadiness(now: 30, fans: snapshot().fans, conflictingApp: false) == .inactive,
               "release checks do not bypass retry backoff")
        _ = releaseLifecycle.reconnectReadiness(now: 40, fans: snapshot().fans, conflictingApp: false)
        _ = releaseLifecycle.reconnectReadiness(now: 41, fans: snapshot(mode: 1).fans, conflictingApp: false)
        expect(releaseLifecycle.reconnectReadiness(now: 42, fans: snapshot().fans, conflictingApp: false) == .confirmingRelease,
               "forced mode between Auto readings resets stability confirmation")
        _ = releaseLifecycle.reconnectReadiness(now: 44, fans: nil, conflictingApp: false)
        expect(releaseLifecycle.reconnectReadiness(now: 46, fans: snapshot().fans, conflictingApp: false) == .confirmingRelease,
               "missing or stale readings cannot confirm release")
        expect(releaseLifecycle.reconnectReadiness(now: 48, fans: snapshot().fans, conflictingApp: true) == .conflictingApp,
               "an identified competing application still blocks even with Auto readings")
        expect(releaseLifecycle.reconnectReadiness(now: 71, fans: snapshot(mode: 1).fans, conflictingApp: false) == .releaseTimedOut,
               "unidentified forced control is never acquired after a bounded release wait")
        releaseLifecycle.disable()
        expect(releaseLifecycle.reconnectReadiness(now: 100, fans: snapshot().fans, conflictingApp: false) == .inactive,
               "explicit disable cancels pending release recovery")
        releaseLifecycle.enable(); releaseLifecycle.sleep()
        expect(releaseLifecycle.reconnectReadiness(now: 100, fans: snapshot().fans, conflictingApp: false) == .inactive,
               "sleep suspends release recovery")
        releaseLifecycle.wake(now: 100)
        expect(releaseLifecycle.reconnectReadiness(now: 102, fans: snapshot(mode: 1).fans, conflictingApp: false) == .waitingForRelease,
               "wake starts a fresh bounded release wait")

        var standbyPolicy = ControlPolicy()
        let standbyHardware = MockHardware()
        let standbyActuator = FanActuator(standbyHardware)
        for tick in 0...10 {
            let current = snapshot(primary: 27, battery: 29.4, cpu: 62,
                                   target: standbyHardware.target, mode: Int(standbyHardware.mode))
            let decision = try standbyPolicy.targets(snapshot: current, mode: .automatic, manualRPM: 3000, now: Double(tick * 2))
            if decision.standby { try standbyActuator.standby(fans: current.fans) }
            else { try standbyActuator.apply(decision.values, fans: current.fans) }
            if tick < 10 { expect(!decision.standby, "cold readings must persist before standby") }
            else { expect(decision.standby && decision.values.isEmpty && standbyHardware.mode == 0,
                          "sustained cold releases hardware while the automatic policy remains active") }
        }
        let idleWrites = standbyHardware.writes.count
        let stableStandby = try standbyPolicy.targets(snapshot: snapshot(primary: 27, battery: 29.4, cpu: 71, mode: 0),
                                                      mode: .automatic, manualRPM: 3000, now: 22)
        try standbyActuator.standby(fans: snapshot(mode: 0).fans)
        expect(stableStandby.standby && standbyHardware.writes.count == idleWrites,
               "small CPU fluctuations do not toggle standby or repeatedly write hardware")
        let warmingStandby = try standbyPolicy.targets(snapshot: snapshot(primary: 29, battery: 30, cpu: 62, mode: 0),
                                                       mode: .automatic, manualRPM: 3000, now: 24)
        try standbyActuator.apply(warmingStandby.values, fans: snapshot(mode: 0).fans)
        expect(!warmingStandby.standby && standbyHardware.mode == 1,
               "warming automatically retakes hardware control without changing the switch")
        try standbyActuator.restore()
        var coldEmergency = ControlPolicy()
        for tick in 0...10 {
            _ = try coldEmergency.targets(snapshot: snapshot(primary: 27, battery: 29.4, cpu: 60),
                                          mode: .automatic, manualRPM: 3000, now: Double(tick * 2))
        }
        let exitOnCPU = try coldEmergency.targets(snapshot: snapshot(primary: 27, battery: 29.4, cpu: 75),
                                                mode: .automatic, manualRPM: 3000, now: 22)
        expect(!exitOnCPU.standby && exitOnCPU.values[0]! >= 3200, "CPU warming exits standby immediately")
        let coldCritical = try coldEmergency.targets(snapshot: snapshot(primary: 27, battery: 29.4, cpu: 93),
                                                    mode: .automatic, manualRPM: 3000, now: 24)
        expect(!coldCritical.standby && coldCritical.values[0] == 7200, "cold palm readings never suppress emergency cooling")
        var coldPressure = ControlPolicy()
        for tick in 0...10 {
            _ = try coldPressure.targets(snapshot: snapshot(primary: 27, battery: 29.4, cpu: 60),
                                         mode: .automatic, manualRPM: 3000, now: Double(tick * 2))
        }
        let pressureExit = try coldPressure.targets(snapshot: snapshot(primary: 27, battery: 29.4, cpu: 60, pressure: 1),
                                                   mode: .automatic, manualRPM: 3000, now: 22)
        expect(!pressureExit.standby, "system thermal pressure ends standby")
        let manualCold = try coldPressure.targets(snapshot: snapshot(primary: 27, battery: 29.4, cpu: 60),
                                                 mode: .manual, manualRPM: 3000, now: 24)
        expect(!manualCold.standby && manualCold.values[0] == 3000, "manual mode does not enter automatic standby")
        let conflictWrites = standbyHardware.writes.count
        do { try standbyActuator.standby(fans: snapshot(mode: 1).fans); fatalError("external forced mode ignored") }
        catch { expect(standbyHardware.writes.count == conflictWrites, "standby detects an external controller without changing its settings") }

        var policy = ControlPolicy()
        let comfy = try policy.targets(snapshot: snapshot(), mode: .automatic, manualRPM: 3000, now: 0)
        expect(comfy.values[0]! > 1200, "body references start cooling without a hot CPU")
        for i in 1...10 { _ = try policy.targets(snapshot: snapshot(), mode: .automatic, manualRPM: 3000, now: Double(i * 2)) }
        let settled = try policy.targets(snapshot: snapshot(), mode: .automatic, manualRPM: 3000, now: 22)
        expect(settled.values[0] == 5000, "warm body references settle at the daily ceiling even with a cool CPU")
        let reduced = try policy.targets(snapshot: snapshot(primary: 28, battery: 31), mode: .automatic, manualRPM: 3000, now: 24)
        expect(reduced.values[0]! == settled.values[0]!, "hold speed during cooling")
        var last = reduced.values[0]!
        for i in 13...110 {
            let next = try policy.targets(snapshot: snapshot(primary: 28, battery: 31), mode: .automatic, manualRPM: 3000, now: Double(i * 2)).values[0]!
            expect(last - next <= 400.01, "automatic decline stays within comfortable-zone ramp limit")
            last = next
        }
        expect(last < settled.values[0]!, "speed eventually decreases")

        var comfortCycle = ControlPolicy()
        var maintained = 0.0
        for tick in 0...35 {
            maintained = try comfortCycle.targets(snapshot: snapshot(primary: 30, battery: 33.6, cpu: 64, actual: 4500),
                mode: .automatic, manualRPM: 5000, now: Double(tick * 2)).values[0]!
        }
        expect(maintained == 5000, "the revised comfort margin maintains airflow before the newly reported warm state")
        let warmAgain = try comfortCycle.targets(snapshot: snapshot(primary: 30.2, battery: 33.9, cpu: 64),
            mode: .automatic, manualRPM: 5000, now: 72)
        expect(warmAgain.values[0] == maintained, "renewed warming retains airflow without waiting for CPU heat")
        var cooledAgain = warmAgain.values[0]!
        for tick in 37...180 {
            cooledAgain = try comfortCycle.targets(snapshot: snapshot(primary: 28, battery: 31, cpu: 64),
                mode: .automatic, manualRPM: 5000, now: Double(tick * 2)).values[0]!
        }
        expect(cooledAgain < 3000, "sustained cooling of body references eventually permits lower automatic speed")
        let protectedComfort = try comfortCycle.targets(snapshot: snapshot(primary: 30, battery: 33.6, cpu: 93),
            mode: .automatic, manualRPM: 5000, now: 362)
        expect(protectedComfort.values[0] == 7200, "CPU emergency still overrides comfortable palm-rest readings")
        let emergency = try policy.targets(snapshot: snapshot(cpu: 93), mode: .manual, manualRPM: 1200, now: 244)
        expect(emergency.values[0] == 7200, "CPU emergency overrides manual low speed immediately")
        let pressure = try policy.targets(snapshot: snapshot(pressure: 2), mode: .manual, manualRPM: 1200, now: 126)
        expect(pressure.values[0] == 7200, "thermal pressure overrides manual")
        var everydayPolicy = ControlPolicy()
        let guarded = try everydayPolicy.targets(snapshot: snapshot(cpu: 85), mode: .manual, manualRPM: 1200, now: 128)
        expect(guarded.values[0] == 5000, "manual CPU protection respects the normal ceiling below emergency")
        let manual = try everydayPolicy.targets(snapshot: snapshot(cpu: 60), mode: .manual, manualRPM: 3400, now: 130)
        expect(manual.values[0] == 3400, "manual setting is applied when safe")
        let capped = try everydayPolicy.targets(snapshot: snapshot(maximum: 4500), mode: .manual, manualRPM: 20000, now: 132)
        expect(capped.values[0] == 4500, "lower hardware maximum enforced")
        let floor = try everydayPolicy.targets(snapshot: snapshot(primary: 28, battery: 30, cpu: 40), mode: .manual, manualRPM: 0, now: 134)
        expect(floor.values[0] == 1200, "hardware minimum enforced")
        do {
            _ = try policy.targets(snapshot: snapshot(primary: nil), mode: .automatic, manualRPM: 3000, now: 136)
            fatalError("missing sensor accepted")
        } catch { expect(true, "missing sensor stops control") }

        var quietPolicy = ControlPolicy()
        let manualCeiling = try quietPolicy.targets(snapshot: snapshot(cpu: 60), mode: .manual, manualRPM: 7200, now: 0)
        expect(manualCeiling.values[0] == 5000, "manual requests above the normal ceiling are capped by the helper policy")
        let nearEmergency = try quietPolicy.targets(snapshot: snapshot(cpu: 91.9), mode: .automatic, manualRPM: 3000, now: 2)
        expect(nearEmergency.values[0] == 5000, "CPU protection below the emergency threshold respects 5000 RPM")
        let atEmergency = try quietPolicy.targets(snapshot: snapshot(cpu: 92), mode: .automatic, manualRPM: 3000, now: 4)
        expect(atEmergency.values[0] == 7200, "CPU emergency at exactly 92 degrees bypasses the normal ceiling")
        let clearedEmergency = try quietPolicy.targets(snapshot: snapshot(primary: 32, battery: 35, cpu: 80, actual: 7200),
                                                       mode: .automatic, manualRPM: 3000, now: 6)
        expect(clearedEmergency.values[0] == 7200, "one cool reading does not end emergency cooling")
        let pressureEmergency = try quietPolicy.targets(snapshot: snapshot(pressure: 2), mode: .automatic, manualRPM: 3000, now: 8)
        expect(pressureEmergency.values[0] == 7200, "automatic thermal-pressure emergency bypasses the normal ceiling")
        let clearedPressure = try quietPolicy.targets(snapshot: snapshot(pressure: 1), mode: .automatic, manualRPM: 3000, now: 10)
        expect(clearedPressure.values[0] == 7200, "clearing severe pressure requires stable cooling before release")
        var fastStart = ControlPolicy()
        let initialFast = try fastStart.targets(snapshot: snapshot(actual: 7200), mode: .automatic, manualRPM: 3000, now: 0)
        expect(initialFast.values[0] == 5000, "initial actual RPM above the ceiling cannot carry into the automatic target")
        for hotSnapshot in [snapshot(primary: 35, battery: 33), snapshot(primary: 29, battery: 39)] {
            var hotPolicy = ControlPolicy()
            var hotTarget = 0.0
            for tick in 0...10 {
                hotTarget = try hotPolicy.targets(snapshot: hotSnapshot, mode: .automatic, manualRPM: 3000,
                                                  now: Double(tick * 2)).values[0]!
                expect(hotTarget <= 5000, "palm or battery warming never exceeds the normal ceiling while ramping")
            }
            expect(hotTarget == 5000, "hot palm or battery readings settle at the normal ceiling")
        }

        try checkEmergencyRecovery()
        try checkBodyComfort()

        let hw = MockHardware()
        let live = FanActuator(hw)
        try live.apply([0: 3500], fans: snapshot().fans)
        expect(hw.mode == 1 && hw.target == 3500, "fan is forced to requested RPM")
        try live.restore()
        expect(hw.mode == 0, "release restores automatic mode")
        hw.failTarget = true
        do { try live.apply([0: 3500], fans: snapshot().fans); fatalError("write failure accepted") }
        catch { expect(hw.mode == 0, "partial failure rolls back forced mode") }
        hw.failTarget = false
        try live.apply([0: 3500], fans: snapshot().fans)
        do {
            try live.apply([0: 3600], fans: snapshot(target: 4000, mode: 1).fans)
            fatalError("external change accepted")
        } catch { expect(hw.mode == 0, "external controller conflict releases ownership") }
        try live.apply([0: 3500], fans: snapshot().fans)
        hw.restoreFailures = 2
        try live.restore()
        expect(hw.mode == 0, "transient restoration failures are retried")
        let before = hw.writes.count
        do { try live.apply([0: 3500], fans: snapshot(mode: 1).fans); fatalError("external forced mode accepted") }
        catch { expect(hw.writes.count == before, "does not take over another controller") }

        let delayedHardware = MockHardware()
        delayedHardware.delayReads = 3
        let delayedActuator = FanActuator(delayedHardware)
        try delayedActuator.apply([0: 4100], fans: snapshot().fans)
        expect(delayedHardware.mode == 1 && delayedHardware.target == 4100, "delayed firmware readback does not falsely fail")
        try delayedActuator.restore()
        expect(delayedHardware.mode == 0, "delayed automatic mode restoration is confirmed")

        for delay in [1.25, 2.0] {
            let clock = VirtualClock()
            let hardware = TimedModeHardware(clock: clock, modeDelay: delay)
            let actuator = FanActuator(hardware, now: { clock.time }, pause: clock.advance)
            try actuator.apply([0: 3500], fans: snapshot(target: 0).fans)
            expect(hardware.mode == 1 && hardware.target == 3500 && hardware.targetWrites == 1,
                   "slow mode changes, including success at the deadline, proceed to target writing")
            try actuator.restore()
            expect(hardware.mode == 0, "a delayed mode acquisition still releases normally")
        }
        let timeoutClock = VirtualClock()
        let timeoutHardware = TimedModeHardware(clock: timeoutClock, modeDelay: 2.25)
        let timeoutActuator = FanActuator(timeoutHardware, now: { timeoutClock.time }, pause: timeoutClock.advance)
        var retryFailure: Error?
        do { try timeoutActuator.apply([0: 3500], fans: snapshot(target: 0).fans); fatalError("mode timeout ignored") }
        catch { retryFailure = error }
        expect(retryFailure is RecoverableControlError && timeoutHardware.mode == 0 && timeoutHardware.targetWrites == 0,
               "confirmed rollback makes a mode timeout retryable without writing an unconfirmed target")
        expect(String(describing: retryFailure!).contains("最后读到 F0Md=0"), "timeout message uses the failed confirmation sample")
        var retryLifecycle = ControlLifecycle()
        retryLifecycle.enable(); retryLifecycle.failed(now: 0, retryable: retryFailure is RecoverableControlError)
        expect(retryLifecycle.requested && retryLifecycle.shouldReconnect(now: 10), "mode timeout preserves the switch and schedules reconnection")
        timeoutHardware.modeDelay = 1.25
        try timeoutActuator.apply([0: 3500], fans: snapshot(target: 0).fans)
        expect(timeoutHardware.mode == 1 && timeoutHardware.target == 3500, "the same actuator can acquire control after a transient timeout")
        try timeoutActuator.restore()
        let unsafeClock = VirtualClock()
        let unsafeHardware = TimedModeHardware(clock: unsafeClock, modeDelay: 3)
        unsafeHardware.failRestore = true
        let unsafeActuator = FanActuator(unsafeHardware, now: { unsafeClock.time }, pause: unsafeClock.advance)
        do { try unsafeActuator.apply([0: 3500], fans: snapshot(target: 0).fans); fatalError("rollback failure ignored") }
        catch { expect(!(error is RecoverableControlError), "unconfirmed rollback never permits automatic retry") }

        let request = HelperRequest(token: "test", mode: .manual, manualRPM: 3200)
        var descriptors: [Int32] = [0, 0]
        expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0, "socketpair created")
        defer { close(descriptors[0]); close(descriptors[1]) }
        try SessionIPC.send(request, fd: descriptors[0])
        let decoded = try SessionIPC.receive(HelperRequest.self, fd: descriptors[1])
        expect(decoded.mode == .manual && decoded.manualRPM == 3200, "IPC JSON round trip")
        let recoveryReply = HelperResponse(snapshot: snapshot(), mode: .automatic, targets: [0: 6900],
                                            reason: "recovering", error: nil, coolingPhase: .recovery, bodyCooling: true)
        let decodedRecovery = try JSONDecoder().decode(HelperResponse.self, from: JSONEncoder().encode(recoveryReply))
        expect(decodedRecovery.coolingPhase == .recovery && decodedRecovery.targets[0] == 6900 && decodedRecovery.bodyCooling == true,
               "protective recovery, body cooling and the intermediate target survive IPC encoding")
        let legacyReply = try JSONDecoder().decode(HelperResponse.self, from: Data("{\"mode\":\"system\",\"targets\":{},\"reason\":\"failure\",\"error\":\"hardware failure\"}".utf8))
        expect(legacyReply.coolingPhase == nil, "responses without the new cooling phase still decode")
        do { try legacyReply.checkError(); fatalError("legacy error ignored") }
        catch { expect(!(error is RecoverableControlError), "older responses without an explicit retry flag remain nonretryable") }
        do { _ = try SessionIPC.directory("../../invalid"); fatalError("unsafe session accepted") }
        catch { expect(true, "session path traversal rejected") }

        let session = UUID().uuidString
        let directory = try SessionIPC.directory(session)
        expect(mkdir(directory, 0o700) == 0, "test session directory created")
        let socketPath = directory + "/control.sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener); unlink(socketPath); rmdir(directory) }
        var address = try SessionIPC.address(socketPath)
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        expect(bound == 0 && listen(listener, 4) == 0, "test server listening")
        let ownHash = try CodeIdentity.staticIdentity(URL(fileURLWithPath: CommandLine.arguments[0])).hash
        let identityChecked = DispatchSemaphore(value: 0)
        var authenticatedPID: pid_t?
        var wrongHashRejected = false
        var wrongUIDRejected = false
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            defer { close(client); identityChecked.signal() }
            authenticatedPID = try? CodeIdentity.peer(client, uid: getuid(), hash: ownHash)
            do { _ = try CodeIdentity.peer(client, uid: getuid(), hash: String(repeating: "0", count: 40)) }
            catch { wrongHashRejected = true }
            do { _ = try CodeIdentity.peer(client, uid: getuid() + 1, hash: ownHash) }
            catch { wrongUIDRejected = true }
        }
        let identityClient = try SessionIPC.connect(path: socketPath)
        expect(identityChecked.wait(timeout: .now() + 5) == .success, "kernel peer identity was checked")
        close(identityClient)
        expect(authenticatedPID == getpid(), "audit token authenticates the actual signed peer process")
        expect(wrongHashRejected, "a different executable signature is rejected")
        expect(wrongUIDRejected, "another user cannot connect to the privileged broker")
        let serverHardware = MockHardware()
        let finished = DispatchSemaphore(value: 0)
        var serverError: Error?
        DispatchQueue.global().async {
            do {
                try PrivilegedHelper.serve(listener: listener, parent: getpid(), owner: getuid(), token: "test-token",
                    readSnapshot: { _ in snapshot(target: serverHardware.target, mode: Int(serverHardware.mode)) },
                    actuator: FanActuator(serverHardware), heartbeatTimeout: 0.4)
            } catch { serverError = error }
            finished.signal()
        }
        let reply = try SessionIPC.request(session: session, request: HelperRequest(token: "test-token", mode: .manual, manualRPM: 3300), requireRoot: false)
        expect(reply.error == nil && reply.mode == .manual && reply.targets[0] == 3300, "authenticated server applies manual command")
        expect(finished.wait(timeout: .now() + 4) == .success, "server exits after heartbeat expires")
        expect(serverError == nil, "watchdog exits cleanly")
        expect(serverHardware.mode == 0, "heartbeat loss restores hardware to system control")

        let faultHardware = MockHardware()
        let faultReached = DispatchSemaphore(value: 0), faultFinished = DispatchSemaphore(value: 0)
        var faultError: Error?
        DispatchQueue.global().async {
            var controlledReads = 0
            do {
                try PrivilegedHelper.serve(listener: listener, parent: getpid(), owner: getuid(), token: "test-token",
                    readSnapshot: { required in
                        if required {
                            controlledReads += 1
                            if controlledReads >= 3 {
                                faultReached.signal()
                                throw SamplingError("simulated CPU sensor failure")
                            }
                        }
                        return snapshot(target: faultHardware.target, mode: Int(faultHardware.mode))
                    }, actuator: FanActuator(faultHardware))
            } catch { faultError = error }
            faultFinished.signal()
        }
        _ = try SessionIPC.request(session: session, request: HelperRequest(token: "test-token", mode: .automatic, manualRPM: 3300), requireRoot: false)
        expect(faultReached.wait(timeout: .now() + 5) == .success, "background sensor failure occurs between UI heartbeats")
        let faultReply = try SessionIPC.request(session: session, request: HelperRequest(token: "test-token", mode: .automatic, manualRPM: 3300), requireRoot: false)
        expect(faultReply.error?.contains("simulated CPU sensor failure") == true && faultReply.mode == .system,
               "background hardware failure reaches the UI instead of looking like a transient disconnect")
        expect(faultFinished.wait(timeout: .now() + 2) == .success && faultError != nil && faultHardware.mode == 0,
               "fatal fault releases hardware and terminates after reporting the real cause")
        expect(faultReply.retryable == false, "sensor failure is not misclassified as a retryable mode transition")

        let ipcClock = VirtualClock()
        let ipcHardware = TimedModeHardware(clock: ipcClock, modeDelay: 3)
        let retryFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { retryFinished.signal() }
            try? PrivilegedHelper.serve(listener: listener, parent: getpid(), owner: getuid(), token: "test-token",
                readSnapshot: { _ in snapshot(target: ipcHardware.target, mode: Int(ipcHardware.mode)) },
                actuator: FanActuator(ipcHardware, now: { ipcClock.time }, pause: ipcClock.advance))
        }
        let retryReply = try SessionIPC.request(session: session, request: HelperRequest(token: "test-token", mode: .automatic, manualRPM: 3300), requireRoot: false)
        expect(retryReply.retryable == true && retryReply.mode == .system, "helper carries confirmed mode-timeout recovery over real IPC")
        do { try retryReply.checkError(); fatalError("retryable response ignored") }
        catch { expect(error is RecoverableControlError, "app response handling preserves the helper's recoverable classification") }
        expect(retryFinished.wait(timeout: .now() + 2) == .success && ipcHardware.mode == 0,
               "retryable session exits cleanly with system control restored")

        let refreshHardware = MockHardware()
        let refreshFinished = DispatchSemaphore(value: 0)
        var fullScans = 0, fanRefreshes = 0
        var refreshError: Error?
        DispatchQueue.global().async {
            defer { refreshFinished.signal() }
            do {
                try PrivilegedHelper.serve(listener: listener, parent: getpid(), owner: getuid(), token: "test-token",
                    readSnapshot: { _ in
                        fullScans += 1
                        return snapshot(target: refreshHardware.target, mode: Int(refreshHardware.mode))
                    }, actuator: FanActuator(refreshHardware), refreshFans: { previous in
                        fanRefreshes += 1
                        return ThermalSnapshot(timestamp: previous.timestamp, temperatures: previous.temperatures,
                            fans: snapshot(target: refreshHardware.target, mode: Int(refreshHardware.mode)).fans,
                            powerSource: previous.powerSource, isCharging: previous.isCharging, thermalPressure: previous.thermalPressure)
                    })
            } catch { refreshError = error }
        }
        let refreshReply = try SessionIPC.request(session: session, request: HelperRequest(token: "test-token", mode: .manual, manualRPM: 3300), requireRoot: false)
        expect(refreshReply.error == nil && refreshReply.snapshot?.fans.first?.target == 3300,
               "fan-only confirmation returns the freshly applied target")
        let releaseReply = try SessionIPC.request(session: session, request: HelperRequest(token: "test-token", mode: .system, manualRPM: 3300), requireRoot: false)
        expect(refreshFinished.wait(timeout: .now() + 2) == .success && refreshError == nil,
               "fan-only release confirmation exits cleanly")
        expect(fullScans == 2 && fanRefreshes == 2 && releaseReply.snapshot?.fans.first?.mode == 0,
               "control and release confirmations avoid duplicate full sensor scans")

        let stoppedHardware = MockHardware()
        let stoppedFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var exitRequested = false
            defer { stoppedFinished.signal() }
            try? PrivilegedHelper.serve(listener: listener, parent: getpid(), owner: getuid(), token: "test-token",
                readSnapshot: { required in
                    if required { exitRequested = true }
                    return snapshot(target: stoppedHardware.target, mode: Int(stoppedHardware.mode))
                }, actuator: FanActuator(stoppedHardware), shouldStop: { exitRequested })
        }
        let stoppedReply = try SessionIPC.request(session: session, request: HelperRequest(token: "test-token", mode: .automatic, manualRPM: 3300), requireRoot: false)
        expect(stoppedFinished.wait(timeout: .now() + 2) == .success && stoppedReply.retryable == true,
               "a stop arriving during a sensor scan returns a recoverable interruption")
        expect(stoppedHardware.writes.isEmpty, "an exiting helper never starts new fan writes after the scan returns")

        var sessions: [MockSessionProcess] = []
        var peers: [pid_t] = []
        let broker = ServiceBroker { _, _, pid in
            let session = MockSessionProcess(); sessions.append(session); peers.append(pid); return session
        }
        let token = String(repeating: "a", count: 64)
        let begin = ServiceRequest(action: .start, session: UUID().uuidString, token: token)
        try broker.handle(ServiceRequest(action: .status), peer: 321)
        expect(sessions.isEmpty, "service status never starts fan control")
        try broker.handle(begin, peer: 321)
        try broker.handle(begin, peer: 321)
        expect(sessions.count == 1 && peers == [321], "duplicate session start is idempotent and uses authenticated peer")
        do {
            try broker.handle(ServiceRequest(action: .stop, session: begin.session, token: token), peer: 322)
            fatalError("another app stopped the session")
        } catch { expect(sessions[0].stopRequests == 0, "another PID cannot request release") }
        do {
            try broker.handle(ServiceRequest(action: .stop, session: begin.session, token: String(repeating: "b", count: 64)), peer: 321)
            fatalError("wrong token stopped the session")
        } catch { expect(sessions[0].stopRequests == 0, "release checks the session token") }
        try broker.handle(ServiceRequest(action: .stop, session: UUID().uuidString, token: token), peer: 321)
        expect(sessions[0].stopRequests == 0, "stale release does not stop a newer session")
        do {
            try broker.handle(ServiceRequest(action: .start, session: UUID().uuidString, token: token), peer: 321)
            fatalError("overlapping session accepted")
        } catch {
            expect(error is RecoverableControlError && sessions.count == 1 && sessions[0].isRunning && sessions[0].stopRequests == 1,
                   "same authenticated app requests graceful release and waits without creating overlapping sessions")
            let encoded = try JSONEncoder().encode(ServiceResponse(version: ServicePaths.protocolVersion,
                                                                   error: String(describing: error), retryable: true))
            do { try JSONDecoder().decode(ServiceResponse.self, from: encoded).checkError(); fatalError("busy response ignored") }
            catch { expect(error is RecoverableControlError, "broker busy classification survives wire encoding and client checking") }
        }
        try broker.handle(ServiceRequest(action: .stop, session: begin.session, token: token), peer: 321)
        expect(sessions[0].stopRequests == 1, "duplicate release requests do not repeatedly signal an exiting session")
        do { try broker.handle(begin, peer: 321); fatalError("retiring session reported connected") }
        catch { expect(error is RecoverableControlError, "a retiring session cannot reconnect as though still active") }
        var busyLifecycle = ControlLifecycle()
        busyLifecycle.enable()
        let replacement = ServiceRequest(action: .start, session: UUID().uuidString, token: token)
        for attempt in 0..<6 {
            do { try broker.handle(replacement, peer: 321); fatalError("slow old session replaced prematurely") }
            catch {
                busyLifecycle.failed(now: Double(attempt * 60), retryable: error is RecoverableControlError)
                expect(busyLifecycle.requested && sessions.count == 1 && sessions[0].stopRequests == 1,
                       "more than three busy replies keep monitoring and never force takeover")
            }
        }
        do { try broker.handle(begin, peer: 322); fatalError("another app took over the session") }
        catch { expect(!(error is RecoverableControlError) && sessions.count == 1 && sessions[0].isRunning,
                       "second app is rejected without retrying or stopping active control") }
        do {
            try broker.handle(ServiceRequest(action: .start, session: "../../bad", token: token), peer: 321)
            fatalError("invalid session path accepted")
        } catch { expect(sessions[0].isRunning, "malformed requests leave current session intact") }
        sessions[0].stop()
        try broker.handle(replacement, peer: 321)
        expect(sessions.count == 2 && sessions[1].isRunning, "persistent broker accepts a new app after old app exits")
        busyLifecycle.connected(now: 400)
        expect(busyLifecycle.requested && busyLifecycle.retryAt == nil, "long busy recovery finishes without reopening the switch")
        try broker.handle(ServiceRequest(action: .stop, session: begin.session, token: token), peer: 321)
        expect(sessions[1].stopRequests == 0, "late old-session cleanup never terminates the replacement")
        try broker.handle(ServiceRequest(action: .stop, session: replacement.session, token: token), peer: 321)
        expect(sessions[1].stopRequests == 1 && sessions[1].isRunning, "matching release asks for graceful exit without assuming it finished")
        broker.stop()
        expect(!sessions[1].isRunning, "service shutdown stops its active session")
        do {
            try broker.handle(ServiceRequest(action: .start, session: UUID().uuidString, token: "invalid"), peer: 322)
            fatalError("invalid token accepted")
        } catch { expect(sessions.count == 2, "invalid tokens cannot launch a privileged process") }
        print("Passed \(checks) control, recovery and IPC checks. No hardware writes performed.")
    }
}
