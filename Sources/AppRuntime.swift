import Foundation
import Darwin

enum AppRuntime {
    static let root: URL = {
        let resource = Bundle.main.resourceURL
        setenv("MEETING_APP_PATH", Bundle.main.bundleURL.path, 1)
        if let resource { setenv("MEETING_RESOURCES", resource.path, 1) }
        if let development = Bundle.main.object(forInfoDictionaryKey: "MeetingProjectRoot") as? String {
            return URL(fileURLWithPath: development)
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingMemory", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Only declared program files are replaced. Settings and meeting data are never bundled.
            if let runtime = resource?.appendingPathComponent("Runtime"),
               let data = try? Data(contentsOf: runtime.appendingPathComponent("runtime-files.json")),
               let files = try JSONSerialization.jsonObject(with: data) as? [String] {
                for name in files where !name.contains("..") && !name.hasPrefix("/") {
                    let target = root.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let bytes = try Data(contentsOf: runtime.appendingPathComponent(name))
                    if (try? Data(contentsOf: target)) != bytes { try bytes.write(to: target, options: .atomic) }
                }
            }
        } catch { NSLog("Meeting runtime preparation failed: %@", error.localizedDescription) }
        return root
    }()
    static var python: URL {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }
    static func settings() -> [String: Any] {
        ((try? Data(contentsOf: root.appendingPathComponent("settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }
    static func save(_ values: [String: Any]) throws {
        let lockURL = root.appendingPathComponent(".settings.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var current = settings(); current.merge(values) { _, new in new }
        try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }
    static var providerName: String { settings()["archive_provider"] as? String == "claude" ? "Claude" : "Codex" }
    static var vault: URL { URL(fileURLWithPath: settings()["vault_path"] as? String ?? root.appendingPathComponent("Vault").path) }
    static func tool(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [settings()[name+"_path"] as? String ?? "", "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] +
            (name == "codex" ? ["/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"] : [])
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
