import Foundation

struct PreparedAudio: Codable, Sendable {
    var filename: String
    var duration: Double
    var size: Int
    var sha256: String
}
struct UploadPart: Codable { var Etag: String; var PartNumber: Int }
struct UploadCheckpoint: Codable {
    var phase = "prepare"
    var account_id = ""
    var workspace_id = ""
    var recording_id = Int64(Date().timeIntervalSince1970 * 1000)
    var audio_sha256 = ""
    var transcription_language: String? = nil
    var transcription_engine: String? = nil
    var upload_id: String? = nil
    var object_name: String? = nil
    var parts: [UploadPart] = []
    var upload_route: String? = nil
    var file_id: String? = nil
    var last_error: String? = nil
    var last_error_code: String? = nil
    var adapter_revision: String? = nil
    var needs_login = false
    var retry_after: Date? = nil
    var attempts: Int? = 0
    var updated_at = Date()
}

extension MeetingStore {
    func uploadCheckpoint(_ id: String) -> UploadCheckpoint {
        let path = folder(id).appendingPathComponent("cloud-upload.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            var recovered = UploadCheckpoint()
            if let m = meetings.first(where: { $0.id == id }), let fid = m.plaud_file_id, fid.hasPrefix("of_") {
                recovered.file_id = String(fid.dropFirst(3)); recovered.account_id = m.plaud_account_id ?? ""; recovered.phase = "generate"
            }
            return recovered
        }
        guard let bytes = try? Data(contentsOf: path), let checkpoint = try? JSONDecoder().decode(UploadCheckpoint.self, from: bytes) else {
            var invalid = UploadCheckpoint(); invalid.phase = "invalid"; invalid.last_error = "上传进度文件无法读取，已暂停以防重复上传。"; return invalid
        }
        return checkpoint
    }
    func saveUpload(_ id: String, _ state: UploadCheckpoint) throws {
        let url = folder(id).appendingPathComponent("cloud-upload.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func cloudProgress(_ id: String, _ message: String, _ value: Double = 0, state: String = "processing") {
        let status = ProcessingStatus(state:state,message:message,progress:value,pid:ProcessInfo.processInfo.processIdentifier)
        statuses[id] = status
        let path = folder(id).appendingPathComponent("progress.json")
        try? JSONEncoder().encode(status).write(to:path,options:.atomic)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
    func checkUploadConnection() {
        Task {
            do {
                let identity = try await plaudWeb.call("identity")
                let response = await Task.detached { Self.plaudCommand(["plaud-account",Self.root.path]) }.value
                guard response.ok, let account = response.account, let workspace = account.workspace_id,
                      !workspace.isEmpty else { throw MeetingError.message(response.error ?? "请先连接 Plaud 账户。") }
                guard identity["workspace_id"] as? String == workspace else { throw PlaudWebFailure(code:"ACCOUNT") }
                plaudAccount = account
                plaudWeb.message = "已连接 \(account.name)，新录音将自动上传，并使用所选的转写方式。"
                showPlaudUploadLogin = false
                for m in meetings where m.cloud_upload == true && m.capture_state == "captured" && !locked(m.id) {
                    if uploadCheckpoint(m.id).phase != "complete" { startPlaudUpload(m.id) }
                }
            } catch { plaudWeb.message = error.localizedDescription }
        }
    }
    func resumeCloudUploads() {
        for m in meetings where m.cloud_upload == true && m.capture_state == "captured" && !locked(m.id) {
            let state = uploadCheckpoint(m.id)
            if AutomaticFlow.shouldResumeCloud(phase: state.phase, materialComplete: statuses[m.id]?.state == "complete",
                error: state.last_error, retryAt: state.retry_after,
                errorCode: state.last_error_code, adapterRevision: state.adapter_revision) { startPlaudUpload(m.id) }
        }
    }
    func startPlaudUpload(_ id: String) {
        guard !cloudInFlight.contains(id), !locked(id),
              let m = meetings.first(where:{$0.id == id}), m.capture_state == "captured" else { return }
        cloudInFlight.insert(id)
        Task { await processPlaudUpload(id, m: m) }
    }
    private func processPlaudUpload(_ id: String, m: Meeting) async {
            defer { cloudInFlight.remove(id); refresh() }
            var checkpoint = uploadCheckpoint(id)
            do {
                guard checkpoint.phase != "invalid" else { throw MeetingError.message("上传进度文件无法读取，已暂停以防重复上传。") }
                checkpoint.last_error = nil; checkpoint.needs_login = false; checkpoint.retry_after = nil
                checkpoint.last_error_code = nil
                checkpoint.adapter_revision = AutomaticFlow.uploadAdapterRevision
                // A confirmed upload is already linked to this recording/account.
                // Resume the local OpenAI work without re-opening a Plaud connection.
                if AutomaticFlow.canResumeUploadedOpenAI(openAI: m.usesOpenAI, summary: includesPlaudSummary(id),
                    fileID: checkpoint.file_id, expectedFileID: m.plaud_file_id,
                    account: checkpoint.account_id, expectedAccount: m.plaud_account_id) {
                    checkpoint.phase = "openai"; try saveUpload(id, checkpoint)
                    cloudProgress(id, "正在从已保存的片段恢复 OpenAI 转写…", 0.85)
                    let dir = folder(id)
                    let failure = await Task.detached { OpenAISettingsModel.transcribeMeeting(root: Self.root, folder: dir) }.value
                    if let failure { throw MeetingError.message(failure) }
                    guard !includesPlaudSummary(id) else { throw MeetingError.message("总结选项已改变，正在自动重新核验资料。") }
                    checkpoint.phase = "complete"; checkpoint.last_error = nil; checkpoint.updated_at = Date(); try saveUpload(id, checkpoint)
                    cloudProgress(id, "OpenAI 转写已就绪 · 正在自动归档", 1, state: "complete")
                    return
                }
                cloudProgress(id,"正在连接 Plaud…")
                let response = await Task.detached { Self.plaudCommand(["plaud-account",Self.root.path]) }.value
                guard response.ok, let account = response.account, let workspace = account.workspace_id, !workspace.isEmpty else {
                    throw MeetingError.message(response.error ?? "请先连接 Plaud 账户。")
                }
                if !checkpoint.account_id.isEmpty && checkpoint.account_id != account.id { throw PlaudWebFailure(code:"ACCOUNT") }
                if !checkpoint.workspace_id.isEmpty && checkpoint.workspace_id != workspace { throw PlaudWebFailure(code:"ACCOUNT") }
                checkpoint.account_id = account.id; checkpoint.workspace_id = workspace; plaudAccount = account
                try saveUpload(id,checkpoint)
                let identity = try await plaudWeb.call("identity")
                guard identity["workspace_id"] as? String == workspace else { throw PlaudWebFailure(code:"ACCOUNT") }
                let dir = folder(id)
                if checkpoint.file_id == nil {
                    let prepared = await Task.detached { Self.plaudCommand(["plaud-prepare",dir.path]) }.value
                    guard prepared.ok, let audio = prepared.prepared, audio.filename == "plaud-upload.mp3" else {
                        throw MeetingError.message(prepared.error ?? "录音整理尚未完成。")
                    }
                    if !checkpoint.audio_sha256.isEmpty && checkpoint.audio_sha256 != audio.sha256 {
                        throw MeetingError.message("这条录音的内容发生变化，已停止重复上传；请导入为新会议。")
                    }
                    checkpoint.audio_sha256 = audio.sha256
                    edit(id) { $0.duration = audio.duration }
                    if checkpoint.phase != "confirm" {
                        cloudProgress(id,"正在上传到你的 Plaud 账户…",0.1)
                        let signed = try await plaudWeb.call("presign",["workspace_id":workspace,"size":audio.size])
                        guard let uploadID = signed["upload_id"] as? String, let object = signed["object_name"] as? String,
                              let urls = signed["part_urls"] as? [String], urls.count == (audio.size + 5*1024*1024-1)/(5*1024*1024) else {
                            throw MeetingError.message("Plaud 上传响应不完整，已保留原始录音。")
                        }
                        checkpoint.phase = "upload"; checkpoint.upload_id = uploadID; checkpoint.object_name = object; checkpoint.parts = []
                        try saveUpload(id,checkpoint)
                        let handle = try FileHandle(forReadingFrom:dir.appendingPathComponent(audio.filename))
                        defer { try? handle.close() }
                        var uploadRoute = PlaudAudioTransport.Route.system
                        for (index, rawURL) in urls.enumerated() {
                            guard let bytes = try handle.read(upToCount:5*1024*1024), !bytes.isEmpty else { throw MeetingError.message("本机音频读取不完整。") }
                            let receipt = try await PlaudAudioTransport.upload(bytes, url:rawURL, startingRoute:uploadRoute)
                            uploadRoute = receipt.route
                            checkpoint.parts.append(UploadPart(Etag:receipt.etag,PartNumber:index+1))
                            checkpoint.upload_route = receipt.route == .direct ? "direct-after-connection-failure" : "system"
                            try saveUpload(id,checkpoint)
                            cloudProgress(id,"正在上传到 Plaud · \((index+1)*100/urls.count)%",0.1+0.65*Double(index+1)/Double(urls.count))
                        }
                        let parts: [[String:Any]] = checkpoint.parts.map { part in ["Etag":part.Etag,"PartNumber":part.PartNumber] }
                        _ = try await plaudWeb.call("merge",["workspace_id":workspace,"upload_id":uploadID,"object_name":object,"parts":parts])
                        // Persist before confirmation. Retrying confirmation reuses the same object and stable serial.
                        checkpoint.phase = "confirm"; try saveUpload(id,checkpoint)
                    }
                    guard let uploadID = checkpoint.upload_id, let object = checkpoint.object_name else { throw MeetingError.message("上传检查点缺失。") }
                    cloudProgress(id,"正在确认 Plaud 已收到录音…",0.8)
                    let confirmPayload: [String:Any] = ["workspace_id":workspace,"upload_id":uploadID,"object_name":object,
                        "title":meetings.first(where:{$0.id == id})?.title ?? m.title,"recording_id":checkpoint.recording_id,"serial_number":m.id]
                    let confirmed = try await plaudWeb.call("confirm",confirmPayload)
                    guard let fileID = confirmed["file_id"] as? String, fileID.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil else {
                        throw MeetingError.message("Plaud 未返回可识别的录音编号；保留上传检查点，重试不会重新传音频。")
                    }
                    checkpoint.file_id = fileID; checkpoint.phase = "generate"; try saveUpload(id,checkpoint)
                }
                guard let fileID = checkpoint.file_id else { throw MeetingError.message("Plaud 录音编号缺失。") }
                edit(id) { $0.source = "Plaud"; $0.plaud_file_id = "of_"+fileID; $0.plaud_account_id = account.id }
                if m.transcription_engine == "local" {
                    checkpoint.phase = "local"; try saveUpload(id, checkpoint)
                    let result = await Task.detached(priority: .utility) { Self.command(["transcribe", dir.path], log: dir.appendingPathComponent("worker.log")) }.value
                    guard result.code == 0 else { throw MeetingError.message("本机转写暂时中断，已有进度保留。") }
                    checkpoint.phase = "complete"; checkpoint.last_error = nil; checkpoint.updated_at = Date()
                    try saveUpload(id, checkpoint)
                    cloudProgress(id, "离线转写已完成 · 正在自动归档", 1, state: "complete")
                    return
                }
                checkpoint.transcription_engine = m.usesOpenAI ? "openai" : "plaud"
                if m.usesOpenAI {
                    checkpoint.phase = "openai"; try saveUpload(id, checkpoint)
                    cloudProgress(id, "已上传 Plaud · OpenAI 正在保留中英原文…", 0.85)
                    let failure = await Task.detached { OpenAISettingsModel.transcribeMeeting(root: Self.root, folder: dir) }.value
                    if let failure { throw MeetingError.message(failure) }
                    let includeSummary = includesPlaudSummary(id)
                    if includeSummary {
                        cloudProgress(id, "OpenAI 原文已就绪 · 正在等待所选 Plaud 总结…", 0.97)
                        _ = try await plaudWeb.call("generate", ["workspace_id":workspace, "file_id":fileID, "language":m.language])
                        var summaryReady = false
                        for _ in 0..<120 {
                            if !includesPlaudSummary(id) { summaryReady = true; break }
                            let result = await Task.detached { Self.plaudCommand(["plaud-summary", dir.path]) }.value
                            if result.ok { summaryReady = true; break }
                            guard result.error?.contains("尚未") == true else { throw MeetingError.message(result.error ?? "Plaud 总结暂未同步。") }
                            try await Task.sleep(for: .seconds(15))
                        }
                        guard summaryReady else { throw MeetingError.message("Plaud 总结仍在处理，OpenAI 原文已保留；稍后继续即可。") }
                    }
                    guard includeSummary == includesPlaudSummary(id) else { throw MeetingError.message("总结选项已改变，正在自动重新核验资料。") }
                    checkpoint.phase = "complete"; checkpoint.last_error = nil; checkpoint.updated_at = Date(); try saveUpload(id, checkpoint)
                    cloudProgress(id, "OpenAI 转写已就绪 · 正在自动归档", 1, state: "complete")
                    return
                }
                // is_reload=0 follows Plaud Desktop's polling protocol and does not regenerate completed work.
                cloudProgress(id,"已上传 · Plaud 正在转写，可先补充背景与截图…",0.85)
                // Freeze the chosen input language before submitting; retries must
                // not silently change the recording's generation configuration.
                if checkpoint.transcription_language == nil {
                    checkpoint.transcription_language = m.language
                    try saveUpload(id,checkpoint)
                }
                _ = try await plaudWeb.call("generate",["workspace_id":workspace,"file_id":fileID,"language":checkpoint.transcription_language ?? m.language])
                // The combined generation status includes summary completion. Poll the
                // transcript independently so the default path never waits for a summary.
                checkpoint.phase = "sync"; try saveUpload(id,checkpoint)
                var synced = false
                for _ in 0..<120 {
                    let policy = includesPlaudSummary(id)
                    let result = await Task.detached { Self.plaudCommand(["plaud-refresh",dir.path]) }.value
                    if !result.ok { throw MeetingError.message(result.error ?? "Plaud 结果同步尚未完成。") }
                    if let data = try? Data(contentsOf:dir.appendingPathComponent("progress.json")),
                       let status = try? JSONDecoder().decode(ProcessingStatus.self,from:data), status.state == "complete",
                       policy == includesPlaudSummary(id) { synced = true; break }
                    refresh()
                    try await Task.sleep(for:.seconds(15))
                }
                guard synced else { throw MeetingError.message("Plaud 仍在处理所选资料，稍后继续即可；不会重复上传。") }
                checkpoint.phase = "complete"; checkpoint.last_error = nil; checkpoint.updated_at = Date(); try saveUpload(id,checkpoint)
                cloudProgress(id,"Plaud 所选资料已就绪 · 正在自动归档",1,state:"complete")
            } catch {
                checkpoint.last_error = error.localizedDescription
                checkpoint.needs_login = (error as? PlaudWebFailure)?.code == "LOGIN"
                let code = (error as? PlaudWebFailure)?.code ?? ""
                checkpoint.last_error_code = code.isEmpty ? nil : code
                let saved = (try? Data(contentsOf: folder(id).appendingPathComponent("progress.json"))).flatMap { try? JSONDecoder().decode(ProcessingStatus.self, from: $0) }
                let transient = code == "CONNECTION" || error.localizedDescription.hasPrefix("音频上传中断") ||
                    saved?.retryable == true || error.localizedDescription.contains("仍在处理") ||
                    error.localizedDescription.contains("选项已改变") || error.localizedDescription.contains("超时") ||
                    error.localizedDescription.hasPrefix("暂时无法连接") || error.localizedDescription.hasPrefix("本机转写暂时中断")
                checkpoint.attempts = (checkpoint.attempts ?? 0) + 1
                if transient {
                    let delay = error.localizedDescription.hasPrefix("已恢复无进展的转写") ? 15 : AutomaticFlow.retryDelay(attempt: checkpoint.attempts ?? 1)
                    checkpoint.retry_after = Date().addingTimeInterval(delay)
                }
                if checkpoint.phase != "invalid" { try? saveUpload(id,checkpoint) }
                cloudProgress(id,transient ? "处理暂时中断，已保存进度，正在等待自动恢复。" : error.localizedDescription,state:transient ? "retry_wait" : "error")
            }
    }
}
