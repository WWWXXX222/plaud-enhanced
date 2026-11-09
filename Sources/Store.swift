import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Meeting: Codable, Identifiable, Sendable {
    var id = "mm_" + UUID().uuidString.lowercased()
    var title = ""
    var created_at = ISO8601DateFormatter().string(from: Date())
    var participants = ""
    var purpose = ""
    var notes = ""
    var images: [String] = []
    var documents: [MeetingDocument]? = nil
    var audio_files: [String] = []
    var capture_state = "draft"
    var capture_mode = "microphone+system"
    var capture_warning: String? = nil
    var duration: Double = 0
    var language = "auto"
    var is_test = false
    var cloud_upload: Bool? = nil
    var include_plaud_summary: Bool? = nil
    var source: String? = nil
    var plaud_file_id: String? = nil
    var plaud_account_id: String? = nil
    var transcription_engine: String? = nil
    var auto_archive: Bool? = true
    var autoArchive: Bool { auto_archive == true }
    var usesOpenAI: Bool { transcription_engine == "openai" }
    var engineName: String { usesOpenAI ? "OpenAI" : transcription_engine == "local" ? "本机离线" : "Plaud" }
    var isPlaud: Bool { source == "Plaud" }
    var usesPlaud: Bool { isPlaud || cloud_upload == true }
}
struct ProcessingStatus: Codable, Sendable, Equatable {
    var state: String
    var message: String
    var progress: Double
    var pid: Int32?
    var retryable: Bool? = nil
}
struct Segment: Codable, Identifiable, Sendable, Equatable {
    var start_seconds: Double
    var end_seconds: Double?
    var speaker: String? = nil
    var text: String
    var speaker_scope: String? = nil
    var part_index: Int? = nil
    var speaker_issues: [String]? = nil
    var id: Double { start_seconds }
}
struct Transcript: Codable, Sendable, Equatable { var segments: [Segment]; var duration: Double; var text: String? = nil; var source: String? = nil; var timestamp_role: String? = nil }
struct Receipt: Codable, Sendable { var file_id: String; var job_path: String; var raw_dir: String }
struct QueueJob: Codable, Sendable, Equatable { var state: String; var outputs: [String]?; var last_error: String?; var include_plaud_summary: Bool? }
struct CommandResult: Sendable { var code: Int32; var output: String }
struct DiskSnapshot: Sendable {
    var archiveProgress: [String: ArchiveProgress] = [:]
    var delivered: Set<String> = []
    var statuses: [String: ProcessingStatus] = [:]
    var transcripts: [String: Transcript] = [:]
    var jobs: [String: QueueJob] = [:]
    var analysis: [String: String] = [:]
    var summaries: [String: String] = [:]
}

@MainActor final class MeetingStore: ObservableObject {
    nonisolated static let root = AppRuntime.root
    let data = root.appendingPathComponent("data/meetings", isDirectory: true)
    @Published var meetings: [Meeting] = []
    @Published var meetingTitles: [String: MeetingTitleRecord] = [:]
    var titleReadFailures: Set<String> = []
    @Published var selected: String? = nil
    @Published var statuses: [String: ProcessingStatus] = [:]
    @Published var transcripts: [String: Transcript] = [:]
    @Published var transcriptExports: Set<String> = []
    @Published var transcriptExportMessages: [String: String] = [:]
    @Published var storageReport = StorageReport()
    @Published var storageBusy = false
    @Published var storageMessage = ""
    @Published var jobs: [String: QueueJob] = [:]
    @Published var archiveProgress: [String: ArchiveProgress] = [:]
    @Published var analysis: [String: String] = [:]
    @Published var archiveSettings = ArchiveSettings()
    @Published var summaries: [String: String] = [:]
    @Published var showPlaudUploadLogin = false
    @Published var showingSettings = false
    @Published var showingOnboarding = false
    let openAI = OpenAISettingsModel(root: MeetingStore.root)
    @Published var cloudInFlight: Set<String> = []
    let plaudWeb = PlaudWebSession()
    @Published var showingPlaud = false
    @Published var plaudAccount: PlaudAccount? = nil
    @Published var plaudRecordings: [PlaudRecording] = []
    @Published var plaudLoading = false
    @Published var plaudOpeningID: String? = nil
    @Published var plaudBusy: Set<String> = []
    @Published var plaudMessage: String? = nil
    @Published var plaudPage = 1
    @Published var plaudHasMore = false
    @Published var error: String? = nil
    @Published var documentImports: Set<String> = []
    @Published var documentErrors: [String: String] = [:]
    @Published var recoveryInFlight: Set<String> = []
    @Published var recoveryMessages: [String: String] = [:]
    @Published var isStarting = false
    @Published var isStopping = false
    @Published var submitting: Set<String> = []
    @Published var playing = false
    @Published var activeRecordingID: String? = nil
    @Published var handoffMessages: [String:String] = [:]
    private var handoffInFlight: Set<String> = []
    private var nextHandoff: [String:Date] = [:]
    private var delivered: Set<String> = []
    let recorder = Recorder()
    let liveCaptions = LiveCaptionModel()
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var workers: Set<String> = []
    func hasLocalWorker(_ id: String) -> Bool { workers.contains(id) }
    private var refreshing = false
    private let snapshotFiles = SnapshotFileCache()
    private var lastCloudSweep = Date()
    private var lastArchiveSweep = Date.distantPast
    private var lastStorageSweep = Date.distantPast

