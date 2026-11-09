import SwiftUI
import AppKit

struct PlaudAccount: Codable, Sendable {
    var id: String
    var name: String
    var email: String
    var connected: Bool
    var checked_at: String
    var workspace_id: String? = nil
}
struct PlaudRecording: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var date: String
    var duration: String
}
struct PlaudResponse: Codable, Sendable {
    var ok: Bool
    var error: String?
    var account: PlaudAccount?
    var records: [PlaudRecording]?
    var page: Int?
    var has_more: Bool?
    var meeting: Meeting?
    var audio: String?
    var prepared: PreparedAudio?
}

extension MeetingStore {
    func loadPlaudCache() {
        let dir = Self.root.appendingPathComponent("data/plaud")
        if let bytes = try? Data(contentsOf: dir.appendingPathComponent("account.json")), let account = try? JSONDecoder().decode(PlaudAccount.self, from: bytes) {
            plaudAccount = account
            let page = dir.appendingPathComponent(account.id).appendingPathComponent("page-1.json")
            if let bytes = try? Data(contentsOf: page), let cached = try? JSONDecoder().decode(PlaudCachedPage.self, from: bytes) {
                plaudRecordings = cached.records; plaudHasMore = cached.has_more
            }
            plaudMessage = "显示上次同步的资料，刷新可检查最新状态。"
        }
    }
    nonisolated static func plaudCommand(_ args: [String]) -> PlaudResponse {
        let dir = root.appendingPathComponent("data/plaud")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = dir.appendingPathComponent("request-" + UUID().uuidString + ".log")
        let result = command(args, log: log)
        defer { try? FileManager.default.removeItem(at: log) }
        if let bytes = result.output.data(using: .utf8), let response = try? JSONDecoder().decode(PlaudResponse.self, from: bytes) { return response }
        return PlaudResponse(ok: false, error: "Plaud 连接未完成，请稍后重试。")
    }
    func showPlaudLibrary() {
        stopPlayback(); showingPlaud = true
        if !plaudLoading { refreshPlaud() }
    }
    func refreshPlaud(more: Bool = false) {
        guard !plaudLoading else { return }
        plaudLoading = true; plaudMessage = nil
        let page = more ? plaudPage + 1 : 1
        Task {
            let response = await Task.detached { Self.plaudCommand(["plaud-list", Self.root.path, "--page", String(page)]) }.value
            plaudLoading = false
            guard response.ok, let account = response.account, let records = response.records else {
                plaudMessage = response.error ?? "Plaud 暂时无法连接。"; return
            }
            if more, plaudAccount?.id != account.id {
                plaudRecordings = []; plaudPage = 0; plaudAccount = account; refreshPlaud(); return
            }
            plaudAccount = account; plaudPage = response.page ?? page; plaudHasMore = response.has_more ?? false
            if more {
                let ids = Set(plaudRecordings.map(\.id)); plaudRecordings += records.filter { !ids.contains($0.id) }
            } else { plaudRecordings = records }
            plaudMessage = "已同步 \(plaudRecordings.count) 条录音 · " + Date().formatted(.dateTime.hour().minute())
        }
    }
    func connectPlaud() {
        guard !plaudLoading else { return }
        plaudLoading = true; plaudMessage = "请在 Plaud 官方页面完成授权，完成后会自动同步。"
        Task {
            let response = await Task.detached { Self.plaudCommand(["plaud-login", Self.root.path]) }.value
            plaudLoading = false
            if response.ok { plaudAccount = response.account; refreshPlaud() }
            else { plaudMessage = response.error ?? "授权尚未完成，请重试。" }
        }
    }
    func openPlaudRecording(_ recording: PlaudRecording) {
        guard let account = plaudAccount, plaudOpeningID == nil else { return }
        plaudOpeningID = recording.id; plaudMessage = "正在同步这条录音的时间轴转写…"
        Task {
            let response = await Task.detached { Self.plaudCommand(["plaud-import", Self.root.path, "--file-id", recording.id, "--account-id", account.id]) }.value
            plaudOpeningID = nil
            guard response.ok, let meeting = response.meeting else { plaudMessage = response.error; return }
            // A history sync must never replace metadata owned by a live capture.
            guard meeting.id != activeRecordingID else { return }
            if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
            else { meetings.insert(meeting, at: 0) }
            if showingPlaud { selectMeeting(meeting.id) }
            refresh()
        }
    }
    func refreshPlaudRecording(_ id: String) {
        if meetings.first(where: { $0.id == id })?.usesOpenAI == true { startPlaudUpload(id); return }
        guard !plaudBusy.contains(id), !locked(id) else { return }
        plaudBusy.insert(id)
        let dir = folder(id)
        Task {
            let response = await Task.detached { Self.plaudCommand(["plaud-refresh", dir.path]) }.value
            plaudBusy.remove(id); refresh()
            if !response.ok { error = response.error }
        }
    }
    func loadPlaudSummary(_ id: String) {
        guard !plaudBusy.contains(id), !locked(id), !cloudInFlight.contains(id) else { return }
        plaudBusy.insert(id); let dir = folder(id)
        Task {
            let response = await Task.detached { Self.plaudCommand(["plaud-summary", dir.path]) }.value
            plaudBusy.remove(id); refresh()
            if !response.ok { error = response.error }
        }
    }
    func playPlaud(_ id: String, at seconds: Double) {
        guard !plaudBusy.contains(id), !isBusyRecording else { return }
        plaudBusy.insert(id); let dir = folder(id)
        Task {
            let response = await Task.detached { Self.plaudCommand(["plaud-audio", dir.path]) }.value
            plaudBusy.remove(id)
            if response.ok, selected == id, !isBusyRecording { play(id, at: seconds) }
            else if !response.ok { error = response.error }
        }
    }
    func openOriginalPlaud() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.plaud.desktop.plaud") else {
            error = "没有找到原版 Plaud，请从应用程序中打开。"; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
private struct PlaudCachedPage: Codable { var records: [PlaudRecording]; var has_more: Bool }

struct PlaudLibraryView: View {
    @ObservedObject var store: MeetingStore
    @State private var search = ""
    var matches: [PlaudRecording] { store.plaudRecordings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.date.contains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("我的 Plaud").font(.system(size: 27, weight: .semibold))
                    Text("账户里的录音和转写，连同会后补充一起归档；Plaud 总结可选。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("连接自动上传") { store.showPlaudUploadLogin = true }
                Button("打开原版 Plaud") { store.openOriginalPlaud() }
            }
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle").font(.system(size: 34))
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.plaudAccount?.name ?? "连接你的 Plaud 账户").font(.headline)
                    Text(store.plaudAccount?.email ?? "通过 Plaud 官方页面授权，无需在这里输入密码。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("连接 Plaud 账户") { store.connectPlaud() }.disabled(store.plaudLoading || store.plaudOpeningID != nil)
                Button { store.refreshPlaud() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(store.plaudLoading || store.plaudOpeningID != nil)
            }.padding(20).background(Color(white: 0.97)).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                TextField("搜索已加载录音的名称或日期", text: $search).textFieldStyle(.roundedBorder)
                Text("已加载 \(store.plaudRecordings.count) 条").font(.caption).foregroundStyle(.secondary)
            }
            if store.plaudLoading || store.plaudOpeningID != nil || store.plaudMessage != nil {
                HStack(spacing: 10) {
                    if store.plaudLoading || store.plaudOpeningID != nil { ProgressView().controlSize(.small) }
                    Text(store.plaudMessage ?? "正在从 Plaud 同步录音列表…").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { recording in
                        Button { store.openPlaudRecording(recording) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "waveform").font(.system(size: 20)).frame(width: 32)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(recording.title).font(.system(size: 14, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(recording.date + "  ·  " + recording.duration).font(.caption).foregroundStyle(.secondary)
                                }
                                if store.plaudOpeningID == recording.id { ProgressView().controlSize(.small) }
                                else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.plaudOpeningID != nil || store.plaudLoading)
                        Divider()
                    }
                    if matches.isEmpty && !store.plaudLoading {
                        Text(search.isEmpty ? "暂无录音。连接或刷新账户后显示历史记录。" : "已加载的录音中没有匹配项，可加载更多历史。")
                            .foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    if store.plaudHasMore {
                        Button("加载更早的录音") { store.refreshPlaud(more: true) }.disabled(store.plaudLoading || store.plaudOpeningID != nil).padding(.vertical, 18)
                    }
                }
            }
            Text("打开一条录音后可查看 Plaud 原文、补充参会人和会议目的、附截图并交给 Codex。设备、模板与会员设置继续在原版 Plaud 中使用。").font(.caption).foregroundStyle(.secondary)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
