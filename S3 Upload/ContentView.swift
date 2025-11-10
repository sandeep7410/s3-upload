import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

struct UploadItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case uploading
        case completed
        case failed(String)
        case cancelled
    }
    let id = UUID()
    let url: URL
    var fileName: String { url.lastPathComponent }
    var state: State = .queued
    var progress: Double? = nil // 0...1 if determinate; nil for indeterminate
    var startTime: Date? = nil
    var endTime: Date? = nil

    var elapsedText: String {
        let end = endTime ?? Date()
        guard let start = startTime else { return "" }
        let interval = end.timeIntervalSince(start)
        return Self.formatInterval(interval)
    }

    static func formatInterval(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.1fs", interval)
        } else {
            let minutes = Int(interval) / 60
            let seconds = Int(interval) % 60
            return String(format: "%dm %02ds", minutes, seconds)
        }
    }
}

struct ContentView: View {
    // Queue of files
    @State private var uploadQueue: [UploadItem] = []

    // Output and status
    @State private var outputText: String = "Drop files to upload to S3."
    @State private var isRunning: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var runError: String?
    @State private var s3Path: String = ""
    @State private var uploadProgress: Double? = nil // legacy overall progress (not used now)

    // Collapsible output
    @State private var isOutputExpanded: Bool = false

    private let fileUploader = FileUploader()
    private let s3Service = S3Service()

    // Approximate 10 cm height in points
    private let tenCentimetersPoints: CGFloat = 380

