import Foundation
import AWSS3
import AWSClientRuntime
import Smithy
import AWSSDKIdentity

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

final class S3Service {
    private let profileName = "nasa-personal"
    private let region = "us-east-1"
    private let s3Client: S3Client
    
    init() {
        debugLog("Initializing S3Service with profile='\(profileName)', region='\(region)'")
        let profileResolver = ProfileAWSCredentialIdentityResolver(profileName: profileName)
        do {
            let configuration = try S3Client.S3ClientConfiguration(
                awsCredentialIdentityResolver: profileResolver,
                region: region
            )
            //https://sandeep-nallapati.s3.us-east-1.amazonaws.com/gallery/
            s3Client = S3Client(config: configuration)
            debugLog("S3Client initialized successfully: \(s3Client), \(configuration)")
        } catch {
            debugLog("Failed to initialize S3Client configuration: \(error.localizedDescription)")
            fatalError("Failed to initialize S3Client configuration: \(error.localizedDescription)")
        }
    }
    
    private func loadCredentials() throws -> (accessKey: String?, secretKey: String?) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let credentialsPath = homeDir.appendingPathComponent(".aws/credentials")
        debugLog("Attempting to load credentials from \(credentialsPath.path)")
        
        guard let credentialsContent = try? String(contentsOf: credentialsPath) else {
            debugLog("Credentials file not found or unreadable at path")
            return (nil, nil)
        }
        
        var accessKey: String?
        var secretKey: String?
        var inProfile = false
        
