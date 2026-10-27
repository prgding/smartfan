import Foundation
import IOKit.ps

enum FanMode: String, Codable { case system, automatic, manual }

struct FanReading: Codable {
    let index: Int
    let minimum: Double
    let maximum: Double
    let actual: Double
    let target: Double
    let mode: Int
}

struct ThermalSnapshot: Codable {
    let timestamp: Date
    let temperatures: [String: Double]
    let fans: [FanReading]
    let powerSource: String
    let isCharging: Bool?
    let thermalPressure: Int

    var primary: Double? { temperatures["Ts1P"] }
    var secondary: Double? { temperatures["Ts0P"] }
    var battery: Double? { ["TB0T", "TB1T", "TB2T"].compactMap { temperatures[$0] }.max() }
    var cpu: Double? {
        temperatures.filter { $0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te") }.values.max()
    }
    var controlReady: Bool { primary != nil && battery != nil && cpu != nil && !fans.isEmpty }
}

final class SensorReader {
    let smc: SMCConnection
    private var keys: [String] = []
    private var cpuKeys: Set<String> = []
    private var batteryKeys: Set<String> = []
    init(smc: SMCConnection) throws {
        self.smc = smc
        guard let count = smc.value("#KEY"), count > 0, count < 100_000 else {
            throw SamplingError("无法枚举温度传感器")
        }
        for i in 0..<Int(count) {
            if let key = try? smc.key(at: i), key.hasPrefix("T"),
               let value = smc.value(key), value > 0.1, value < 125 { keys.append(key) }
        }
        cpuKeys = Set(keys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") })
        batteryKeys = Set(keys.filter { ["TB0T", "TB1T", "TB2T"].contains($0) })
        guard !keys.isEmpty else { throw SamplingError("没有可读温度") }
    }

    func snapshot(requireControlSensors: Bool = false) throws -> ThermalSnapshot {
        var temperatures: [String: Double] = [:]
        for key in keys {
            if let value = smc.value(key), value > 0.1, value < 125 { temperatures[key] = value }
        }
        guard !temperatures.isEmpty else { throw SamplingError("温度读取失败") }
        // A missing hot CPU sensor must not silently lower the aggregate temperature.
        if requireControlSensors && (cpuKeys.isEmpty || !cpuKeys.isSubset(of: Set(temperatures.keys))) {
            throw SamplingError("CPU 温度读取不完整，已停止接管")
        }
        if requireControlSensors && (batteryKeys.isEmpty || !batteryKeys.isSubset(of: Set(temperatures.keys))) {
            throw SamplingError("电池温度读取不完整，已停止接管")
        }
        let fans = try fanReadings()
        let power = powerContext()
        let result = ThermalSnapshot(timestamp: Date(), temperatures: temperatures, fans: fans,
                                     powerSource: power["source"] as? String ?? "未知",
                                     isCharging: power["is_charging"] as? Bool,
                                     thermalPressure: ProcessInfo.processInfo.thermalState.rawValue)
        if requireControlSensors && !result.controlReady { throw SamplingError("体感或电池传感器缺失，已停止接管") }
        return result
    }

    // Target confirmation needs fresh fan readings, not another full temperature/power scan.
    // Preserve the temperature timestamp so fan refreshes never make old samples look fresh.
    func refreshingFans(in snapshot: ThermalSnapshot) throws -> ThermalSnapshot {
        ThermalSnapshot(timestamp: snapshot.timestamp, temperatures: snapshot.temperatures,
                        fans: try fanReadings(), powerSource: snapshot.powerSource,
                        isCharging: snapshot.isCharging, thermalPressure: snapshot.thermalPressure)
    }

    private func fanReadings() throws -> [FanReading] {
        var fans: [FanReading] = []
        guard let count = smc.value("FNum"), count >= 0, count <= 16 else {
            throw SamplingError("无法读取风扇数量")
        }
        for index in 0..<Int(count) {
            guard let minimum = smc.value("F\(index)Mn"), let maximum = smc.value("F\(index)Mx"),
                  let actual = smc.value("F\(index)Ac"), let target = smc.value("F\(index)Tg"),
                  let mode = smc.value("F\(index)Md"), minimum >= 0, maximum > minimum,
                  maximum < 30000, actual >= 0 else { throw SamplingError("风扇状态读取失败") }
            fans.append(FanReading(index: index, minimum: minimum, maximum: maximum,
                                   actual: actual, target: target, mode: Int(mode)))
        }
        return fans
    }
}

struct HelperRequest: Codable {
    let token: String
    let mode: FanMode
    let manualRPM: Double
}
struct HelperResponse: Codable {
    let snapshot: ThermalSnapshot?
    let mode: FanMode
    let targets: [Int: Double]
    let reason: String
    let error: String?
    var retryable: Bool? = nil

    func checkError() throws {
        guard let error else { return }
        if retryable == true { throw RecoverableControlError(error) }
        throw SamplingError(error)
    }
}

// Used for confirmed rollback or the same authenticated app's old session still exiting.
struct RecoverableControlError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { max(lower, min(upper, value)) }
