import Foundation
import AVFoundation
import CoreAudio

// A private, audio-only process tap. There is no display/window/screen stream,
// and locking or turning off a display does not recreate the audio device.
final class SystemAudioTap: @unchecked Sendable {
    private let control = DispatchQueue(label: "com.local.meetingmemory.audio-tap-control")
    private let input = DispatchQueue(label: "com.local.meetingmemory.audio-tap-input", qos: .userInitiated)
    private let pending = DispatchSemaphore(value: 512)
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var device: AudioObjectID = kAudioObjectUnknown
    private var io: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var running = false
    private var reportedFailure = false
    private let sink: SystemAudioSink
    var onInvalidated: ((String) -> Void)?

    init(sink: SystemAudioSink) { self.sink = sink }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw MeetingError.message("电脑声音采集\(step)失败（\(status)）。请确认系统设置中的系统音频录制权限。") }
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            control.async {
                do { try self.startDevice(); c.resume() }
                catch { self.stopDevice(); c.resume(throwing: error) }
            }
        }
    }
    private func startDevice() throws {
        guard !running else { return }
        // CATapDescription takes AudioObjectIDs, never Unix PIDs.
        var pid = ProcessInfo.processInfo.processIdentifier
        var process: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var property = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "定位自身进程")
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: process == kAudioObjectUnknown ? [] : [process])
        description.name = "Plaud威力加强版 · 会议电脑声音"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "建立")

        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        property = Self.address(kAudioTapPropertyFormat)
        try Self.check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &asbd), "读取格式")
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else { throw MeetingError.message("电脑声音格式不可用。") }
        // A tap-only aggregate avoids binding the capture lifetime to a screen or
        // a specific speaker device. Never change the user's default audio route.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Plaud 会议音频采集",
            kAudioAggregateDeviceUIDKey: "com.local.meetingmemory.tap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "建立音频设备")
        let writer = sink
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&io, device, input) { [weak self] now, data, timestamp, _, _ in
            guard let self else { return }
            let host = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : now.pointee.mHostTime
            let pts = AVAudioTime.seconds(forHostTime: host)
            guard let buffer = Self.copyInput(data, format: format) else { return }
            // The HAL owns input memory only during this callback. Copy it before
            // returning, then write on the disk queue; never block HAL on disk IO.
            guard self.pending.wait(timeout: .now()) == .success else {
                self.invalidate("电脑声音写盘排队过久，部分内容可能缺失。")
                return
            }
            writer.queue.async {
                defer { self.pending.signal() }
                writer.write(buffer, at: pts)
            }
        }, "注册音频回调")
        try Self.check(AudioDeviceStart(device, io), "启动")
        running = true
        try watch(device, kAudioDevicePropertyDeviceIsAlive, onlyWhenDead: true)
        try watch(tap, kAudioTapPropertyFormat)
        try watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted)
    }

    // Internal for regression tests: input can be interleaved or planar and is
    // copied without retaining pointers owned by Core Audio.
    static func copyInput(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let first = source.first, first.mData != nil else { return nil }
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for i in source.indices {
            guard let src = source[i].mData, let dst = target[i].mData,
                  source[i].mDataByteSize == target[i].mDataByteSize else { return nil }
            memcpy(dst, src, Int(source[i].mDataByteSize))
        }
        return copy
    }

    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, onlyWhenDead: Bool = false) throws {
        var property = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            if onlyWhenDead {
                var alive: UInt32 = 0, length = UInt32(MemoryLayout<UInt32>.size)
                var p = Self.address(selector)
                if AudioObjectGetPropertyData(object, &p, 0, nil, &length, &alive) == noErr, alive != 0 { return }
            }
            self.invalidate("电脑声音设备发生变化，正在恢复采集。")
        }
        try Self.check(AudioObjectAddPropertyListenerBlock(object, &property, control, block), "监听设备变化")
        listeners.append((object, property, block))
    }
    private func invalidate(_ message: String) {
        control.async { [weak self] in
            guard let self, self.running, !self.reportedFailure else { return }
            self.reportedFailure = true
            DispatchQueue.main.async { self.onInvalidated?(message) }
        }
    }
    func stop() async {
        await withCheckedContinuation { c in control.async { self.stopDevice(); c.resume() } }
    }
    private func stopDevice() {
        running = false
        for (object, value, block) in listeners {
            var property = value
            AudioObjectRemovePropertyListenerBlock(object, &property, control, block)
        }
        listeners.removeAll()
        if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
        io = nil
        input.sync {} // every accepted input buffer is now queued on the writer
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }
}
