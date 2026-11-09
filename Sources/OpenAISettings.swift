import Foundation
import Darwin
import Security
import LocalAuthentication
import SwiftUI

enum OpenAIKeyError: LocalizedError {
    case invalid, missing, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid: return "请输入有效的 OpenAI API Key。"
        case .missing: return "请先保存 OpenAI API Key。"
        case .keychain: return "钥匙串访问未完成，请解锁 Mac 或允许本应用访问后重试。"
        }
    }
}

// A single app-owned item; never enumerate other credentials or echo its value.
enum OpenAIKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.local.meetingmemory.mac.openai",
         kSecAttrAccount as String: "audio-api-key",
         kSecAttrSynchronizable as String: false]
    }
    static func valid(_ value: String) -> Bool {
        value.hasPrefix("sk-") && (20...1024).contains(value.utf8.count) && !value.contains(where: { $0.isWhitespace })
    }
    static func exists() throws -> Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw OpenAIKeyError.keychain(status) }
        return true
    }
    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(key) else { throw OpenAIKeyError.invalid }
        let changes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(changes) { _, new in new }
            item[kSecAttrLabel as String] = "Plaud威力加强版 · OpenAI 语音 API"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw OpenAIKeyError.keychain(status) }
    }
    static func read() throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { throw OpenAIKeyError.missing }
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), valid(key) else { throw OpenAIKeyError.keychain(status) }
        return key
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenAIKeyError.keychain(status) }
    }
}

struct OpenAIComparisonResult: Decodable, Sendable, Identifiable {
    var model: String
    var status: String
    var http_status: Int?
    var error_code: String?
    var id: String { model }
    var display: String {
        if status == "success" { return "已返回结果" }
        switch error_code {
        case "invalid_api_key": return "密钥无效，请重新保存"
        case "insufficient_quota": return "API 额度不足，请检查 OpenAI 账户"
        case "model_not_found": return "当前 API 项目无法使用此模型"
        case "rate_limit_exceeded": return "调用频率受限，稍后重试"
        default: return "未完成" + (http_status.map { "（HTTP \($0)）" } ?? "，请检查网络")
        }
    }
}
struct OpenAIComparisonRun: Decodable, Sendable {
    var phase: String
    var message: String
    var results: [OpenAIComparisonResult]
}

@MainActor final class OpenAISettingsModel: ObservableObject {
    let root: URL
    @Published var hasKey = false
    @Published var saving = false
    @Published var running = false
    @Published var keyMessage = "尚未配置密钥"
    @Published var testMessage = "使用同一段 56 秒、三种合成音色的中英混合音频。"
    @Published var results: [OpenAIComparisonResult] = []
    @Published var report = ""
    @Published var complete = false
    var evidence: URL { root.appendingPathComponent("evidence/openai-comparison-2026-10-18") }
    init(root: URL) { self.root = root }

