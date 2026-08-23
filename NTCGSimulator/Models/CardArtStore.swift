//
//  CardArtStore.swift
//  NTCGSimulator
//
//  Card illustrations, read from the app bundle.
//
//  The artwork ships inside the app so that every install looks identical —
//  there is no per-device import, and nothing to configure. Files live in
//  Resources/CardArt and are named by collector number, so `N-004.AVIF` is the
//  art for card `N-004` and adding a card's art is just dropping the file in.
//

import UIKit

@Observable
final class CardArtStore {

    /// How many illustrations the bundle carries.
    private(set) var installedCount: Int = 0

    /// Decoded images, keyed by card id plus the size they were decoded for.
    @ObservationIgnored
    private let cache = NSCache<NSString, UIImage>()

    /// Normalised card id -> bundled file URL.
    @ObservationIgnored
    private var manifest: [String: URL] = [:]

    /// Extensions we will look for. AVIF is what a modern iPhone exports and
    /// what the shipped set uses; the rest are accepted so a replacement set
    /// need not be converted first.
    private static let supportedExtensions = [
        "avif", "AVIF", "png", "PNG", "jpg", "JPG", "jpeg", "heic", "HEIC", "webp",
    ]

    /// Folder inside the bundle holding the artwork.
    private static let bundleSubdirectory = "CardArt"

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 64 * 1024 * 1024
        rebuildManifest()
    }

    // MARK: - Lookup

    /// The illustration for a card, or `nil` when the bundle has none.
    func image(forCardID cardID: String) -> UIImage? {
        image(forCardID: cardID, maxPixelSize: 0)
    }

    /// The illustration downsampled to `maxPixelSize` on its longest edge.
    ///
    /// Card art is printed far larger than any slot on the board draws it, so
    /// decoding at full size and letting the GPU shrink it wastes memory on
    /// every card. Zero means full size, for the inspector.
    func image(forCardID cardID: String, maxPixelSize: Int) -> UIImage? {
        let key = "\(cardID)@\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let url = manifest[normalize(cardID)] else { return nil }

        let decoded: UIImage?
        if maxPixelSize > 0 {
            decoded = Self.thumbnail(at: url, maxPixelSize: maxPixelSize)
        } else {
            decoded = UIImage(contentsOfFile: url.path)
        }

        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * 4)
            cache.setObject(decoded, forKey: key, cost: cost)
        }
        return decoded
    }

    /// Whether the bundle carries art for a card.
    func hasArt(forCardID cardID: String) -> Bool {
        manifest[normalize(cardID)] != nil
    }

    // MARK: - Decoding

    /// Decodes a size-appropriate thumbnail rather than the full image.
    private static func thumbnail(at url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Manifest

    /// Indexes the bundled artwork. Cheap, and run once at construction.
    func rebuildManifest() {
        var found: [String: URL] = [:]

        for ext in Self.supportedExtensions {
            let urls = Bundle.main.urls(
                forResourcesWithExtension: ext,
                subdirectory: Self.bundleSubdirectory
            ) ?? []

            // Some build configurations flatten resource folders, so fall back
            // to the bundle root before giving up on an extension.
            let flattened = urls.isEmpty
                ? (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
                : urls

            for url in flattened {
                let stem = url.deletingPathExtension().lastPathComponent
                let key = normalize(stem)
                // First extension in the list wins, so a replacement PNG does
                // not silently shadow the shipped AVIF, or vice versa.
                if found[key] == nil { found[key] = url }
            }
        }

        manifest = found
        installedCount = found.count
        cache.removeAllObjects()
    }

    // MARK: - Name matching

    /// Reduces an id or filename stem to a comparable key: uppercase, letters
    /// and digits only, so `N-004`, `n_004` and `N 004` all agree.
    func normalize(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
