import Foundation
import Security

#if os(macOS)
  import Darwin
#endif

public struct CodexUsageWindow: Codable, Equatable, Sendable {
  public var label: String
  public var remainingPercent: Double
  public var resetAt: Date?
  public var detail: String?
  public var valueText: String?

  public init(
    label: String,
    remainingPercent: Double,
    resetAt: Date?,
    detail: String? = nil,
    valueText: String? = nil
  ) {
    self.label = label
    self.remainingPercent = remainingPercent
    self.resetAt = resetAt
    self.detail = detail
    self.valueText = valueText
  }
}

public struct CodexUsageSnapshot: Codable, Equatable, Sendable {
  public var provider: String
  public var fetchedAt: Date
  public var fiveHour: CodexUsageWindow?
  public var weekly: CodexUsageWindow?

  public init(
    provider: String = "openai-codex", fetchedAt: Date, fiveHour: CodexUsageWindow?,
    weekly: CodexUsageWindow?
  ) {
    self.provider = provider
    self.fetchedAt = fetchedAt
    self.fiveHour = fiveHour
    self.weekly = weekly
  }

  public var displayName: String {
    CodexUsageProviderID(rawValue: provider)?.displayName ?? provider
  }
}

public enum CodexUsageProviderID: String, Codable, CaseIterable, Sendable {
  case openAICodex = "openai-codex"
  case openRouter = "openrouter"
  case claudeCode = "claude-code"

  public var displayName: String {
    switch self {
    case .openAICodex:
      return "Codex"
    case .openRouter:
      return "OpenRouter"
    case .claudeCode:
      return "Claude Code"
    }
  }

  public var beaconTitle: String {
    switch self {
    case .openAICodex:
      return "CODEX"
    case .openRouter:
      return "OPENROUTER"
    case .claudeCode:
      return "CLAUDE CODE"
    }
  }

  public var beaconSubtitle: String {
    switch self {
    case .openAICodex:
      return "USAGE"
    case .openRouter:
      return "CREDITS"
    case .claudeCode:
      return "LOCAL SESSIONS"
    }
  }

  public var beaconAccentColor: BeaconRGB {
    switch self {
    case .openAICodex:
      return BeaconRGB(red: 191, green: 90, blue: 242)
    case .openRouter:
      return BeaconRGB(red: 100, green: 103, blue: 242)
    case .claudeCode:
      return BeaconRGB(red: 255, green: 159, blue: 10)
    }
  }
}

public struct CodexAuthCredentials: Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date?
  public var accountId: String?
  public var baseURL: URL

  public init(
    accessToken: String,
    refreshToken: String? = nil,
    expiresAt: Date? = nil,
    accountId: String?,
    baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.accountId = accountId
    self.baseURL = baseURL
  }
}

public enum CodexUsageError: LocalizedError, Sendable {
  case missingCredentials
  case missingRefreshToken
  case invalidAuthFile(URL)
  case keychainFailed(String, OSStatus)
  case oauthCallbackFailed(String)
  case deviceCodeFailed(String)
  case tokenExchangeFailed(Int?)
  case tokenRefreshFailed(Int?)
  case invalidUsagePayload
  case invalidOpenRouterPayload
  case missingOpenRouterAPIKey
  case requestFailed(Int)

  public var errorDescription: String? {
    switch self {
    case .missingCredentials:
      return "No Codex access token was found. Sign in or set CODEX_MONITOR_ACCESS_TOKEN."
    case .missingRefreshToken:
      return "The Codex credentials do not include a refresh token. Sign in again."
    case .invalidAuthFile(let url):
      return "Could not parse Codex auth file at \(url.path)."
    case .keychainFailed(let operation, let status):
      return "Codex Monitor Keychain \(operation) failed with OSStatus \(status)."
    case .oauthCallbackFailed(let reason):
      return "Codex OAuth callback failed: \(reason)"
    case .deviceCodeFailed(let reason):
      return "Codex device-code login failed: \(reason)"
    case .tokenExchangeFailed(let statusCode):
      return "Codex OAuth token exchange failed\(Self.statusSuffix(statusCode))."
    case .tokenRefreshFailed(let statusCode):
      return "Codex OAuth token refresh failed\(Self.statusSuffix(statusCode))."
    case .invalidUsagePayload:
      return "Codex usage response did not contain rate_limit windows."
    case .invalidOpenRouterPayload:
      return "OpenRouter usage response did not contain credits or key usage."
    case .missingOpenRouterAPIKey:
      return "No OpenRouter API key was found. Add one in Settings."
    case .requestFailed(let statusCode):
      return "Usage request failed with HTTP \(statusCode)."
    }
  }

  private static func statusSuffix(_ statusCode: Int?) -> String {
    guard let statusCode else {
      return ""
    }
    return " with HTTP \(statusCode)"
  }
}

public protocol CodexSecureAuthStoring: Sendable {
  var storageDescription: String { get }

  func loadCredentials() throws -> CodexAuthCredentials?
  func save(credentials: CodexAuthCredentials) throws
  func clear() throws
}

public final class CodexKeychainAuthStore: CodexSecureAuthStoring, @unchecked Sendable {
  public static let service = "net.pardev.CodexMonitor.codex-auth"
  public static let account = "codex-oauth"
  public static let accessGroup = "QMLVG482FY.net.pardev.CodexMonitor"

  private let service: String
  private let account: String
  private let accessGroup: String

  public init(
    service: String = CodexKeychainAuthStore.service,
    account: String = CodexKeychainAuthStore.account,
    accessGroup: String = CodexKeychainAuthStore.accessGroup
  ) {
    self.service = service
    self.account = account
    self.accessGroup = accessGroup
  }

  public var storageDescription: String {
    "Keychain item \(service) / \(account)"
  }

