import Foundation

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

struct S3Lister {
    private let s3Service: S3Service
    
    init() {
        debugLog("S3Lister init")
        self.s3Service = S3Service()
    }
    
    func listBuckets() async throws -> [String] {
        debugLog("listBuckets called")
        let buckets = try await s3Service.listBuckets()
        debugLog("listBuckets success. count=\(buckets.count)")
        return buckets
    }
    
    func listObjects(bucket: String, prefix: String = "") async throws -> [S3Item] {
        debugLog("listObjects called. bucket='\(bucket)', prefix='\(prefix)'")
        let items = try await s3Service.listObjects(bucket: bucket, prefix: prefix)
        debugLog("listObjects success. returned items=\(items.count)")
        return items
    }
}
