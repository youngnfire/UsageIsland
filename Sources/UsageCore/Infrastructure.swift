import Foundation

public protocol KeychainStoring: Sendable {
    func read(service: String) async -> String?
    func write(service: String, value: String) async throws
    func delete(service: String) async
}

public struct HTTPResult: Equatable, Sendable {
    public let status: Int
    public let retryAfter: TimeInterval?
    public let body: Data

    public init(status: Int, retryAfter: TimeInterval?, body: Data) {
        self.status = status
        self.retryAfter = retryAfter
        self.body = body
    }
}

public protocol HTTPGetting: Sendable {
    func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult
}

/// 토큰이 디스크 캐시나 쿠키 저장소에 남지 않도록 ephemeral 세션만 쓴다.
public struct URLSessionHTTP: HTTPGetting {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchFailure.network("HTTP 응답이 아님")
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return HTTPResult(status: http.statusCode, retryAfter: retryAfter, body: data)
    }
}
