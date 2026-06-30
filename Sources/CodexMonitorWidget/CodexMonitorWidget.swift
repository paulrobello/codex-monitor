import AppIntents
import CodexUsageCore
import SwiftUI
import WidgetKit

struct CodexUsageEntry: TimelineEntry {
  let date: Date
  let nextRefreshAt: Date
  let providerID: CodexUsageProviderID
  let snapshots: [CodexUsageSnapshot]
}

enum CodexWidgetProviderChoice: String, AppEnum {
  case openAICodex
  case openRouter
  case claudeCode

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
  static let caseDisplayRepresentations: [CodexWidgetProviderChoice: DisplayRepresentation] = [
    .openAICodex: "Codex",
    .openRouter: "OpenRouter",
    .claudeCode: "Claude Code",
  ]

  var providerID: CodexUsageProviderID {
    switch self {
    case .openAICodex:
      return .openAICodex
    case .openRouter:
      return .openRouter
    case .claudeCode:
      return .claudeCode
    }
  }
}

struct CodexWidgetConfigurationIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Provider"
  static let description = IntentDescription("Choose which usage provider this widget displays.")

  @Parameter(title: "Provider")
  var provider: CodexWidgetProviderChoice?

  init() {
    self.provider = .openAICodex
  }

  init(provider: CodexWidgetProviderChoice) {
    self.provider = provider
  }

  var providerID: CodexUsageProviderID {
    provider?.providerID ?? .openAICodex
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
      ]
    )
  }

  func snapshot(for configuration: CodexWidgetConfigurationIntent, in context: Context) async
    -> CodexUsageEntry
  {
    await loadEntry(providerID: configuration.providerID, refreshFromAPI: false)
  }

  func timeline(for configuration: CodexWidgetConfigurationIntent, in context: Context) async
    -> Timeline<CodexUsageEntry>
  {
    let entry = await loadEntry(providerID: configuration.providerID, refreshFromAPI: true)
    return Timeline(entries: countdownEntries(from: entry), policy: .after(entry.nextRefreshAt))
  }

  private func loadEntry(providerID: CodexUsageProviderID, refreshFromAPI: Bool) async
    -> CodexUsageEntry
  {
    let date = Date()
    let settings = CodexSettingsStore().load()
    if refreshFromAPI, let snapshot = await fetchAndCacheSnapshot(providerID: providerID) {
      return CodexUsageEntry(
        date: date,
        nextRefreshAt: settings.nextRefreshDate(after: date),
        providerID: providerID,
        snapshots: [snapshot]
      )
    }
    return CodexUsageEntry(
      date: date,
      nextRefreshAt: settings.nextRefreshDate(after: date),
      providerID: providerID,
      snapshots: cachedSnapshot(providerID: providerID).map { [$0] } ?? []
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
      snapshots: entry.snapshots
    )
  }

  private func fetchAndCacheSnapshot(providerID: CodexUsageProviderID) async -> CodexUsageSnapshot? {
    do {
      let settings = CodexSettingsStore().load()
      let providerSettings = CodexMonitorSettings(
        refreshIntervalMinutes: settings.refreshIntervalMinutes,
        enabledProviders: [providerID]
      )
      let snapshots = try await UsageProviderClient().fetchUsage(
        settings: providerSettings,
        codexAuthStore: CodexAuthStore(),
        openRouterAPIKeyStore: OpenRouterAPIKeyStore()
      )
      guard let snapshot = snapshots.first(where: { $0.provider == providerID.rawValue }) else {
        return nil
      }
      try saveMerged(snapshot)
      return snapshot
    } catch {
      return nil
    }
  }

  private func cachedSnapshot(providerID: CodexUsageProviderID) -> CodexUsageSnapshot? {
    cachedSnapshots().first { $0.provider == providerID.rawValue }
  }

  private func cachedSnapshots() -> [CodexUsageSnapshot] {
    (try? CodexUsageCache().loadSnapshots()) ?? []
  }

  private func saveMerged(_ snapshot: CodexUsageSnapshot) throws {
    let cache = CodexUsageCache()
    var snapshots = (try? cache.loadSnapshots()) ?? []
    snapshots.removeAll { $0.provider == snapshot.provider }
    snapshots.append(snapshot)
    snapshots.sort { lhs, rhs in
      providerSortIndex(lhs.provider) < providerSortIndex(rhs.provider)
    }
    try cache.save(snapshots: snapshots)
  }

  private func providerSortIndex(_ rawValue: String) -> Int {
    CodexUsageProviderID.allCases.firstIndex { $0.rawValue == rawValue } ?? Int.max
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
        Text(entry.providerID.displayName)
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
        if let fiveHour = snapshot.fiveHour {
          WidgetUsageRow(window: fiveHour)
        }
        if family != .systemSmall, let weekly = snapshot.weekly {
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

struct WidgetUsageRow: View {
  var window: CodexUsageWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(displayLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        remainingLabel
      }
      if window.valueText == nil {
        UsageProgressBar(value: window.remainingPercent, tint: tint)
      }
      Text(resetText)
        .font(.caption2)
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
          .font(.system(.caption2, design: .rounded).weight(.semibold))
      }
    }
    .font(.system(.caption, design: .rounded).weight(.semibold))
    .foregroundStyle(tint)
    .frame(minWidth: 34, alignment: .trailing)
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
