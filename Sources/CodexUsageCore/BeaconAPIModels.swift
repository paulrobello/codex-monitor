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

  public init(
    id: String,
    provider: String,
    title: String,
    subtitle: String,
    primaryMetric: String,
    secondaryMetric: String?,
    status: BeaconCardStatus,
    kind: BeaconCardKind,
    accentColor: BeaconRGB,
    progressPercent: Int,
    secondaryProgressPercent: Int
  ) {
    self.id = id
    self.provider = provider
    self.title = title
    self.subtitle = subtitle
    self.primaryMetric = primaryMetric
    self.secondaryMetric = secondaryMetric
    self.status = status
    self.kind = kind
    self.accentColor = accentColor
    self.progressPercent = progressPercent
    self.secondaryProgressPercent = secondaryProgressPercent
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case provider
    case title
    case subtitle
    case primaryMetric = "primary_metric"
    case secondaryMetric = "secondary_metric"
    case status
    case kind
    case accentColor = "accent_color"
    case progressPercent = "progress_percent"
    case secondaryProgressPercent = "secondary_progress_percent"
  }

  public static func fromSnapshot(_ snapshot: CodexUsageSnapshot) -> BeaconCard? {
    let fiveHour = snapshot.fiveHour
    let weekly = snapshot.weekly
    let primaryPercent = clampedPercent(fiveHour?.remainingPercent ?? 0)
    let secondaryPercent = clampedPercent(weekly?.remainingPercent ?? Double(primaryPercent))
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
      progressPercent: primaryPercent,
      secondaryProgressPercent: secondaryPercent
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

  private static func clampedPercent(_ value: Double) -> Int {
    max(0, min(100, Int(value.rounded())))
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
