import CodexUsageCore
import Darwin
import ServiceManagement
import SwiftUI
import WidgetKit

@main
struct CodexMonitorApp: App {
  @StateObject private var store = UsageStore()

  init() {
    CodexMonitorServiceCommand.handleIfNeeded()
  }

  var body: some Scene {
    WindowGroup("Codex Monitor") {
      ContentView(store: store)
        .frame(minWidth: 420, minHeight: store.displayedSnapshots.count <= 1 ? 260 : 320)
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
      if !store.displayedSnapshots.isEmpty {
        ForEach(store.displayedSnapshots, id: \.instanceID) { snapshot in
          UsageSummaryView(
            snapshot: snapshot,
            compact: true,
            showProviderName: true,
            hideOpenRouterKeyUsage: store.settings.hideOpenRouterKeyUsage,
            hideOpenRouterCredits: store.settings.hideOpenRouterCredits
          )
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

enum CodexMonitorServiceCommand {
  static func handleIfNeeded(arguments: [String] = CommandLine.arguments) {
    guard let command = arguments.dropFirst().first else {
      return
    }
    do {
      switch command {
      case "--register-service":
        try CodexMonitorServiceLifecycle.registerOrRestart()
        print("CodexMonitorService login item enabled.")
        Darwin.exit(EXIT_SUCCESS)
      case "--unregister-service":
        let wasEnabled = CodexMonitorServiceLifecycle.isEnabled
        try CodexMonitorServiceLifecycle.unregister()
        print(
          wasEnabled
            ? "CodexMonitorService login item unregistered."
            : "CodexMonitorService login item already unregistered."
        )
        Darwin.exit(EXIT_SUCCESS)
      default:
        return
      }
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      Darwin.exit(EXIT_FAILURE)
    }
  }
}

enum CodexMonitorServiceLifecycle {
  private static let serviceIdentifier = "net.pardev.CodexMonitor.Service"

  static var isEnabled: Bool {
    service.status == .enabled
  }

  static func registerOrRestart() throws {
    let loginItem = service
    if loginItem.status == .enabled {
      try loginItem.unregister()
    }
    try service.register()
    guard isEnabled else {
      throw ServiceLifecycleError.unexpectedStatus(service.status)
    }
  }

  static func unregister() throws {
    let loginItem = service
    guard loginItem.status != .notRegistered else {
      return
    }
    try loginItem.unregister()
  }

  private static var service: SMAppService {
    SMAppService.loginItem(identifier: serviceIdentifier)
  }

  private enum ServiceLifecycleError: LocalizedError {
    case unexpectedStatus(SMAppService.Status)

    var errorDescription: String? {
      switch self {
      case .unexpectedStatus(let status):
        return "CodexMonitorService login item lifecycle ended with status \(status)."
      }
    }
  }
}

@MainActor
final class UsageStore: ObservableObject {
  @Published var snapshots: [CodexUsageSnapshot] = []
  @Published var isRefreshing = false
  @Published private(set) var isCodexSignedIn = false
  @Published private(set) var hasOpenRouterAPIKey = false
  @Published private(set) var openRouterAPIKeys: [OpenRouterAPIKeyDescriptor] = []
  @Published var errorMessage: String?
  @Published private(set) var settings: CodexMonitorSettings
  @Published private(set) var nextRefreshAt: Date?
  @Published private(set) var beaconAPIURLText = "Beacon API disabled"
  @Published private(set) var hasBeaconAPIKey = false
  @Published private(set) var serviceLaunchAtLoginEnabled = false

  private let authStore = CodexAuthStore()
  private let openRouterAPIKeyStore = OpenRouterAPIKeyStore()
  private let service = CodexMonitorCollectionService()
  private let settingsStore = CodexSettingsStore()
  private let beaconAPIKeyStore = BeaconAPIKeyStore()
  private var refreshLoop: Task<Void, Never>?

  init() {
    self.settings = CodexSettingsStore().load()
    self.isCodexSignedIn = authStore.hasCredentials()
    let openRouterKeys = (try? openRouterAPIKeyStore.loadAPIKeyDescriptors()) ?? []
    self.openRouterAPIKeys = openRouterKeys
    self.hasOpenRouterAPIKey = !openRouterKeys.isEmpty
    self.serviceLaunchAtLoginEnabled = CodexMonitorServiceLifecycle.isEnabled
    self.hasBeaconAPIKey = (try? beaconAPIKeyStore.currentOrCreateAPIKey()) != nil
    self.beaconAPIURLText = Self.serviceEndpointText(
      settings: settings,
      serviceLaunchAtLoginEnabled: serviceLaunchAtLoginEnabled
    )
    syncOpenRouterAPIKeyDescriptors(openRouterKeys)
  }

  deinit {
    refreshLoop?.cancel()
  }

  var menuBarSymbolName: String {
    guard
      let lowestRemaining = [
        displayedSnapshots.flatMap { [$0.fiveHour?.remainingPercent, $0.weekly?.remainingPercent] }
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

  var displayedSnapshots: [CodexUsageSnapshot] {
    snapshots.filteringDisabledProviders(settings: settings)
  }

  func start() {
    WidgetCenter.shared.reloadAllTimelines()
    syncServiceLaunchStateIfNeeded()
    restartRefreshLoop(runImmediately: true)
  }

  func loadCachedThenRefresh() async {
    await loadCached()
    await refresh()
  }

  func loadCached() async {
    do {
      snapshots = try await service.cachedSnapshots()
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
      let nextSnapshots = try await service.refreshNow()
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
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits,
      openRouterAPIKeyDescriptors: settings.openRouterAPIKeyDescriptors
    )
    saveSettingsAndApplyBeaconAPI(nextSettings)
    nextRefreshAt = nextSettings.nextRefreshDate(after: Date())
    WidgetCenter.shared.reloadAllTimelines()
    restartRefreshLoop(runImmediately: false)
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
      enabledProviders: providers,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits,
      openRouterAPIKeyDescriptors: settings.openRouterAPIKeyDescriptors
    )
    saveSettingsAndApplyBeaconAPI(nextSettings)
    WidgetCenter.shared.reloadAllTimelines()
    Task {
      await refresh()
    }
  }

  func setBeaconAPIEnabled(_ enabled: Bool) {
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: enabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits,
      openRouterAPIKeyDescriptors: settings.openRouterAPIKeyDescriptors
    )
    saveSettingsAndApplyBeaconAPI(nextSettings)
  }

  func setBeaconAPIPort(_ port: Int) {
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: port,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits,
      openRouterAPIKeyDescriptors: settings.openRouterAPIKeyDescriptors
    )
    saveSettingsAndApplyBeaconAPI(nextSettings)
  }

  func setBeaconAccentColor(_ color: BeaconRGB, for provider: CodexUsageProviderID) {
    var providerColors = settings.beaconProviderColors
    providerColors[provider.rawValue] = color
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: providerColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits,
      openRouterAPIKeyDescriptors: settings.openRouterAPIKeyDescriptors
    )
    saveSettingsAndApplyBeaconAPI(nextSettings)
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
      hideOpenRouterCredits: hideCredits,
      openRouterAPIKeyDescriptors: settings.openRouterAPIKeyDescriptors
    )
    saveSettingsAndApplyBeaconAPI(nextSettings)
    WidgetCenter.shared.reloadAllTimelines()
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
      hideOpenRouterCredits: hideCredits,
      openRouterAPIKeyDescriptors: settings.openRouterAPIKeyDescriptors
    )
    saveSettingsAndApplyBeaconAPI(nextSettings)
    WidgetCenter.shared.reloadAllTimelines()
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

  func setServiceLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try CodexMonitorServiceLifecycle.registerOrRestart()
      } else {
        try CodexMonitorServiceLifecycle.unregister()
      }
      updateBeaconAPIState(restartServiceIfNeeded: false)
    } catch {
      refreshServiceLaunchState()
      updateBeaconAPIState(restartServiceIfNeeded: false)
      errorMessage = error.localizedDescription
    }
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
    let descriptors = (try? openRouterAPIKeyStore.loadAPIKeyDescriptors()) ?? []
    openRouterAPIKeys = descriptors
    hasOpenRouterAPIKey = !descriptors.isEmpty
    syncOpenRouterAPIKeyDescriptors(descriptors)
  }

  private func syncOpenRouterAPIKeyDescriptors(_ descriptors: [OpenRouterAPIKeyDescriptor]) {
    let nextSettings = CodexMonitorSettings(
      refreshIntervalMinutes: settings.refreshIntervalMinutes,
      enabledProviders: settings.enabledProviders,
      beaconAPIEnabled: settings.beaconAPIEnabled,
      beaconAPIPort: settings.beaconAPIPort,
      beaconProviderColors: settings.beaconProviderColors,
      hideOpenRouterKeyUsage: settings.hideOpenRouterKeyUsage,
      hideOpenRouterCredits: settings.hideOpenRouterCredits,
      openRouterAPIKeyDescriptors: descriptors
    )
    do {
      try settingsStore.save(nextSettings)
      settings = nextSettings
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

  private func saveSettingsAndApplyBeaconAPI(_ nextSettings: CodexMonitorSettings) {
    do {
      try settingsStore.save(nextSettings)
      settings = nextSettings
      updateBeaconAPIState()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func updateBeaconAPIState(restartServiceIfNeeded: Bool = true) {
    if settings.beaconAPIEnabled {
      do {
        _ = try beaconAPIKeyStore.currentOrCreateAPIKey()
        hasBeaconAPIKey = true
      } catch {
        errorMessage = error.localizedDescription
      }
    }
    if restartServiceIfNeeded {
      syncServiceLaunchStateIfNeeded()
    } else {
      refreshServiceLaunchState()
    }
    beaconAPIURLText = Self.serviceEndpointText(
      settings: settings,
      serviceLaunchAtLoginEnabled: serviceLaunchAtLoginEnabled
    )
  }

  private func syncServiceLaunchStateIfNeeded() {
    refreshServiceLaunchState()
    if serviceLaunchAtLoginEnabled && settings.beaconAPIEnabled {
      do {
        try CodexMonitorServiceLifecycle.registerOrRestart()
        refreshServiceLaunchState()
      } catch {
        refreshServiceLaunchState()
        errorMessage = error.localizedDescription
      }
    }
  }

  private func refreshServiceLaunchState() {
    serviceLaunchAtLoginEnabled = CodexMonitorServiceLifecycle.isEnabled
  }

  private static func serviceEndpointText(
    settings: CodexMonitorSettings,
    serviceLaunchAtLoginEnabled: Bool
  ) -> String {
    guard settings.beaconAPIEnabled else {
      return "Beacon API disabled"
    }
    let localURL = "http://localhost:\(settings.beaconAPIPort)"
    guard serviceLaunchAtLoginEnabled else {
      return "Enable launch service to serve \(localURL)"
    }
    guard let host = firstLANIPv4Address() else {
      return "Beacon API service: \(localURL); use this Mac's LAN IP for Beacon firmware"
    }
    return "Beacon API service: http://\(host):\(settings.beaconAPIPort) (local: \(localURL))"
  }

  private static func firstLANIPv4Address() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return nil
    }
    defer {
      freeifaddrs(interfaces)
    }

    var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let interface = cursor {
      defer {
        cursor = interface.pointee.ifa_next
      }
      let flags = Int32(interface.pointee.ifa_flags)
      guard
        flags & IFF_UP == IFF_UP,
        flags & IFF_LOOPBACK == 0,
        interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        interface.pointee.ifa_addr,
        socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      if result == 0 {
        return String(cString: hostname)
      }
    }
    return nil
  }
}

struct ContentView: View {
  @ObservedObject var store: UsageStore

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          if let nextRefreshAt = store.nextRefreshAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text("Next refresh \(CodexRefreshText.remainingText(until: nextRefreshAt, now: context.date))")
            }
            .foregroundStyle(.secondary)
          } else {
            Text("No cached snapshot")
              .foregroundStyle(.secondary)
          }
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

      if !store.displayedSnapshots.isEmpty {
        ForEach(store.displayedSnapshots, id: \.instanceID) { snapshot in
          UsageSummaryView(
            snapshot: snapshot,
            showProviderName: true,
            hideOpenRouterKeyUsage: store.settings.hideOpenRouterKeyUsage,
            hideOpenRouterCredits: store.settings.hideOpenRouterCredits
          )
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

}

struct SettingsView: View {
  @ObservedObject var store: UsageStore
  @State private var openRouterAPIKeyLabel = ""
  @State private var openRouterAPIKey = ""
  @State private var openRouterLabelEdits: [String: String] = [:]

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
            Text("OpenRouter API Keys")
              .font(.headline)
            Text(
              store.hasOpenRouterAPIKey
                ? "\(store.openRouterAPIKeys.count) key label(s) available" : "No OpenRouter key stored"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Clear Stored", role: .destructive) {
            store.clearOpenRouterAPIKey()
            openRouterAPIKeyLabel = ""
            openRouterAPIKey = ""
            openRouterLabelEdits = [:]
          }
          .disabled(!hasStoredOpenRouterAPIKeys)
        }
        if !store.openRouterAPIKeys.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(store.openRouterAPIKeys) { descriptor in
              HStack {
                TextField("Key label", text: openRouterLabelBinding(for: descriptor))
                  .textFieldStyle(.roundedBorder)
                  .disabled(descriptor.isEnvironment)
                if descriptor.isEnvironment {
                  Label("Environment", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
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
        Toggle("Show OpenRouter Key Usage", isOn: openRouterKeyUsageBinding)
          .disabled(!store.settings.hideOpenRouterKeyUsage && store.settings.hideOpenRouterCredits)
        Toggle("Show OpenRouter Credits", isOn: openRouterCreditsBinding)
          .disabled(store.settings.hideOpenRouterKeyUsage && !store.settings.hideOpenRouterCredits)
        Divider()
        VStack(alignment: .leading, spacing: 6) {
          Text("Add OpenRouter API Key")
            .font(.subheadline)
          TextField("New key label (optional)", text: $openRouterAPIKeyLabel)
            .textFieldStyle(.roundedBorder)
          SecureField("sk-or-...", text: $openRouterAPIKey)
            .textFieldStyle(.roundedBorder)
          Button("Add Key") {
            store.saveOpenRouterAPIKey(label: openRouterAPIKeyLabel, apiKey: openRouterAPIKey)
            openRouterAPIKeyLabel = ""
            openRouterAPIKey = ""
          }
          .disabled(openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }

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
        VStack(alignment: .leading, spacing: 6) {
          Text("Card Colors")
            .font(.subheadline)
          ForEach(CodexUsageProviderID.allCases, id: \.self) { provider in
            ColorPicker(provider.displayName, selection: beaconColorBinding(provider), supportsOpacity: false)
          }
        }
        Button("Regenerate API Key") {
          store.regenerateBeaconAPIKey()
        }
        .disabled(!store.settings.beaconAPIEnabled)
        Toggle("Launch service at login", isOn: serviceLaunchAtLoginBinding)
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

  private var beaconAPIEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.settings.beaconAPIEnabled },
      set: { store.setBeaconAPIEnabled($0) }
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

  private var beaconAPIPortBinding: Binding<Int> {
    Binding(
      get: { store.settings.beaconAPIPort },
      set: { store.setBeaconAPIPort($0) }
    )
  }

  private func beaconColorBinding(_ provider: CodexUsageProviderID) -> Binding<Color> {
    Binding(
      get: { store.settings.beaconAccentColor(for: provider).swiftUIColor },
      set: { store.setBeaconAccentColor(BeaconRGB(color: $0), for: provider) }
    )
  }

  private var serviceLaunchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { store.serviceLaunchAtLoginEnabled },
      set: { store.setServiceLaunchAtLogin($0) }
    )
  }
}

private extension BeaconRGB {
  init(color: Color) {
    let color = NSColor(color).usingColorSpace(.sRGB) ?? .white
    self.init(
      red: Self.byte(from: color.redComponent),
      green: Self.byte(from: color.greenComponent),
      blue: Self.byte(from: color.blueComponent)
    )
  }

  var swiftUIColor: Color {
    Color(
      red: Double(red) / 255.0,
      green: Double(green) / 255.0,
      blue: Double(blue) / 255.0
    )
  }

  private static func byte(from component: CGFloat) -> Int {
    max(0, min(255, Int((Double(component) * 255.0).rounded())))
  }
}

struct UsageSummaryView: View {
  var snapshot: CodexUsageSnapshot
  var compact = false
  var showProviderName = false
  var hideOpenRouterKeyUsage = false
  var hideOpenRouterCredits = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 10 : 14) {
      if showProviderName {
        Text(snapshot.displayName)
          .font(compact ? .subheadline.weight(.semibold) : .headline.weight(.semibold))
      }
      if let fiveHour = visibleFiveHourWindow {
        UsageWindowView(
          window: fiveHour,
          tint: color(for: fiveHour.remainingPercent),
          compact: compact,
          forcePercentDisplay: snapshot.provider == CodexUsageProviderID.claudeCode.rawValue)
      }
      if let weekly = visibleWeeklyWindow {
        UsageWindowView(
          window: weekly,
          tint: color(for: weekly.remainingPercent),
          compact: compact,
          forcePercentDisplay: snapshot.provider == CodexUsageProviderID.claudeCode.rawValue)
      }
    }
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
  var forcePercentDisplay = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(displayLabel)
          .font(compact ? .body : .headline)
        Spacer()
        Text(displayValueText)
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

  private var resetText: String {
    if let detail = window.detail {
      return detail
    }
    guard let resetAt = window.resetAt else {
      return "Reset time unavailable"
    }
    return CodexResetText.string(resetAt: resetAt)
  }

  private var displayValueText: String {
    if forcePercentDisplay {
      return "\(Int(window.remainingPercent.rounded()))%"
    }
    return window.valueText ?? "\(Int(window.remainingPercent.rounded()))%"
  }

  private var showsProgressBar: Bool {
    forcePercentDisplay || window.valueText == nil || window.label.hasSuffix("limit")
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
