import AppIntents
import CodexUsageCore
import SwiftUI
import WidgetKit

struct CodexUsageEntry: TimelineEntry {
  let date: Date
  let nextRefreshAt: Date
  let providerID: CodexUsageProviderID
  let snapshots: [CodexUsageSnapshot]
  let hideOpenRouterKeyUsage: Bool
  let hideOpenRouterCredits: Bool
}

enum CodexWidgetProviderChoice: String, AppEnum {
  case openAICodex
  case openRouter
  #if os(macOS)
  case claudeCode
  #endif

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
  #if os(macOS)
  static let caseDisplayRepresentations: [CodexWidgetProviderChoice: DisplayRepresentation] = [
    .openAICodex: "Codex",
    .openRouter: "OpenRouter",
    .claudeCode: "Claude Code",
  ]
  #else
  static let caseDisplayRepresentations: [CodexWidgetProviderChoice: DisplayRepresentation] = [
    .openAICodex: "Codex",
    .openRouter: "OpenRouter",
  ]
  #endif

  var providerID: CodexUsageProviderID {
    switch self {
    case .openAICodex:
      return .openAICodex
    case .openRouter:
      return .openRouter
    #if os(macOS)
    case .claudeCode:
      return .claudeCode
    #endif
    }
  }
}

struct OpenRouterWidgetKeyChoice: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenRouter Key")
  static let defaultQuery = OpenRouterWidgetKeyQuery()

  let id: String
  let label: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(label)")
  }
}

struct OpenRouterWidgetKeyQuery: EntityQuery {
  func entities(for identifiers: [OpenRouterWidgetKeyChoice.ID]) async throws
    -> [OpenRouterWidgetKeyChoice]
  {
    let requested = Set(identifiers)
    return openRouterKeyChoices().filter { requested.contains($0.id) }
  }

  func suggestedEntities() async throws -> [OpenRouterWidgetKeyChoice] {
    openRouterKeyChoices()
  }

  private func openRouterKeyChoices() -> [OpenRouterWidgetKeyChoice] {
    let snapshots = (try? CodexUsageCache().loadSnapshots()) ?? []
    var seenIDs = Set<String>()
    return snapshots.compactMap { snapshot in
      guard snapshot.provider == CodexUsageProviderID.openRouter.rawValue else {
        return nil
      }
      let id = snapshot.openRouterWidgetKeyID
      guard seenIDs.insert(id).inserted else {
        return nil
      }
      return OpenRouterWidgetKeyChoice(id: id, label: snapshot.openRouterWidgetKeyLabel)
    }
  }
}

struct CodexWidgetConfigurationIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Provider"
  static let description = IntentDescription("Choose which usage provider this widget displays.")

  @Parameter(title: "Provider")
  var provider: CodexWidgetProviderChoice?

  @Parameter(title: "Show Key Usage")
  var showsOpenRouterKeyUsage: Bool?

  @Parameter(title: "Show Credits")
  var showsOpenRouterCredits: Bool?

  @Parameter(title: "OpenRouter Key")
  var openRouterKey: OpenRouterWidgetKeyChoice?

  init() {
    self.provider = .openAICodex
    self.showsOpenRouterKeyUsage = true
    self.showsOpenRouterCredits = true
    self.openRouterKey = nil
  }

  init(provider: CodexWidgetProviderChoice) {
    self.provider = provider
    self.showsOpenRouterKeyUsage = true
    self.showsOpenRouterCredits = true
    self.openRouterKey = nil
  }

  var providerID: CodexUsageProviderID {
    provider?.providerID ?? .openAICodex
  }

  var openRouterKeyID: String? {
    openRouterKey?.id
  }

  var showsOpenRouterKeyUsageEffective: Bool {
    rawShowsOpenRouterKeyUsage || (!rawShowsOpenRouterKeyUsage && !rawShowsOpenRouterCredits)
  }

  var showsOpenRouterCreditsEffective: Bool {
    rawShowsOpenRouterCredits
  }

  private var rawShowsOpenRouterKeyUsage: Bool {
    showsOpenRouterKeyUsage ?? true
  }

  private var rawShowsOpenRouterCredits: Bool {
    showsOpenRouterCredits ?? true
  }
}

