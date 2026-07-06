import Foundation

public struct BeaconRGB: Codable, Equatable, Sendable {
  public var red: Int
  public var green: Int
  public var blue: Int

  public init(red: Int, green: Int, blue: Int) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public var hexString: String {
    String(format: "#%02X%02X%02X", clamped(red), clamped(green), clamped(blue))
  }

  private static func clamped(_ value: Int) -> Int {
    max(0, min(255, value))
  }

  private func clamped(_ value: Int) -> Int {
    Self.clamped(value)
  }
}

public enum BeaconCardStatus: String, Codable, Equatable, Sendable {
  case healthy
  case warning
  case caution
  case critical
  case idle
  case error
  case updating
}

public enum BeaconCardKind: String, Codable, Equatable, Sendable {
  case meter
  case spend
  case status

  public var beaconType: String {
    switch self {
    case .meter:
      return "progress"
    case .spend:
      return "spend"
    case .status:
      return "status"
    }
  }

  public static func fromBeaconType(_ value: String) -> BeaconCardKind {
    switch value {
    case "progress", "meter":
      return .meter
    case "spend":
      return .spend
    default:
      return .status
    }
  }
}

public struct BeaconCardDetails: Codable, Equatable, Sendable {
  public var resetAt: Date?
  public var weeklyResetAt: Date?
  public var primaryDetail: String?
  public var secondaryDetail: String?
  public var primaryProgressPercent: Int?
  public var secondaryProgressPercent: Int?
  public var reason: String?
  public var creditsDetail: String?
  public var keyLimitDetail: String?

  public init(
    resetAt: Date? = nil,
    weeklyResetAt: Date? = nil,
    primaryDetail: String? = nil,
    secondaryDetail: String? = nil,
    primaryProgressPercent: Int? = nil,
    secondaryProgressPercent: Int? = nil,
    reason: String? = nil,
    creditsDetail: String? = nil,
    keyLimitDetail: String? = nil
  ) {
    self.resetAt = resetAt
    self.weeklyResetAt = weeklyResetAt
    self.primaryDetail = primaryDetail
    self.secondaryDetail = secondaryDetail
    self.primaryProgressPercent = primaryProgressPercent
    self.secondaryProgressPercent = secondaryProgressPercent
    self.reason = reason
    self.creditsDetail = creditsDetail
    self.keyLimitDetail = keyLimitDetail
  }

  private enum CodingKeys: String, CodingKey {
    case resetAt = "reset_at"
    case weeklyResetAt = "weekly_reset_at"
    case primaryDetail = "primary_detail"
    case secondaryDetail = "secondary_detail"
    case primaryProgressPercent = "primary_progress_percent"
    case secondaryProgressPercent = "secondary_progress_percent"
    case reason
    case creditsDetail = "credits_detail"
    case keyLimitDetail = "key_limit_detail"
  }
}

public struct BeaconCard: Codable, Equatable, Sendable {
  public var id: String
  public var provider: String
  public var title: String
  public var subtitle: String?
  public var label: String?
  public var value: Int?
  public var unit: String?
  public var primaryMetric: String
  public var secondaryMetric: String?
  public var status: BeaconCardStatus
  public var kind: BeaconCardKind
  public var accentColor: BeaconRGB
  public var updatedAt: Date
  public var details: BeaconCardDetails?
  public var progressPercent: Int
  public var secondaryProgressPercent: Int

