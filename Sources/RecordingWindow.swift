import SwiftUI
import AppKit
import Combine

private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum MiniRecordingLayout {
    // Half the original width and height gives one quarter of the screen area.
    static let size = NSSize(width: 43, height: 146)
}

@MainActor final class RecordingWindowController: ObservableObject {
    @Published private(set) var isCompact = false
    @Published private(set) var isPreview = false
    private weak var store: MeetingStore?
    private var mainWindow: NSWindow?
    private var panel: RecordingPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var presentation = RecordingPresentationState()
    private var closedObserver: NSObjectProtocol?
    private var screensObserver: NSObjectProtocol?
    private let silencePrompt = RecordingSilencePromptController()
    private let panelSize = MiniRecordingLayout.size

    func attach(window: NSWindow, store: MeetingStore) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        if self.store == nil {
            self.store = store
            // Published properties emit before assignment; receive on the next main run-loop turn.
            Publishers.MergeMany(
                store.$activeRecordingID.map { _ in () }.eraseToAnyPublisher(),
                store.$isStarting.map { _ in () }.eraseToAnyPublisher(),
                store.$isStopping.map { _ in () }.eraseToAnyPublisher(),
                store.recorder.$isRecording.map { _ in () }.eraseToAnyPublisher()
            ).receive(on: RunLoop.main).sink { [weak self] in self?.syncRecordingState() }.store(in: &subscriptions)
            store.$error.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in
                if self?.isCompact == true { self?.showMain() }
            }.store(in: &subscriptions)
            store.recorder.$silenceReminder.receive(on: RunLoop.main).sink { [weak self] reminder in
                guard let self else { return }
                guard let reminder, let meeting = self.store?.activeRecording,
                      self.store?.recorder.isRecording == true, self.store?.isStopping == false else {
                    self.silencePrompt.dismiss(); return
                }
                self.silencePrompt.present(reminder, meetingTitle: meeting.title,
                    system: meeting.capture_mode == "microphone+system") { [weak self] id, stop in
                    guard let store = self?.store, store.activeRecordingID == meeting.id,
                          !store.isStopping, store.recorder.acknowledgeSilenceReminder(id) else { return }
                    if stop { Task {
                        guard store.activeRecordingID == meeting.id, store.recorder.isRecording else { return }
                        await store.endRecording()
                    } }
                }
            }.store(in: &subscriptions)
            screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionPanel() }
            }
        }
        if let closedObserver { NotificationCenter.default.removeObserver(closedObserver) }
        closedObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.store?.isBusyRecording == true else { return }
                // Closing the expanded window must not leave an active recording without controls.
                self.showCompact()
            }
        }
    }

    private func syncRecordingState() {
        guard let store else { return }
        switch presentation.update(id: store.activeRecordingID, starting: store.isStarting, stopping: store.isStopping, recording: store.recorder.isRecording) {
        case .compact: showCompact()
        case .expanded: showMain()
        case nil: break
        }
    }

    func preview() {
        guard let store, !store.isBusyRecording else { return }
        isPreview = true
        showCompact()
    }

    func showCompact() {
        guard let store, isPreview || store.isBusyRecording else { return }
        if panel == nil {
            let floating = RecordingPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            floating.isReleasedWhenClosed = false
            floating.level = .floating
            floating.isFloatingPanel = true
            floating.hidesOnDeactivate = false
            floating.becomesKeyOnlyIfNeeded = true
            floating.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            floating.isMovableByWindowBackground = true
            floating.isOpaque = false
            floating.backgroundColor = .clear
            floating.hasShadow = true
            floating.contentView = NSHostingView(rootView: MiniRecordingView(store: store, recorder: store.recorder, windows: self).preferredColorScheme(.light))
            panel = floating
        }
        panel?.title = isPreview ? "Plaud威力加强版 · 浮窗预览" : "Plaud威力加强版 · 正在录音"
        positionPanel()
        isCompact = true
        panel?.orderFrontRegardless()
        mainWindow?.orderOut(nil)
    }

    func positionPanel() {
        guard let panel, let screen = mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let safe = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: safe.maxX - panelSize.width - 20, y: safe.maxY - panelSize.height - 20))
    }

    func showMain() {
        isPreview = false
        isCompact = false
        panel?.orderOut(nil)
        store?.returnToRecording()
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish() {
        if isPreview { showMain(); return }
        guard let store, !store.isStarting, !store.isStopping else { return }
        Task { await store.endRecording() }
    }
}

struct MainWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    final class Reader: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
    func makeNSView(context: Context) -> Reader { let view = Reader(); view.onWindow = onWindow; return view }
    func updateNSView(_ nsView: Reader, context: Context) { nsView.onWindow = onWindow }
}

private struct MiniControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 33, height: 32)
            .background(configuration.isPressed ? Color(white: 0.88) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }
}

struct MiniRecordingView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var recorder: Recorder
    @ObservedObject var windows: RecordingWindowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var status: String { windows.isPreview ? "预览" : store.isStopping ? "保存中" : store.isStarting ? "准备中" : "录音中" }
    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 3, height: barHeight(index))
                }
            }.frame(width: 33, height: 32)
                .animation(reduceMotion ? nil : .linear(duration: 0.12), value: recorder.level)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status)
                .accessibilityValue(clockText(windows.isPreview ? 0 : recorder.elapsed))
                .help(windows.isPreview ? "浮窗预览；拖动空白区域移动" : "拖动空白区域移动浮窗")
            Rectangle().fill(Color(white: 0.86)).frame(width: 23, height: 1).accessibilityHidden(true)
            Button { windows.finish() } label: {
                if store.isStopping && !windows.isPreview { ProgressView().controlSize(.mini) }
                else { Image(systemName: "stop.fill").font(.system(size: 15)) }
            }.buttonStyle(MiniControlStyle()).disabled(!windows.isPreview && (store.isStarting || store.isStopping))
                .accessibilityLabel(windows.isPreview ? "结束预览" : "结束录音并转写")
                .help(windows.isPreview ? "结束预览，返回大窗口" : "结束录音、保存并打开大窗口")
            Button { windows.showMain() } label: { Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .regular)) }
                .buttonStyle(MiniControlStyle())
                .accessibilityLabel("展开会议窗口").help("展开窗口，补充会议内容；录音继续")
        }.padding(.horizontal, 5).padding(.vertical, 8)
            .frame(width: MiniRecordingLayout.size.width, height: MiniRecordingLayout.size.height)
            .foregroundStyle(Color.black).background(Color(white: 0.985))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.84), lineWidth: 1))
            .contextMenu { Button("回到右上角") { windows.positionPanel() }; Button("展开会议窗口") { windows.showMain() } }
    }
    private func barHeight(_ index: Int) -> CGFloat {
        let level = windows.isPreview ? 0.38 : Double(recorder.level)
        let shape = [0.5, 0.8, 1.0, 0.72, 0.45][index]
        return 4 + 16 * level * shape
    }
}
