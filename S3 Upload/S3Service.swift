import Foundation
import AWSS3
import AWSClientRuntime
import Smithy
import AWSSDKIdentity
import SmithyIdentity
import Combine
internal import ClientRuntime

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

final class S3Service {
    // Lazily created client; built when credentials become available.
    private var s3Client: S3Client?
    private var settingsCancellable: AnyCancellable?

    init() {
        debugLog("S3Service init (no immediate credential requirement)")
        // Removed automatic invalidation on settings changes.
        // Caller will explicitly invoke invalidateClient() when appropriate (e.g., just before test connection).
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

    // Call this to force a rebuild on next call.
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

    // Progress-enabled upload. Uses single-part for <= 8 MiB, multipart for larger files.
    func uploadFile(
        localPath: URL,
        bucket: String,
        key: String,
        storageClass: S3StorageClass = .standard,
        progress: ((_ sent: Int64, _ total: Int64) -> Void)? = nil
    ) async throws {
        let client = try ensureClientReady()
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: localPath.path)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        debugLog("uploadFile start. local='\(localPath.path)', bucket='\(bucket)', key='\(key)', storageClass=\(storageClass.rawValue), size=\(total)")

        let contentType = getContentType(for: localPath)
        let awsStorageClass = mapStorageClass(storageClass)

        let partSize = 8 * 1024 * 1024 // 8 MiB

        if total <= partSize {
            // Single-part upload
            var bodyData = try Data(contentsOf: localPath, options: .mappedIfSafe)
            var input = PutObjectInput(
                body: .data(bodyData),
                bucket: bucket,
                key: key
            )
            input.contentLength = Int(total) // Int (fixes NSNumber/Int mismatch)
            input.contentType = contentType
            if let storageClass = awsStorageClass {
                input.storageClass = storageClass
            }

            progress?(0, total)
            _ = try await client.putObject(input: input)
            progress?(total, total)
            debugLog("uploadFile success (single-part): s3://\(bucket)/\(key)")
            bodyData.removeAll(keepingCapacity: false)
            return
        }

        // Multipart upload
        progress?(0, total)

        // 1) Initiate multipart upload
        var createInput = CreateMultipartUploadInput(
            bucket: bucket,
            key: key
        )
        createInput.contentType = contentType
        if let storageClass = awsStorageClass {
            createInput.storageClass = storageClass
        }

        let createOutput = try await client.createMultipartUpload(input: createInput)
        guard let uploadId = createOutput.uploadId else {
            debugLog("createMultipartUpload returned nil uploadId")
            throw S3Error.requestFailed
        }
        debugLog("createMultipartUpload success. uploadId=\(uploadId)")

        // 2) Read file and upload parts
        let handle = try FileHandle(forReadingFrom: localPath)
        defer {
            do { try handle.close() } catch {
                debugLog("Warning: failed to close FileHandle: \(error.localizedDescription)")
            }
        }

        var bytesSent: Int64 = 0
        var partNumber = 0
        var completedParts: [S3ClientTypes.CompletedPart] = []

        do {
            while true {
                try Task.checkCancellation()

                let chunk = try handle.read(upToCount: partSize) ?? Data()
                if chunk.isEmpty {
                    break
                }
                partNumber += 1

                var uploadPartInput = UploadPartInput()
                uploadPartInput.bucket = bucket
                uploadPartInput.key = key
                uploadPartInput.uploadId = uploadId
                uploadPartInput.partNumber = partNumber
                uploadPartInput.contentLength = chunk.count
                uploadPartInput.body = .data(chunk)

                debugLog("Uploading part #\(partNumber), size=\(chunk.count)")
                let partOutput = try await client.uploadPart(input: uploadPartInput)
                guard let etag = partOutput.eTag else {
                    debugLog("uploadPart returned nil ETag for part \(partNumber)")
                    throw S3Error.requestFailed
                }

                let completed = S3ClientTypes.CompletedPart(eTag: etag, partNumber: partNumber)
                completedParts.append(completed)

                bytesSent += Int64(chunk.count)
                progress?(bytesSent, total)
            }

            // 3) Complete multipart upload
            let completedUpload = S3ClientTypes.CompletedMultipartUpload(parts: completedParts)
            var completeInput = CompleteMultipartUploadInput(
                bucket: bucket,
                key: key,
                multipartUpload: completedUpload,
                uploadId: uploadId
            )
            completeInput.mpuObjectSize = Int(total)

            let completeOutput = try await client.completeMultipartUpload(input: completeInput)
            debugLog("completeMultipartUpload success. eTag=\(completeOutput.eTag ?? "nil")")
            progress?(total, total)
            debugLog("uploadFile success (multipart): s3://\(bucket)/\(key)")
        } catch {
            // 4) Abort on failure or cancellation
            debugLog("multipart upload failed or cancelled: \(error.localizedDescription). Aborting uploadId=\(uploadId)")
            do {
                let abortInput = AbortMultipartUploadInput(
                    bucket: bucket,
                    key: key,
                    uploadId: uploadId
                )
                _ = try await client.abortMultipartUpload(input: abortInput)
                debugLog("abortMultipartUpload success")
            } catch {
                debugLog("abortMultipartUpload failed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    // MARK: - Folder Operations

    // Creates a "folder" by putting a zero-byte object whose key ends with "/".
    // Returns the normalized folder key (ensures trailing slash).
    func createFolder(bucket: String, key: String) async throws -> String {
        let client = try ensureClientReady()
        var folderKey = key
        if !folderKey.hasSuffix("/") {
            folderKey += "/"
        }
        debugLog("createFolder start. bucket='\(bucket)', key='\(folderKey)'")

        var input = PutObjectInput(
            body: .data(Data()), // zero-byte
            bucket: bucket,
            key: folderKey
        )
        input.contentLength = 0
        input.contentType = "application/x-directory"

        _ = try await client.putObject(input: input)
        debugLog("createFolder success: s3://\(bucket)/\(folderKey)")
        return folderKey
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
            "json": "application/json",
            "webp": "image/webp"
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
