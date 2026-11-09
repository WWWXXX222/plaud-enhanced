import Foundation
import SwiftUI

enum LiveUpdate: Sendable {
    case caption(LiveCaption)
    case status(String, String)
    case metric(String, Double)
    case reconnect(String)
}

actor LiveCaptionStream {
    let folder: URL
    let source: String
    let key: String
    let began: Double
    let deliver: @Sendable (LiveUpdate) async -> Void
    private var socket: URLSessionWebSocketTask?
    private var ready = false
    private var connectionError: LiveCaptionError?
    private var ledger: LiveTurnLedger
    private var seenFirst: Set<String> = []
    private var completedThrough: Double
    private var lastPong = 0.0
    private var receiving: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var running: Task<Void, Never>?

    init(folder: URL, source: String, key: String, elapsed: Double, startAt: Double? = nil,
         deliver: @escaping @Sendable (LiveUpdate) async -> Void) {
        self.folder = folder; self.source = source; self.key = key
        began = ProcessInfo.processInfo.systemUptime-elapsed
        completedThrough = startAt ?? elapsed; ledger = LiveTurnLedger(source: source); self.deliver = deliver
    }
    func start() { guard running == nil else { return }; running = Task { await loop() } }
    func stop() { running?.cancel(); receiving?.cancel(); watchdog?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil; running = nil }
#if MEETING_STORE_TESTS
    func disconnectForTest() { connectionError = .connection; socket?.cancel(with: .goingAway, reason: nil) }
#endif
    private var now: Double { ProcessInfo.processInfo.systemUptime-began }
    private func pong(_ task: URLSessionWebSocketTask, failed: Bool) {
        guard socket === task else { return }
        if failed { connectionError = .connection } else { lastPong = now }
    }
    private func watch(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if now-lastPong > 30 {
                connectionError = .connection
                task.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }
    private func send(_ value: [String: Any]) async throws {
        guard let socket else { throw LiveCaptionError.connection }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func receive(_ current: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let response = try await current.receive()
                let data: Data
                switch response { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                guard socket === current, let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let type = event["type"] as? String ?? ""
#if MEETING_STORE_TESTS
                let trace: [String: Any] = ["at": now, "type": type, "item": event["item_id"] ?? "",
                    "text_length": (event["delta"] as? String ?? event["transcript"] as? String ?? "").count,
                    "turns": ledger.turns.map { ["start": $0.start, "end": $0.end, "item": $0.item ?? "", "committed": $0.committed] as [String: Any] }]
                if let bytes = try? JSONSerialization.data(withJSONObject: trace),
                   let handle = try? FileHandle(forWritingTo: folder.appendingPathComponent("events-"+source+".jsonl")) {
                    _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes+Data([10])); try? handle.close()
                }
#endif
                if type == "session.updated" || type == "transcription_session.updated" { ready = true }
                if type == "error" {
                    let code = (event["error"] as? [String: Any])?["code"] as? String ?? "api_error"
                    // Never display raw server messages (which can echo submitted input).
                    connectionError = .unavailable(code); return
                }
                if let caption = ledger.receive(event, now: now) {
                    if caption.final {
                        let contiguous = ledger.turns.prefix { turn in
                            guard let item = turn.item else { return false }
                            return ledger.captions[source+":"+item]?.final == true
                        }
                        if let end = contiguous.last?.end { completedThrough = max(completedThrough, end) }
                    }
                    guard !caption.text.isEmpty else { continue }
                    if seenFirst.insert(caption.id).inserted {
                        await deliver(.metric(source+".first_text_seconds", max(0, now-caption.start)))
                    }
                    if caption.final {
                        await deliver(.metric(source+".final_after_audio_seconds", max(0, now-caption.end)))
                    }
                    await deliver(.caption(caption))
                }
            }
        } catch { if socket === current { connectionError = .transport((error as NSError).code) } }
    }
    private func loop() async {
        var failures = 0
        while !Task.isCancelled {
            var session: URLSession?
            var scheduledRotation = false
            defer { session?.invalidateAndCancel() }
            do {
                let tail = try LiveCAFTail(folder.appendingPathComponent(source+".caf"), start: max(completedThrough, now-20))
                await deliver(.reconnect(source))
                if now-completedThrough > 21 { await deliver(.status(source, "连接恢复，跳过的实时字幕请在会后转写中查看")) }
                ledger = LiveTurnLedger(source: source); seenFirst = []; ready = false; connectionError = nil
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 1800
                let client = URLSession(configuration: config); session = client
                var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
                request.setValue("Bearer "+key, forHTTPHeaderField: "Authorization")
                let current = client.webSocketTask(with: request); socket = current; current.resume()
                receiving = Task { await receive(current) }
                lastPong = now; watchdog = Task { await watch(current) }
                await deliver(.status(source, "连接实时字幕…"))
                try await send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "transcription": ["model": "gpt-live-transcribe", "languages": ["zh", "en"], "delay": "low",
                        "prompt": "中英文混合会议。逐字保留说话时使用的原语言，包括中文和 English；不翻译、不总结、不补全未说出的内容，保留否定和条件。"],
                    "turn_detection": NSNull()]]]])
                let connected = ProcessInfo.processInfo.systemUptime
                while !ready {
                    try Task.checkCancellation()
                    if let connectionError { throw connectionError }
                    if ProcessInfo.processInfo.systemUptime-connected > 15 { throw LiveCaptionError.connection }
                    try await Task.sleep(for: .milliseconds(100))
                }
                await deliver(.status(source, "实时字幕已连接"))
                await deliver(.metric(source+".connection_ready_seconds", now))
                failures = 0
                var active = false; var silence = 0.0; var turnStart = 0.0
                var preroll: [LivePCM] = []; var lastPing = now; lastPong = now
                while !Task.isCancelled {
                    if let connectionError { throw connectionError }
                    // Bound stale work and reconnect periodically for long meetings.
                    if now-tail.seconds > 30 { throw LiveCaptionError.connection }
                    if ProcessInfo.processInfo.systemUptime-connected > 1500 { throw LiveCaptionError.rotation }
                    if let pcm = try tail.read() {
                        let voiced = pcm.rms > 0.0015
                        if !active {
                            preroll.append(pcm); if preroll.count > 2 { preroll.removeFirst() }
                            if voiced {
                                active = true; silence = 0; turnStart = preroll[0].start
                                for part in preroll {
                                    ledger.audio(start: part.start, end: part.end)
                                    try await send(["type": "input_audio_buffer.append", "audio": part.bytes.base64EncodedString()])
                                }
                                preroll = []
                            }
                        } else {
                            ledger.audio(start: pcm.start, end: pcm.end)
                            try await send(["type": "input_audio_buffer.append", "audio": pcm.bytes.base64EncodedString()])
                            silence = voiced ? 0 : silence+pcm.end-pcm.start
                            if silence >= 0.75 || pcm.end-turnStart >= 12 {
                                ledger.commit(); try await send(["type": "input_audio_buffer.commit"])
                                active = false; silence = 0
                            }
                        }
                        await deliver(.metric(source+".processed_audio_seconds", pcm.end-pcm.start))
                        // Drain small disk-write batches without waiting once per batch.
                        if tail.seconds >= now-0.35 { try await Task.sleep(for: .milliseconds(150)) }
                    } else { try await Task.sleep(for: .milliseconds(150)) }
                    if now-lastPong > 25 { throw LiveCaptionError.connection }
                    if now-lastPing > 10 {
                        current.sendPing { [weak self] error in Task { await self?.pong(current, failed: error != nil) } }
                        lastPing = now
                    }
                }
            } catch is CancellationError { break }
            catch {
                if Task.isCancelled { break }
                let diagnostic = LiveCaptionDiagnostics.code(error)
                scheduledRotation = diagnostic == "scheduled_rotation"
                await deliver(.metric(source+(scheduledRotation ? "." : ".failure.")+diagnostic, now))
                var status = LiveCaptionDiagnostics.message(error)
                if case LiveCaptionError.unavailable(let code) = error,
                   ["invalid_api_key", "insufficient_quota", "model_not_found", "invalid_request_error"].contains(code) {
                    status = code == "model_not_found" ? "当前 API 账户尚不能使用实时转写；录音继续" : "实时字幕暂不可用，请检查 OpenAI 设置；录音继续"
                    await deliver(.status(source, status)); receiving?.cancel(); watchdog?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
                    session?.invalidateAndCancel(); return
                }
                await deliver(.status(source, status))
            }
            receiving?.cancel(); watchdog?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
            session?.invalidateAndCancel()
            if Task.isCancelled { break }
            do { try await Task.sleep(for: .seconds(scheduledRotation ? 0.1 : [1.0, 2, 5, 10, 30][min(failures, 4)])) } catch { break }
            if !scheduledRotation { failures += 1 }
        }
        receiving?.cancel(); watchdog?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
}

