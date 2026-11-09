import SwiftUI
import AppKit
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var provider = "codex"
    @State private var cloudUpload = false
    @State private var engine = "local"
    @State private var vault = AppRuntime.vault.path
    @State private var check = ""
    @State private var busy = false
    @State private var message = ""
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    private var hasArchives: Bool { store.meetings.contains { store.locked($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("欢迎使用威力加强版").font(.title.bold())
            Text("\(step + 1) / 4 · " + ["选择处理方式", "设置知识库", "账户与 API", "录音权限"][step]).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if step == 0 {
                        Text("没有 Plaud 也可以使用").font(.headline)
                        Text("录音和离线转写在本机完成。分析调用这台 Mac 已安装、已登录的 Codex 或 Claude；模型分析通常需要联网，使用你自己的账户额度。")
                        Picker("分析工具", selection: $provider) { Text("Codex").tag("codex"); Text("Claude Code").tag("claude") }
                        Toggle("同时上传到我的 Plaud 账户（可选）", isOn: $cloudUpload)
                        Picker("会后转写", selection: $engine) {
                            Text("本机离线 · 无需 API Key").tag("local")
                            Text("OpenAI · 使用自己的 API Key").tag("openai")
                            if cloudUpload { Text("Plaud").tag("plaud") }
                        }.onChange(of: cloudUpload) { _, enabled in if !enabled && engine == "plaud" { engine = "local" } }
                        Text("已有会议继续使用原来的处理方式；此处设置用于新会议。实时字幕默认离线，可在设置中切换。").font(.caption).foregroundStyle(.secondary)
                    } else if step == 1 {
                        Text("选择分析和归档保存的位置").font(.headline)
                        Text("可以选择已有的 Markdown / Obsidian 知识库，也可以使用默认的本机知识库。每次分析先检索这个目录的历史记录，再更新已有资料。")
                        Text(vault).font(.callout).textSelection(.enabled)
                        Button("选择知识库文件夹…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { vault = url.path }
                        }.disabled(hasArchives)
                        if hasArchives { Text("已有归档使用当前知识库。为保留历史记录和处理中进度，此处不迁移已有资料。").font(.caption).foregroundStyle(.secondary) }
                        Text("录音与附件保存在本机应用资料目录；知识库可由你自己备份或同步。不要选择他人无权查看的共享文件夹。").font(.caption).foregroundStyle(.secondary)
                    } else if step == 2 {
                        Text("连接你的 \(provider == "codex" ? "Codex" : "Claude Code")").font(.headline)
                        HStack {
                            Button(busy ? "检查中…" : "检查安装与登录") { checkTools() }.disabled(busy)
                            Button("登录所选工具…") { login() }
                        }
                        if !check.isEmpty { Text(check).font(.callout).textSelection(.enabled) }
                        Text("需要先安装所选工具，以及 Python 3、FFmpeg。登录在工具自己的窗口完成，本 App 不保存它的账户密码。").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        if engine == "openai" { OpenAISettingsSection(model: store.openAI) }
                        else { Text("本机离线转写无需 OpenAI API Key。以后可在设置中启用云端转写并保存 Key 到 macOS 钥匙串。") }
                        if cloudUpload { Text("完成后可从侧栏连接你自己的 Plaud 账户；未连接前录音仍保存在本机。") }
                    } else {
                        Text("权限按需开启").font(.headline)
                        HStack { Text(microphone ? "麦克风已允许" : "麦克风尚未允许"); Spacer(); Button("允许麦克风") { Task { microphone = await AVCaptureDevice.requestAccess(for: .audio) } } }
                        Button("打开系统音频录制权限设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        Text("录制电脑声音时，macOS 可能显示系统音频授权。请确认来源为本 App 后允许。使用知识库和文档时，系统也可能请求该目录的访问权限。").font(.callout)
                        Text("完成后即可录音；结束录音会自动转写、分析和归档。权限暂未开启时也可以导入已有音频。")
                    }
                    if !message.isEmpty { Text(message).foregroundStyle(.red).font(.callout) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("稍后设置") { dismiss() }
                Spacer()
                if step > 0 { Button("上一步") { step -= 1 } }
                Button(step == 3 ? "完成设置" : "下一步") { if step < 3 { step += 1 } else { finish() } }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 650, height: 610)
        .onAppear {
            let saved = AppRuntime.settings(); provider = saved["archive_provider"] as? String ?? "codex"
            cloudUpload = store.defaultCloudUpload; engine = store.defaultTranscriptionEngine
        }
    }
    private func checkTools() {
        busy = true
        let selected = provider
        Task {
            check = await Task.detached {
                var lines = ["Python：\(AppRuntime.python.path)", "FFmpeg：\(AppRuntime.tool("ffmpeg") == nil ? "未安装" : "已安装")"]
                if let tool = AppRuntime.tool(selected) {
                    let p = Process(); let pipe = Pipe()
                    p.executableURL = tool; p.arguments = selected == "claude" ? ["auth", "status"] : ["login", "status"]
                    p.standardOutput = pipe; p.standardError = pipe
                    do {
                        try p.run()
                        let deadline = Date().addingTimeInterval(15)
                        while p.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                        if p.isRunning { p.terminate(); lines.append("\(selected)：已安装，登录检查超时") }
                        else { lines.append("\(selected)：已安装，" + (p.terminationStatus == 0 ? "已登录" : "请先登录")) }
                    } catch { lines.append("\(selected)：无法启动") }
                } else { lines.append("\(selected)：未安装") }
                return lines.joined(separator: "\n")
            }.value
            busy = false
        }
    }
    private func login() {
        guard let tool = AppRuntime.tool(provider) else { message = "请先安装 \(provider == "codex" ? "Codex CLI" : "Claude Code")，再点击登录。"; return }
        do {
            let file = AppRuntime.root.appendingPathComponent("login-\(provider).command")
            let quoted = "'" + tool.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try ("#!/bin/sh\nexec " + quoted + (provider == "claude" ? " auth login\n" : " login\n")).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch { message = "登录窗口未能打开，请在所选工具中完成登录。" }
    }
    private func finish() {
        do {
            let url = URL(fileURLWithPath: vault)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".meeting-write-check-" + UUID().uuidString)
            try Data().write(to: probe); try FileManager.default.removeItem(at: probe)
            try AppRuntime.save(["vault_path":url.path, "archive_provider":provider, "archive_mode":"app-background",
                "archive_auto_trigger":true, "onboarding_complete":true, "cloud_upload":cloudUpload])
            UserDefaults.standard.set(engine, forKey: "transcriptionEngine")
            for meeting in store.meetings where meeting.capture_state == "draft" {
                store.edit(meeting.id) { $0.cloud_upload = cloudUpload; $0.transcription_engine = engine }
            }
            store.recoverArchives()
            if Bundle.main.bundleIdentifier == "com.local.meetingmemory.mac" {
            Task.detached(priority: .utility) {
                let p = Process(); p.executableURL = AppRuntime.python
                p.arguments = [AppRuntime.root.appendingPathComponent("install_archive_recovery.py").path]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run()
            }
            }
            dismiss()
        } catch { message = "无法保存设置或写入知识库：" + error.localizedDescription }
    }
}
