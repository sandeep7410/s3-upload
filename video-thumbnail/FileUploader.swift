import Foundation

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

class FileUploader {
    private let s3Service: S3Service
    private let thumbnailGenerator: VideoThumbnailGenerator?
    
    init(s3Service: S3Service = S3Service()) {
        self.s3Service = s3Service
        self.thumbnailGenerator = nil
        debugLog("FileUploader init")
    }
    
    // Added onProgress closure (0.0 ... 1.0). For now we set 0 at start and 1 at end.
    func uploadFile(
        fileURL: URL,
        s3Path: String,
        onMessage: @escaping (String) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        debugLog("uploadFile called. fileURL='\(fileURL.path)', s3Path='\(s3Path)'")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            debugLog("Local file not found at \(fileURL.path)")
            throw S3Error.invalidURL
        }
        
        let (bucket, key) = try parseS3Path(s3Path: s3Path, fileURL: fileURL)
        debugLog("Parsed S3 path. bucket='\(bucket)', key='\(key)'")
        
        onMessage("📁 Local file: \(fileURL.path)")
        onMessage("☁️ Destination: s3://\(bucket)/\(key)")
        
        onProgress(0.0)
        do {
            try await s3Service.uploadFile(localPath: fileURL, bucket: bucket, key: key, storageClass: .standard)
            onMessage("✅ Upload complete: s3://\(bucket)/\(key)")
            onProgress(1.0)
            debugLog("Upload success")
        } catch {
            onMessage("❌ Upload failed: \(error.localizedDescription)")
            debugLog("Upload failed: \(error.localizedDescription)")
            throw S3Error.uploadFailed
        }
        // If it's a video, generate a 4x4 grid thumbnail first
//        let ext = fileURL.pathExtension.lowercased()
//        let isVideo = ["mp4","mov","m4v","webm","mkv","avi","wmv","flv","3gp","ogv"].contains(ext)
//        var thumbnailKey: String?
    }
    
    private func parseS3Path(s3Path: String, fileURL: URL) throws -> (bucket: String, key: String) {
        debugLog("parseS3Path called. s3Path='\(s3Path)'")
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
}
