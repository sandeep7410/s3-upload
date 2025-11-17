import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import ImageIO

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

class VideoThumbnailGenerator {
    private let videoURL: URL
    private let rows: Int
    private let cols: Int
    private let thumbSize: CGSize
    private let aspectRatio: CGFloat
    
    // Tunables for output size/quality
    // Lower quality -> smaller files.
    private let webPQuality: CGFloat = 0.5
    private let jpegQuality: CGFloat = 0.5
    
    init(videoURL: URL, rows: Int = 4, cols: Int = 4, thumbSize: CGSize = CGSize(width: 320, height: 180), aspectRatio: CGFloat=16.0/9.0) {
        self.videoURL = videoURL
        self.rows = rows
        self.cols = cols
        self.thumbSize = thumbSize
        self.aspectRatio = aspectRatio
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
        
        let (outputURL, preferWebP) = getOutputURL()
        do {
            try saveImage(gridImage, to: outputURL, preferWebP: preferWebP)
            debugLog("Thumbnail saved to \(outputURL.path)")
            return outputURL
        } catch {
            debugLog("WebP save failed (\(error.localizedDescription)); falling back to JPEG")
            let fallbackURL = outputURL.deletingPathExtension().appendingPathExtension("jpg")
            try saveImageAsJPEG(gridImage, to: fallbackURL)
            debugLog("Thumbnail saved (JPEG fallback) to \(fallbackURL.path)")
            return fallbackURL
        }
    }
    
    private func createGrid(from images: [NSImage]) -> NSImage {
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

    // MARK: - Saving (WebP preferred, JPEG fallback)

    private func saveImage(_ image: NSImage, to url: URL, preferWebP: Bool) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            debugLog("saveImage failed: no CGImage")
            throw ThumbnailError.imageConversionFailed
        }

        if preferWebP, let webPType = webPTypeIdentifier() {
            // Build WebP properties to target smaller file sizes (lossy, reduced quality).
            let props = webPProperties(quality: webPQuality)
            if saveCGImage(cgImage, to: url, type: webPType, properties: props) {
                return
            } else {
                throw ThumbnailError.imageConversionFailed
            }
        } else {
            // If not preferring WebP or unavailable, fall back to JPEG
            try saveImageAsJPEG(image, to: url.deletingPathExtension().appendingPathExtension("jpg"))
        }
    }

    private func saveImageAsJPEG(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
            debugLog("saveImageAsJPEG failed: imageConversionFailed")
            throw ThumbnailError.imageConversionFailed
        }
        try jpegData.write(to: url)
    }

    private func saveCGImage(_ cgImage: CGImage, to url: URL, type: CFString, properties: [CFString: Any]) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - WebP properties and type resolution

    // Provide SDK-agnostic CFString keys for WebP dictionary entries.
    // On newer SDKs, the kCGImagePropertyWebP* constants exist; on older ones, we use string literals.
    private var webPDictionaryKey: CFString {
        // kCGImagePropertyWebPDictionary is available on newer SDKs; else fallback to its name.
        // We can’t reference it directly if it doesn't exist at compile-time, so just use the literal.
        return "WebP" as CFString // Same as kCGImagePropertyWebPDictionary without requiring symbol
    }

    private var webPLosslessKey: CFString {
        // "Lossless" key inside the WebP dictionary
        return "Lossless" as CFString // same semantic as kCGImagePropertyWebPLossless
    }

    private var webPCompressionFactorKey: CFString {
        // "CompressionFactor" key inside the WebP dictionary
        return "CompressionFactor" as CFString // same semantic as kCGImagePropertyWebPCompressionFactor
    }

    // Build a WebP properties dictionary aimed at smaller file sizes
    private func webPProperties(quality: CGFloat) -> [CFString: Any] {
        var props: [CFString: Any] = [:]
        // General lossy compression quality (0.0 ... 1.0)
        props[kCGImageDestinationLossyCompressionQuality] = NSNumber(value: Double(quality))
        // WebP-specific dictionary
        var webpDict: [CFString: Any] = [:]
        // Force lossy (lossless often produces larger files)
        webpDict[webPLosslessKey] = false as CFBoolean
        // Some systems accept a compression factor key in the WebP dictionary too
        webpDict[webPCompressionFactorKey] = NSNumber(value: Double(quality))
        props[webPDictionaryKey] = webpDict as CFDictionary
        return props
    }

    // Try to resolve WebP UTI/UTType
    private func webPTypeIdentifier() -> CFString? {
        if #available(macOS 11.0, *) {
            if let type = UTType.webP.identifier as CFString? {
                return type
            }
        }
        // Fallback for older SDKs where UTType.webP may not exist, common UTI string:
        // "public.webp" is widely used; some systems may also accept "org.webmproject.webp"
        return "public.webp" as CFString
    }
    
    private func getOutputURL() -> (URL, Bool) {
        let fileName = videoURL.deletingPathExtension().lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
        // Prefer WebP name; we will fall back to JPEG if encoding fails.
        let out = tempDir.appendingPathComponent("\(fileName)_thumbnail.webp")
        debugLog("getOutputURL -> \(out.path)")
        return (out, true)
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
            return "Failed to convert image"
        case .frameExtractionFailed:
            return "Failed to extract frames from video"
        }
    }
}