  public func loadCredentials() throws -> CodexAuthCredentials? {
    var query = baseQuery()
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw CodexUsageError.keychainFailed("read", status)
    }
    guard let data = item as? Data else {
      throw CodexUsageError.keychainFailed("decode", errSecInternalComponent)
    }
    return try JSONDecoder.codexMonitor.decode(CodexAuthCredentialsPayload.self, from: data)
      .credentials
  }

  public func save(credentials: CodexAuthCredentials) throws {
    let data = try JSONEncoder.codexMonitor.encode(
      CodexAuthCredentialsPayload(credentials: credentials))
    let attributes: [String: Any] = [
      kSecValueData as String: data
    ]
    let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw CodexUsageError.keychainFailed("update", updateStatus)
    }

    var query = baseQuery()
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw CodexUsageError.keychainFailed("save", addStatus)
    }
  }

  public func clear() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CodexUsageError.keychainFailed("clear", status)
    }
  }

  private func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if !accessGroup.isEmpty {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }
}

public final class OpenRouterAPIKeyStore: @unchecked Sendable {
  public static let service = "net.pardev.CodexMonitor.openrouter-api-key"
  public static let account = "openrouter-api-key"
  public static let accessGroup = CodexKeychainAuthStore.accessGroup

  private let environment: [String: String]
  private let service: String
  private let account: String
  private let accessGroup: String

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    service: String = OpenRouterAPIKeyStore.service,
    account: String = OpenRouterAPIKeyStore.account,
    accessGroup: String = OpenRouterAPIKeyStore.accessGroup
  ) {
    self.environment = environment
    self.service = service
    self.account = account
    self.accessGroup = accessGroup
  }

  public var storageDescription: String {
    "Keychain item \(service) / \(account)"
  }

  public func hasAPIKey() -> Bool {
    (try? loadAPIKey()) != nil
  }

  public func loadAPIKey() throws -> String {
    if let key = nonEmpty(environment["OPENROUTER_API_KEY"]) {
      return key
    }

    var query = baseQuery()
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      throw CodexUsageError.missingOpenRouterAPIKey
    }
    guard status == errSecSuccess else {
      throw CodexUsageError.keychainFailed("read OpenRouter key", status)
    }
    guard let data = item as? Data, let key = String(data: data, encoding: .utf8),
      let trimmed = nonEmpty(key)
    else {
      throw CodexUsageError.keychainFailed("decode OpenRouter key", errSecInternalComponent)
    }
    return trimmed
  }

  public func save(apiKey: String) throws {
    guard let trimmed = nonEmpty(apiKey) else {
      try clear()
      return
    }
    let data = Data(trimmed.utf8)
    let attributes: [String: Any] = [
      kSecValueData as String: data
    ]
    let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw CodexUsageError.keychainFailed("update OpenRouter key", updateStatus)
    }

    var query = baseQuery()
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw CodexUsageError.keychainFailed("save OpenRouter key", addStatus)
    }
  }

  public func clear() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CodexUsageError.keychainFailed("clear OpenRouter key", status)
    }
  }

  private func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if !accessGroup.isEmpty {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}

public final class BeaconAPIKeyStore: @unchecked Sendable {
  public static let service = "net.pardev.CodexMonitor.beacon-api"
  public static let account = "beacon-api-key"
  public static let accessGroup = CodexKeychainAuthStore.accessGroup

  private let service: String
  private let account: String
  private let accessGroup: String

  public init(
    service: String = BeaconAPIKeyStore.service,
    account: String = BeaconAPIKeyStore.account,
    accessGroup: String = BeaconAPIKeyStore.accessGroup
  ) {
    self.service = service
    self.account = account
    self.accessGroup = accessGroup
  }

  public func currentOrCreateAPIKey() throws -> String {
    if let existing = try? loadAPIKey(), !existing.isEmpty {
      return existing
    }
    let key = Self.generateAPIKey()
    try save(apiKey: key)
    return key
  }

  public func validate(apiKey: String) -> Bool {
    guard let stored = try? loadAPIKey() else {
      return false
    }
    return stored == apiKey
  }

  public func loadAPIKey() throws -> String {
    var query = baseQuery()
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      throw CodexUsageError.keychainFailed("read Beacon API key", status)
    }
    guard status == errSecSuccess else {
      throw CodexUsageError.keychainFailed("read Beacon API key", status)
    }
    guard let data = item as? Data, let key = String(data: data, encoding: .utf8),
      !key.isEmpty
    else {
      throw CodexUsageError.keychainFailed("decode Beacon API key", errSecInternalComponent)
    }
    return key
  }

  public func save(apiKey: String) throws {
    let data = Data(apiKey.utf8)
    let attributes: [String: Any] = [
      kSecValueData as String: data
    ]
    let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw CodexUsageError.keychainFailed("update Beacon API key", updateStatus)
    }

    var query = baseQuery()
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw CodexUsageError.keychainFailed("save Beacon API key", addStatus)
    }
  }

  public func clear() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CodexUsageError.keychainFailed("clear Beacon API key", status)
    }
  }

  public static func generateAPIKey() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
    }
    return Data(bytes).base64EncodedString()
  }

  private func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if !accessGroup.isEmpty {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }
}

private struct CodexAuthCredentialsPayload: Codable {
  var accessToken: String
  var refreshToken: String?
  var expiresAt: Date?
  var accountId: String?
  var baseURL: URL

  init(credentials: CodexAuthCredentials) {
    self.accessToken = credentials.accessToken
    self.refreshToken = credentials.refreshToken
    self.expiresAt = credentials.expiresAt
    self.accountId = credentials.accountId
    self.baseURL = credentials.baseURL
  }

  var credentials: CodexAuthCredentials {
    CodexAuthCredentials(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      accountId: accountId,
      baseURL: baseURL
    )
  }
}

public enum CodexMonitorStorage {
  public static let appGroupIdentifier = "group.net.pardev.CodexMonitor"

