import Foundation
import CryptoKit
import SwiftUI

struct SpeakerSpan: Codable, Sendable {
    var start: Double
    var end: Double?
    var text_sha256: String
}
struct SpeakerTarget: Identifiable, Sendable {
    var id: String
    var group: String?
    var automaticLabel: String?
    var source: String
    var start: Double
    var end: Double?
    var text: String
    var members: [SpeakerSpan] = []
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func letter(_ index: Int) -> String {
        var n = max(0, index), result = ""
        repeat { result = String(UnicodeScalar(65+n%26)!) + result; n = n/26-1 } while n >= 0
        return result
    }
    static func groupKey(_ segment: Segment) -> String? {
        guard let label = segment.speaker, !label.isEmpty,
              label != "说话人待确认", !label.contains("?"), !label.contains("短片段"), !label.contains("合并多人"),
              (segment.speaker_issues ?? []).isEmpty else { return nil }
        // Provider-local labels are never merged across chunks or meetings.
        return digest((segment.speaker_scope ?? String(segment.part_index ?? 0))+"|"+label)
    }
    static func timeline(_ segment: Segment, in transcript: Transcript) -> Self {
        let baseGroup = groupKey(segment)
        var keys: [String] = []
        for row in transcript.segments { if let key = groupKey(row), !keys.contains(key) { keys.append(key) } }
        let label = baseGroup.flatMap { keys.firstIndex(of: $0) }.map(letter)
        let rows = baseGroup.map { key in transcript.segments.filter { groupKey($0) == key } } ?? []
        let members = rows.map { SpeakerSpan(start: $0.start_seconds, end: $0.end_seconds, text_sha256: digest($0.text)) }
        let group = baseGroup.map { key in digest(key + "|" + rows.map { "\($0.start_seconds)|\($0.end_seconds ?? -1)|\(digest($0.text))" }.joined(separator: ";")) }
        return Self(id: "timeline:"+digest("\(segment.start_seconds)|\(segment.end_seconds ?? -1)|\(segment.text)|\(group ?? "")"),
                    group: group, automaticLabel: label, source: "timeline", start: segment.start_seconds, end: segment.end_seconds, text: segment.text, members: members)
    }
    static func live(_ row: LiveCaption) -> Self {
        // A microphone/system channel is not a speaker. Live turns remain
        // unassigned until the user explicitly chooses a meeting-local label.
        Self(id: "live:"+row.id, group: nil, automaticLabel: nil, source: row.source, start: row.start, end: row.end, text: row.text)
    }
}

struct SpeakerAnnotation: Codable, Sendable {
    var label: String
    var name: String
    var source: String
    var start: Double
    var end: Double?
    var text_sha256: String
    var scope: String
    var updated_at: String
    var members: [SpeakerSpan]? = nil
}
struct SpeakerNotes: Codable, Sendable {
    var version = 1
    var meeting_id: String
    var segments: [String: SpeakerAnnotation] = [:]
    var groups: [String: SpeakerAnnotation] = [:]
}

@MainActor final class SpeakerAnnotationModel: ObservableObject {
    let file: URL
    let libraryFile: URL
    @Published private(set) var notes: SpeakerNotes
    @Published private(set) var names: [String] = []
    @Published var error: String?
    private var notesReadable = true
    private var libraryReadable = true
    init(folder: URL, libraryFile: URL) {
        file = folder.appendingPathComponent("speaker-annotations.json"); self.libraryFile = libraryFile
        notes = SpeakerNotes(meeting_id: folder.lastPathComponent)
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let loaded = try JSONDecoder().decode(SpeakerNotes.self, from: Data(contentsOf: file))
                guard loaded.version == 1, loaded.meeting_id == folder.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                notes = loaded
            } catch { notesReadable = false; self.error = "说话人标注无法读取，已保留原文件。" }
        }
        if FileManager.default.fileExists(atPath: libraryFile.path) {
            do { names = try JSONDecoder().decode([String].self, from: Data(contentsOf: libraryFile)) }
            catch { libraryReadable = false; self.error = "姓名库无法读取，已保留原文件。" }
        }
    }
    func annotation(_ target: SpeakerTarget) -> SpeakerAnnotation? { notes.segments[target.id] ?? target.group.flatMap { notes.groups[$0] } }
    func display(_ target: SpeakerTarget) -> String {
        if let value = annotation(target) { return "说话人 \(value.label)" + (value.name.isEmpty ? " · 姓名待确认（手动分组）" : " · \(value.name)（手动标注）") }
        return target.automaticLabel.map { "说话人 \($0) · 待确认" } ?? "说话人待确认"
    }
    var labels: [String] { Array(Set((Array(notes.segments.values)+Array(notes.groups.values)).map(\.label))).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count } }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    @discardableResult func save(_ target: SpeakerTarget, label: String, name: String, entireGroup: Bool) -> Bool {
        guard notesReadable, label.range(of: "^[A-Z]{1,3}$", options: .regularExpression) != nil,
              target.start.isFinite, target.start >= 0 else { error = "无法保存这段标注。"; return false }
        let name = MeetingNaming.clean(name)
        guard name.count <= 80 else { error = "姓名请控制在 80 字以内。"; return false }
        var updated = notes
        let value = SpeakerAnnotation(label: label, name: name, source: target.source, start: target.start, end: target.end,
            text_sha256: SpeakerTarget.digest(target.text), scope: entireGroup && target.group != nil ? "provider_group" : "segment",
            updated_at: ISO8601DateFormatter().string(from: Date()), members: entireGroup && target.group != nil ? target.members : nil)
        if entireGroup, let group = target.group { updated.groups[group] = value; updated.segments.removeValue(forKey: target.id) }
        else { updated.segments[target.id] = value }
        do { try write(updated, to: file); notes = updated; error = nil; return true }
        catch { self.error = "说话人标注未保存：" + error.localizedDescription; return false }
    }
    func clear(_ target: SpeakerTarget) {
        guard notesReadable else { return }
        var updated = notes
        if updated.segments[target.id] != nil { updated.segments.removeValue(forKey: target.id) }
        else if let group = target.group { updated.groups.removeValue(forKey: group) }
        do { try write(updated, to: file); notes = updated; error = nil }
        catch { self.error = "标注未清除：" + error.localizedDescription }
    }
    @discardableResult func remember(_ name: String) -> Bool {
        let name = MeetingNaming.clean(name)
        guard libraryReadable, !name.isEmpty, name.count <= 80 else { error = "请输入 1–80 字的姓名。"; return false }
        if names.contains(name) { return true }
        guard names.count < 500 else { error = "姓名库已达 500 个，请先移除不用的姓名。"; return false }
        do { let updated = (names+[name]).sorted(); try write(updated, to: libraryFile); names = updated; error = nil; return true }
        catch { self.error = "姓名未保存：" + error.localizedDescription; return false }
    }
    func forget(_ name: String) {
        guard libraryReadable else { return }
        do { let updated = names.filter { $0 != name }; try write(updated, to: libraryFile); names = updated; error = nil }
        catch { self.error = "姓名未移除：" + error.localizedDescription }
    }
}

