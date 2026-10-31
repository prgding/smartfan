import Foundation
import Darwin

protocol FanHardware: AnyObject {
    func set(index: Int, suffix: String, value: Double) throws
    func value(index: Int, suffix: String) -> Double?
}
extension SMCConnection: FanHardware {
    func set(index: Int, suffix: String, value: Double) throws { try writeFan(index: index, suffix: suffix, value: value) }
    func value(index: Int, suffix: String) -> Double? { value("F\(index)\(suffix)") }
}

private struct ModeConfirmationTimeout: Error, CustomStringConvertible {
    let description: String
}

final class FanActuator {
    private let hardware: FanHardware
    private var owned: Set<Int> = []
    private var lastTargets: [Int: Double] = [:]
    private let now: () -> Double
    private let pause: (Double) -> Void
    init(_ hardware: FanHardware,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.hardware = hardware; self.now = now; self.pause = pause
    }

    private func waitForReadback(index: Int, suffix: String, expected: Double, tolerance: Double = 0,
                                 timeout: Double = 1.0) -> (confirmed: Bool, lastValue: Double?) {
        let deadline = now() + timeout
        while true {
            let value = hardware.value(index: index, suffix: suffix)
            if let value, abs(value - expected) <= tolerance { return (true, value) }
            let remaining = deadline - now()
            // Read once at the deadline too: sleeping across it must not discard success.
            if remaining <= 0 { return (false, value) }
            pause(min(0.05, remaining))
        }
    }

    private func readbackDescription(index: Int) -> String {
        let mode = hardware.value(index: index, suffix: "Md").map { String(Int($0)) } ?? "不可读"
        let target = hardware.value(index: index, suffix: "Tg").map { String(Int($0)) } ?? "不可读"
        return "F\(index)Md=\(mode)，F\(index)Tg=\(target) RPM"
    }

    func apply(_ targets: [Int: Double], fans: [FanReading]) throws {
        do {
            for fan in fans {
                guard let target = targets[fan.index], target.isFinite,
                      target >= fan.minimum, target <= fan.maximum else { throw SamplingError("目标转速超出硬件范围") }
                if owned.contains(fan.index) {
                    guard fan.mode == 1, let last = lastTargets[fan.index], abs(fan.target - last) < 100 else {
                        throw SamplingError("检测到其他程序修改风扇，已停止接管")
                    }
                } else {
                    guard fan.mode == 0 else { throw SamplingError("风扇已被其他程序接管，请先恢复自动模式") }
                    owned.insert(fan.index)
                    try hardware.set(index: fan.index, suffix: "Md", value: 1)
                    let confirmation = waitForReadback(index: fan.index, suffix: "Md", expected: 1, timeout: 2)
                    guard confirmation.confirmed else {
                        let last = confirmation.lastValue.map { String(Int($0)) } ?? "不可读"
                        throw ModeConfirmationTimeout(description: "风扇 \(fan.index) 模式确认超时（等待 2 秒，最后读到 F\(fan.index)Md=\(last)）")
                    }
                }
                try hardware.set(index: fan.index, suffix: "Tg", value: target)
                guard waitForReadback(index: fan.index, suffix: "Tg", expected: target, tolerance: 99).confirmed,
                      hardware.value(index: fan.index, suffix: "Md") == 1 else {
                    throw SamplingError("风扇 \(fan.index) 目标写入未生效：期望 \(Int(target)) RPM，\(readbackDescription(index: fan.index))")
                }
                lastTargets[fan.index] = target
            }
        } catch {
            let original = error
            do { try restore() } catch { throw SamplingError("\(original)；\(error)") }
            if original is ModeConfirmationTimeout {
                throw RecoverableControlError("\(original)；已确认恢复系统控制，可自动重试")
            }
            throw original
        }
    }