  public static func supportDirectory(fileManager: FileManager = .default) -> URL {
    if let groupURL = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    {
      return groupURL.appendingPathComponent("CodexMonitor", isDirectory: true)
    }
    return legacySupportDirectory(fileManager: fileManager)
  }

  public static func legacySupportDirectory(fileManager: FileManager = .default) -> URL {
    #if os(iOS)
      let baseURL =
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      return baseURL.appendingPathComponent("CodexMonitor", isDirectory: true)
    #else
      fileManager
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexMonitor", isDirectory: true)
    #endif
  }
}

public final class CodexAuthStore: @unchecked Sendable {
  private let environment: [String: String]
  private let fileManager: FileManager
  private let secureStore: CodexSecureAuthStoring
  private let legacyMonitorAuthFileURLs: [URL]?
  private let urlSession: URLSession

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    secureStore: CodexSecureAuthStoring? = nil,
    legacyMonitorAuthFileURLs: [URL]? = nil,
    urlSession: URLSession? = nil
  ) {
    self.environment = environment
    self.fileManager = fileManager
    self.secureStore = secureStore ?? CodexKeychainAuthStore()
    self.legacyMonitorAuthFileURLs = legacyMonitorAuthFileURLs
    self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
  }

  public func loadCredentials(forceRefresh: Bool = false) async throws -> CodexAuthCredentials {
    let credentials = try loadStoredCredentials()
    guard shouldRefresh(credentials, forceRefresh: forceRefresh) else {
      return credentials
    }
    return try await refresh(credentials: credentials)
  }

  public func hasCredentials() -> Bool {
    (try? loadStoredCredentials()) != nil
  }

  public func login(openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void)
    async throws -> CodexAuthCredentials
  {
    let credentials = try await CodexOAuthService(urlSession: urlSession).login(
      openAuthorizationURL: openAuthorizationURL)
    try secureStore.save(credentials: credentials)
    try removeLegacyMonitorCredentials()
    return credentials
  }

  public func loginWithDeviceCode(
    openVerificationURL: @escaping @Sendable (URL) async throws -> Void,
    onCode: @escaping @Sendable (CodexDeviceCodeLogin) async -> Void
  ) async throws -> CodexAuthCredentials {
    let credentials = try await CodexOAuthService(urlSession: urlSession).loginWithDeviceCode(
      openVerificationURL: openVerificationURL,
      onCode: onCode
    )
    try secureStore.save(credentials: credentials)
    try removeLegacyMonitorCredentials()
    return credentials
  }

  public func beginDeviceCodeLogin() async throws -> CodexDeviceCodeLogin {
    try await CodexOAuthService(urlSession: urlSession).beginDeviceCodeLogin()
  }

  public func completeDeviceCodeLogin(_ login: CodexDeviceCodeLogin) async throws
    -> CodexAuthCredentials
  {
    let credentials = try await CodexOAuthService(urlSession: urlSession).completeDeviceCodeLogin(
      login)
    try secureStore.save(credentials: credentials)
    try removeLegacyMonitorCredentials()
    return credentials
  }

  public func clearMonitorCredentials() throws {
    try secureStore.clear()
    try removeLegacyMonitorCredentials()
  }

  public var authStorageDescription: String {
    secureStore.storageDescription
  }

  private func loadStoredCredentials() throws -> CodexAuthCredentials {
    if let credentials = credentialsFromEnvironment() {
      return credentials
    }

    if let credentials = try secureStore.loadCredentials() {
      return credentials
    }

    if let credentials = try migrateLegacyMonitorCredentials() {
      return credentials
    }

    throw CodexUsageError.missingCredentials
  }

  private func credentialsFromEnvironment() -> CodexAuthCredentials? {
    guard
      let token = nonEmpty(
        environment["CODEX_MONITOR_ACCESS_TOKEN"] ?? environment["CODEX_ACCESS_TOKEN"])
    else {
      return nil
    }
    return CodexAuthCredentials(
      accessToken: token,
      refreshToken: nonEmpty(
        environment["CODEX_MONITOR_REFRESH_TOKEN"] ?? environment["CODEX_REFRESH_TOKEN"]),
      expiresAt: expiresAt(environment["CODEX_MONITOR_EXPIRES"] ?? environment["CODEX_EXPIRES"]),
      accountId: nonEmpty(
        environment["CODEX_MONITOR_ACCOUNT_ID"] ?? environment["CODEX_ACCOUNT_ID"]),
      baseURL: URL(
        string: nonEmpty(environment["CODEX_MONITOR_BASE_URL"]) ?? "https://chatgpt.com/backend-api"
      )!
    )
  }

  private func legacyMonitorAuthFileCandidates() -> [URL] {
    legacyMonitorAuthFileURLs ?? [ownAuthFileURL(), legacyOwnAuthFileURL()]
  }

  private func ownAuthFileURL() -> URL {
    CodexMonitorStorage
      .supportDirectory(fileManager: fileManager)
      .appendingPathComponent("auth.json")
  }

  private func legacyOwnAuthFileURL() -> URL {
    CodexMonitorStorage
      .legacySupportDirectory(fileManager: fileManager)
      .appendingPathComponent("auth.json")
  }

  private func credentialsFromLegacyMonitorAuth(_ root: [String: Any]) -> CodexAuthCredentials? {
    guard
      let provider = root["openai-codex"] as? [String: Any],
      let token = nonEmpty(provider["access"] as? String)
    else {
      return nil
    }
    return CodexAuthCredentials(
      accessToken: token,
      refreshToken: nonEmpty(provider["refresh"] as? String),
      expiresAt: expiresAt(provider["expires"]),
      accountId: nonEmpty(provider["accountId"] as? String)
    )
  }

  private func shouldRefresh(_ credentials: CodexAuthCredentials, forceRefresh: Bool) -> Bool {
    if forceRefresh {
      return true
    }
    guard let expiresAt = credentials.expiresAt else {
      return false
    }
    return expiresAt <= Date().addingTimeInterval(60)
  }

  private func refresh(credentials: CodexAuthCredentials) async throws -> CodexAuthCredentials {
    guard let refreshToken = credentials.refreshToken else {
      throw CodexUsageError.missingRefreshToken
    }
    var refreshed = try await CodexOAuthService(urlSession: urlSession).refresh(
      refreshToken: refreshToken)
    refreshed.baseURL = credentials.baseURL
    try secureStore.save(credentials: refreshed)
    try removeLegacyMonitorCredentials()
    return refreshed
  }

  private func migrateLegacyMonitorCredentials() throws -> CodexAuthCredentials? {
    for url in legacyMonitorAuthFileCandidates() {
      guard fileManager.fileExists(atPath: url.path) else { continue }
      let data = try Data(contentsOf: url)
      guard
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let credentials = credentialsFromLegacyMonitorAuth(root)
      else {
        throw CodexUsageError.invalidAuthFile(url)
      }
      try secureStore.save(credentials: credentials)
      try removeLegacyMonitorCredentials()
      return credentials
    }
    return nil
  }

  private func removeLegacyMonitorCredentials() throws {
    for url in legacyMonitorAuthFileCandidates() {
      guard fileManager.fileExists(atPath: url.path) else { continue }
      try fileManager.removeItem(at: url)
    }
  }

  private func expiresAt(_ value: Any?) -> Date? {
    if let number = value as? NSNumber {
      return expiresAt(number.doubleValue)
    }
    if let string = value as? String,
      let numeric = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return expiresAt(numeric)
    }
    return nil
  }

  private func expiresAt(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value < 1_000_000_000_000 ? value : value / 1000)
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }
}

