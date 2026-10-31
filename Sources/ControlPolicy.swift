import Foundation

// Provisional comfort curves based on user-labelled samples. Temperatures are not surface measurements.
struct ControlPolicy {
    static let normalMaximumRPM = 5000.0

    static func normalMaximum(for fan: FanReading) -> Double {
        max(fan.minimum, min(fan.maximum, normalMaximumRPM))
    }

    private var smoothedPrimary: Double?
    private var smoothedBattery: Double?
    private var lastTime: Double?
    private var lastMode: FanMode?
    private var previousTargets: [Int: Double] = [:]
    private var downSince: [Int: Double] = [:]
    private var coldSince: Double?
    private var inStandby = false
    private var emergencyCoolSince: Double?
    private(set) var coolingPhase: CoolingPhase = .normal
    private var bodyCoolSince: Double?
    private(set) var bodyCooling = false

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
        let sampleGap = lastTime.map { now - $0 }
        let continuous = sampleGap.map { $0 >= 0 && $0 <= 6 } ?? true
        let elapsed = sampleGap.map { max(0.1, min(10, $0)) } ?? 2
        let alpha = 1 - exp(-elapsed / 8)
        let oldPrimary = smoothedPrimary ?? primary
        let oldBattery = smoothedBattery ?? battery
        let p = oldPrimary + alpha * (primary - oldPrimary)
        let b = oldBattery + alpha * (battery - oldBattery)
        let predictedP = max(p, primary) + min(1.5, max(0, (p - oldPrimary) / elapsed) * 30)
        let predictedB = max(b, battery) + min(2.0, max(0, (b - oldBattery) / elapsed) * 60)
        // Charging adds heat before the battery reference catches up. These are
        // empirical comfort references, not measurements of the palm-rest surface.
        let comfortBattery = predictedB + (snapshot.isCharging == true ? 0.5 : 0)
        smoothedPrimary = p; smoothedBattery = b; lastTime = now
        if lastMode != mode {
            downSince.removeAll()
            // Changing tabs or the manual setpoint must not bypass protective cooling.
            if coolingPhase == .normal { previousTargets.removeAll() }
            lastMode = mode
            coldSince = nil; inStandby = false
        }

