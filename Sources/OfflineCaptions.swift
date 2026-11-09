import Foundation
import Darwin

struct OfflineCaptionChunk {
    var source: String
    var start: Double
    var end: Double
    var pcm: Data
    var final: Bool
    var id: String { "offline:\(source):\(Int((start*1000).rounded()))" }
}

struct OfflineUtterance {
    let source: String
    private var parts: [LivePCM] = []
    private var preroll: [LivePCM] = []
    private var silence = 0.0
    private var lastPreview = 0.0
    private var previewed = false
    init(source: String) { self.source = source }
    mutating func append(_ part: LivePCM) -> OfflineCaptionChunk? {
        let voiced = part.rms > 0.0015
        if parts.isEmpty {
            preroll.append(part); if preroll.count > 2 { preroll.removeFirst() }
            guard voiced else { return nil }
            parts = preroll; preroll = []; lastPreview = part.start; silence = 0; previewed = false
        } else { parts.append(part) }
        silence = voiced ? 0 : silence+part.end-part.start
        let length = part.end-parts[0].start
        let final = silence >= 0.75 || length >= 12
        // One early draft + the completed turn avoids decoding the same long
        // utterance three times on both tracks and accumulating a live backlog.
        guard final || (!previewed && part.end-lastPreview >= 4) else { return nil }
        let chunk = OfflineCaptionChunk(source: source, start: parts[0].start, end: part.end,
            pcm: parts.reduce(into: Data()) { $0.append($1.bytes) }, final: final)
        lastPreview = part.end; previewed = true
        if final { parts = []; silence = 0 }
        return chunk
    }
    static func floatPCM(_ int16: Data) -> Data {
        var result = Data(capacity: int16.count*2)
        int16.withUnsafeBytes { raw in
            for index in stride(from: 0, to: raw.count-1, by: 2) {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: Int16.self))
                var bits = (Float(value)/32768).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
            }
        }
        return result
    }
}

// One bounded, app-owned inference process shared by both audio sources. It
// reads committed audio bytes only and never owns the recorder or network.
final class OfflineCaptionSession: @unchecked Sendable {
    let folder: URL
    let sources: [String]
    let startAt: Double
    let began: Double
    let deliver: @Sendable (LiveUpdate) async -> Void
    let helper: URL
    let model: URL
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var task: Task<Void, Never>?
    private var cancelled: Bool { lock.withLock { stopped } }
#if MEETING_STORE_TESTS
    var processID: Int32? { lock.withLock { process?.processIdentifier } }
#endif
    private var now: Double { ProcessInfo.processInfo.systemUptime-began }