public final class CodexUsageClient: @unchecked Sendable {
  private let urlSession: URLSession

  public convenience init(timeout: TimeInterval = 15) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    self.init(urlSession: URLSession(configuration: configuration))
  }

  public init(urlSession: URLSession) {
    self.urlSession = urlSession
  }

  public func fetchUsage(credentials: CodexAuthCredentials) async throws -> CodexUsageSnapshot {
    var request = URLRequest(url: usageURL(for: credentials.baseURL))
    request.timeoutInterval = 15
    request.httpMethod = "GET"
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("codex-monitor", forHTTPHeaderField: "User-Agent")
    if let accountId = credentials.accountId {
      request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    let (data, response) = try await urlSession.data(for: request)
    if let httpResponse = response as? HTTPURLResponse,
      !(200..<300).contains(httpResponse.statusCode)
    {
      throw CodexUsageError.requestFailed(httpResponse.statusCode)
    }
    guard let snapshot = CodexUsageParser.parse(data: data) else {
      throw CodexUsageError.invalidUsagePayload
    }
    return snapshot
  }

  public func fetchUsage(authStore: CodexAuthStore) async throws -> CodexUsageSnapshot {
    do {
      return try await fetchUsage(credentials: authStore.loadCredentials())
    } catch CodexUsageError.requestFailed(401) {
      return try await fetchUsage(credentials: authStore.loadCredentials(forceRefresh: true))
    }
  }

  private func usageURL(for baseURL: URL) -> URL {
    var normalized = baseURL.absoluteString
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    if normalized.hasPrefix("https://chatgpt.com")
      || normalized.hasPrefix("https://chat.openai.com"),
      !normalized.contains("/backend-api")
    {
      normalized += "/backend-api"
    }
    let suffix = normalized.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
    return URL(string: normalized + suffix)!
  }
}

public final class OpenRouterUsageClient: @unchecked Sendable {
  private let baseURL: URL
  private let urlSession: URLSession

  public convenience init(timeout: TimeInterval = 15) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    self.init(urlSession: URLSession(configuration: configuration))
  }

  public init(
    baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
    urlSession: URLSession
  ) {
    self.baseURL = baseURL
    self.urlSession = urlSession
  }

  public func fetchUsage(apiKey: String) async throws -> CodexUsageSnapshot {
    async let keyData = fetch(path: "key", apiKey: apiKey)
    async let creditsData = fetch(path: "credits", apiKey: apiKey)
    return try await OpenRouterUsageParser.parse(keyData: keyData, creditsData: creditsData)
  }

  public func fetchUsage(apiKeyStore: OpenRouterAPIKeyStore) async throws -> CodexUsageSnapshot {
    try await fetchUsage(apiKey: apiKeyStore.loadAPIKey())
  }

  private func fetch(path: String, apiKey: String) async throws -> Data {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.timeoutInterval = 15
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("codex-monitor", forHTTPHeaderField: "User-Agent")
    request.setValue("Codex Monitor", forHTTPHeaderField: "X-Title")

    let (data, response) = try await urlSession.data(for: request)
    if let httpResponse = response as? HTTPURLResponse,
      !(200..<300).contains(httpResponse.statusCode)
    {
      throw CodexUsageError.requestFailed(httpResponse.statusCode)
    }
    return data
  }
}

public enum OpenRouterUsageParser {
  public static func parse(keyData: Data, creditsData: Data, fetchedAt: Date = Date()) throws
    -> CodexUsageSnapshot
  {
    let keyWindow = parseKeyWindow(data: keyData)
    let creditsWindow = parseCreditsWindow(data: creditsData)
    guard keyWindow != nil || creditsWindow != nil else {
      throw CodexUsageError.invalidOpenRouterPayload
    }
    return CodexUsageSnapshot(
      provider: CodexUsageProviderID.openRouter.rawValue,
      fetchedAt: fetchedAt,
      fiveHour: keyWindow,
      weekly: creditsWindow
    )
  }

  private static func parseKeyWindow(data: Data) -> CodexUsageWindow? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let record = root["data"] as? [String: Any]
    else {
      return nil
    }

    let usage = number(record["usage"]) ?? 0
    let daily = number(record["usage_daily"]) ?? 0
    let weekly = number(record["usage_weekly"]) ?? 0
    let monthly = number(record["usage_monthly"]) ?? 0
    let isFreeTier = (record["is_free_tier"] as? Bool) == true

