import Foundation
import AVFoundation
import AppKit

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

class VideoThumbnailGenerator {
    private let videoURL: URL
    private let rows: Int
    private let cols: Int
    private let thumbSize: CGSize
    
    init(videoURL: URL, rows: Int = 4, cols: Int = 4, thumbSize: CGSize = CGSize(width: 320, height: 180)) {
        self.videoURL = videoURL
        self.rows = rows
        self.cols = cols
        self.thumbSize = thumbSize
        debugLog("Init VideoThumbnailGenerator. url='\(videoURL.path)', rows=\(rows), cols=\(cols), thumbSize=\(thumbSize)")
    }
    
    func generateThumbnail(mode: ThumbnailMode = .timeframe) async throws -> URL {
        debugLog("generateThumbnail start. mode=\(mode)")
        let asset = AVAsset(url: videoURL)
        
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        debugLog("Video duration seconds=\(durationSeconds)")
        
        let numThumbnails = rows * cols
        var frameTimes: [CMTime] = []
        
        switch mode {
        case .timeframe:
            for i in 0..<numThumbnails {
                let time = CMTime(seconds: durationSeconds * Double(i) / Double(max(numThumbnails - 1, 1)), preferredTimescale: 600)
                frameTimes.append(time)
            }
            debugLog("Timeframe mode. frameTimes.count=\(frameTimes.count)")
        case .sceneChange:
            for i in 0..<numThumbnails {
                let time = CMTime(seconds: durationSeconds * Double(i) / Double(max(numThumbnails - 1, 1)), preferredTimescale: 600)
                frameTimes.append(time)
            }
            debugLog("SceneChange placeholder. frameTimes.count=\(frameTimes.count)")
        }
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        var images: [NSImage] = []
        for time in frameTimes {
            do {
                let cgImage = try await generator.image(at: time).image
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                images.append(nsImage)
            } catch {
                debugLog("Failed to extract frame at time \(CMTimeGetSeconds(time)): \(error.localizedDescription)")
            }
        }
        debugLog("Extracted frames count=\(images.count)")
        
        let gridImage = createGrid(from: images)
        
        let outputURL = getOutputURL()
        try saveImage(gridImage, to: outputURL)
        debugLog("Thumbnail saved to \(outputURL.path)")
        
        return outputURL
    }
    
    private func createGrid(from images: [NSImage]) -> NSImage {
        let aspectRatio: CGFloat = 16.0 / 9.0
        let gridWidth = thumbSize.width * CGFloat(cols)
        let gridHeight = gridWidth / aspectRatio
        let cellWidth = gridWidth / CGFloat(cols)
        let cellHeight = gridHeight / CGFloat(rows)
        debugLog("createGrid: grid=\(Int(gridWidth))x\(Int(gridHeight)), cell=\(Int(cellWidth))x\(Int(cellHeight)), images=\(images.count)")
        
        let gridSize = NSSize(width: gridWidth, height: gridHeight)
        let gridImage = NSImage(size: gridSize)
        
        gridImage.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: gridSize).fill()
        
        for (index, image) in images.enumerated() {
            let row = index / cols
            let col = index % cols
            let x = CGFloat(col) * cellWidth
            let y = CGFloat(rows - row - 1) * cellHeight
            let resizedImage = resizeImage(image, to: NSSize(width: cellWidth, height: cellHeight))
            resizedImage.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        
        gridImage.unlockFocus()
        return gridImage
    }
    
    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let resizedImage = NSImage(size: size)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
        resizedImage.unlockFocus()
        return resizedImage
    }
    
    private func saveImage(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            debugLog("saveImage failed: imageConversionFailed")
            throw ThumbnailError.imageConversionFailed
        }
        try jpegData.write(to: url)
        debugLog("saveImage success to \(url.path)")
    }
    
    private func getOutputURL() -> URL {
        let fileName = videoURL.deletingPathExtension().lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
        let out = tempDir.appendingPathComponent("\(fileName)_thumbnail.jpg")
        debugLog("getOutputURL -> \(out.path)")
        return out
    }
}

enum ThumbnailMode {
    case timeframe
    case sceneChange
}

enum ThumbnailError: LocalizedError {
    case imageConversionFailed
    case frameExtractionFailed
    
    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return "Failed to convert image to JPEG"
        case .frameExtractionFailed:
            return "Failed to extract frames from video"
        }
    }
}
