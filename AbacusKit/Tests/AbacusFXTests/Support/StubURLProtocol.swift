import Foundation
import Synchronization

/// Serves canned responses so `swift test` never touches the network (R-NF-1). Each test gets
/// its own `StubNetwork` with its own `URLSession`; the session tags requests with a header so
/// parallel tests never see each other's routes.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  static let header = "X-Stub-Network"
  static let networks = Mutex<[String: StubNetwork]>([:])

  override class func canInit(with request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: header) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let id = request.value(forHTTPHeaderField: Self.header) ?? ""
    guard let network = Self.networks.withLock({ $0[id] }), let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    switch network.respond(to: url) {
    case .failure(let error):
      client?.urlProtocol(self, didFailWithError: error)
    case .success(let (status, body)):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

/// Routes: the first route whose predicate matches the URL answers. Unmatched URLs fail the
/// request with `URLError(.cannotConnectToHost)`, like being offline.
final class StubNetwork: Sendable {
  typealias Responder = @Sendable (URL) -> Result<(Int, String), URLError>?

  let id = UUID().uuidString
  let session: URLSession
  private let state = Mutex<(routes: [Responder], requests: [URL])>(([], []))

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [StubURLProtocol.header: id]
    session = URLSession(configuration: configuration)
    StubURLProtocol.networks.withLock { $0[id] = self }
  }

  deinit {
    let id = id
    StubURLProtocol.networks.withLock { $0[id] = nil }
  }

  /// Answers URLs on `host` whose query contains every `key=value` in `query`.
  func on(
    host: String, query: [String: String] = [:], status: Int = 200, body: String
  ) {
    route { url in
      guard url.host == host else { return nil }
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      for (key, value) in query where !items.contains(where: { $0.name == key && $0.value == value }) {
        return nil
      }
      return .success((status, body))
    }
  }

  /// Fails every request to `host` with a transport error.
  func fail(host: String, code: URLError.Code = .notConnectedToInternet) {
    route { url in url.host == host ? .failure(URLError(code)) : nil }
  }

  func route(_ responder: @escaping Responder) {
    state.withLock { $0.routes.append(responder) }
  }

  var requests: [URL] { state.withLock { $0.requests } }

  func requests(host: String) -> [URL] { requests.filter { $0.host == host } }

  fileprivate func respond(to url: URL) -> Result<(Int, String), URLError> {
    state.withLock { state in
      state.requests.append(url)
      for route in state.routes {
        if let result = route(url) { return result }
      }
      return .failure(URLError(.cannotConnectToHost))
    }
  }
}

extension URL {
  func queryValue(_ name: String) -> String? {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }

  func hasQueryItem(_ name: String) -> Bool {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?
      .contains { $0.name == name } ?? false
  }
}
