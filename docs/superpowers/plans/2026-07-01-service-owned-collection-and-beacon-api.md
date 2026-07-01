# Service-Owned Collection and Beacon API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Codex Monitor to one service-owned collection/cache path so the macOS app, widgets, CLI, and Beacon display all consume the same normalized data.

**Architecture:** Provider collection remains in `CodexUsageCore`, but refresh scheduling and cache writes move behind a shared service coordinator. Widgets become cache-only readers. Beacon gets an opt-in, API-key-protected local HTTP API served by the macOS service path, default off.

**Tech Stack:** Swift 6, SwiftUI, WidgetKit, Network.framework, Security/Keychain, XcodeGen, XCTest.

---

## Target File Map

- Modify `Sources/CodexUsageCore/CodexUsageCore.swift`: add service status/settings models, Beacon card/payload models, API-key store, cache metadata, and service coordinator.
- Create `Sources/CodexUsageCore/BeaconAPIModels.swift`: split Beacon API contract types here if `CodexUsageCore.swift` gets too large during implementation.
- Create `Sources/CodexUsageCore/CodexMonitorService.swift`: service coordinator if not kept in the existing core file.
- Create `Sources/CodexUsageCore/BeaconHTTPServer.swift`: Network.framework HTTP server for Beacon endpoints.
- Modify `Sources/CodexMonitorApp/CodexMonitorApp.swift`: replace app-owned provider fetch loop with service calls and add API settings UI.
- Modify `Sources/CodexMonitorWidget/CodexMonitorWidget.swift`: remove widget-side provider fetches; read shared cache only.
- Modify `Sources/CodexUsageCLI/main.swift`: add `service-status`, `api-key`, and `api-enabled` commands while preserving `refresh` and `print`.
- Modify `project.yml`: include new core source files and add the helper/login-item target in Task 10.
- Modify `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`: add model, cache, service, widget source, and HTTP contract tests.
- Create `Sources/CodexMonitorService/`: macOS login item/helper in Task 10 after the in-app service path is verified.

## Non-Negotiable Behavior

- Widgets must not call provider APIs. They read `CodexUsageCache` only.
- Only one component writes provider snapshots to `usage.json`: the service coordinator.
- Beacon firmware receives generic card payloads only. Provider-specific logic stays on macOS.
- Beacon API is disabled by default.
- Beacon API key is generated locally, stored in Keychain, and never written to `usage.json` or `settings.json`.
- `make checkall` must pass after every task before commit.

---

### Task 1: Add Service Settings, Status, and API-Key Models

**Files:**
- Modify: `Sources/CodexUsageCore/CodexUsageCore.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write failing settings/status tests**

Add these tests to `CodexUsageCoreTests`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because `beaconAPIEnabled`, `beaconAPIPort`, and `CodexMonitorServiceStatus` do not exist.

- [ ] **Step 3: Implement minimal models**

Extend `CodexMonitorSettings`:

```swift
public struct CodexMonitorSettings: Codable, Equatable, Sendable {
  public static let defaultRefreshIntervalMinutes = 15
  public static let allowedRefreshIntervalMinutes = [5, 15, 30, 60]
  public static let defaultBeaconAPIPort = 8765

  public var refreshIntervalMinutes: Int
  public var enabledProviders: [CodexUsageProviderID]
  public var beaconAPIEnabled: Bool
  public var beaconAPIPort: Int

  public init(
    refreshIntervalMinutes: Int = Self.defaultRefreshIntervalMinutes,
    enabledProviders: [CodexUsageProviderID] = [.openAICodex],
    beaconAPIEnabled: Bool = false,
    beaconAPIPort: Int = Self.defaultBeaconAPIPort
  ) {
    self.refreshIntervalMinutes = Self.normalizedRefreshIntervalMinutes(refreshIntervalMinutes)
    self.enabledProviders = Self.normalizedEnabledProviders(enabledProviders)
    self.beaconAPIEnabled = beaconAPIEnabled
    self.beaconAPIPort = Self.normalizedBeaconAPIPort(beaconAPIPort)
  }

  private enum CodingKeys: String, CodingKey {
    case refreshIntervalMinutes
    case enabledProviders
    case beaconAPIEnabled
    case beaconAPIPort
  }

