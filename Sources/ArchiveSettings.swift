import Foundation
import AppKit

struct ArchiveSettings: Decodable, Sendable {
    var archive_auto_trigger: Bool?
    var archive_result_view: String?
    var automatic: Bool { archive_auto_trigger ?? true }
    var resultView: String { archive_result_view == "codex" ? "codex" : "app" }
    static func read(_ root: URL) -> Self {
        (try? Data(contentsOf: root.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
}

extension MeetingStore {
    nonisolated static func archiveCommand(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = AppRuntime.python
        process.arguments = [root.appendingPathComponent("archive_runner.py").path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }
    func saveArchiveSettings(automatic: Bool, resultView: String) async -> Bool {
        let success = await Task.detached {
            Self.archiveCommand(["--configure", automatic ? "automatic" : "manual", "--result-view", resultView])
        }.value
        if success { archiveSettings = ArchiveSettings(archive_auto_trigger: automatic, archive_result_view: resultView) }
        else { error = "归档设置未保存，请检查本机文件访问权限。" }
        return success
    }
    func recoverArchives() {
        Task { _ = await Task.detached(priority: .utility) { Self.archiveCommand([]) }.value }
    }
    func showAnalysisFile(_ id: String) {
        guard let path = jobs[id]?.outputs?.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func discussAnalysis(_ id: String) {
        guard let text = analysis[id], let path = jobs[id]?.outputs?.first else { openCodex(); return }
        let title = meetingTitle(id)
        let content = "请基于这份已归档的分析继续讨论；无需重复归档。\n会议：\(title)\n已有记录：\(path)\n\n\(text)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        openCodex()
    }
}