    init(folder: URL, sources: [String], elapsed: Double, startAt: Double,
         helper: URL? = nil, model: URL? = nil, deliver: @escaping @Sendable (LiveUpdate) async -> Void) {
        self.folder = folder; self.sources = sources; self.startAt = startAt
        self.began = ProcessInfo.processInfo.systemUptime-elapsed; self.deliver = deliver
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent")
        self.helper = helper ?? resources.appendingPathComponent("OfflineSpeechWorker")
        self.model = model ?? resources.appendingPathComponent("OfflineSpeechModel")
    }
    func start() { task = Task.detached(priority: .utility) { [self] in await run() } }
    func stop() {
        let owned = lock.withLock { stopped = true; return process }
        task?.cancel()
        Self.stopOwned(owned)
    }
    private static func stopOwned(_ owned: Process?) {
        guard let owned, owned.isRunning else { return }
        owned.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+2) {
            if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
        }
    }
    private func message(_ text: String) async { for source in sources { await deliver(.status(source, text)) } }
    private func readMessage(_ output: FileHandle, buffer: inout Data, timeout: Double,
                             preparing: Bool = false) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime+timeout
        let started = ProcessInfo.processInfo.systemUptime
        var nextNotice = started + 5
        var phase = "正在载入本机字幕模型"
        while !cancelled && ProcessInfo.processInfo.systemUptime < deadline {
            if preparing && ProcessInfo.processInfo.systemUptime >= nextNotice {
                await message("\(phase) · 已等待 \(Int(ProcessInfo.processInfo.systemUptime-started)) 秒；首次准备较慢，录音继续")
                nextNotice = ProcessInfo.processInfo.systemUptime + 5
            }
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if preparing, value["type"] as? String == "progress" {
                        phase = value["stage"] as? String == "warming" ? "正在完成首次识别准备" : "正在载入本机字幕模型"
                        await message(phase + "；录音继续")
                        continue
                    }
                    return value
                }
                continue
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let state = poll(&descriptor, 1, 100)
            if state < 0 { if errno == EINTR { continue }; throw LiveCaptionError.connection }
            if state == 0 { continue }
            // FileHandle.read(upToCount:) can wait to fill the requested size
            // on a pipe. One POSIX read consumes only the bytes poll observed.
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LiveCaptionError.connection }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 2_000_000 else { throw LiveCaptionError.connection }
        }
        if cancelled { throw CancellationError() }
        throw LiveCaptionError.transport(-1001)
    }
    private func run() async {
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              FileManager.default.fileExists(atPath: model.appendingPathComponent("manifest.json").path) else {
            await message("离线模型未就绪，请重新安装完整版本，或手动切换 OpenAI；录音继续"); return
        }
        var positions = Dictionary(uniqueKeysWithValues: sources.map { ($0, startAt) })
        var failures = 0
        while !cancelled {
            var stage = "loading"
            let worker = Process(); let input = Pipe(); let output = Pipe()
            // A pause/switch may close the child while a request is being
            // written. Return EPIPE for this pipe instead of killing the app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            worker.executableURL = helper; worker.arguments = [model.path]
            worker.qualityOfService = .utility
            worker.standardInput = input; worker.standardOutput = output; worker.standardError = FileHandle.nullDevice
            do {
                try lock.withLock {
                    if stopped { throw CancellationError() }
                    try worker.run(); process = worker
                }
                // Only the child's copies should keep these pipe ends open.
                // Otherwise a crashed worker looks like a silent, live worker.
                try input.fileHandleForReading.close()
                try output.fileHandleForWriting.close()
                await message("正在载入本机字幕模型…")
                var buffer = Data()
                // Cold Core ML specialization exceeded the old 120s deadline
                // in production. Ready now includes a warm-up inference; one
                // absolute deadline bounds progress messages as well.
                let ready = try await readMessage(output.fileHandleForReading, buffer: &buffer, timeout: 300, preparing: true)
                guard ready["type"] as? String == "ready" else {
                    throw LiveCaptionError.unavailable("model_load_failed")
                }
                await deliver(.metric("offline.model_load_seconds", ready["load_seconds"] as? Double ?? 0))
                stage = "decode"
                var tails: [String: LiveCAFTail] = [:]
                var turns: [String: OfflineUtterance] = [:]
                for source in sources {
                    tails[source] = try LiveCAFTail(folder.appendingPathComponent(source+".caf"), start: positions[source]!, outputRate: 16000)
                    turns[source] = OfflineUtterance(source: source)
                    await deliver(.status(source, "离线字幕运行中"))
                }
                while !cancelled {
                    var readAny = false
                    for source in sources {
                        guard let tail = tails[source], let pcm = try tail.read() else { continue }
                        readAny = true
                        guard let chunk = turns[source]?.append(pcm) else { continue }
                        if !chunk.final && now-chunk.end > 8 { continue } // Catch up using complete turns.
                        let payload = try JSONSerialization.data(withJSONObject: ["id":chunk.id,
                            "pcm":OfflineUtterance.floatPCM(chunk.pcm).base64EncodedString()])
                        try input.fileHandleForWriting.write(contentsOf: payload+Data([10]))
                        let result = try await readMessage(output.fileHandleForReading, buffer: &buffer, timeout: 45)
                        guard result["type"] as? String == "result", result["id"] as? String == chunk.id else { throw LiveCaptionError.connection }
                        failures = 0
                        if cancelled { throw CancellationError() }
                        if let text = result["text"] as? String, !text.isEmpty {
                            await deliver(.caption(LiveCaption(id: chunk.id, source: source, start: chunk.start,
                                end: chunk.end, text: text, final: chunk.final, receivedAt: now)))
                            await deliver(.metric(source+".offline_after_audio_seconds", max(0, now-chunk.end)))
                        }
                        if result["needs_review"] as? Bool == true {
                            await deliver(.caption(LiveCaption(id: chunk.id, source: source, start: chunk.start,
                                end: chunk.end, text: "［这段语音未能可靠识别，请回听原录音］", final: chunk.final, receivedAt: now)))
                            await deliver(.metric(source+".offline_review_required", chunk.start))
                        }
                        await deliver(.metric(source+".offline_decode_seconds", result["seconds"] as? Double ?? 0))
                        if chunk.final { positions[source] = chunk.end }
                        await deliver(.status(source, now-chunk.end > 20 ? "离线识别正在追赶进度；录音继续" : "离线字幕运行中"))
                    }
                    if !readAny { try await Task.sleep(for: .milliseconds(150)) }
                }
            } catch is CancellationError { Self.stopOwned(worker); break }
            catch {
                if cancelled { Self.stopOwned(worker); break }
                let code = LiveCaptionDiagnostics.code(error)
                await deliver(.metric("offline."+stage+"_"+code, now))
                await message(stage == "loading" ? "离线模型准备未完成，正在重试；录音继续" : "离线字幕暂时中断，正在恢复；录音继续")
                await deliver(.metric("offline.worker_restart", now))
            }
            Self.stopOwned(worker)
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if cancelled { break }
            if failures >= 2 {
                await message(stage == "loading" ? "离线模型准备连续失败，请点重启字幕或手动切换 OpenAI；录音继续" : "离线识别连续失败，请点重启字幕或手动切换 OpenAI；录音继续")
                break
            }
            do { try await Task.sleep(for: .seconds([1.0, 3, 10, 30][min(failures,3)])) } catch { break }
            failures += 1
        }
        lock.withLock { process = nil }
    }
}
