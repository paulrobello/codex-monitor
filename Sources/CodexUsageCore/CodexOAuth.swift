import CryptoKit
import Foundation
import Network
import Security

enum CodexOAuthConstants {
  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let authBaseURL = URL(string: "https://auth.openai.com")!
  static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
  static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
  static let redirectURI = "http://localhost:1455/auth/callback"
  static let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"
  static let scope = "openid profile email offline_access"
  static let originator = "codex_monitor"
}

public struct CodexDeviceCodeLogin: Equatable, Sendable {
  public var verificationURL: URL
  public var userCode: String
  public var deviceAuthID: String
  public var interval: TimeInterval

  public init(verificationURL: URL, userCode: String, deviceAuthID: String, interval: TimeInterval)
  {
    self.verificationURL = verificationURL
    self.userCode = userCode
    self.deviceAuthID = deviceAuthID
    self.interval = interval
  }
}

final class CodexOAuthService: @unchecked Sendable {
  private let urlSession: URLSession

  init(urlSession: URLSession) {
    self.urlSession = urlSession
  }

  func login(openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void) async throws
    -> CodexAuthCredentials
  {
    let verifier = try randomBase64URL(byteCount: 32)
    let state = try randomHex(byteCount: 16)
    let challenge = pkceChallenge(for: verifier)
    let server = try CodexOAuthCallbackServer(state: state)

    try await server.start()
    defer {
      server.close()
    }

    try await openAuthorizationURL(authorizationURL(challenge: challenge, state: state))
    let code = try await server.waitForCode()
    return try await exchangeAuthorizationCode(code: code, verifier: verifier)
  }

  func loginWithDeviceCode(
    openVerificationURL: @escaping @Sendable (URL) async throws -> Void,
    onCode: @escaping @Sendable (CodexDeviceCodeLogin) async -> Void
  ) async throws -> CodexAuthCredentials {
    let login = try await beginDeviceCodeLogin()
    await onCode(login)
    try await openVerificationURL(login.verificationURL)
    return try await completeDeviceCodeLogin(login)
  }

  func beginDeviceCodeLogin() async throws -> CodexDeviceCodeLogin {
    let deviceCode = try await requestDeviceCode()
    return CodexDeviceCodeLogin(
      verificationURL: CodexOAuthConstants.authBaseURL.appendingPathComponent("codex/device"),
      userCode: deviceCode.userCode,
      deviceAuthID: deviceCode.deviceAuthID,
      interval: deviceCode.interval
    )
  }

  func completeDeviceCodeLogin(_ login: CodexDeviceCodeLogin) async throws -> CodexAuthCredentials {
    let deviceCode = DeviceCode(
      deviceAuthID: login.deviceAuthID,
      userCode: login.userCode,
      interval: login.interval
    )
    let code = try await pollForDeviceAuthorizationCode(deviceCode)
    return try await exchangeDeviceAuthorizationCode(code)
  }

  func refresh(refreshToken: String) async throws -> CodexAuthCredentials {
    var request = URLRequest(url: CodexOAuthConstants.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formBody([
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": CodexOAuthConstants.clientID,
    ])

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CodexUsageError.tokenRefreshFailed(nil)
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw CodexUsageError.tokenRefreshFailed(httpResponse.statusCode)
    }
    return try credentials(from: data)
  }

  private struct DeviceCode {
    var deviceAuthID: String
    var userCode: String
    var interval: TimeInterval
  }

  private struct DeviceAuthorizationCode {
    var authorizationCode: String
    var codeVerifier: String
  }