    func restore() throws {
        for _ in 0..<3 {
            for index in Array(owned) {
                do {
                    try hardware.set(index: index, suffix: "Md", value: 0)
                    if waitForReadback(index: index, suffix: "Md", expected: 0, timeout: 0.5).confirmed {
                        owned.remove(index); lastTargets[index] = nil
                    }
                } catch { /* retry the remaining owned fans */ }
            }
            if owned.isEmpty { return }
            pause(0.1)
        }
        throw SamplingError("无法确认风扇已恢复系统控制，请在 Macs Fan Control 中恢复 Auto")
    }

    func standby(fans: [FanReading]) throws {
        // Never silently wait behind another controller while claiming automatic monitoring.
        for fan in fans {
            if owned.contains(fan.index) {
                guard fan.mode == 1, let last = lastTargets[fan.index], abs(fan.target - last) < 100 else {
                    throw SamplingError("检测到其他程序修改风扇，已停止接管")
                }
            } else if fan.mode != 0 {
                throw SamplingError("低温待机期间检测到其他风扇控制程序")
            }
        }
        try restore()
    }
}

private var helperStop: Int32 = 0

enum PrivilegedHelper {
    static func run(arguments: [String]) throws {
        guard geteuid() == 0 else { throw SamplingError("风扇控制服务需要管理员授权") }
        guard arguments.count == 5, let parent = Int32(arguments[2]), parent > 1,
              let owner = UInt32(arguments[3]), owner > 0, let group = UInt32(arguments[4]),
              arguments[1].count == 64, arguments[1].allSatisfy({ $0.isHexDigit }) else {
            throw SamplingError("控制服务参数无效")
        }
        let session = arguments[0], token = arguments[1]
        let directory = try SessionIPC.directory(session)
        guard mkdir(directory, 0o700) == 0 else { throw SamplingError("无法建立独立控制会话") }
        defer { rmdir(directory) }
        let path = directory + "/control.sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SamplingError("无法启动控制服务") }
        defer { close(listener); unlink(path) }
        var address = try SessionIPC.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // The session directory stays root-owned. Clients cannot replace the socket with a symlink.
        guard bound == 0, chmod(path, 0o600) == 0, chown(path, owner, group) == 0,
              chmod(directory, 0o711) == 0, listen(listener, 4) == 0 else {
            throw SamplingError("无法配置控制会话权限")
        }
        signal(SIGTERM) { _ in helperStop = 1 }
        signal(SIGINT) { _ in helperStop = 1 }
        signal(SIGHUP) { _ in helperStop = 1 }
        let smc = try SMCConnection(writable: true)
        let reader = try SensorReader(smc: smc)
        let actuator = FanActuator(smc)
        try serve(listener: listener, parent: parent, owner: owner, token: token,
                  readSnapshot: { try reader.snapshot(requireControlSensors: $0) }, actuator: actuator,
                  refreshFans: { try reader.refreshingFans(in: $0) })
    }

