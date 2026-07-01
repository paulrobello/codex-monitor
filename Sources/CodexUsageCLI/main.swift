import CodexUsageCore
import Darwin
import Foundation

@main
struct CodexUsageCLI {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "refresh"
    let authStore = CodexAuthStore(
      secureStore: CodexKeychainAuthStore(accessGroup: "")
    )
    let openRouterAPIKeyStore = OpenRouterAPIKeyStore(accessGroup: "")
    let cache = CodexUsageCache()
    let settingsStore = CodexSettingsStore()
    let service = CodexMonitorCollectionService(
      settingsStore: settingsStore,
      cache: cache,
      codexAuthStore: authStore,
      openRouterAPIKeyStore: openRouterAPIKeyStore
    )
    let beaconAPIKeyStore = BeaconAPIKeyStore(accessGroup: "")

    do {
      switch command {
      case "login":
        let credentials = try await authStore.login(openAuthorizationURL: openURL)
        print(
          credentials.accountId.map { "Signed in to Codex account \($0)." } ?? "Signed in to Codex."
        )
      case "refresh":
        let snapshots = try await service.refreshNow()
        print(String(data: try JSONEncoder.codexMonitor.encode(snapshots), encoding: .utf8) ?? "[]")
      case "print":
        let snapshots = try cache.loadSnapshots()
        if !snapshots.isEmpty {
          print(
            String(data: try JSONEncoder.codexMonitor.encode(snapshots), encoding: .utf8) ?? "[]")
        } else {
          eprint("No cached Codex usage snapshot at \(cache.cacheURL.path).")
          exit(1)
        }
      case "cache-path":
        print(cache.cacheURL.path)
      case "clear-auth":
        try authStore.clearMonitorCredentials()
        print("Cleared Codex Monitor auth from \(authStore.authStorageDescription).")
      case "interval":
        if let rawValue = arguments.dropFirst().first, let minutes = Int(rawValue) {
          let currentSettings = settingsStore.load()
          let settings = CodexMonitorSettings(
            refreshIntervalMinutes: minutes,
            enabledProviders: currentSettings.enabledProviders,
            beaconAPIEnabled: currentSettings.beaconAPIEnabled,
            beaconAPIPort: currentSettings.beaconAPIPort,
            beaconProviderColors: currentSettings.beaconProviderColors
          )
          try settingsStore.save(settings)
          print("Usage refresh interval set to \(settings.refreshIntervalMinutes) minutes.")
        } else {
          print("\(settingsStore.load().refreshIntervalMinutes)")
        }
      case "providers":
        let settings = settingsStore.load()
        let rawProviders = Array(arguments.dropFirst())
        if rawProviders.isEmpty {
          print(settings.enabledProviders.map(\.rawValue).joined(separator: ","))
        } else {
          let providers = rawProviders.map { rawProvider -> CodexUsageProviderID in
            guard let provider = CodexUsageProviderID(rawValue: rawProvider) else {
              eprint(
                "Unknown provider '\(rawProvider)'. Use one of: "
                  + CodexUsageProviderID.allCases.map(\.rawValue).joined(separator: ", ")
              )
              exit(2)
            }
            return provider
          }
          let nextSettings = CodexMonitorSettings(
            refreshIntervalMinutes: settings.refreshIntervalMinutes,
            enabledProviders: providers,
            beaconAPIEnabled: settings.beaconAPIEnabled,
            beaconAPIPort: settings.beaconAPIPort,
            beaconProviderColors: settings.beaconProviderColors
          )
          try settingsStore.save(nextSettings)
          print(nextSettings.enabledProviders.map(\.rawValue).joined(separator: ","))
        }
      case "service-status":
        let status = await service.status()
        print(String(data: try JSONEncoder.codexMonitor.encode(status), encoding: .utf8) ?? "{}")
      case "api-enabled":
        let settings = settingsStore.load()
        if let rawValue = arguments.dropFirst().first {
          let enabled = rawValue == "true" || rawValue == "on" || rawValue == "1"
          let nextSettings = CodexMonitorSettings(
            refreshIntervalMinutes: settings.refreshIntervalMinutes,
            enabledProviders: settings.enabledProviders,
            beaconAPIEnabled: enabled,
            beaconAPIPort: settings.beaconAPIPort,
            beaconProviderColors: settings.beaconProviderColors
          )
          try settingsStore.save(nextSettings)
          print(enabled ? "on" : "off")
        } else {
          print(settings.beaconAPIEnabled ? "on" : "off")
        }
      case "api-key":
        if arguments.dropFirst().first == "rotate" {
          try beaconAPIKeyStore.clear()
        }
        print(try beaconAPIKeyStore.currentOrCreateAPIKey())
      default:
        eprint(
          "usage: codex-usage [login|refresh|print|cache-path|clear-auth|interval [minutes]|providers [provider ...]|service-status|api-enabled [on|off]|api-key [rotate]]"
        )
        exit(2)
      }
    } catch {
      eprint(error.localizedDescription)
      exit(1)
    }
  }

  private static func eprint(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
  }

  private static func openURL(_ url: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw CodexUsageError.oauthCallbackFailed("could not open browser")
    }
  }
}
