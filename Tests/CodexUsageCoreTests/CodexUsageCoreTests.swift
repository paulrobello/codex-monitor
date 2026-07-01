import Darwin
import Foundation
import XCTest

@testable import CodexUsageCore

final class CodexUsageCoreTests: XCTestCase {
  func testParsesCodexRateLimitWindows() throws {
    let data = Data(
      """
      {
        "rate_limit": {
          "primary_window": { "used_percent": 25, "resets_at": 1800000000 },
          "secondary_window": { "used_percent": 40, "reset_at": 1800604800000 }
        }
      }
      """.utf8
    )

    let snapshot = try XCTUnwrap(
      CodexUsageParser.parse(data: data, fetchedAt: Date(timeIntervalSince1970: 0)))
    XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
    XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
    XCTAssertEqual(snapshot.fiveHour?.resetAt, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(snapshot.weekly?.resetAt, Date(timeIntervalSince1970: 1_800_604_800))
  }

  func testRejectsPayloadWithoutUsageWindows() {
    let data = Data(#"{ "rate_limit": {} }"#.utf8)

    XCTAssertNil(CodexUsageParser.parse(data: data))
  }

  func testExtractsAccountIdFromCodexAccessToken() throws {
    let token = try jwt(
      payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}"#)

    XCTAssertEqual(CodexAuthTokenParser.accountId(from: token), "acct-123")
  }

  func testCodexOAuthOriginatorMatchesAuthPattern() {
    XCTAssertEqual(CodexOAuthConstants.originator, "codex_monitor")
    XCTAssertNil(
      CodexOAuthConstants.originator.range(of: #"[^A-Za-z0-9_]"#, options: .regularExpression))
  }

  func testDetectsCredentialsFromEnvironment() {
    let store = CodexAuthStore(
      environment: ["CODEX_MONITOR_ACCESS_TOKEN": "access-token"],
      secureStore: MemorySecureAuthStore(),
      legacyMonitorAuthFileURLs: []
    )

    XCTAssertTrue(store.hasCredentials())
  }

  func testLoadsCredentialsFromSecureStore() async throws {
    let credentials = CodexAuthCredentials(
      accessToken: "secure-access-token",
      refreshToken: "secure-refresh-token",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
      accountId: "acct-secure"
    )
    let store = CodexAuthStore(
      environment: [:],
      secureStore: MemorySecureAuthStore(credentials: credentials),
      legacyMonitorAuthFileURLs: []
    )

    let loadedCredentials = try await store.loadCredentials()
    XCTAssertEqual(loadedCredentials, credentials)
  }

  func testDoesNotLoadPiAgentAuthFilesByDefault() {
    let store = CodexAuthStore(
      environment: [:],
      secureStore: MemorySecureAuthStore(),
      legacyMonitorAuthFileURLs: []
    )

    XCTAssertFalse(store.hasCredentials())
  }

  func testMigratesLegacyMonitorAuthFileToSecureStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let authFile = directory.appendingPathComponent("auth.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(
      """
      {
        "openai-codex": {
          "type": "oauth",
          "access": "pi-access-token",
          "refresh": "pi-refresh-token"
        }
      }
      """.utf8
    ).write(to: authFile)
    let secureStore = MemorySecureAuthStore()

    let store = CodexAuthStore(
      environment: [:],
      secureStore: secureStore,
      legacyMonitorAuthFileURLs: [authFile]
    )

    let credentials = try await store.loadCredentials()
    XCTAssertEqual(credentials.accessToken, "pi-access-token")
    XCTAssertEqual(credentials.refreshToken, "pi-refresh-token")
    XCTAssertEqual(secureStore.credentials?.accessToken, "pi-access-token")
    XCTAssertFalse(FileManager.default.fileExists(atPath: authFile.path))
  }

  func testNormalizesRefreshInterval() {
    XCTAssertEqual(CodexMonitorSettings(refreshIntervalMinutes: 30).refreshIntervalMinutes, 30)
    XCTAssertEqual(CodexMonitorSettings(refreshIntervalMinutes: 3).refreshIntervalMinutes, 15)
  }

  func testMonitorSettingsIncludeBeaconAPIDefaultOff() throws {
    let settings = CodexMonitorSettings()

    XCTAssertFalse(settings.beaconAPIEnabled)
    XCTAssertEqual(settings.beaconAPIPort, 8765)
    XCTAssertEqual(settings.refreshIntervalMinutes, 15)
  }

  func testMonitorSettingsClampBeaconAPIPort() throws {
    XCTAssertEqual(CodexMonitorSettings(beaconAPIPort: 0).beaconAPIPort, 8765)
    XCTAssertEqual(CodexMonitorSettings(beaconAPIPort: 70000).beaconAPIPort, 8765)
    XCTAssertEqual(CodexMonitorSettings(beaconAPIPort: 9000).beaconAPIPort, 9000)
  }

  func testServiceStatusEncodesRefreshState() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = CodexMonitorServiceStatus(
      generatedAt: now,
      lastRefreshAt: now.addingTimeInterval(-60),
      nextRefreshAt: now.addingTimeInterval(840),
      refreshIntervalSeconds: 900,
      refreshState: .healthy,
      refreshMessage: "Refresh completed",
      refreshCount: 3,
      providerCount: 2
    )

    let data = try JSONEncoder.codexMonitor.encode(status)
    let decoded = try JSONDecoder.codexMonitor.decode(CodexMonitorServiceStatus.self, from: data)

    XCTAssertEqual(decoded.refreshState, .healthy)
    XCTAssertEqual(decoded.refreshCount, 3)
    XCTAssertEqual(decoded.providerCount, 2)
  }

  func testBuildsBeaconCardsFromUsageSnapshots() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshots = [
      CodexUsageSnapshot(
        provider: "openai-codex",
        fetchedAt: now,
        fiveHour: CodexUsageWindow(
          label: "5h",
          remainingPercent: 88,
          resetAt: now.addingTimeInterval(3600)
        ),
        weekly: CodexUsageWindow(
          label: "wk",
          remainingPercent: 89,
          resetAt: now.addingTimeInterval(172800)
        )
      )
    ]

    let payload = BeaconPayload.fromSnapshots(
      snapshots,
      generatedAt: now,
      deviceID: "beacon-dev"
    )

    XCTAssertEqual(payload.deviceID, "beacon-dev")
    XCTAssertEqual(payload.cards.count, 1)
    XCTAssertEqual(payload.cards[0].provider, "openai-codex")
    XCTAssertEqual(payload.cards[0].title, "CODEX")
    XCTAssertEqual(payload.cards[0].kind, .meter)
    XCTAssertEqual(payload.cards[0].accentColor, BeaconRGB(red: 191, green: 90, blue: 242))
    XCTAssertEqual(payload.cards[0].progressPercent, 88)
    XCTAssertEqual(payload.cards[0].secondaryProgressPercent, 89)
  }

  func testBuildsWarningBeaconPayloadWhenNoCardsExist() throws {
    let payload = BeaconPayload.fromSnapshots(
      [],
      generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      deviceID: "beacon-dev"
    )

    XCTAssertEqual(payload.cards.count, 1)
    XCTAssertEqual(payload.cards[0].status, .warning)
    XCTAssertEqual(payload.cards[0].title, "DATA UNAVAILABLE")
    XCTAssertEqual(payload.cards[0].accentColor, BeaconRGB(red: 255, green: 214, blue: 10))
  }

  func testServiceRefreshWritesCacheAndStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cacheURL = directory.appendingPathComponent("usage.json")
    let cache = CodexUsageCache(cacheURL: cacheURL)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = CodexUsageSnapshot(
      fetchedAt: now,
      fiveHour: CodexUsageWindow(label: "5h", remainingPercent: 82, resetAt: now.addingTimeInterval(3600)),
      weekly: nil
    )
    let fetcher = StubUsageFetcher(snapshots: [snapshot])
    let service = CodexMonitorCollectionService(
      settingsStore: CodexSettingsStore(settingsURL: directory.appendingPathComponent("settings.json")),
      cache: cache,
      fetcher: fetcher,
      codexAuthStore: CodexAuthStore(environment: [:], secureStore: MemorySecureAuthStore(), legacyMonitorAuthFileURLs: []),
      openRouterAPIKeyStore: OpenRouterAPIKeyStore(service: "test", account: "test", accessGroup: "")
    )

    let snapshots = try await service.refreshNow()
    let status = await service.status(now: now)

    XCTAssertEqual(snapshots, [snapshot])
    XCTAssertEqual(try cache.loadSnapshots(), [snapshot])
    XCTAssertEqual(status.refreshState, .healthy)
    XCTAssertEqual(status.refreshCount, 1)
    XCTAssertEqual(fetcher.calls, 1)
  }

