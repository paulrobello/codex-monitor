import CodexUsageCore
import SwiftUI
import UIKit
import WidgetKit

@main
struct CodexMonitoriOSApp: App {
  @StateObject private var store = iOSUsageStore()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    loadRocketSimConnect()
  }

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

  private func loadRocketSimConnect() {
    #if DEBUG
    guard (Bundle(path: "/Applications/RocketSim.app/Contents/Frameworks/RocketSimConnectLinker.nocache.framework")?.load() == true) else {
      print("Failed to load linker framework")
      return
    }
    print("RocketSim Connect successfully linked")
    #endif
  }
}

@MainActor
final class iOSUsageStore: ObservableObject {
  private static let supportedProviders: [CodexUsageProviderID] = [.openAICodex, .openRouter]

  @Published var snapshots: [CodexUsageSnapshot] = []
  @Published var isRefreshing = false
  @Published private(set) var isCodexSignedIn = false
  @Published private(set) var hasOpenRouterAPIKey = false
  @Published private(set) var openRouterAPIKeys: [OpenRouterAPIKeyDescriptor] = []
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
    let loadedSettings = CodexSettingsStore().load()
    let supportedSettings = Self.settingsWithSupportedProviders(loadedSettings)
    self.settings = supportedSettings
    self.isCodexSignedIn = authStore.hasCredentials()
    let openRouterKeys = (try? openRouterAPIKeyStore.loadAPIKeyDescriptors()) ?? []
    self.openRouterAPIKeys = openRouterKeys
    self.hasOpenRouterAPIKey = !openRouterKeys.isEmpty
    if supportedSettings != loadedSettings {
      try? settingsStore.save(supportedSettings)
    }
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

  var displayedSnapshots: [CodexUsageSnapshot] {
    snapshots.filteringDisabledProviders(settings: settings)
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
      refreshOpenRouterAPIKeyState()
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      isCodexSignedIn = authStore.hasCredentials()
      refreshOpenRouterAPIKeyState()
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
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits
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
    guard Self.supportedProviders.contains(provider) else {
      return
    }
    var providers = settings.enabledProviders
    if enabled {
      providers.append(provider)
    } else {
      providers.removeAll { $0 == provider }
    }
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: providers,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits
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

  private static func settingsWithSupportedProviders(_ settings: CodexMonitorSettings)
    -> CodexMonitorSettings
  {
    CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders.filter { supportedProviders.contains($0) },
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits
    )
  }

  private func saveSettings(_ nextSettings: CodexMonitorSettings) {
    do {
      try settingsStore.save(nextSettings)
      settings = nextSettings
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setOpenRouterKeyUsageVisible(_ visible: Bool) {
    let hideKeyUsage = !visible
    let hideCredits = hideKeyUsage && settings.hideOpenRouterCredits ? false : settings.hideOpenRouterCredits
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: hideKeyUsage,
      hideOpenRouterCredits: hideCredits
    )
    saveSettings(nextSettings)
  }

  func setOpenRouterCreditsVisible(_ visible: Bool) {
    let hideCredits = !visible
    let hideKeyUsage = hideCredits && settings.hideOpenRouterKeyUsage ? false : settings.hideOpenRouterKeyUsage
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: hideKeyUsage,
      hideOpenRouterCredits: hideCredits
    )
    saveSettings(nextSettings)
  }

  func saveOpenRouterAPIKey(_ apiKey: String) {
    saveOpenRouterAPIKey(label: "", apiKey: apiKey)
  }