        let emergency = cpu >= 92 || snapshot.thermalPressure >= 2
        if emergency {
            coolingPhase = .emergency; emergencyCoolSince = nil
        } else if coolingPhase == .emergency {
            // Separate entry/exit thresholds prevent rapid switching around 92°C.
            // A sampling gap cannot count as evidence of sustained cooling.
            if !continuous { emergencyCoolSince = nil }
            if cpu <= 86 && snapshot.thermalPressure == 0 {
                if emergencyCoolSince == nil { emergencyCoolSince = now }
                if now - emergencyCoolSince! >= 15 {
                    coolingPhase = .recovery; emergencyCoolSince = nil
                    downSince.removeAll()
                }
            } else { emergencyCoolSince = nil }
        }
        if mode == .automatic {
            let warmBody = predictedP >= 30 || comfortBattery >= 33 || (snapshot.secondary.map { $0 >= 31.5 } ?? false)
            let coolBody = predictedP <= 29 && comfortBattery <= 32 &&
                (snapshot.secondary.map { $0 <= 31 } ?? true) && snapshot.thermalPressure == 0
            if warmBody {
                bodyCooling = true; bodyCoolSince = nil
            } else if bodyCooling {
                if !continuous { bodyCoolSince = nil }
                if coolBody {
                    if bodyCoolSince == nil { bodyCoolSince = now }
                    if now - bodyCoolSince! >= 120 { bodyCooling = false; bodyCoolSince = nil }
                } else { bodyCoolSince = nil }
            }
        } else {
            // Manual control cannot silently accumulate time toward automatic release.
            bodyCoolSince = nil
        }
        // User-labelled cold sample: Ts1P ≈ 27°C, battery ≈ 29.4°C.
        // Standby keeps the automatic session alive; firmware decides whether to stop.
        if mode == .automatic && coolingPhase == .normal && !bodyCooling {
            let cold = predictedP <= 28 && predictedB <= 30.5 && cpu < 70 && snapshot.thermalPressure == 0
            let needsCooling = predictedP >= 29 || predictedB >= (snapshot.isCharging == true ? 31 : 32) ||
                cpu >= 75 || snapshot.thermalPressure >= 1
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
        } else { inStandby = false; coldSince = nil }
        // The latest warm samples include Ts1P ≈29, Ts0P ≈32 and battery 33.9–34.8°C
        // with a cool CPU. Start earlier and keep airflow until body references settle.
        let comfortP = Self.interpolate(predictedP, points: [(27.5, 1200), (28, 1800), (29, 3200), (30, 5000)])
        let comfortB = Self.interpolate(comfortBattery, points: [(30.5, 1200), (31, 2200), (32, 3800), (32.5, 4500), (33, 5000)])
        let comfortS = snapshot.secondary.map {
            Self.interpolate($0, points: [(29, 1200), (30, 2000), (31, 3500), (31.5, 5000)])
        } ?? 0
        let comfortable = predictedP <= 29 && comfortBattery <= 32 && (snapshot.secondary.map { $0 <= 31 } ?? true)
        let protection = Self.interpolate(cpu, points: [(60, 1200), (70, 2400), (80, 4000), (85, 5400), (90, 8000)])
        let comfort = max(max(comfortP, comfortB), max(comfortS, bodyCooling ? Self.normalMaximumRPM : 0))
        let base = mode == .manual ? manualRPM : comfort
        let requested = max(base, protection)
        var result: [Int: Double] = [:]
        for fan in snapshot.fans {
            let normalCeiling = Self.normalMaximum(for: fan)
            let ceiling = coolingPhase == .normal ? normalCeiling : fan.maximum
            let desired = clamp(requested, fan.minimum, normalCeiling)
            let previous = clamp(previousTargets[fan.index] ?? fan.actual, fan.minimum, fan.maximum)
            let next: Double
            if coolingPhase == .emergency {
                next = fan.maximum
                downSince[fan.index] = nil
            } else if coolingPhase == .recovery && previous > normalCeiling {
                // Above 5000 RPM only while finishing protective cooling. Pause
                // descent on a rebound; a fresh emergency still goes full speed.
                let canDescend = continuous && cpu < 88 && snapshot.thermalPressure == 0
                next = canDescend ? max(normalCeiling, previous - 150 * min(elapsed, 2)) : previous
                downSince[fan.index] = nil
            } else if protection > previous {
                next = max(desired, min(protection, normalCeiling))
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
            result[fan.index] = clamp(next, fan.minimum, ceiling)
        }
        previousTargets = result
        if coolingPhase == .recovery && snapshot.fans.allSatisfy({ result[$0.index]! <= Self.normalMaximum(for: $0) }) {
            coolingPhase = .normal; downSince.removeAll()
        }
        let reason: String
        switch coolingPhase {
        case .emergency: reason = "过热保护 · 全速冷却，等待温度稳定"
        case .recovery:
            reason = cpu >= 88 || snapshot.thermalPressure > 0 ? "过热后恢复 · 温度回升，暂缓降速" : "过热后恢复 · 平稳降回 5000 RPM"
        case .normal:
            if mode == .automatic && bodyCooling { reason = "机身积热散热 · 等待电池与掌托参考稳定降温" }
            else if min(protection, Self.normalMaximumRPM) > min(base, Self.normalMaximumRPM) { reason = "CPU 保护正在提高转速" }
            else if mode == .manual { reason = "手动转速" }
            else if comfortable && requested <= 2000 { reason = "低速维持 · 持续自动调节" }
            else if comfortB >= max(comfortP, comfortS) { reason = snapshot.isCharging == true ? "提前散热 · 充电预冷与电池温度" : "提前散热 · 电池温度" }
            else { reason = "提前散热 · 掌托温度参考" }
        }
        return (result, reason, false)
    }
}