  private func requestDeviceCode() async throws -> DeviceCode {
    let url = CodexOAuthConstants.authBaseURL
      .appendingPathComponent("api/accounts/deviceauth/usercode")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try jsonBody(["client_id": CodexOAuthConstants.clientID])

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CodexUsageError.deviceCodeFailed("user-code request returned no HTTP response")
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw CodexUsageError.deviceCodeFailed(
        "user-code request returned HTTP \(httpResponse.statusCode)")
    }
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let deviceAuthID = root["device_auth_id"] as? String,
      let userCode = (root["user_code"] as? String) ?? (root["usercode"] as? String)
    else {
      throw CodexUsageError.deviceCodeFailed("user-code response was missing fields")
    }
    return DeviceCode(
      deviceAuthID: deviceAuthID,
      userCode: userCode,
      interval: interval(from: root["interval"])
    )
  }

  private func pollForDeviceAuthorizationCode(_ deviceCode: DeviceCode) async throws
    -> DeviceAuthorizationCode
  {
    let url = CodexOAuthConstants.authBaseURL
      .appendingPathComponent("api/accounts/deviceauth/token")
    let deadline = Date().addingTimeInterval(15 * 60)

    while Date() < deadline {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try jsonBody([
        "device_auth_id": deviceCode.deviceAuthID,
        "user_code": deviceCode.userCode,
      ])

      let (data, response) = try await urlSession.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw CodexUsageError.deviceCodeFailed("poll returned no HTTP response")
      }
      if (200..<300).contains(httpResponse.statusCode) {
        guard
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let authorizationCode = root["authorization_code"] as? String,
          let codeVerifier = root["code_verifier"] as? String
        else {
          throw CodexUsageError.deviceCodeFailed("poll response was missing fields")
        }
        return DeviceAuthorizationCode(
          authorizationCode: authorizationCode,
          codeVerifier: codeVerifier
        )
      }
      if httpResponse.statusCode != 403 && httpResponse.statusCode != 404 {
        throw CodexUsageError.deviceCodeFailed("poll returned HTTP \(httpResponse.statusCode)")
      }

      try await Task.sleep(nanoseconds: UInt64(max(deviceCode.interval, 1) * 1_000_000_000))
    }

    throw CodexUsageError.deviceCodeFailed("timed out after 15 minutes")
  }

  private func exchangeDeviceAuthorizationCode(_ code: DeviceAuthorizationCode) async throws
    -> CodexAuthCredentials
  {
    var request = URLRequest(url: CodexOAuthConstants.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formBody([
      "grant_type": "authorization_code",
      "client_id": CodexOAuthConstants.clientID,
      "code": code.authorizationCode,
      "code_verifier": code.codeVerifier,
      "redirect_uri": CodexOAuthConstants.deviceRedirectURI,
    ])

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CodexUsageError.tokenExchangeFailed(nil)
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw CodexUsageError.tokenExchangeFailed(httpResponse.statusCode)
    }
    return try credentials(from: data, requiresExpiresIn: false)
  }

  private func authorizationURL(challenge: String, state: String) -> URL {
    var components = URLComponents(
      url: CodexOAuthConstants.authorizeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: CodexOAuthConstants.clientID),
      URLQueryItem(name: "redirect_uri", value: CodexOAuthConstants.redirectURI),
      URLQueryItem(name: "scope", value: CodexOAuthConstants.scope),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "id_token_add_organizations", value: "true"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "originator", value: CodexOAuthConstants.originator),
    ]
    return components.url!
  }

  private func exchangeAuthorizationCode(code: String, verifier: String) async throws
    -> CodexAuthCredentials
  {
    var request = URLRequest(url: CodexOAuthConstants.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formBody([
      "grant_type": "authorization_code",
      "client_id": CodexOAuthConstants.clientID,
      "code": code,
      "code_verifier": verifier,
      "redirect_uri": CodexOAuthConstants.redirectURI,
    ])

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CodexUsageError.tokenExchangeFailed(nil)
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw CodexUsageError.tokenExchangeFailed(httpResponse.statusCode)
    }
    return try credentials(from: data, requiresExpiresIn: true)
  }

  private func credentials(from data: Data, requiresExpiresIn: Bool = true) throws
    -> CodexAuthCredentials
  {
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = root["access_token"] as? String,
      let refreshToken = root["refresh_token"] as? String
    else {
      throw CodexUsageError.invalidAuthFile(CodexOAuthConstants.tokenURL)
    }

    let expiresIn = root["expires_in"] as? NSNumber
    if requiresExpiresIn, expiresIn == nil {
      throw CodexUsageError.invalidAuthFile(CodexOAuthConstants.tokenURL)
    }

    let accountId = CodexAuthTokenParser.accountId(from: accessToken)
    return CodexAuthCredentials(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresIn.map { Date().addingTimeInterval($0.doubleValue) },
      accountId: accountId
    )
  }

  private func jsonBody(_ values: [String: String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: values)
  }

  private func interval(from value: Any?) -> TimeInterval {
    if let number = value as? NSNumber {
      return max(number.doubleValue, 1)
    }
    if let string = value as? String,
      let interval = TimeInterval(string.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return max(interval, 1)
    }
    return 5
  }

  private func formBody(_ values: [String: String]) -> Data {
    var components = URLComponents()
    components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    return Data((components.percentEncodedQuery ?? "").utf8)
  }
}

public enum CodexAuthTokenParser {
  private static let jwtClaimPath = "https://api.openai.com/auth"

  public static func accountId(from accessToken: String) -> String? {
    let parts = accessToken.split(separator: ".")
    guard parts.count == 3, let payloadData = base64URLDecode(String(parts[1])) else {
      return nil
    }
    guard
      let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
      let auth = root[jwtClaimPath] as? [String: Any],
      let accountId = auth["chatgpt_account_id"] as? String,
      !accountId.isEmpty
    else {
      return nil
    }
    return accountId
  }

  private static func base64URLDecode(_ value: String) -> Data? {
    var base64 =
      value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: padding)
    return Data(base64Encoded: base64)
  }
}

private final class CodexOAuthCallbackServer: @unchecked Sendable {
  private let state: String
  private let queue = DispatchQueue(label: "net.pardev.CodexMonitor.oauth-callback")
  private let listener: NWListener
  private let lock = NSLock()
  private var startContinuation: CheckedContinuation<Void, Error>?
  private var codeContinuation: CheckedContinuation<String, Error>?
  private var completedCode: String?
  private var completedError: Error?

