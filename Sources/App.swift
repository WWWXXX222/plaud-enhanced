import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

private let ink = Color(white: 0.06)
private let paper = Color(white: 0.97)
private let hairline = Color(white: 0.88)

struct MonochromePrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(isEnabled ? Color.white : Color(white: 0.55))
            .background(isEnabled ? (configuration.isPressed ? Color(white: 0.23) : Color.black) : Color(white: 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct MonochromeSecondaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(isEnabled ? ink : Color(white: 0.6))
            .background(configuration.isPressed ? paper : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(hairline, lineWidth: 1))
    }
}

struct MonochromeLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(isEnabled ? ink : Color(white: 0.6))
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: MeetingStore?
    weak var windows: RecordingWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the running Dock tile even when Launch Services cached an older bundle icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url), icon.isValid {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isBusyRecording == true {
            let alert = NSAlert(); alert.messageText = "录音还在进行"; alert.informativeText = "请先在Plaud威力加强版中结束录音，确保声音完整保存。"; alert.addButton(withTitle: "返回录音"); alert.runModal()
            return .terminateCancel
        }
        if store?.openAI.running == true {
            let alert = NSAlert(); alert.messageText = "OpenAI 对比测试正在进行"; alert.informativeText = "请等待测试返回后再退出，避免中断正在进行的调用。"; alert.addButton(withTitle: "返回测试"); alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows?.showMain()
        return true
    }
}

#if !MEETING_STORE_TESTS
@main enum OwnPlaudLauncher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--archive-recover-only") {
            // Run under the same authorized native application identity, without
            // constructing a SwiftUI window, recorder, or Plaud browser session.
            let okay = MeetingStore.archiveCommand([])
            _ = try? MeetingStore.storageCommand(["--run", "--automatic"])
            exit(okay ? 0 : 1)
        }
        OwnPlaudApp.main()
    }
}
#endif

