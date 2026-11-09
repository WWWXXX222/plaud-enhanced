import Foundation
import SwiftUI

enum MeetingTitleTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case dateTopic, datePeopleTopic, topic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateTopic: return "日期 · 主题"
        case .datePeopleTopic: return "日期 · 参会人 · 主题"
        case .topic: return "仅主题"
        }
    }
}

struct MeetingTitleRecord: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case manual, automatic }
    var title: String
    var mode: Mode
    // nil follows the global default; an explicit meeting choice overrides it.
    var template: MeetingTitleTemplate?
}

enum MeetingNaming {
    static func clean(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }
    static func isPlaceholder(_ title: String) -> Bool {
        title == "会议" || title.range(of: #"^会议 · (?:[A-Za-z]+ \d{1,2}(?:,? \d{4})? (?:at )?\d{1,2}:\d{2}(?: [AP]M)?|\d{1,4}年.*\d{1,2}:\d{2}|\d{1,2}月\d{1,2}日.*\d{1,2}:\d{2})$"#, options: .regularExpression) != nil
    }
    static func topic(from markdown: String) -> String? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var frontMatter = lines.first == "---", fenced = false
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if frontMatter {
                if index > 0 && line == "---" { frontMatter = false }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced, line.hasPrefix("# ") else { continue }
            var heading = String(line.dropFirst(2)).replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
            heading = heading.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            heading = heading.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            heading = heading.replacingOccurrences(of: #"^(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}/\d{1,2}|\d{1,2}月\d{1,2}日)\s*(?:[·｜|：:—–-]\s*)?"#, with: "", options: .regularExpression)
            heading = clean(heading)
            guard !["会议分析", "会议纪要", "分析与归档", "完整分析", "会议总结", "Analysis", "Meeting analysis"].contains(heading), heading.count >= 3 else { continue }
            return heading.count <= 160 ? heading : String(heading.prefix(159)) + "…"
        }
        return nil
    }
    static func dateText(_ createdAt: String) -> String? {
        let parser = ISO8601DateFormatter()
        var date = parser.date(from: createdAt)
        if date == nil { parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; date = parser.date(from: createdAt) }
        guard let date else { return nil }
        let display = DateFormatter(); display.locale = Locale(identifier: "zh_CN"); display.dateFormat = "yyyy-MM-dd"
        return display.string(from: date)
    }
    static func title(topic: String, participants: String, createdAt: String, template: MeetingTitleTemplate) -> String {
        var pieces: [String] = []
        if template != .topic, let date = dateText(createdAt) { pieces.append(date) }
        let people = clean(participants)
        if template == .datePeopleTopic, !people.isEmpty { pieces.append(people) }
        pieces.append(topic)
        return pieces.joined(separator: " · ")
    }
}

@MainActor extension MeetingStore {
    var automaticMeetingNames: Bool { UserDefaults.standard.object(forKey: "automaticMeetingNames") as? Bool ?? true }
    var defaultTitleTemplate: MeetingTitleTemplate { MeetingTitleTemplate(rawValue: UserDefaults.standard.string(forKey: "meetingTitleTemplate") ?? "") ?? .dateTopic }
    func meetingTitle(_ id: String) -> String {
        meetingTitles[id]?.title ?? meetings.first(where: { $0.id == id })?.title ?? "会议"
    }
    func loadMeetingTitles() {
        for m in meetings {
            let file = folder(m.id).appendingPathComponent("meeting-title.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do { meetingTitles[m.id] = try JSONDecoder().decode(MeetingTitleRecord.self, from: Data(contentsOf: file)) }
            catch { titleReadFailures.insert(m.id) }
        }
    }
    @discardableResult func saveMeetingTitle(_ id: String, record: MeetingTitleRecord) -> Bool {
        guard meetings.contains(where: { $0.id == id }), !record.title.isEmpty else { return false }
        do {
            let data = try JSONEncoder().encode(record)
            let file = folder(id).appendingPathComponent("meeting-title.json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            meetingTitles[id] = record; titleReadFailures.remove(id)
            return true
        } catch {
            titleReadFailures.insert(id) // Avoid repeating a failed automatic write every UI refresh.
            self.error = "会议名称未保存：" + error.localizedDescription; return false
        }
    }
    @discardableResult func renameMeeting(_ id: String, title: String) -> Bool {
        let title = MeetingNaming.clean(title)
        guard !title.isEmpty, title.count <= 160 else { error = "请输入 1–160 字的会议名称。"; return false }
        return saveMeetingTitle(id, record: MeetingTitleRecord(title: title, mode: .manual))
    }
    func suggestedMeetingTitle(_ id: String, template: MeetingTitleTemplate) -> String? {
        guard jobs[id]?.state == "done", let m = meetings.first(where: { $0.id == id }),
              let text = analysis[id], let topic = MeetingNaming.topic(from: text) else { return nil }
        return MeetingNaming.title(topic: topic, participants: m.participants, createdAt: m.created_at, template: template)
    }
    @discardableResult func useAutomaticMeetingTitle(_ id: String, template: MeetingTitleTemplate) -> Bool {
        let title = suggestedMeetingTitle(id, template: template) ?? meetingTitle(id)
        return saveMeetingTitle(id, record: MeetingTitleRecord(title: title, mode: .automatic, template: template))
    }
    func applyAutomaticMeetingTitles() {
        for m in meetings where jobs[m.id]?.state == "done" && !titleReadFailures.contains(m.id) {
            let record = meetingTitles[m.id]
            guard record?.mode != .manual else { continue }
            if record == nil {
                guard automaticMeetingNames, !m.is_test, MeetingNaming.isPlaceholder(m.title) else { continue }
            } else if record?.template == nil && !automaticMeetingNames { continue }
            let template = record?.template ?? defaultTitleTemplate
            guard let title = suggestedMeetingTitle(m.id, template: template), title != meetingTitle(m.id) else { continue }
            saveMeetingTitle(m.id, record: MeetingTitleRecord(title: title, mode: .automatic, template: record?.template))
        }
    }
    func saveMeetingNamingSettings(automatic: Bool, template: MeetingTitleTemplate) {
        UserDefaults.standard.set(automatic, forKey: "automaticMeetingNames")
        UserDefaults.standard.set(template.rawValue, forKey: "meetingTitleTemplate")
        applyAutomaticMeetingTitles()
    }
}

struct MeetingTitleEditor: View {
    @ObservedObject var store: MeetingStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = MeetingTitleTemplate.dateTopic
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("会议名称").font(.title2.bold())
            TextField("输入会议名称", text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { saveManual() }
            HStack {
                Text("手动保存后，这场会议的名称不会被自动覆盖。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存名称") { saveManual() }.keyboardShortcut(.defaultAction)
                    .disabled(MeetingNaming.clean(name).isEmpty || name.count > 160)
            }
            Divider()
            Text("按分析自动命名").font(.headline)
            Picker("命名模板", selection: $template) {
                ForEach(MeetingTitleTemplate.allCases) { Text($0.label).tag($0) }
            }
            if let suggestion = store.suggestedMeetingTitle(id, template: template) {
                Text(suggestion).textSelection(.enabled).font(.callout).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.96)).cornerRadius(8)
            } else {
                Text(store.jobs[id]?.state == "done" ? "分析中暂无可用主题，可以先手动命名。" : "分析完成后按此模板更新；现在可先保存选择。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("使用此模板自动命名") {
                if store.useAutomaticMeetingTitle(id, template: template) { dismiss() }
                else { message = store.error ?? "名称未保存，请重试。" }
            }
            Text("修改 App 中的显示名称，支持已归档的会议；Plaud 原名和归档原始证据保留。自动名称取自分析标题，无需额外调用模型。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520).onAppear {
            name = store.meetingTitle(id); template = store.meetingTitles[id]?.template ?? store.defaultTitleTemplate
        }
    }
    private func saveManual() {
        if store.renameMeeting(id, title: name) { dismiss() }
        else { message = store.error ?? "名称未保存，请重试。" }
    }
}
