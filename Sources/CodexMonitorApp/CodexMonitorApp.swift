import CodexUsageCore
import SwiftUI
import WidgetKit

@main
struct CodexMonitorApp: App {
  @StateObject private var store = UsageStore()

  var body: some Scene {
    WindowGroup("Codex Monitor") {
      ContentView(store: store)
        .frame(minWidth: 420, minHeight: 320)
        .task {
          store.start()
        }
    }
    .commands {
      CommandMenu("Codex Monitor") {
        if store.shouldShowCodexSignIn {
          Button("Sign In") {
            Task {
              await store.signIn()
            }
          }
          .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        Button("Refresh Usage") {
          Task {
            await store.refresh()
          }
        }
        .keyboardShortcut("r", modifiers: [.command])

        SettingsLink()
      }
    }

    MenuBarExtra("Codex", systemImage: store.menuBarSymbolName) {
      if !store.snapshots.isEmpty {
        ForEach(store.snapshots, id: \.provider) { snapshot in
          UsageSummaryView(snapshot: snapshot, compact: true, showProviderName: true)
        }
        Divider()
      } else {
        Text("No cached usage")
      }
      if store.shouldShowCodexSignIn {
        Button("Sign In") {
          Task {
            await store.signIn()
          }
        }
      }
      Button("Refresh Usage") {
        Task {
          await store.refresh()
        }
      }
      Button("Open Codex Monitor") {
        NSApp.activate(ignoringOtherApps: true)
      }
      Divider()
      Button("Quit") {
        NSApp.terminate(nil)
      }
    }

    Settings {
      SettingsView(store: store)
        .frame(width: 420)
    }
  }
}

@MainActor
final class UsageStore: ObservableObject {
  @Published var snapshots: [CodexUsageSnapshot] = []
  @Published var isRefreshing = false
  @Published private(set) var isCodexSignedIn = false
  @Published private(set) var hasOpenRouterAPIKey = false
  @Published var errorMessage: String?
  @Published private(set) var settings: CodexMonitorSettings

  private let authStore = CodexAuthStore()
  private let openRouterAPIKeyStore = OpenRouterAPIKeyStore()
  private let client = UsageProviderClient()
  private let cache = CodexUsageCache()
  private let settingsStore = CodexSettingsStore()
  private var refreshLoop: Task<Void, Never>?

  init() {
    self.settings = CodexSettingsStore().load()
    self.isCodexSignedIn = authStore.hasCredentials()
    self.hasOpenRouterAPIKey = openRouterAPIKeyStore.hasAPIKey()
  }

  deinit {
    refreshLoop?.cancel()
  }

  var menuBarSymbolName: String {
    guard
      let lowestRemaining = [
        snapshots.flatMap { [$0.fiveHour?.remainingPercent, $0.weekly?.remainingPercent] }
      ].flatMap { $0 }.compactMap({ $0 }).min()
    else {
      return "gauge.with.dots.needle.bottom.50percent"
    }
    if lowestRemaining < 15 {
      return "exclamationmark.triangle"
    }
    if lowestRemaining < 50 {
      return "gauge.with.dots.needle.33percent"
    }
    return "gauge.with.dots.needle.67percent"
  }

  var authStorageDescription: String {
    authStore.authStorageDescription
  }

  var openRouterStorageDescription: String {
    openRouterAPIKeyStore.storageDescription
  }

  var shouldShowCodexSignIn: Bool {
    settings.enabledProviders.contains(.openAICodex) && !isCodexSignedIn
  }

  func start() {
    restartRefreshLoop(runImmediately: true)
  }

  func loadCachedThenRefresh() async {
    await loadCached()
    await refresh()
  }

