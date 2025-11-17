import SwiftUI

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

@main
struct S3UploadApp: App {
    @StateObject private var openFilesRouter = OpenFilesRouter()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        debugLog("App init")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(openFilesRouter)
                .onAppear {
                    debugLog("WindowGroup ContentView onAppear")
                    // Ensure delegate can forward “Open With…” URLs into the same router
                    appDelegate.setRouter(openFilesRouter)
                }
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
        }
    }
}
