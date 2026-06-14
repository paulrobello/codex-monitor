import CodexUsageCore
import SwiftUI
import UIKit
import WidgetKit

@main
struct CodexMonitoriOSApp: App {
  @StateObject private var store = iOSUsageStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      iOSContentView(store: store)
        .task {
          store.start()
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active {
            store.resumeDeviceLoginIfNeeded()
          }
        }
    }
  }
}

@MainActor
final class iOSUsageStore: ObservableObject {
  @Published var snapshots: [CodexUsageSnapshot] = []
  @Published var isRefreshing = false
  @Published private(set) var isCodexSignedIn = false
  @Published private(set) var hasOpenRouterAPIKey = false
  @Published var errorMessage: String?
  @Published private(set) var settings: CodexMonitorSettings
  @Published private(set) var nextRefreshAt: Date?
  @Published var deviceLogin: CodexDeviceCodeLogin?
  @Published private(set) var isDeviceLoginPolling = false

  private let authStore = CodexAuthStore()
  private let openRouterAPIKeyStore = OpenRouterAPIKeyStore()
  private let client = UsageProviderClient()
  private let cache = CodexUsageCache()
  private let settingsStore = CodexSettingsStore()
  private var refreshLoop: Task<Void, Never>?
  private var deviceLoginTask: Task<Void, Never>?

  init() {
    self.settings = CodexSettingsStore().load()
    self.isCodexSignedIn = authStore.hasCredentials()
    self.hasOpenRouterAPIKey = openRouterAPIKeyStore.hasAPIKey()
  }

