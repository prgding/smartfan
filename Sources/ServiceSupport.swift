import Foundation
import Security
import Darwin

enum ServicePaths {
    static let label = "com.shuai.smartfan.helper"
    static let executable = "/Library/PrivilegedHelperTools/\(label)"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let configurationDirectory = "/Library/Application Support/SmartFanService"
    static let configuration = configurationDirectory + "/installation.json"
    static let runtimeDirectory = "/private/var/run/\(label)"
    static let socket = runtimeDirectory + "/control.sock"
    static let protocolVersion = 1
}

struct ServiceInstallation: Codable, Equatable {
    let version: Int
    let uid: UInt32
    let gid: UInt32
    let appHash: String
    let helperHash: String

    static func expected(app: URL, uid: UInt32 = getuid(), gid: UInt32 = getgid()) throws -> Self {
        let identity = try CodeIdentity.staticIdentity(app)
        guard identity.identifier == "com.shuai.smartfan.menubar", uid > 0 else {
            throw SamplingError("安装来源或用户身份无效")
        }
        let helper = app.appendingPathComponent("Contents/MacOS/SmartFanHelper")
        return Self(version: ServicePaths.protocolVersion, uid: uid, gid: gid,
                    appHash: identity.hash, helperHash: try CodeIdentity.staticIdentity(helper).hash)
    }

    static func installed() throws -> Self {
        try TrustedFile.check(ServicePaths.configurationDirectory, directory: true)
        try TrustedFile.check(ServicePaths.configuration)
        try TrustedFile.check(ServicePaths.executable)
        try TrustedFile.check(ServicePaths.plist)
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: ServicePaths.configuration)))
    }
}

enum TrustedFile {
    static func check(_ path: String, directory: Bool = false) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw SamplingError("后台服务文件权限无效：\(path)")
        }
    }

    static func directory(_ path: String, mode: mode_t = 0o755) throws {
        if mkdir(path, mode) != 0 && errno != EEXIST { throw SamplingError("无法创建后台服务目录") }
        try check(path, directory: true)
    }

    static func write(_ data: Data, to path: String, mode: mode_t) throws {
        let temporary = path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SamplingError("无法写入后台服务文件") }
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SamplingError("后台服务文件写入不完整") }
                offset += count
            }
        }
        guard fchown(fd, 0, 0) == 0, fchmod(fd, mode) == 0, fsync(fd) == 0,
              rename(temporary, path) == 0 else { throw SamplingError("无法保存后台服务文件") }
    }
}

enum CodeIdentity {
    static func staticIdentity(_ path: URL) throws -> (identifier: String, hash: String) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw SamplingError("应用或控制服务签名无效，请重新构建")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data,
              let identifier = values[kSecCodeInfoIdentifier as String] as? String else {
            throw SamplingError("无法读取应用签名")
        }
        return (identifier, hash.map { String(format: "%02x", $0) }.joined())
    }

    // Audit tokens identify the actual connection peer, including its process generation.
    static func peer(_ fd: Int32, uid expectedUID: UInt32, hash expectedHash: String) throws -> pid_t {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        var audit = audit_token_t()
        var auditSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0, pid > 1,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &audit, &auditSize) == 0 else {
            throw SamplingError("后台服务连接身份不匹配")
        }
        let auditData = withUnsafeBytes(of: audit) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: auditData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw SamplingError("后台服务拒绝未受信任的应用")
        }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data,
              hash.map({ String(format: "%02x", $0) }).joined() == expectedHash else {
            throw SamplingError("应用签名已变化，请更新后台服务")
        }
        return pid
    }
}

struct ServiceRequest: Codable {
    enum Action: String, Codable { case status, start, stop }
    let action: Action
    let session: String?
    let token: String?
    init(action: Action, session: String? = nil, token: String? = nil) {
        self.action = action; self.session = session; self.token = token
    }
}
struct ServiceResponse: Codable {
    let version: Int
    let error: String?
    var retryable: Bool? = nil

    func checkError() throws {
        guard let error else { return }
        if retryable == true { throw RecoverableControlError(error) }
        throw SamplingError(error)
    }
}

enum ServiceClient {
    static func request(_ request: ServiceRequest, installation: ServiceInstallation) throws {
        try TrustedFile.check(ServicePaths.runtimeDirectory, directory: true)
        let fd = try SessionIPC.connect(path: ServicePaths.socket)
        defer { close(fd) }
        _ = try CodeIdentity.peer(fd, uid: 0, hash: installation.helperHash)
        try SessionIPC.send(request, fd: fd)
        let response = try SessionIPC.receive(ServiceResponse.self, fd: fd)
        guard response.version == ServicePaths.protocolVersion else { throw SamplingError("后台服务需要更新") }
        try response.checkError()
    }
}