  public init(
    id: String,
    provider: String,
    title: String,
    subtitle: String?,
    label: String? = nil,
    value: Int?,
    unit: String?,
    primaryMetric: String,
    secondaryMetric: String?,
    status: BeaconCardStatus,
    kind: BeaconCardKind,
    accentColor: BeaconRGB,
    updatedAt: Date,
    details: BeaconCardDetails?,
    progressPercent: Int,
    secondaryProgressPercent: Int
  ) {
    self.id = id
    self.provider = provider
    self.title = title
    self.subtitle = subtitle
    self.label = label
    self.value = value
    self.unit = unit
    self.primaryMetric = primaryMetric
    self.secondaryMetric = secondaryMetric
    self.status = status
    self.kind = kind
    self.accentColor = accentColor
    self.updatedAt = updatedAt
    self.details = details
    self.progressPercent = progressPercent
    self.secondaryProgressPercent = secondaryProgressPercent
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case provider
    case title
    case subtitle
    case label
    case type
    case value
    case unit
    case primaryMetric = "primary_metric"
    case secondaryMetric = "secondary_metric"
    case status
    case accentColor = "accent_color"
    case updatedAt = "updated_at"
    case details
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(provider, forKey: .provider)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(subtitle, forKey: .subtitle)
    try container.encodeIfPresent(label, forKey: .label)
    try container.encode(kind.beaconType, forKey: .type)
    try container.encodeIfPresent(value, forKey: .value)
    try container.encodeIfPresent(unit, forKey: .unit)
    try container.encode(primaryMetric, forKey: .primaryMetric)
    try container.encodeIfPresent(secondaryMetric, forKey: .secondaryMetric)
    try container.encode(status, forKey: .status)
    try container.encode(accentColor.hexString, forKey: .accentColor)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encodeIfPresent(details, forKey: .details)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    provider = try container.decode(String.self, forKey: .provider)
    title = try container.decode(String.self, forKey: .title)
    subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    label = try container.decodeIfPresent(String.self, forKey: .label)
    value = try container.decodeIfPresent(Int.self, forKey: .value)
    unit = try container.decodeIfPresent(String.self, forKey: .unit)
    primaryMetric = try container.decodeIfPresent(String.self, forKey: .primaryMetric) ?? ""
    secondaryMetric = try container.decodeIfPresent(String.self, forKey: .secondaryMetric)
    status = try container.decode(BeaconCardStatus.self, forKey: .status)
    let type = try container.decode(String.self, forKey: .type)
    kind = BeaconCardKind.fromBeaconType(type)
    let hexColor = try container.decode(String.self, forKey: .accentColor)
    accentColor = BeaconRGB(hexString: hexColor) ?? BeaconRGB(red: 112, green: 124, blue: 140)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    details = try container.decodeIfPresent(BeaconCardDetails.self, forKey: .details)
    progressPercent = value ?? details?.primaryProgressPercent ?? 0
    secondaryProgressPercent = details?.secondaryProgressPercent ?? 0
  }

  public static func fromSnapshot(
    _ snapshot: CodexUsageSnapshot,
    providerColors: [String: BeaconRGB] = [:]
  ) -> BeaconCard? {
    let fiveHour = snapshot.fiveHour
    let weekly = snapshot.weekly
    let providerID = CodexUsageProviderID(rawValue: snapshot.provider)
    let isOpenRouter = providerID == .openRouter
    let primaryWindow = isOpenRouter ? weekly ?? fiveHour : fiveHour
    let secondaryWindow = isOpenRouter ? fiveHour : weekly
    let primaryPercent = clampedPercent(primaryWindow?.remainingPercent ?? 0)
    let secondaryPercent = clampedPercent(secondaryWindow?.remainingPercent ?? Double(primaryPercent))
    let primaryDetail = resetDetail(for: primaryWindow, now: snapshot.fetchedAt)
    let secondaryDetail = resetDetail(for: secondaryWindow, now: snapshot.fetchedAt)
    let kind: BeaconCardKind = isOpenRouter ? .spend : .meter
    let accountLabel = nonEmpty(snapshot.accountLabel)

    return BeaconCard(
      id: snapshot.instanceID,
      provider: snapshot.provider,
      title: providerID?.beaconTitle ?? snapshot.displayName.uppercased(),
      subtitle: accountLabel ?? providerID?.beaconSubtitle ?? "STATUS",
      label: accountLabel,
      value: primaryPercent,
      unit: "%",
      primaryMetric: primaryMetric(for: primaryWindow, providerID: providerID, percent: primaryPercent)
        ?? snapshot.displayName,
      secondaryMetric: secondaryMetric(
        for: secondaryWindow,
        providerID: providerID,
        percent: secondaryPercent
      ),
      status: .healthy,
      kind: kind,
      accentColor: providerColors[snapshot.provider]
        ?? providerID?.beaconAccentColor
        ?? BeaconRGB(red: 112, green: 124, blue: 140),
      updatedAt: snapshot.fetchedAt,
      details: BeaconCardDetails(
        resetAt: primaryWindow?.resetAt,
        weeklyResetAt: secondaryWindow?.resetAt,
        primaryDetail: primaryDetail,
        secondaryDetail: secondaryDetail,
        primaryProgressPercent: primaryPercent,
        secondaryProgressPercent: secondaryPercent,
        creditsDetail: isOpenRouter ? primaryWindow?.detail ?? primaryWindow?.valueText : nil,
        keyLimitDetail: isOpenRouter ? secondaryWindow?.detail ?? secondaryWindow?.valueText : nil
      ),
      progressPercent: primaryPercent,
      secondaryProgressPercent: secondaryPercent
    )
  }