  init(state: String) throws {
    self.state = state
    self.listener = try NWListener(using: .tcp, on: 1455)
  }

  func start() async throws {
    try await withCheckedThrowingContinuation { continuation in
      startContinuation = continuation
      listener.stateUpdateHandler = { [weak self] state in
        self?.handleListenerState(state)
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.handle(connection: connection)
      }
      listener.start(queue: queue)
    }
  }

  func waitForCode() async throws -> String {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let completedCode {
          lock.unlock()
          continuation.resume(returning: completedCode)
          return
        }
        if let completedError {
          lock.unlock()
          continuation.resume(throwing: completedError)
          return
        }
        codeContinuation = continuation
        lock.unlock()
      }
    } onCancel: {
      close()
    }
  }

  func close() {
    listener.cancel()
  }

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      startContinuation?.resume()
      startContinuation = nil
    case .failed(let error):
      startContinuation?.resume(
        throwing: CodexUsageError.oauthCallbackFailed(error.localizedDescription))
      startContinuation = nil
      complete(.failure(CodexUsageError.oauthCallbackFailed(error.localizedDescription)))
    case .cancelled:
      break
    default:
      break
    }
  }

  private func handle(connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, _, error in
      guard let self else {
        connection.cancel()
        return
      }
      if let error {
        self.send(
          error: "Could not read callback request.", statusCode: 500, connection: connection)
        self.complete(.failure(CodexUsageError.oauthCallbackFailed(error.localizedDescription)))
        return
      }
      guard let data, let request = String(data: data, encoding: .utf8) else {
        self.send(error: "Empty callback request.", statusCode: 400, connection: connection)
        self.complete(.failure(CodexUsageError.oauthCallbackFailed("empty callback request")))
        return
      }
      self.handle(request: request, connection: connection)
    }
  }

  private func handle(request: String, connection: NWConnection) {
    let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2 else {
      send(error: "Malformed callback request.", statusCode: 400, connection: connection)
      complete(.failure(CodexUsageError.oauthCallbackFailed("malformed callback request")))
      return
    }

    let path = String(parts[1])
    guard
      let components = URLComponents(string: "http://localhost\(path)"),
      components.path == "/auth/callback"
    else {
      send(error: "Callback route not found.", statusCode: 404, connection: connection)
      return
    }

    let params = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      })
    guard params["state"] == state else {
      send(error: "State mismatch.", statusCode: 400, connection: connection)
      complete(.failure(CodexUsageError.oauthCallbackFailed("state mismatch")))
      return
    }
    guard let code = params["code"], !code.isEmpty else {
      send(error: "Missing authorization code.", statusCode: 400, connection: connection)
      complete(.failure(CodexUsageError.oauthCallbackFailed("missing authorization code")))
      return
    }

    send(
      success: "OpenAI authentication completed. You can close this window.", connection: connection
    )
    complete(.success(code))
  }

  private func complete(_ result: Result<String, Error>) {
    lock.lock()
    let continuation = codeContinuation
    codeContinuation = nil
    switch result {
    case .success(let code):
      completedCode = code
    case .failure(let error):
      completedError = error
    }
    lock.unlock()

    close()
    switch result {
    case .success(let code):
      continuation?.resume(returning: code)
    case .failure(let error):
      continuation?.resume(throwing: error)
    }
  }

  private func send(success message: String, connection: NWConnection) {
    send(
      html: "<html><body><h1>Success</h1><p>\(message)</p></body></html>", statusCode: 200,
      connection: connection)
  }

  private func send(error message: String, statusCode: Int, connection: NWConnection) {
    send(
      html: "<html><body><h1>Authentication Failed</h1><p>\(message)</p></body></html>",
      statusCode: statusCode, connection: connection)
  }

  private func send(html: String, statusCode: Int, connection: NWConnection) {
    let reason = statusCode == 200 ? "OK" : "Error"
    let data = Data(html.utf8)
    let header = """
      HTTP/1.1 \(statusCode) \(reason)\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(data.count)\r
      Connection: close\r
      \r

      """
    var response = Data(header.utf8)
    response.append(data)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }
}

private func pkceChallenge(for verifier: String) -> String {
  let digest = SHA256.hash(data: Data(verifier.utf8))
  return base64URL(Data(digest))
}

private func randomBase64URL(byteCount: Int) throws -> String {
  try base64URL(randomData(byteCount: byteCount))
}

private func randomHex(byteCount: Int) throws -> String {
  try randomData(byteCount: byteCount)
    .map { String(format: "%02x", $0) }
    .joined()
}

private func randomData(byteCount: Int) throws -> Data {
  var bytes = [UInt8](repeating: 0, count: byteCount)
  let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
  guard status == errSecSuccess else {
    throw CodexUsageError.oauthCallbackFailed("could not generate secure random bytes")
  }
  return Data(bytes)
}

private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}
