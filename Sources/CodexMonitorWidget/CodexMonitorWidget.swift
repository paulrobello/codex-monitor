import AppIntents
import CodexUsageCore
import SwiftUI
import WidgetKit

struct CodexUsageEntry: TimelineEntry {
  let date: Date
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
    CodexUsageEntry(
      date: Date(),
      providerID: .openAICodex,
      snapshots: [
        CodexUsageSnapshot(
          fetchedAt: Date(),
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
    let interval = CodexSettingsStore().load().refreshIntervalSeconds
    return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(interval)))
  }

  private func loadEntry(providerID: CodexUsageProviderID, refreshFromAPI: Bool) async
    -> CodexUsageEntry
  {
    if refreshFromAPI, let snapshot = await fetchAndCacheSnapshot(providerID: providerID) {
      return CodexUsageEntry(date: Date(), providerID: providerID, snapshots: [snapshot])
    }
    return CodexUsageEntry(
      date: Date(),
      providerID: providerID,
      snapshots: cachedSnapshot(providerID: providerID).map { [$0] } ?? []
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
    VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
      HStack(spacing: 7) {
        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
          .font(.system(size: family == .systemSmall ? 14 : 16, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(entry.providerID.displayName)
          .font(
            family == .systemSmall ? .subheadline.weight(.semibold) : .headline.weight(.semibold)
          )
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .allowsTightening(true)
          .layoutPriority(1)
        Spacer(minLength: 4)
        if let fetchedAt = entry.snapshots.first?.fetchedAt {
          Text(Self.relativeFormatter.localizedString(for: fetchedAt, relativeTo: Date()))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
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
    .padding(family == .systemSmall ? 10 : 16)
    .containerBackground(.background, for: .widget)
  }

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

}

struct WidgetUsageRow: View {
  var window: CodexUsageWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(displayLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        remainingLabel
      }
      if window.valueText == nil {
        ProgressView(value: window.remainingPercent, total: 100)
          .tint(tint)
      }
      Text(resetText)
        .font(.caption2)
        .foregroundStyle(.secondary)
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
          .font(.system(.callout, design: .rounded).weight(.semibold))
      }
    }
    .font(.system(.body, design: .rounded).weight(.semibold))
    .foregroundStyle(tint)
    .frame(minWidth: 46, alignment: .trailing)
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
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