  public static func dataUnavailable(updatedAt: Date = Date()) -> BeaconCard {
    BeaconCard(
      id: "data-unavailable",
      provider: "system",
      title: "DATA UNAVAILABLE",
      subtitle: "WAITING FOR CARDS",
      label: nil,
      value: nil,
      unit: nil,
      primaryMetric: "NO CACHE",
      secondaryMetric: "SERVICE NOT READY",
      status: .warning,
      kind: .status,
      accentColor: BeaconRGB(red: 255, green: 214, blue: 10),
      updatedAt: updatedAt,
      details: BeaconCardDetails(reason: "Collector cache is empty"),
      progressPercent: 0,
      secondaryProgressPercent: 0
    )
  }

  private static func clampedPercent(_ value: Double) -> Int {
    max(0, min(100, Int(value.rounded())))
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  private static func primaryMetric(
    for window: CodexUsageWindow?,
    providerID: CodexUsageProviderID?,
    percent: Int
  ) -> String? {
    guard let window else {
      return nil
    }
    if providerID == .openRouter {
      let metric = "\(percent)% REMAINING"
      if let balance = firstCurrencyToken(in: window.detail ?? window.valueText) {
        return "\(balance) / \(metric)"
      }
      return metric
    }
    return "\(normalizedLabel(window.label)) \(percent)%"
  }

  private static func secondaryMetric(
    for window: CodexUsageWindow?,
    providerID: CodexUsageProviderID?,
    percent: Int
  ) -> String? {
    guard let window else {
      return nil
    }
    if providerID == .openRouter {
      return "KEY LIMIT \(percent)%"
    }
    return "\(normalizedLabel(window.label)) \(percent)%"
  }

  private static func normalizedLabel(_ label: String) -> String {
    switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "wk", "week":
      return "WEEKLY"
    default:
      return label.uppercased()
    }
  }

  private static func firstCurrencyToken(in value: String?) -> String? {
    guard let value, let start = value.firstIndex(of: "$") else {
      return nil
    }
    var end = value.index(after: start)
    while end < value.endIndex {
      let character = value[end]
      if character.isNumber || character == "." || character == "," {
        end = value.index(after: end)
      } else {
        break
      }
    }
    return end > value.index(after: start) ? String(value[start..<end]) : nil
  }

  private static func resetDetail(for window: CodexUsageWindow?, now: Date) -> String? {
    guard let resetAt = window?.resetAt else {
      return window?.detail
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "EEE h:mma"
    let resetText = formatter.string(from: resetAt)
      .replacingOccurrences(of: "AM", with: "a")
      .replacingOccurrences(of: "PM", with: "p")
    _ = now
    return "Resets \(resetText)"
  }
}

extension BeaconRGB {
  public init?(hexString: String) {
    let raw = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6, let value = Int(raw, radix: 16) else {
      return nil
    }
    self.init(red: (value >> 16) & 0xFF, green: (value >> 8) & 0xFF, blue: value & 0xFF)
  }
}

public struct BeaconPayload: Codable, Equatable, Sendable {
  public var deviceID: String
  public var generatedAt: Date
  public var cards: [BeaconCard]

  public init(deviceID: String, generatedAt: Date, cards: [BeaconCard]) {
    self.deviceID = deviceID
    self.generatedAt = generatedAt
    self.cards = cards
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case generatedAt = "generated_at"
    case cards
  }

