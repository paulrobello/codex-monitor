import Foundation

public protocol UsageFetching: Sendable {
  func fetchUsage(
    settings: CodexMonitorSettings,
    codexAuthStore: CodexAuthStore,
    openRouterAPIKeyStore: OpenRouterAPIKeyStore
  ) async throws -> [CodexUsageSnapshot]
}

extension UsageProviderClient: UsageFetching {}

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

public actor CodexMonitorCollectionService {
  private let settingsStore: CodexSettingsStore
  private let cache: CodexUsageCache
  private let fetcher: UsageFetching
  private let codexAuthStore: CodexAuthStore
  private let openRouterAPIKeyStore: OpenRouterAPIKeyStore
  private var lastRefreshAt: Date?
  private var lastRefreshStartedAt: Date?
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
    lastRefreshStartedAt = Date()
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
    let settings = settingsStore.load()
    return try cache.loadSnapshots().filteringDisabledProviders(settings: settings)
  }

  public func beaconPayload(
    deviceID: String = "beacon-dev",
    generatedAt: Date = Date()
  ) throws -> BeaconPayload {
    let settings = settingsStore.load()
    return BeaconPayload.fromSnapshots(
      try cache.loadSnapshots().filteringDisabledProviders(settings: settings),
      generatedAt: generatedAt,
      deviceID: deviceID,
      providerColors: settings.beaconProviderColors
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
      providerCount: (try? cachedSnapshots().count) ?? 0
    )
  }

  public func beaconStatus(deviceID: String = "beacon-dev", now: Date = Date()) -> BeaconAPIStatus {
    let settings = settingsStore.load()
    let snapshots =
      ((try? cache.loadSnapshots()) ?? []).filteringDisabledProviders(settings: settings)
    let providers = snapshots.map { snapshot in
      BeaconProviderStatus(
        provider: snapshot.provider,
        status: .healthy,
        cardCount: 1,
        updatedAt: snapshot.fetchedAt
      )
    }
    let status = beaconStatus(from: refreshState, hasCards: !snapshots.isEmpty)
    return BeaconAPIStatus(
      deviceID: deviceID,
      generatedAt: now,
      lastRefreshAt: lastRefreshAt,
      nextRefreshAt: lastRefreshAt.map { settings.nextRefreshDate(after: $0) },
      refreshIntervalSeconds: Int(settings.refreshIntervalSeconds),
      refreshStatus: beaconStatus(from: refreshState, hasCards: !snapshots.isEmpty),
      refreshMessage: refreshMessage,
      refreshStartedAt: lastRefreshStartedAt,
      refreshCompletedAt: lastRefreshAt,
      refreshCount: refreshCount,
      status: status,
      cardCount: snapshots.count,
      providers: providers
    )
  }

  private func beaconStatus(from state: CodexMonitorRefreshState, hasCards: Bool) -> BeaconCardStatus {
    switch state {
    case .idle:
      return hasCards ? .healthy : .idle
    case .updating:
      return .updating
    case .healthy:
      return hasCards ? .healthy : .warning
    case .warning:
      return .warning
    case .error:
      return .error
    }
  }
}
