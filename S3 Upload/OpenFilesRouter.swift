import Foundation
import Combine

final class OpenFilesRouter: ObservableObject {
    // URLs handed to the app via “Open With…”, drag from Finder onto app icon, etc.
    @Published var incomingFileURLs: [URL] = []
}