@MainActor final class LiveCaptionModel: ObservableObject {
    @Published var meetingID: String?
    @Published var enabled = false
    @Published var captions: [LiveCaption] = []
    @Published var statuses: [String: String] = [:]
    @Published var recap = ""
    @Published var recapBusy = false
    @Published var recapRange = ""
    @Published var recapWarning = ""
    @Published var recapIsExcerpt = true
    @Published var elapsed = 0.0
    @Published var provider: LiveCaptionProvider = .offline
    private var generation = UUID()
    private var streams: [LiveCaptionStream] = []
    private var offline: OfflineCaptionSession?
    private var ticker: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var folder: URL?
    private var began = 0.0
    private var metrics: [String: [Double]] = [:]
    private var pendingCaptions: [String: LiveCaption] = [:]
    var allConnected: Bool { enabled && !statuses.isEmpty && statuses.values.allSatisfy { $0 == "实时字幕已连接" || $0 == "离线字幕运行中" } }
    var connectionSummary: String {
        let mode = provider == .offline ? "本机离线" : "OpenAI 联网"
        return mode + (!enabled ? " · 会中草稿" : allConnected ? " · 持续识别中" : provider == .offline ? " · 准备或恢复中" : " · 连接恢复中")
    }

    func start(id: String, folder: URL, elapsed: Double, system: Bool, startAt: Double? = nil,
               provider: LiveCaptionProvider = .preferred, offlineHelper: URL? = nil, offlineModel: URL? = nil) {
        pause()
        if meetingID != id { captions = []; recap = ""; recapRange = ""; recapWarning = ""; metrics = [:] }
        pendingCaptions = [:]
        meetingID = id; self.folder = folder; self.elapsed = elapsed; self.provider = provider
        began = ProcessInfo.processInfo.systemUptime-elapsed
        enabled = true
        let sources = system ? ["microphone", "system"] : ["microphone"]
        statuses = Dictionary(uniqueKeysWithValues: sources.map { ($0, "正在准备实时字幕…") })
        let token = generation
        ticker = Task {
          if provider == .offline {
            let session = OfflineCaptionSession(folder: folder, sources: sources,
                elapsed: ProcessInfo.processInfo.systemUptime-began, startAt: startAt ?? elapsed,
                helper: offlineHelper, model: offlineModel) { [weak self] update in
                    await self?.receive(update, token: token)
                }
            offline = session; session.start()
          } else {
            let keyResult = await Task.detached(priority: .utility) { Result { try OpenAIKeychain.read() } }.value
            guard token == generation, !Task.isCancelled else { return }
            guard case .success(let key) = keyResult else { statuses = ["microphone": "无法读取 OpenAI 密钥，请检查设置；录音继续"]; enabled = false; return }
            for source in sources {
                let stream = LiveCaptionStream(folder: folder, source: source, key: key,
                    elapsed: ProcessInfo.processInfo.systemUptime-began, startAt: startAt ?? elapsed) { [weak self] update in
                    await self?.receive(update, token: token)
                }
                streams.append(stream); await stream.start()
            }
          }
            var ticks = 0
            while !Task.isCancelled, token == generation {
                let now = ProcessInfo.processInfo.systemUptime-began
                if Int(self.elapsed) != Int(now) { self.elapsed = now }
                flushCaptions()
                ticks += 1; if ticks % 10 == 0 { persist() }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
    private func receive(_ update: LiveUpdate, token: UUID) {
        guard token == generation else { return }
        switch update {
        case .caption(let caption):
            pendingCaptions[caption.id] = caption
        case .status(let source, let message):
            if statuses[source] != message { statuses[source] = message }
        case .reconnect(let source):
            // Keep the last visible draft while disconnected. Only supersede it
            // once replay actually returns replacement text for the same range.
            metrics[source+".connections", default: []].append(elapsed)
        case .metric(let name, let value):
            if name.hasSuffix("processed_audio_seconds") { metrics[name] = [(metrics[name]?.first ?? 0)+value] }
            else { metrics[name, default: []].append(value); if metrics[name, default: []].count > 500 { metrics[name]?.removeFirst() } }
        }
    }
#if MEETING_STORE_TESTS
    func disconnectForTest() async { for stream in streams { await stream.disconnectForTest() } }
    var offlineProcessID: Int32? { offline?.processID }
#endif
    func pause() {
        flushCaptions()
        generation = UUID(); enabled = false; ticker?.cancel(); ticker = nil
        summaryTask?.cancel(); summaryTask = nil; recapBusy = false
        let old = streams; streams = []; Task { for stream in old { await stream.stop() } }
        offline?.stop(); offline = nil
        statuses = ["microphone": "字幕已暂停；录音继续"]
        persist()
    }
    private func flushCaptions() {
        guard !pendingCaptions.isEmpty else { return }
        var updated = captions
        for caption in pendingCaptions.values {
            updated.removeAll { $0.id != caption.id && !$0.final && $0.source == caption.source &&
                abs($0.start-caption.start) < 0.5 && $0.end <= caption.end }
            if let index = updated.firstIndex(where: { $0.id == caption.id }) { updated[index] = caption }
            else {
                updated.append(caption)
                metrics[caption.source+".first_display_seconds", default: []].append(max(0, elapsed-caption.start))
            }
        }
        pendingCaptions = [:]
        let retained = LiveCaptionHistory.retained(updated.sorted { $0.start < $1.start })
        if retained != captions { captions = retained }
    }
    func finish() { pause(); statuses = ["microphone": "实时字幕已结束；完整转写与分析将自动生成"] }
    private func persist() {
        guard let folder else { return }
        let rows = captions; let snapshot = metrics
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(rows) { try? data.write(to: folder.appendingPathComponent("live-captions.json"), options: .atomic) }
            if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: folder.appendingPathComponent("live-metrics.json"), options: .atomic) }
        }
    }
    func catchUp(seconds: Double = 180) {
        guard !recapBusy else { return }
        let rows = LiveCatchUp.recent(captions, now: elapsed, seconds: seconds)
        recapIsExcerpt = provider == .offline
        recapRange = "\(clockText(max(0, elapsed-seconds)))–\(clockText(elapsed))"
        let suspect = rows.filter { $0.reviewReason != nil }.count
        recapWarning = suspect == 0 ? "" : "有 \(suspect) 段字幕识别异常，已标为待确认。其余内容仍为字幕草稿，不能替代原录音。"
        guard !rows.isEmpty else { recap = "这段时间还没有收到字幕。可先回看已有内容，或等待转写返回。"; return }
        if provider == .offline || suspect == rows.count {
            recapIsExcerpt = true
            recapRange += provider == .offline ? " · 离线原文回看，不生成摘要" : " · 字幕均待确认，未生成摘要"
            recap = LiveCatchUp.text(rows)
            return
        }
        recapBusy = true; recap = ""; let token = generation
        recapRange += " · 实时草稿，供会中参考"
        summaryTask = Task {
            defer { if token == generation { recapBusy = false } }
            do {
                let text = try await Self.summarize(rows)
                guard token == generation, !Task.isCancelled else { return }
                recap = text
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                recap = "暂时无法生成补看摘要。字幕和录音仍保留，可稍后重试。"
            }
        }
    }
    nonisolated static func summarize(_ rows: [LiveCaption]) async throws -> String {
        let key = try await Task.detached(priority: .utility) { try OpenAIKeychain.read() }.value
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer "+key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-4.1-mini", "store": false,
            "instructions": LiveCatchUp.instructions, "input": LiveCatchUp.text(rows), "max_output_tokens": 900])
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 35
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["status"] as? String == "completed",
              let output = json["output"] as? [[String: Any]] else { throw LiveCaptionError.connection }
        let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw LiveCaptionError.connection }; return text
    }
}