        for line in credentialsContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let profile = String(trimmed.dropFirst().dropLast())
                inProfile = (profile == profileName)
                continue
            }
            if inProfile {
                if trimmed.hasPrefix("aws_access_key_id") {
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        accessKey = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                } else if trimmed.hasPrefix("aws_secret_access_key") {
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        secretKey = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        
        if let accessKey = accessKey, let secretKey = secretKey, !accessKey.isEmpty, !secretKey.isEmpty {
            debugLog("Successfully loaded credentials for profile: \(profileName)")
        } else {
            debugLog("Warning: Could not find credentials for profile '\(profileName)'")
        }
        
        return (accessKey, secretKey)
    }
    
    // MARK: - Listing Operations
    
    func listBuckets() async throws -> [String] {
        debugLog("listBuckets start")
        let input = ListBucketsInput()
        let output = try await s3Client.listBuckets(input: input)
        let names = output.buckets?.compactMap { $0.name } ?? []
        debugLog("listBuckets success. count=\(names.count)")
        return names
    }
    
    func listObjects(bucket: String, prefix: String = "") async throws -> [S3Item] {
        debugLog("listObjects start. bucket='\(bucket)', prefix='\(prefix)', region='\(region)'")
        var collected: [S3Item] = []
        var continuationToken: String? = nil
        var pageIndex = 0
//        _ = try await s3Client.headBucket(input: .init(bucket: "sandeep-nallapati"))
        repeat {
            pageIndex += 1
            var input = ListObjectsV2Input(
                bucket: bucket,
                delimiter: "/",
                prefix: prefix.isEmpty ? nil : prefix
            )
            input.continuationToken = continuationToken
            
            debugLog("Request page \(pageIndex): delimiter='/', prefix='\(input.prefix ?? "")', continuationToken='\(continuationToken ?? "nil")'")
            
            do {
                let output = try await s3Client.listObjectsV2(input: input)
                
                let commonPrefixesCount = output.commonPrefixes?.count ?? 0
                let contentsCount = output.contents?.count ?? 0
                debugLog("Response page \(pageIndex): commonPrefixes=\(commonPrefixesCount), contents=\(contentsCount), isTruncated=\(output.isTruncated ?? false)")
                
                // Folders (common prefixes)
                if let commonPrefixes = output.commonPrefixes {
                    for (i, commonPrefix) in commonPrefixes.enumerated() {
                        if let prefixPath = commonPrefix.prefix {
                            let name: String
                            if prefix.isEmpty {
                                name = prefixPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            } else {
                                let drop = String(prefixPath.dropFirst(prefix.count))
                                name = drop.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            }
                            collected.append(S3Item(name: name, key: prefixPath, isFolder: true, size: nil))
                            debugLog("  [Folder \(i)] name='\(name)', key='\(prefixPath)'")
                        } else {
                            debugLog("  [Folder \(i)] Missing prefix value")
                        }
                    }
                }
                
                // Files (contents)
                if let contents = output.contents {
                    for (i, object) in contents.enumerated() {
                        guard let key = object.key else {
                            debugLog("  [Object \(i)] Missing key")
                            continue
                        }
                        if !prefix.isEmpty && key == prefix {
                            debugLog("  [Object \(i)] Skipping directory marker key='\(key)'")
                            continue
                        }
                        let size = object.size.map { Int64($0) }
                        let name = prefix.isEmpty ? key : String(key.dropFirst(prefix.count))
                        collected.append(S3Item(name: name, key: key, isFolder: false, size: size))
                        debugLog("  [File \(i)] name='\(name)', key='\(key)', size=\(size ?? -1)")
                    }
                }
                
                continuationToken = output.nextContinuationToken
                debugLog("Page \(pageIndex) processed. collectedTotal=\(collected.count), nextToken='\(continuationToken ?? "nil")'")
            } catch {
                let nsError = error as NSError
                debugLog("listObjectsV2 failed on page \(pageIndex). domain='\(nsError.domain)', code=\(nsError.code), userInfo=\(nsError.userInfo)")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    debugLog("Underlying error: domain='\(underlying.domain)', code=\(underlying.code), userInfo=\(underlying.userInfo)")
                }
                debugLog("Hint: Check DNS/proxy/network. Ensure region '\(region)' is correct for bucket '\(bucket)'.")
                throw error
            }
        } while continuationToken != nil
        
        debugLog("Sorting \(collected.count) items: folders-first, then files, by name")
        let sorted = collected.sorted { first, second in
            if first.isFolder != second.isFolder {
                return first.isFolder && !second.isFolder
            }
            return first.name < second.name
        }
        let foldersCount = sorted.filter { $0.isFolder }.count
        let filesCount = sorted.count - foldersCount
        debugLog("listObjects complete. total=\(sorted.count) (folders=\(foldersCount), files=\(filesCount))")
        return sorted
    }
    
    // MARK: - Upload Operations
    
    func uploadFile(
        localPath: URL,
        bucket: String,
        key: String,
        storageClass: S3StorageClass = .standard
    ) async throws {
        debugLog("uploadFile start. local='\(localPath.path)', bucket='\(bucket)', key='\(key)', storageClass=\(storageClass.rawValue)")
        let fileData = try Data(contentsOf: localPath)
        let contentType = getContentType(for: localPath)
        debugLog("uploadFile read data. size=\(fileData.count) bytes, contentType='\(contentType)'")
        
        let awsStorageClass = mapStorageClass(storageClass)
        
        var input = PutObjectInput(
            body: .data(fileData),
            bucket: bucket,
            key: key
        )
        input.contentType = contentType
        if let storageClass = awsStorageClass {
            input.storageClass = storageClass
        }
        
        _ = try await s3Client.putObject(input: input)
        debugLog("uploadFile success: s3://\(bucket)/\(key)")
    }
    
    // MARK: - Helper Methods
    
    private func mapStorageClass(_ sc: S3StorageClass) -> S3ClientTypes.StorageClass? {
        switch sc {
        case .standard:
            return .standard
        case .deepArchive:
            return .deepArchive
        }
    }
    
    private func getContentType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        let contentTypes: [String: String] = [
            "mp4": "video/mp4",
            "avi": "video/x-msvideo",
            "mov": "video/quicktime",
            "mkv": "video/x-matroska",
            "wmv": "video/x-ms-wmv",
            "flv": "video/x-flv",
            "webm": "video/webm",
            "m4v": "video/x-m4v",
            "3gp": "video/3gpp",
            "ogv": "video/ogg",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "pdf": "application/pdf",
            "txt": "text/plain",
            "json": "application/json"
        ]
        let type = contentTypes[pathExtension] ?? "application/octet-stream"
        debugLog("getContentType: ext='\(pathExtension)' -> '\(type)'")
        return type
    }
}

// MARK: - Supporting Types

enum S3StorageClass: String {
    case standard = "STANDARD"
    case deepArchive = "DEEP_ARCHIVE"
}

enum S3Error: LocalizedError {
    case credentialsNotFound
    case requestFailed
    case invalidURL
    case uploadFailed
    
    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "AWS credentials not found. Please configure ~/.aws/credentials"
        case .requestFailed:
            return "S3 request failed"
        case .invalidURL:
            return "Invalid S3 URL"
        case .uploadFailed:
            return "File upload to S3 failed"
        }
    }
}