    if let limit = number(record["limit"]), let remaining = number(record["limit_remaining"]),
      limit > 0
    {
      let used = max(0, limit - remaining)
      let reset = nonEmpty(record["limit_reset"] as? String)
      var detail = "\(currency(remaining)) of \(currency(limit)) left"
      detail += " • \(currency(daily)) today"
      if let reset, reset != "never" {
        detail += " • resets \(reset)"
      }
      return CodexUsageWindow(
        label: "Key limit",
        remainingPercent: clamp((remaining / limit) * 100),
        resetAt: nil,
        detail: detail + " • \(currency(used)) used"
      )
    }

    let tier = isFreeTier ? "free tier" : "unlimited key"
    return CodexUsageWindow(
      label: "Key usage",
      remainingPercent: 100,
      resetAt: nil,
      detail:
        "\(tier) • \(currency(daily)) today • \(currency(weekly)) week • \(currency(monthly)) month • \(currency(usage)) all time"
    )
  }

  private static func parseCreditsWindow(data: Data) -> CodexUsageWindow? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let record = root["data"] as? [String: Any],
      let totalCredits = number(record["total_credits"]),
      let totalUsage = number(record["total_usage"])
    else {
      return nil
    }

    let balance = totalCredits - totalUsage
    let percent = totalCredits > 0 ? clamp((balance / totalCredits) * 100) : 0
    return CodexUsageWindow(
      label: "Credits",
      remainingPercent: percent,
      resetAt: nil,
      detail: "\(currency(balance)) balance • \(currency(totalUsage)) used"
    )
  }

  private static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let string = value as? String {
      return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func currency(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = abs(value) < 10 ? 2 : 0
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
  }

  private static func clamp(_ value: Double) -> Double {
    min(100, max(0, value))
  }
}

public struct ClaudeCodeUsageTotals: Equatable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheCreationTokens: Int
  public var cacheReadTokens: Int
  public var assistantTurns: Int
  public var latestAt: Date?
  public var resetAt: Date?

  public init(
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheCreationTokens: Int = 0,
    cacheReadTokens: Int = 0,
    assistantTurns: Int = 0,
    latestAt: Date? = nil,
    resetAt: Date? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.cacheReadTokens = cacheReadTokens
    self.assistantTurns = assistantTurns
    self.latestAt = latestAt
    self.resetAt = resetAt
  }

  public var totalTokens: Int {
    inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
  }

  public mutating func add(_ other: ClaudeCodeUsageTotals) {
    inputTokens += other.inputTokens
    outputTokens += other.outputTokens
    cacheCreationTokens += other.cacheCreationTokens
    cacheReadTokens += other.cacheReadTokens
    assistantTurns += other.assistantTurns
    if let otherLatest = other.latestAt, latestAt.map({ otherLatest > $0 }) ?? true {
      latestAt = otherLatest
    }
    if resetAt == nil {
      resetAt = other.resetAt
    }
  }
}

public final class ClaudeCodeUsageClient: @unchecked Sendable {
  private let fileManager: FileManager
  private let projectsDirectory: URL
  private let maxFiles: Int
  private let tailBytes: UInt64

  public init(
    fileManager: FileManager = .default,
    projectsDirectory: URL? = nil,
    maxFiles: Int = 12,
    tailBytes: UInt64 = 2_000_000
  ) {
    self.fileManager = fileManager
    self.projectsDirectory = projectsDirectory ?? Self.defaultProjectsDirectory(fileManager: fileManager)
    self.maxFiles = maxFiles
    self.tailBytes = tailBytes
  }

  public static func defaultProjectsDirectory(fileManager: FileManager = .default) -> URL {
    #if os(iOS)
      let baseURL =
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      return baseURL.appendingPathComponent(".claude/projects", isDirectory: true)
    #elseif os(macOS)
      return Self.realUserHomeDirectory()
        .appendingPathComponent(".claude/projects", isDirectory: true)
    #else
      return fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    #endif
  }

