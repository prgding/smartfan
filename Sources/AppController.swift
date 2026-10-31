import AppKit
import Security

final class ObservationStore {
    let directory: URL
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartFan/observations", isDirectory: true)
    }
    func appendEvent(_ event: String, detail: String, requested: Bool, mode: FanMode) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
        let destination = directory.appendingPathComponent("control-events-" + String(stamp.prefix(10)) + ".jsonl")
        let record: [String: Any] = ["captured_at": stamp, "event": event, "detail": detail,
                                    "control_requested": requested, "selected_mode": mode.rawValue]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw SamplingError("无法创建控制事件记录")
            }
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    func append(snapshot: ThermalSnapshot, feeling: String, mode: FanMode, note: String,
                coolingPhase: CoolingPhase? = nil, bodyCooling: Bool? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: snapshot.timestamp)
        let destination = directory.appendingPathComponent(String(stamp.prefix(10)) + ".jsonl")
        let record: [String: Any] = [
            "schema_version": 1, "id": UUID().uuidString, "captured_at": stamp,
            "source": "SmartFanMenuBar", "feeling": feeling, "note": note,
            "control_mode": mode.rawValue, "temperature_c": snapshot.temperatures,
            "thermal_pressure": snapshot.thermalPressure,
            "cooling_phase": coolingPhase?.rawValue as Any? ?? NSNull(),
            "body_cooling": bodyCooling as Any? ?? NSNull(),
            "power": ["source": snapshot.powerSource, "is_charging": snapshot.isCharging as Any? ?? NSNull()],
            "fans": snapshot.fans.map { ["index": Double($0.index), "actual_rpm": $0.actual,
                                          "target_rpm": $0.target, "mode_raw": Double($0.mode)] }
        ]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw SamplingError("无法创建温度记录")
            }
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }
}

final class AppController {
    var onChange: (() -> Void)?
    private(set) var snapshot: ThermalSnapshot?
    private(set) var enabled = false
    private(set) var authorizing = false
    private(set) var installing = false
    private(set) var stopping = false
    private(set) var message = "正在读取传感器…"
    private(set) var errorMessage: String?
    var selectedMode: FanMode = .automatic
    var manualRPM = 3000.0
    var allowsServiceInstallation = true
    private(set) var targets: [Int: Double] = [:]
    private(set) var coolingPhase: CoolingPhase?
    private(set) var bodyCooling = false
    let observations = ObservationStore()
    private let worker = DispatchQueue(label: "SmartFan.hardware", qos: .utility)
    private var reader: SensorReader?
    private var timer: Timer?
    private var busy = false
    private var generation = 0
    private var session: String?
    private var token: String?
    private var installerProcess: Process?
    private var sessionConnected = false
    private var authorizationStarted: Date?
    private var lastLog = Date.distantPast
    private var lifecycle = ControlLifecycle()
    private var lastReconnectReadiness: ReconnectReadiness?
    private var activity: NSObjectProtocol?
    var controlRequested: Bool { lifecycle.requested }
    var reconnecting: Bool { lifecycle.requested && !enabled && !authorizing }

    private func logEvent(_ event: String, _ detail: String) {
        let requested = lifecycle.requested, mode = selectedMode
        worker.async { try? self.observations.appendEvent(event, detail: detail, requested: requested, mode: mode) }
    }

    private func fanState(_ snapshot: ThermalSnapshot?) -> String {
        guard let snapshot else { return "风扇读数不可用" }
        return snapshot.fans.map { "F\($0.index)Md=\($0.mode),target=\(Int($0.target)),actual=\(Int($0.actual))" }
            .joined(separator: "; ")
    }