struct OwnPlaudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = MeetingStore()
    @StateObject private var windows = RecordingWindowController()
    var body: some Scene {
        Window("Plaud威力加强版", id: "meeting-main") {
            RootView(store: store, windows: windows).frame(minWidth: 1000, minHeight: 700).preferredColorScheme(.light)
                .background(MainWindowReader { window in windows.attach(window: window, store: store) }.frame(width: 0, height: 0))
                .onAppear { delegate.store = store; delegate.windows = windows; NSApp.activate(ignoringOtherApps: true) }
                .alert("Plaud威力加强版", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
        }
        .defaultSize(width: 1220, height: 850)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showingSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("新会议") { store.newMeeting() }.keyboardShortcut("n").disabled(store.isBusyRecording)
                Button("导入录音…") { store.importAudio() }.keyboardShortcut("o").disabled(store.isBusyRecording)
            }
            CommandMenu("录音窗口") {
                Button("展开会议窗口") { windows.showMain() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("收起为迷你浮窗") { windows.showCompact() }.disabled(!store.isBusyRecording)
                Divider()
                Button("预览录音浮窗") { windows.preview() }.disabled(store.isBusyRecording)
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var windows: RecordingWindowController
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    if let url = Bundle.main.url(forResource: "AppIconPreview", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).resizable().frame(width: 39, height: 39).accessibilityLabel("Plaud威力加强版图标")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Plaud威力加强版").font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        Text("录音 · 转写 · 归档").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 10)
                Button { store.newMeeting() } label: { Label("新会议", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(MonochromePrimaryStyle()).disabled(store.isBusyRecording)
                Button { store.showPlaudLibrary() } label: {
                    HStack { Image(systemName: "cloud"); Text("Plaud 账户与录音"); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                        .padding(12).background(store.showingPlaud ? paper : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                Text("已打开的会议").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.meetings) { meeting in
                            Button { store.selectMeeting(meeting.id) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(store.meetingTitle(meeting.id)).font(.system(size: 13, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        if meeting.id == store.activeRecordingID { Image(systemName: "waveform").accessibilityLabel("当前录音") }
                                    }
                                    Text((meeting.isPlaud ? "Plaud · " : "本机 · ") + store.statusText(meeting.id)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                }.padding(13).background(!store.showingPlaud && store.selected == meeting.id ? paper : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Button { store.importAudio() } label: { Label("导入已有录音", systemImage: "square.and.arrow.down") }.buttonStyle(.plain).disabled(store.isBusyRecording)
                    if Bundle.main.object(forInfoDictionaryKey: "MeetingProjectRoot") != nil {
                    Menu {
                        Button("麦克风＋电脑声音实录测试") { store.newMeeting(test: true) }
                        Button("导入一分钟演示音频") { store.importAudio(test: true) }
                        Button("中英混合 · 三位说话人测试") { store.importMultispeakerTest() }
                    } label: { Label("一分钟流程测试", systemImage: "play.rectangle") }.menuStyle(.borderlessButton).disabled(store.isBusyRecording)
                    }
                    Divider()
                    Button { store.showingSettings = true } label: { Label("设置 · 会后自动归档", systemImage: "gearshape") }.buttonStyle(.plain)
                    Text("录音按设置自动处理\n分析归档交给所选工具").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
                }.font(.system(size: 12))
            }.padding(22).frame(width: 250).background(Color.white)
            Divider()
            VStack(spacing: 0) {
                if store.activeRecording != nil && !store.isViewingRecording {
                    ActiveRecordingBanner(store: store, recorder: store.recorder, windows: windows)
                    Divider()
                }
                if store.showingPlaud { PlaudLibraryView(store: store) }
                else if let m = store.current { MeetingDetail(store: store, windows: windows, id: m.id).id(m.id) }
                else { ContentUnavailableView("从一场会议开始", systemImage: "waveform", description: Text("开始录音，或导入一段已有音频。")) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.foregroundStyle(ink).background(Color.white).tint(ink)
            .buttonStyle(MonochromeSecondaryStyle())
            .sheet(isPresented: $store.showPlaudUploadLogin) { PlaudUploadConnectionView(store: store, session: store.plaudWeb) }
            .sheet(isPresented: $store.showingOnboarding) { OnboardingView(store: store) }
            .sheet(isPresented: $store.showingSettings) { SettingsView(store: store, windows: windows).tint(ink).buttonStyle(MonochromeSecondaryStyle()) }
    }
}

struct SettingsView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var windows: RecordingWindowController
    @Environment(\.dismiss) var dismiss
    @State private var recordingLanguage = "zh"
    @State private var transcriptionEngine = "plaud"
    @State private var previewRequested = false
    @State private var automaticAnalysis = true
    @State private var resultView = "app"
    @State private var automaticNames = true
    @State private var titleTemplate = MeetingTitleTemplate.dateTopic
    @State private var saving = false
    @AppStorage("liveCaptionsEnabled") private var liveCaptionsEnabled = true
    @AppStorage("liveCaptionProvider") private var liveCaptionProvider = LiveCaptionProvider.offline.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Plaud威力加强版设置").font(.title2.bold())
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Button("首次设置 · 账户、处理方式与知识库") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { store.showingOnboarding = true } }
            OpenAISettingsSection(model: store.openAI)
            Toggle("录音时自动开启实时字幕", isOn: $liveCaptionsEnabled)
            Picker("实时字幕方式", selection: Binding(get: {
                LiveCaptionProvider(rawValue: liveCaptionProvider) ?? .offline
            }, set: { store.changeLiveCaptionProvider($0) })) {
                ForEach(LiveCaptionProvider.allCases) { Text($0.label).tag($0) }
            }
            Text("默认离线，保留中英原文并回看最近 10 分钟；「刚才说了什么」离线回看最近 3 分钟原文。可手动切换 OpenAI 联网字幕及摘要，另计 API 用量。切换只重启字幕，录音继续；选择会记住。自动开启开关从下次录音生效。会后处理使用下方独立设置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("会议自动命名").font(.headline)
            Toggle("分析完成后为默认名称生成主题", isOn: $automaticNames)
            Picker("默认命名模板", selection: $titleTemplate) {
                ForEach(MeetingTitleTemplate.allCases) { Text($0.label).tag($0) }
            }
            Text("适用于仍以日期命名的会议。手动改过的名称和导入文件原名保留；也可在单场会议的「改名」中选择模板。无需额外调用模型。").font(.caption).foregroundStyle(.secondary)
            Divider()
            StorageSettingsSection(store: store)
            Divider()
            Picker("新录音的转写方式", selection: $transcriptionEngine) {
                Text("本机离线 · 无需 API Key").tag("local"); Text("OpenAI · 保留中英原文").tag("openai"); if store.defaultCloudUpload { Text("Plaud").tag("plaud") }
            }
            Text("上传 Plaud 为可选项，在首次设置中配置。离线转写无需密钥；OpenAI 转写使用自己的 API 额度。说话人身份保留待确认。").font(.caption).foregroundStyle(.secondary)
            Picker("新录音的主要语言", selection: $recordingLanguage) {
                Text("中文为主").tag("zh"); Text("English 为主").tag("en"); Text("自动识别").tag("auto")
            }
            Text("中英混合建议选主要语言。说话人识别始终开启；Plaud 仍可能识别错语言或合并说话人，请回听核对。").font(.caption).foregroundStyle(.secondary)
            Text("会议结束后自动归档").font(.headline)
            Toggle("转写完成后立即自动分析", isOn: $automaticAnalysis)
            Text("有新会议才启动所选后台分析工具；空闲不调用模型。本机每 30 分钟检查中断任务，联网或唤醒后自动续做。背景和截图选填。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !automaticAnalysis { Text("自动分析已关闭。录音、上传和转写照常完成，资料保留；重新开启后处理待办，或到 Codex 继续。").font(.caption).foregroundStyle(.secondary) }
            Picker("结果查看偏好", selection: $resultView) {
                Text("App 与知识库").tag("app")
                Text("在所选工具中继续讨论").tag("codex")
            }
            Text("两种偏好都在后台自动完成分析并保存完整结果。选择继续讨论后，结果页优先显示「复制分析并打开所选工具」；粘贴后即可继续讨论，不自动发送消息，也不弹网页。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("两种工具共用分析标准：沿用各自的模型设置，先检索所选知识库，再按相同深度分析。后台不继承某个聊天里尚未存入知识库的临时上下文，结果不保证逐字相同。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("录音迷你浮窗").font(.headline)
                    Text("开始后收起到右上角，结束后自动展开。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("预览浮窗") { previewRequested = true; dismiss() }.disabled(store.isBusyRecording)
            }
            Divider()
            Button("连接 Plaud 自动上传") { dismiss(); store.showPlaudUploadLogin = true }
            Text("知识库：\(AppRuntime.vault.path)\n分析工具：\(AppRuntime.providerName)\nPlaud 上传：\(store.defaultCloudUpload ? "开启" : "关闭")").font(.callout).lineSpacing(6)
            }.padding(.trailing, 8)
            }
            HStack { Spacer(); Button("关闭") { dismiss() }; Button(saving ? "保存中…" : "保存设置") {
                saving = true
                Task {
                    if await store.saveArchiveSettings(automatic: automaticAnalysis, resultView: resultView) {
                        UserDefaults.standard.set(recordingLanguage, forKey: "recordingLanguage")
                        UserDefaults.standard.set(transcriptionEngine, forKey: "transcriptionEngine")
                        store.saveMeetingNamingSettings(automatic: automaticNames, template: titleTemplate)
                        dismiss()
                    }
                    saving = false
                }
            }.disabled(saving).buttonStyle(MonochromePrimaryStyle()).keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 610, height: 740).onAppear { recordingLanguage = store.defaultRecordingLanguage; transcriptionEngine = store.defaultTranscriptionEngine; automaticAnalysis = store.archiveSettings.automatic; resultView = store.archiveSettings.resultView; automaticNames = store.automaticMeetingNames; titleTemplate = store.defaultTitleTemplate }
            .onDisappear { if previewRequested { windows.preview() } }
    }
}

struct ActiveRecordingBanner: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var recorder: Recorder
    @ObservedObject var windows: RecordingWindowController
    var body: some View {
        if let meeting = store.activeRecording {
            HStack(spacing: 14) {
                Image(systemName: "waveform").font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(store.statusText(meeting.id)).fontWeight(.semibold)
                        Text(clockText(recorder.elapsed)).monospacedDigit()
                    }
                    Text(store.meetingTitle(meeting.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("返回录音") { store.returnToRecording() }
                Button { windows.showCompact() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .accessibilityLabel("收起为迷你浮窗").help("收起为迷你浮窗")
                    .disabled(store.isStarting || store.isStopping)
            }.padding(.horizontal, 28).padding(.vertical, 14).background(paper)
        }
    }
}

struct RecordingCard: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var recorder: Recorder
    @ObservedObject var windows: RecordingWindowController
    var meeting: Meeting
    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white).frame(width: 54, height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(hairline, lineWidth: 1))
                Image(systemName: store.activeRecordingID == meeting.id && recorder.isRecording ? "waveform" : "mic").font(.system(size: 24)).foregroundStyle(ink)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(store.activeRecordingID == meeting.id ? clockText(recorder.elapsed) : clockText(meeting.duration > 0 ? meeting.duration : store.transcripts[meeting.id]?.duration ?? 0)).font(.system(size: 27, weight: .medium, design: .monospaced))
                if store.activeRecordingID == meeting.id {
                    ProgressView(value: Double(recorder.level)).tint(ink).frame(width: 170)
                    Text("录音中 · " + (meeting.capture_mode == "microphone+system" ? "麦克风与电脑声音" : "麦克风")).font(.caption).foregroundStyle(.secondary)
                } else { Text(meeting.capture_mode == "import" ? "已导入的音频" : meeting.capture_state == "draft" ? "准备好后开始录音" : "录音已保存在本机").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if meeting.capture_state == "draft" || store.activeRecordingID == meeting.id {
                VStack(alignment: .trailing, spacing: 10) {
                    if store.activeRecordingID == meeting.id {
                        Button { Task { await store.endRecording() } } label: { Label(store.isStopping ? "正在保存…" : meeting.usesPlaud ? "结束并上传 Plaud" : "结束并自动处理", systemImage: "stop.fill") }.buttonStyle(MonochromePrimaryStyle()).disabled(store.isStarting || store.isStopping)
                        Button { windows.showCompact() } label: { Label("收起为迷你浮窗", systemImage: "arrow.down.right.and.arrow.up.left") }.buttonStyle(MonochromeLinkStyle()).font(.caption).disabled(store.isStarting || store.isStopping)
                    } else {
                        Button { Task { await store.startRecording() } } label: { Label("开始录音", systemImage: "record.circle") }.buttonStyle(MonochromePrimaryStyle()).disabled(store.isBusyRecording)
                        Toggle("同时录制电脑声音", isOn: Binding(get: { meeting.capture_mode == "microphone+system" }, set: { value in store.edit(meeting.id) { $0.capture_mode = value ? "microphone+system" : "microphone" } })).toggleStyle(.checkbox).font(.caption)
                    }
                }
            } else {
                Button { store.playing ? store.stopPlayback() : store.play(meeting.id) } label: { Label(store.isBusyRecording ? "录音结束后可回听" : store.playing ? "停止回听" : "回听录音", systemImage: store.playing ? "stop.fill" : "play.fill") }.buttonStyle(MonochromeSecondaryStyle()).disabled(store.isBusyRecording)
            }
        }.padding(22).background(paper).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hairline, lineWidth: 1))
    }
}

struct MeetingDetail: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var windows: RecordingWindowController
    let id: String
    @StateObject private var speakers: SpeakerAnnotationModel
    init(store: MeetingStore, windows: RecordingWindowController, id: String) {
        self.store = store; self.windows = windows; self.id = id
        _tab = State(initialValue: store.jobs[id]?.state == "done" ? 2 : 0)
        _waitingForInitialJob = State(initialValue: store.jobs[id] == nil && store.locked(id))
        _speakers = StateObject(wrappedValue: SpeakerAnnotationModel(folder: store.folder(id),
            libraryFile: MeetingStore.root.appendingPathComponent("data/participant-names.json")))
    }
    @State private var tab = 0
    @State private var waitingForInitialJob = false
    @State private var editingTitle = false
    @State private var addingDocumentLink = false
    @FocusState private var imagePasteFocused: Bool
    @FocusState private var documentPasteFocused: Bool
    var meeting: Meeting { store.meetings.first(where: {$0.id == id})! }
    func field(_ key: WritableKeyPath<Meeting,String>) -> Binding<String> { Binding(get: { meeting[keyPath: key] }, set: { value in store.edit(id) { $0[keyPath: key] = value } }) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("会议记录").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(store.statusText(id)).font(.caption).foregroundStyle(ink).padding(.horizontal, 12).padding(.vertical, 6).background(paper).clipShape(RoundedRectangle(cornerRadius: 5))
                    if meeting.capture_state == "captured", store.jobs[id]?.state != "done" {
                        Button { store.recoverMeeting(id) } label: {
                            Label(store.recoveryInFlight.contains(id) ? "正在检查…" : "检查并恢复", systemImage: "arrow.clockwise")
                        }.disabled(store.recoveryInFlight.contains(id) || store.documentImports.contains(id) || store.submitting.contains(id))
                        .help("检查中断或长时间无进展的任务，从已有进度续做")
                    }
                }
                if let message = store.recoveryMessages[id] {
                    Text(message).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 12) {
                    Text(store.meetingTitle(id)).font(.system(size: 25, weight: .semibold)).foregroundStyle(ink).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { editingTitle = true } label: { Label("改名", systemImage: "pencil") }
                        .help("手动修改会议名称，或根据分析自动命名")
                }.sheet(isPresented: $editingTitle) { MeetingTitleEditor(store: store, id: id) }
                CollapsibleSection("录音", key: "recording", subtitle: store.statusText(id), symbol: "waveform", initiallyExpanded: true) {
                    if meeting.isPlaud && meeting.cloud_upload != true { plaudCard }
                    else { RecordingCard(store: store, recorder: store.recorder, windows: windows, meeting: meeting) }
                }
                if store.activeRecordingID == id || store.liveCaptions.meetingID == id {
                    LiveCaptionPanel(model: store.liveCaptions, speakers: speakers, isRecording: store.activeRecordingID == id,
                                     enable: { store.startLiveCaptions() }, changeProvider: { store.changeLiveCaptionProvider($0) })
                }
                if meeting.capture_state != "draft" || meeting.cloud_upload == true {
                    CollapsibleSection("处理与归档进度", key: "pipeline", subtitle: store.statusText(id), symbol: "cloud", initiallyExpanded: false) { cloudStatus }
                }
                if let warning = meeting.capture_warning {
                    Label(warning, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(ink).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(paper).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let status = store.statuses[id], status.state == "processing" {
                    HStack(spacing: 12) { ProgressView().controlSize(.small); Text(status.message).font(.callout); Spacer(); Text("可以继续填写背景").font(.caption).foregroundStyle(.secondary) }.padding(15).background(paper).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Picker("会议内容", selection: $tab) { Text("背景与附件").tag(0); Text("分析与归档").tag(2); Text("时间轴转写").tag(1); if meeting.usesPlaud { Text("Plaud 总结").tag(3) } }.pickerStyle(.segmented).labelsHidden()
                if tab == 0 { context }
                if tab == 1 { CollapsibleSection("时间轴转写", key: "timeline", symbol: "text.alignleft") { timeline } }
                if tab == 2 { CollapsibleSection("分析与归档", key: "analysis", subtitle: store.statusText(id), symbol: "doc.text.magnifyingglass", initiallyExpanded: true) { archive } }
                if tab == 3 { CollapsibleSection("Plaud 总结", key: "plaud-summary", symbol: "doc.text") { plaudSummary } }
                Divider()
                HStack {
                    Text("\(AppRuntime.vault.lastPathComponent) · \(AppRuntime.providerName)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("本机文件") { store.showFolder(id) }.buttonStyle(MonochromeLinkStyle()).font(.caption)
                }
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: store.jobs[id]?.state) { _, state in
            if waitingForInitialJob, let state {
                waitingForInitialJob = false
                if state == "done" { tab = 2 }
            }
        }
        .sheet(isPresented: $addingDocumentLink) { DocumentLinkEditor(store: store, id: id) }
    }
    private func openScreenshot(_ name: String) {
        do { try ScreenshotPreview.shared.open(store.folder(id).appendingPathComponent(name)) }
        catch { store.error = error.localizedDescription }
    }
    private func copyScreenshot(_ name: String) {
        do { try ScreenshotAsset(url: store.folder(id).appendingPathComponent(name)).copy() }
        catch { store.error = error.localizedDescription }
    }
    var cloudStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.capture_state == "draft" ? "录完自动上传 Plaud，使用 \(meeting.engineName) 转写" : store.statusText(id)).font(.callout)
                if let progress = store.archiveProgress[id] {
                    Text(progress.detail).font(.caption).foregroundStyle(.secondary)
                }
                Text("录音 → " + (meeting.usesPlaud ? "上传 Plaud → " : "") + "\(meeting.engineName) 转写 → 自动分析归档").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.cloudInFlight.contains(id) || store.archiveProgress[id]?.active == true { ProgressView().controlSize(.small) }
        }.padding(16).background(paper).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    var plaudCard: some View {
        HStack(spacing: 20) {
            Image(systemName: "cloud").font(.system(size: 28)).frame(width: 52)
            VStack(alignment: .leading, spacing: 7) {
                Text("来自你的 Plaud 账户").font(.headline)
                Text(plaudDateText(meeting.created_at) + "  ·  " + clockText(meeting.duration)).font(.caption).foregroundStyle(.secondary)
                Text("转写与总结保留 Plaud 原文；会后补充只用于 Codex 归档。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                HStack {
                    if store.plaudBusy.contains(id) { ProgressView().controlSize(.small) }
                    Button(store.isBusyRecording ? "录音结束后可回听" : store.playing ? "停止回听" : "回听 Plaud 录音") { store.playing ? store.stopPlayback() : store.play(id) }.disabled(store.plaudBusy.contains(id) || store.isBusyRecording)
                }
                HStack {
                    Button("刷新内容") { store.refreshPlaudRecording(id) }.disabled(store.locked(id) || store.plaudBusy.contains(id))
                    Button("打开原版") { store.openOriginalPlaud() }
                }.font(.caption)
            }
        }.padding(20).background(paper).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    var plaudSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plaud 原始总结").font(.title3.bold())
            Text("Plaud 总结是 AI 生成的参考，可能不准确。是否交给 Codex，以“背景与附件”中的发送选项为准。").font(.caption).foregroundStyle(.secondary)
            if let summary = store.summaries[id] {
                if store.statuses[id]?.state != "complete" && !store.locked(id) { Text("下面是上次成功同步的内容，最新同步尚未完成。").font(.caption).foregroundStyle(.secondary) }
                MarkdownView(summary)
            } else { Text("默认无需等待或读取总结。只查看总结不会改变发送选项。").foregroundStyle(.secondary).padding(.vertical, 20) }
            if meeting.isPlaud && !store.locked(id) {
                Button("读取 Plaud 总结（仅查看）") { store.loadPlaudSummary(id) }.disabled(store.plaudBusy.contains(id) || store.cloudInFlight.contains(id))
            }
            Text(store.includesPlaudSummary(id) ? "本次会将总结作为参考交给 Codex。" : "本次不向 Codex 发送 Plaud 总结。").font(.caption).foregroundStyle(.secondary)
        }
    }
    var context: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingStorageSection(store: store, id: id)
            CollapsibleSection("转写与归档选项", key: "options", subtitle: meeting.engineName + " · 自动处理", symbol: "slider.horizontal.3", initiallyExpanded: false) {
                VStack(alignment: .leading, spacing: 14) {
            if !meeting.isPlaud || meeting.cloud_upload == true {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("本次转写方式", selection: Binding(get: { meeting.transcription_engine ?? "local" }, set: { store.setTranscriptionEngine(id, $0) })) {
                        Text("本机离线 · 无需 API Key").tag("local"); Text("OpenAI · 保留中英原文").tag("openai"); if meeting.usesPlaud { Text("Plaud").tag("plaud") }
                    }.disabled(store.cloudInFlight.contains(id) || store.plaudBusy.contains(id) || store.isBusyRecording)
                    Text("已录音的会议切换后会重新处理，录音不会重复上传。归档后转写方式锁定。").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Picker("录音主要语言", selection: field(\.language)) { Text("自动识别").tag("auto"); Text("中文为主").tag("zh"); Text("English 为主").tag("en") }.frame(width: 250)
                    .disabled(meeting.usesPlaud && meeting.capture_state != "draft")
                Spacer()
                if meeting.is_test { Label("模拟测试，不生成真实待办", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
            }
            if meeting.usesPlaud && meeting.transcription_engine != "local" {
                VStack(alignment: .leading, spacing: 7) {
                    Text(meeting.usesOpenAI ? "OpenAI 保留原语言正文；回听时间参考是独立转写，所有说话人待确认。" : "语言在开始录音前选择；导入音频使用设置里的默认值。保留 Plaud 原始转写与说话人标签，不自动翻译或推断身份。").font(.caption).foregroundStyle(.secondary)
                    Toggle("同时发送 Plaud 总结", isOn: Binding(get: { store.includesPlaudSummary(id) }, set: { store.setIncludePlaudSummary(id, $0) }))
                        .disabled(store.plaudBusy.contains(id))
                    Text("默认关闭：转写完成即自动归档，背景和截图选填。开启后会等待总结，并将其作为未经核实的参考。").font(.caption).foregroundStyle(.secondary)
                }.padding(14).background(paper).clipShape(RoundedRectangle(cornerRadius: 8))
            }
                }.disabled(store.locked(id))
            }
            CollapsibleSection("参会人", key: "participants", subtitle: "选填 · 不确定的身份会保留为待确认", initiallyExpanded: true) {
                TextField("例如：我、张明（产品）、Alex（客户）", text: field(\.participants)).textFieldStyle(.roundedBorder).disabled(store.locked(id))
                ParticipantNamesView(model: speakers, select: { name in
                    guard !store.locked(id) else { return }
                    let existing = meeting.participants.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n")).map { $0.trimmingCharacters(in: .whitespaces) }
                    if !existing.contains(name) { store.edit(id) { $0.participants = ($0.participants.isEmpty ? "" : $0.participants + "、") + name } }
                }, allowSelection: !store.locked(id))
            }
            labeled("会议目的", hint: "选填 · 不填写也会自动分析") { TextEditor(text: field(\.purpose)).scrollContentBackground(.hidden).font(.body).frame(height: 80).padding(8).background(paper).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15))) }
            labeled("我的补充", hint: "选填 · 会后判断、额外背景，或需要特别关注的部分") { TextEditor(text: field(\.notes)).scrollContentBackground(.hidden).font(.body).frame(height: 65).padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15))) }
            CollapsibleSection("会议截图", key: "screenshots", subtitle: "\(meeting.images.count) / 8 张 · 选填", symbol: "photo", initiallyExpanded: false) {
                VStack(spacing: 12) {
                    VStack(spacing: 7) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 22))
                        Text("复制图片后，点击这里按 ⌘V 粘贴").font(.callout)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle()).onTapGesture { imagePasteFocused = true }
                    HStack(spacing: 12) {
                        Button { store.pasteImage(id) } label: { Label("粘贴剪贴板图片", systemImage: "doc.on.clipboard") }
                        Button { store.addImages(id) } label: { Label("选择图片文件…", systemImage: "folder") }
                    }
                    Text("也可复制 Finder 中的 PNG、JPEG 图片文件后粘贴 · 每张不超过 15 MB").font(.caption).foregroundStyle(.secondary)
                }.disabled(store.locked(id)).padding(18).frame(maxWidth: .infinity).background(paper).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(imagePasteFocused ? ink : hairline, style: StrokeStyle(lineWidth: 1, dash: imagePasteFocused ? [] : [5, 4])))
                    .focusable(!store.locked(id)).focused($imagePasteFocused).focusEffectDisabled()
                    .onPasteCommand(of: [.image, .fileURL]) { _ in store.pasteImage(id) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("会议截图粘贴区域")
                    .accessibilityHint("点击后按 Command V 粘贴剪贴板图片，也可使用粘贴或选择文件按钮。")
                if !meeting.images.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))],alignment: .leading) {
                        ForEach(meeting.images, id: \.self) { name in
                            VStack { Button { openScreenshot(name) } label: { if let image = NSImage(contentsOf: store.folder(id).appendingPathComponent(name)) { Image(nsImage: image).resizable().scaledToFit().frame(height: 92) } }.buttonStyle(.plain)
                                    .help("打开大图，可缩放、复制或查看原图")
                                    .accessibilityLabel("查看截图：\(name)")
                                    .contextMenu {
                                        Button("查看大图") { openScreenshot(name) }
                                        Button("复制图片") { copyScreenshot(name) }
                                        Button("打开原图") { NSWorkspace.shared.open(store.folder(id).appendingPathComponent(name)) }
                                    }
                                Button("复制图片") { copyScreenshot(name) }.font(.caption).buttonStyle(MonochromeLinkStyle())
                                if !store.locked(id) { Button("移除") { store.edit(id) { $0.images.removeAll {$0 == name} } }.font(.caption).buttonStyle(MonochromeLinkStyle()) }
                            }.padding(8).background(paper).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            documentSection
            if meeting.cloud_upload != true, let s = store.statuses[id], s.state == "error" { HStack { Text(s.message).foregroundStyle(ink); Spacer(); Button(meeting.isPlaud ? "重试同步" : "重试转写") { store.transcribe(id) } }.font(.callout) }
            if !meeting.usesPlaud, meeting.capture_state == "captured", store.statuses[id] == nil { Button("开始转写") { store.transcribe(id) }.buttonStyle(MonochromeSecondaryStyle()) }
            HStack {
                Label(store.jobs[id]?.state == "done" ? "分析与归档已完成。" : store.archiveProgress[id]?.detail ?? store.handoffMessages[id] ?? "录音结束后自动处理并归档，无需点击提交。", systemImage: "checkmark.arrow.trianglehead.counterclockwise").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.submitting.contains(id) { ProgressView().controlSize(.small) }
                // Preserve the old explicit handoff for historical, un-migrated recordings.
                if !meeting.autoArchive {
                    Button("归档这条历史录音") { store.submit(id) }.disabled(store.statuses[id]?.state != "complete")
                }
            }.padding(.top, 12)
        }
    }
    var documentSection: some View {
        CollapsibleSection("会议文档", key: "documents", subtitle: "\((meeting.documents ?? []).count) / 10 份 · 选填", symbol: "paperclip", initiallyExpanded: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 12) {
                    Text("复制文档或链接后，点击这里按 ⌘V 粘贴").font(.callout)
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                        .onTapGesture { documentPasteFocused = true }
                    HStack(spacing: 12) {
                        Button { store.pasteDocuments(id) } label: { Label("粘贴文档或链接", systemImage: "doc.on.clipboard") }
                        Button { store.addDocuments(id) } label: { Label("选择文档文件…", systemImage: "folder") }
                        Button { addingDocumentLink = true } label: { Label("添加链接…", systemImage: "link") }
                    }
                }.disabled(store.locked(id) || store.documentImports.contains(id))
                    .padding(16).frame(maxWidth: .infinity).background(paper).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(documentPasteFocused ? ink : hairline, style: StrokeStyle(lineWidth: 1, dash: documentPasteFocused ? [] : [5, 4])))
                    .focusable(!store.locked(id) && !store.documentImports.contains(id)).focused($documentPasteFocused).focusEffectDisabled()
                    .onPasteCommand(of: [.fileURL, .url, .plainText]) { _ in store.pasteDocuments(id) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("会议文档粘贴区域")
                    .accessibilityHint("复制文件或文档链接后，点击此区域并按 Command V，或使用粘贴按钮。")
                if store.documentImports.contains(id) { HStack { ProgressView().controlSize(.small); Text("正在保存文档…").font(.caption) } }
                Text("支持 PDF、Word (.docx)、PPT (.pptx)、Excel (.xlsx)、Markdown、TXT、CSV；每份 25 MB，每场共 100 MB。原件随会议保存，交给所选工具分析。").font(.caption).foregroundStyle(.secondary)
                Text("也支持在线文档或文件链接，与文件合计最多 10 份。链接在分析时尝试读取，无法访问的内容会注明。").font(.caption).foregroundStyle(.secondary)
                if let message = store.documentErrors[id] { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(meeting.documents ?? []) { document in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: document.source_url == nil ? "doc.text" : "link").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.name).font(.callout.weight(.medium)).textSelection(.enabled)
                            if let url = document.source_url { Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                            Text((document.source_url == nil ? document.sizeText + " · " : "") + document.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button(document.source_url == nil ? "查看" : "打开链接") { store.showDocument(id, document: document) }.accessibilityLabel("查看 " + document.name)
                        if !store.locked(id) {
                            Button("移除") { store.removeDocument(id, document: document) }.disabled(store.documentImports.contains(id)).accessibilityLabel("移除 " + document.name)
                        }
                    }.padding(12).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if store.locked(id) { Text("资料已交给分析工具，附件已锁定，可查看保存的原件。").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    var timeline: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(meeting.usesOpenAI ? "OpenAI · 原语言逐字稿" : "带时间轴的逐字稿").font(.title3.bold())
                Spacer()
                Menu {
                    ForEach(TranscriptExportFormat.allCases, id: \.self) { format in
                        Button(format.label) { store.exportTranscript(id, format: format, speakerNotes: speakers.notes) }
                    }
                } label: {
                    Label(store.transcriptExports.contains(id) ? "正在导出…" : "导出转写", systemImage: "square.and.arrow.down")
                }.fixedSize()
                    .disabled(store.transcriptExportDocument(id) == nil || store.transcriptExports.contains(id))
                    .help("保存 TXT 或 Markdown，包含原文、已有时间参考和说话人标签")
                if !meeting.autoArchive, !store.locked(id), meeting.capture_state == "captured", store.statuses[id]?.state != "processing" {
                    Button(meeting.usesOpenAI ? "继续 OpenAI 处理" : meeting.isPlaud ? "刷新 Plaud 内容" : "重新转写") { store.transcribe(id) }
                        .disabled(store.plaudBusy.contains(id) || store.cloudInFlight.contains(id))
                }
            }
            if let message = store.transcriptExportMessages[id] { Text(message).font(.caption).foregroundStyle(.secondary) }
            if meeting.usesOpenAI, let text = store.transcripts[id]?.text {
                Text(text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text("回听时间参考 · 说话人待确认").font(.headline)
            }
            Text(meeting.usesOpenAI ? "下面是独立转写的回听参考，可能与正文不同。说话人均待确认；短碎片不认定为新人物，疑似合并的标签按发言片段显示。长录音优先按停顿分段，标出的边界疑点不能单独作为决定依据。点击时间回听。" : meeting.isPlaud ? "点击时间回听，首次会从 Plaud 下载原音频。时间与说话人标签来自 Plaud，标签不等于身份确认。" : "点击时间回听。时间位置由模型估计；本版不自动区分说话人，请核对关键内容。").font(.caption).foregroundStyle(.secondary)
            if let transcript = store.transcripts[id] {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 18) {
                        Button(clockText(segment.start_seconds)) { store.play(id, at: segment.start_seconds) }.font(.system(size: 12, design: .monospaced)).buttonStyle(MonochromeLinkStyle()).frame(width: 74).disabled(store.isBusyRecording).help(store.isBusyRecording ? "录音结束后可回听，避免声音录入当前会议" : "回听这一段")
                        VStack(alignment: .leading, spacing: 6) {
                            SpeakerLabelButton(model: speakers, target: .timeline(segment, in: transcript))
                            Text(segment.text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 10)
                    Divider()
                }
            } else { Text(meeting.usesOpenAI ? "录音保存后自动使用 OpenAI 转写，完成后会显示原语言正文和独立时间参考。" : meeting.cloud_upload == true ? "录音结束后自动上传，Plaud 生成的时间轴逐字稿会显示在这里。" : meeting.isPlaud ? "Plaud 尚未生成转写。请在原版中生成，然后刷新这条录音。" : "录音结束后自动开始本机转写，完成后会显示在这里。").foregroundStyle(.secondary).padding(.vertical, 40) }
        }
    }
    var archive: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("会议留下什么？").font(.title3.bold())
            if let text = store.analysis[id] {
                HStack {
                    if store.archiveSettings.resultView == "codex" {
                        Button("复制分析并打开 " + AppRuntime.providerName) { store.discussAnalysis(id) }.buttonStyle(MonochromePrimaryStyle())
                        Button("在知识库中查看") { store.showAnalysisFile(id) }
                    } else {
                        Button("在知识库中查看") { store.showAnalysisFile(id) }
                        Button("复制分析并打开 " + AppRuntime.providerName) { store.discussAnalysis(id) }
                    }
                    Spacer(minLength: 0)
                    Button("复制 Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                MarkdownView(text, baseURL: store.jobs[id]?.outputs?.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
            } else if let job = store.jobs[id] {
                Label(store.statusText(id), systemImage: "tray.and.arrow.up").font(.headline).foregroundStyle(ink)
                Text("资料已保存到所选知识库。后台分析工具会先检索历史资料，再完成分析归档；完整结果显示在这里。中断后自动续做，空闲不调用模型。").font(.callout).foregroundStyle(.secondary)
                if let message = job.last_error, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                Button("打开 " + AppRuntime.providerName) { store.openCodex() }.buttonStyle(MonochromeSecondaryStyle())
            } else if store.submitting.contains(id) { ProgressView("正在保存录音、截图和背景…") }
            else {
                Text("录音结束后自动上传、转写和归档，背景与截图选填。\n结果包括会议分析、决策与行动项、待确认问题，以及可检索的来源摘要。").foregroundStyle(.secondary).lineSpacing(8).padding(.vertical, 22)
            }
        }
    }
    func labeled<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        CollapsibleSection(title, key: "context." + title, subtitle: hint) { content().disabled(store.locked(id)) }
    }
}

// Plaud's official CLI treats API timestamps without an offset as UTC.
func plaudDateText(_ value: String) -> String {
    var normalized = value
    if value.contains("T"), value.range(of: "(?:Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) == nil { normalized += "Z" }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = parser.date(from: normalized)
    if date == nil { parser.formatOptions = [.withInternetDateTime]; date = parser.date(from: normalized) }
    guard let date else { return value }
    let display = DateFormatter(); display.locale = Locale(identifier: "zh_CN"); display.timeZone = TimeZone(identifier: "America/Los_Angeles"); display.dateFormat = "yyyy-MM-dd HH:mm"
    return display.string(from: date) + " · 洛杉矶时间"
}