  #if os(macOS)
    private static func realUserHomeDirectory() -> URL {
      if let passwd = getpwuid(getuid()), let homeDirectory = passwd.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: homeDirectory), isDirectory: true)
      }
      return URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
    }
  #endif

  public func fetchUsage(now: Date = Date()) throws -> CodexUsageSnapshot {
    let files = try latestSessionFiles()
    if files.isEmpty {
      return statusSnapshot(
        now: now,
        detail: "No Claude Code JSONL sessions were found under \(projectsDirectory.path)."
      )
    }
    var fiveHour = ClaudeCodeUsageTotals()
    var sevenDay = ClaudeCodeUsageTotals()
    let fiveHourStart = now.addingTimeInterval(-5 * 60 * 60)
    let sevenDayStart = now.addingTimeInterval(-7 * 24 * 60 * 60)

    for file in files {
      let records = try usageRecords(in: file)
      for record in records {
        guard let timestamp = record.latestAt else {
          continue
        }
        if timestamp >= sevenDayStart {
          sevenDay.add(record)
        }
        if timestamp >= fiveHourStart {
          fiveHour.add(record)
        }
      }
    }

    guard sevenDay.assistantTurns > 0 || fiveHour.assistantTurns > 0 else {
      return statusSnapshot(
        now: now,
        detail: "No Claude Code usage records were found in recent JSONL tails."
      )
    }

    let resetDetail =
      sevenDay.resetAt == nil
      ? "Reset metadata was not present in recent JSONL tails" : nil
    return CodexUsageSnapshot(
      provider: CodexUsageProviderID.claudeCode.rawValue,
      fetchedAt: now,
      fiveHour: window(label: "5h tokens", totals: fiveHour, fallbackDetail: resetDetail),
      weekly: window(label: "7d tokens", totals: sevenDay, fallbackDetail: resetDetail)
    )
  }

  private func latestSessionFiles() throws -> [URL] {
    var projectsPathIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: projectsDirectory.path, isDirectory: &projectsPathIsDirectory),
      projectsPathIsDirectory.boolValue
    else {
      return []
    }

    let projectDirectoryURLs: [URL]
    do {
      projectDirectoryURLs = try fileManager.contentsOfDirectory(
        at: projectsDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      return []
    }
    let projectDirectories = projectDirectoryURLs
      .filter { isDirectory($0) }
      .sorted { modificationDate($0) > modificationDate($1) }

    var files: [URL] = []
    for directory in projectDirectories {
      let sessionFiles = jsonlFiles(in: directory)
      files.append(contentsOf: sessionFiles.prefix(max(1, maxFiles - files.count)))
      if files.count >= maxFiles {
        break
      }
    }
    return Array(files.prefix(maxFiles))
  }

  private func jsonlFiles(in directory: URL) -> [URL] {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    var files: [URL] = []
    for case let file as URL in enumerator {
      guard file.pathExtension == "jsonl" else {
        continue
      }
      let values = try? file.resourceValues(forKeys: keys)
      if values?.isRegularFile == true {
        files.append(file)
      }
    }
    return files.sorted { modificationDate($0) > modificationDate($1) }
  }

  private func statusSnapshot(now: Date, detail: String) -> CodexUsageSnapshot {
    let window = CodexUsageWindow(
      label: "7d tokens",
      remainingPercent: 100,
      resetAt: nil,
      detail: detail,
      valueText: "0"
    )
    return CodexUsageSnapshot(
      provider: CodexUsageProviderID.claudeCode.rawValue,
      fetchedAt: now,
      fiveHour: nil,
      weekly: window
    )
  }

  private func usageRecords(in file: URL) throws -> [ClaudeCodeUsageTotals] {
    let text = try tailText(from: file)
    var records: [ClaudeCodeUsageTotals] = []
    var seen = Set<String>()
    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        continue
      }
      if let uuid = root["uuid"] as? String, !seen.insert(uuid).inserted {
        continue
      }
      if let record = usageRecord(from: root) {
        records.append(record)
      }
    }
    return records
  }

  private func usageRecord(from root: [String: Any]) -> ClaudeCodeUsageTotals? {
    guard
      root["type"] as? String == "assistant",
      (root["isApiErrorMessage"] as? Bool) != true,
      let message = root["message"] as? [String: Any],
      let usage = message["usage"] as? [String: Any]
    else {
      return nil
    }

    let totals = ClaudeCodeUsageTotals(
      inputTokens: int(usage["input_tokens"]),
      outputTokens: int(usage["output_tokens"]),
      cacheCreationTokens: int(usage["cache_creation_input_tokens"]),
      cacheReadTokens: int(usage["cache_read_input_tokens"]),
      assistantTurns: 1,
      latestAt: timestamp(root["timestamp"]),
      resetAt: resetDate(in: root)
    )
    return totals.totalTokens > 0 ? totals : nil
  }

  private func tailText(from file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer {
      try? handle.close()
    }
    let size = try handle.seekToEnd()
    let offset = size > tailBytes ? size - tailBytes : 0
    try handle.seek(toOffset: offset)
    let data = try handle.readToEnd() ?? Data()
    var text = String(decoding: data, as: UTF8.self)
    if offset > 0, let firstNewline = text.firstIndex(where: \.isNewline) {
      text = String(text[text.index(after: firstNewline)...])
    }
    return text
  }

  private func window(label: String, totals: ClaudeCodeUsageTotals, fallbackDetail: String?)
    -> CodexUsageWindow?
  {
    guard totals.assistantTurns > 0 else {
      return nil
    }
    let detail =
      "\(totals.assistantTurns) responses • \(formatTokens(totals.inputTokens)) in • \(formatTokens(totals.outputTokens)) out • \(formatTokens(totals.cacheCreationTokens + totals.cacheReadTokens)) cache"
    return CodexUsageWindow(
      label: label,
      remainingPercent: 100,
      resetAt: totals.resetAt,
      detail: [detail, fallbackDetail].compactMap { $0 }.joined(separator: " • "),
      valueText: formatTokens(totals.totalTokens)
    )
  }

  private func resetDate(in root: [String: Any]) -> Date? {
    guard let error = root["error"] as? [String: Any],
      let rateLimits = error["rateLimits"] as? [String: Any]
    else {
      return nil
    }
    return firstTimestamp(in: rateLimits)
  }

  private func firstTimestamp(in value: Any) -> Date? {
    if let date = timestamp(value) {
      return date
    }
    if let dictionary = value as? [String: Any] {
      for key in ["resetAt", "reset_at", "resetsAt", "resets_at", "retryAfter", "retry_after"] {
        if let date = timestamp(dictionary[key]) {
          return date
        }
      }
      for child in dictionary.values {
        if let date = firstTimestamp(in: child) {
          return date
        }
      }
    }
    if let array = value as? [Any] {
      for child in array {
        if let date = firstTimestamp(in: child) {
          return date
        }
      }
    }
    return nil
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private func modificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  private func timestamp(_ value: Any?) -> Date? {
    if let string = value as? String {
      let formatter = ISO8601DateFormatter()
      if let date = formatter.date(from: string) {
        return date
      }
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.date(from: string)
    }
    if let number = value as? NSNumber {
      return Date(timeIntervalSince1970: number.doubleValue > 1_000_000_000_000 ? number.doubleValue / 1000 : number.doubleValue)
    }
    return nil
  }

  private func int(_ value: Any?) -> Int {
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = value as? String {
      return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    return 0
  }

  private func formatTokens(_ value: Int) -> String {
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
  }
}

public final class UsageProviderClient: @unchecked Sendable {
  private let codexClient: CodexUsageClient
  private let openRouterClient: OpenRouterUsageClient
  private let claudeCodeClient: ClaudeCodeUsageClient

  public init(
    codexClient: CodexUsageClient = CodexUsageClient(),
    openRouterClient: OpenRouterUsageClient = OpenRouterUsageClient(),
    claudeCodeClient: ClaudeCodeUsageClient = ClaudeCodeUsageClient()
  ) {
    self.codexClient = codexClient
    self.openRouterClient = openRouterClient
    self.claudeCodeClient = claudeCodeClient
  }

  public func fetchUsage(
    settings: CodexMonitorSettings,
    codexAuthStore: CodexAuthStore,
    openRouterAPIKeyStore: OpenRouterAPIKeyStore
  ) async throws -> [CodexUsageSnapshot] {
    var snapshots: [CodexUsageSnapshot] = []
    for provider in settings.enabledProviders {
      switch provider {
      case .openAICodex:
        snapshots.append(try await codexClient.fetchUsage(authStore: codexAuthStore))
      case .openRouter:
        snapshots.append(try await openRouterClient.fetchUsage(apiKeyStore: openRouterAPIKeyStore))
      case .claudeCode:
        snapshots.append(try claudeCodeClient.fetchUsage())
      }
    }
    guard !snapshots.isEmpty else {
      throw CodexUsageError.invalidUsagePayload
    }
    return snapshots
  }
}

public enum CodexUsageParser {
  public static func parse(data: Data, fetchedAt: Date = Date()) -> CodexUsageSnapshot? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rateLimit = root["rate_limit"] as? [String: Any]
    else {
      return nil
    }

    let fiveHour = parseWindow(label: "5h", value: rateLimit["primary_window"])
    let weekly = parseWindow(label: "wk", value: rateLimit["secondary_window"])
    guard fiveHour != nil || weekly != nil else {
      return nil
    }
    return CodexUsageSnapshot(fetchedAt: fetchedAt, fiveHour: fiveHour, weekly: weekly)
  }

  private static func parseWindow(label: String, value: Any?) -> CodexUsageWindow? {
    guard let record = value as? [String: Any], let usedPercent = number(record["used_percent"])
    else {
      return nil
    }
    return CodexUsageWindow(
      label: label,
      remainingPercent: clamp(100 - usedPercent),
      resetAt: resetDate(in: record)
    )
  }

  private static func resetDate(in record: [String: Any]) -> Date? {
    for key in [
      "resets_at", "reset_at", "resetsAt", "resetAt", "nextResetTime", "next_reset_time",
      "resetTime", "reset_time",
    ] {
      if let date = timestamp(record[key]) {
        return date
      }
    }
    return nil
  }

  private static func timestamp(_ value: Any?) -> Date? {
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return nil
      }
      if let numeric = Double(trimmed) {
        return timestamp(numeric)
      }
      return ISO8601DateFormatter().date(from: trimmed)
    }
    guard let numeric = number(value), numeric > 0 else {
      return nil
    }
    return timestamp(numeric)
  }

  private static func timestamp(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value < 1_000_000_000_000 ? value : value / 1000)
  }

  private static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let double = value as? Double {
      return double
    }
    if let int = value as? Int {
      return Double(int)
    }
    if let string = value as? String {
      return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func clamp(_ value: Double) -> Double {
    min(100, max(0, value))
  }
}

