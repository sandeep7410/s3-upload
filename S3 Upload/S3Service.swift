import Foundation
import AWSS3
import AWSClientRuntime
import Smithy
import AWSSDKIdentity
import SmithyIdentity
import Combine

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

final class S3Service {
    // Lazily created client; built when credentials become available.
    private var s3Client: S3Client?
    private var settingsCancellable: AnyCancellable?

    init() {
        debugLog("S3Service init (no immediate credential requirement)")

        // Observe settings changes and invalidate client automatically so that
        // next API call rebuilds the client with latest credentials/region.
        let settings = AWSSettings.shared

        // Merge changes from each @Published property into a single stream of Void
        let useCustom = settings.$useCustomCredentials.map { _ in () }.eraseToAnyPublisher()
        let accessKey = settings.$accessKeyId.map { _ in () }.eraseToAnyPublisher()
        let secretKey = settings.$secretAccessKey.map { _ in () }.eraseToAnyPublisher()
        let region = settings.$region.map { _ in () }.eraseToAnyPublisher()

        settingsCancellable = Publishers.MergeMany([useCustom, accessKey, secretKey, region])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                debugLog("AWSSettings changed -> invalidating S3 client")
                self?.invalidateClient()
            }
    }

    deinit {
        settingsCancellable?.cancel()
    }

    // Builds the client from current settings (no session token, no fallback).
    // Returns a ready client or throws if settings are invalid.
    private func ensureClientReady() throws -> S3Client {
        if let client = s3Client {
            return client
        }

        let settings = AWSSettings.shared
        let accessKey = settings.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = settings.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = settings.region.trimmingCharacters(in: .whitespacesAndNewlines)

        guard settings.useCustomCredentials,
              !accessKey.isEmpty,
              !secretKey.isEmpty,
              !region.isEmpty
        else {
            debugLog("ensureClientReady: credentials missing or disabled")
            throw S3Error.credentialsNotFound
        }

        debugLog("ensureClientReady: building S3Client for region='\(region)' using custom credentials")

        let creds = AWSCredentialIdentity(
            accessKey: accessKey,
            secret: secretKey
            // no session token
        )
        let resolver = StaticAWSCredentialIdentityResolver(creds)

        do {
            let configuration = try S3Client.S3ClientConfiguration(
                awsCredentialIdentityResolver: resolver,
                region: region
            )
            let client = S3Client(config: configuration)
            self.s3Client = client
            debugLog("ensureClientReady: S3Client built successfully")
            return client
        } catch {
            debugLog("ensureClientReady: failed to create S3Client config: \(error.localizedDescription)")
            throw error
        }
    }

    // Call this if settings change to force a rebuild on next call.
    func invalidateClient() {
        debugLog("invalidateClient: clearing S3 client")
        s3Client = nil
    }

    // MARK: - Listing Operations

    func listBuckets() async throws -> [String] {
        debugLog("listBuckets start")
        let client = try ensureClientReady()
        let input = ListBucketsInput()
        let output = try await client.listBuckets(input: input)
        let names = output.buckets?.compactMap { $0.name } ?? []
        debugLog("listBuckets success. count=\(names.count)")
        return names
    }

    func listObjects(bucket: String, prefix: String = "") async throws -> [S3Item] {
        let client = try ensureClientReady()
        debugLog("listObjects start. bucket='\(bucket)', prefix='\(prefix)'")
        var collected: [S3Item] = []
        var continuationToken: String? = nil
        var pageIndex = 0

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
                let output = try await client.listObjectsV2(input: input)

                let commonPrefixesCount = output.commonPrefixes?.count ?? 0
                let contentsCount = output.contents?.count ?? 0
                debugLog("Response page \(pageIndex): commonPrefixes=\(commonPrefixesCount), contents=\(contentsCount), isTruncated=\(output.isTruncated ?? false)")

                // Folders
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

                // Files
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
        let client = try ensureClientReady()
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

        _ = try await client.putObject(input: input)
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
            return "AWS credentials are required. Open Settings and fill Access Key ID, Secret Access Key, and Region, then enable 'Use custom credentials'."
        case .requestFailed:
            return "S3 request failed"
        case .invalidURL:
            return "Invalid S3 URL"
        case .uploadFailed:
            return "File upload to S3 failed"
        }
    }
}