  func saveOpenRouterAPIKey(label: String, apiKey: String) {
    do {
      try openRouterAPIKeyStore.save(label: label, apiKey: apiKey)
      refreshOpenRouterAPIKeyState()
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func renameOpenRouterAPIKey(id: String, label: String) {
    do {
      try openRouterAPIKeyStore.updateLabel(id: id, label: label)
      refreshOpenRouterAPIKeyState()
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearOpenRouterAPIKey() {
    do {
      try openRouterAPIKeyStore.clear()
      refreshOpenRouterAPIKeyState()
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func removeOpenRouterAPIKey(id: String) {
    do {
      try openRouterAPIKeyStore.removeAPIKey(id: id)
      refreshOpenRouterAPIKeyState()
      errorMessage = nil
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refreshOpenRouterAPIKeyState() {
    openRouterAPIKeys = (try? openRouterAPIKeyStore.loadAPIKeyDescriptors()) ?? []
    hasOpenRouterAPIKey = !openRouterAPIKeys.isEmpty
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
  @State private var openRouterAPIKeyLabel = ""
  @State private var openRouterAPIKey = ""
  @State private var openRouterLabelEdits: [String: String] = [:]

  var body: some View {
    NavigationStack {
      List {
        Section {
          if !store.displayedSnapshots.isEmpty {
            ForEach(store.displayedSnapshots, id: \.instanceID) { snapshot in
              iOSUsageSummaryView(
                snapshot: snapshot,
                nextRefreshAt: store.nextRefreshAt,
                showProviderName: true,
                hideOpenRouterKeyUsage: store.settings.hideOpenRouterKeyUsage,
                hideOpenRouterCredits: store.settings.hideOpenRouterCredits
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

          VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API Keys")
            Text(
              store.hasOpenRouterAPIKey
                ? "\(store.openRouterAPIKeys.count) key label(s) available" : "No OpenRouter key stored"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Toggle("Show OpenRouter Key Usage", isOn: openRouterKeyUsageBinding)
              .disabled(!store.settings.hideOpenRouterKeyUsage && store.settings.hideOpenRouterCredits)
            Toggle("Show OpenRouter Credits", isOn: openRouterCreditsBinding)
              .disabled(store.settings.hideOpenRouterKeyUsage && !store.settings.hideOpenRouterCredits)
            if !store.openRouterAPIKeys.isEmpty {
              ForEach(store.openRouterAPIKeys) { descriptor in
                VStack(alignment: .leading, spacing: 6) {
                  TextField("Key label", text: openRouterLabelBinding(for: descriptor))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(descriptor.isEnvironment)
                  if descriptor.isEnvironment {
                    Label("Environment", systemImage: "terminal")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  HStack {
                    Button("Save Label") {
                      store.renameOpenRouterAPIKey(id: descriptor.id, label: editedOpenRouterLabel(for: descriptor))
                      openRouterLabelEdits[descriptor.id] = nil
                    }
                    .disabled(openRouterLabelSaveDisabled(for: descriptor))
                    Button("Remove", role: .destructive) {
                      store.removeOpenRouterAPIKey(id: descriptor.id)
                      openRouterLabelEdits[descriptor.id] = nil
                    }
                    .disabled(descriptor.isEnvironment)
                  }
                }
              }
            }
            Text("Add OpenRouter API Key")
              .font(.subheadline)
            TextField("New key label (optional)", text: $openRouterAPIKeyLabel)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            SecureField("sk-or-...", text: $openRouterAPIKey)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            HStack {
              Button("Add Key") {
                store.saveOpenRouterAPIKey(label: openRouterAPIKeyLabel, apiKey: openRouterAPIKey)
                openRouterAPIKeyLabel = ""
                openRouterAPIKey = ""
              }
              .disabled(openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              Button("Clear Stored", role: .destructive) {
                store.clearOpenRouterAPIKey()
                openRouterAPIKeyLabel = ""
                openRouterAPIKey = ""
                openRouterLabelEdits = [:]
              }
              .disabled(!hasStoredOpenRouterAPIKeys)
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

  private var openRouterKeyUsageBinding: Binding<Bool> {
    Binding(
      get: { !store.settings.hideOpenRouterKeyUsage },
      set: { store.setOpenRouterKeyUsageVisible($0) }
    )
  }

  private var openRouterCreditsBinding: Binding<Bool> {
    Binding(
      get: { !store.settings.hideOpenRouterCredits },
      set: { store.setOpenRouterCreditsVisible($0) }
    )
  }

  private var hasStoredOpenRouterAPIKeys: Bool {
    store.openRouterAPIKeys.contains { !$0.isEnvironment }
  }

  private func openRouterLabelBinding(for descriptor: OpenRouterAPIKeyDescriptor) -> Binding<String> {
    Binding(
      get: { openRouterLabelEdits[descriptor.id] ?? descriptor.label },
      set: { openRouterLabelEdits[descriptor.id] = $0 }
    )
  }

  private func editedOpenRouterLabel(for descriptor: OpenRouterAPIKeyDescriptor) -> String {
    openRouterLabelEdits[descriptor.id] ?? descriptor.label
  }

  private func openRouterLabelSaveDisabled(for descriptor: OpenRouterAPIKeyDescriptor) -> Bool {
    descriptor.isEnvironment
      || editedOpenRouterLabel(for: descriptor).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || editedOpenRouterLabel(for: descriptor) == descriptor.label
  }
}

struct iOSUsageSummaryView: View {
  var snapshot: CodexUsageSnapshot
  var nextRefreshAt: Date?
  var showProviderName = false
  var hideOpenRouterKeyUsage = false
  var hideOpenRouterCredits = false

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

      if let fiveHour = visibleFiveHourWindow {
        iOSUsageWindowView(window: fiveHour)
      }
      if let weekly = visibleWeeklyWindow {
        iOSUsageWindowView(window: weekly)
      }
    }
    .padding(.vertical, 4)
  }

  private var visibleFiveHourWindow: CodexUsageWindow? {
    guard !isOpenRouterKeyUsageWindow else {
      return nil
    }
    return snapshot.fiveHour
  }

  private var visibleWeeklyWindow: CodexUsageWindow? {
    guard !isOpenRouterCreditsWindow else {
      return nil
    }
    return snapshot.weekly
  }

  private var isOpenRouterKeyUsageWindow: Bool {
    hideOpenRouterKeyUsage
      && snapshot.provider == CodexUsageProviderID.openRouter.rawValue
      && isOpenRouterKeyUsageLabel(snapshot.fiveHour?.label)
  }

  private func isOpenRouterKeyUsageLabel(_ label: String?) -> Bool {
    label == "Key limit" || label == "Key usage"
  }

  private var isOpenRouterCreditsWindow: Bool {
    hideOpenRouterCredits
      && snapshot.provider == CodexUsageProviderID.openRouter.rawValue
      && snapshot.weekly?.label == "Credits"
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
      if showsProgressBar {
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

  private var showsProgressBar: Bool {
    window.valueText == nil || window.label.hasSuffix("limit")
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