  func testBeaconAPIKeyStoreGeneratesAndPersistsKey() throws {
    let store = BeaconAPIKeyStore(service: "test.beacon.api", account: UUID().uuidString, accessGroup: "")

    try? store.clear()
    let first = try store.currentOrCreateAPIKey()
    let second = try store.currentOrCreateAPIKey()

    XCTAssertEqual(first, second)
    XCTAssertGreaterThanOrEqual(first.count, 32)
    XCTAssertTrue(store.validate(apiKey: first))
    XCTAssertFalse(store.validate(apiKey: "wrong"))

    try store.clear()
  }

  func testBeaconHTTPHandlerRequiresAPIKeyForCards() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = CodexMonitorCollectionService(
      settingsStore: CodexSettingsStore(settingsURL: directory.appendingPathComponent("settings.json")),
      cache: CodexUsageCache(cacheURL: directory.appendingPathComponent("usage.json")),
      fetcher: StubUsageFetcher(snapshots: []),
      codexAuthStore: CodexAuthStore(environment: [:], secureStore: MemorySecureAuthStore(), legacyMonitorAuthFileURLs: []),
      openRouterAPIKeyStore: OpenRouterAPIKeyStore(service: "test", account: "test", accessGroup: "")
    )
    let keyStore = MemoryBeaconAPIKeyStore(apiKey: "secret")
    let handler = BeaconHTTPRequestHandler(service: service, apiKeyValidator: keyStore, now: { now })

