import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Combine
import AVFoundation
import CoreGraphics

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}


/// Returns the video size after applying track preferredTransform (i.e. the correct width/height).
func correctedVideoSize(for asset: AVAsset) async -> CGSize? {
    do {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }
        let size = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)

        // Apply transform to the four corners of the rect to get the bounding box
        let rect = CGRect(origin: .zero, size: size)
        let transformedRect = rect.applying(t)
        // boundingBox might have negative origin; use absolute width/height
        return CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    } catch {
        return nil
    }
}

/// True if the video is portrait (vertical). Returns nil when size can't be determined.
func isVideoPortrait(_ asset: AVAsset) async -> Bool? {
    guard let sz = await correctedVideoSize(for: asset) else { return nil }
    return sz.height > sz.width
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

    // New: bytes tracking for speed/ETA
    var totalBytes: Int64? = nil
    var bytesSent: Int64? = nil
    // Transient display fields (updated by UI)
    var speedText: String? = nil
    var etaText: String? = nil

    var elapsedText: String {
        let end = endTime ?? Date()
        guard let start = startTime else { return "" }
        let interval = end.timeIntervalSince(start)
        return Self.formatInterval(interval)
    }

    static func formatInterval(_ interval: TimeInterval) -> String {
        if interval.isNaN || interval.isInfinite || interval < 0 {
            return "--"
        }
        if interval < 60 {
            return String(format: "%.1fs", interval)
        } else if interval < 3600 {
            let minutes = Int(interval) / 60
            let seconds = Int(interval) % 60
            return String(format: "%dm %02ds", minutes, seconds)
        } else {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            return String(format: "%dh %02dm", hours, minutes)
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

    // Incoming files from “Open With…”
    @EnvironmentObject private var router: OpenFilesRouter

    // Timer to refresh elapsed time while uploading
    @State private var elapsedTick: Int = 0
    private let elapsedTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // New: short history for speed smoothing per uploading item
    struct SpeedSample {
        let time: CFAbsoluteTime
        let bytes: Int64
    }
    @State private var speedHistory: [UUID: [SpeedSample]] = [:] // keyed by UploadItem.id

    // Stability additions: keep last valid values and timestamps
    @State private var lastValidSpeedText: [UUID: String] = [:]
    @State private var lastValidETAText: [UUID: String] = [:]
    @State private var lastValidSpeedTime: [UUID: CFAbsoluteTime] = [:]

    // Tunables for stability (increased windows)
    private let smoothingWindowSeconds: CFAbsoluteTime = 10.0
    private let graceTimeoutSeconds: CFAbsoluteTime = 15.0
    private let minimumDeltaTimeForCompute: CFAbsoluteTime = 1.0
    private let maxETAHoursClamp: Double = 24.0

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
                    HStack {
                        Text("Files to upload (\(uploadQueue.count))")
                            .font(.headline)

                        Spacer()

                        // Clear all button
                        Button {
                            debugLog("Clear All tapped")
                            removeAllNonUploading()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.red)
                        }
                        .help("Remove all files that are not currently uploading")
                        .buttonStyle(.plain)
                        .disabled(!hasRemovableItems || currentTask != nil)
                    }

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
                                .disabled(isRunning)
                            }

                            // File name
                            Text(item.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            // Progress, speed, ETA, elapsed
                            Group {
                                switch item.state {
                                case .queued:
                                    Text("Queued")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                case .uploading:
                                    if let p = item.progress {
                                        HStack(spacing: 8) {
                                            ProgressView(value: p)
                                                .frame(width: 160)
                                            Text(String(format: "%.0f%%", p * 100))
                                                .font(.caption2)
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        ProgressView()
                                            .frame(width: 160)
                                    }

                                    VStack(alignment: .trailing, spacing: 2) {
                                        // Speed
                                        if let speed = item.speedText {
                                            Text(speed)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                        // ETA
                                        if let eta = item.etaText {
                                            Text("ETA: \(eta)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                    }
                                    .frame(minWidth: 120, alignment: .trailing)

                                    // Force view to re-render elapsedText every tick while uploading
                                    Text(item.elapsedText + " ")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .id(elapsedTick)
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
            // If app launched via files, process them once
            if !router.incomingFileURLs.isEmpty {
                addSelectedFiles(router.incomingFileURLs)
                router.incomingFileURLs = []
            }
        }
        .onReceive(elapsedTimer) { _ in
            if currentUploadingItem() != nil {
                elapsedTick &+= 1
            }
        }
        .onChange(of: router.incomingFileURLs) { newValue in
            guard !newValue.isEmpty else { return }
            debugLog("Received incomingFileURLs change: \(newValue.map { $0.lastPathComponent })")
            addSelectedFiles(newValue)
            router.incomingFileURLs = []
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
        let existingURLs = Set(uploadQueue.map { $0.url })
        let filtered = newItems.filter { !existingURLs.contains($0.url) }
        uploadQueue.append(contentsOf: filtered)
    }

    private func removeItem(_ item: UploadItem) {
        guard !isUploading(item) else { return }
        uploadQueue.removeAll { $0.id == item.id }
        speedHistory[item.id] = nil
        lastValidSpeedText[item.id] = nil
        lastValidETAText[item.id] = nil
        lastValidSpeedTime[item.id] = nil
    }

    private func removeAllNonUploading() {
        let beforeCount = uploadQueue.count
        let uploadingId = currentUploadingItem()?.id
        uploadQueue.removeAll { item in
            switch item.state {
            case .uploading:
                return false
            default:
                return true
            }
        }
        if let uploadingId {
            speedHistory = speedHistory.filter { $0.key == uploadingId }
            lastValidSpeedText = lastValidSpeedText.filter { $0.key == uploadingId }
            lastValidETAText = lastValidETAText.filter { $0.key == uploadingId }
            lastValidSpeedTime = lastValidSpeedTime.filter { $0.key == uploadingId }
        }
        debugLog("removeAllNonUploading removed \(beforeCount - uploadQueue.count) items")
    }

    private var hasRemovableItems: Bool {
        uploadQueue.contains { item in
            switch item.state {
            case .uploading:
                return false
            default:
                return true
            }
        }
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
        switch uploadQueue[nextIndex].state {
        case .failed, .cancelled:
            uploadQueue[nextIndex].state = .queued
            uploadQueue[nextIndex].startTime = nil
            uploadQueue[nextIndex].endTime = nil
            uploadQueue[nextIndex].progress = nil
            uploadQueue[nextIndex].bytesSent = nil
            uploadQueue[nextIndex].totalBytes = nil
            uploadQueue[nextIndex].speedText = nil
            uploadQueue[nextIndex].etaText = nil
            speedHistory[uploadQueue[nextIndex].id] = []
            lastValidSpeedText[uploadQueue[nextIndex].id] = nil
            lastValidETAText[uploadQueue[nextIndex].id] = nil
            lastValidSpeedTime[uploadQueue[nextIndex].id] = nil
        default:
            break
        }
        Task { await startSingleUpload(at: nextIndex) }
    }

    // MARK: - Upload orchestration

    @State private var currentTask: Task<Void, Never>? = nil

    private func cancelCurrentUpload() {
        currentTask?.cancel()
        if let idx = uploadQueue.firstIndex(where: { $0.state == .uploading }) {
            uploadQueue[idx].state = .cancelled
            uploadQueue[idx].endTime = Date()
            uploadQueue[idx].speedText = nil
            uploadQueue[idx].etaText = nil
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
        speedHistory.removeAll()
        lastValidSpeedText.removeAll()
        lastValidETAText.removeAll()
        lastValidSpeedTime.removeAll()
    }

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

            while !Task.isCancelled {
                guard let nextIndex = await MainActor.run(body: { () -> Int? in
                    uploadQueue.firstIndex(where: { item in
                        if case .queued = item.state { return true }
                        return false
                    })
                }) else {
                    debugLog("Sequential: no more eligible items")
                    break
                }

                await startSingleUpload(at: nextIndex)

                if Task.isCancelled {
                    debugLog("Sequential: task cancelled; stopping sequence")
                    break
                }
            }
        }
    }

    private func startSingleUpload(at index: Int) async {
        guard await MainActor.run(body: { uploadQueue.indices.contains(index) }) else { return }
        guard hasValidS3Path else {
            await MainActor.run { runError = "Please select an S3 destination." }
            return
        }

        let item = await MainActor.run { uploadQueue[index] }
        let url = item.url
        let itemId = item.id

        await MainActor.run {
            isRunning = true
            uploadProgress = nil
            runError = nil
            if outputText == "Drop files to upload to S3." {
                outputText = ""
            }
        }

        let securityScoped = url.startAccessingSecurityScopedResource()
        debugLog("Security scoped access started=\(securityScoped) for \(url.path)")

        await MainActor.run {
            if uploadQueue.indices.contains(index) {
                uploadQueue[index].state = .uploading
                uploadQueue[index].startTime = Date()
                uploadQueue[index].endTime = nil
                uploadQueue[index].progress = 0
                uploadQueue[index].bytesSent = 0
                // set totalBytes for UI speed/ETA
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber {
                    uploadQueue[index].totalBytes = size.int64Value
                }
                speedHistory[uploadQueue[index].id] = []
                lastValidSpeedText[uploadQueue[index].id] = nil
                lastValidETAText[uploadQueue[index].id] = nil
                lastValidSpeedTime[uploadQueue[index].id] = nil
            }
        }

        func updateUIProgress(sent: Int64, total: Int64) {
            let now = CFAbsoluteTimeGetCurrent()
            // Lookup by id to avoid stale index issues
            guard let idx = uploadQueue.firstIndex(where: { $0.id == itemId }) else { return }
            guard uploadQueue[idx].state == .uploading else { return }

            // Ensure monotonic bytes (coerce backwards to last)
            let previousSent = uploadQueue[idx].bytesSent ?? 0
            let coercedSent = max(previousSent, sent)

            uploadQueue[idx].bytesSent = coercedSent
            uploadQueue[idx].totalBytes = total
            if total > 0 {
                uploadQueue[idx].progress = Double(coercedSent) / Double(total)
            } else {
                uploadQueue[idx].progress = nil
            }

            var history = speedHistory[itemId] ?? []

            // Append new sample with coerced bytes
            history.append(SpeedSample(time: now, bytes: coercedSent))

            // Keep only samples within smoothing window and ensure non-decreasing bytes
            history = history.filter { now - $0.time <= smoothingWindowSeconds }
            // Compact duplicates to reduce noise (keep last for same bytes)
            var compacted: [SpeedSample] = []
            for s in history {
                if let last = compacted.last, s.bytes < last.bytes {
                    // coerce to last.bytes to keep monotonicity
                    compacted.append(SpeedSample(time: s.time, bytes: last.bytes))
                } else {
                    compacted.append(s)
                }
            }
            history = compacted
            speedHistory[itemId] = history

            var updatedSpeedText: String? = nil
            var updatedETAText: String? = nil
            var hadValidWindow = false

            // Compute window-based speed if we have at least 2 samples and enough dt
            if let first = history.first, let last = history.last {
                let dt = last.time - first.time
                let db = last.bytes - first.bytes
                if dt >= minimumDeltaTimeForCompute, db >= 0 {
                    let bps = max(Double(db) / dt, 0)
                    updatedSpeedText = formatSpeed(bps)
                    if total > 0, bps > 0 {
                        let remaining = Double(total - coercedSent)
                        var eta = remaining / bps
                        // clamp ETA to avoid absurd values
                        let maxEta = maxETAHoursClamp * 3600.0
                        if eta > maxEta { eta = maxEta }
                        updatedETAText = UploadItem.formatInterval(eta)
                    } else {
                        updatedETAText = "--"
                    }
                    hadValidWindow = true
                }
            }

            // Fallback: since-start average if window invalid but we have progress
            if !hadValidWindow,
               let start = uploadQueue[idx].startTime,
               coercedSent > 0 {
                let dt = Date().timeIntervalSince(start)
                if dt >= minimumDeltaTimeForCompute {
                    let bps = max(Double(coercedSent) / dt, 0)
                    updatedSpeedText = formatSpeed(bps)
                    if total > 0, bps > 0 {
                        let remaining = Double(total - coercedSent)
                        var eta = remaining / bps
                        let maxEta = maxETAHoursClamp * 3600.0
                        if eta > maxEta { eta = maxEta }
                        updatedETAText = UploadItem.formatInterval(eta)
                    } else {
                        updatedETAText = "--"
                    }
                }
            }

            if let s = updatedSpeedText, let e = updatedETAText {
                uploadQueue[idx].speedText = s
                uploadQueue[idx].etaText = e
                lastValidSpeedText[itemId] = s
                lastValidETAText[itemId] = e
                lastValidSpeedTime[itemId] = now
            } else {
                // Use last valid within grace; otherwise keep current display without forcing "0 B/s"
                let lastTime = lastValidSpeedTime[itemId] ?? 0
                if now - lastTime <= graceTimeoutSeconds,
                   let lastSpeed = lastValidSpeedText[itemId],
                   let lastETA = lastValidETAText[itemId] {
                    uploadQueue[idx].speedText = lastSpeed
                    uploadQueue[idx].etaText = lastETA
                } else {
                    // Only show minimal fallback if we truly have nothing
                    if uploadQueue[idx].bytesSent ?? 0 == 0 {
                        uploadQueue[idx].speedText = "--"
                        uploadQueue[idx].etaText = "--"
                    } else {
                        // Keep previous display if any
                        // No update, avoids flicker to 0 B/s
                    }
                }
            }
        }

        do {
            try Task.checkCancellation()
            let (bucket, key) = try parseS3Path(s3Path: s3Path, fileURL: url)
            let isVideo = isVideoFile(url)

            try await s3Service.uploadFile(
                localPath: url,
                bucket: bucket,
                key: key,
                storageClass: .deepArchive,
                progress: { sent, total in
                    Task { @MainActor in
                        updateUIProgress(sent: sent, total: total)
                    }
                }
            )
            await MainActor.run {
                outputText += "✅ Upload complete: s3://\(bucket)/\(key)\n"
            }

            if isVideo {
                do {
                    let thumbURL = try await generateThumbnail(for: url)
                    let thumbKey = thumbnailKey(for: key)
                    try await s3Service.uploadFile(localPath: thumbURL, bucket: bucket, key: thumbKey, storageClass: .standard, progress: { _, _ in })
                    await MainActor.run {
                        outputText += "✅ Thumbnail uploaded: s3://\(bucket)/\(thumbKey)\n"
                    }
                } catch {
                    await MainActor.run {
                        if let idx = uploadQueue.firstIndex(where: { $0.id == itemId }) {
                            uploadQueue[idx].state = .failed("Thumbnail generation/upload failed: \(error.localizedDescription)")
                            uploadQueue[idx].endTime = Date()
                        }
                        outputText += "\n❌ Thumbnail error for \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                    throw error
                }
            }

            try Task.checkCancellation()

            await MainActor.run {
                if let idx = uploadQueue.firstIndex(where: { $0.id == itemId }) {
                    uploadQueue[idx].state = .completed
                    uploadQueue[idx].endTime = Date()
                    uploadQueue[idx].progress = 1.0
                    uploadQueue[idx].speedText = nil
                    uploadQueue[idx].etaText = nil
                }
                outputText += "\n✅ Upload complete!"
                runError = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                if let idx = uploadQueue.firstIndex(where: { $0.id == itemId }) {
                    uploadQueue[idx].state = .cancelled
                    uploadQueue[idx].endTime = Date()
                    uploadQueue[idx].speedText = nil
                    uploadQueue[idx].etaText = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = uploadQueue.firstIndex(where: { $0.id == itemId }) {
                    if case .failed = uploadQueue[idx].state {
                    } else {
                        uploadQueue[idx].state = .failed(error.localizedDescription)
                    }
                    uploadQueue[idx].endTime = Date()
                    uploadQueue[idx].speedText = nil
                    uploadQueue[idx].etaText = nil
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
        let asset = AVAsset(url: videoURL)
        let thumbsize: CGSize
        let aspectRatio: CGFloat
        let rows: Int
        let cols: Int
        if let portrait = await isVideoPortrait(asset), portrait {
            thumbsize = CGSize(width: 180, height: 320)
            aspectRatio = 9.0/16.0
            rows = 3
            cols = 3
        } else {
            thumbsize = CGSize(width: 320, height: 180)
            aspectRatio = 16.0/9.0
            rows = 4
            cols = 4
        }
        let generator = VideoThumbnailGenerator(videoURL: videoURL, rows: rows, cols: cols, thumbSize: thumbsize, aspectRatio: aspectRatio)
        let url = try await generator.generateThumbnail(mode: .timeframe)
        return url
    }

    private func thumbnailKey(for originalKey: String) -> String {
        let ns = originalKey as NSString
        let base = ns.deletingPathExtension
        return "\(base)_thumbnail.webp"
    }

    // Format speed as human-readable (B/s, KB/s, MB/s, GB/s)
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite && bytesPerSecond >= 0 else { return "--" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond
        var unitIndex = 0
        while value >= 1024.0 && unitIndex < units.count - 1 {
            value /= 1024.0
            unitIndex += 1
        }
        if unitIndex == 0 {
            return String(format: "%.0f %@", value, units[unitIndex])
        } else {
            return String(format: "%.2f %@", value, units[unitIndex])
        }
    }
}

#Preview {
    ContentView()
}
