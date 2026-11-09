import Foundation
import AVFoundation
import AppKit

struct CaptureResult {
    var files: [String]
    var duration: Double
    var warning: String?
}

enum MeetingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

// A separate serial queue owns the system audio file; the microphone has its own file.
// Silence gaps are preserved against the host clock, so mixing keeps the recording timeline.
final class SystemAudioSink: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.local.meetingmemory.system-audio")
    let url: URL
    let startHost: Double
    var onFailure: ((String) -> Void)?
    var onSamplesResumed: ((Double) -> Void)?
    private var notifyOnNextSample = false
    private var file: AVAudioFile?
    private var failure: String?
    private var closed = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var receivedFrames: Int64 = 0
    private var paddingFrames: Int64 = 0
    private var nonSilentFrames: Int64 = 0
    let soundActivity = RecordingSoundActivity()
    private var firstSample: Double?
    private var lastSample: Double?
    private var gaps: [[String: Double]] = []
    private(set) var frames: Int64 = 0
    init(url: URL, startHost: Double) { self.url = url; self.startHost = startHost }
    func markInterrupted() -> Double {
        queue.sync { notifyOnNextSample = true; return Double(frames) / format.sampleRate }
    }
    // One file and one host-clock timeline across changes of audio devices.
    // Missing samples remain explicit gaps; silence padding is not evidence of capture.
    func write(_ input: AVAudioPCMBuffer, at pts: Double) {
        guard !closed, failure == nil else { return }
        do {
            let elapsed = max(0, pts - startHost)
            guard elapsed.isFinite, elapsed < ProcessInfo.processInfo.systemUptime - startHost + 10 else { throw MeetingError.message("电脑声音的时间轴异常。") }
            let buffer: AVAudioPCMBuffer
            if input.format == format { buffer = input }
            else {
                if inputFormat != input.format {
                    converter = AVAudioConverter(from: input.format, to: format)
                    inputFormat = input.format
                }
                guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 256) else {
                    throw MeetingError.message("电脑声音格式转换失败。")
                }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return input
                }
                if status == .error { throw error ?? MeetingError.message("电脑声音格式转换失败。") }
                buffer = converted
            }
            guard buffer.frameLength > 0 else { return }
            if file == nil { file = try AVAudioFile(forWriting: url, settings: format.settings) }
            guard let file else { return }
            let target = Int64(elapsed * format.sampleRate)
            var gap = target - frames
            if gap > Int64(format.sampleRate * 0.04) {
                gaps.append(["start": Double(frames) / format.sampleRate, "end": elapsed])
                while gap > 0 {
                    let n = AVAudioFrameCount(min(gap, 8192))
                    guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { throw MeetingError.message("电脑声音写入内存不足。") }
                    silence.frameLength = n
                    for b in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                        if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
                    }
                    try file.write(from: silence); frames += Int64(n); paddingFrames += Int64(n); gap -= Int64(n)
                }
            }
            try file.write(from: buffer)
            frames += Int64(buffer.frameLength); receivedFrames += Int64(buffer.frameLength)
            if let channels = buffer.floatChannelData {
                var leftEnergy = 0.0, rightEnergy = 0.0
                for i in 0..<Int(buffer.frameLength) {
                    if abs(channels[0][i]) > 0.00001 || abs(channels[1][i]) > 0.00001 { nonSilentFrames += 1 }
                    leftEnergy += Double(channels[0][i]) * Double(channels[0][i])
                    rightEnergy += Double(channels[1][i]) * Double(channels[1][i])
                }
                soundActivity.observe(meanSquare: max(leftEnergy, rightEnergy) / Double(buffer.frameLength), at: pts)
            }
            if firstSample == nil { firstSample = elapsed }; lastSample = elapsed
            if notifyOnNextSample {
                notifyOnNextSample = false
                DispatchQueue.main.async { self.onSamplesResumed?(elapsed) }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) {
        guard failure == nil else { return }; failure = message
        DispatchQueue.main.async { self.onFailure?(message) }
    }
    func finish() async -> (Bool, String?) {
        await withCheckedContinuation { c in queue.async {
            self.closed = true; self.file = nil
            let stats: [String: Any] = ["engine": "core-audio-process-tap", "sample_rate": self.format.sampleRate,
                "frames": self.frames, "received_frames": self.receivedFrames, "padding_frames": self.paddingFrames,
                "non_silent_frames": self.nonSilentFrames, "first_sample_seconds": self.firstSample ?? -1,
                "last_sample_seconds": self.lastSample ?? -1, "gaps": self.gaps, "error": self.failure ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: self.url.deletingLastPathComponent().appendingPathComponent("capture-system-stats.json"), options: .atomic)
            }
            c.resume(returning: (self.receivedFrames > 0, self.failure))
        } }
    }
}