    let response = await handler.handle(
      method: "GET",
      path: "/api/v1/cards",
      headers: [:],
      body: Data()
    )

    XCTAssertEqual(response.statusCode, 401)
  }

  func testBeaconHTTPHandlerReturnsCardsWithValidAPIKey() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = CodexUsageCache(cacheURL: directory.appendingPathComponent("usage.json"))
    try cache.save(snapshots: [
      CodexUsageSnapshot(
        fetchedAt: now,
        fiveHour: CodexUsageWindow(label: "5h", remainingPercent: 88, resetAt: now.addingTimeInterval(3600)),
        weekly: nil
      )
    ])
    let service = CodexMonitorCollectionService(
      settingsStore: CodexSettingsStore(settingsURL: directory.appendingPathComponent("settings.json")),
      cache: cache,
      fetcher: StubUsageFetcher(snapshots: []),
      codexAuthStore: CodexAuthStore(environment: [:], secureStore: MemorySecureAuthStore(), legacyMonitorAuthFileURLs: []),
      openRouterAPIKeyStore: OpenRouterAPIKeyStore(service: "test", account: "test", accessGroup: "")
    )
    let handler = BeaconHTTPRequestHandler(
      service: service,
      apiKeyValidator: MemoryBeaconAPIKeyStore(apiKey: "secret"),
      now: { now }
    )

    let response = await handler.handle(
      method: "GET",
      path: "/api/v1/cards",
      headers: ["authorization": "Bearer secret"],
      body: Data()
    )

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertTrue(String(data: response.body, encoding: .utf8)?.contains("\"cards\"") == true)
  }

  func testBeaconHTTPServerServesHealthEndpoint() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = CodexMonitorCollectionService(
      settingsStore: CodexSettingsStore(settingsURL: directory.appendingPathComponent("settings.json")),
      cache: CodexUsageCache(cacheURL: directory.appendingPathComponent("usage.json")),
      fetcher: StubUsageFetcher(snapshots: []),
      codexAuthStore: CodexAuthStore(environment: [:], secureStore: MemorySecureAuthStore(), legacyMonitorAuthFileURLs: []),
      openRouterAPIKeyStore: OpenRouterAPIKeyStore(service: "test", account: "test", accessGroup: "")
    )
    let handler = BeaconHTTPRequestHandler(
      service: service,
      apiKeyValidator: MemoryBeaconAPIKeyStore(apiKey: "secret")
    )
    let server = BeaconHTTPServer(handler: handler)
    let port = try Self.unusedLocalPort()
    try server.start(port: port)
    defer {
      server.stop()
    }

    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/health"))
    var lastError: Error?
    for _ in 0..<20 {
      do {
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"ok":true}"#)
        return
      } catch {
        lastError = error
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    throw lastError ?? NSError(domain: "BeaconHTTPServerTest", code: 1)
  }

  func testBeaconHTTPServerStartThrowsWhenPortIsUnavailable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = CodexMonitorCollectionService(
      settingsStore: CodexSettingsStore(settingsURL: directory.appendingPathComponent("settings.json")),
      cache: CodexUsageCache(cacheURL: directory.appendingPathComponent("usage.json")),
      fetcher: StubUsageFetcher(snapshots: []),
      codexAuthStore: CodexAuthStore(environment: [:], secureStore: MemorySecureAuthStore(), legacyMonitorAuthFileURLs: []),
      openRouterAPIKeyStore: OpenRouterAPIKeyStore(service: "test", account: "test", accessGroup: "")
    )
    let handler = BeaconHTTPRequestHandler(
      service: service,
      apiKeyValidator: MemoryBeaconAPIKeyStore(apiKey: "secret")
    )
    let server = BeaconHTTPServer(handler: handler)
    let occupiedSocket = try Self.boundLocalSocket()
    defer {
      close(occupiedSocket.descriptor)
      server.stop()
    }

    XCTAssertThrowsError(try server.start(port: occupiedSocket.port))
  }

  func testComputesNextRefreshDateFromEntryDate() {
    let entryDate = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = CodexMonitorSettings(refreshIntervalMinutes: 15)

    XCTAssertEqual(settings.nextRefreshDate(after: entryDate), entryDate.addingTimeInterval(15 * 60))
  }

  func testFormatsRefreshRemainingTextWithSecondsOnlyUnderMinute() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    XCTAssertEqual(
      CodexRefreshText.remainingText(until: now.addingTimeInterval(45), now: now), "in 45s")
    XCTAssertEqual(
      CodexRefreshText.remainingText(until: now.addingTimeInterval(75), now: now), "in 2m")
    XCTAssertEqual(
      CodexRefreshText.remainingText(until: now.addingTimeInterval(65 * 60), now: now), "in 1h 5m")
    XCTAssertEqual(CodexRefreshText.remainingText(until: now, now: now), "now")
  }

  func testAppViewsShowNextRefreshInsteadOfFetchedAge() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSources = [
      repositoryRoot.appendingPathComponent("Sources/CodexMonitorApp/CodexMonitorApp.swift"),
      repositoryRoot.appendingPathComponent("Sources/CodexMonitoriOS/CodexMonitoriOSApp.swift"),
    ]

    for appSource in appSources {
      let source = try String(contentsOf: appSource, encoding: .utf8)
      XCTAssertTrue(source.contains("@Published private(set) var nextRefreshAt"))
      XCTAssertTrue(source.contains("Next refresh \\(CodexRefreshText.remainingText"))
      XCTAssertFalse(source.contains("\"Fetched \\(Self.fetchedAgoText"))
    }
  }

  func testWidgetUsesMinuteOnlyRefreshTextUntilFinalMinute() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let widgetSource = repositoryRoot
      .appendingPathComponent("Sources/CodexMonitorWidget/CodexMonitorWidget.swift")
    let source = try String(contentsOf: widgetSource, encoding: .utf8)

    XCTAssertTrue(source.contains("return Timeline(entries: countdownEntries(from: entry), policy: .after(entry.nextRefreshAt))"))
    XCTAssertTrue(source.contains("private func countdownEntries(from entry: CodexUsageEntry) -> [CodexUsageEntry]"))
    XCTAssertTrue(source.contains("entry.nextRefreshAt.addingTimeInterval(-59)"))
    XCTAssertTrue(source.contains("nextRefreshLabel(for: entry.nextRefreshAt, now: entry.date)"))
    XCTAssertTrue(source.contains("if remaining < 60"))
    XCTAssertTrue(source.contains("Text(date, style: .timer)"))
    XCTAssertTrue(source.contains("Text(nextRefreshMinuteText(for: date, now: now))"))
    XCTAssertFalse(source.contains("TimelineView(.periodic"))
    XCTAssertFalse(source.contains("Text(date, style: .relative)"))
  }

  func testWidgetReadsCacheOnlyAndDoesNotFetchProviderAPIs() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let widgetSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexMonitorWidget/CodexMonitorWidget.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(widgetSource.contains("cachedSnapshot(providerID: configuration.providerID)"))
    XCTAssertTrue(widgetSource.contains("CodexUsageCache().loadSnapshots()"))
    XCTAssertFalse(widgetSource.contains("fetchAndCacheSnapshot"))
    XCTAssertFalse(widgetSource.contains("UsageProviderClient().fetchUsage"))
    XCTAssertFalse(widgetSource.contains("OpenRouterAPIKeyStore()"))
    XCTAssertFalse(widgetSource.contains("CodexAuthStore()"))
  }

  func testMacAppUsesCollectionServiceForRefreshes() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexMonitorApp/CodexMonitorApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(appSource.contains("private let service = CodexMonitorCollectionService()"))
    XCTAssertTrue(appSource.contains("let nextSnapshots = try await service.refreshNow()"))
    XCTAssertTrue(appSource.contains("snapshots = try await service.cachedSnapshots()"))
    XCTAssertFalse(appSource.contains("private let client = UsageProviderClient()"))
    XCTAssertFalse(appSource.contains("try cache.save(snapshots: nextSnapshots)"))
  }

  func testMacSettingsExposeBeaconAPIToggleAndKeyControls() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexMonitorApp/CodexMonitorApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(appSource.contains("Text(\"Beacon API\")"))
    XCTAssertTrue(appSource.contains("Toggle(\"Enable Beacon API\""))
    XCTAssertTrue(appSource.contains("Regenerate API Key"))
    XCTAssertTrue(appSource.contains("serviceEndpointText"))
    XCTAssertTrue(appSource.contains("syncServiceLaunchStateIfNeeded"))
    XCTAssertTrue(appSource.contains("NSRunningApplication.runningApplications"))
    XCTAssertFalse(appSource.contains("beaconHTTPServer"))
    XCTAssertFalse(appSource.contains("startBeaconServerIfNeeded"))
  }

  func testUsageBarsUseAccentableCustomWidgetFillAndReloadOnAppStart() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let widgetSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexMonitorWidget/CodexMonitorWidget.swift"),
      encoding: .utf8
    )
    let appSources = [
      repositoryRoot.appendingPathComponent("Sources/CodexMonitorApp/CodexMonitorApp.swift"),
      repositoryRoot.appendingPathComponent("Sources/CodexMonitoriOS/CodexMonitoriOSApp.swift"),
    ]

    XCTAssertTrue(widgetSource.contains("struct UsageProgressBar: View"))
    XCTAssertTrue(widgetSource.contains("@Environment(\\.widgetRenderingMode)"))
    XCTAssertTrue(widgetSource.contains("widgetRenderingMode == .fullColor"))
    XCTAssertTrue(widgetSource.contains(".frame(width: geometry.size.width * progress)"))
    XCTAssertTrue(widgetSource.contains(".widgetAccentable()"))
    XCTAssertTrue(widgetSource.contains(".font(.caption.weight(.semibold))"))
    XCTAssertTrue(widgetSource.contains(".padding(.horizontal, family == .systemSmall ? 14 : 20)"))
    XCTAssertTrue(widgetSource.contains(".padding(.vertical, family == .systemSmall ? 14 : 18)"))
    XCTAssertTrue(widgetSource.contains("VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 7)"))
    XCTAssertTrue(widgetSource.contains(".font(.system(size: 10, weight: .semibold))"))
    XCTAssertTrue(widgetSource.contains(".font(.system(size: 11, weight: .semibold, design: .rounded))"))
    XCTAssertTrue(widgetSource.contains(".frame(height: 5)"))
    XCTAssertFalse(widgetSource.contains("ProgressView(value: window.remainingPercent, total: 100)"))

    for appSource in appSources {
      let source = try String(contentsOf: appSource, encoding: .utf8)
      XCTAssertTrue(source.contains("func start() {\n    WidgetCenter.shared.reloadAllTimelines()"))
    }
  }

  func testCLIRefreshUsesCollectionServiceAndReadsCache() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let cliSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexUsageCLI/main.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(cliSource.contains("CodexMonitorCollectionService"))
    XCTAssertTrue(cliSource.contains("let snapshots = try await service.refreshNow()"))
    XCTAssertTrue(cliSource.contains("CodexKeychainAuthStore(accessGroup: \"\")"))
    XCTAssertTrue(cliSource.contains("OpenRouterAPIKeyStore(accessGroup: \"\")"))
    XCTAssertTrue(cliSource.contains("try cache.loadSnapshots()"))
    XCTAssertFalse(cliSource.contains("UsageProviderClient().fetchUsage"))
    XCTAssertFalse(cliSource.contains("try cache.save(snapshot: snapshot)"))
  }

  func testCLIExposesBeaconAPIManagementCommands() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let cliSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexUsageCLI/main.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(cliSource.contains("case \"service-status\":"))
    XCTAssertTrue(cliSource.contains("case \"api-enabled\":"))
    XCTAssertTrue(cliSource.contains("case \"api-key\":"))
    XCTAssertTrue(cliSource.contains("CodexMonitorCollectionService"))
    XCTAssertTrue(cliSource.contains("BeaconAPIKeyStore"))
  }

  func testCLIProvidersCommandManagesEnabledProviders() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let cliSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexUsageCLI/main.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(cliSource.contains("case \"providers\":"))
    XCTAssertTrue(cliSource.contains("CodexUsageProviderID(rawValue: rawProvider)"))
    XCTAssertTrue(cliSource.contains("settings.refreshIntervalMinutes"))
    XCTAssertTrue(cliSource.contains("let nextSettings = CodexMonitorSettings("))
    XCTAssertTrue(cliSource.contains("enabledProviders: providers"))
    XCTAssertTrue(cliSource.contains("try settingsStore.save(nextSettings)"))
    XCTAssertTrue(
      cliSource.contains(
        "usage: codex-usage [login|refresh|print|cache-path|clear-auth|interval [minutes]|providers [provider ...]|service-status|api-enabled [on|off]|api-key [rotate]]"
      )
    )
  }

  func testProjectDefinesCodexMonitorServiceLoginItem() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let project = try String(
      contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
      encoding: .utf8
    )

    XCTAssertTrue(project.contains("CodexMonitorService:"))
    XCTAssertTrue(project.contains("Sources/CodexMonitorService"))
    XCTAssertTrue(project.contains("net.pardev.CodexMonitor.Service"))
    XCTAssertTrue(project.contains("- target: CodexMonitorService"))
    XCTAssertTrue(project.contains("$CONTENTS_FOLDER_PATH/Library/LoginItems"))
    XCTAssertTrue(project.contains("CodexMonitorService.app was not built"))
  }

  func testMacAppExposesServiceRegistrationCommandLineMode() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexMonitorApp/CodexMonitorApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(appSource.contains("CodexMonitorServiceCommand.handleIfNeeded()"))
    XCTAssertTrue(appSource.contains("case \"--register-service\":"))
    XCTAssertTrue(appSource.contains("case \"--unregister-service\":"))
    XCTAssertTrue(appSource.contains("SMAppService.loginItem(identifier: serviceIdentifier)"))
    XCTAssertTrue(appSource.contains("Darwin.exit(EXIT_SUCCESS)"))
  }

  func testMakefileExposesServiceInstallTargets() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let makefile = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Makefile"),
      encoding: .utf8
    )

    XCTAssertTrue(makefile.contains("install-service: install"))
    XCTAssertTrue(makefile.contains("uninstall-service:"))
    XCTAssertTrue(makefile.contains("INSTALLED_APP_EXECUTABLE"))
    XCTAssertTrue(makefile.contains("--register-service"))
    XCTAssertTrue(makefile.contains("--unregister-service"))
  }

  func testCLITargetDoesNotRequireProvisionedKeychainEntitlement() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let project = try String(
      contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
      encoding: .utf8
    )
    let cliTarget = try XCTUnwrap(project.range(of: "  CodexUsageCLI:"))
    let nextTarget = try XCTUnwrap(
      project.range(of: "\n  CodexMonitor:", range: cliTarget.upperBound..<project.endIndex)
    )
    let cliSettings = String(project[cliTarget.lowerBound..<nextTarget.lowerBound])

    XCTAssertFalse(cliSettings.contains("CODE_SIGN_ENTITLEMENTS"))
    XCTAssertTrue(cliSettings.contains("LD_RUNPATH_SEARCH_PATHS: \"$(inherited) @executable_path\""))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: repositoryRoot
          .appendingPathComponent("Sources/CodexUsageCLI/CodexUsageCLI.entitlements")
          .path
      )
    )
  }

  func testKeychainStoresCanOmitAccessGroupForUnprovisionedCLI() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let coreSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/CodexUsageCore/CodexUsageCore.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(coreSource.contains("if !accessGroup.isEmpty"))
    XCTAssertTrue(coreSource.contains("query[kSecAttrAccessGroup as String] = accessGroup"))
  }

  func testPersistsSettings() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("settings.json")
    let store = CodexSettingsStore(settingsURL: url)

    try store.save(
      CodexMonitorSettings(refreshIntervalMinutes: 60, enabledProviders: [.openAICodex, .openRouter])
    )

    XCTAssertEqual(store.load().refreshIntervalMinutes, 60)
    XCTAssertEqual(store.load().enabledProviders, [.openAICodex, .openRouter])
  }

  func testParsesOpenRouterKeyLimitAndCredits() throws {
    let keyData = Data(
      """
      {
        "data": {
          "label": "Codex Monitor",
          "limit": 50,
          "limit_reset": "monthly",
          "limit_remaining": 35,
          "include_byok_in_limit": false,
          "usage": 15,
          "usage_daily": 1.25,
          "usage_weekly": 5,
          "usage_monthly": 15,
          "byok_usage": 0,
          "byok_usage_daily": 0,
          "byok_usage_weekly": 0,
          "byok_usage_monthly": 0,
          "is_free_tier": false
        }
      }
      """.utf8
    )
    let creditsData = Data(
      """
      {
        "data": {
          "total_credits": 100.5,
          "total_usage": 25.5
        }
      }
      """.utf8
    )

    let snapshot = try OpenRouterUsageParser.parse(
      keyData: keyData,
      creditsData: creditsData,
      fetchedAt: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(snapshot.provider, CodexUsageProviderID.openRouter.rawValue)
    XCTAssertEqual(snapshot.fiveHour?.label, "Key limit")
    XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 70)
    XCTAssertEqual(snapshot.weekly?.label, "Credits")
    XCTAssertEqual(try XCTUnwrap(snapshot.weekly?.remainingPercent), 74.6268656716418, accuracy: 0.0001)
  }

  func testCacheReadsLegacySingleSnapshot() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("usage.json")
    let cache = CodexUsageCache(cacheURL: url)
    let snapshot = CodexUsageSnapshot(
      fetchedAt: Date(timeIntervalSince1970: 0),
      fiveHour: CodexUsageWindow(label: "5h", remainingPercent: 80, resetAt: nil),
      weekly: nil
    )
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder.codexMonitor.encode(snapshot).write(to: url)

    XCTAssertEqual(try cache.loadSnapshots(), [snapshot])
  }

  func testExtractsClaudeCodeUsageFromNewestProjectSessionTails() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)
    let project = root.appendingPathComponent("-Users-probello-Repos-example", isDirectory: true)
    let session = project.appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-06-11T16:00:00Z")!
    let recent = "2026-06-11T15:30:00.615Z"
    let older = "2026-06-09T12:00:00.125Z"
    try [
      claudeUsageLine(
        uuid: "recent",
        timestamp: recent,
        input: 100,
        output: 50,
        cacheCreation: 25,
        cacheRead: 825
      ),
      claudeUsageLine(
        uuid: "older",
        timestamp: older,
        input: 200,
        output: 75,
        cacheCreation: 0,
        cacheRead: 725
      ),
    ].joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)

    let snapshot = try ClaudeCodeUsageClient(projectsDirectory: root).fetchUsage(now: now)

    XCTAssertEqual(snapshot.provider, CodexUsageProviderID.claudeCode.rawValue)
    XCTAssertEqual(snapshot.fiveHour?.valueText, "1.0K")
    XCTAssertEqual(snapshot.weekly?.valueText, "2.0K")
    XCTAssertEqual(snapshot.fiveHour?.detail?.contains("1 responses"), true)
    XCTAssertEqual(snapshot.weekly?.detail?.contains("2 responses"), true)
  }

  func testExtractsClaudeCodeUsageFromNestedProjectSessionFolders() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)
    let project = root.appendingPathComponent("-Users-probello-Repos-example", isDirectory: true)
    let sessionFolder = project.appendingPathComponent(
      "f6faab22-67e3-44f6-85cf-99a447f982a6", isDirectory: true)
    let session = sessionFolder.appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-06-11T16:00:00Z")!
    try claudeUsageLine(
      uuid: "nested",
      timestamp: "2026-06-11T15:30:00.615Z",
      input: 400,
      output: 100,
      cacheCreation: 0,
      cacheRead: 500
    ).write(to: session, atomically: true, encoding: .utf8)

    let snapshot = try ClaudeCodeUsageClient(projectsDirectory: root).fetchUsage(now: now)

    XCTAssertEqual(snapshot.provider, CodexUsageProviderID.claudeCode.rawValue)
    XCTAssertEqual(snapshot.fiveHour?.valueText, "1.0K")
    XCTAssertEqual(snapshot.weekly?.valueText, "1.0K")
  }

  func testClaudeCodeMissingProjectsDirectoryReturnsStatusSnapshot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)

    let snapshot = try ClaudeCodeUsageClient(projectsDirectory: root)
      .fetchUsage(now: Date(timeIntervalSince1970: 0))

    XCTAssertEqual(snapshot.provider, CodexUsageProviderID.claudeCode.rawValue)
    XCTAssertNil(snapshot.fiveHour)
    XCTAssertEqual(snapshot.weekly?.valueText, "0")
    XCTAssertEqual(
      snapshot.weekly?.detail,
      "No Claude Code JSONL sessions were found under \(root.path)."
    )
  }

  #if os(macOS)
    func testClaudeCodeDefaultProjectsDirectoryUsesRealHomeOnMacOS() {
      let path = ClaudeCodeUsageClient.defaultProjectsDirectory().path

      XCTAssertEqual(path, "/Users/\(NSUserName())/.claude/projects")
      XCTAssertFalse(path.contains("/Library/Containers/"))
    }
  #endif

  func testFormatsRemainingResetTime() {
    let now = Date(timeIntervalSince1970: 0)

    XCTAssertEqual(
      CodexResetText.remainingText(until: now.addingTimeInterval(45), now: now), "in <1m")
    XCTAssertEqual(
      CodexResetText.remainingText(until: now.addingTimeInterval(65 * 60), now: now), "in 1h 5m")
    XCTAssertEqual(
      CodexResetText.remainingText(until: now.addingTimeInterval(26 * 60 * 60), now: now),
      "in 1d 2h")
    XCTAssertEqual(CodexResetText.remainingText(until: now, now: now), "now")
  }

  private func jwt(payload: String) throws -> String {
    let header = #"{"alg":"none"}"#
    return [
      base64URL(Data(header.utf8)),
      base64URL(Data(payload.utf8)),
      "signature",
    ].joined(separator: ".")
  }

  private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func claudeUsageLine(
    uuid: String,
    timestamp: String,
    input: Int,
    output: Int,
    cacheCreation: Int,
    cacheRead: Int
  ) -> String {
    """
    {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead),"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}
    """
  }

  private static func unusedLocalPort() throws -> UInt16 {
    let socket = try boundLocalSocket()
    close(socket.descriptor)
    return socket.port
  }

  private static func boundLocalSocket() throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      close(descriptor)
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    guard listen(descriptor, 1) == 0 else {
      close(descriptor)
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        getsockname(descriptor, socketAddress, &length)
      }
    }
    guard nameResult == 0 else {
      close(descriptor)
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
  }
}