    var body: some View {
        VStack(spacing: 16) {
            Text("S3 Upload")
                .font(.largeTitle)
                .padding(.top, 24)

            // Clickable + droppable area
            Button {
                debugLog("Drop area clicked -> opening file importer")
                showFileImporter = true
            } label: {
                dropArea
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: 200)
            .padding(.horizontal)

            // Selected files list
            if !uploadQueue.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files to upload (\(uploadQueue.count))")
                        .font(.headline)

                    ForEach($uploadQueue) { $item in
                        HStack(spacing: 12) {
                            // Remove or cancel button
                            if isUploading(item) {
                                Button {
                                    debugLog("Cancel upload tapped for \(item.fileName)")
                                    cancelCurrentUpload()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .help("Cancel this upload")
                            } else {
                                Button {
                                    debugLog("Remove item tapped for \(item.fileName)")
                                    removeItem(item)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .help("Remove from list")
                                .disabled(isRunning) // prevent removing while running sequence
                            }

                            // File name
                            Text(item.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            // Progress and elapsed time
                            Group {
                                switch item.state {
                                case .queued:
                                    Text("Queued")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                case .uploading:
                                    if let p = item.progress {
                                        ProgressView(value: p)
                                            .frame(width: 160)
                                    } else {
                                        ProgressView()
                                            .frame(width: 160)
                                    }
                                    Text(item.elapsedText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                case .completed:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(item.elapsedText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                case .failed(let message):
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(item.elapsedText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help(message)
                                case .cancelled:
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(item.elapsedText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal)
            }

            // S3 browser; disabled while running to prevent selection changes
            S3Browser(selectedPath: $s3Path)
                .disabled(isRunning)
                .frame(maxHeight: tenCentimetersPoints)

            if let runError {
                Text(runError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            // Collapsible output
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        isOutputExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isOutputExpanded ? "chevron.down" : "chevron.right")
                            Text("Output")
                                .font(.headline)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                if isOutputExpanded && shouldShowOutputEditor {
                    TextEditor(text: $outputText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                        .padding()
                        .border(Color.gray.opacity(0.5), width: 1)
                }
            }
            .padding(.horizontal)

            // Bottom action button: Upload or Reset
            HStack {
                Spacer()
                if shouldShowResetButton {
                    Button {
                        resetAll()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                            Text("Reset")
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    Button {
                        debugLog("Bottom Upload tapped")
                        startSequentialUploads()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Upload")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canStartUploadButton)
                    .padding(.vertical, 8)
                }
                Spacer()
            }

            Spacer()
        }
        .padding(.bottom, 24)
        .frame(minWidth: 640, minHeight: 720)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            debugLog("fileImporter result received")
            switch result {
            case .success(let urls):
                debugLog("fileImporter success. urls.count=\(urls.count)")
                addSelectedFiles(urls)
            case .failure(let error):
                debugLog("fileImporter failure. error=\(error.localizedDescription)")
                runError = error.localizedDescription
            }
        }
        .onAppear {
            debugLog("ContentView appeared")
        }
        .onChange(of: s3Path) { _, _ in
            // Do not auto-start anymore; user controls via bottom button
        }
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.blue.opacity(0.1))

            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("Drag & drop files here, or click to choose")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            debugLog("onDrop called. providers.count=\(providers.count)")
            var urls: [URL] = []
            let group = DispatchGroup()

            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { object, error in
                    if let error {
                        debugLog("loadObject error: \(error.localizedDescription)")
                    } else if let url = object {
                        urls.append(url)
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                if !urls.isEmpty {
                    addSelectedFiles(urls)
                } else {
                    runError = "Unable to read dropped files."
                }
            }

            return true
        }
    }

    private var shouldShowOutputEditor: Bool {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && outputText != "Drop files to upload to S3."
    }

    private var canStartUploadButton: Bool {
        hasValidS3Path && uploadQueue.contains(where: { item in
            switch item.state {
            case .queued, .failed, .cancelled:
                return true
            case .uploading, .completed:
                return false
            }
        }) && currentUploadingItem() == nil && currentTask == nil
    }

    private var shouldShowResetButton: Bool {
        // Show reset when there are no eligible items left and not currently uploading
        let anyEligible = uploadQueue.contains { item in
            switch item.state {
            case .queued, .failed, .cancelled:
                return true
            case .uploading, .completed:
                return false
            }
        }
        return !anyEligible && currentUploadingItem() == nil && currentTask == nil && !uploadQueue.isEmpty
    }

    // MARK: - Queue management

    private func addSelectedFiles(_ urls: [URL]) {
        debugLog("addSelectedFiles: \(urls.map { $0.lastPathComponent })")
        runError = nil
        let newItems = urls.map { UploadItem(url: $0) }
        // Avoid duplicates by URL
        let existingURLs = Set(uploadQueue.map { $0.url })
        let filtered = newItems.filter { !existingURLs.contains($0.url) }
        uploadQueue.append(contentsOf: filtered)
    }

    private func removeItem(_ item: UploadItem) {
        // Only allow removal if not uploading
        guard !isUploading(item) else { return }
        uploadQueue.removeAll { $0.id == item.id }
    }

    private func isUploading(_ item: UploadItem) -> Bool {
        if let current = currentUploadingItem() {
            return current.id == item.id
        }
        return false
    }

    private func currentUploadingItem() -> UploadItem? {
        uploadQueue.first(where: { $0.state == .uploading })
    }

    private var hasQueuedItems: Bool {
        uploadQueue.contains(where: { $0.state == .queued })
    }

    private var hasValidS3Path: Bool {
        !s3Path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func attemptStartNextIfNeeded() {
        // Retained for potential manual single-start behavior; now unused by the Upload button.
        guard hasValidS3Path else {
            debugLog("attemptStartNextIfNeeded: no valid s3Path")
            runError = "Please select an S3 destination."
            return
        }
        guard currentUploadingItem() == nil else {
            debugLog("attemptStartNextIfNeeded: already uploading one")
            return
        }
        guard let nextIndex = uploadQueue.firstIndex(where: { item in
            switch item.state {
            case .queued, .cancelled:
                return true
            case .failed:
                return true
            case .uploading, .completed:
                return false
            }
        }) else {
            debugLog("attemptStartNextIfNeeded: no eligible items")
            return
        }
        // Reset failed/cancelled back to queued when starting again
        switch uploadQueue[nextIndex].state {
        case .failed, .cancelled:
            uploadQueue[nextIndex].state = .queued
            uploadQueue[nextIndex].startTime = nil
            uploadQueue[nextIndex].endTime = nil
            uploadQueue[nextIndex].progress = nil
        default:
            break
        }
        // Start just one (legacy)
        Task { await startSingleUpload(at: nextIndex) }
    }

    // MARK: - Upload orchestration

    @State private var currentTask: Task<Void, Never>? = nil

    private func cancelCurrentUpload() {
        currentTask?.cancel()
        // Mark the uploading item as cancelled; sequence will stop
        if let idx = uploadQueue.firstIndex(where: { $0.state == .uploading }) {
            uploadQueue[idx].state = .cancelled
            uploadQueue[idx].endTime = Date()
        }
        isRunning = false
        uploadProgress = nil
        currentTask = nil
    }

    private func resetAll() {
        uploadQueue.removeAll()
        runError = nil
        outputText = "Drop files to upload to S3."
        isOutputExpanded = false
    }

    // New: run all eligible items sequentially
    private func startSequentialUploads() {
        guard hasValidS3Path else {
            runError = "Please select an S3 destination."
            return
        }
        guard currentTask == nil else {
            debugLog("startSequentialUploads: already running")
            return
        }
        outputText = ""
        runError = nil

        currentTask = Task {
            isRunning = true
            defer {
                Task { @MainActor in
                    isRunning = false
                    uploadProgress = nil
                    currentTask = nil
                }
            }

            // Loop over items until none left or cancelled
            while !Task.isCancelled {
                // Find next eligible item (only queued in this run)
                guard let nextIndex = await MainActor.run(body: { () -> Int? in
                    uploadQueue.firstIndex(where: { item in
                        if case .queued = item.state { return true }
                        return false
                    })
                }) else {
                    debugLog("Sequential: no more eligible items")
                    break
                }

                // Upload this item and await completion
                await startSingleUpload(at: nextIndex)

                // If cancelled during upload, stop the sequence
                if Task.isCancelled {
                    debugLog("Sequential: task cancelled; stopping sequence")
                    break
                }
            }
        }
    }

    // Refactored: upload a single item at index and await completion
    private func startSingleUpload(at index: Int) async {
        guard await MainActor.run(body: { uploadQueue.indices.contains(index) }) else { return }
        guard hasValidS3Path else {
            await MainActor.run { runError = "Please select an S3 destination." }
            return
        }

        // Snapshot the item and URL
        let item = await MainActor.run { uploadQueue[index] }
        let url = item.url

        await MainActor.run {
            isRunning = true
            uploadProgress = nil
            runError = nil
            if outputText == "Drop files to upload to S3." {
                outputText = ""
            }
        }

        // Security scope
        let securityScoped = url.startAccessingSecurityScopedResource()
        debugLog("Security scoped access started=\(securityScoped) for \(url.path)")

        // Mark uploading
        await MainActor.run {
            if uploadQueue.indices.contains(index) {
                uploadQueue[index].state = .uploading
                uploadQueue[index].startTime = Date()
                uploadQueue[index].progress = nil
            }
        }

        // Perform the upload with storage class selection and optional thumbnail
        do {
            try Task.checkCancellation()

            // Compute bucket and key from s3Path
            let (bucket, key) = try parseS3Path(s3Path: s3Path, fileURL: url)

            // Determine if file is a video
            let isVideo = isVideoFile(url)

            // Upload main file: Deep Archive for all non-thumbnails
            try await s3Service.uploadFile(localPath: url, bucket: bucket, key: key, storageClass: .deepArchive)
            await MainActor.run {
                outputText += "✅ Upload complete: s3://\(bucket)/\(key)\n"
            }

            // If video, generate thumbnail (4x4 timeframe) and upload to Standard
            if isVideo {
                do {
                    let thumbURL = try await generateThumbnail(for: url)
                    let thumbKey = thumbnailKey(for: key)
                    try await s3Service.uploadFile(localPath: thumbURL, bucket: bucket, key: thumbKey, storageClass: .standard)
                    await MainActor.run {
                        outputText += "✅ Thumbnail uploaded: s3://\(bucket)/\(thumbKey)\n"
                    }
                } catch {
                    // Thumbnail failed — mark item failed and continue to next file
                    await MainActor.run {
                        if uploadQueue.indices.contains(index) {
                            uploadQueue[index].state = .failed("Thumbnail generation/upload failed: \(error.localizedDescription)")
                            uploadQueue[index].endTime = Date()
                        }
                        outputText += "\n❌ Thumbnail error for \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                    throw error
                }
            }

            try Task.checkCancellation()

            await MainActor.run {
                if uploadQueue.indices.contains(index) {
                    uploadQueue[index].state = .completed
                    uploadQueue[index].endTime = Date()
                    uploadQueue[index].progress = 1.0
                }
                outputText += "\n✅ Upload complete!"
                runError = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                if uploadQueue.indices.contains(index) {
                    uploadQueue[index].state = .cancelled
                    uploadQueue[index].endTime = Date()
                }
            }
        } catch {
            // Any error (including thumbnail) marks the item as failed; do not retry in this run
            await MainActor.run {
                if uploadQueue.indices.contains(index) {
                    // If not already set as failed by thumbnail branch, set failed now
                    if case .failed = uploadQueue[index].state {
                        // already failed
                    } else {
                        uploadQueue[index].state = .failed(error.localizedDescription)
                    }
                    uploadQueue[index].endTime = Date()
                }
                runError = error.localizedDescription
                outputText += "\n❌ Error: \(error.localizedDescription)"
            }
        }

        if securityScoped {
            url.stopAccessingSecurityScopedResource()
            debugLog("Security scoped access stopped for \(url.path)")
        }
    }

    // MARK: - Helpers for S3 key parsing and thumbnails

    private func parseS3Path(s3Path: String, fileURL: URL) throws -> (bucket: String, key: String) {
        // Same logic as FileUploader.parseS3Path to avoid changing FileUploader
        if let slashIndex = s3Path.firstIndex(of: "/") {
            let bucket = String(s3Path[..<slashIndex])
            var key = String(s3Path[s3Path.index(after: slashIndex)...])
            if key.isEmpty {
                key = fileURL.lastPathComponent
            } else if key.hasSuffix("/") {
                key.append(fileURL.lastPathComponent)
            }
            return (bucket, key)
        } else {
            let bucket = s3Path
            let filename = fileURL.lastPathComponent
            return (bucket, filename)
        }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let videoExts: Set<String> = ["mp4","mov","m4v","webm","mkv","avi","wmv","flv","3gp","ogv"]
        return videoExts.contains(ext)
    }

    private func generateThumbnail(for videoURL: URL) async throws -> URL {
        // Uses your VideoThumbnailGenerator in timeframe mode; it already generates evenly spaced frames
        let generator = VideoThumbnailGenerator(videoURL: videoURL, rows: 4, cols: 4, thumbSize: CGSize(width: 320, height: 180))
        let url = try await generator.generateThumbnail(mode: .timeframe)
        return url
    }

    private func thumbnailKey(for originalKey: String) -> String {
        // Replace extension with _thumbnail.jpg
        let ns = originalKey as NSString
        let base = ns.deletingPathExtension
        return "\(base)_thumbnail.jpg"
    }
}

#Preview {
    ContentView()
}
