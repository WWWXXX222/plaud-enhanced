import Foundation
import SwiftUI

struct MeetingStorageInfo: Decodable, Sendable {
    var local_bytes: Int64 = 0
    var candidate_bytes: Int64 = 0
    var keep_originals: Bool = false
    var originals_available: Bool = true
    var message: String = ""
}

struct StorageReport: Decodable, Sendable {
    var enabled: Bool = true
    var raw_retention_days: Int = 7
    var local_bytes: Int64 = 0
    var candidate_bytes: Int64 = 0
    var duplicate_bytes: Int64 = 0
    var expired_bytes: Int64 = 0
    var cache_bytes: Int64 = 0
    var cleaned_bytes: Int64 = 0
    var meetings: [String: MeetingStorageInfo] = [:]
    var message: String = ""
    static func size(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

extension MeetingStore {
    nonisolated static func storageCommand(_ args: [String]) throws -> StorageReport {
        let process = Process()
        process.executableURL = AppRuntime.python
        process.arguments = [root.appendingPathComponent("storage_maintenance.py").path] + args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"] ?? "存储检查未完成，文件已保留。"
            throw NSError(domain: "MeetingStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(StorageReport.self, from: data)
    }

    func updateStorage(_ args: [String] = []) {
        guard !storageBusy else { return }
        storageBusy = true
        storageMessage = ""
        Task {
            defer { storageBusy = false }
            do { storageReport = try await Task.detached(priority: .utility) { try Self.storageCommand(args) }.value }
            catch { storageMessage = error.localizedDescription }
        }
    }

    func maintainStorage(automatic: Bool = true) {
        guard !isBusyRecording, !storageBusy else { return }
        storageMessage = "正在核验并整理；压缩录音和会议记录会保留。"
        storageBusy = true
        Task {
            defer { storageBusy = false }
            do {
                let report = try await Task.detached(priority: .utility) {
                    try Self.storageCommand(automatic ? ["--run", "--automatic"] : ["--run"])
                }.value
                storageReport = report
                storageMessage = report.cleaned_bytes > 0 ? "已清理文件大小：\(StorageReport.size(report.cleaned_bytes))。\(report.message)" : report.message
            } catch { storageMessage = error.localizedDescription }
        }
    }

    func saveStorageSettings(enabled: Bool, days: Int) {
        updateStorage(["--configure", enabled ? "on" : "off", "--days", String(days)])
    }

    func keepOriginals(_ id: String, _ keep: Bool) {
        updateStorage(["--meeting", id, "--keep", keep ? "yes" : "no"])
    }
}

struct StorageSettingsSection: View {
    @ObservedObject var store: MeetingStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("录音存储管理").font(.headline)
            Toggle("自动整理已完成的会议", isOn: Binding(get: { store.storageReport.enabled }, set: {
                store.saveStorageSettings(enabled: $0, days: store.storageReport.raw_retention_days)
            })).disabled(store.storageBusy)
            Picker("原始双轨保留", selection: Binding(get: { store.storageReport.raw_retention_days }, set: {
                store.saveStorageSettings(enabled: store.storageReport.enabled, days: $0)
            })) {
                Text("归档完成后 7 天").tag(7)
                Text("归档完成后 30 天").tag(30)
                Text("归档完成后 90 天").tag(90)
                Text("一直保留").tag(0)
            }.disabled(store.storageBusy)
            Text("仅整理上传、转写和分析归档均完成的会议。核验后去除原始音轨的重复副本，清理临时音频；到期后清理原始双轨。完整压缩录音、转写、分析和附件继续保留，重要会议可单独选择长期保留。录音期间延后整理。").font(.caption).foregroundStyle(.secondary)
            Text("本机会议目录：\(StorageReport.size(store.storageReport.local_bytes)) · 待核验可整理：\(StorageReport.size(store.storageReport.candidate_bytes))")
                .font(.callout)
            Text("重复音轨 \(StorageReport.size(store.storageReport.duplicate_bytes)) · 过期原始音轨 \(StorageReport.size(store.storageReport.expired_bytes)) · 临时音频 \(StorageReport.size(store.storageReport.cache_bytes))")
                .font(.caption).foregroundStyle(.secondary)
            Text("待整理范围含 App 与知识库中的音频，按文件大小统计；实际释放空间可能不同。清理后无法恢复原始独立双轨，保留的压缩录音仍可回听。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("刷新占用") { store.updateStorage() }.disabled(store.storageBusy)
                Button(store.storageBusy ? "正在检查…" : "检查并整理") { store.maintainStorage(automatic: false) }
                    .disabled(store.storageBusy || store.isBusyRecording)
            }
            if store.isBusyRecording { Text("录音结束后再整理，不影响当前会议。").font(.caption).foregroundStyle(.secondary) }
            if !store.storageMessage.isEmpty { Text(store.storageMessage).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { store.updateStorage() }
    }
}

struct MeetingStorageSection: View {
    @ObservedObject var store: MeetingStore
    let id: String
    var body: some View {
        let info = store.storageReport.meetings[id] ?? MeetingStorageInfo()
        CollapsibleSection("录音存储", key: "storage", subtitle: StorageReport.size(info.local_bytes), symbol: "internaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("长期保留这场会议的原始双轨", isOn: Binding(get: { info.keep_originals }, set: { store.keepOriginals(id, $0) }))
                    .disabled(store.storageBusy || !info.originals_available)
                Text(info.message.isEmpty ? "默认按全局保留策略整理；录音与处理期间保留所有资料。" : info.message)
                    .font(.caption).foregroundStyle(.secondary)
                Text("重复原始音轨核验后只保留知识库中的一份。压缩录音、转写、分析与附件始终保留。").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { store.updateStorage() }
    }
}