private final class MemorySecureAuthStore: CodexSecureAuthStoring, @unchecked Sendable {
  var credentials: CodexAuthCredentials?
  let storageDescription = "memory secure auth store"

  init(credentials: CodexAuthCredentials? = nil) {
    self.credentials = credentials
  }

  func loadCredentials() throws -> CodexAuthCredentials? {
    credentials
  }

  func save(credentials: CodexAuthCredentials) throws {
    self.credentials = credentials
  }

  func clear() throws {
    credentials = nil
  }
}

private final class StubUsageFetcher: UsageFetching, @unchecked Sendable {
  var snapshots: [CodexUsageSnapshot]
  var calls = 0

  init(snapshots: [CodexUsageSnapshot]) {
    self.snapshots = snapshots
  }

  func fetchUsage(
    settings: CodexMonitorSettings,
    codexAuthStore: CodexAuthStore,
    openRouterAPIKeyStore: OpenRouterAPIKeyStore
  ) async throws -> [CodexUsageSnapshot] {
    _ = settings
    _ = codexAuthStore
    _ = openRouterAPIKeyStore
    calls += 1
    return snapshots
  }
}

private struct MemoryBeaconAPIKeyStore: BeaconAPIKeyValidating {
  var apiKey: String

  func validate(apiKey: String) -> Bool {
    self.apiKey == apiKey
  }
}
