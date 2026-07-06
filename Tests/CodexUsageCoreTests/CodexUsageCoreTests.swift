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

  func testMonitorSettingsPersistBeaconProviderColors() throws {
    let color = BeaconRGB(red: 12, green: 34, blue: 56)
    let settings = CodexMonitorSettings(
      beaconProviderColors: [
        CodexUsageProviderID.openAICodex.rawValue: color
      ]
    )

    let data = try JSONEncoder.codexMonitor.encode(settings)
    let decoded = try JSONDecoder.codexMonitor.decode(CodexMonitorSettings.self, from: data)

    XCTAssertEqual(decoded.beaconProviderColors[CodexUsageProviderID.openAICodex.rawValue], color)
    XCTAssertEqual(decoded.beaconAccentColor(for: .openAICodex), color)
    XCTAssertEqual(decoded.beaconAccentColor(for: .openRouter), CodexUsageProviderID.openRouter.beaconAccentColor)
  }

  func testSnapshotsFilterToEnabledProviders() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshots = [
      CodexUsageSnapshot(
        provider: CodexUsageProviderID.openAICodex.rawValue,
        fetchedAt: now,
        fiveHour: CodexUsageWindow(label: "5h", remainingPercent: 88, resetAt: nil),
        weekly: nil
      ),
      CodexUsageSnapshot(
        provider: CodexUsageProviderID.openRouter.rawValue,
        fetchedAt: now,
        fiveHour: CodexUsageWindow(label: "Credits", remainingPercent: 74, resetAt: nil),
        weekly: nil
      ),
    ]
    let settings = CodexMonitorSettings(enabledProviders: [.openRouter])

    XCTAssertEqual(
      snapshots.filteringDisabledProviders(settings: settings).map(\.provider),
      [CodexUsageProviderID.openRouter.rawValue]
    )
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
    XCTAssertEqual(payload.cards[0].accentColor.hexString, "#BF5AF2")
    XCTAssertEqual(payload.cards[0].updatedAt, now)
    XCTAssertEqual(payload.cards[0].value, 88)
    XCTAssertEqual(payload.cards[0].unit, "%")
    XCTAssertEqual(payload.cards[0].primaryMetric, "5H 88%")
    XCTAssertEqual(payload.cards[0].secondaryMetric, "WEEKLY 89%")
    XCTAssertEqual(payload.cards[0].details?.primaryProgressPercent, 88)
    XCTAssertEqual(payload.cards[0].details?.secondaryProgressPercent, 89)
    XCTAssertEqual(payload.cards[0].progressPercent, 88)
    XCTAssertEqual(payload.cards[0].secondaryProgressPercent, 89)

    let encoded = try Self.jsonObject(from: JSONEncoder.codexMonitor.encode(payload))
    let cards = try XCTUnwrap(encoded["cards"] as? [[String: Any]])
    let card = try XCTUnwrap(cards.first)
    XCTAssertEqual(card["type"] as? String, "progress")
    XCTAssertNil(card["kind"])
    XCTAssertEqual(card["accent_color"] as? String, "#BF5AF2")
    XCTAssertEqual(card["value"] as? Int, 88)
    XCTAssertEqual(card["unit"] as? String, "%")
    XCTAssertNotNil(card["updated_at"] as? String)
    let details = try XCTUnwrap(card["details"] as? [String: Any])
    XCTAssertEqual(details["primary_progress_percent"] as? Int, 88)
    XCTAssertEqual(details["secondary_progress_percent"] as? Int, 89)
  }

  func testBuildsOpenRouterBeaconCardWithCreditBalanceAndPercent() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = BeaconPayload.fromSnapshots(
      [
        CodexUsageSnapshot(
          provider: CodexUsageProviderID.openRouter.rawValue,
          fetchedAt: now,
          fiveHour: CodexUsageWindow(
            label: "Key limit",
            remainingPercent: 70,
            resetAt: nil,
            detail: "$35 of $50 left"
          ),
          weekly: CodexUsageWindow(
            label: "Credits",
            remainingPercent: 74.6268656716418,
            resetAt: nil,
            detail: "$75 balance • $25 used"
          )
        )
      ],
      generatedAt: now,
      deviceID: "beacon-dev"
    )

    let card = try XCTUnwrap(payload.cards.first)
    XCTAssertEqual(card.title, "OPENROUTER")
    XCTAssertEqual(card.kind, .spend)
    XCTAssertEqual(card.value, 75)
    XCTAssertEqual(card.unit, "%")
    XCTAssertEqual(card.primaryMetric, "$75 / 75% CREDITS REMAINING")
    XCTAssertEqual(card.secondaryMetric, "KEY LIMIT 70%")
    XCTAssertEqual(card.details?.creditsDetail, "$75 balance • $25 used")
    XCTAssertEqual(card.details?.keyLimitDetail, "$35 of $50 left")
    XCTAssertEqual(card.details?.primaryProgressPercent, 75)
    XCTAssertEqual(card.details?.secondaryProgressPercent, 70)
    XCTAssertEqual(card.progressPercent, 75)
    XCTAssertEqual(card.secondaryProgressPercent, 70)
  }

  func testBuildsBeaconCardsWithProviderColorOverride() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = BeaconPayload.fromSnapshots(
      [
        CodexUsageSnapshot(
          provider: CodexUsageProviderID.openAICodex.rawValue,
          fetchedAt: now,
          fiveHour: CodexUsageWindow(label: "5h", remainingPercent: 88, resetAt: nil),
          weekly: nil
        )
      ],
      generatedAt: now,
      deviceID: "beacon-dev",
      providerColors: [
        CodexUsageProviderID.openAICodex.rawValue: BeaconRGB(red: 12, green: 34, blue: 56)
      ]
    )

    XCTAssertEqual(payload.cards[0].accentColor, BeaconRGB(red: 12, green: 34, blue: 56))
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
    let body = try Self.jsonObject(from: response.body)
    let cards = try XCTUnwrap(body["cards"] as? [[String: Any]])
    let card = try XCTUnwrap(cards.first)
    XCTAssertEqual(card["type"] as? String, "progress")
    XCTAssertEqual(card["accent_color"] as? String, "#BF5AF2")
    XCTAssertNotNil(card["updated_at"] as? String)
    XCTAssertNil(card["kind"])
  }

  func testBeaconHTTPHandlerReturnsFirmwareContractRoutesWithValidAPIKey() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = CodexUsageCache(cacheURL: directory.appendingPathComponent("usage.json"))
    try cache.save(snapshots: [
      CodexUsageSnapshot(
        provider: CodexUsageProviderID.openAICodex.rawValue,
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
    let headers = ["authorization": "Bearer secret"]

    let apiInfo = await handler.handle(method: "GET", path: "/api/v1", headers: headers, body: Data())
    XCTAssertEqual(apiInfo.statusCode, 200)
    let apiInfoBody = try Self.jsonObject(from: apiInfo.body)
    XCTAssertEqual(apiInfoBody["firmware_contract_version"] as? String, "2026-06-29")
    XCTAssertEqual(apiInfoBody["card_endpoint"] as? String, "/api/v1/cards")
    XCTAssertEqual(apiInfoBody["refresh_endpoint"] as? String, "/api/v1/refresh")

    let contracts = await handler.handle(method: "GET", path: "/api/v1/contracts", headers: headers, body: Data())
    XCTAssertEqual(contracts.statusCode, 200)
    let contractBody = try Self.jsonObject(from: contracts.body)
    let schemas = try XCTUnwrap(contractBody["schemas"] as? [[String: Any]])
    let examples = try XCTUnwrap(contractBody["examples"] as? [[String: Any]])
    XCTAssertTrue(schemas.contains { $0["name"] as? String == "beacon-payload.schema.json" })
    XCTAssertTrue(examples.contains { $0["endpoint"] as? String == "/api/v1/examples/overview-payload.json" })

    let device = await handler.handle(
      method: "GET",
      path: "/api/v1/device/beacon-dev",
      headers: headers,
      body: Data()
    )
    XCTAssertEqual(device.statusCode, 200)
    let deviceBody = try Self.jsonObject(from: device.body)
    XCTAssertEqual(deviceBody["device_id"] as? String, "beacon-dev")
    XCTAssertEqual(deviceBody["status"] as? String, "registered")
    XCTAssertEqual(deviceBody["firmware_contract_version"] as? String, "2026-06-29")

    let status = await handler.handle(method: "GET", path: "/api/v1/status", headers: headers, body: Data())
    XCTAssertEqual(status.statusCode, 200)
    let statusBody = try Self.jsonObject(from: status.body)
    XCTAssertEqual(statusBody["device_id"] as? String, "beacon-dev")
    XCTAssertEqual(statusBody["card_count"] as? Int, 1)
    XCTAssertNotNil(statusBody["refresh_message"])
    XCTAssertNotNil(statusBody["providers"] as? [[String: Any]])
  }

  func testServiceBeaconPayloadUsesSavedProviderColors() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let settingsStore = CodexSettingsStore(settingsURL: directory.appendingPathComponent("settings.json"))
    let override = BeaconRGB(red: 9, green: 44, blue: 120)
    try settingsStore.save(CodexMonitorSettings(
      beaconProviderColors: [
        CodexUsageProviderID.openAICodex.rawValue: override
      ]
    ))
    let cache = CodexUsageCache(cacheURL: directory.appendingPathComponent("usage.json"))
    try cache.save(snapshots: [
      CodexUsageSnapshot(
        fetchedAt: now,
        fiveHour: CodexUsageWindow(label: "5h", remainingPercent: 88, resetAt: now.addingTimeInterval(3600)),
        weekly: nil
      )
    ])
    let service = CodexMonitorCollectionService(
      settingsStore: settingsStore,
      cache: cache,
      fetcher: StubUsageFetcher(snapshots: []),
      codexAuthStore: CodexAuthStore(environment: [:], secureStore: MemorySecureAuthStore(), legacyMonitorAuthFileURLs: []),
      openRouterAPIKeyStore: OpenRouterAPIKeyStore(service: "test", account: "test", accessGroup: "")
    )

    let payload = try await service.beaconPayload(deviceID: "beacon-dev", generatedAt: now)

    XCTAssertEqual(payload.cards[0].accentColor, override)
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

  func testAppsDoNotShowCodexOnlyUsageTitle() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let macAppSource = repositoryRoot.appendingPathComponent("Sources/CodexMonitorApp/CodexMonitorApp.swift")
    let iosAppSource = repositoryRoot.appendingPathComponent("Sources/CodexMonitoriOS/CodexMonitoriOSApp.swift")
    let macSource = try String(contentsOf: macAppSource, encoding: .utf8)
    let iosSource = try String(contentsOf: iosAppSource, encoding: .utf8)

    XCTAssertFalse(macSource.contains("Text(\"Codex Usage\")"))
    XCTAssertFalse(iosSource.contains(".navigationTitle(\"Codex Usage\")"))
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

    XCTAssertTrue(widgetSource.contains("cachedSnapshot(providerID: configuration.providerID, settings: settings)"))
    XCTAssertTrue(widgetSource.contains("CodexUsageCache().loadSnapshots()"))
    XCTAssertFalse(widgetSource.contains("fetchAndCacheSnapshot"))
    XCTAssertFalse(widgetSource.contains("UsageProviderClient().fetchUsage"))
    XCTAssertFalse(widgetSource.contains("OpenRouterAPIKeyStore()"))
    XCTAssertFalse(widgetSource.contains("CodexAuthStore()"))
  }

  func testWidgetFiltersCachedSnapshotsToEnabledProviders() throws {
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

    XCTAssertTrue(widgetSource.contains("cachedSnapshot(providerID: configuration.providerID, settings: settings)"))
    XCTAssertTrue(widgetSource.contains("filteringDisabledProviders(settings: settings)"))
  }

  func testIOSWidgetProviderPickerExcludesClaudeCode() throws {
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

    XCTAssertTrue(widgetSource.contains("#if os(macOS)\n  case claudeCode\n  #endif"))
    XCTAssertTrue(
      widgetSource.contains(
        "#if os(macOS)\n  static let caseDisplayRepresentations: [CodexWidgetProviderChoice: DisplayRepresentation] = ["
      ))
    XCTAssertTrue(widgetSource.contains(".claudeCode: \"Claude Code\""))
    XCTAssertTrue(
      widgetSource.contains(
        "#else\n  static let caseDisplayRepresentations: [CodexWidgetProviderChoice: DisplayRepresentation] = ["
      ))
    XCTAssertTrue(
      widgetSource.contains("#if os(macOS)\n    case .claudeCode:\n      return .claudeCode\n    #endif"))
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
    XCTAssertTrue(appSource.contains("ColorPicker"))
    XCTAssertTrue(appSource.contains("beaconColorBinding"))
    XCTAssertTrue(appSource.contains("setBeaconAccentColor"))
    XCTAssertTrue(appSource.contains("serviceEndpointText"))
    XCTAssertTrue(appSource.contains("syncServiceLaunchStateIfNeeded"))
    XCTAssertTrue(appSource.contains("CodexMonitorServiceLifecycle.isEnabled"))
    XCTAssertFalse(appSource.contains("beaconHTTPServer"))
    XCTAssertFalse(appSource.contains("startBeaconServerIfNeeded"))
  }

  func testMacAppCentralizesServiceLifecycleDetection() throws {
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

    XCTAssertTrue(appSource.contains("enum CodexMonitorServiceLifecycle"))
    XCTAssertTrue(appSource.contains("static var isEnabled: Bool"))
    XCTAssertTrue(appSource.contains("static func registerOrRestart() throws"))
    XCTAssertTrue(appSource.contains("static func unregister() throws"))
    XCTAssertTrue(appSource.contains("refreshServiceLaunchState()"))
    XCTAssertFalse(appSource.contains("NSRunningApplication.runningApplications"))
  }

  func testIOSAppLoadsRocketSimConnectOnLaunch() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexMonitoriOS/CodexMonitoriOSApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(appSource.contains("init() {\n    loadRocketSimConnect()\n  }"))
    XCTAssertTrue(appSource.contains("private func loadRocketSimConnect()"))
    XCTAssertTrue(appSource.contains("RocketSimConnectLinker.nocache.framework"))
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
    XCTAssertTrue(widgetSource.contains("private var showsProgressBar: Bool"))
    XCTAssertTrue(widgetSource.contains("window.valueText == nil || window.label.hasSuffix(\"limit\")"))
    XCTAssertTrue(widgetSource.contains("if showsProgressBar {"))
    XCTAssertFalse(widgetSource.contains("ProgressView(value: window.remainingPercent, total: 100)"))

    for appSource in appSources {
      let source = try String(contentsOf: appSource, encoding: .utf8)
      XCTAssertTrue(source.contains("func start() {\n    WidgetCenter.shared.reloadAllTimelines()"))
    }
  }

  func testAppUsageWindowsShowProgressBarsForLimitRowsWithValueText() throws {
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
      XCTAssertTrue(source.contains("private var showsProgressBar: Bool"))
      XCTAssertTrue(source.contains("window.valueText == nil || window.label.hasSuffix(\"limit\")"))
      XCTAssertTrue(source.contains("if showsProgressBar {"))
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

  func testServiceLoginItemRefreshesUsageAndReloadsWidgets() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let serviceSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexMonitorService/CodexMonitorService.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(serviceSource.contains("import WidgetKit"))
    XCTAssertTrue(serviceSource.contains("let refreshTask = Task {"))
    XCTAssertTrue(serviceSource.contains("await runRefreshLoop(service: service, settingsStore: settingsStore)"))
    XCTAssertTrue(serviceSource.contains("defer { refreshTask.cancel() }"))
    XCTAssertTrue(serviceSource.contains("private static func runRefreshLoop("))
    XCTAssertTrue(serviceSource.contains("_ = try await service.refreshNow()"))
    XCTAssertTrue(serviceSource.contains("WidgetCenter.shared.reloadAllTimelines()"))
    XCTAssertTrue(serviceSource.contains("settingsStore.load().refreshIntervalSeconds"))
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
    XCTAssertTrue(makefile.contains("SERVICE_APP_BUNDLE"))
    XCTAssertTrue(makefile.contains("INSTALLED_SERVICE_LOGIN_ITEM"))
    XCTAssertTrue(makefile.contains("--register-service"))
    XCTAssertTrue(makefile.contains("--unregister-service"))
    XCTAssertTrue(makefile.contains("pluginkit -m -A -D -vv"))
    XCTAssertTrue(makefile.contains("CodexMonitorWidgetExtension.appex"))
    XCTAssertTrue(makefile.contains("pluginkit -r \"$$stale_widget\""))
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
      fetchedAt: Date(timeIntervalSince1970: 0),
      accountID: "personal-id",
      accountLabel: "Personal"
    )

    XCTAssertEqual(snapshot.provider, CodexUsageProviderID.openRouter.rawValue)
    XCTAssertEqual(snapshot.accountID, "personal-id")
    XCTAssertEqual(snapshot.accountLabel, "Personal")
    XCTAssertEqual(snapshot.displayName, "OpenRouter - Personal")
    XCTAssertEqual(snapshot.instanceID, "openrouter:personal-id")
    XCTAssertEqual(snapshot.fiveHour?.label, "Key limit")
    XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 70)
    XCTAssertEqual(snapshot.weekly?.label, "Credits")
    XCTAssertEqual(try XCTUnwrap(snapshot.weekly?.remainingPercent), 74.6268656716418, accuracy: 0.0001)
  }

  func testOpenRouterAPIKeyStorePersistsMultipleLabeledKeys() throws {
    let store = OpenRouterAPIKeyStore(
      environment: [:],
      service: "test.openrouter.keys",
      account: UUID().uuidString,
      accessGroup: ""
    )
    try? store.clear()

    try store.save(label: "Personal", apiKey: " key-one ")
    try store.save(label: "Work", apiKey: "key-two")
    try store.save(label: "Personal", apiKey: "key-one-updated")

    var keys = try store.loadAPIKeys()
    XCTAssertEqual(keys.map(\.label), ["Personal", "Work"])
    XCTAssertEqual(keys.map(\.apiKey), ["key-one-updated", "key-two"])
    XCTAssertEqual(try store.loadAPIKeyDescriptors().map(\.label), ["Personal", "Work"])

    try store.removeAPIKey(id: keys[0].id)
    keys = try store.loadAPIKeys()
    XCTAssertEqual(keys.map(\.label), ["Work"])

    try store.clear()
  }

  func testOpenRouterAPIKeyStoreRelabelsDefaultKeyByAPIKey() throws {
    let store = OpenRouterAPIKeyStore(
      environment: [:],
      service: "test.openrouter.keys",
      account: UUID().uuidString,
      accessGroup: ""
    )
    try? store.clear()

    try store.save(apiKey: "default-key")
    XCTAssertEqual(try store.loadAPIKeys().map(\.label), ["Default"])

    try store.save(label: "Personal", apiKey: "default-key")

    let keys = try store.loadAPIKeys()
    XCTAssertEqual(keys.map(\.label), ["Personal"])
    XCTAssertEqual(keys.map(\.apiKey), ["default-key"])

    try store.clear()
  }

  func testOpenRouterAPIKeyStoreIncludesEnvironmentKeyWithLabel() throws {
    let store = OpenRouterAPIKeyStore(
      environment: [
        "OPENROUTER_API_KEY": "env-key",
        "OPENROUTER_API_KEY_LABEL": "Env Label",
      ],
      service: "test.openrouter.keys",
      account: UUID().uuidString,
      accessGroup: ""
    )
    try? store.clear()
    try store.save(label: "Stored", apiKey: "stored-key")

    let keys = try store.loadAPIKeys()
    XCTAssertEqual(keys.map(\.label), ["Env Label", "Stored"])
    XCTAssertEqual(keys.map(\.apiKey), ["env-key", "stored-key"])
    XCTAssertEqual(keys.map(\.isEnvironment), [true, false])

    try store.clear()
    XCTAssertEqual(try store.loadAPIKeys().map(\.label), ["Env Label"])
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

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: root.deletingLastPathComponent().appendingPathComponent("missing-statusline.json")
    ).fetchUsage(now: now)

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

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: root.deletingLastPathComponent().appendingPathComponent("missing-statusline.json")
    ).fetchUsage(now: now)

    XCTAssertEqual(snapshot.provider, CodexUsageProviderID.claudeCode.rawValue)
    XCTAssertEqual(snapshot.fiveHour?.valueText, "1.0K")
    XCTAssertEqual(snapshot.weekly?.valueText, "1.0K")
  }

  func testClaudeCodeSessionSelectionUsesJsonlFileModificationDates() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)
    let staleProject = root.appendingPathComponent("-Users-probello-Repos-stale", isDirectory: true)
    let activeProject = root.appendingPathComponent("-Users-probello-Repos-active", isDirectory: true)
    try FileManager.default.createDirectory(at: staleProject, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: activeProject, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-06-11T16:00:00Z")!
    let oldFileDate = ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z")!
    let activeFileDate = ISO8601DateFormatter().date(from: "2026-06-11T15:45:00Z")!

    for index in 0..<3 {
      let session = staleProject.appendingPathComponent("stale-\(index).jsonl")
      try claudeUsageLine(
        uuid: "stale-\(index)",
        timestamp: "2026-06-01T12:00:00.000Z",
        input: 100,
        output: 100,
        cacheCreation: 0,
        cacheRead: 800
      ).write(to: session, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.modificationDate: oldFileDate], ofItemAtPath: session.path)
    }

    let activeSession = activeProject.appendingPathComponent("active.jsonl")
    try claudeUsageLine(
      uuid: "active",
      timestamp: "2026-06-11T15:30:00.615Z",
      input: 100,
      output: 50,
      cacheCreation: 25,
      cacheRead: 825
    ).write(to: activeSession, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: activeFileDate],
      ofItemAtPath: activeSession.path
    )
    try FileManager.default.setAttributes(
      [.modificationDate: ISO8601DateFormatter().date(from: "2026-06-11T15:55:00Z")!],
      ofItemAtPath: staleProject.path
    )
    try FileManager.default.setAttributes(
      [.modificationDate: ISO8601DateFormatter().date(from: "2026-06-10T15:55:00Z")!],
      ofItemAtPath: activeProject.path
    )

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: root.deletingLastPathComponent().appendingPathComponent("missing-statusline.json"),
      maxFiles: 3
    ).fetchUsage(now: now)

    XCTAssertEqual(snapshot.fiveHour?.valueText, "1.0K")
    XCTAssertEqual(snapshot.weekly?.valueText, "1.0K")
  }

  func testClaudeCodeIgnoresTranscriptResetMetadataForNonAnthropicModels() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)
    let project = root.appendingPathComponent("-Users-probello-Repos-example", isDirectory: true)
    let session = project.appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-06-11T16:00:00Z")!
    try claudeUsageLine(
      uuid: "glm",
      timestamp: "2026-06-11T15:30:00.615Z",
      input: 400,
      output: 100,
      cacheCreation: 0,
      cacheRead: 500,
      model: "zai/glm-4.5",
      error: #""error":{"rateLimits":{"resetAt":1782933000}}"#
    ).write(to: session, atomically: true, encoding: .utf8)

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: root.deletingLastPathComponent().appendingPathComponent("missing-statusline.json")
    ).fetchUsage(now: now)

    XCTAssertEqual(snapshot.fiveHour?.valueText, "1.0K")
    XCTAssertNil(snapshot.fiveHour?.resetAt)
    XCTAssertEqual(
      snapshot.fiveHour?.detail?.contains("Reset metadata was not present in recent JSONL tails"),
      true
    )
    XCTAssertNil(snapshot.weekly?.resetAt)
  }

  func testClaudeCodeUsageReadsStatuslineLocalRateLimits() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)
    let project = root.appendingPathComponent("-Users-probello-Repos-example", isDirectory: true)
    let session = project.appendingPathComponent("session.jsonl")
    let statuslineFile = root.deletingLastPathComponent()
      .appendingPathComponent("statusline.local.json")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-06-11T16:00:00Z")!
    try claudeUsageLine(
      uuid: "recent",
      timestamp: "2026-06-11T15:30:00.615Z",
      input: 100,
      output: 50,
      cacheCreation: 25,
      cacheRead: 825
    ).write(to: session, atomically: true, encoding: .utf8)
    try """
      {
        "sessions": {
          "older": {
            "updated_epoch": 1783043336,
            "rate_limits": {
              "five_hour_used_pct": 80,
              "five_hour_resets_at": 1783060000,
              "seven_day_used_pct": 90,
              "seven_day_resets_at": 1783280000
            }
          },
          "newer": {
            "updated_epoch": 1783043564,
            "rate_limits": {
              "five_hour_used_pct": 38,
              "five_hour_resets_at": 1782933000,
              "seven_day_used_pct": 37,
              "seven_day_resets_at": 1783288800
            }
          }
        }
      }
      """.write(to: statuslineFile, atomically: true, encoding: .utf8)

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: statuslineFile
    ).fetchUsage(now: now)

    XCTAssertEqual(snapshot.fiveHour?.label, "5h limit")
    XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 62)
    XCTAssertEqual(snapshot.fiveHour?.resetAt, Date(timeIntervalSince1970: 1_782_933_000))
    XCTAssertNil(snapshot.fiveHour?.valueText)
    XCTAssertEqual(snapshot.fiveHour?.detail?.contains("Resets"), true)
    XCTAssertEqual(
      snapshot.fiveHour?.detail?.contains("Reset metadata was not present in recent JSONL tails"),
      false
    )
    XCTAssertEqual(snapshot.weekly?.label, "7d limit")
    XCTAssertEqual(snapshot.weekly?.remainingPercent, 63)
    XCTAssertEqual(snapshot.weekly?.resetAt, Date(timeIntervalSince1970: 1_783_288_800))
    XCTAssertNil(snapshot.weekly?.valueText)
    XCTAssertEqual(snapshot.weekly?.detail?.contains("Resets"), true)
    XCTAssertEqual(
      snapshot.weekly?.detail?.contains("Reset metadata was not present in recent JSONL tails"),
      false
    )
  }

  func testClaudeCodeShowsStatuslineFiveHourLimitWithoutRecentUsage() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)
    let project = root.appendingPathComponent("-Users-probello-Repos-example", isDirectory: true)
    let session = project.appendingPathComponent("session.jsonl")
    let statuslineFile = root.deletingLastPathComponent()
      .appendingPathComponent("statusline.local.json")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-06-11T16:00:00Z")!
    try claudeUsageLine(
      uuid: "weekly-only",
      timestamp: "2026-06-11T09:30:00.615Z",
      input: 100,
      output: 50,
      cacheCreation: 25,
      cacheRead: 825
    ).write(to: session, atomically: true, encoding: .utf8)
    try """
      {
        "sessions": {
          "current": {
            "updated_epoch": 1783043564,
            "rate_limits": {
              "five_hour_used_pct": 38,
              "five_hour_resets_at": 1782933000,
              "seven_day_used_pct": 37,
              "seven_day_resets_at": 1783288800
            }
          }
        }
      }
      """.write(to: statuslineFile, atomically: true, encoding: .utf8)

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: statuslineFile
    ).fetchUsage(now: now)

    XCTAssertEqual(snapshot.fiveHour?.label, "5h limit")
    XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 62)
    XCTAssertEqual(snapshot.fiveHour?.resetAt, Date(timeIntervalSince1970: 1_782_933_000))
    XCTAssertNil(snapshot.fiveHour?.valueText)
    XCTAssertEqual(snapshot.fiveHour?.detail?.contains("Resets"), true)
    XCTAssertEqual(snapshot.weekly?.label, "7d limit")
    XCTAssertNil(snapshot.weekly?.valueText)
  }

  func testClaudeCodeTreatsFiveHourUsedThresholdAsExhausted() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)
    let statuslineFile = root.deletingLastPathComponent()
      .appendingPathComponent("statusline.local.json")
    let now = ISO8601DateFormatter().date(from: "2026-07-05T03:40:00Z")!
    try FileManager.default.createDirectory(
      at: root.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
      {
        "sessions": {
          "current": {
            "updated_epoch": 1783221083,
            "rate_limits": {
              "five_hour_used_pct": 78,
              "five_hour_resets_at": 1783227600,
              "seven_day_used_pct": 37,
              "seven_day_resets_at": 1783288800
            }
          }
        }
      }
      """.write(to: statuslineFile, atomically: true, encoding: .utf8)

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: statuslineFile
    ).fetchUsage(now: now)

    XCTAssertEqual(snapshot.fiveHour?.label, "5h limit")
    XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 0)
    XCTAssertEqual(snapshot.weekly?.remainingPercent, 63)
  }

  func testClaudeCodeMissingProjectsDirectoryReturnsStatusSnapshot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("projects", isDirectory: true)

    let snapshot = try ClaudeCodeUsageClient(
      projectsDirectory: root,
      statuslineFile: root.deletingLastPathComponent().appendingPathComponent("missing.json")
    )
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
    cacheRead: Int,
    model: String = "claude-opus-4-8",
    error: String? = nil
  ) -> String {
    let errorFragment = error.map { ",\($0)" } ?? ""
    return """
    {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"role":"assistant","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead),"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}\(errorFragment)}
    """
  }

  private static func jsonObject(from data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
