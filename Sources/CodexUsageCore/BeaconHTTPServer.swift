import Foundation
@preconcurrency import Network

public protocol BeaconAPIKeyValidating: Sendable {
  func validate(apiKey: String) -> Bool
}

extension BeaconAPIKeyStore: BeaconAPIKeyValidating {}

public struct BeaconHTTPResponse: Equatable, Sendable {
  public var statusCode: Int
  public var headers: [String: String]
  public var body: Data

  public init(statusCode: Int, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

public struct BeaconHTTPRequestHandler: Sendable {
  private let service: CodexMonitorCollectionService
  private let apiKeyValidator: BeaconAPIKeyValidating
  private let now: @Sendable () -> Date

  public init(
    service: CodexMonitorCollectionService,
    apiKeyValidator: BeaconAPIKeyValidating,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.service = service
    self.apiKeyValidator = apiKeyValidator
    self.now = now
  }

  public func handle(
    method: String,
    path: String,
    headers: [String: String],
    body: Data
  ) async -> BeaconHTTPResponse {
    _ = body
    if path == "/health" {
      return json(statusCode: 200, ["ok": true])
    }
    guard authorized(headers: headers) else {
      return json(statusCode: 401, ["error": "unauthorized"])
    }

    do {
      switch (method, path) {
      case ("GET", "/api/v1/cards"):
        return try await encodedJSON(
          statusCode: 200,
          service.beaconPayload(generatedAt: now())
        )
      case ("GET", "/api/v1/status"):
        return await encodedJSON(statusCode: 200, service.status(now: now()))
      case ("POST", "/api/v1/refresh"):
        _ = try await service.refreshNow()
        return try await encodedJSON(
          statusCode: 200,
          service.beaconPayload(generatedAt: now())
        )
      default:
        return json(statusCode: 404, ["error": "not_found"])
      }
    } catch {
      return json(statusCode: 500, ["error": error.localizedDescription])
    }
  }

  private func authorized(headers: [String: String]) -> Bool {
    let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    guard let authorization = normalized["authorization"] else {
      return false
    }
    let prefix = "Bearer "
    guard authorization.hasPrefix(prefix) else {
      return false
    }
    return apiKeyValidator.validate(apiKey: String(authorization.dropFirst(prefix.count)))
  }

  private func encodedJSON<T: Encodable>(statusCode: Int, _ value: T) -> BeaconHTTPResponse {
    do {
      return BeaconHTTPResponse(
        statusCode: statusCode,
        headers: ["Content-Type": "application/json"],
        body: try JSONEncoder.codexMonitor.encode(value)
      )
    } catch {
      return json(statusCode: 500, ["error": error.localizedDescription])
    }
  }

  private func json(statusCode: Int, _ value: [String: Any]) -> BeaconHTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    return BeaconHTTPResponse(
      statusCode: statusCode,
      headers: ["Content-Type": "application/json"],
      body: body
    )
  }
}

public final class BeaconHTTPServer: @unchecked Sendable {
  private let handler: BeaconHTTPRequestHandler
  private let queue = DispatchQueue(label: "net.pardev.CodexMonitor.beacon-http")
  private var listener: NWListener?

  public init(handler: BeaconHTTPRequestHandler) {
    self.handler = handler
  }

  public func start(port: UInt16) throws {
    stop()
    let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    listener.newConnectionHandler = { [handler, queue] connection in
      connection.start(queue: queue)
      Self.receiveRequest(on: connection, handler: handler)
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  public func stop() {
    listener?.cancel()
    listener = nil
  }

  private static func receiveRequest(on connection: NWConnection, handler: BeaconHTTPRequestHandler) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
      let request = parseRequest(data ?? Data())
      Task {
        let response = await handler.handle(
          method: request.method,
          path: request.path,
          headers: request.headers,
          body: request.body
        )
        let payload = serialize(response)
        connection.send(content: payload, completion: .contentProcessed { _ in
          connection.cancel()
        })
      }
    }
  }

  private static func parseRequest(_ data: Data) -> (method: String, path: String, headers: [String: String], body: Data) {
    guard let raw = String(data: data, encoding: .utf8) else {
      return ("GET", "/", [:], Data())
    }
    let parts = raw.components(separatedBy: "\r\n\r\n")
    let head = parts.first ?? ""
    let body = parts.dropFirst().joined(separator: "\r\n\r\n")
    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
    let method = requestLine.first ?? "GET"
    let path = requestLine.dropFirst().first ?? "/"
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
      guard pieces.count == 2 else {
        continue
      }
      headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces)
    }
    return (method, path, headers, Data(body.utf8))
  }

  private static func serialize(_ response: BeaconHTTPResponse) -> Data {
    let reason = reasonPhrase(for: response.statusCode)
    var head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
    let headers = response.headers.merging([
      "Content-Length": "\(response.body.count)",
      "Connection": "close",
    ]) { current, _ in current }
    for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(response.body)
    return data
  }

  private static func reasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 200:
      return "OK"
    case 401:
      return "Unauthorized"
    case 404:
      return "Not Found"
    case 500:
      return "Internal Server Error"
    default:
      return "OK"
    }
  }
}
