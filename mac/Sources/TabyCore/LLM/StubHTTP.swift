// Prüf-Hilfe: HTTP-Grenze per URLProtocol stubben (kein echtes Netz).
// Jeder Stub bekommt einen eigenen Host (`stub-<uuid>.test`), damit sich
// Prüfungen nicht gegenseitig beeinflussen.
import Foundation

struct StubRequest {
  var method: String
  var url: URL
  var headers: [String: String]
  var body: JSONValue?

  func header(_ name: String) -> String? {
    headers.first { $0.key.lowercased() == name.lowercased() }?.value
  }
}

enum StubReply {
  case json(status: Int, body: String)
  case transportError(URLError.Code)
  /// Antwortet nie (für Abbruch-Prüfungen).
  case hang
  /// Antwort erst bei der Anfrage erzeugen (z. B. mit einer ID, die erst
  /// während der Prüfung entsteht).
  case dynamic(@Sendable () -> StubReply)
}

final class StubServer: @unchecked Sendable {
  let host: String
  private let lock = NSLock()
  private var _requests: [StubRequest] = []
  private let script: [StubReply]

  var requests: [StubRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
  var baseUrl: String { "https://\(host)/api/v1" }

  /// Pro Anfrage der nächste Eintrag; danach wird der letzte wiederholt
  /// (wie der TS-Mock, so lässt sich eine Endlosschleife simulieren).
  init(_ script: [StubReply]) {
    host = "stub-\(UUID().uuidString.lowercased()).test"
    self.script = script
    StubURLProtocol.register(self)
  }

  func record(_ r: StubRequest) -> StubReply {
    lock.lock(); defer { lock.unlock() }
    _requests.append(r)
    if script.isEmpty { return .json(status: 500, body: "{}") }
    return script[min(_requests.count - 1, script.count - 1)]
  }

  lazy var session: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
  }()

  /// Erfolgreiche Chat-Antwort mit dieser assistant-Nachricht (rohes JSON).
  static func completion(_ messageJSON: String) -> StubReply {
    .json(status: 200, body: #"{"id":"x","choices":[{"index":0,"message":"# + messageJSON + "}]}")
  }

  static func text(_ content: String) -> StubReply {
    completion(JSONValue.object(["role": "assistant", "content": .string(content)]).jsonString())
  }

  static func toolCall(_ name: String, _ args: String, id: String = "c1") -> StubReply {
    completion(
      JSONValue.object([
        "role": "assistant", "content": .null,
        "tool_calls": [["id": .string(id), "type": "function",
                        "function": ["name": .string(name), "arguments": .string(args)]]],
      ]).jsonString())
  }
}

final class StubURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var servers: [String: WeakServer] = [:]
  private struct WeakServer { weak var server: StubServer? }

  static func register(_ s: StubServer) {
    lock.lock(); servers[s.host] = WeakServer(server: s); lock.unlock()
  }

  private static func server(for host: String?) -> StubServer? {
    guard let host else { return nil }
    lock.lock(); defer { lock.unlock() }
    return servers[host]?.server
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private static func readBody(_ r: URLRequest) -> Data? {
    if let b = r.httpBody { return b }
    guard let stream = r.httpBodyStream else { return nil }
    stream.open(); defer { stream.close() }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let n = stream.read(&buf, maxLength: buf.count)
      if n <= 0 { break }
      data.append(buf, count: n)
    }
    return data
  }

  override func startLoading() {
    guard let url = request.url, let server = Self.server(for: url.host) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    let body = Self.readBody(request).flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) }
    let reply = server.record(
      StubRequest(method: request.httpMethod ?? "GET", url: url,
                  headers: request.allHTTPHeaderFields ?? [:], body: body))
    var resolved = reply
    while case .dynamic(let make) = resolved { resolved = make() }
    switch resolved {
    case .dynamic:
      break
    case .json(let status, let text):
      let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                 headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(text.utf8))
      client?.urlProtocolDidFinishLoading(self)
    case .transportError(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .hang:
      break
    }
  }

  override func stopLoading() {}
}
