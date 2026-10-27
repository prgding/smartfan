import Foundation
import Darwin

protocol ControlSessionProcess: AnyObject {
    var isRunning: Bool { get }
    func requestStop()
    func stop()
}

private final class HelperSessionProcess: ControlSessionProcess {
    private let process = Process()
    var isRunning: Bool { process.isRunning }
    init(session: String, token: String, pid: pid_t, installation: ServiceInstallation) throws {
        process.executableURL = URL(fileURLWithPath: ServicePaths.executable)
        process.arguments = [session, token, String(pid), String(installation.uid), String(installation.gid)]
        try process.run()
    }
    func requestStop() { if process.isRunning { process.terminate() } }
    func stop() { requestStop(); if process.isRunning { process.waitUntilExit() } }
}

// The broker only starts this fixed helper. It cannot execute client-supplied programs or write keys.
final class ServiceBroker {
    private var active: ControlSessionProcess?
    private var activeSession: String?
    private var activeToken: String?
    private var activePID: pid_t?
    private var retiring = false
    private let launch: (String, String, pid_t) throws -> ControlSessionProcess

    init(launch: @escaping (String, String, pid_t) throws -> ControlSessionProcess) { self.launch = launch }

    func handle(_ request: ServiceRequest, peer: pid_t) throws {
        guard peer > 1 else { throw SamplingError("无效应用进程") }
        if request.action == .status { return }
        guard let session = request.session, let token = request.token,
              token.count == 64, token.allSatisfy({ $0.isHexDigit }) else { throw SamplingError("无效控制会话") }
        _ = try SessionIPC.directory(session)
        if request.action == .stop {
            guard active?.isRunning == true else { return }
            guard activePID == peer else { throw SamplingError("不能停止其他应用进程的控制会话") }
            // An obsolete release request must not stop a newer session.
            guard activeSession == session else { return }
            guard activeToken == token else { throw SamplingError("控制会话令牌不匹配") }
            retireActiveSession()
            return
        }
        if active?.isRunning == true {
            if activeSession == session, activeToken == token, activePID == peer, !retiring { return }
            if activePID == peer {
                if activeSession == session && activeToken != token { throw SamplingError("控制会话令牌不匹配") }
                retireActiveSession()
                throw RecoverableControlError("已请求旧控制会话退出，等待释放后自动重连")
            }
            throw SamplingError("已有控制会话，请先关闭原来的风扇控制")
        }
        active = try launch(session, token, peer)
        activeSession = session; activeToken = token; activePID = peer
        retiring = false
    }

    private func retireActiveSession() {
        guard !retiring else { return }
        retiring = true
        // SIGTERM follows the helper's restore path. Never SIGKILL a fan owner,
        // and never launch a replacement until this child has actually exited.
        active?.requestStop()
    }

    func stop() { active?.stop(); active = nil; retiring = false }
}

private var serviceStopping: Int32 = 0

enum PersistentService {
    static func run() throws {
        guard geteuid() == 0 else { throw SamplingError("后台服务需要系统权限") }
        let installation = try ServiceInstallation.installed()
        guard installation.version == ServicePaths.protocolVersion,
              try CodeIdentity.staticIdentity(URL(fileURLWithPath: ServicePaths.executable)).hash == installation.helperHash else {
            throw SamplingError("后台服务版本或签名不匹配")
        }
        try TrustedFile.directory(ServicePaths.runtimeDirectory, mode: 0o711)
        let lock = open(ServicePaths.runtimeDirectory + "/service.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw SamplingError("无法锁定后台服务") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SamplingError("后台服务已经运行") }
        let path = ServicePaths.socket
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SamplingError("无法建立后台服务连接") }
        defer { close(listener); unlink(path) }
        var address = try SessionIPC.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, 0o600) == 0, chown(path, installation.uid, installation.gid) == 0,
              listen(listener, 4) == 0 else { throw SamplingError("无法配置后台服务连接") }
        // A session child must not inherit the broker socket or singleton lock.
        guard fcntl(listener, F_SETFD, FD_CLOEXEC) == 0, fcntl(lock, F_SETFD, FD_CLOEXEC) == 0 else {
            throw SamplingError("无法隔离后台服务连接")
        }
        signal(SIGTERM) { _ in serviceStopping = 1 }
        signal(SIGINT) { _ in serviceStopping = 1 }
        signal(SIGHUP) { _ in serviceStopping = 1 }
        let broker = ServiceBroker { try HelperSessionProcess(session: $0, token: $1, pid: $2, installation: installation) }
        defer { broker.stop() }
        while serviceStopping == 0 {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 1000) <= 0 { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else { close(client); continue }
            SessionIPC.configure(client)
            do {
                let peer = try CodeIdentity.peer(client, uid: installation.uid, hash: installation.appHash)
                let request = try SessionIPC.receive(ServiceRequest.self, fd: client)
                try broker.handle(request, peer: peer)
                try SessionIPC.send(ServiceResponse(version: ServicePaths.protocolVersion, error: nil), fd: client)
            } catch {
                // Rejected clients never disturb the session already controlling the fan.
                try? SessionIPC.send(ServiceResponse(version: ServicePaths.protocolVersion, error: String(describing: error),
                                                    retryable: error is RecoverableControlError), fd: client)
            }
            close(client)
        }
    }
}

