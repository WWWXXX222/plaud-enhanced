import Foundation
import AppKit
import UniformTypeIdentifiers
import SwiftUI

struct MeetingDocument: Codable, Identifiable, Sendable {
    var path: String
    var name: String
    var size: Int
    var sha256: String
    var text_path: String?
    var text_sha256: String?
    var extraction_status: String
    var note: String
    var source_url: String? = nil
    var id: String { sha256 }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

@MainActor extension MeetingStore {
    func pasteDocuments(_ id: String, from pasteboard: NSPasteboard = .general) {
        guard !locked(id), !documentImports.contains(id) else { return }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importDocuments(id, urls: urls); return
        }
        // Only explicit web links become references. Copied paths or arbitrary text
        // never grant file access, and adding a reference does not fetch a website.
        let value = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) ?? ""
        if let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            Task { await addDocumentLink(id, value: value) }; return
        }
        documentErrors[id] = "请先复制 Finder 中的文档，或完整的 http://、https:// 文档链接。"
    }
    func addDocuments(_ id: String) {
        guard !locked(id), !documentImports.contains(id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["pdf", "docx", "pptx", "xlsx", "md", "txt", "csv"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "文档会保留原件，并随会议交给 Codex 分析。每份不超过 25 MB，每场最多 10 份。"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.importDocuments(id, urls: panel.urls) }
        }
    }
    func importDocuments(_ id: String, urls: [URL]) {
        guard !locked(id), !documentImports.contains(id), let m = meetings.first(where: {$0.id == id}), !urls.isEmpty else { return }
        guard urls.count <= 10 else { documentErrors[id] = "一次最多添加 10 份文档。"; return }
        documentImports.insert(id); documentErrors[id] = nil
        let directory = folder(id); let previous = m.documents ?? []
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> (rows: [MeetingDocument], messages: [String]) in
                var rows = previous; var messages: [String] = []
                for url in urls {
                    do {
                        let row = try Self.prepareDocument(url, directory: directory)
                        if rows.contains(where: {$0.sha256 == row.sha256}) { continue }
                        guard rows.count < 10, rows.reduce(0, {$0+$1.size})+row.size <= 100*1024*1024 else { messages.append("文档超过每场 10 份或总计 100 MB 的限制。"); continue }
                        rows.append(row)
                    } catch { messages.append(url.lastPathComponent + "：" + error.localizedDescription) }
                }
                return (rows,messages)
            }.value
            // Auto-handoff waits for this import; publish metadata only when copies are ready.
            if !locked(id) {
                edit(id) { $0.documents = outcome.rows }
                documentErrors[id] = outcome.messages.isEmpty ? nil : outcome.messages.joined(separator: "\n")
            } else { documentErrors[id] = "会议已开始分析，本次添加未提交；原文件仍保留。" }
            documentImports.remove(id)
        }
    }
    nonisolated static func prepareDocument(_ source: URL, directory: URL) throws -> MeetingDocument {
        var args = [root.appendingPathComponent("meeting_documents.py").path, source.path, directory.path]
        if let helper = Bundle.main.url(forResource: "MeetingDocumentText", withExtension: nil) { args += ["--pdf-helper", helper.path] }
        return try runDocumentPreparation(args)
    }
    nonisolated static func prepareDocumentLink(_ value: String, name: String, directory: URL) throws -> MeetingDocument {
        try runDocumentPreparation([root.appendingPathComponent("meeting_documents.py").path, "--link", value, directory.path, "--name", name])
    }
    nonisolated static func runDocumentPreparation(_ args: [String]) throws -> MeetingDocument {
        let process = Process(); process.executableURL = AppRuntime.python
        process.arguments = args
        let out = Pipe(); let err = Pipe(); process.standardOutput = out; process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw MeetingError.message(detail ?? "文档未能添加，原文件没有修改。")
        }
        return try JSONDecoder().decode(MeetingDocument.self, from: data)
    }
    @discardableResult func addDocumentLink(_ id: String, value: String, name: String = "") async -> Bool {
        guard !locked(id), !documentImports.contains(id), meetings.contains(where: {$0.id == id}) else { return false }
        documentImports.insert(id); documentErrors[id] = nil
        defer { documentImports.remove(id) }
        let directory = folder(id)
        do {
            let row = try await Task.detached(priority: .utility) { try Self.prepareDocumentLink(value, name: name, directory: directory) }.value
            guard !locked(id), let current = meetings.first(where: {$0.id == id}) else { throw MeetingError.message("会议已开始分析，本次链接未提交。") }
            let previous = current.documents ?? []
            if previous.contains(where: { $0.source_url == row.source_url }) { return true }
            guard previous.count < 10, previous.reduce(0, {$0+$1.size})+row.size <= 100*1024*1024 else { throw MeetingError.message("每场最多添加 10 份文档或链接，总计不超过 100 MB。") }
            var updated = current; updated.documents = previous + [row]
            try persist(updated)
            if let index = meetings.firstIndex(where: {$0.id == id}) { meetings[index] = updated }
            return true
        } catch { documentErrors[id] = error.localizedDescription; return false }
    }
    func removeDocument(_ id: String, document: MeetingDocument) {
        guard !locked(id), !documentImports.contains(id) else { return }
        // Remove the reference; never delete the user's original or an archived copy.
        edit(id) { $0.documents?.removeAll { $0.id == document.id } }
    }
    func showDocument(_ id: String, document: MeetingDocument) {
        if let value = document.source_url, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            NSWorkspace.shared.open(url); return
        }
        let base = folder(id).standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(document.path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path+"/"), FileManager.default.fileExists(atPath: url.path) else { documentErrors[id] = "附件文件未找到。"; return }
        NSWorkspace.shared.open(url)
    }
}

struct DocumentLinkEditor: View {
    @ObservedObject var store: MeetingStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var saving = false
    @FocusState private var addressFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加文档链接").font(.title2.bold())
            TextField("粘贴 https:// 文档地址", text: $address).textFieldStyle(.roundedBorder).focused($addressFocused)
                .accessibilityLabel("文档链接地址")
            TextField("名称（选填）", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("文档链接名称")
            Text("支持在线文档和文件下载链接。链接随会议保存，Codex 分析时尝试读取；需要登录或无法访问时会明确标注。").font(.callout).foregroundStyle(.secondary)
            if let message = store.documentErrors[id] { Text(message).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("添加链接") {
                    saving = true
                    Task { let added = await store.addDocumentLink(id, value: address, name: name); saving = false; if added { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(saving || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.locked(id) || store.documentImports.contains(id))
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(saving)
            .onAppear { store.documentErrors[id] = nil; addressFocused = true }
    }
}
