import Foundation
import AppKit
import UniformTypeIdentifiers

enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case text, markdown
    var fileExtension: String { self == .text ? "txt" : "md" }
    var label: String { self == .text ? "纯文本（.txt）" : "Markdown（.md）" }
    var contentType: UTType { self == .text ? .plainText : (UTType(filenameExtension: "md") ?? .plainText) }
}

/// Capture one meeting at the time the user chooses Export. A refresh, rename,
/// or selection change while the save sheet is open must not change its contents.
struct TranscriptExportDocument: Sendable {
    let title: String
    let createdAt: String
    let transcript: Transcript
    let independentReference: Bool
    var speakerNotes: SpeakerNotes? = nil

    init?(title: String, meeting: Meeting, transcript: Transcript?) {
        guard let transcript, Self.hasContent(transcript) else { return nil }
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "会议" : title
        createdAt = meeting.created_at
        self.transcript = transcript
        independentReference = meeting.usesOpenAI || transcript.timestamp_role?.contains("independent_listening_reference") == true
    }

    static func hasContent(_ transcript: Transcript) -> Bool {
        !(transcript.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            transcript.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var suggestedFilename: String {
        let disallowed = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let cleaned = title.components(separatedBy: disallowed).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // Limit UTF-8 bytes, not character count: Chinese titles otherwise exceed
        // filesystem filename limits. Never split a Unicode grapheme.
        var name = ""
        for character in cleaned {
            if name.utf8.count + String(character).utf8.count > 180 { break }
            name.append(character)
        }
        return (name.isEmpty ? "会议" : name) + "-transcript"
    }

    func contents(format: TranscriptExportFormat) -> String {
        func heading(_ value: String, level: Int) -> String {
            format == .markdown ? String(repeating: "#", count: level) + " " + value : value
        }
        let titleLine = title.components(separatedBy: .newlines).joined(separator: " ")
        var parts = [heading(titleLine, level: 1)]
        if !createdAt.isEmpty { parts.append("会议时间：" + createdAt) }
        parts.append("保留中英文原文。说话人标签不代表身份确认；时间为回听参考，请核对关键内容。")
        if let text = transcript.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(heading("原语言正文", level: 2))
            parts.append(text)
        }
        let segments = transcript.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !segments.isEmpty {
            parts.append(heading(independentReference ? "独立回听时间参考" : "带时间参考的逐字稿", level: 2))
            if independentReference {
                parts.append("以下内容来自独立转写，可能与原语言正文不同；不是正文的逐句时间对齐。未手动标注的说话人待确认。")
            }
            for segment in segments {
                let label = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var speaker = label.isEmpty ? "说话人待确认" : label.contains("待确认") ? label : label + "（待确认）"
                if let notes = speakerNotes {
                    let target = SpeakerTarget.timeline(segment, in: transcript)
                    if let annotation = notes.segments[target.id] ?? target.group.flatMap({ notes.groups[$0] }) {
                        speaker = "说话人 \(annotation.label) · " + (annotation.name.isEmpty ? "姓名待确认（手动分组）" : annotation.name + "（手动标注，未经声纹验证）")
                    }
                }
                let start = Self.timestamp(segment.start_seconds)
                var time = start.map { "约 " + $0 } ?? "时间待确认"
                if start != nil, let end = segment.end_seconds, end > segment.start_seconds, let endText = Self.timestamp(end) {
                    time += "–" + endText
                }
                parts.append("[\(time)] \(speaker)\n\(segment.text)")
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < 360_000_000 else { return nil }
        let whole = Int(seconds)
        return String(format: "%02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }

    func write(to url: URL, format: TranscriptExportFormat) throws {
        try contents(format: format).write(to: url, atomically: true, encoding: .utf8)
    }
}

extension MeetingStore {
    func transcriptExportDocument(_ id: String) -> TranscriptExportDocument? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        return TranscriptExportDocument(title: meetingTitle(id), meeting: meeting, transcript: transcripts[id])
    }

    func exportTranscript(_ id: String, format: TranscriptExportFormat, speakerNotes: SpeakerNotes? = nil) {
        guard !transcriptExports.contains(id), var document = transcriptExportDocument(id) else { return }
        if speakerNotes?.meeting_id == id { document.speakerNotes = speakerNotes }
        let snapshot = document
        transcriptExports.insert(id)
        transcriptExportMessages.removeValue(forKey: id)
        let panel = NSSavePanel()
        panel.title = "导出转写"
        panel.message = "保存原语言正文、已有时间参考和说话人标签。"
        panel.prompt = "导出"
        panel.allowedContentTypes = [format.contentType]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.suggestedFilename + "." + format.fileExtension
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.transcriptExports.remove(id)
                return
            }
            Task { @MainActor in
                defer { self.transcriptExports.remove(id) }
                do {
                    // Saving never touches the capture, upload or archive queues.
                    try await Task.detached(priority: .utility) { try snapshot.write(to: url, format: format) }.value
                    self.transcriptExportMessages[id] = "已导出：" + url.lastPathComponent
                } catch {
                    self.error = "转写导出失败，请选择可写入的位置后重试。" + error.localizedDescription
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
}