@MainActor final class AudioReconnect {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var active: Bool { task != nil }
    static func delay(_ attempt: Int) -> Double { [2.0, 5, 10, 20, 30][min(max(attempt, 0), 4)] }
    func start(connect: @escaping () async throws -> Void, recovered: @escaping () -> Void,
               wait: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            defer { if self?.generation == token { self?.task = nil } }
            var attempt = 0
            while !Task.isCancelled {
                do { try await wait(Self.delay(attempt)); try Task.checkCancellation() }
                catch { return }
                guard self?.generation == token else { return }
                do {
                    try await connect()
                    guard !Task.isCancelled, self?.generation == token else { return }
                    self?.task = nil; recovered(); return
                } catch is CancellationError { return }
                catch { attempt = min(attempt + 1, 4) }
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

@MainActor final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var level: Float = 0
    @Published var elapsed: Double = 0
    @Published private(set) var silenceReminder: RecordingSilenceReminder?
    private var silenceWatchdog = RecordingSilenceWatchdog()
    // The first display timer tick may occur after system audio setup. Readers
    // need the actual recording clock, including that setup interval.
    var currentElapsed: Double { isRecording ? max(0, ProcessInfo.processInfo.systemUptime - began) : elapsed }
    var onInterruption: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    private var microphone: AVAudioRecorder?
    private var audioTap: SystemAudioTap?
    private var sink: SystemAudioSink?
    private var timer: Timer?
    private var began: TimeInterval = 0
    private var activity: NSObjectProtocol?
    private var folder: URL?
    private var warning: String?
    private var systemEnabled = false
    private var sleepObserver: NSObjectProtocol?
    private let reconnect = AudioReconnect()
    private var generation = UUID()
    private var gaps: [(start: Double, end: Double?)] = []

    override init() {
        super.init()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self, self.isRecording { self.onInterruption?("Mac 即将睡眠，录音已结束；请核对录音范围。") } }
        }
    }
    func start(folder: URL, system: Bool) async throws {
        guard !isRecording else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw MeetingError.message("需要麦克风权限。请在系统设置 → 隐私与安全性 → 麦克风中允许“Plaud威力加强版”。") }
        self.folder = folder; warning = nil; systemEnabled = system; gaps = []; generation = UUID()
        let recorder = try AVAudioRecorder(url: folder.appendingPathComponent("microphone.caf"), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        recorder.delegate = self; recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else { throw MeetingError.message("麦克风未就绪，请检查输入设备。") }
        began = ProcessInfo.processInfo.systemUptime
        guard recorder.record() else { throw MeetingError.message("无法开始录音，请检查麦克风。") }
        microphone = recorder; isRecording = true; elapsed = 0
        silenceWatchdog.start(at: began); silenceReminder = nil
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "会议录音中")
        do {
            if system {
                let output = SystemAudioSink(url: folder.appendingPathComponent("system.caf"), startHost: began)
                output.onFailure = { [weak self] message in self?.systemFailed(message, recoverable: false) }
                output.onSamplesResumed = { [weak self] elapsed in
                    guard let self, self.isRecording, let index = self.gaps.indices.last, self.gaps[index].end == nil else { return }
                    self.gaps[index].end = max(self.gaps[index].start, elapsed)
                    self.publishGaps(extra: "电脑声音已恢复；以上区间可能缺少电脑声音，麦克风未因此停止。")
                }
                sink = output
                try await connectSystemAudio()
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMetersAndSilence() }
            }
            // Keep checking while the user drags, scrolls, or has another sheet open.
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        } catch {
            let cause = error as NSError
            let diagnostic: [String: Any] = ["phase": "start-system-audio", "domain": cause.domain, "code": cause.code, "message": cause.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]) {
                let path = folder.appendingPathComponent("capture-diagnostic.json")
                try? data.write(to: path, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
            _ = await stop(); throw MeetingError.message("电脑声音无法开始录制。已有麦克风片段已保留。系统信息：" + cause.localizedDescription)
        }
    }
    private func updateMetersAndSilence() {
        guard isRecording else { return }
        microphone?.updateMeters()
        let power = microphone?.isRecording == true ? microphone?.averagePower(forChannel: 0) : nil
        level = max(0, min(1, ((power ?? -60) + 60) / 60))
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - began
        silenceWatchdog.update(at: now, microphonePower: power,
            systemActivity: systemEnabled ? sink?.soundActivity.lastActiveHostTime : nil)
        if silenceReminder != silenceWatchdog.reminder { silenceReminder = silenceWatchdog.reminder }
    }
    func acknowledgeSilenceReminder(_ id: UUID) -> Bool {
        // Recheck real audio before honoring a dialog that may have just become stale.
        updateMetersAndSilence()
        guard isRecording, silenceWatchdog.acknowledge(id, at: ProcessInfo.processInfo.systemUptime) else { return false }
        silenceReminder = nil
        return true
    }
    private func connectSystemAudio() async throws {
        let token = generation
        guard isRecording, let output = sink else { throw CancellationError() }
        let capture = SystemAudioTap(sink: output)
        capture.onInvalidated = { [weak self, weak capture] message in
            guard let self, let capture, self.audioTap === capture else { return }
            self.systemFailed(message, recoverable: true, lastAudio: output.markInterrupted())
        }
        audioTap = capture
        do { try await capture.start() }
        catch {
            if audioTap === capture { audioTap = nil }
            await capture.stop(); throw error
        }
        guard !Task.isCancelled, isRecording, generation == token else {
            await capture.stop(); throw CancellationError()
        }
    }
    func systemFailed(_ message: String, recoverable: Bool, lastAudio: Double? = nil) {
        guard isRecording else { return }
        if gaps.last?.end != nil || gaps.isEmpty { gaps.append((max(0, lastAudio ?? ProcessInfo.processInfo.systemUptime - began), nil)) }
        publishGaps(extra: recoverable ? "麦克风继续录音，电脑声音将自动尝试恢复。" : "麦克风继续录音；电脑声音写入失败：" + message)
        if !recoverable { reconnect.cancel(); return }
        guard !reconnect.active else { return }
        let failed = audioTap; audioTap = nil
        reconnect.start(connect: { [weak self] in
            guard let self, self.isRecording else { throw CancellationError() }
            await failed?.stop()
            try await self.connectSystemAudio()
        }, recovered: { [weak self] in
            guard let self, self.isRecording else { return }
            // Successful start is not proof that audio arrived. The sink closes
            // the gap only when the first actual resumed buffer is persisted.
            if self.gaps.last?.end == nil { self.publishGaps(extra: "采集已重连，等待电脑声音；麦克风继续录音。") }
        })

    }
    private func publishGaps(extra: String) {
        func time(_ seconds: Double) -> String { let s = Int(seconds); return String(format: "%02d:%02d", s / 60, s % 60) }
        let ranges = gaps.map { time($0.start) + "–" + ($0.end.map(time) ?? "尚未恢复") }.joined(separator: "、")
        warning = "电脑声音中断区间：\(ranges)。\(extra)"
        if let warning { onWarning?(warning) }
    }
    func stop() async -> CaptureResult {
        let length = max(0, ProcessInfo.processInfo.systemUptime - began)
        // Invalidate before awaits so a late reconnect cannot revive a stopped session.
        isRecording = false; generation = UUID(); reconnect.cancel()
        silenceWatchdog.stop(); silenceReminder = nil
        if let index = gaps.indices.last, gaps[index].end == nil {
            gaps[index].end = length; publishGaps(extra: "直到录音结束仍未恢复；该区间仅保留实际收到的音轨。")
        }
        timer?.invalidate(); timer = nil; microphone?.stop(); microphone = nil
        await audioTap?.stop()
        var files = ["microphone.caf"]
        if let sink {
            let (hasAudio, failure) = await sink.finish()
            if hasAudio { files.append("system.caf") }
            else if systemEnabled { warning = warning ?? "没有收到电脑声音数据，这段录音只包含麦克风；请核对权限与会议应用。" }
            warning = warning ?? failure
        }
        audioTap = nil; sink = nil; isRecording = false; level = 0; elapsed = length
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        return CaptureResult(files: files, duration: length, warning: warning)
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in onInterruption?("麦克风录音中断，请检查输入设备并核对已有录音。") }
    }
}
