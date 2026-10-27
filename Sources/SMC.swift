// AppleSMC transport shared by the menu app and its session-scoped helper.
import Foundation
import IOKit
import IOKit.ps
import Darwin

typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct Limits { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0 }
struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }
struct Parameter {
    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var index: UInt32 = 0
    var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SamplingError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
func keyText(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }, encoding: .ascii) ?? "????"
}

final class SMCConnection {
    private let writable: Bool
    private var infoCache: [UInt32: KeyInfo] = [:]
    private var connection: io_connect_t = 0
    init(writable: Bool = false) throws {
        self.writable = writable
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SamplingError("找不到 AppleSMC 服务") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw SamplingError("无法读取 AppleSMC（\(result)）；沙箱可能阻止硬件访问。")
        }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout Parameter) throws -> Parameter {
        precondition([5, 8, 9].contains(input.command) || (writable && input.command == 6))
        var output = Parameter()
        var size = MemoryLayout<Parameter>.stride
        let result = withUnsafePointer(to: &input) {
            IOConnectCallStructMethod(connection, 2, $0, MemoryLayout<Parameter>.stride, &output, &size)
        }
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SamplingError("SMC \(input.command == 6 ? "写入" : "读取")失败 [\(keyText(input.key))]：kern=\(result), result=\(output.result)")
        }
        return output
    }

    func key(at index: Int) throws -> String {
        var input = Parameter()
        input.command = 8
        input.index = UInt32(index)
        return keyText(try call(&input).key)
    }

    func read(_ key: String) throws -> (type: String, value: Double) {
        var input = Parameter()
        input.key = fourCC(key)
        input.command = 9
        let info: KeyInfo
        if let cached = infoCache[input.key] { info = cached } else {
            info = try call(&input).info
            infoCache[input.key] = info
        }
        guard info.size <= 32 else { throw SamplingError("\(key)：数据长度不支持") }
        input.info.size = info.size
        input.command = 5
        let output = try call(&input)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        let type = keyText(info.type)
        let value: Double
        switch type {
        case "flt " where bytes.count >= 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        case "sp78" where bytes.count >= 2:
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count >= 2:
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 " where bytes.count >= 1:
            value = Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            value = Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si16" where bytes.count >= 2:
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        default: throw SamplingError("\(key)：无法解码 \(type)")
        }
        guard value.isFinite else { throw SamplingError("\(key)：非有限值") }
        return (type, value)
    }

    func value(_ key: String) -> Double? { try? read(key).value }

    // Only the privileged helper can write. No arbitrary keys or raw writes are exposed over IPC.
    func writeFan(index: Int, suffix: String, value: Double) throws {
        guard writable, geteuid() == 0, (0..<16).contains(index),
              ["Md", "Tg"].contains(suffix), value.isFinite else {
            throw SamplingError("风扇写入未授权")
        }
        let key = "F\(index)\(suffix)"
        var input = Parameter()
        input.key = fourCC(key)
        input.command = 9
        let info = try call(&input).info
        let type = keyText(info.type)
        var bytes: [UInt8]
        switch type {
        case "flt " where info.size == 4:
            let bits = Float(value).bitPattern
            bytes = [0, 8, 16, 24].map { UInt8((bits >> $0) & 255) }
        case "ui8 " where info.size == 1:
            guard value >= 0, value <= 255 else { throw SamplingError("无效控制值") }
            bytes = [UInt8(value)]
        case "fpe2" where info.size == 2:
            guard value >= 0, value < 16384 else { throw SamplingError("转速超出范围") }
            let bits = UInt16(value * 4)
            bytes = [UInt8(bits >> 8), UInt8(bits & 255)]
        default: throw SamplingError("不支持此风扇的写入格式：\(type)")
        }
        input.command = 6
        input.info.size = info.size
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        _ = try call(&input)
    }

}

func powerContext() -> [String: Any] {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return [:] }
    var context: [String: Any] = [:]
    if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
        context["source"] = source as String
    }
    if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(),
                  let details = raw as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            context["is_charging"] = details[kIOPSIsChargingKey]
            if let current = details[kIOPSCurrentCapacityKey] as? Int,
               let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                context["battery_percent"] = Double(current) / Double(maximum) * 100
            }
        }
    }
    return context
}

