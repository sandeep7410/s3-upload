import SwiftUI

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

@main
struct S3UploadApp: App {
    @StateObject private var openFilesRouter = OpenFilesRouter()

    init() {
        debugLog("App init")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(openFilesRouter)
                .onAppear {
                    debugLog("WindowGroup ContentView onAppear")
                }
        }
        .windowStyle(.titleBar)

        // macOS Settings window
        Settings {
            SettingsView()
        }
    }
}
