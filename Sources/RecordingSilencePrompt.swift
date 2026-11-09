import AppKit

// Modeless: a forgotten question must never block audio callbacks, timers, or saving.
// Independent of the selected meeting and of whether the main window is collapsed.
@MainActor final class RecordingSilencePromptController: NSObject {
    private(set) var alert: NSAlert?
    private var reminderID: UUID?
    private var response: ((UUID, Bool) -> Void)?
    private var attention: Int?

    func present(_ reminder: RecordingSilenceReminder, meetingTitle: String, system: Bool,
                 respond: @escaping (UUID, Bool) -> Void) {
        guard reminderID != reminder.id else { return }
        dismiss()
        let alert = Self.makeAlert(meetingTitle: meetingTitle, system: system)
        self.alert = alert; reminderID = reminder.id; response = respond
        alert.buttons[0].target = self; alert.buttons[0].action = #selector(keepRecording)
        alert.buttons[1].target = self; alert.buttons[1].action = #selector(endRecording)
        let window = alert.window
        window.title = "录音静音提醒"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        alert.layout()
        window.center()
        window.makeKeyAndOrderFront(nil)
        attention = NSApp.requestUserAttention(.informationalRequest)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func makeAlert(meetingTitle: String, system: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已经 5 分钟未检测到明显声音"
        let sources = system ? "麦克风和电脑声音" : "麦克风"
        alert.informativeText = "\(meetingTitle)\n\n\(sources)连续 5 分钟未检测到明显声音。录音仍在继续，是否结束并保存？\n\n结束后会按原设置自动上传、转写和归档。选择继续后，如再安静 5 分钟会再次提醒；未选择时会继续录音。"
        // Return continues recording. Ending has no keyboard shortcut.
        alert.addButton(withTitle: "继续录音").keyEquivalent = "\r"
        alert.addButton(withTitle: "结束并保存").keyEquivalent = ""
        return alert
    }

    @objc private func keepRecording() { answer(stop: false) }
    @objc private func endRecording() { answer(stop: true) }
    private func answer(stop: Bool) {
        guard let id = reminderID, let response else { return }
        dismiss()
        response(id, stop)
    }

    func dismiss() {
        alert?.window.orderOut(nil)
        alert = nil; reminderID = nil; response = nil
        if let attention { NSApp.cancelUserAttentionRequest(attention) }
        attention = nil
    }
}
