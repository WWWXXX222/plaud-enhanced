import SwiftUI
import WebKit

struct PlaudWebFailure: LocalizedError {
    let code: String
    var errorDescription: String? {
        switch code {
        case "LOGIN": return "请在 App 内登录 Plaud，完成后点“检查连接并继续”。"
        case "ACCOUNT": return "上传页面与已连接的 Plaud 账户不同，请切换到同一账户和工作区。"
        case "VERSION": return "Plaud 上传接口暂不兼容，录音已保留；需要更新连接适配。"
        default: return "Plaud 处理暂未完成（\(code)）。录音和上传进度已保留，可重试。"
        }
    }
}

@MainActor final class PlaudWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var popup: NSWindow?
    @Published var message = "在 Plaud 官方页面登录同一个账户。登录状态保留在此 App 内。"
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
    }
    func load() {
        if webView.url == nil { webView.load(URLRequest(url: URL(string: "https://web.plaud.ai/")!)) }
    }
    func call(_ action: String, _ payload: [String:Any] = [:]) async throws -> [String:Any] {
        load()
        // Initial navigation is not an expired login. Retry after the official
        // page and its workspace store have finished restoring their session.
        if webView.isLoading { throw PlaudWebFailure(code: "CONNECTION") }
        guard webView.url?.scheme == "https", webView.url?.host == "web.plaud.ai" else { throw PlaudWebFailure(code: "LOGIN") }
        guard let adapterURL = Bundle.main.url(forResource: "plaud_web_adapter", withExtension: "js") else { throw PlaudWebFailure(code: "INSTALL") }
        let source = try await Task.detached { try String(contentsOf: adapterURL, encoding: .utf8) }.value
        let result: Any
        do { result = try await webView.callAsyncJavaScript(source, arguments: ["action":action,"payload":payload], in: nil, contentWorld: .page) as Any }
        catch { throw PlaudWebFailure(code: "CONNECTION") }
        guard let response = result as? [String:Any] else { throw PlaudWebFailure(code: "CONNECTION") }
        guard response["ok"] as? Bool == true else {
            let code = response["code"] as? String ?? "CONNECTION"
            let status = response["status"] as? Int
            throw PlaudWebFailure(code: code + (status.map { " \($0)" } ?? ""))
        }
        return response
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Login providers may redirect across HTTPS origins. Custom-scheme launches stay disabled.
        decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 600,height: 760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.title = "Plaud 官方账户登录"; window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil)
        popup = window; return view
    }
    func webViewDidClose(_ webView: WKWebView) {
        // Google GIS closes its popup while delivering a postMessage to the opener.
        // Keep the WebKit popup alive until the next login rather than releasing it inside this callback.
        if popup?.contentView === webView { popup?.orderOut(nil) }
    }
}

struct PlaudWebContent: NSViewRepresentable {
    let session: PlaudWebSession
    func makeNSView(context: Context) -> WKWebView { session.load(); return session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
struct PlaudUploadConnectionView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var session: PlaudWebSession
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("连接 Plaud 上传").font(.headline)
                    Text(session.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("检查连接并继续") { store.checkUploadConnection() }
                Button("完成") { store.showPlaudUploadLogin = false }
            }.padding(18)
            Divider()
            PlaudWebContent(session:session)
        }.frame(width:1000,height:730)
    }
}
