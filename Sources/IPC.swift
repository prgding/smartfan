import Foundation
import Darwin

struct ControlTransportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum SessionIPC {
    static func directory(_ session: String) throws -> String {
        guard let uuid = UUID(uuidString: session), uuid.uuidString == session else {
            throw SamplingError("无效控制会话")
        }
        return "/private/tmp/smartfan.\(session)"
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SamplingError("通信路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = byte }
        }
        return address
    }

    static func configure(_ fd: Int32, timeoutSeconds: Int = 2) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func send<T: Encodable>(_ message: T, fd: Int32) throws {
        var data = try JSONEncoder().encode(message)
        data.append(10)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ControlTransportError("控制服务连接中断") }
                offset += count
            }
        }
    }

    static func receive<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 262144 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ControlTransportError("控制服务没有响应") }
            if let end = buffer.prefix(count).firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<end])
                return try JSONDecoder().decode(type, from: data)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw SamplingError("控制服务响应过长")
    }

    static func request(session: String, request: HelperRequest, requireRoot: Bool = true) throws -> HelperResponse {
        let path = try directory(session) + "/control.sock"
        let fd = try connect(path: path)
        defer { close(fd) }
        // Session directories are created by root and cannot be replaced by another user.
        var owner: uid_t = 0, group: gid_t = 0
        guard getpeereid(fd, &owner, &group) == 0, owner == 0 || (!requireRoot && owner == getuid()) else {
            throw SamplingError("控制服务身份无效")
        }
        try send(request, fd: fd)
        return try receive(HelperResponse.self, fd: fd)
    }

    static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SamplingError("无法创建控制连接") }
        var connected = false
        defer { if !connected { close(fd) } }
        configure(fd, timeoutSeconds: 5)
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ControlTransportError("控制服务尚未连接") }
        connected = true
        return fd
    }
}
