import CodexUsageCore
import Foundation
import WidgetKit

@main
struct CodexMonitorServiceApp {
  static func main() async {
    let settingsStore = CodexSettingsStore()
    let service = CodexMonitorCollectionService(settingsStore: settingsStore)
    let refreshTask = Task {
      await runRefreshLoop(service: service, settingsStore: settingsStore)
    }
    var server: BeaconHTTPServer?
    var activePort: Int?
    defer { refreshTask.cancel() }

    while !Task.isCancelled {
      let settings = settingsStore.load()
      if settings.beaconAPIEnabled {
        if activePort != settings.beaconAPIPort || server == nil {
          server?.stop()
          do {
            let keyStore = BeaconAPIKeyStore()
            _ = try keyStore.currentOrCreateAPIKey()
            let handler = BeaconHTTPRequestHandler(service: service, apiKeyValidator: keyStore)
            let nextServer = BeaconHTTPServer(handler: handler)
            try nextServer.start(port: UInt16(settings.beaconAPIPort))
            server = nextServer
            activePort = settings.beaconAPIPort
          } catch {
            server = nil
            activePort = nil
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
          }
        }
      } else {
        server?.stop()
        server = nil
        activePort = nil
      }
      try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    server?.stop()
  }

  private static func runRefreshLoop(
    service: CodexMonitorCollectionService,
    settingsStore: CodexSettingsStore
  ) async {
    while !Task.isCancelled {
      do {
        _ = try await service.refreshNow()
        WidgetCenter.shared.reloadAllTimelines()
      } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      }

      let interval = settingsStore.load().refreshIntervalSeconds
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
  }
}
