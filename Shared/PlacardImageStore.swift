import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Image files for placard image layers. They live in the App Group container
/// so the widget extension can read them; the placard model only stores the
/// file name, which keeps saved placards small.
enum PlacardImageStore {
    /// Longest side after import. Plenty for a medium widget at 3x, and small
    /// enough to stay well inside the widget extension's memory budget.
    static let maxPixelLength = 1024

    enum ImportError: LocalizedError {
        case unreadable
        case storageUnavailable

        var errorDescription: String? {
            switch self {
            case .unreadable: "That image couldn't be read."
            case .storageUnavailable: "There's no space to save that image."
            }
        }
    }

    private static let cache = NSCache<NSString, UIImage>()

    private static var directory: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            return nil
        }
        let folder = container.appendingPathComponent("PlacardImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Downscales, orients and stores an image. Opaque photos are saved as
    /// JPEG; images with transparency (cutouts, stickers) as PNG.
    static func importImage(_ data: Data) throws -> (assetID: String, aspectRatio: Double) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelLength,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // ImageIO decodes straight to the target size, so a 48MP photo never has
        // to be fully decoded in memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else {
            throw ImportError.unreadable
        }
        guard let directory else { throw ImportError.storageUnavailable }

        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type: UTType = opaque ? .jpeg : .png
        let assetID = "\(UUID().uuidString).\(opaque ? "jpg" : "png")"
        let url = directory.appendingPathComponent(assetID)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImportError.storageUnavailable
        }
        let properties: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.storageUnavailable }

        return (assetID, Double(image.height) / Double(image.width))
    }

    /// Nil when the file is missing; callers skip the layer rather than fail.
    static func image(for assetID: String) -> UIImage? {
        if let cached = cache.object(forKey: assetID as NSString) { return cached }
        guard let url = directory?.appendingPathComponent(assetID),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: assetID as NSString)
        return image
    }

    /// Deletes files no placard refers to any more. Run when nothing can bring
    /// a reference back (not while an undo is pending), e.g. as the library loads.
    static func removeUnreferenced(keeping referenced: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            cache.removeObject(forKey: file as NSString)
        }
    }
}
