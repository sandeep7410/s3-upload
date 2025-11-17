import SwiftUI

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

struct S3Item: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let key: String
    let isFolder: Bool
    let size: Int64?
    
    init(name: String, key: String, isFolder: Bool, size: Int64? = nil) {
        self.name = name
        self.key = key
        self.isFolder = isFolder
        self.size = size
    }
}

struct S3Browser: View {
    @Binding var selectedPath: String
    @ObservedObject private var settings = AWSSettings.shared
    @State private var currentPrefix: String = ""
    @State private var items: [S3Item] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var pathHistory: [String] = []
    @State private var keyHistory: [String] = []
    @State private var showNewFolderPrompt: Bool = false
    @State private var newFolderName: String = ""

    private let s3Lister = S3Lister()
    private let s3Service = S3Service()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("S3 Destination")
                .font(.headline)
            
            // Breadcrumbs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        Button(action: { navigateToPath(crumb.key) }) {
                            Text(crumb.title)
                                .font(.caption)
                                .underline(index != breadcrumbs.count - 1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(index == breadcrumbs.count - 1 ? Color.clear : Color.blue.opacity(0.06))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        if index < breadcrumbs.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // Current folder selector & path preview
            HStack {
                Button {
                    debugLog("Select current folder tapped: '\(currentPrefix)'")
                    toggleSelectPathForCurrentFolder()
                } label: {
                    Label(
                        isCurrentFolderSelected ? "Unselect this folder" : "Select this folder",
                        systemImage: isCurrentFolderSelected ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                    .font(.subheadline)
                }
                .disabled(currentPrefix.isEmpty || settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    showNewFolderPrompt = true
                    newFolderName = ""
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .font(.subheadline)
                .disabled(settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Text(selectedPath.isEmpty ? "No folder selected" : "Selected: s3://\(selectedPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 4)

            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
            }
            
            if let error = errorMessage {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            // Leading tick that toggles selection for folders
                            if item.isFolder {
                                Button(action: {
                                    debugLog("Select folder tapped: key='\(item.key)'")
                                    toggleSelectPath(forFolderKey: item.key)
                                }) {
                                    Image(systemName: isFolderKeySelected(item.key) ? "checkmark.circle.fill" : "checkmark.circle")
                                        .foregroundStyle(isFolderKeySelected(item.key) ? .green : .gray)
                                        .font(.title3)
                                        .padding(6)
                                }
                                .buttonStyle(.plain)
                                .help(isFolderKeySelected(item.key) ? "Unselect this folder" : "Select this folder for upload")
                            } else {
                                // spacer to align with folders
                                Image(systemName: "circle")
                                    .opacity(0.0)
                                    .frame(width: 20)
                            }
                            
                            Button(action: {
                                if item.isFolder {
                                    navigateToFolder(item)
                                }
                            }) {
                                HStack {
                                    Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
                                        .foregroundStyle(item.isFolder ? .blue : .gray)
                                        .frame(width: 20)
                                    
                                    Text(item.name)
                                        .foregroundStyle(.primary)
                                    
                                    Spacer()
                                    
                                    if !item.isFolder, let size = item.size {
                                        Text(formatFileSize(size))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    if item.isFolder {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.clear)
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
            .border(Color.gray.opacity(0.3), width: 1)
            .cornerRadius(4)
        }
        .padding()
        .onAppear {
            loadRoot()
        }
        .onChange(of: settings.bucketName) { _, _ in
            loadRoot()
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { Task { await createNewFolder() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a folder name to create under the current path.")
        }
    }
    
    // MARK: - Loading and Navigation
    
    private var breadcrumbs: [(title: String, key: String)] {
        let bucket = settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        var crumbs: [(String, String)] = [("s3://\(bucket.isEmpty ? "—" : bucket)", "")]
        guard !currentPrefix.isEmpty else { return crumbs }
        let parts = currentPrefix.split(separator: "/").filter { !$0.isEmpty }
        var running = ""
        for part in parts {
            running += part + "/"
            crumbs.append((String(part), running))
        }
        return crumbs
    }

    private func loadRoot() {
        debugLog("loadRoot")
        pathHistory = []
        keyHistory = []
        currentPrefix = ""
        load(prefix: "")
    }
    
    private func navigateToFolder(_ item: S3Item) {
        guard item.isFolder else { return }
        debugLog("navigateToFolder -> key='\(item.key)'")
        pathHistory.append(item.name)
        keyHistory.append(item.key)
        currentPrefix = item.key
        load(prefix: item.key)
    }
    
    private func navigateToPath(_ prefix: String) {
        debugLog("navigateToPath -> prefix='\(prefix)'")
        currentPrefix = prefix
        load(prefix: prefix)
    }
    
    private func load(prefix: String) {
        let bucket = settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else {
            items = []
            isLoading = false
            errorMessage = "Set a bucket name in Settings."
            debugLog("load aborted: empty bucket name in settings")
            return
        }

        isLoading = true
        errorMessage = nil
        debugLog("load called with bucket='\(bucket)', prefix='\(prefix)'")
        
        Task {
            do {
                let listed = try await s3Lister.listObjects(bucket: bucket, prefix: prefix)
                await MainActor.run {
                    self.items = listed
                    self.isLoading = false
                    self.errorMessage = nil
                    debugLog("load success. items.count=\(listed.count)")
                }
            } catch {
                await MainActor.run {
                    self.items = []
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    debugLog("load failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - New Folder

    @MainActor
    private func createNewFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let bucket = settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else { return }

        // Construct new folder key under currentPrefix
        var newKey = currentPrefix
        newKey += name
        if !newKey.hasSuffix("/") { newKey += "/" }

        // Optional: check existence
        if items.contains(where: { $0.isFolder && $0.key == newKey }) {
            errorMessage = "Folder already exists."
            return
        }

        do {
            let createdKey = try await s3Service.createFolder(bucket: bucket, key: newKey)
            // Navigate into it and select it
            currentPrefix = createdKey
            load(prefix: createdKey)
            selectedPath = normalizedPath(forFolderKey: createdKey)
            debugLog("Created and selected folder '\(createdKey)'")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Selection
    
    private func normalizedPath(forFolderKey key: String) -> String {
        let bucket = settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix("/") {
            return "\(bucket)/\(key)"
        } else {
            return "\(bucket)/\(key)/"
        }
    }
    
    private func isFolderKeySelected(_ key: String) -> Bool {
        selectedPath == normalizedPath(forFolderKey: key)
    }
    
    private var isCurrentFolderSelected: Bool {
        guard !currentPrefix.isEmpty else { return false }
        return selectedPath == normalizedPath(forFolderKey: currentPrefix)
    }
    
    private func toggleSelectPath(forFolderKey key: String) {
        let path = normalizedPath(forFolderKey: key)
        if selectedPath == path {
            selectedPath = ""
            debugLog("toggleSelectPath: cleared selection (was '\(path)')")
        } else {
            selectedPath = path
            debugLog("toggleSelectPath: selected '\(path)'")
        }
    }
    
    private func toggleSelectPathForCurrentFolder() {
        guard !currentPrefix.isEmpty else { return }
        toggleSelectPath(forFolderKey: currentPrefix)
    }
    
    private func selectPath(_ key: String) {
        let bucket = settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix("/") {
            selectedPath = "\(bucket)/\(key)"
        } else {
            selectedPath = "\(bucket)/\(key)/"
        }
        debugLog("selectPath: key='\(key)', selectedPath='\(selectedPath)'")
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
