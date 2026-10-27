import Foundation

// Provisional comfort curves based on user-labelled samples. Temperatures are not surface measurements.
struct ControlPolicy {
    private var smoothedPrimary: Double?
    private var smoothedBattery: Double?
    private var lastTime: Double?
    private var lastMode: FanMode?
    private var previousTargets: [Int: Double] = [:]
    private var downSince: [Int: Double] = [:]
    private var coldSince: Double?
    private var inStandby = false

    static func interpolate(_ temperature: Double, points: [(Double, Double)]) -> Double {
        if temperature <= points[0].0 { return points[0].1 }
        for index in 1..<points.count where temperature <= points[index].0 {
            let a = points[index - 1], b = points[index]
            return a.1 + (temperature - a.0) / (b.0 - a.0) * (b.1 - a.1)
        }
        return points.last!.1
    }

    mutating func targets(snapshot: ThermalSnapshot, mode: FanMode, manualRPM: Double,
                          now: Double) throws -> (values: [Int: Double], reason: String, standby: Bool) {
        guard snapshot.controlReady, let primary = snapshot.primary,
              let battery = snapshot.battery, let cpu = snapshot.cpu,
              manualRPM.isFinite else { throw SamplingError("控制所需传感器或转速无效") }
        let elapsed = lastTime.map { max(0.1, min(10, now - $0)) } ?? 2
        let alpha = 1 - exp(-elapsed / 8)
        let oldPrimary = smoothedPrimary ?? primary
        let oldBattery = smoothedBattery ?? battery
        let p = oldPrimary + alpha * (primary - oldPrimary)
        let b = oldBattery + alpha * (battery - oldBattery)
        let predictedP = max(p, primary) + min(1.5, max(0, (p - oldPrimary) / elapsed) * 30)
        let predictedB = max(b, battery) + min(2.0, max(0, (b - oldBattery) / elapsed) * 60)
        smoothedPrimary = p; smoothedBattery = b; lastTime = now
        if lastMode != mode {
            downSince.removeAll(); previousTargets.removeAll(); lastMode = mode
            coldSince = nil; inStandby = false
        }

        let emergency = cpu >= 92 || snapshot.thermalPressure >= 2
        // User-labelled cold sample: Ts1P ≈ 27°C, battery ≈ 29.4°C.
        // Standby keeps the automatic session alive; firmware decides whether to stop.
        if mode == .automatic {
            let cold = predictedP <= 28 && predictedB <= 30.5 && cpu < 70 && snapshot.thermalPressure == 0
            let needsCooling = predictedP >= 29 || predictedB >= 32 || cpu >= 75 || snapshot.thermalPressure >= 1
            if inStandby && needsCooling { inStandby = false; coldSince = nil }
            if !inStandby {
                if cold {
                    if coldSince == nil { coldSince = now }
                    if now - coldSince! >= 20 { inStandby = true }
                } else { coldSince = nil }
            }
            if inStandby {
                previousTargets.removeAll(); downSince.removeAll()
                return ([:], "低温待机 · 持续监测，升温自动接管", true)
            }
        }
        // The user reported comfort at Ts1P ≈ 30°C and battery ≈ 33.6°C.
        // Stay in automatic mode at low speed here; rising readings/trends increase cooling again.
        let comfortP = Self.interpolate(predictedP, points: [(30, 1200), (30.5, 2600), (31, 4000), (32, 5400), (33, 6400), (35, 8000)])
        let comfortB = Self.interpolate(predictedB, points: [(33.8, 1200), (34.2, 2600), (34.6, 4000), (34.8, 5000), (36, 6000), (37, 6400), (39, 8000)])
        let comfortable = predictedP <= 30 && predictedB <= 33.8
        let protection = Self.interpolate(cpu, points: [(60, 1200), (70, 2400), (80, 4000), (85, 5400), (90, 8000)])
        let base = mode == .manual ? manualRPM : max(comfortP, comfortB)
        let requested = max(base, protection)
        var result: [Int: Double] = [:]
        for fan in snapshot.fans {
            let desired = emergency ? fan.maximum : clamp(requested, fan.minimum, fan.maximum)
            let previous = previousTargets[fan.index] ?? max(fan.actual, fan.minimum)
            let next: Double
            if emergency || protection > previous {
                next = max(desired, min(protection, fan.maximum))
                downSince[fan.index] = nil
            } else if mode == .manual {
                next = desired
            } else if desired >= previous {
                next = min(desired, previous + 400 * elapsed)
                downSince[fan.index] = nil
            } else {
                if downSince[fan.index] == nil { downSince[fan.index] = now }
                let delay = comfortable ? 10.0 : 45.0
                let rate = comfortable ? 200.0 : 100.0
                next = now - downSince[fan.index]! >= delay ? max(desired, previous - rate * elapsed) : previous
            }
            result[fan.index] = clamp(next, fan.minimum, fan.maximum)
        }
        previousTargets = result
        let reason = emergency ? "过热保护 · 最高转速" :
            (mode == .automatic && comfortable && requested <= 2000 ? "低速维持 · 持续自动调节" :
                (protection > base ? "CPU 保护正在提高转速" : (mode == .manual ? "手动转速" : "提前散热 · 体感与电池温度")))
        return (result, reason, false)
    }
}