    nonisolated static func transcribeMeeting(root: URL, folder: URL) -> String? {
        do {
            var key = try OpenAIKeychain.read()
            defer { key = "" }
            let process = Process(); let input = Pipe()
            process.executableURL = AppRuntime.python
            process.arguments = [root.appendingPathComponent("openai_transcription.py").path, folder.path]
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            do { try input.fileHandleForWriting.write(contentsOf: Data(key.utf8)); try input.fileHandleForWriting.close() }
            catch { try? input.fileHandleForWriting.close(); process.terminate(); return "OpenAI 转写启动暂时中断，正在自动恢复。" }
            key = ""
            let launched = Date()
            var restarted = false
            while process.isRunning {
                let progress = folder.appendingPathComponent("progress.json")
                let modified = (try? progress.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? launched
                let request = (try? Data(contentsOf: folder.appendingPathComponent("transcription-restart-request.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] }
                if TranscriptionWatchdog.shouldRestart(pid: process.processIdentifier, launched: launched, modified: modified, request: request) {
                    TranscriptionWatchdog.stopOwned(process); restarted = true
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return nil }
            if let data = try? Data(contentsOf: folder.appendingPathComponent("progress.json")),
               let status = try? JSONDecoder().decode(ProcessingStatus.self, from: data),
               process.terminationReason != .uncaughtSignal,
               !["processing", "openai_ready"].contains(status.state) { return status.message }
            // A killed worker cannot write its own failure record. Persist a
            // retryable state here so the upload coordinator resumes its cache.
            let message = restarted ? "已恢复无进展的转写，正在从成功片段续做。" : "OpenAI 处理意外中断，已保存片段将自动续跑。"
            let status = ProcessingStatus(state: "retry_wait", message: message, progress: 0, pid: nil, retryable: true)
            if let data = try? JSONEncoder().encode(status) { try? data.write(to: folder.appendingPathComponent("progress.json"), options: .atomic) }
            return message
        } catch {
            let retryable: Bool
            switch error { case OpenAIKeyError.missing, OpenAIKeyError.invalid: retryable = false; default: retryable = true }
            let message = error is OpenAIKeyError ? error.localizedDescription : "OpenAI 启动暂时中断，正在自动恢复。"
            let status = ProcessingStatus(state: retryable ? "retry_wait" : "error", message: message, progress: 0, pid: nil, retryable: retryable)
            if let data = try? JSONEncoder().encode(status) { try? data.write(to: folder.appendingPathComponent("progress.json"), options: .atomic) }
            return message
        }
    }

    func refresh() {
        Task {
            let found = await Task.detached { () -> Result<Bool, Error> in Result { try OpenAIKeychain.exists() } }.value
            switch found {
            case .success(let exists): hasKey = exists; keyMessage = exists ? "已保存到此 Mac 的钥匙串" : "尚未配置密钥"
            case .failure(let error): keyMessage = error.localizedDescription
            }
            await loadResults()
        }
    }
    func save(_ value: String) {
        guard !saving, !running else { return }
        saving = true; keyMessage = "正在保存到钥匙串…"
        Task {
            let saved = await Task.detached { () -> Result<Void, Error> in Result { try OpenAIKeychain.save(value) } }.value
            saving = false
            switch saved {
            case .success: hasKey = true; keyMessage = "已保存到此 Mac 的钥匙串 · 尚未验证 API 权限"
            case .failure(let error): keyMessage = error.localizedDescription
            }
        }
    }
    func remove() {
        guard !saving, !running else { return }
        saving = true
        Task {
            let removed = await Task.detached { () -> Result<Void, Error> in Result { try OpenAIKeychain.remove() } }.value
            saving = false
            switch removed {
            case .success: hasKey = false; keyMessage = "已移除此 App 保存的密钥"
            case .failure(let error): keyMessage = error.localizedDescription
            }
        }
    }
    func loadResults() async {
        let directory = evidence
        let snapshot = await Task.detached { () -> (OpenAIComparisonRun?, String) in
            let status = (try? Data(contentsOf: directory.appendingPathComponent("run.json")))
                .flatMap { try? JSONDecoder().decode(OpenAIComparisonRun.self, from: $0) }
            let report = (try? String(contentsOf: directory.appendingPathComponent("COMPARISON.md"), encoding: .utf8)) ?? ""
            return (status, report)
        }.value
        if let status = snapshot.0 {
            results = status.results; complete = status.phase == "complete"
            testMessage = complete ? "两项测试已完成。原始结果已保留，不会重复调用。" : status.message
        }
        report = snapshot.1
    }
    func compare() {
        guard hasKey, !saving, !running, !complete else { return }
        running = true; testMessage = "正在调用 OpenAI，预计需要约一分钟…"
        let project = root
        Task {
            let result = await Task.detached { () -> Result<Int32, Error> in
                Result {
                    var key = try OpenAIKeychain.read()
                    defer { key = "" }
                    let process = Process()
                    process.executableURL = AppRuntime.python
                    process.arguments = [project.appendingPathComponent("tools/openai_comparison.py").path, "--stdin-key"]
                    let input = Pipe()
                    process.standardInput = input
                    // The key travels only over stdin, never in arguments, environment or logs.
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    do {
                        try input.fileHandleForWriting.write(contentsOf: Data(key.utf8))
                        try input.fileHandleForWriting.close()
                    } catch {
                        try? input.fileHandleForWriting.close(); process.terminate()
                        throw OpenAIKeyError.missing
                    }
                    key = ""
                    process.waitUntilExit()
                    return process.terminationStatus
                }
            }.value
            running = false
            await loadResults()
            switch result {
            case .failure(let error): testMessage = error is OpenAIKeyError ? error.localizedDescription : "本机测试未能启动，请重试。"
            case .success(let code):
                if code != 0 && results.isEmpty { testMessage = "测试尚未完成，请检查密钥与网络后重试。" }
            }
        }
    }
}

struct OpenAISettingsSection: View {
    @ObservedObject var model: OpenAISettingsModel
    @State private var key = ""
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("OpenAI 转写", systemImage: "waveform").font(.headline); Spacer(); Text("可选").font(.caption).foregroundStyle(.secondary) }
            Text("API Key 只保存到本机钥匙串，不进入会议资料、日志或 Codex 归档。").font(.caption).foregroundStyle(.secondary)
            SecureField(model.hasKey ? "输入新密钥以替换" : "输入 OpenAI API Key（sk-…）", text: $key)
                .textFieldStyle(.roundedBorder).accessibilityLabel("OpenAI API Key")
                .disabled(model.saving || model.running)
                .onSubmit { saveKey() }
            HStack {
                Button(model.hasKey ? "更新密钥" : "保存密钥") { saveKey() }.disabled(!OpenAIKeychain.valid(key.trimmingCharacters(in: .whitespacesAndNewlines)) || model.saving || model.running)
                Button("移除密钥") { key = ""; model.remove() }.disabled(!model.hasKey || model.saving || model.running)
                if model.saving { ProgressView().controlSize(.small) }
            }
            Text(model.keyMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("openai-key-status")
            if Bundle.main.object(forInfoDictionaryKey: "MeetingProjectRoot") != nil {
            Divider()
            HStack {
                Button(model.running ? "正在测试…" : model.complete ? "同段音频测试已完成" : "运行同段音频对比") { model.compare() }
                    .disabled(!model.hasKey || model.saving || model.running || model.complete)
                if model.running { ProgressView().controlSize(.small) }
            }
            Text(model.testMessage).font(.caption).foregroundStyle(.secondary)
            if !model.complete { Text("仅发送内置测试音频到 OpenAI，预计约 US$0.01；保存密钥不会发起调用。").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.results) { result in
                HStack(alignment: .top) { Text(result.model); Spacer(); Text(result.display) }.font(.caption)
            }
            if !model.report.isEmpty {
                DisclosureGroup("查看本次对比结果", isExpanded: $expanded) {
                    Text(model.report).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.callout)
            }
            }
            Text("新录音可选择离线、Plaud 或 OpenAI。OpenAI 优先保留中英原文，时间轴作为独立回听参考，所有说话人待确认。").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(Color(white: 0.97)).clipShape(RoundedRectangle(cornerRadius: 10))
            .task { model.refresh() }
            .onDisappear { key = "" }
    }
    private func saveKey() {
        let value = key; key = ""; model.save(value)
    }
}