    private func updateActivity() {
        if lifecycle.requested && !lifecycle.sleeping {
            if activity == nil {
                // Prevent App Nap from throttling the UI heartbeat, without preventing system sleep.
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                  reason: "SmartFan 温度监测与风扇控制心跳")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity); self.activity = nil
        }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: "manualRPM")
        if saved.isFinite && saved >= 1000 && saved <= 15000 {
            manualRPM = min(saved, ControlPolicy.normalMaximumRPM)
        }
    }

    func startMonitoring() {
        self.timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    var conflictingApp: Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased().contains("macsfancontrol") ||
            ($0.localizedName ?? "").lowercased().contains("macs fan control")
        }
    }

    func enable(isRecovery: Bool = false) {
        guard !lifecycle.sleeping else { return }
        guard !enabled, !authorizing, !stopping else { return }
        guard installerProcess?.isRunning != true else { fail("后台服务仍在安装，请稍后再开启"); return }
        guard let snapshot, snapshot.controlReady else { fail("尚未获得完整传感器和风扇数据"); return }
        guard !conflictingApp else { fail("请先退出 Macs Fan Control，再开启控制"); return }
        guard snapshot.fans.allSatisfy({ $0.mode == 0 }) else { fail("风扇仍处于手动模式，尚未确认释放"); return }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { fail("无法建立安全控制会话"); return }
        if !isRecovery { lifecycle.enable() }
        lastReconnectReadiness = nil
        updateActivity()
        logEvent(isRecovery ? "reconnect_started" : "control_enabled", isRecovery ? "自动恢复连接，不请求管理员授权" : "开启风扇控制")
        let secret = random.map { String(format: "%02x", $0) }.joined()
        let identifier = UUID().uuidString
        generation += 1
        let currentGeneration = generation
        session = identifier; token = secret; sessionConnected = false
        authorizing = true; errorMessage = nil; authorizationStarted = Date()
        message = "正在连接后台服务…"
        onChange?()
        let app = Bundle.main.bundleURL
        worker.async {
            do {
                let expected = try ServiceInstallation.expected(app: app)
                let installed = try? ServiceInstallation.installed()
                DispatchQueue.main.async {
                    guard self.generation == currentGeneration else { return }
                    if installed == expected { self.startSession(installation: expected, generation: currentGeneration) }
                    else if self.allowsServiceInstallation && !isRecovery { self.installService(installation: expected, generation: currentGeneration) }
                    else { self.connectionFailed("后台服务尚未安装或需要更新，请重新开启风扇控制完成授权") }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == currentGeneration else { return }
                    self.connectionFailed(String(describing: error))
                }
            }
        }
    }

    private func connectionFailed(_ text: String, retryable: Bool = false) {
        handleControlFailure(text, retryable: retryable)
    }

    private func startSession(installation: ServiceInstallation, generation expectedGeneration: Int) {
        guard let id = session, let secret = token else { return }
        message = "正在连接后台服务…"; authorizationStarted = Date(); onChange?()
        worker.async {
            var failure: String?
            var retryable = false
            // launchd startup and the previous session's exit can take a moment.
            for attempt in 0..<8 {
                do {
                    try ServiceClient.request(ServiceRequest(action: .start, session: id, token: secret), installation: installation)
                    failure = nil; break
                } catch {
                    failure = String(describing: error)
                    retryable = error is ControlTransportError || error is RecoverableControlError
                    if attempt < 7 { Thread.sleep(forTimeInterval: 0.25) }
                }
            }
            DispatchQueue.main.async {
                guard self.generation == expectedGeneration else {
                    if failure == nil {
                        self.worker.async {
                            _ = try? SessionIPC.request(session: id, request: HelperRequest(token: secret, mode: .system, manualRPM: 3000))
                        }
                    }
                    return
                }
                if let failure { self.connectionFailed("无法连接后台服务：\(failure)", retryable: retryable); return }
                self.sessionConnected = true
                self.poll()
            }
        }
    }

    private func installService(installation: ServiceInstallation, generation expectedGeneration: Int) {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SmartFanHelper") else {
            connectionFailed("缺少风扇控制服务，请重新构建应用"); return
        }
        installing = true
        message = "首次安装或更新后台服务，需要管理员授权…"; onChange?()
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = [helper.path, "--install", String(getuid()), String(getgid()), Bundle.main.bundlePath]
            .map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"exec \(escaped)\" with administrator privileges\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.installerProcess = nil
                self.installing = false
                guard self.generation == expectedGeneration else { return }
                if process.terminationStatus == 0 {
                    self.startSession(installation: installation, generation: expectedGeneration)
                } else {
                    self.connectionFailed(detail.contains("-128") ? "已取消后台服务安装" : (detail.isEmpty ? "后台服务安装失败" : detail))
                }
            }
        }
        do {
            try process.run(); installerProcess = process
            input.fileHandleForWriting.write(Data(script.utf8)); try input.fileHandleForWriting.close()
        } catch { installing = false; connectionFailed("无法请求管理员授权：\(error.localizedDescription)") }
    }

    func disable(completion: (() -> Void)? = nil) {
        lifecycle.disable()
        updateActivity()
        logEvent("control_disabled", "用户关闭风扇控制")
        stopSession(completion: completion)
    }

    func handleControlFailure(_ text: String, retryable: Bool) {
        lifecycle.failed(now: ProcessInfo.processInfo.systemUptime, retryable: retryable)
        lastReconnectReadiness = nil
        logEvent(lifecycle.requested ? "reconnect_scheduled" : "control_fault", "\(text)；最后读数：\(fanState(snapshot))")
        updateActivity()
        stopSession {
            let reason = self.errorMessage ?? text
            self.errorMessage = self.lifecycle.requested ? "\(reason)；等待确认释放后自动重连，开关保持开启" : "\(reason)；控制已停止，请检查后重新开启"
            self.message = self.lifecycle.requested ? "等待自动重连" : "控制已停止"
            self.onChange?()
        }
    }

    private func stopSession(completion: (() -> Void)? = nil) {
        generation += 1
        let currentGeneration = generation
        guard let id = session, let secret = token else {
            sessionConnected = false
            coolingPhase = nil
            bodyCooling = false
            enabled = false; authorizing = false; targets = [:]; errorMessage = nil; onChange?(); completion?(); return
        }
        stopping = true; message = "正在恢复系统控制…"; onChange?()
        let connected = sessionConnected
        let app = Bundle.main.bundleURL
        worker.async {
            var failure: String?
            var restoredSnapshot: ThermalSnapshot?
            var hardFailure = false
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let response = try SessionIPC.request(session: id, request: HelperRequest(token: secret, mode: .system, manualRPM: 3000))
                try response.checkError()
                guard response.mode == .system, let released = response.snapshot, !released.fans.isEmpty,
                      released.fans.allSatisfy({ $0.mode == 0 }) else {
                    throw SamplingError("后台服务未确认风扇已恢复系统模式")
                }
                restoredSnapshot = released
            } catch {
                hardFailure = !(error is ControlTransportError) && !(error is RecoverableControlError)
                if hardFailure { failure = String(describing: error) }
                else if error is ControlTransportError {
                    do {
                        let installation = try ServiceInstallation.expected(app: app)
                        try ServiceClient.request(ServiceRequest(action: .stop, session: id, token: secret), installation: installation)
                        failure = "已请求旧会话退出，正在确认风扇释放"
                    } catch {
                        hardFailure = !(error is ControlTransportError) && !(error is RecoverableControlError)
                        failure = "未能确认旧会话退出：\(error)"
                    }
                } else if connected { failure = "正在核对风扇释放状态" }
            }
            let duration = ProcessInfo.processInfo.systemUptime - started
            DispatchQueue.main.async {
                guard self.generation == currentGeneration else { return }
                if hardFailure {
                    self.lifecycle.failed(now: ProcessInfo.processInfo.systemUptime, retryable: false)
                    self.updateActivity()
                }
                let outcome = hardFailure ? "session_release_failed" : (restoredSnapshot == nil ? "session_release_unconfirmed" : "session_released")
                self.logEvent(outcome, "\(failure ?? (restoredSnapshot == nil ? "未收到释放确认" : "已确认系统模式"))；耗时 \(String(format: "%.2f", duration)) 秒；\(self.fanState(restoredSnapshot))")
                self.sessionConnected = false
                if let restoredSnapshot { self.snapshot = restoredSnapshot }
                self.session = nil; self.token = nil; self.enabled = false; self.authorizing = false
                self.stopping = false; self.targets = [:]; self.coolingPhase = nil; self.bodyCooling = false; self.errorMessage = failure
                self.message = failure ?? "系统自动控制"
                self.onChange?(); self.poll(); completion?()
            }
        }
    }

    func updateMode(_ mode: FanMode) { selectedMode = mode; errorMessage = nil; poll(); onChange?() }
    func updateManual(_ rpm: Double) {
        guard rpm.isFinite else { return }
        let minimum = snapshot?.fans.map(\.minimum).max() ?? 1200
        let maximum = max(minimum, snapshot?.fans.map { ControlPolicy.normalMaximum(for: $0) }.min()
                          ?? ControlPolicy.normalMaximumRPM)
        manualRPM = clamp(rpm, minimum, maximum)
        UserDefaults.standard.set(manualRPM, forKey: "manualRPM")
        onChange?()
    }

    func poll() {
        guard !busy, !stopping, !lifecycle.sleeping else { return }
        if authorizing, let started = authorizationStarted, Date().timeIntervalSince(started) > 180 {
            handleControlFailure("后台服务连接或授权超时", retryable: !installing); return
        }
        busy = true
        let currentGeneration = generation, id = sessionConnected ? session : nil, secret = token
        let mode = selectedMode, rpm = manualRPM, pending = authorizing
        worker.async {
            var response: HelperResponse?
            var snapshot: ThermalSnapshot?
            var failure: String?
            var retryable = false
            let started = ProcessInfo.processInfo.systemUptime
            do {
                if let id, let secret {
                    response = try SessionIPC.request(session: id, request: HelperRequest(token: secret, mode: mode, manualRPM: rpm))
                    try response?.checkError()
                    snapshot = response?.snapshot
                } else {
                    if self.reader == nil { self.reader = try SensorReader(smc: SMCConnection()) }
                    snapshot = try self.reader?.snapshot()
                }
                if let snapshot, Date().timeIntervalSince(self.lastLog) >= 30 {
                    do {
                        try self.observations.append(snapshot: snapshot, feeling: "unknown", mode: response?.mode ?? .system,
                                                     note: "定时温度记录，未报告体感", coolingPhase: response?.coolingPhase,
                                                     bodyCooling: response?.bodyCooling)
                        self.lastLog = Date()
                    } catch { /* Monitoring and control remain available if logging fails. */ }
                }
            } catch {
                failure = String(describing: error)
                retryable = error is ControlTransportError || error is RecoverableControlError
                if id == nil { self.reader = nil }
            }
            DispatchQueue.main.async {
                self.busy = false
                guard self.generation == currentGeneration else { return }
                if let snapshot { self.snapshot = snapshot }
                let connectingTimedOut = pending && self.sessionConnected && Date().timeIntervalSince(self.authorizationStarted ?? Date()) > 10
                if let failure, !pending || connectingTimedOut {
                    self.errorMessage = failure
                    if id != nil {
                        self.logEvent("session_request_failed", "\(failure)；耗时 \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started)) 秒")
                        self.handleControlFailure(failure, retryable: retryable)
                        return
                    }
                    self.message = "传感器读取失败"
                } else if let response, response.error == nil {
                    let wasConnected = self.enabled
                    let wasStandby = self.enabled && self.selectedMode == .automatic && self.targets.isEmpty
                    self.authorizing = false; self.enabled = response.mode != .system
                    if self.enabled {
                        self.lifecycle.connected(now: ProcessInfo.processInfo.systemUptime)
                        if !wasConnected { self.logEvent("control_connected", "已恢复\(self.selectedMode == .manual ? "手动" : "自动")控速") }
                    }
                    if let phase = response.coolingPhase, phase != self.coolingPhase,
                       phase != .normal || self.coolingPhase != nil {
                        let cpu = snapshot?.cpu.map { String(format: "%.1f", $0) } ?? "不可用"
                        let pressure = snapshot.map { String($0.thermalPressure) } ?? "不可用"
                        self.logEvent("cooling_phase_changed", "\(phase.rawValue)；\(response.reason)；CPU=\(cpu)°C，thermalPressure=\(pressure)；\(self.fanState(snapshot))")
                    }
                    self.coolingPhase = response.coolingPhase
                    let bodyCooling = response.bodyCooling == true
                    if bodyCooling != self.bodyCooling {
                        let battery = snapshot?.battery.map { String(format: "%.1f", $0) } ?? "不可用"
                        let primary = snapshot?.primary.map { String(format: "%.1f", $0) } ?? "不可用"
                        let secondary = snapshot?.secondary.map { String(format: "%.1f", $0) } ?? "不可用"
                        self.logEvent(bodyCooling ? "body_cooling_started" : "body_cooling_released",
                                      "\(response.reason)；电池=\(battery)°C，Ts1P=\(primary)°C，Ts0P=\(secondary)°C；\(self.fanState(snapshot))")
                    }
                    self.bodyCooling = bodyCooling
                    self.targets = response.targets; self.message = response.reason; self.errorMessage = nil
                    if response.mode == .automatic {
                        let isStandby = response.targets.isEmpty
                        if isStandby != wasStandby {
                            self.logEvent(isStandby ? "cooling_standby" : "cooling_resumed", response.reason)
                        }
                    }
                } else if let response, let failure = response.error {
                    self.handleControlFailure(failure, retryable: response.retryable == true)
                    return
                } else if id == nil && failure == nil && !self.authorizing {
                    if self.reconnecting { self.message = "等待自动恢复控速" }
                    else { self.message = snapshot?.fans.contains(where: { $0.mode != 0 }) == true ? "监测中 · 风扇处于手动模式" : "系统自动控制" }
                }
                self.onChange?()
                self.reconnectIfReady(snapshot: snapshot)
            }
        }
    }

    private func reconnectIfReady(snapshot: ThermalSnapshot?) {
        guard !enabled, !authorizing, !stopping, installerProcess?.isRunning != true else { return }
        let fresh = snapshot.flatMap { $0.controlReady && Date().timeIntervalSince($0.timestamp) < 6 ? $0 : nil }
        let readiness = lifecycle.reconnectReadiness(now: ProcessInfo.processInfo.systemUptime,
                                                     fans: fresh?.fans, conflictingApp: conflictingApp)
        if readiness != .inactive && readiness != lastReconnectReadiness {
            logEvent("reconnect_gate", "\(readiness)；\(fanState(fresh))")
        }
        lastReconnectReadiness = readiness
        switch readiness {
        case .inactive: return
        case .waitingForRelease:
            message = "等待风扇释放"
            errorMessage = "风扇仍处于手动模式，正在等待释放；开关保持开启"
        case .confirmingRelease:
            message = "确认释放状态"
            errorMessage = "已读到系统模式，确认稳定后自动恢复控速"
        case .ready: enable(isRecovery: true); return
        case .conflictingApp:
            handleControlFailure("检测到 Macs Fan Control 主程序正在运行，未重新接管", retryable: false); return
        case .releaseTimedOut:
            handleControlFailure("尚未确认风扇释放，保留开关并延后复查，不强行接管", retryable: true); return
        }
        onChange?()
    }

    func recordFeeling(_ feeling: String) {
        let mode = enabled ? selectedMode : .system
        worker.async {
            do {
                if self.reader == nil { self.reader = try SensorReader(smc: SMCConnection()) }
                guard let snapshot = try self.reader?.snapshot() else { throw SamplingError("无法采样") }
                let note = ["warm", "hot"].contains(feeling) ? "掌托已超过期望舒适状态；希望风扇更早介入避免温热" : "用户从菜单记录掌托体感"
                try self.observations.append(snapshot: snapshot, feeling: feeling, mode: mode, note: note)
                DispatchQueue.main.async { self.errorMessage = nil; self.message = "已保存体感记录"; self.onChange?() }
            } catch { DispatchQueue.main.async { self.fail("体感记录失败：\(error)") } }
        }
    }

    func shutdown() {
        timer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if let session, let token {
            worker.sync {
                do {
                    let response = try SessionIPC.request(session: session, request: HelperRequest(token: token, mode: .system, manualRPM: 3000))
                    try response.checkError()
                } catch {
                    if let installation = try? ServiceInstallation.expected(app: Bundle.main.bundleURL) {
                        try? ServiceClient.request(ServiceRequest(action: .stop, session: session, token: token), installation: installation)
                    }
                }
            }
        }
    }

    // Only the explicit verification executable path can request this diagnostic.
    // Use the same authenticated broker stop as outage cleanup; no synthetic IPC error.
    func interruptSessionForVerification(completion: @escaping (Error?) -> Void) {
        guard CommandLine.arguments.contains("--verify-control-recovery"), enabled,
              let session, let token else { completion(SamplingError("验证需要已连接的控制会话")); return }
        let app = Bundle.main.bundleURL
        logEvent("verification_session_stop", "恢复验证：要求当前会话正常退出，验证真实通信中断后的恢复")
        worker.async {
            do {
                let installation = try ServiceInstallation.expected(app: app)
                try ServiceClient.request(ServiceRequest(action: .stop, session: session, token: token), installation: installation)
                DispatchQueue.main.async { completion(nil); self.poll() }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }

    func prepareForSleep() {
        lifecycle.sleep()
        logEvent("sleep", "休眠前暂停控制，保留开关意愿，唤醒后自动恢复")
        generation += 1
        shutdown()
        sessionConnected = false; session = nil; token = nil
        enabled = false; authorizing = false; stopping = false; targets = [:]; coolingPhase = nil; bodyCooling = false
        message = lifecycle.requested ? "休眠中 · 唤醒后自动恢复控速" : "休眠中"
        onChange?()
    }
    func resumeAfterWake() {
        lifecycle.wake(now: ProcessInfo.processInfo.systemUptime)
        updateActivity()
        logEvent("wake", lifecycle.requested ? "唤醒后等待新传感器数据，再自动恢复控速" : "保持用户关闭状态")
        // A new IOKit connection avoids carrying a stale sensor connection across sleep.
        worker.async { self.reader = nil }
        startMonitoring()
    }
    private func fail(_ text: String) { errorMessage = text; onChange?() }
}
