import SwiftUI

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

@main
struct video_thumbnailApp: App {
    init() {
        debugLog("App init")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    debugLog("WindowGroup ContentView onAppear")
                }
        }
        .windowStyle(.titleBar)
    }
}
