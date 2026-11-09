import Foundation
import Darwin

struct ArchiveReceipt: Decodable, Sendable {
    var state: String
    var started_at: String?
    var retry_at: Double?
    var message: String?
}

struct ArchiveProgress: Sendable, Equatable {
    var title: String
    var detail: String
    var active: Bool

    // The worker holds this kernel lease while running or waiting for the shared
    // chat. A persisted PID or the canonical "processing" state alone is stale
    // after a crash and must never be presented as proof of ongoing activity.
    static func workerLease(_ directory: URL) -> Bool? {
        let fd = open(directory.appendingPathComponent(".archive-run.lock").path, O_RDONLY)
        guard fd >= 0 else { return errno == ENOENT ? false : nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK ? true : nil
    }

    static func read(_ directory: URL, jobState: String, now: Date = Date()) -> ArchiveProgress? {
        var receipt = (try? Data(contentsOf: directory.appendingPathComponent("archive-trigger.json")))
            .flatMap { try? JSONDecoder().decode(ArchiveReceipt.self, from: $0) }
        if receipt?.state == "blocked" { return describe(receipt: receipt, lease: false, lastActivity: nil, now: now) }
        guard ["ready", "processing"].contains(jobState) else { return nil }
        // Native Codex owns the canonical job. A manual historical submission
        // has no automatic App handoff loop to refresh its display receipt.
        if let state = receipt?.state, ["native_ready", "native_processing"].contains(state) {
            receipt?.state = jobState == "processing" ? "native_processing" : "native_ready"
        }
        let activity = (try? directory.appendingPathComponent("archive-codex-events.jsonl")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return describe(receipt: receipt, lease: workerLease(directory), lastActivity: activity, now: now)
    }

    static func describe(receipt: ArchiveReceipt?, lease: Bool?, lastActivity: Date?, now: Date) -> ArchiveProgress {
        guard let receipt else {
            return Self(title: "等待后台分析", detail: "会议资料已保存，正在自动交接。", active: false)
        }
        if receipt.state == "blocked" {
            return Self(title: "归档需要检查", detail: receipt.message ?? "资料已保留，请检查权限或原始证据。", active: false)
        }
        if receipt.state == "held" {
            return Self(title: "自动分析已关闭", detail: "会议资料已保留；在设置中开启后会自动处理。", active: false)
        }
        if receipt.state == "queued" {
            return Self(title: "等待后台分析", detail: "按会议顺序处理，完成后完整结果显示在 App 与知识库。", active: false)
        }
        if receipt.state == "native_ready" {
            return Self(title: "等待 Codex 自动分析", detail: "资料已保存；Codex 每 5 分钟自动检查，无需提交或重试。", active: false)
        }
        if receipt.state == "native_processing" {
            return Self(title: "后台正在分析归档", detail: "已由原有 Codex 聊天领取；中断后会自动续做。", active: true)
        }
        if receipt.state == "pending" {
            let seconds = max(0, Int(ceil((receipt.retry_at ?? 0) - now.timeIntervalSince1970)))
            let when = seconds > 60 ? "约 \((seconds + 59) / 60) 分钟后" : seconds > 0 ? "约 \(seconds) 秒后" : "即将"
            return Self(title: "分析将自动续做", detail: "已有进度已保存，最早\(when)重试；本机每 30 分钟检查恢复。", active: false)
        }
        guard lease == true else {
            return Self(title: "分析等待自动恢复", detail: "正在核对执行状态，已有资料与分析进度保留。", active: false)
        }
        guard receipt.state == "running" else {
            return Self(title: "分析排队中", detail: "按会议顺序分析，轮到本场后自动开始。", active: false)
        }
        let started = receipt.started_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        let minutes = started.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
        let elapsed = minutes.map { $0 == 0 ? "不足 1 分钟" : "\($0) 分钟" }
        let title = "后台正在分析" + (elapsed.map { " · 已运行 " + $0 } ?? "")
        // Old retry logs cannot count as activity for a newly started attempt.
        guard let lastActivity, let started, lastActivity >= started else {
            return Self(title: title, detail: "正在建立分析会话，尚未收到新的执行记录。", active: true)
        }
        let quietMinutes = max(0, Int(now.timeIntervalSince(lastActivity) / 60))
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
        let freshness = quietMinutes == 0 ? "刚刚有新活动" : "\(quietMinutes) 分钟前有活动"
        let detail = "最近活动 \(clock.string(from: lastActivity))（\(freshness)）"
            + (quietMinutes >= 5 ? "；暂未收到新进展，超时后会自动续做。" : "；中断后会自动续做。")
        return Self(title: title, detail: detail, active: true)
    }
}