public enum CodexResetText {
  public static func string(resetAt: Date, now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE h:mm a"
    return "Resets \(formatter.string(from: resetAt)) (\(remainingText(until: resetAt, now: now)))"
  }

  public static func remainingText(until resetAt: Date, now: Date = Date()) -> String {
    let seconds = Int(resetAt.timeIntervalSince(now).rounded(.up))
    guard seconds > 0 else {
      return "now"
    }
    if seconds < 60 {
      return "in <1m"
    }

    let minutes = seconds / 60
    let days = minutes / (24 * 60)
    let hours = (minutes % (24 * 60)) / 60
    let remainingMinutes = minutes % 60

    if days > 0 {
      return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
    }
    if hours > 0 {
      return remainingMinutes > 0 ? "in \(hours)h \(remainingMinutes)m" : "in \(hours)h"
    }
    return "in \(remainingMinutes)m"
  }
}

public enum CodexRefreshText {
  public static func remainingText(until refreshAt: Date, now: Date = Date()) -> String {
    let seconds = Int(refreshAt.timeIntervalSince(now).rounded(.up))
    guard seconds > 0 else {
      return "now"
    }
    if seconds < 60 {
      return "in \(seconds)s"
    }

    let totalMinutes = max(1, Int(ceil(Double(seconds) / 60)))
    let hours = totalMinutes / 60
    let remainingMinutes = totalMinutes % 60

    if hours > 0 {
      return remainingMinutes > 0 ? "in \(hours)h \(remainingMinutes)m" : "in \(hours)h"
    }
    return "in \(remainingMinutes)m"
  }
}

public final class CodexUsageCache: @unchecked Sendable {
  private let fileManager: FileManager
  public let cacheURL: URL

  public init(fileManager: FileManager = .default, cacheURL: URL? = nil) {
    self.fileManager = fileManager
    self.cacheURL = cacheURL ?? Self.defaultCacheURL(fileManager: fileManager)
  }

  public func loadSnapshot() throws -> CodexUsageSnapshot? {
    try loadSnapshots().first
  }

  public func loadSnapshots() throws -> [CodexUsageSnapshot] {
    guard fileManager.fileExists(atPath: cacheURL.path) else {
      return []
    }
    let data = try Data(contentsOf: cacheURL)
    if let snapshots = try? JSONDecoder.codexMonitor.decode([CodexUsageSnapshot].self, from: data) {
      return snapshots
    }
    return [try JSONDecoder.codexMonitor.decode(CodexUsageSnapshot.self, from: data)]
  }

  public func save(snapshot: CodexUsageSnapshot) throws {
    try save(snapshots: [snapshot])
  }

