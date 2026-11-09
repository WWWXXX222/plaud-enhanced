import Foundation
import Darwin

struct MeetingRecoveryReply: Decodable, Sendable {
    var state: String
    var message: String
}

enum MeetingRecovery {
    static func processingLease(_ directory: URL) -> Bool? {
        let fd = open(directory.appendingPathComponent(".processing.lock").path, O_RDONLY)
        guard fd >= 0 else { return errno == ENOENT ? false : nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK ? true : nil
    }
    static func activeMessage(_ directory: URL, canRestartOpenAI: Bool, now: Date = Date()) -> String {
        let progress = directory.appendingPathComponent("progress.json")
        guard canRestartOpenAI,
              let changed = (try? progress.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(changed) >= 600,
              let data = try? Data(contentsOf: progress), let status = try? JSONDecoder().decode(ProcessingStatus.self, from: data),
              status.state == "processing", let pid = status.pid, pid > 1, pid != getpid() else {
            return "任务仍在处理，已检查；不会重复启动。持续无进展时会自动恢复。"
        }
        let request: [String: Any] = ["pid": pid, "requested_at": now.timeIntervalSince1970]
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            try data.write(to: directory.appendingPathComponent("transcription-restart-request.json"), options: .atomic)
            return "长时间没有进展，已请求本次转写安全退出并自动续做；成功片段保留。"
        } catch { return "恢复请求未保存，请检查本机文件访问权限。" }
    }
}

@MainActor extension MeetingStore {
    func recoverMeeting(_ id: String) {
        guard let m = meetings.first(where: { $0.id == id }), m.capture_state == "captured", activeRecordingID != id,
              !recoveryInFlight.contains(id) else { return }
        guard !documentImports.contains(id), !submitting.contains(id) else {
            recoveryMessages[id] = "资料正在保存，完成后会自动继续。"; return
        }
        if jobs[id]?.state == "done" { recoveryMessages[id] = "这场会议已归档，无需重复处理。"; return }
        recoveryInFlight.insert(id); recoveryMessages[id] = "正在检查任务与已保存进度…"
        let directory = folder(id)
        Task {
            defer { recoveryInFlight.remove(id) }
            if locked(id) {
                let result = await Task.detached { Self.recoverArchive(directory) }.value
                recoveryMessages[id] = result.message
                refresh(); return
            }
            let lease = await Task.detached { MeetingRecovery.processingLease(directory) }.value
            if lease == nil { recoveryMessages[id] = "无法核对正在运行的任务，请检查文件访问权限；资料保持原状。"; return }
            if lease == true || cloudInFlight.contains(id) || hasLocalWorker(id) || plaudBusy.contains(id) {
                recoveryMessages[id] = await Task.detached { MeetingRecovery.activeMessage(directory, canRestartOpenAI: m.usesOpenAI) }.value
                return
            }
            if statuses[id]?.state == "complete" {
                submit(id); recoveryMessages[id] = "转写已完成，正在核验并交给 Codex；沿用同一条归档记录。"
            } else if m.cloud_upload == true {
                let checkpoint = uploadCheckpoint(id)
                guard checkpoint.phase != "invalid" else { recoveryMessages[id] = checkpoint.last_error; return }
                guard !checkpoint.needs_login else { recoveryMessages[id] = "Plaud 登录已失效，请在账户入口重新连接；录音和进度仍保留。"; return }
                startPlaudUpload(id)
                recoveryMessages[id] = "已从保存的进度继续处理，保留已有 Plaud 录音和成功转写。"
            } else {
                transcribe(id); recoveryMessages[id] = "已检查并恢复处理，原录音保持不变。"
            }
        }
    }
    nonisolated static func recoverArchive(_ directory: URL) -> MeetingRecoveryReply {
        let p = Process(); p.executableURL = AppRuntime.python
        p.arguments = [root.appendingPathComponent("archive_runner.py").path, "--recover", directory.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do {
            try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            if p.terminationStatus == 0 { return try JSONDecoder().decode(MeetingRecoveryReply.self, from: data) }
        } catch { }
        return MeetingRecoveryReply(state: "error", message: "暂未完成恢复检查，资料已保留；请检查本机访问权限。")
    }
}
