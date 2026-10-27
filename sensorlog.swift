// Read-only AppleSMC sampling. No fan-control or SMC write commands.
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

final class ReadOnlySMC {
    private var connection: io_connect_t = 0
    init() throws {
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
        precondition([5, 8, 9].contains(input.command), "Only read commands are permitted")
        var output = Parameter()
        var size = MemoryLayout<Parameter>.stride
        let result = withUnsafePointer(to: &input) {
            IOConnectCallStructMethod(connection, 2, $0, MemoryLayout<Parameter>.stride, &output, &size)
        }
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SamplingError("SMC 读取失败：kern=\(result), result=\(output.result)")
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
        let info = try call(&input).info
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

func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return formatter.string(from: date)
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") {
        print("""
        只读温度记录（不会控制风扇）
        ./record-sample.sh --feeling comfortable|warm|hot|cold|unknown --note '体感、位置、负载等'
        可选：--out /绝对路径/samples.jsonl
        默认体感 unknown；只有你明确描述的体感才应写入记录。
        """)
        return
    }
    var options: [String: String] = [:]
    var index = 0
    while index < args.count {
        let key = args[index]
        guard ["--feeling", "--note", "--out"].contains(key), index + 1 < args.count,
              options[key] == nil else { throw SamplingError("无效或重复参数：\(key)，请使用 --help") }
        options[key] = args[index + 1]
        index += 2
    }
    let feeling = options["--feeling"] ?? "unknown"
    guard ["comfortable", "warm", "hot", "cold", "unknown"].contains(feeling) else {
        throw SamplingError("无效体感标签：\(feeling)")
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let defaultPath = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("observations/samples.jsonl").path
    let destination = URL(fileURLWithPath: options["--out"] ?? defaultPath)
    let start = Date()
    let smc = try ReadOnlySMC()
    let rawCount = try smc.read("#KEY").value
    guard rawCount >= 1, rawCount <= 100_000, rawCount.rounded() == rawCount else {
        throw SamplingError("SMC key 数量不合理：\(rawCount)")
    }
    let count = Int(rawCount)
    var temperatures: [String: Double] = [:]
    var types: [String: String] = [:]
    var unreadableIndices: [Int] = []
    var skippedKeys: [String] = []
    for i in 0..<count {
        guard let key = try? smc.key(at: i) else { unreadableIndices.append(i); continue }
        guard key.hasPrefix("T") else { continue }
        guard let reading = try? smc.read(key), reading.value > 0.1, reading.value < 125 else {
            skippedKeys.append(key)
            continue
        }
        temperatures[key] = (reading.value * 1000).rounded() / 1000
        types[key] = reading.type
    }
    guard !temperatures.isEmpty else { throw SamplingError("没有可读温度，未写入记录") }
    var fans: [[String: Any]] = []
    if let n = smc.value("FNum"), n >= 0, n <= 16, n.rounded() == n {
        for i in 0..<Int(n) {
            var fan: [String: Any] = ["index": i]
            fan["actual_rpm"] = smc.value("F\(i)Ac")
            fan["target_rpm"] = smc.value("F\(i)Tg")
            fan["mode_raw"] = smc.value("F\(i)Md")
            fans.append(fan)
        }
    }
    let record: [String: Any] = [
        "schema_version": 1, "id": UUID().uuidString,
        "captured_at": timestamp(start), "completed_at": timestamp(Date()),
        "source": "sensorlog_live_smc", "feeling": feeling,
        "note": options["--note"] ?? "", "temperature_c": temperatures,
        "smc_types": types, "fans": fans, "power": powerContext(),
        "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        "smc_key_count": count, "unreadable_indices": unreadableIndices,
        "skipped_temperature_keys": skippedKeys,
        "interpretation": "T-prefixed numeric candidates; physical locations and derived values are unverified."
    ]
    var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(0x0a)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else { throw SamplingError("无法打开记录文件：\(String(cString: strerror(errno)))") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw SamplingError("无法锁定记录文件") }
    defer { flock(descriptor, LOCK_UN) }
    try data.withUnsafeBytes { raw in
        var written = 0
        while written < raw.count {
            let result = write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw SamplingError("记录写入失败：\(String(cString: strerror(errno)))") }
            written += result
        }
    }
    guard fsync(descriptor) == 0 else { throw SamplingError("记录持久化失败") }
    print("已记录 \(temperatures.count) 个温度数据项；体感：\(feeling)")
    for key in ["Ts0P", "Ts1P", "TB0T", "TB1T", "TB2T", "TH0T"] {
        if let value = temperatures[key] { print(String(format: "  %@: %.1f°C", key, value)) }
    }
    for fan in fans { print("  风扇 \(fan["index"]!): \(fan["actual_rpm"] ?? "未知") RPM") }
    print("保存于：\(destination.path)")
}

do { try main() } catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(1)
}