  public static func fromSnapshots(
    _ snapshots: [CodexUsageSnapshot],
    generatedAt: Date = Date(),
    deviceID: String = "beacon-dev",
    providerColors: [String: BeaconRGB] = [:]
  ) -> BeaconPayload {
    let cards = snapshots.compactMap { BeaconCard.fromSnapshot($0, providerColors: providerColors) }
    return BeaconPayload(
      deviceID: deviceID,
      generatedAt: generatedAt,
      cards: cards.isEmpty ? [BeaconCard.dataUnavailable(updatedAt: generatedAt)] : cards
    )
  }
}

public enum BeaconAPIContract {
  public static let version = "v1"
  public static let firmwareContractVersion = "2026-06-29"
  public static let cardEndpoint = "/api/v1/cards"
  public static let refreshEndpoint = "/api/v1/refresh"
}

public struct BeaconAPIInfo: Codable, Equatable, Sendable {
  public var name: String
  public var version: String
  public var firmwareContractVersion: String
  public var cardEndpoint: String
  public var refreshEndpoint: String
  public var schemaIDs: [String]
  public var examplePayloads: [String]
  public var endpoints: [String]

  public init() {
    self.name = "Codex Monitor Beacon API"
    self.version = BeaconAPIContract.version
    self.firmwareContractVersion = BeaconAPIContract.firmwareContractVersion
    self.cardEndpoint = BeaconAPIContract.cardEndpoint
    self.refreshEndpoint = BeaconAPIContract.refreshEndpoint
    self.schemaIDs = [
      "https://example.com/beacon/schemas/api-info.schema.json",
      "https://example.com/beacon/schemas/api-contract-index.schema.json",
      "https://example.com/beacon/schemas/api-status.schema.json",
      "https://example.com/beacon/schemas/beacon-card.schema.json",
      "https://example.com/beacon/schemas/beacon-payload.schema.json",
      "https://example.com/beacon/schemas/device-status.schema.json",
      "https://example.com/beacon/schemas/provider-status.schema.json",
    ]
    self.examplePayloads = [
      "api-info.json",
      "api-status.json",
      "device-status.json",
      "overview-payload.json",
      "error-payload.json",
    ]
    self.endpoints = [
      "/health",
      "/api/v1",
      "/api/v1/contracts",
      "/api/v1/status",
      "/api/v1/cards",
      "/api/v1/cards/{provider}",
      "/api/v1/device/{device_id}",
      "/api/v1/refresh",
    ]
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case version
    case firmwareContractVersion = "firmware_contract_version"
    case cardEndpoint = "card_endpoint"
    case refreshEndpoint = "refresh_endpoint"
    case schemaIDs = "schema_ids"
    case examplePayloads = "example_payloads"
    case endpoints
  }
}

public struct BeaconContractSchema: Codable, Equatable, Sendable {
  public var name: String
  public var schemaID: String
  public var endpoint: String

  public init(name: String) {
    self.name = name
    self.schemaID = "https://example.com/beacon/schemas/\(name)"
    self.endpoint = "/api/v1/schemas/\(name)"
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case schemaID = "schema_id"
    case endpoint
  }
}

public struct BeaconContractExample: Codable, Equatable, Sendable {
  public var name: String
  public var schema: String
  public var endpoint: String

  public init(name: String, schema: String) {
    self.name = name
    self.schema = schema
    self.endpoint = "/api/v1/examples/\(name)"
  }
}

public struct BeaconContractIndex: Codable, Equatable, Sendable {
  public var schemas: [BeaconContractSchema]
  public var examples: [BeaconContractExample]

  public init() {
    self.schemas = [
      BeaconContractSchema(name: "api-info.schema.json"),
      BeaconContractSchema(name: "api-contract-index.schema.json"),
      BeaconContractSchema(name: "api-status.schema.json"),
      BeaconContractSchema(name: "beacon-card.schema.json"),
      BeaconContractSchema(name: "beacon-payload.schema.json"),
      BeaconContractSchema(name: "device-status.schema.json"),
      BeaconContractSchema(name: "provider-status.schema.json"),
    ]
    self.examples = [
      BeaconContractExample(name: "api-info.json", schema: "api-info.schema.json"),
      BeaconContractExample(name: "api-status.json", schema: "api-status.schema.json"),
      BeaconContractExample(name: "device-status.json", schema: "device-status.schema.json"),
      BeaconContractExample(name: "overview-payload.json", schema: "beacon-payload.schema.json"),
      BeaconContractExample(name: "error-payload.json", schema: "beacon-payload.schema.json"),
    ]
  }
}

public struct BeaconDeviceStatus: Codable, Equatable, Sendable {
  public var deviceID: String
  public var status: String
  public var apiVersion: String
  public var firmwareContractVersion: String
  public var cardEndpoint: String
  public var refreshEndpoint: String
  public var capabilities: [String]