  public func save(snapshots: [CodexUsageSnapshot]) throws {
    try fileManager.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder.codexMonitor.encode(snapshots)
    try data.write(to: cacheURL, options: [.atomic])
  }

  public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_MONITOR_CACHE_PATH"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
    }
    return
      CodexMonitorStorage
      .supportDirectory(fileManager: fileManager)
      .appendingPathComponent("usage.json")
  }
}

public struct CodexMonitorSettings: Codable, Equatable, Sendable {
  public static let defaultRefreshIntervalMinutes = 15
  public static let allowedRefreshIntervalMinutes = [5, 15, 30, 60]
  public static let defaultBeaconAPIPort = 8765

  public var refreshIntervalMinutes: Int
  public var enabledProviders: [CodexUsageProviderID]
  public var beaconAPIEnabled: Bool
  public var beaconAPIPort: Int
  public var beaconProviderColors: [String: BeaconRGB]

  public init(
    refreshIntervalMinutes: Int = Self.defaultRefreshIntervalMinutes,
    enabledProviders: [CodexUsageProviderID] = [.openAICodex],
    beaconAPIEnabled: Bool = false,
    beaconAPIPort: Int = Self.defaultBeaconAPIPort,
    beaconProviderColors: [String: BeaconRGB] = [:]
  ) {
    self.refreshIntervalMinutes = Self.normalizedRefreshIntervalMinutes(refreshIntervalMinutes)
    self.enabledProviders = Self.normalizedEnabledProviders(enabledProviders)
    self.beaconAPIEnabled = beaconAPIEnabled
    self.beaconAPIPort = Self.normalizedBeaconAPIPort(beaconAPIPort)
    self.beaconProviderColors = Self.normalizedBeaconProviderColors(beaconProviderColors)
  }

  private enum CodingKeys: String, CodingKey {
    case refreshIntervalMinutes
    case enabledProviders
    case beaconAPIEnabled
    case beaconAPIPort
    case beaconProviderColors
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let refreshIntervalMinutes =
      try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
      ?? Self.defaultRefreshIntervalMinutes
    let enabledProviders =
      try container.decodeIfPresent([CodexUsageProviderID].self, forKey: .enabledProviders)
      ?? [.openAICodex]
    let beaconAPIEnabled = try container.decodeIfPresent(Bool.self, forKey: .beaconAPIEnabled) ?? false
    let beaconAPIPort =
      try container.decodeIfPresent(Int.self, forKey: .beaconAPIPort) ?? Self.defaultBeaconAPIPort
    let beaconProviderColors =
      try container.decodeIfPresent([String: BeaconRGB].self, forKey: .beaconProviderColors) ?? [:]
    self.init(
      refreshIntervalMinutes: refreshIntervalMinutes,
      enabledProviders: enabledProviders,
      beaconAPIEnabled: beaconAPIEnabled,
      beaconAPIPort: beaconAPIPort,
      beaconProviderColors: beaconProviderColors
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
    try container.encode(enabledProviders, forKey: .enabledProviders)
    try container.encode(beaconAPIEnabled, forKey: .beaconAPIEnabled)
    try container.encode(beaconAPIPort, forKey: .beaconAPIPort)
    try container.encode(beaconProviderColors, forKey: .beaconProviderColors)
  }

  public var refreshIntervalSeconds: TimeInterval {
    TimeInterval(refreshIntervalMinutes * 60)
  }

  public func nextRefreshDate(after date: Date) -> Date {
    date.addingTimeInterval(refreshIntervalSeconds)
  }

  public static func normalizedRefreshIntervalMinutes(_ value: Int) -> Int {
    allowedRefreshIntervalMinutes.contains(value) ? value : defaultRefreshIntervalMinutes
  }

  public static func normalizedBeaconAPIPort(_ value: Int) -> Int {
    (1024...65535).contains(value) ? value : defaultBeaconAPIPort
  }

  public static func normalizedEnabledProviders(_ value: [CodexUsageProviderID])
    -> [CodexUsageProviderID]
  {
    let unique = CodexUsageProviderID.allCases.filter { value.contains($0) }
    return unique.isEmpty ? [.openAICodex] : unique
  }

  public static func normalizedBeaconProviderColors(_ value: [String: BeaconRGB])
    -> [String: BeaconRGB]
  {
    Dictionary(
      uniqueKeysWithValues: value.compactMap { provider, color in
        guard CodexUsageProviderID(rawValue: provider) != nil else {
          return nil
        }
        return (provider, color)
      }
    )
  }

  public func beaconAccentColor(for provider: CodexUsageProviderID) -> BeaconRGB {
    beaconProviderColors[provider.rawValue] ?? provider.beaconAccentColor
  }
}

public final class CodexSettingsStore: @unchecked Sendable {
  private let fileManager: FileManager
  public let settingsURL: URL

  public init(fileManager: FileManager = .default, settingsURL: URL? = nil) {
    self.fileManager = fileManager
    self.settingsURL = settingsURL ?? Self.defaultSettingsURL(fileManager: fileManager)
  }

  public func load() -> CodexMonitorSettings {
    guard fileManager.fileExists(atPath: settingsURL.path),
      let data = try? Data(contentsOf: settingsURL),
      let settings = try? JSONDecoder.codexMonitor.decode(CodexMonitorSettings.self, from: data)
    else {
      return CodexMonitorSettings()
    }
    return CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors
    )
  }

  public func save(_ settings: CodexMonitorSettings) throws {
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder.codexMonitor.encode(settings)
    try data.write(to: settingsURL, options: [.atomic])
  }

  public static func defaultSettingsURL(fileManager: FileManager = .default) -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_MONITOR_SETTINGS_PATH"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
    }
    return
      CodexMonitorStorage
      .supportDirectory(fileManager: fileManager)
      .appendingPathComponent("settings.json")
  }
}

extension JSONEncoder {
  public static var codexMonitor: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  public static var codexMonitor: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
