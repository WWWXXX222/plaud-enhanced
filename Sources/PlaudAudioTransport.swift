import Foundation
import CFNetwork

private final class NoUploadRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum PlaudAudioTransport {
    enum Route: Equatable { case system, direct }
    struct Receipt { let etag: String; let route: Route }
    enum Failure: LocalizedError {
        case address, response, interrupted
        var errorDescription: String? {
            switch self {
            case .address: return "Plaud 返回了不支持的上传地址。"
            case .response, .interrupted: return "音频上传中断，原始录音仍在本机；恢复网络后重试。"
            }
        }
    }
    typealias Sender = (Data, URL, Route) async throws -> String

    static func configuration(_ route: Route) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        if route == .direct {
            // Applies only to the verified audio-storage PUT, never login/API traffic.
            // TLS validation and redirect rejection remain unchanged.
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesSOCKSEnable as String: 0,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
            ]
        }
        return configuration
    }

    static func canTryDirect(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

    static func upload(_ data: Data, url rawURL: String, startingRoute: Route = .system,
                       send: Sender = sendPart) async throws -> Receipt {
        guard let url = URL(string:rawURL), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              host.hasSuffix(".amazonaws.com") || host.hasSuffix(".plaud.ai") else { throw Failure.address }
        var route = startingRoute
        for attempt in 0..<3 {
            do {
                let etag = try await send(data, url, route)
                guard !etag.isEmpty else { throw Failure.response }
                return Receipt(etag:etag, route:route)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if attempt == 2 { throw Failure.interrupted }
                // A repeated PUT of this same signed multipart part is idempotent.
                // Do not create a new upload or relax TLS/host checks to recover it.
                if route == .system && canTryDirect(error) { route = .direct }
            }
        }
        throw Failure.interrupted
    }

    static func sendPart(_ data: Data, _ url: URL, _ route: Route) async throws -> String {
        let session = URLSession(configuration:configuration(route),delegate:NoUploadRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url:url); request.httpMethod = "PUT"; request.timeoutInterval = 120
        let (_, response) = try await session.upload(for:request,from:data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let etag = http.value(forHTTPHeaderField:"ETag"), !etag.isEmpty else { throw Failure.response }
        return etag.replacingOccurrences(of:"\"",with:"")
    }

}