  public init(deviceID: String) {
    self.deviceID = deviceID
    self.status = "registered"
    self.apiVersion = BeaconAPIContract.version
    self.firmwareContractVersion = BeaconAPIContract.firmwareContractVersion
    self.cardEndpoint = BeaconAPIContract.cardEndpoint
    self.refreshEndpoint = BeaconAPIContract.refreshEndpoint
    self.capabilities = [
      "cards",
      "provider_filtering",
      "manual_refresh",
      "touch_navigation",
      "ws2812_underglow",
    ]
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case status
    case apiVersion = "api_version"
    case firmwareContractVersion = "firmware_contract_version"
    case cardEndpoint = "card_endpoint"
    case refreshEndpoint = "refresh_endpoint"
    case capabilities
  }
}

public struct BeaconProviderStatus: Codable, Equatable, Sendable {
  public var provider: String
  public var status: BeaconCardStatus
  public var cardCount: Int
  public var updatedAt: Date?
  public var message: String?

  public init(
    provider: String,
    status: BeaconCardStatus,
    cardCount: Int,
    updatedAt: Date?,
    message: String? = nil
  ) {
    self.provider = provider
    self.status = status
    self.cardCount = cardCount
    self.updatedAt = updatedAt
    self.message = message
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case status
    case cardCount = "card_count"
    case updatedAt = "updated_at"
    case message
  }
}

public struct BeaconAPIStatus: Codable, Equatable, Sendable {
  public var deviceID: String
  public var generatedAt: Date
  public var lastRefreshAt: Date?
  public var nextRefreshAt: Date?
  public var refreshIntervalSeconds: Int
  public var refreshStatus: BeaconCardStatus
  public var refreshMessage: String?
  public var refreshStartedAt: Date?
  public var refreshCompletedAt: Date?
  public var refreshCount: Int
  public var status: BeaconCardStatus
  public var cardCount: Int
  public var providers: [BeaconProviderStatus]

  public init(
    deviceID: String,
    generatedAt: Date,
    lastRefreshAt: Date?,
    nextRefreshAt: Date?,
    refreshIntervalSeconds: Int,
    refreshStatus: BeaconCardStatus,
    refreshMessage: String?,
    refreshStartedAt: Date? = nil,
    refreshCompletedAt: Date?,
    refreshCount: Int,
    status: BeaconCardStatus,
    cardCount: Int,
    providers: [BeaconProviderStatus]
  ) {
    self.deviceID = deviceID
    self.generatedAt = generatedAt
    self.lastRefreshAt = lastRefreshAt
    self.nextRefreshAt = nextRefreshAt
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.refreshStatus = refreshStatus
    self.refreshMessage = refreshMessage
    self.refreshStartedAt = refreshStartedAt
    self.refreshCompletedAt = refreshCompletedAt
    self.refreshCount = refreshCount
    self.status = status
    self.cardCount = cardCount
    self.providers = providers
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case generatedAt = "generated_at"
    case lastRefreshAt = "last_refresh_at"
    case nextRefreshAt = "next_refresh_at"
    case refreshIntervalSeconds = "refresh_interval_seconds"
    case refreshStatus = "refresh_status"
    case refreshMessage = "refresh_message"
    case refreshStartedAt = "refresh_started_at"
    case refreshCompletedAt = "refresh_completed_at"
    case refreshCount = "refresh_count"
    case status
    case cardCount = "card_count"
    case providers
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(generatedAt, forKey: .generatedAt)
    try container.encode(lastRefreshAt, forKey: .lastRefreshAt)
    try container.encode(nextRefreshAt, forKey: .nextRefreshAt)
    try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
    try container.encode(refreshStatus, forKey: .refreshStatus)
    try container.encode(refreshMessage, forKey: .refreshMessage)
    try container.encode(refreshStartedAt, forKey: .refreshStartedAt)
    try container.encode(refreshCompletedAt, forKey: .refreshCompletedAt)
    try container.encode(refreshCount, forKey: .refreshCount)
    try container.encode(status, forKey: .status)
    try container.encode(cardCount, forKey: .cardCount)
    try container.encode(providers, forKey: .providers)
  }
}