    // Injected hardware boundary allows watchdog/IPC tests without any SMC writes.
    static func serve(listener: Int32, parent: Int32, owner: UInt32, token: String,
                      readSnapshot: (Bool) throws -> ThermalSnapshot, actuator: FanActuator,
                      heartbeatTimeout: Double = 8,
                      refreshFans: ((ThermalSnapshot) throws -> ThermalSnapshot)? = nil,
                      shouldStop: () -> Bool = { helperStop != 0 }) throws {
        defer { try? actuator.restore() }
        var policy = ControlPolicy()
        var mode = FanMode.system
        var manualRPM = 3000.0
        var latest = try readSnapshot(false)
        var targets: [Int: Double] = [:]
        var reason = "等待应用连接"
        var heartbeat = ProcessInfo.processInfo.systemUptime
        var lastTick = heartbeat
        var fatalError: String?
        var fatalRetryable = false
        var shouldExit = false

        func update() throws {
            latest = try readSnapshot(mode != .system)
            if mode != .system {
                // A delayed hardware read must not start another write after the
                // broker requested exit, the client vanished, or its heartbeat expired.
                guard !shouldStop(), kill(parent, 0) == 0,
                      ProcessInfo.processInfo.systemUptime - heartbeat <= heartbeatTimeout else {
                    throw ControlTransportError("控制会话已暂停或心跳超时，正在释放风扇")
                }
                let decision = try policy.targets(snapshot: latest, mode: mode, manualRPM: manualRPM,
                                                  now: ProcessInfo.processInfo.systemUptime)
                if decision.standby { try actuator.standby(fans: latest.fans) }
                else { try actuator.apply(decision.values, fans: latest.fans) }
                targets = decision.values; reason = decision.reason
                latest = try refreshFans?(latest) ?? readSnapshot(true)
            }
            lastTick = ProcessInfo.processInfo.systemUptime
        }

        while !shouldStop() && !shouldExit {
            let now = ProcessInfo.processInfo.systemUptime
            // No UI heartbeat, or the UI process disappeared: release ownership and terminate.
            if now - heartbeat > heartbeatTimeout || kill(parent, 0) != 0 { break }
            if mode != .system && now - lastTick >= 2 {
                do { try update() } catch {
                    fatalError = String(describing: error)
                    fatalRetryable = error is RecoverableControlError || error is ControlTransportError
                    do { try actuator.restore() } catch { fatalError! += "；\(error)"; fatalRetryable = false }
                    // Release immediately, but retain the error for the next UI heartbeat.
                    // Otherwise the UI sees only a missing socket and mistakes a hardware
                    // failure for a recoverable connection interruption.
                    mode = .system; targets = [:]
                }
            }
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 200) <= 0 { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            SessionIPC.configure(client)
            do {
                var peerUID: uid_t = 0, peerGID: gid_t = 0, peerPID: pid_t = 0
                var size = socklen_t(MemoryLayout<pid_t>.size)
                guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == owner,
                      getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0, peerPID == parent else {
                    throw SamplingError("控制连接身份不匹配")
                }
                let request = try SessionIPC.receive(HelperRequest.self, fd: client)
                guard request.token == token, request.manualRPM.isFinite,
                      request.manualRPM >= 0, request.manualRPM <= 30000 else { throw SamplingError("无效控制请求") }
                heartbeat = ProcessInfo.processInfo.systemUptime
                if let fatalError {
                    try SessionIPC.send(HelperResponse(snapshot: nil, mode: .system, targets: [:],
                                                       reason: "控制故障，已释放", error: fatalError, retryable: fatalRetryable), fd: client)
                    close(client)
                    break
                }
                if request.mode == .system {
                    try actuator.restore()
                    mode = .system; targets = [:]; reason = "已恢复系统控制"
                    latest = try refreshFans?(latest) ?? readSnapshot(false)
                    shouldExit = true
                } else {
                    let changed = mode != request.mode || manualRPM != request.manualRPM
                    mode = request.mode; manualRPM = request.manualRPM
                    if changed || ProcessInfo.processInfo.systemUptime - lastTick >= 1.5 { try update() }
                }
                try SessionIPC.send(HelperResponse(snapshot: latest, mode: mode, targets: targets, reason: reason, error: nil,
                                                   coolingPhase: mode == .system ? nil : policy.coolingPhase,
                                                   bodyCooling: mode == .automatic ? policy.bodyCooling : false), fd: client)
            } catch {
                fatalError = String(describing: error)
                fatalRetryable = error is RecoverableControlError || error is ControlTransportError
                do { try actuator.restore() } catch { fatalError! += "；\(error)"; fatalRetryable = false }
                try? SessionIPC.send(HelperResponse(snapshot: nil, mode: .system, targets: [:], reason: "已停止控制", error: fatalError, retryable: fatalRetryable), fd: client)
                shouldExit = true
            }
            close(client)
        }
        try actuator.restore()
        if let error = fatalError { throw SamplingError(error) }
    }
}
