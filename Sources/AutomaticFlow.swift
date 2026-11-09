import Foundation

enum AutomaticFlow {
    static let uploadAdapterRevision = "workspace-contract-v1"
    static func shouldResumeCloud(phase: String, materialComplete: Bool, error: String?, retryAt: Date?, now: Date = Date(), errorCode: String? = nil, adapterRevision: String? = nil) -> Bool {
        guard phase != "invalid", !(phase == "complete" && materialComplete) else { return false }
        // A verified adapter update can resume a previously blocked checkpoint
        // once. Preserve upload/object/recording identity; never clear the job.
        let legacyVersionError = "Plaud 网页版本已变化，上传已暂停；本机录音仍保留，需要更新连接适配。"
        if (errorCode == "VERSION" || error == legacyVersionError), adapterRevision != uploadAdapterRevision { return true }
        return error == nil || (retryAt.map { $0 <= now } ?? false)
    }
    static func canResumeUploadedOpenAI(openAI: Bool, summary: Bool, fileID: String?, expectedFileID: String?, account: String, expectedAccount: String?) -> Bool {
        openAI && !summary && fileID != nil && expectedFileID == "of_" + (fileID ?? "") &&
            !account.isEmpty && account == expectedAccount
    }
    static func retryDelay(attempt: Int) -> TimeInterval {
        min(900, 15 * pow(2, Double(min(max(attempt - 1, 0), 6))))
    }
    static func shouldHandoff(enabled: Bool, captured: Bool, complete: Bool, submitted: Bool, delivered: Bool) -> Bool {
        enabled && captured && !delivered && (complete || submitted)
    }
}
