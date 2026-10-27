import Foundation

@main
enum HelperApplication {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--daemon"] { try PersistentService.run() }
            else if arguments.first == "--install" { try ServiceInstaller.install(arguments: Array(arguments.dropFirst())) }
            else if arguments == ["--uninstall"] { try ServiceInstaller.uninstall() }
            else { try PrivilegedHelper.run(arguments: arguments) }
        }
        catch {
            FileHandle.standardError.write(Data("SmartFan：\(error)\n".utf8))
            exit(1)
        }
    }
}
