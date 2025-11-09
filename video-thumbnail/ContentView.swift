import SwiftUI
import UniformTypeIdentifiers

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

struct ContentView: View {
    @State private var lastDroppedFileURL: URL?
    @State private var outputText: String = "Drop a file to upload to S3."
    @State private var isRunning: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var runError: String?
    @State private var s3Path: String = ""
    @State private var uploadProgress: Double? = nil // 0.0 ... 1.0 when known

    private let fileUploader = FileUploader()

    // Approximate 10 cm height in points
    private let tenCentimetersPoints: CGFloat = 380

    var body: some View {
        VStack(spacing: 16) {
            Text("Video Thumbnail")
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
            .border(Color.blue, width: 2)
            .padding(.horizontal)

            HStack {
                Button("Choose File…") {
                    debugLog("Choose File button tapped. isRunning=\(isRunning)")
                    showFileImporter.toggle()
                }
                .disabled(isRunning)

                if let fileName = lastDroppedFileURL?.lastPathComponent {
                    Text("Selected: \(fileName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Confirm Upload button
                Button {
                    debugLog("Confirm Upload tapped")
                    startUploadIfPossible()
                } label: {
                    Text("Upload")
                        .fontWeight(.semibold)
                }
                .disabled(!canUpload || isRunning)
                .keyboardShortcut(.defaultAction)
                .help("Start uploading the selected file to the selected S3 path")
            }
            
            // Make the S3 browser area approximately 10 cm tall
            S3Browser(selectedPath: $s3Path)
                .disabled(isRunning)
                .frame(maxHeight: tenCentimetersPoints)

            // Progress indicator area
            if isRunning {
                if let progress = uploadProgress {
                    VStack(spacing: 6) {
                        ProgressView(value: progress)
                        Text(String(format: "Uploading… %.0f%%", progress * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Uploading…")
                }
            }

            if let runError {
                Text(runError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            // Show output editor only when there is meaningful output
            if shouldShowOutputEditor {
                TextEditor(text: $outputText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .padding()
                    .border(Color.gray.opacity(0.5), width: 1)
            }
            
            // Bottom-centered Upload button
            HStack {
                Spacer()
                Button {
                    debugLog("Bottom Upload tapped")
                    startUploadIfPossible()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Upload")
                            .fontWeight(.semibold)
                    }
                }
                .padding(.vertical, 12)
                .padding(.bottom, 4)
                .disabled(!canUpload || isRunning)
                Spacer()
            }

            Spacer()
        }
        .padding(.bottom, 24)
        .frame(minWidth: 640, minHeight: 720)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            debugLog("fileImporter result received")
            switch result {
            case .success(let urls):
                debugLog("fileImporter success. urls=\(urls)")
                guard let fileURL = urls.first else {
                    debugLog("No URL returned from importer")
                    return
                }
                setSelectedFile(fileURL)
            case .failure(let error):
                debugLog("fileImporter failure. error=\(error.localizedDescription)")
                runError = error.localizedDescription
            }
        }
        .onAppear {
            debugLog("ContentView appeared")
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
                Text("Drag & drop a file here, or click to choose")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding()
        }
        // Keep drag-and-drop support
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            debugLog("onDrop called. providers.count=\(providers.count)")
            guard let provider = providers.first else {
                debugLog("No provider in onDrop")
                return false
            }

            _ = provider.loadObject(ofClass: URL.self) { object, error in
                if let error {
                    debugLog("loadObject error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        runError = error.localizedDescription
                    }
                    return
                }
                guard let url = object else {
                    debugLog("loadObject returned nil URL")
                    DispatchQueue.main.async {
                        runError = "Unable to read dropped file."
                    }
                    return
                }

                debugLog("Dropped URL received: \(url.path)")
                DispatchQueue.main.async {
                    setSelectedFile(url)
                }
            }

            return true
        }
    }

    private var shouldShowOutputEditor: Bool {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && outputText != "Drop a file to upload to S3."
    }

    private var canUpload: Bool {
        lastDroppedFileURL != nil && !s3Path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setSelectedFile(_ url: URL) {
        debugLog("setSelectedFile with url=\(url.path)")
        lastDroppedFileURL = url
        // Do not auto-start upload; wait for user to press Upload.
        runError = nil
        // Clear previous output only when starting a new upload, not on selection.
    }

    private func startUploadIfPossible() {
        guard let fileURL = lastDroppedFileURL else {
            runError = "Please choose a file to upload."
            return
        }
        guard !s3Path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            runError = "Please select an S3 destination."
            return
        }
        uploadProgress = 0 // start at 0 if we get progress callbacks
        outputText = ""
        runError = nil
        runUpload(with: fileURL)
    }

    private func runUpload(with url: URL) {
        debugLog("runUpload invoked. isRunning=\(isRunning), s3Path='\(s3Path)'")
        guard !isRunning else { return }
        
        isRunning = true

        let securityScoped = url.startAccessingSecurityScopedResource()
        debugLog("Security scoped access started=\(securityScoped) for \(url.path)")

        Task {
            defer {
                if securityScoped {
                    url.stopAccessingSecurityScopedResource()
                    debugLog("Security scoped access stopped for \(url.path)")
                }
            }

            do {
                debugLog("Starting upload via FileUploader. file=\(url.lastPathComponent), s3Path=\(s3Path)")
                try await fileUploader.uploadFile(
                    fileURL: url,
                    s3Path: s3Path,
                    onMessage: { message in
                        Task { @MainActor in
                            outputText += message + "\n"
                        }
                    },
                    onProgress: { progress in
                        Task { @MainActor in
                            uploadProgress = progress // 0...1
                        }
                    }
                )
                await MainActor.run {
                    outputText += "\n✅ Upload complete!"
                    runError = nil
                    isRunning = false
                    uploadProgress = nil
                    debugLog("Upload completed successfully")
                }
            } catch {
                await MainActor.run {
                    runError = error.localizedDescription
                    outputText += "\n❌ Error: \(error.localizedDescription)"
                    isRunning = false
                    uploadProgress = nil
                    debugLog("Upload failed with error: \(error.localizedDescription)")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
