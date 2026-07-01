import CodexUsageCore
import Foundation

@main
struct CodexMonitorServiceApp {
  static func main() async {
    let settingsStore = CodexSettingsStore()
    let service = CodexMonitorCollectionService(settingsStore: settingsStore)
    var server: BeaconHTTPServer?
    var activePort: Int?

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
}