struct SpeakerLabelButton: View {
    @ObservedObject var model: SpeakerAnnotationModel
    let target: SpeakerTarget
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: { Label(model.display(target), systemImage: "person.crop.circle.badge.pencil") }
            .font(.caption).buttonStyle(.plain).help("手动分组或标注姓名；只作用于本场会议")
            .sheet(isPresented: $editing) { SpeakerEditor(model: model, target: target) }
    }
}
struct SpeakerEditor: View {
    @ObservedObject var model: SpeakerAnnotationModel
    let target: SpeakerTarget
    @Environment(\.dismiss) private var dismiss
    @State private var label = "A"
    @State private var name = ""
    @State private var entireGroup = false
    @State private var remember = false
    private var options: [String] { Array(Set(model.labels + (0..<26).map(SpeakerTarget.letter) + [target.automaticLabel ?? "A"])).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("标注这段发言").font(.title2.bold())
            Text("约 \(clockText(target.start)) · " + (target.source == "timeline" ? "会后时间参考" : target.source == "microphone" ? "麦克风" : "电脑声音")).foregroundStyle(.secondary)
            Text(String(target.text.prefix(400))).lineLimit(6).textSelection(.enabled)
            Picker("会内说话人", selection: $label) { ForEach(options, id: \.self) { Text("说话人 " + $0).tag($0) } }.frame(width: 250)
            TextField("姓名（可留空，继续标待确认）", text: $name).textFieldStyle(.roundedBorder)
            if !model.names.isEmpty { Menu("从常用姓名选择") { ForEach(model.names, id: \.self) { n in Button(n) { name = n } } } }
            Toggle("把这个姓名存入常用姓名库", isOn: $remember).toggleStyle(.checkbox)
            if target.group != nil {
                Toggle("应用到本会同一自动分组", isOn: $entireGroup).toggleStyle(.checkbox)
                Text("默认只改这一段。若模型混入了其他人的发言，请不要批量应用；已有单段标注优先保留。").font(.caption).foregroundStyle(.secondary)
            } else { Text(target.source == "timeline" ? "这段没有可靠的自动说话人分组，仅对当前片段保存标注。" : "实时字幕按发言片段手动分组；音源不等于人物，会后再提供自动分组参考。").font(.caption).foregroundStyle(.secondary) }
            Text("姓名是你的手动标注，不是声纹验证。不会更改原始转写或其他会议；归档后的修改仅用于 App 和转写导出。").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if model.annotation(target) != nil { Button("清除此标注") { model.clear(target); if model.error == nil { dismiss() } } }
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存标注") {
                    if remember && !name.isEmpty && !model.remember(name) { return }
                    if model.save(target, label: label, name: name, entireGroup: entireGroup) { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530).onAppear {
            label = model.annotation(target)?.label ?? target.automaticLabel ?? "A"; name = model.annotation(target)?.name ?? ""
        }
    }
}
struct ParticipantNamesView: View {
    @ObservedObject var model: SpeakerAnnotationModel
    var select: (String) -> Void
    var allowSelection = true
    @State private var newName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("常用参会人姓名", text: $newName).textFieldStyle(.roundedBorder); Button("保存姓名") { if model.remember(newName) { newName = "" } } }
            if !model.names.isEmpty {
                HStack {
                    Menu("加入本场参会人") { ForEach(model.names, id: \.self) { n in Button(n) { select(n) } } }.disabled(!allowSelection)
                    Menu("管理姓名库") { ForEach(model.names, id: \.self) { n in Button("移除 " + n) { model.forget(n) } } }
                }
            }
            Text("姓名库只保存手动输入的姓名；不会自动认人。字幕或时间轴中的说话人按钮可逐段标注。移除姓名不会删除已有会议标注。").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