enum ServiceInstaller {
    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }

    private static func stopExisting() throws {
        let target = "system/" + ServicePaths.label
        if try launchctl(["print", target]) == 0 {
            guard try launchctl(["bootout", target]) == 0 else { throw SamplingError("无法停止旧后台服务") }
        }
    }

    static func install(arguments: [String]) throws {
        guard geteuid() == 0, arguments.count == 3,
              let uid = UInt32(arguments[0]), uid > 0, let gid = UInt32(arguments[1]) else {
            throw SamplingError("后台服务安装参数无效")
        }
        let app = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let installation = try ServiceInstallation.expected(app: app, uid: uid, gid: gid)
        let source = app.appendingPathComponent("Contents/MacOS/SmartFanHelper")
        guard try CodeIdentity.staticIdentity(URL(fileURLWithPath: CommandLine.arguments[0])).hash == installation.helperHash else {
            throw SamplingError("安装器与应用中的服务不匹配")
        }
        // Copy bytes before stopping an existing service, and validate the installed copy before loading it.
        let binary = try Data(contentsOf: source)
        for directory in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons"] {
            try TrustedFile.directory(directory)
        }
        try TrustedFile.directory(ServicePaths.configurationDirectory)
        try stopExisting()
        try TrustedFile.write(binary, to: ServicePaths.executable, mode: 0o755)
        guard try CodeIdentity.staticIdentity(URL(fileURLWithPath: ServicePaths.executable)).hash == installation.helperHash else {
            throw SamplingError("安装后的控制服务签名校验失败")
        }
        try TrustedFile.write(JSONEncoder().encode(installation), to: ServicePaths.configuration, mode: 0o644)
        let plist: [String: Any] = [
            "Label": ServicePaths.label,
            "ProgramArguments": [ServicePaths.executable, "--daemon"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
            "ExitTimeOut": 15, "ProcessType": "Background"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try TrustedFile.write(data, to: ServicePaths.plist, mode: 0o644)
        _ = try launchctl(["enable", "system/" + ServicePaths.label])
        guard try launchctl(["bootstrap", "system", ServicePaths.plist]) == 0 else {
            throw SamplingError("后台服务已复制，但系统未能启动它")
        }
        print("SmartFan 后台服务已安装。")
    }

    static func uninstall() throws {
        guard geteuid() == 0 else { throw SamplingError("移除后台服务需要管理员授权") }
        try stopExisting()
        for path in [ServicePaths.plist, ServicePaths.executable, ServicePaths.configuration,
                     ServicePaths.socket, ServicePaths.runtimeDirectory + "/service.lock"] {
            if unlink(path) != 0 && errno != ENOENT { throw SamplingError("无法移除 \(path)") }
        }
        rmdir(ServicePaths.runtimeDirectory); rmdir(ServicePaths.configurationDirectory)
        print("SmartFan 后台服务已移除，温度记录已保留。")
    }
}
