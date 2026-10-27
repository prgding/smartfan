import Foundation
@main enum FanProbe {
    static func main() throws {
        let smc = try SMCConnection()
        for key in ["Ftst", "F0md", "FS! "] {
            do { print("probe \(key.debugDescription): \(try smc.read(key))") } catch { print("probe \(key.debugDescription): \(error)") }
        }
        let count = Int(try smc.read("#KEY").value)
        for i in 0..<count {
            guard let key = try? smc.key(at: i), key.hasPrefix("F") else { continue }
            do { let reading = try smc.read(key); print("\(key.debugDescription) type=\(reading.type.debugDescription) value=\(reading.value)") } catch { print("\(key.debugDescription): \(error)") }
        }
    }
}
