import SwiftUI

struct LiveCaptionPanel: View {
    @ObservedObject var model: LiveCaptionModel
    var speakers: SpeakerAnnotationModel? = nil
    var isRecording: Bool
    var enable: () -> Void
    var changeProvider: (LiveCaptionProvider) -> Void = { _ in }
    @AppStorage("liveCaptionProvider") private var providerName = LiveCaptionProvider.offline.rawValue
    @State private var follow = true
    @State private var window = 600.0
    private var display: (rows: [LiveCaption], historical: Bool) { LiveCaptionHistory.window(model.captions, now: model.elapsed, seconds: window) }
    private var rows: [LiveCaption] { display.rows }
    var body: some View {
        CollapsibleSection("实时字幕", key: "live", subtitle: model.connectionSummary, symbol: "captions.bubble") {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("字幕方式", selection: Binding(get: {
                    LiveCaptionProvider(rawValue: providerName) ?? .offline
                }, set: changeProvider)) {
                    ForEach(LiveCaptionProvider.allCases) { Text($0.label).tag($0) }
                }.frame(width: 250)
                Spacer()
                if isRecording {
                    if model.enabled && !model.allConnected {
                        Button(model.provider == .offline ? "重启字幕" : "重连字幕") { enable() }.help("只重新启动字幕服务，不停止录音")
                    }
                    Button(model.enabled ? "暂停字幕" : "开启字幕") { model.enabled ? model.pause() : enable() }
                        .help("只控制字幕，录音继续")
                }
                Button { model.catchUp() } label: {
                    Label(model.recapBusy ? "正在整理…" : "刚才说了什么？", systemImage: "arrow.counterclockwise")
                }.disabled(model.recapBusy || LiveCatchUp.recent(model.captions, now: model.elapsed, seconds: 180).isEmpty)
            }
            HStack {
                Picker("回看", selection: $window) { Text("最近 2 分钟").tag(120.0); Text("最近 5 分钟").tag(300.0); Text("最近 10 分钟").tag(600.0) }
                    .frame(width: 180)
                Spacer()
                if !follow { Button("回到最新") { follow = true } }
                else { Text("滚动回看时暂停跟随").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        if rows.isEmpty {
                            Text(model.enabled ? (model.allConnected ? "正在等待语音。字幕会保留原来的中文和 English。" : "字幕正在准备或恢复，目前还没有可显示的内容；本地录音继续。") : "开启后边录边看，录音与会后归档照常进行。")
                                .foregroundStyle(.secondary).padding(.vertical, 18)
                        }
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("约 \(clockText(row.start)) · \(speakers == nil ? row.sourceLabel : row.source == "microphone" ? "麦克风" : "电脑声音")\(row.final ? "" : " · 正在识别")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let speakers { SpeakerLabelButton(model: speakers, target: .live(row)) }
                                Text(row.reviewText).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if row.reviewReason != nil && !row.text.hasPrefix("［") {
                                    DisclosureGroup("查看有疑问的原始字幕") {
                                        Text(row.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    }.font(.caption)
                                }
                            }.id(row.id)
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }.padding(12)
                }.frame(height: 260)
                    .background(LiveScrollIntent { follow = false })
                    .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15)))
                    .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { _ in follow = false })
                    .onChange(of: model.captions) { _, _ in if follow { proxy.scrollTo("live-bottom", anchor: .bottom) } }
                    .onChange(of: follow) { _, value in if value { proxy.scrollTo("live-bottom", anchor: .bottom) } }
            }
            if model.enabled || !model.statuses.isEmpty {
                if display.historical, let latest = rows.map(\.end).max() {
                    Text("最近 \(Int(window/60)) 分钟没有新字幕。以上保留截至 \(clockText(latest)) 收到的较早内容，并非当前发言；会后生成完整转写。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(model.statuses.keys.sorted().map { ($0 == "microphone" ? "麦克风：" : "电脑声音：")+(model.statuses[$0] ?? "") }.joined(separator: "　"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.recapBusy || !model.recap.isEmpty {
                Divider()
                HStack { Text(model.recapIsExcerpt ? "最近 3 分钟 · 字幕原文回看" : "最近 3 分钟 · 补看摘要").font(.subheadline.bold()); if model.recapBusy { ProgressView().controlSize(.small) } }
                Text(model.recapRange).font(.caption).foregroundStyle(.secondary)
                if !model.recapWarning.isEmpty { Text(model.recapWarning).font(.callout).foregroundStyle(.secondary) }
                if !model.recap.isEmpty {
                    ScrollView {
                        Group {
                            if model.recapIsExcerpt { Text(model.recap) }
                            else { Text(.init(model.recap)) }
                        }.textSelection(.enabled).font(.callout).lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(maxHeight: 260).background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15)))
                }
            }
            Text(model.provider == .offline
                 ? "离线字幕与原文补看在本机完成，无需联网或 API 密钥；身份待确认。会后上传、转写和分析归档仍按原设置联网处理。"
                 : "字幕使用 OpenAI，另计 API 用量；时间为片段参考，身份待确认。会后仍会生成完整转写、分析与归档。")
                .font(.caption).foregroundStyle(.secondary)
          }
        }
    }
}

private struct LiveScrollIntent: NSViewRepresentable {
    var action: () -> Void
    final class View: NSView {
        var action: () -> Void = {}
        var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.action() }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> View { let view = View(); view.action = action; return view }
    func updateNSView(_ view: View, context: Context) { view.action = action }
    static func dismantleNSView(_ view: View, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor); view.monitor = nil }
    }
}
