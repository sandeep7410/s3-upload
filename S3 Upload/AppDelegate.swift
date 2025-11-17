import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    // We need a reference to the same router that the SwiftUI hierarchy uses.
    // We’ll publish it via NotificationCenter so S3UploadApp can pass it in.
    private var router: OpenFilesRouter?

    func setRouter(_ router: OpenFilesRouter) {
        self.router = router
    }

    // Called when the app is launched by opening files, or when files are sent to a running app.
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let router = self.router else { return }
            // Append and notify ContentView
            router.incomingFileURLs.append(contentsOf: urls)
        }
    }

    // Optional: support legacy single-file open
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        application(NSApp, open: [url])
        return true
    }
}