  func loadCached() async {
    do {
      snapshots = try cache.loadSnapshots()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func refresh() async {
    isRefreshing = true
    errorMessage = nil
    defer {
      isRefreshing = false
    }

    do {
      let nextSnapshots = try await client.fetchUsage(
        settings: settings,
        codexAuthStore: authStore,
        openRouterAPIKeyStore: openRouterAPIKeyStore
      )
      try cache.save(snapshots: nextSnapshots)
      snapshots = nextSnapshots
      isCodexSignedIn = authStore.hasCredentials()
      hasOpenRouterAPIKey = openRouterAPIKeyStore.hasAPIKey()
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      isCodexSignedIn = authStore.hasCredentials()
      hasOpenRouterAPIKey = openRouterAPIKeyStore.hasAPIKey()
      errorMessage = error.localizedDescription
    }
  }

  func signIn() async {
    isRefreshing = true
    errorMessage = nil
    defer {
      isRefreshing = false
    }

    do {
      _ = try await authStore.login { url in
        await MainActor.run {
          _ = NSWorkspace.shared.open(url)
        }
      }
      isCodexSignedIn = true
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearMonitorAuth() {
    do {
      try authStore.clearMonitorCredentials()
      isCodexSignedIn = authStore.hasCredentials()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setRefreshInterval(minutes: Int) {
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: minutes,
      enabledProviders: settings.enabledProviders
    )
    do {
      try settingsStore.save(nextSettings)
      settings = nextSettings
      WidgetCenter.shared.reloadAllTimelines()
      restartRefreshLoop(runImmediately: false)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setProvider(_ provider: CodexUsageProviderID, enabled: Bool) {
    var providers = settings.enabledProviders
    if enabled {
      providers.append(provider)
    } else {
      providers.removeAll { $0 == provider }
    }
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: providers
    )
    do {
      try settingsStore.save(nextSettings)
      settings = nextSettings
      WidgetCenter.shared.reloadAllTimelines()
      Task {
        await refresh()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func saveOpenRouterAPIKey(_ apiKey: String) {
    do {
      try openRouterAPIKeyStore.save(apiKey: apiKey)
      hasOpenRouterAPIKey = openRouterAPIKeyStore.hasAPIKey()
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearOpenRouterAPIKey() {
    do {
      try openRouterAPIKeyStore.clear()
      hasOpenRouterAPIKey = false
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func restartRefreshLoop(runImmediately: Bool) {
    refreshLoop?.cancel()
    refreshLoop = Task { [weak self] in
      if runImmediately {
        await self?.loadCachedThenRefresh()
      }
      while !Task.isCancelled {
        guard let interval = self?.settings.refreshIntervalSeconds else {
          return
        }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        if !Task.isCancelled {
          await self?.refresh()
        }
      }
    }
  }
}

struct ContentView: View {
  @ObservedObject var store: UsageStore

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Codex Usage")
            .font(.title2)
            .fontWeight(.semibold)
          Text(
            store.snapshots.first.map {
              "Fetched \(Self.fetchedAgoText(for: $0.fetchedAt))"
            } ?? "No cached snapshot"
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
        if store.shouldShowCodexSignIn {
          Button {
            Task {
              await store.signIn()
            }
          } label: {
            Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
          }
          .disabled(store.isRefreshing)
        }
        Button {
          Task {
            await store.refresh()
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshing)
      }

      if !store.snapshots.isEmpty {
        ForEach(store.snapshots, id: \.provider) { snapshot in
          UsageSummaryView(snapshot: snapshot, showProviderName: true)
        }
      } else {
        ContentUnavailableView(
          "No Usage Snapshot", systemImage: "gauge.with.dots.needle.bottom.50percent",
          description: Text("Refresh to fetch current provider usage."))
      }

      if let errorMessage = store.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }

      if store.isRefreshing {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(24)
  }

  private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  private static func fetchedAgoText(for date: Date, now: Date = Date()) -> String {
    guard date < now else {
      return "0 seconds ago"
    }
    let fetchedAt = min(date, now)
    return relativeDateFormatter.localizedString(for: fetchedAt, relativeTo: now)
  }
}

struct SettingsView: View {
  @ObservedObject var store: UsageStore
  @State private var openRouterAPIKey = ""

  var body: some View {
    Form {
      Picker("Usage refresh", selection: refreshIntervalBinding) {
        ForEach(CodexMonitorSettings.allowedRefreshIntervalMinutes, id: \.self) { minutes in
          Text("\(minutes) min").tag(minutes)
        }
      }
      .pickerStyle(.segmented)

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Text("Providers")
          .font(.headline)
        Toggle(
          CodexUsageProviderID.openAICodex.displayName,
          isOn: providerBinding(.openAICodex)
        )
        Toggle(
          CodexUsageProviderID.openRouter.displayName,
          isOn: providerBinding(.openRouter)
        )
        Toggle(
          CodexUsageProviderID.claudeCode.displayName,
          isOn: providerBinding(.claudeCode)
        )
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("OpenRouter API Key")
              .font(.headline)
            Text(
              store.hasOpenRouterAPIKey
                ? "Stored securely in Keychain" : "No OpenRouter key stored"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Clear", role: .destructive) {
            store.clearOpenRouterAPIKey()
            openRouterAPIKey = ""
          }
          .disabled(!store.hasOpenRouterAPIKey)
        }
        SecureField("sk-or-...", text: $openRouterAPIKey)
          .textFieldStyle(.roundedBorder)
        Button("Save OpenRouter Key") {
          store.saveOpenRouterAPIKey(openRouterAPIKey)
          openRouterAPIKey = ""
        }
        .disabled(openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      Divider()

      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Codex Auth")
            .font(.headline)
          Text(store.authStorageDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Spacer()
        Button("Clear", role: .destructive) {
          store.clearMonitorAuth()
        }
      }

      if let errorMessage = store.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    }
    .padding(20)
  }

  private var refreshIntervalBinding: Binding<Int> {
    Binding(
      get: { store.settings.refreshIntervalMinutes },
      set: { store.setRefreshInterval(minutes: $0) }
    )
  }

  private func providerBinding(_ provider: CodexUsageProviderID) -> Binding<Bool> {
    Binding(
      get: { store.settings.enabledProviders.contains(provider) },
      set: { store.setProvider(provider, enabled: $0) }
    )
  }
}

struct UsageSummaryView: View {
  var snapshot: CodexUsageSnapshot
  var compact = false
  var showProviderName = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 10 : 14) {
      if showProviderName {
        Text(snapshot.displayName)
          .font(compact ? .subheadline.weight(.semibold) : .headline.weight(.semibold))
      }
      if let fiveHour = snapshot.fiveHour {
        UsageWindowView(
          window: fiveHour, tint: color(for: fiveHour.remainingPercent), compact: compact)
      }
      if let weekly = snapshot.weekly {
        UsageWindowView(window: weekly, tint: color(for: weekly.remainingPercent), compact: compact)
      }
    }
  }

  private func color(for remainingPercent: Double) -> Color {
    if remainingPercent < 15 {
      return .red
    }
    if remainingPercent < 50 {
      return .orange
    }
    return .green
  }
}

struct UsageWindowView: View {
  var window: CodexUsageWindow
  var tint: Color
  var compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(displayLabel)
          .font(compact ? .body : .headline)
        Spacer()
        Text(window.valueText ?? "\(Int(window.remainingPercent.rounded()))%")
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(tint)
      }
      if window.valueText == nil {
        ProgressView(value: window.remainingPercent, total: 100)
          .tint(tint)
      }
      Text(resetText)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var resetText: String {
    if let detail = window.detail {
      return detail
    }
    guard let resetAt = window.resetAt else {
      return "Reset time unavailable"
    }
    return CodexResetText.string(resetAt: resetAt)
  }

  private var displayLabel: String {
    if window.label == "5h" {
      return "5-hour window"
    }
    if window.label == "wk" {
      return "Weekly window"
    }
    return window.label
  }
}