struct CodexUsageProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> CodexUsageEntry {
    let date = Date()
    let settings = CodexMonitorSettings()
    return CodexUsageEntry(
      date: date,
      nextRefreshAt: settings.nextRefreshDate(after: date),
      providerID: .openAICodex,
      snapshots: [
        CodexUsageSnapshot(
          fetchedAt: date,
          fiveHour: CodexUsageWindow(
            label: "5h", remainingPercent: 72, resetAt: Date().addingTimeInterval(3600)),
          weekly: CodexUsageWindow(
            label: "wk", remainingPercent: 48, resetAt: Date().addingTimeInterval(172800))
        )
      ],
      hideOpenRouterKeyUsage: false,
      hideOpenRouterCredits: false
    )
  }

  func snapshot(for configuration: CodexWidgetConfigurationIntent, in context: Context) async
    -> CodexUsageEntry
  {
    await loadEntry(configuration: configuration, refreshFromAPI: false)
  }

  func timeline(for configuration: CodexWidgetConfigurationIntent, in context: Context) async
    -> Timeline<CodexUsageEntry>
  {
    let entry = await loadEntry(configuration: configuration, refreshFromAPI: true)
    return Timeline(entries: countdownEntries(from: entry), policy: .after(entry.nextRefreshAt))
  }

  private func loadEntry(configuration: CodexWidgetConfigurationIntent, refreshFromAPI: Bool) async
    -> CodexUsageEntry
  {
    _ = refreshFromAPI
    let date = Date()
    let settings = CodexSettingsStore().load()
    return CodexUsageEntry(
      date: date,
      nextRefreshAt: settings.nextRefreshDate(after: date),
      providerID: configuration.providerID,
      snapshots: cachedSnapshot(
        providerID: configuration.providerID,
        settings: settings,
        openRouterKeyID: configuration.openRouterKeyID
      ).map { [$0] } ?? [],
      hideOpenRouterKeyUsage: !configuration.showsOpenRouterKeyUsageEffective,
      hideOpenRouterCredits: !configuration.showsOpenRouterCreditsEffective
    )
  }

  private func countdownEntries(from entry: CodexUsageEntry) -> [CodexUsageEntry] {
    guard entry.nextRefreshAt > entry.date else {
      return [entry]
    }

    var entries = [entry]
    let finalMinuteDate = entry.nextRefreshAt.addingTimeInterval(-59)
    var nextDate = entry.date.addingTimeInterval(60)
    while nextDate < finalMinuteDate {
      entries.append(copy(entry, date: nextDate))
      nextDate = nextDate.addingTimeInterval(60)
    }
    if finalMinuteDate > entry.date {
      entries.append(copy(entry, date: finalMinuteDate))
    }
    return entries
  }

  private func copy(_ entry: CodexUsageEntry, date: Date) -> CodexUsageEntry {
    CodexUsageEntry(
      date: date,
      nextRefreshAt: entry.nextRefreshAt,
      providerID: entry.providerID,
      snapshots: entry.snapshots,
      hideOpenRouterKeyUsage: entry.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: entry.hideOpenRouterCredits
    )
  }

  private func cachedSnapshot(
    providerID: CodexUsageProviderID,
    settings: CodexMonitorSettings,
    openRouterKeyID: String?
  ) -> CodexUsageSnapshot? {
    let snapshots = cachedSnapshots()
      .filteringDisabledProviders(settings: settings)
      .filter { $0.provider == providerID.rawValue }
    guard providerID == .openRouter, let openRouterKeyID else {
      return snapshots.first
    }
    return snapshots.first { snapshot in
      snapshot.openRouterWidgetKeyID == openRouterKeyID
    } ?? snapshots.first
  }

  private func cachedSnapshots() -> [CodexUsageSnapshot] {
    (try? CodexUsageCache().loadSnapshots()) ?? []
  }
}

struct CodexMonitorWidgetView: View {
  @Environment(\.widgetFamily) private var family
  var entry: CodexUsageEntry