    var current: Meeting? { meetings.first { $0.id == selected } }
    var activeRecording: Meeting? { meetings.first { $0.id == activeRecordingID } }
    var isViewingRecording: Bool { activeRecordingID != nil && selected == activeRecordingID && !showingPlaud }
    var isBusyRecording: Bool { activeRecordingID != nil || isStarting || isStopping }
    func selectMeeting(_ id: String) {
        guard meetings.contains(where: { $0.id == id }) else { return }
        stopPlayback()
        selected = id
        showingPlaud = false
    }
    func returnToRecording() {
        guard let id = activeRecordingID else { return }
        selectMeeting(id)
    }
    var defaultRecordingLanguage: String { UserDefaults.standard.string(forKey: "recordingLanguage") ?? "zh" }
    var defaultTranscriptionEngine: String {
        let value = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "local"
        return ["local", "openai", "plaud"].contains(value) ? value : "local"
    }
    var defaultCloudUpload: Bool { AppRuntime.settings()["cloud_upload"] as? Bool ?? (AppRuntime.settings()["onboarding_complete"] as? Bool == true) }
    func setTranscriptionEngine(_ id: String, _ engine: String) {
        guard ["local", "openai", "plaud"].contains(engine), !locked(id), !cloudInFlight.contains(id), !plaudBusy.contains(id),
              let meeting = meetings.first(where: { $0.id == id }), (engine != "plaud" || meeting.usesPlaud),
              meeting.capture_state != "recording" else { return }
        edit(id) { $0.transcription_engine = engine }
        transcripts.removeValue(forKey: id)
        if meeting.capture_state == "captured" {
            cloudProgress(id, "转写方式已切换，正在准备所选资料…")
            transcribe(id)
        }
    }
    func folder(_ id: String) -> URL { data.appendingPathComponent(id, isDirectory: true) }
    func locked(_ id: String) -> Bool { FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("submission.json").path) || submitting.contains(id) }
    func includesPlaudSummary(_ id: String) -> Bool {
        let saved = meetings.first(where: { $0.id == id })?.include_plaud_summary
        return locked(id) ? (jobs[id]?.include_plaud_summary ?? saved ?? true) : saved == true
    }
    func setIncludePlaudSummary(_ id: String, _ value: Bool) {
        guard !locked(id) else { return }
        edit(id) { $0.include_plaud_summary = value }
        guard meetings.first(where: { $0.id == id })?.isPlaud == true else { return }
        statuses[id] = ProcessingStatus(state: "waiting_plaud", message: "正在检查所选资料…", progress: 0, pid: nil)
        if !cloudInFlight.contains(id) {
            if meetings.first(where: { $0.id == id })?.usesOpenAI == true { startPlaudUpload(id) }
            else { refreshPlaudRecording(id) }
        }
    }
    func statusText(_ id: String) -> String {
        if id == activeRecordingID { return isStarting ? "正在准备录音" : isStopping ? "正在保存录音" : "正在录音" }
        if let job = jobs[id] {
            if let progress = archiveProgress[id] {
                if !archiveSettings.automatic && !progress.active && ["ready", "processing"].contains(job.state) { return "自动分析已关闭" }
                return progress.title
            }
            return ["ready":"等待后台分析", "processing":"正在核对后台分析状态", "done":"已归档", "waiting_plaud":includesPlaudSummary(id) ? "等待 Plaud 转写与总结" : "等待 Plaud 转写", "needs_context":"待补充背景"][job.state] ?? job.state
        }
        if let s = statuses[id] { return s.message }
        return meetings.first(where: {$0.id == id})?.capture_state == "draft" ? "准备录音" : "等待转写"
    }
    init(startServices: Bool = true) {
        // Headless state tests must not recover real recordings or start cloud work.
        guard startServices else { return }
        do {
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let dirs = try FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)
            meetings = dirs.compactMap { try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0.appendingPathComponent("meeting.json"))) }.sorted { $0.created_at > $1.created_at }
            loadMeetingTitles()
            for i in meetings.indices where meetings[i].capture_state == "recording" {
                meetings[i].capture_state = "captured"
                meetings[i].audio_files = ["microphone.caf","system.caf"].filter { FileManager.default.fileExists(atPath: folder(meetings[i].id).appendingPathComponent($0).path) }
                meetings[i].capture_warning = "上次录音意外中断，已找回现有音频；归档将注明录音可能不完整。"
                try persist(meetings[i])
            }
            selected = meetings.first?.id
            if meetings.isEmpty { newMeeting() }
            loadPlaudCache()
            refresh()
            if defaultCloudUpload { plaudWeb.load() }
            showingOnboarding = AppRuntime.settings()["onboarding_complete"] as? Bool != true
            Task { try? await Task.sleep(for: .seconds(10)); resumeCloudUploads() }
        } catch { self.error = error.localizedDescription }
        recorder.onInterruption = { [weak self] message in
            guard let self, let id = self.activeRecordingID else { return }
            self.edit(id) { $0.capture_warning = message }
            Task { await self.endRecording(extraWarning: message) }
        }
        recorder.onWarning = { [weak self] message in
            guard let self, let id = self.activeRecordingID else { return }
            self.edit(id) { $0.capture_warning = message }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func persist(_ m: Meeting) throws {
        let dir = folder(m.id); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let path = dir.appendingPathComponent("meeting.json"); try encoder.encode(m).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func edit(_ id: String, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: {$0.id == id}), !locked(id) else { return }
        change(&meetings[i]); do { try persist(meetings[i]) } catch { self.error = "保存失败：" + error.localizedDescription }
    }
    func newMeeting(test: Bool = false) {
        guard !isBusyRecording else { return }
        showingPlaud = false
        var m = Meeting(); m.cloud_upload = defaultCloudUpload; m.title = "会议 · " + Date().formatted(.dateTime.month().day().hour().minute())
        m.language = defaultRecordingLanguage
        m.transcription_engine = defaultTranscriptionEngine
        if test {
            m.is_test = true; m.title = "一分钟双路云端完整测试（模拟）"
            m.notes = "受控实录测试。电脑播放合成测试会议，同时用麦克风与系统音频通道录制。模拟人物和任务不生成真实个人待办。"
        }
        do { try persist(m); meetings.insert(m, at: 0); selected = m.id } catch { self.error = error.localizedDescription }
    }
    func startRecording() async {
        guard let m = current, !isBusyRecording, m.capture_state == "draft" else { return }
        stopPlayback(); isStarting = true; activeRecordingID = m.id
        edit(m.id) { $0.capture_state = "recording"; $0.audio_files = ["microphone.caf"]; $0.capture_warning = nil; $0.created_at = ISO8601DateFormatter().string(from: Date()) }
        do {
            try await recorder.start(folder: folder(m.id), system: m.capture_mode == "microphone+system")
            if UserDefaults.standard.object(forKey: "liveCaptionsEnabled") as? Bool ?? true { startLiveCaptions(fromStart: true) }
        }
        catch {
            self.error = error.localizedDescription
            let path = folder(m.id).appendingPathComponent("microphone.caf")
            let partial = try? AVAudioFile(forReading: path)
            let hasAudio = (partial?.length ?? 0) > 0
            let duration = partial.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            edit(m.id) { $0.capture_state = hasAudio ? "captured" : "draft"; $0.duration = duration; $0.audio_files = hasAudio ? ["microphone.caf"] : [] ; $0.capture_warning = hasAudio ? "开始电脑声音录制失败，保留了麦克风片段。" : error.localizedDescription }
            activeRecordingID = nil
        }
        isStarting = false
    }
    func endRecording(extraWarning: String? = nil) async {
        guard let id = activeRecordingID, !isStopping else { return }
        isStopping = true
        let result = await recorder.stop()
        liveCaptions.finish()
        edit(id) { $0.audio_files = result.files; $0.duration = result.duration; $0.capture_state = "captured"; $0.capture_warning = extraWarning ?? result.warning ?? $0.capture_warning }
        activeRecordingID = nil; isStopping = false; selectMeeting(id)
        transcribe(id)
    }
    func startLiveCaptions(fromStart: Bool = false) {
        guard let m = activeRecording, recorder.isRecording else { return }
        liveCaptions.start(id: m.id, folder: folder(m.id), elapsed: recorder.currentElapsed,
            system: m.capture_mode == "microphone+system", startAt: fromStart ? 0 : nil)
    }
    func changeLiveCaptionProvider(_ provider: LiveCaptionProvider) {
        guard LiveCaptionProvider.preferred != provider else { return }
        UserDefaults.standard.set(provider.rawValue, forKey: "liveCaptionProvider")
        if liveCaptions.enabled { startLiveCaptions() }
        else { liveCaptions.provider = provider }
    }
    nonisolated static func command(_ args: [String], log: URL) -> CommandResult {
        let p = Process(); p.executableURL = AppRuntime.python
        p.arguments = [root.appendingPathComponent("backend.py").path] + args
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do {
            let file = try FileHandle(forWritingTo: log); defer { try? file.close() }
            p.standardOutput = file; p.standardError = file
            try p.run(); p.waitUntilExit()
            return CommandResult(code: p.terminationStatus, output: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
        } catch { return CommandResult(code: 1, output: error.localizedDescription) }
    }
    func transcribe(_ id: String) {
        if meetings.first(where: { $0.id == id })?.cloud_upload == true { startPlaudUpload(id); return }
        if meetings.first(where: { $0.id == id })?.isPlaud == true { refreshPlaudRecording(id); return }
        guard !workers.contains(id), !locked(id), activeRecordingID != id else { return }
        workers.insert(id); statuses[id] = ProcessingStatus(state: "processing", message: "准备本机转写…", progress: 0, pid: nil)
        let dir = folder(id)
        Task {
            let useOpenAI = meetings.first { $0.id == id }?.usesOpenAI == true
            let result = await Task.detached(priority: .utility) {
                if useOpenAI {
                    let message = OpenAISettingsModel.transcribeMeeting(root: Self.root, folder: dir)
                    return CommandResult(code: message == nil ? 0 : 1, output: message ?? "")
                }
                return Self.command(["transcribe", dir.path], log: dir.appendingPathComponent("worker.log"))
            }.value
            workers.remove(id); refresh()
            if result.code != 0 { handoffMessages[id] = "转写暂时中断，录音与进度已保留。" }
        }
    }
    func resumeLocalProcessing() {
        guard !isBusyRecording else { return }
        for m in meetings where !m.usesPlaud && m.capture_state == "captured" && !locked(m.id) {
            guard statuses[m.id]?.state != "complete", !workers.contains(m.id) else { continue }
            if statuses[m.id]?.state == "error" && statuses[m.id]?.retryable != true { continue }
            let retryURL = folder(m.id).appendingPathComponent("local-retry.json")
            let retry = (try? Data(contentsOf: retryURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if (retry?["retry_at"] as? Double ?? 0) <= Date().timeIntervalSince1970 { transcribe(m.id) }
            break // One local inference process at a time.
        }
    }
    func submit(_ id: String) {
        guard !submitting.contains(id), !locked(id), !documentImports.contains(id) else { return }
        submitting.insert(id); let dir = folder(id)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.command(["submit", dir.path], log: dir.appendingPathComponent("submit.log")) }.value
            submitting.remove(id); refresh()
            if result.code != 0 {
                if let data = result.output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String:Any], let message = json["error"] as? String { error = message }
                else { error = "提交未完成，原始资料已保留，请重试。" }
            }
        }
    }
    func automaticHandoff(_ id: String) {
        guard let m = meetings.first(where: { $0.id == id }), !handoffInFlight.contains(id), !documentImports.contains(id),
              (nextHandoff[id] ?? .distantPast) <= Date(),
              AutomaticFlow.shouldHandoff(enabled: m.autoArchive, captured: m.capture_state == "captured",
                complete: statuses[id]?.state == "complete", submitted: locked(id), delivered: delivered.contains(id)) else { return }
        handoffInFlight.insert(id); submitting.insert(id)
        nextHandoff[id] = Date().addingTimeInterval(20)
        handoffMessages[id] = "正在自动保存并触发分析归档…"
        let dir = folder(id)
        Task {
            let result = await Task.detached { Self.command(["auto-handoff",dir.path],log:dir.appendingPathComponent("handoff.log")) }.value
            handoffInFlight.remove(id); submitting.remove(id)
            if result.code != 0 { handoffMessages[id] = "资料已保留，正在自动恢复归档交接。" }
            else { handoffMessages[id] = "归档事件已保存，连接恢复后会自动交给分析工具。" }
            refresh()
        }
    }
    func refresh() {
        if !isBusyRecording, !storageBusy, Date().timeIntervalSince(lastStorageSweep) > 1800 {
            lastStorageSweep = Date()
            maintainStorage()
        }
        if Date().timeIntervalSince(lastArchiveSweep) > 1800 {
            lastArchiveSweep = Date()
            recoverArchives()
            Task { archiveSettings = await Task.detached { ArchiveSettings.read(Self.root) }.value }
        }
        if Date().timeIntervalSince(lastCloudSweep) > 20 { lastCloudSweep = Date(); resumeCloudUploads(); resumeLocalProcessing() }
        if let player, playing, !player.isPlaying { playing = false }
        guard !refreshing else { return }
        refreshing = true
        let ids = meetings.map(\.id)
        let currentWorkers = workers
        let cache = snapshotFiles
        // iCloud files or macOS file access prompts must never block window creation.
        Task {
            let snapshot = await Task.detached(priority: .utility) { Self.readSnapshot(ids: ids, workers: currentWorkers, cache: cache) }.value
            defer { refreshing = false }
            applySnapshot(snapshot)
            for id in ids { automaticHandoff(id) }
        }
    }
    func applySnapshot(_ snapshot: DiskSnapshot) {
        delivered.formUnion(snapshot.delivered)
        let newStatuses = statuses.merging(snapshot.statuses) { _, new in new }
        if newStatuses != statuses { statuses = newStatuses }
        let newTranscripts = transcripts.merging(snapshot.transcripts) { _, new in new }
        if newTranscripts != transcripts { transcripts = newTranscripts }
        let newlyArchived = snapshot.jobs.contains { id, job in job.state == "done" && jobs[id]?.state != "done" }
        let newJobs = jobs.merging(snapshot.jobs) { _, new in new }
        let jobsChanged = newJobs != jobs
        if jobsChanged { jobs = newJobs }
        if snapshot.archiveProgress != archiveProgress { archiveProgress = snapshot.archiveProgress }
        let newAnalysis = analysis.merging(snapshot.analysis) { _, new in new }
        let analysisChanged = newAnalysis != analysis
        if analysisChanged { analysis = newAnalysis }
        if jobsChanged || analysisChanged { applyAutomaticMeetingTitles() }
        if newlyArchived { lastStorageSweep = .distantPast }
        let newSummaries = summaries.merging(snapshot.summaries) { _, new in new }
        if newSummaries != summaries { summaries = newSummaries }
        for (id, transcript) in snapshot.transcripts {
            if let m = meetings.first(where: { $0.id == id }), !locked(id), transcript.duration.isFinite,
               transcript.duration > 0, abs(m.duration - transcript.duration) > 0.01 {
                edit(id) { $0.duration = transcript.duration }
            }
        }
    }
    nonisolated static func readSnapshot(ids: [String], workers: Set<String>, cache: SnapshotFileCache? = nil) -> DiskSnapshot {
        if let cache { return cache.withPass { readSnapshotFiles(ids: ids, workers: workers, cache: cache) } }
        return readSnapshotFiles(ids: ids, workers: workers, cache: nil)
    }
    nonisolated private static func readSnapshotFiles(ids: [String], workers: Set<String>, cache: SnapshotFileCache?) -> DiskSnapshot {
        func read<T>(_ url: URL, decode: (Data) -> T?) -> T? {
            if let cache { return cache.value(url, decode: decode) }
            return (try? Data(contentsOf: url)).flatMap(decode)
        }
        func json<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
            read(url) { try? JSONDecoder().decode(type, from: $0) }
        }
        func text(_ url: URL) -> String? { read(url) { String(data: $0, encoding: .utf8) } }
        var snapshot = DiskSnapshot()
        for id in ids {
            let dir = root.appendingPathComponent("data/meetings").appendingPathComponent(id)
            let event: [String: Any]? = read(dir.appendingPathComponent("archive-trigger.json")) { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let event,
               let state = event["state"] as? String,
               state == "done" || event["backend"] as? String == "codex-app-events-v1" {
                // Durable publication is enough. Recovery owns unfinished work;
                // the two-second UI refresh must not keep submitting it.
                snapshot.delivered.insert(id)
            }
            if var p = json(dir.appendingPathComponent("progress.json"), as: ProcessingStatus.self) {
                if p.state == "processing", !workers.contains(id), let pid = p.pid, kill(pid, 0) != 0 { p.state = "retry_wait"; p.message = "正在从已保存的进度自动恢复。"; p.retryable = true }
                snapshot.statuses[id] = p
                if ["complete", "waiting_plaud"].contains(p.state), let t = json(dir.appendingPathComponent("transcript.json"), as: Transcript.self) {
                    snapshot.transcripts[id] = t
                }
            }
            if let summary = text(dir.appendingPathComponent("plaud-summary.md")) { snapshot.summaries[id] = summary }
            if let receipt = json(dir.appendingPathComponent("submission.json"), as: Receipt.self),
               let job = json(URL(fileURLWithPath: receipt.job_path), as: QueueJob.self) {
                snapshot.jobs[id] = job
                if ["ready", "processing"].contains(job.state) || event?["state"] as? String == "blocked" {
                    snapshot.archiveProgress[id] = ArchiveProgress.read(dir, jobState: job.state)
                }
                if let output = job.outputs?.first, let rendered: String = read(URL(fileURLWithPath: output), decode: { bytes in
                    guard let text = String(data: bytes, encoding: .utf8) else { return nil }
                    // Keep archival metadata in the source file, outside the reading view.
                    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                    if normalized.hasPrefix("---\n"), let end = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) {
                        return String(normalized[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return text
                }) {
                    snapshot.analysis[id] = rendered
                }
            }
        }
        return snapshot
    }
    func importAudio(test: Bool = false) {
        guard !isBusyRecording else { return }
        if test { importFile(Self.root.appendingPathComponent("fixtures/一分钟测试.m4a"), test: true); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "导入后自动上传、转写并交给 Codex 归档。背景和截图选填，总结可选。"
        if panel.runModal() == .OK, let url = panel.url { importFile(url, test: false) }
    }
    func importMultispeakerTest() {
        guard !isBusyRecording else { return }
        importFile(Self.root.appendingPathComponent("fixtures/中英混合三人测试.m4a"), test: true, multispeaker: true)
    }
    private func importFile(_ url: URL, test: Bool, multispeaker: Bool = false) {
        showingPlaud = false
        var m = Meeting(); m.cloud_upload = defaultCloudUpload; m.title = test ? "一分钟流程测试（模拟）" : url.deletingPathExtension().lastPathComponent
        m.language = defaultRecordingLanguage
        m.transcription_engine = defaultTranscriptionEngine
        m.capture_state = "captured"; m.capture_mode = "import"; m.is_test = test
        if test { m.participants = "我（单人朗读测试；音频为合成演示）"; m.purpose = "验证录音、时间轴转写、截图和 Codex 归档流程。内容均为模拟，不产生真实待办。"; m.notes = "此记录明确为测试；不要把模拟角色和任务写成真实个人行动。" }
        if multispeaker {
            m.title = "中英混合三人转写测试 · \(m.engineName)（合成模拟）"
            m.participants = "模拟角色林（主持）、Alex（工程）、梅（测试）；由三种系统合成音色扮演，不是真人录音。"
            m.purpose = "测试中英混合原文、待确认的说话人与时间参考，以及上传 Plaud、背景截图和 Codex 分析归档。"
            m.notes = "受控合成测试；不生成真实人物、决策或待办。说话人不强行映射身份。OpenAI 正文与独立时间参考分别保留，参考脚本仅用于 QA，不能回填会议正文。"
        }
        do {
            try persist(m); let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
            let name = "imported." + ext; try FileManager.default.copyItem(at: url, to: folder(m.id).appendingPathComponent(name)); m.audio_files = [name]; try persist(m)
            meetings.insert(m, at: 0); selected = m.id; transcribe(m.id)
        } catch { self.error = "导入失败：" + error.localizedDescription }
    }
    func addImages(_ id: String) {
        guard !locked(id) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { for url in panel.urls { addImage(id, source: url) } }
    }
    private func addImage(_ id: String, source: URL) {
        guard !locked(id) else { return }
        guard ["png", "jpg", "jpeg"].contains(source.pathExtension.lowercased()) else { error = "请选择 PNG 或 JPEG 图片文件。"; return }
        do {
            let bytes = try Data(contentsOf: source)
            saveImage(id, bytes: bytes, ext: source.pathExtension.lowercased())
        } catch { self.error = error.localizedDescription }
    }
    func pasteImage(_ id: String) {
        guard !locked(id), let m = meetings.first(where: {$0.id == id}) else { return }
        guard m.images.count < 8 else { error = "每场会议最多 8 张截图。"; return }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.allSatisfy({ ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }) else { error = "剪贴板中的文件须为 PNG 或 JPEG 图片。"; return }
            guard m.images.count + urls.count <= 8 else { error = "每场会议最多 8 张截图。"; return }
            for url in urls { addImage(id, source: url) }
            return
        }
        if let png = pasteboard.data(forType: .png) { saveImage(id, bytes: png, ext: "png"); return }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { error = "剪贴板里没有图片。复制一张图片，或按 ⌃⇧⌘4 截图到剪贴板，再点粘贴。也可以选择本机图片文件。"; return }
        saveImage(id, bytes: png, ext: "png")
    }
    private func saveImage(_ id: String, bytes: Data, ext: String) {
        guard !locked(id), let m = meetings.first(where: {$0.id == id}) else { return }
        guard m.images.count < 8 else { error = "每场会议最多 8 张截图。"; return }
        do {
            guard !bytes.isEmpty, bytes.count <= 15*1024*1024, NSImage(data: bytes) != nil else { throw MeetingError.message("图片须不超过 15 MB，并且可以正常打开。") }
            let name = "images/" + UUID().uuidString.lowercased() + "." + ext; let url = folder(id).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: url, options: .atomic)
            edit(id) { $0.images.append(name) }
        } catch { self.error = error.localizedDescription }
    }
    func play(_ id: String, at seconds: Double = 0) {
        guard !isBusyRecording else { return }
        do {
            let dir = folder(id)
            let localCloud = meetings.first(where: { $0.id == id })?.cloud_upload == true
            let localUpload = dir.appendingPathComponent("plaud-upload.mp3")
            if localCloud, FileManager.default.fileExists(atPath: localUpload.path) {
                player = try AVAudioPlayer(contentsOf: localUpload); player?.currentTime = seconds; playing = player?.play() ?? false; return
            }
            let isPlaud = meetings.first(where: { $0.id == id })?.isPlaud == true
            let audio = dir.appendingPathComponent(isPlaud ? "plaud-audio.m4a" : "audio.wav")
            if isPlaud && !FileManager.default.fileExists(atPath: audio.path) { playPlaud(id, at: seconds); return }
            let fallback = meetings.first(where: {$0.id == id})?.audio_files.first ?? "microphone.caf"
            player = try AVAudioPlayer(contentsOf: FileManager.default.fileExists(atPath: audio.path) ? audio : dir.appendingPathComponent(fallback))
            player?.currentTime = seconds; playing = player?.play() ?? false
        } catch { self.error = "无法播放录音：" + error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); playing = false }
    func showFolder(_ id: String) { NSWorkspace.shared.open(folder(id)) }
    func openCodex() {
        if AppRuntime.providerName == "Codex", let thread = AppRuntime.settings()["event_thread_id"] as? String,
           let url = URL(string: "codex://threads/" + thread) { NSWorkspace.shared.open(url); return }
        let names = AppRuntime.providerName == "Claude" ? ["Claude"] : ["Codex", "ChatGPT"]
        for name in names {
            let app = URL(fileURLWithPath: "/Applications/" + name + ".app")
            if FileManager.default.fileExists(atPath: app.path) { NSWorkspace.shared.open(app); return }
        }
        error = "分析已复制；请打开你使用的分析工具后粘贴。"
    }
}

func clockText(_ value: Double) -> String {
    let seconds = max(0, Int(value)); return String(format: "%02d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60)
}
