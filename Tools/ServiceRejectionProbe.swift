import Foundation
import Darwin

// Read-only integration check: this separately signed executable must be rejected by the broker.
@main enum ServiceRejectionProbe {
    static func main() throws {
        let installation = try ServiceInstallation.installed()
        let fd = try SessionIPC.connect(path: ServicePaths.socket)
        defer { close(fd) }
        _ = try CodeIdentity.peer(fd, uid: 0, hash: installation.helperHash)
        // Authentication happens before the server reads any command from an untrusted process.
        let reply = try SessionIPC.receive(ServiceResponse.self, fd: fd)
        guard let detail = reply.error,
              detail.contains("应用签名已变化") || detail.contains("拒绝未受信任") else {
            throw SamplingError("FAIL: expected an explicit signature rejection")
        }
        print("PASS: installed service rejected this differently signed executable before reading a command.")
    }
}