  var body: some View {
    VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 7) {
      HStack(spacing: 6) {
        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
          .font(.system(size: family == .systemSmall ? 12 : 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(entry.snapshots.first?.displayName ?? entry.providerID.displayName)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .allowsTightening(true)
          .layoutPriority(1)
        Spacer(minLength: 4)
        Self.nextRefreshLabel(for: entry.nextRefreshAt, now: entry.date)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }

      if let snapshot = entry.snapshots.first {
        if let fiveHour = visibleFiveHourWindow(for: snapshot) {
          WidgetUsageRow(window: fiveHour)
        }
        if family != .systemSmall, let weekly = visibleWeeklyWindow(for: snapshot) {
          WidgetUsageRow(window: weekly)
        }
      } else {
        Spacer()
        Text("Open Codex Monitor to set up \(entry.providerID.displayName).")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding(.horizontal, family == .systemSmall ? 14 : 20)
    .padding(.vertical, family == .systemSmall ? 14 : 18)
    .containerBackground(.background, for: .widget)
  }

  private func visibleFiveHourWindow(for snapshot: CodexUsageSnapshot) -> CodexUsageWindow? {
    guard !isOpenRouterKeyUsageWindow(snapshot) else {
      return nil
    }
    return snapshot.fiveHour
  }

  private func visibleWeeklyWindow(for snapshot: CodexUsageSnapshot) -> CodexUsageWindow? {
    guard !isOpenRouterCreditsWindow(snapshot) else {
      return nil
    }
    return snapshot.weekly
  }

  private func isOpenRouterKeyUsageWindow(_ snapshot: CodexUsageSnapshot) -> Bool {
    entry.hideOpenRouterKeyUsage
      && snapshot.provider == CodexUsageProviderID.openRouter.rawValue
      && isOpenRouterKeyUsageLabel(snapshot.fiveHour?.label)
  }

  private func isOpenRouterKeyUsageLabel(_ label: String?) -> Bool {
    label == "Key limit" || label == "Key usage"
  }

  private func isOpenRouterCreditsWindow(_ snapshot: CodexUsageSnapshot) -> Bool {
    entry.hideOpenRouterCredits
      && snapshot.provider == CodexUsageProviderID.openRouter.rawValue
      && snapshot.weekly?.label == "Credits"
  }

  @ViewBuilder
  private static func nextRefreshLabel(for date: Date, now: Date = Date()) -> some View {
    let remaining = date.timeIntervalSince(now)
    if remaining <= 0 {
      Text("now")
    } else if remaining < 60 {
      Text(date, style: .timer)
    } else {
      Text(nextRefreshMinuteText(for: date, now: now))
    }
  }

  private static func nextRefreshMinuteText(for date: Date, now: Date = Date()) -> String {
    let totalMinutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
    if totalMinutes < 60 {
      return "in \(totalMinutes)m"
    }

    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if minutes == 0 {
      return "in \(hours)h"
    }
    return "in \(hours)h \(minutes)m"
  }

}

private extension CodexUsageSnapshot {
  var openRouterWidgetKeyID: String {
    nonEmpty(accountID) ?? nonEmpty(accountLabel) ?? instanceID
  }

  var openRouterWidgetKeyLabel: String {
    nonEmpty(accountLabel) ?? displayName
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

struct WidgetUsageRow: View {
  var window: CodexUsageWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(displayLabel)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer()
        remainingLabel
      }
      if showsProgressBar {
        UsageProgressBar(value: window.remainingPercent, tint: tint)
      }
      Text(resetText)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .allowsTightening(true)
    }
  }

  private var tint: Color {
    if window.remainingPercent < 15 {
      return .red
    }
    if window.remainingPercent < 50 {
      return .orange
    }
    return .green
  }

  private var showsProgressBar: Bool {
    window.valueText == nil || window.label.hasSuffix("limit")
  }

  private var resetText: String {
    if let detail = window.detail {
      return detail
    }
    guard let resetAt = window.resetAt else {
      return "Reset unavailable"
    }
    return CodexResetText.string(resetAt: resetAt)
  }

  private var displayLabel: String {
    if window.label == "5h" {
      return "5h"
    }
    if window.label == "wk" {
      return "Weekly"
    }
    return window.label
  }

  private var remainingLabel: some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      if let valueText = window.valueText {
        Text(valueText)
          .monospacedDigit()
      } else {
        Text("\(Int(window.remainingPercent.rounded()))")
          .monospacedDigit()
        Text("%")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
      }
    }
    .font(.system(size: 11, weight: .semibold, design: .rounded))
    .foregroundStyle(tint)
    .frame(minWidth: 30, alignment: .trailing)
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }
}

struct UsageProgressBar: View {
  @Environment(\.widgetRenderingMode) private var widgetRenderingMode
  var value: Double
  var tint: Color

  private var progress: Double {
    min(max(value / 100, 0), 1)
  }

  private var fill: Color {
    widgetRenderingMode == .fullColor ? tint.opacity(0.95) : Color.primary.opacity(0.92)
  }

  private var track: Color {
    widgetRenderingMode == .fullColor ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.26)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(track)
        Capsule()
          .fill(fill)
          .frame(width: geometry.size.width * progress)
          .widgetAccentable()
      }
    }
    .frame(height: 5)
  }
}

struct CodexMonitorWidget: Widget {
  let kind = "CodexMonitorWidget"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: CodexWidgetConfigurationIntent.self,
      provider: CodexUsageProvider()
    ) { entry in
      CodexMonitorWidgetView(entry: entry)
    }
    .configurationDisplayName("Codex Usage")
    .description("Monitor Codex subscription windows and reset times.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

@main
struct CodexMonitorWidgetBundle: WidgetBundle {
  var body: some Widget {
    CodexMonitorWidget()
  }
}