  public static func normalizedBeaconAPIPort(_ value: Int) -> Int {
    (1024...65535).contains(value) ? value : defaultBeaconAPIPort
  }
}
```

Update `init(from:)`, `encode(to:)`, and `CodexSettingsStore.load()` to preserve the new fields.

Add service status types:

```swift
public enum CodexMonitorRefreshState: String, Codable, Equatable, Sendable {
  case idle
  case updating
  case healthy
  case warning
  case error
}

public struct CodexMonitorServiceStatus: Codable, Equatable, Sendable {
  public var generatedAt: Date
  public var lastRefreshAt: Date?
  public var nextRefreshAt: Date?
  public var refreshIntervalSeconds: Int
  public var refreshState: CodexMonitorRefreshState
  public var refreshMessage: String
  public var refreshCount: Int
  public var providerCount: Int

  public init(
    generatedAt: Date = Date(),
    lastRefreshAt: Date?,
    nextRefreshAt: Date?,
    refreshIntervalSeconds: Int,
    refreshState: CodexMonitorRefreshState,
    refreshMessage: String,
    refreshCount: Int,
    providerCount: Int
  ) {
    self.generatedAt = generatedAt
    self.lastRefreshAt = lastRefreshAt
    self.nextRefreshAt = nextRefreshAt
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.refreshState = refreshState
    self.refreshMessage = refreshMessage
    self.refreshCount = refreshCount
    self.providerCount = providerCount
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 5: Run full verification and commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexUsageCore/CodexUsageCore.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "feat(core): add service configuration models"
```

---

### Task 2: Add Beacon Card Contract Mapping

**Files:**
- Modify: `Sources/CodexUsageCore/CodexUsageCore.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write failing contract tests**

Add:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because `BeaconPayload`, `BeaconCard`, `BeaconRGB`, and `BeaconCardStatus` do not exist.

- [ ] **Step 3: Implement Beacon contract types**

Add:

```swift
public struct BeaconRGB: Codable, Equatable, Sendable {
  public var red: Int
  public var green: Int
  public var blue: Int
}

public enum BeaconCardStatus: String, Codable, Equatable, Sendable {
  case healthy
  case warning
  case error
  case syncing
  case updating
}

public enum BeaconCardKind: String, Codable, Equatable, Sendable {
  case meter
  case spend
  case status
}

public struct BeaconCard: Codable, Equatable, Sendable {
  public var id: String
  public var provider: String
  public var title: String
  public var subtitle: String
  public var primaryMetric: String
  public var secondaryMetric: String?
  public var status: BeaconCardStatus
  public var kind: BeaconCardKind
  public var accentColor: BeaconRGB
  public var progressPercent: Int
  public var secondaryProgressPercent: Int
}

public struct BeaconPayload: Codable, Equatable, Sendable {
  public var deviceID: String
  public var generatedAt: Date
  public var cards: [BeaconCard]

  public static func fromSnapshots(
    _ snapshots: [CodexUsageSnapshot],
    generatedAt: Date = Date(),
    deviceID: String = "beacon-dev"
  ) -> BeaconPayload {
    let cards = snapshots.compactMap { BeaconCard.fromSnapshot($0) }
    return BeaconPayload(
      deviceID: deviceID,
      generatedAt: generatedAt,
      cards: cards.isEmpty ? [BeaconCard.dataUnavailable()] : cards
    )
  }
}
```

Add `CodingKeys` that encode snake_case names matching Beacon firmware, including `device_id`, `generated_at`, `primary_metric`, `secondary_metric`, `accent_color`, `progress_percent`, and `secondary_progress_percent`.

Add `BeaconCard.fromSnapshot(_:)`:

```swift
extension BeaconCard {
  public static func fromSnapshot(_ snapshot: CodexUsageSnapshot) -> BeaconCard? {
    let fiveHour = snapshot.fiveHour
    let weekly = snapshot.weekly
    let primaryPercent = Int((fiveHour?.remainingPercent ?? 0).rounded())
    let secondaryPercent = Int((weekly?.remainingPercent ?? primaryPercent).rounded())
    let providerID = CodexUsageProviderID(rawValue: snapshot.provider)
    return BeaconCard(
      id: snapshot.provider,
      provider: snapshot.provider,
      title: providerID?.beaconTitle ?? snapshot.displayName.uppercased(),
      subtitle: providerID?.beaconSubtitle ?? "STATUS",
      primaryMetric: fiveHour.map { "\($0.label.uppercased()) \(primaryPercent)%" } ?? snapshot.displayName,
      secondaryMetric: weekly.map { "\($0.label.uppercased()) \(secondaryPercent)%" },
      status: .healthy,
      kind: providerID == .openRouter ? .spend : .meter,
      accentColor: providerID?.beaconAccentColor ?? BeaconRGB(red: 112, green: 124, blue: 140),
      progressPercent: max(0, min(100, primaryPercent)),
      secondaryProgressPercent: max(0, min(100, secondaryPercent))
    )
  }

  public static func dataUnavailable() -> BeaconCard {
    BeaconCard(
      id: "data-unavailable",
      provider: "system",
      title: "DATA UNAVAILABLE",
      subtitle: "WAITING FOR CARDS",
      primaryMetric: "NO CACHE",
      secondaryMetric: "SERVICE NOT READY",
      status: .warning,
      kind: .status,
      accentColor: BeaconRGB(red: 255, green: 214, blue: 10),
      progressPercent: 0,
      secondaryProgressPercent: 0
    )
  }
}
```

Add provider presentation constants:

```swift
extension CodexUsageProviderID {
  public var beaconTitle: String {
    switch self {
    case .openAICodex: return "CODEX"
    case .openRouter: return "OPENROUTER"
    case .claudeCode: return "CLAUDE CODE"
    }
  }

  public var beaconSubtitle: String {
    switch self {
    case .openAICodex: return "USAGE"
    case .openRouter: return "CREDITS"
    case .claudeCode: return "LOCAL SESSIONS"
    }
  }

  public var beaconAccentColor: BeaconRGB {
    switch self {
    case .openAICodex: return BeaconRGB(red: 191, green: 90, blue: 242)
    case .openRouter: return BeaconRGB(red: 100, green: 103, blue: 242)
    case .claudeCode: return BeaconRGB(red: 255, green: 159, blue: 10)
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexUsageCore/CodexUsageCore.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "feat(beacon): map usage snapshots to card payloads"
```

---

### Task 3: Centralize Refresh and Cache Writes in a Service Coordinator

**Files:**
- Create: `Sources/CodexUsageCore/CodexMonitorService.swift`
- Modify: `project.yml`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write failing service tests**

Add a provider client protocol so tests can inject refresh output:

```swift
protocol UsageFetching: Sendable {
  func fetchUsage(
    settings: CodexMonitorSettings,
    codexAuthStore: CodexAuthStore,
    openRouterAPIKeyStore: OpenRouterAPIKeyStore
  ) async throws -> [CodexUsageSnapshot]
}
```

Make `UsageProviderClient` conform to it.

Add test double and tests:

```swift
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
    calls += 1
    return snapshots
  }
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because `CodexMonitorCollectionService` and `UsageFetching` do not exist.

- [ ] **Step 3: Implement service coordinator**

Create `Sources/CodexUsageCore/CodexMonitorService.swift`:

```swift
import Foundation

public protocol UsageFetching: Sendable {
  func fetchUsage(
    settings: CodexMonitorSettings,
    codexAuthStore: CodexAuthStore,
    openRouterAPIKeyStore: OpenRouterAPIKeyStore
  ) async throws -> [CodexUsageSnapshot]
}

extension UsageProviderClient: UsageFetching {}

public actor CodexMonitorCollectionService {
  private let settingsStore: CodexSettingsStore
  private let cache: CodexUsageCache
  private let fetcher: UsageFetching
  private let codexAuthStore: CodexAuthStore
  private let openRouterAPIKeyStore: OpenRouterAPIKeyStore
  private var lastRefreshAt: Date?
  private var refreshCount = 0
  private var refreshState: CodexMonitorRefreshState = .idle
  private var refreshMessage = "Idle"

  public init(
    settingsStore: CodexSettingsStore = CodexSettingsStore(),
    cache: CodexUsageCache = CodexUsageCache(),
    fetcher: UsageFetching = UsageProviderClient(),
    codexAuthStore: CodexAuthStore = CodexAuthStore(),
    openRouterAPIKeyStore: OpenRouterAPIKeyStore = OpenRouterAPIKeyStore()
  ) {
    self.settingsStore = settingsStore
    self.cache = cache
    self.fetcher = fetcher
    self.codexAuthStore = codexAuthStore
    self.openRouterAPIKeyStore = openRouterAPIKeyStore
  }

  public func refreshNow() async throws -> [CodexUsageSnapshot] {
    refreshState = .updating
    refreshMessage = "Refresh in progress"
    do {
      let settings = settingsStore.load()
      let snapshots = try await fetcher.fetchUsage(
        settings: settings,
        codexAuthStore: codexAuthStore,
        openRouterAPIKeyStore: openRouterAPIKeyStore
      )
      try cache.save(snapshots: snapshots)
      lastRefreshAt = Date()
      refreshCount += 1
      refreshState = snapshots.isEmpty ? .warning : .healthy
      refreshMessage = "Refresh completed"
      return snapshots
    } catch {
      refreshCount += 1
      refreshState = .error
      refreshMessage = error.localizedDescription
      throw error
    }
  }

  public func cachedSnapshots() throws -> [CodexUsageSnapshot] {
    try cache.loadSnapshots()
  }

  public func beaconPayload(deviceID: String = "beacon-dev", generatedAt: Date = Date())
    throws -> BeaconPayload
  {
    BeaconPayload.fromSnapshots(
      try cache.loadSnapshots(),
      generatedAt: generatedAt,
      deviceID: deviceID
    )
  }

  public func status(now: Date = Date()) -> CodexMonitorServiceStatus {
    let settings = settingsStore.load()
    return CodexMonitorServiceStatus(
      generatedAt: now,
      lastRefreshAt: lastRefreshAt,
      nextRefreshAt: lastRefreshAt.map { settings.nextRefreshDate(after: $0) },
      refreshIntervalSeconds: Int(settings.refreshIntervalSeconds),
      refreshState: refreshState,
      refreshMessage: refreshMessage,
      refreshCount: refreshCount,
      providerCount: (try? cache.loadSnapshots().count) ?? 0
    )
  }
}
```

Update `project.yml` only if XcodeGen does not include the new file automatically through the existing `Sources/CodexUsageCore` source folder.

- [ ] **Step 4: Run tests**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexUsageCore/CodexMonitorService.swift Sources/CodexUsageCore/CodexUsageCore.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift project.yml
git diff --cached --check
git commit -m "feat(core): centralize usage collection service"
```

---

### Task 4: Make Widgets Cache-Only

**Files:**
- Modify: `Sources/CodexMonitorWidget/CodexMonitorWidget.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write failing source-level regression test**

Replace the existing widget API-fetch expectation with:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because the widget currently calls `fetchAndCacheSnapshot`.

- [ ] **Step 3: Remove widget-side fetch**

Change `loadEntry` to:

```swift
private func loadEntry(providerID: CodexUsageProviderID, refreshFromAPI: Bool) async
  -> CodexUsageEntry
{
  let date = Date()
  let settings = CodexSettingsStore().load()
  return CodexUsageEntry(
    date: date,
    nextRefreshAt: settings.nextRefreshDate(after: date),
    providerID: providerID,
    snapshots: cachedSnapshot(providerID: providerID).map { [$0] } ?? []
  )
}
```

Remove `fetchAndCacheSnapshot(providerID:)`, `saveMerged(_:)`, and `providerSortIndex(_:)`.

Keep `refreshFromAPI` in the signature for now so `snapshot` and `timeline` can stay stable; add `_ = refreshFromAPI` if Swift warns about the unused parameter.

- [ ] **Step 4: Run tests**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexMonitorWidget/CodexMonitorWidget.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "refactor(widget): read provider usage from cache only"
```

---

### Task 5: Route macOS App Refresh Through the Service

**Files:**
- Modify: `Sources/CodexMonitorApp/CodexMonitorApp.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write source-level app regression test**

Add:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because `UsageStore` still owns `UsageProviderClient` and `CodexUsageCache`.

- [ ] **Step 3: Update `UsageStore`**

In `UsageStore`, replace:

```swift
private let client = UsageProviderClient()
private let cache = CodexUsageCache()
```

with:

```swift
private let service = CodexMonitorCollectionService()
```

Change `loadCached()`:

```swift
func loadCached() async {
  do {
    snapshots = try await service.cachedSnapshots()
  } catch {
    errorMessage = error.localizedDescription
  }
}
```

Change `refresh()`:

```swift
func refresh() async {
  isRefreshing = true
  errorMessage = nil
  defer {
    isRefreshing = false
  }

  do {
    let nextSnapshots = try await service.refreshNow()
    snapshots = nextSnapshots
    nextRefreshAt = settings.nextRefreshDate(after: Date())
    isCodexSignedIn = authStore.hasCredentials()
    hasOpenRouterAPIKey = openRouterAPIKeyStore.hasAPIKey()
    WidgetCenter.shared.reloadAllTimelines()
  } catch {
    isCodexSignedIn = authStore.hasCredentials()
    hasOpenRouterAPIKey = openRouterAPIKeyStore.hasAPIKey()
    errorMessage = error.localizedDescription
  }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 5: Run app build and commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexMonitorApp/CodexMonitorApp.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "refactor(app): refresh usage through collection service"
```

---

### Task 6: Add API Key Store for Beacon Access

**Files:**
- Modify: `Sources/CodexUsageCore/CodexUsageCore.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write failing key-store tests**

Add:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because `BeaconAPIKeyStore` does not exist.

- [ ] **Step 3: Implement Keychain-backed store**

Follow `OpenRouterAPIKeyStore` style. Add:

```swift
public final class BeaconAPIKeyStore: @unchecked Sendable {
  public static let service = "net.pardev.CodexMonitor.beacon-api"
  public static let account = "beacon-api-key"
  public static let accessGroup = "QMLVG482FY.net.pardev.CodexMonitor"

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

  public static func generateAPIKey() -> String {
    let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
    return Data(bytes).base64EncodedString()
  }
}
```

Implement `loadAPIKey()`, `save(apiKey:)`, and `clear()` using the same Keychain query/update/delete pattern as `OpenRouterAPIKeyStore`.

- [ ] **Step 4: Run tests and commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexUsageCore/CodexUsageCore.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "feat(beacon): store local API key in keychain"
```

---

### Task 7: Add Beacon HTTP Server

**Files:**
- Create: `Sources/CodexUsageCore/BeaconHTTPServer.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write HTTP response unit tests**

Test pure request handling before exercising sockets:

```swift
func testBeaconHTTPHandlerRequiresAPIKeyForCards() async throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let service = CodexMonitorCollectionService(
    settingsStore: CodexSettingsStore(settingsURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
    cache: CodexUsageCache(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because HTTP handler types do not exist.

- [ ] **Step 3: Implement HTTP handler and server shell**

Create `BeaconHTTPServer.swift` with:

```swift
import Foundation
import Network

public protocol BeaconAPIKeyValidating: Sendable {
  func validate(apiKey: String) -> Bool
}

extension BeaconAPIKeyStore: BeaconAPIKeyValidating {}

public struct BeaconHTTPResponse: Equatable, Sendable {
  public var statusCode: Int
  public var headers: [String: String]
  public var body: Data
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

  public func handle(method: String, path: String, headers: [String: String], body: Data)
    async -> BeaconHTTPResponse
  {
    if path == "/health" {
      return json(statusCode: 200, ["ok": true])
    }
    guard authorized(headers: headers) else {
      return json(statusCode: 401, ["error": "unauthorized"])
    }
    do {
      switch (method, path) {
      case ("GET", "/api/v1/cards"):
        return try await encodedJSON(statusCode: 200, service.beaconPayload(generatedAt: now()))
      case ("GET", "/api/v1/status"):
        return await encodedJSON(statusCode: 200, service.status(now: now()))
      case ("POST", "/api/v1/refresh"):
        _ = try await service.refreshNow()
        return try await encodedJSON(statusCode: 200, service.beaconPayload(generatedAt: now()))
      default:
        return json(statusCode: 404, ["error": "not_found"])
      }
    } catch {
      return json(statusCode: 500, ["error": error.localizedDescription])
    }
  }
}
```

Implement helpers:

```swift
private func authorized(headers: [String: String]) -> Bool
private func encodedJSON<T: Encodable>(statusCode: Int, _ value: T) -> BeaconHTTPResponse
private func json(statusCode: Int, _ value: [String: Any]) -> BeaconHTTPResponse
```

Then add a `BeaconHTTPServer` class wrapping `NWListener` with `start(port:)` and `stop()`. Use the handler above for each connection. Keep the request parser minimal: read the first request, parse method/path/header lines, ignore chunked bodies, support `Content-Length` for refresh even though body is unused.

- [ ] **Step 4: Run tests and commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexUsageCore/BeaconHTTPServer.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "feat(beacon): add protected local HTTP API"
```

---

### Task 8: Add macOS API Settings UI and Server Lifecycle

**Files:**
- Modify: `Sources/CodexMonitorApp/CodexMonitorApp.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write source-level settings test**

Add:

```swift
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
  XCTAssertTrue(appSource.contains("startBeaconServerIfNeeded"))
  XCTAssertTrue(appSource.contains("stopBeaconServer"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because settings UI and lifecycle are absent.

- [ ] **Step 3: Add store lifecycle**

Add to `UsageStore`:

```swift
@Published private(set) var beaconAPIURLText = "Beacon API disabled"
@Published private(set) var hasBeaconAPIKey = false
private let beaconAPIKeyStore = BeaconAPIKeyStore()
private var beaconHTTPServer: BeaconHTTPServer?
```

In `init`, set `hasBeaconAPIKey = (try? beaconAPIKeyStore.currentOrCreateAPIKey()) != nil` only if API is enabled.

Add:

```swift
func setBeaconAPIEnabled(_ enabled: Bool) {
  let nextSettings = CodexMonitorSettings(
    refreshIntervalMinutes: settings.refreshIntervalMinutes,
    enabledProviders: settings.enabledProviders,
    beaconAPIEnabled: enabled,
    beaconAPIPort: settings.beaconAPIPort
  )
  saveSettingsAndApplyBeaconAPI(nextSettings)
}

func setBeaconAPIPort(_ port: Int) {
  let nextSettings = CodexMonitorSettings(
    refreshIntervalMinutes: settings.refreshIntervalMinutes,
    enabledProviders: settings.enabledProviders,
    beaconAPIEnabled: settings.beaconAPIEnabled,
    beaconAPIPort: port
  )
  saveSettingsAndApplyBeaconAPI(nextSettings)
}

func regenerateBeaconAPIKey() {
  do {
    try beaconAPIKeyStore.clear()
    _ = try beaconAPIKeyStore.currentOrCreateAPIKey()
    hasBeaconAPIKey = true
  } catch {
    errorMessage = error.localizedDescription
  }
}
```

Add lifecycle methods:

```swift
private func saveSettingsAndApplyBeaconAPI(_ nextSettings: CodexMonitorSettings) {
  do {
    try settingsStore.save(nextSettings)
    settings = nextSettings
    if nextSettings.beaconAPIEnabled {
      startBeaconServerIfNeeded()
    } else {
      stopBeaconServer()
    }
  } catch {
    errorMessage = error.localizedDescription
  }
}

private func startBeaconServerIfNeeded() {
  do {
    let keyStore = beaconAPIKeyStore
    _ = try keyStore.currentOrCreateAPIKey()
    let handler = BeaconHTTPRequestHandler(service: service, apiKeyValidator: keyStore)
    beaconHTTPServer = BeaconHTTPServer(handler: handler)
    try beaconHTTPServer?.start(port: UInt16(settings.beaconAPIPort))
    beaconAPIURLText = "http://localhost:\(settings.beaconAPIPort)"
    hasBeaconAPIKey = true
  } catch {
    errorMessage = error.localizedDescription
  }
}

private func stopBeaconServer() {
  beaconHTTPServer?.stop()
  beaconHTTPServer = nil
  beaconAPIURLText = "Beacon API disabled"
}
```

Call `startBeaconServerIfNeeded()` from `start()` after starting refresh loop.

- [ ] **Step 4: Add settings UI**

Add a `Beacon API` section to `SettingsView`:

```swift
Divider()

VStack(alignment: .leading, spacing: 8) {
  Text("Beacon API")
    .font(.headline)
  Toggle("Enable Beacon API", isOn: beaconAPIEnabledBinding)
  Text(store.beaconAPIURLText)
    .font(.caption)
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
  Stepper("Port \(store.settings.beaconAPIPort)", value: beaconAPIPortBinding, in: 1024...65535)
  Button("Regenerate API Key") {
    store.regenerateBeaconAPIKey()
  }
  .disabled(!store.settings.beaconAPIEnabled)
}
```

Add bindings:

```swift
private var beaconAPIEnabledBinding: Binding<Bool> {
  Binding(
    get: { store.settings.beaconAPIEnabled },
    set: { store.setBeaconAPIEnabled($0) }
  )
}

private var beaconAPIPortBinding: Binding<Int> {
  Binding(
    get: { store.settings.beaconAPIPort },
    set: { store.setBeaconAPIPort($0) }
  )
}
```

- [ ] **Step 5: Verify and commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexMonitorApp/CodexMonitorApp.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "feat(app): control Beacon API server from settings"
```

---

### Task 9: Update CLI to Operate the Shared Service/Cache

**Files:**
- Modify: `Sources/CodexUsageCLI/main.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write CLI source tests**

Add:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because CLI commands are absent.

- [ ] **Step 3: Add CLI commands**

Create service in CLI:

```swift
let service = CodexMonitorCollectionService(
  settingsStore: settingsStore,
  cache: cache,
  codexAuthStore: authStore,
  openRouterAPIKeyStore: openRouterAPIKeyStore
)
let beaconAPIKeyStore = BeaconAPIKeyStore(accessGroup: "")
```

Add cases:

```swift
case "service-status":
  let status = await service.status()
  print(String(data: try JSONEncoder.codexMonitor.encode(status), encoding: .utf8) ?? "{}")
case "api-enabled":
  let settings = settingsStore.load()
  if let rawValue = arguments.dropFirst().first {
    let enabled = rawValue == "true" || rawValue == "on" || rawValue == "1"
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: enabled,
      beaconAPIPort: settings.beaconAPIPort
    )
    try settingsStore.save(nextSettings)
    print(enabled ? "on" : "off")
  } else {
    print(settings.beaconAPIEnabled ? "on" : "off")
  }
case "api-key":
  if arguments.dropFirst().first == "rotate" {
    try beaconAPIKeyStore.clear()
  }
  print(try beaconAPIKeyStore.currentOrCreateAPIKey())
```

Update usage text:

```swift
"usage: codex-usage [login|refresh|print|cache-path|clear-auth|interval [minutes]|providers [provider ...]|service-status|api-enabled [on|off]|api-key [rotate]]"
```

- [ ] **Step 4: Verify and commit**

Run:

```bash
make checkall
git diff --check
git add Sources/CodexUsageCLI/main.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "feat(cli): manage service and Beacon API settings"
```

---

### Task 10: Extract to Login Item Helper After In-App Server Works

**Files:**
- Create: `Sources/CodexMonitorService/CodexMonitorService.swift`
- Create: `Sources/CodexMonitorService/Info.plist`
- Create: `Sources/CodexMonitorService/CodexMonitorService.entitlements`
- Modify: `project.yml`
- Modify: `Sources/CodexMonitorApp/CodexMonitorApp.swift`
- Test: `Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift`

- [ ] **Step 1: Write project structure test**

Add:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
make test
```

Expected: FAIL because helper target does not exist.

- [ ] **Step 3: Add helper target**

Add to `project.yml`:

```yaml
  CodexMonitorService:
    type: application
    platform: macOS
    sources:
      - Sources/CodexMonitorService
    dependencies:
      - target: CodexUsageCore
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Sources/CodexMonitorService/CodexMonitorService.entitlements
        ENABLE_APP_SANDBOX: true
        ENABLE_DEBUG_DYLIB: false
        INFOPLIST_FILE: Sources/CodexMonitorService/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: net.pardev.CodexMonitor.Service
```

Add helper source:

```swift
import CodexUsageCore
import Foundation

@main
struct CodexMonitorServiceApp {
  static func main() async {
    let settingsStore = CodexSettingsStore()
    let service = CodexMonitorCollectionService(settingsStore: settingsStore)
    var server: BeaconHTTPServer?

    if settingsStore.load().beaconAPIEnabled {
      do {
        let keyStore = BeaconAPIKeyStore()
        _ = try keyStore.currentOrCreateAPIKey()
        let handler = BeaconHTTPRequestHandler(service: service, apiKeyValidator: keyStore)
        server = BeaconHTTPServer(handler: handler)
        try server?.start(port: UInt16(settingsStore.load().beaconAPIPort))
      } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      }
    }

    _ = server
    RunLoop.main.run()
  }
}
```

Add `Info.plist` with `LSUIElement` true so the helper has no Dock icon. Add entitlements matching app group and keychain access used by the main app.

- [ ] **Step 4: Register helper from app**

Use `ServiceManagement` in the app:

```swift
import ServiceManagement
```

Add a store method:

```swift
func setServiceLaunchAtLogin(_ enabled: Bool) {
  do {
    if enabled {
      try SMAppService.loginItem(identifier: "net.pardev.CodexMonitor.Service").register()
    } else {
      try SMAppService.loginItem(identifier: "net.pardev.CodexMonitor.Service").unregister()
    }
  } catch {
    errorMessage = error.localizedDescription
  }
}
```

Expose this in Settings as `Launch service at login`.

- [ ] **Step 5: Verify and commit**

Run:

```bash
make generate
make checkall
git diff --check
git add project.yml Sources/CodexMonitorService Sources/CodexMonitorApp/CodexMonitorApp.swift Tests/CodexUsageCoreTests/CodexUsageCoreTests.swift
git diff --cached --check
git commit -m "feat(service): add macOS login item collector"
```

---

### Task 11: Manual Beacon Validation

**Files:**
- Modify: `README.md`
- Optional Modify: `CHANGELOG.md`

- [ ] **Step 1: Install and run the app**

Run:

```bash
make run
```

Expected: app opens from `~/Applications/CodexMonitor.app`.

- [ ] **Step 2: Enable Beacon API**

In Settings:

- Enable Beacon API.
- Confirm URL shows `http://localhost:8765`.
- Regenerate API key once.

- [ ] **Step 3: Validate HTTP endpoints from macOS**

Run with the key from CLI:

```bash
KEY="$(build/DerivedData/Build/Products/Debug/codex-usage api-key)"
curl -i http://127.0.0.1:8765/health
curl -i -H "Authorization: Bearer $KEY" http://127.0.0.1:8765/api/v1/status
curl -i -H "Authorization: Bearer $KEY" http://127.0.0.1:8765/api/v1/cards
curl -i -X POST -H "Authorization: Bearer $KEY" http://127.0.0.1:8765/api/v1/refresh
curl -i http://127.0.0.1:8765/api/v1/cards
```

Expected:

- `/health` returns `200`.
- Authenticated status/cards/refresh return `200`.
- Unauthenticated cards returns `401`.

- [ ] **Step 4: Validate Beacon device**

Update Beacon firmware config to use the Mac LAN IP and the generated API key. Flash the Panellon board. Expected:

- ESP32 connects to Wi-Fi.
- It polls the Codex Monitor API instead of the Python collector.
- Codex, OpenRouter, and Claude Code cards display from the same service cache used by widgets.

- [ ] **Step 5: Document and commit**

Update `README.md` with:

```markdown
## Beacon API

Codex Monitor can expose a disabled-by-default local Beacon API from the macOS service.
The API is off by default. Enable it in Settings, then configure Beacon firmware
with the displayed URL and generated API key.

Widgets and the app read the shared cache directly. Beacon reads the same cache
through the local HTTP API.
```

Run:

```bash
make checkall
git diff --check
git add README.md CHANGELOG.md
git diff --cached --check
git commit -m "docs: document Beacon service API"
```

---

## Self-Review Checklist

- [ ] Widgets no longer fetch provider APIs.
- [ ] App, CLI, service, widgets, and Beacon all read or write the same cache path through `CodexUsageCache`.
- [ ] Only service coordinator performs scheduled provider refreshes.
- [ ] Beacon API remains disabled unless explicitly enabled.
- [ ] Beacon API requires a key for all routes except `/health`.
- [ ] API key lives in Keychain only.
- [ ] The Python Beacon collector can be kept as a reference until Codex Monitor serves matching payloads to the ESP32.
- [ ] `make checkall` passes after every task.