  deinit {
    refreshLoop?.cancel()
    deviceLoginTask?.cancel()
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
    WidgetCenter.shared.reloadAllTimelines()
    restartRefreshLoop(runImmediately: true)
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

  func signIn() {
    guard !isRefreshing else {
      return
    }

    deviceLoginTask?.cancel()
    isRefreshing = true
    errorMessage = nil

    Task { [weak self] in
      await self?.startDeviceLogin()
    }
  }

  func resumeDeviceLoginIfNeeded() {
    guard deviceLogin != nil, !isDeviceLoginPolling, !isCodexSignedIn else {
      return
    }
    startDeviceLoginPolling()
  }

  func openDeviceLoginPage() {
    guard let deviceLogin else {
      return
    }
    UIApplication.shared.open(deviceLogin.verificationURL)
  }

  func copyDeviceCode() {
    guard let deviceLogin else {
      return
    }
    UIPasteboard.general.string = deviceLogin.userCode
  }

  func clearMonitorAuth() {
    do {
      cancelDeviceLogin()
      try authStore.clearMonitorCredentials()
      isCodexSignedIn = authStore.hasCredentials()
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
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
      nextRefreshAt = nextSettings.nextRefreshDate(after: Date())
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

  func cancelDeviceLogin() {
    deviceLoginTask?.cancel()
    deviceLoginTask = nil
    deviceLogin = nil
    isDeviceLoginPolling = false
    isRefreshing = false
  }

  private func startDeviceLogin() async {
    do {
      let login = try await authStore.beginDeviceCodeLogin()
      deviceLogin = login
      await UIApplication.shared.open(login.verificationURL)
      startDeviceLoginPolling()
    } catch {
      isRefreshing = false
      if !isCancellation(error) {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func startDeviceLoginPolling() {
    guard let login = deviceLogin, !isDeviceLoginPolling else {
      return
    }

    isRefreshing = true
    isDeviceLoginPolling = true
    errorMessage = nil
    deviceLoginTask = Task { [weak self] in
      await self?.completeDeviceLogin(login)
    }
  }

  private func completeDeviceLogin(_ login: CodexDeviceCodeLogin) async {
    do {
      _ = try await authStore.completeDeviceCodeLogin(login)
      deviceLogin = nil
      deviceLoginTask = nil
      isDeviceLoginPolling = false
      isCodexSignedIn = true
      await refresh()
    } catch {
      deviceLoginTask = nil
      isDeviceLoginPolling = false
      isRefreshing = false
      if !isCancellation(error) {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  private func loadCachedThenRefresh() async {
    do {
      snapshots = try cache.loadSnapshots()
    } catch {
      errorMessage = error.localizedDescription
    }
    await refresh()
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

struct iOSContentView: View {
  @ObservedObject var store: iOSUsageStore
  @State private var openRouterAPIKey = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          if !store.snapshots.isEmpty {
            ForEach(store.snapshots, id: \.provider) { snapshot in
              iOSUsageSummaryView(
                snapshot: snapshot,
                nextRefreshAt: store.nextRefreshAt,
                showProviderName: true
              )
            }
          } else {
            ContentUnavailableView(
              "No Usage Snapshot",
              systemImage: "gauge.with.dots.needle.bottom.50percent",
              description: Text("Sign in and refresh to fetch provider usage.")
            )
          }
        }

        Section("Settings") {
          if let deviceLogin = store.deviceLogin {
            VStack(alignment: .leading, spacing: 8) {
              Text("Enter this code in Safari")
                .font(.headline)
              Text(deviceLogin.userCode)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .contentShape(Rectangle())
                .onTapGesture {
                  store.copyDeviceCode()
                }
              Text(deviceLogin.verificationURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
              if store.isDeviceLoginPolling {
                ProgressView("Waiting for authorization")
              }
              HStack {
                Button("Open OpenAI") {
                  store.openDeviceLoginPage()
                }
                Button("Check") {
                  store.resumeDeviceLoginIfNeeded()
                }
                Button("Cancel", role: .destructive) {
                  store.cancelDeviceLogin()
                }
              }
            }
            .padding(.vertical, 4)
          }

          Picker("Usage refresh", selection: refreshIntervalBinding) {
            ForEach(CodexMonitorSettings.allowedRefreshIntervalMinutes, id: \.self) { minutes in
              Text("\(minutes) min").tag(minutes)
            }
          }

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

          VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API Key")
            Text(
              store.hasOpenRouterAPIKey
                ? "Stored securely in Keychain" : "No OpenRouter key stored"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            SecureField("sk-or-...", text: $openRouterAPIKey)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            HStack {
              Button("Save") {
                store.saveOpenRouterAPIKey(openRouterAPIKey)
                openRouterAPIKey = ""
              }
              .disabled(openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              Button("Clear", role: .destructive) {
                store.clearOpenRouterAPIKey()
                openRouterAPIKey = ""
              }
              .disabled(!store.hasOpenRouterAPIKey)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Codex Auth")
            Text(store.authStorageDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Button("Clear Auth", role: .destructive) {
            store.clearMonitorAuth()
          }
        }

        if let errorMessage = store.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
      }
      .navigationTitle("Codex Usage")
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          if store.shouldShowCodexSignIn {
            Button {
              store.signIn()
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
      }
      .overlay {
        if store.isRefreshing && store.deviceLogin == nil {
          ProgressView()
            .controlSize(.large)
        }
      }
    }
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

struct iOSUsageSummaryView: View {
  var snapshot: CodexUsageSnapshot
  var nextRefreshAt: Date?
  var showProviderName = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if showProviderName {
        Text(snapshot.displayName)
          .font(.headline)
      }
      if let nextRefreshAt {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text("Next refresh \(CodexRefreshText.remainingText(until: nextRefreshAt, now: context.date))")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }

      if let fiveHour = snapshot.fiveHour {
        iOSUsageWindowView(window: fiveHour)
      }
      if let weekly = snapshot.weekly {
        iOSUsageWindowView(window: weekly)
      }
    }
    .padding(.vertical, 4)
  }

}

struct iOSUsageWindowView: View {
  var window: CodexUsageWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(displayLabel)
          .font(.headline)
        Spacer()
        Text(window.valueText ?? "\(Int(window.remainingPercent.rounded()))%")
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(tint)
      }
      if window.valueText == nil {
        UsageProgressBar(value: window.remainingPercent, tint: tint)
      }
      Text(resetText)
        .font(.callout)
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

struct UsageProgressBar: View {
  var value: Double
  var tint: Color

  private var progress: Double {
    min(max(value / 100, 0), 1)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.18))
        Capsule()
          .fill(tint)
          .frame(width: geometry.size.width * progress)
      }
    }
    .frame(height: 8)
  }
}
