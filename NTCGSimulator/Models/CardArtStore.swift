//
//  CardArtStore.swift
//  NTCGSimulator
//
//  Manages the illustrations the player has installed.
//
//  Artwork is deliberately NOT bundled with the app — card art belongs to the
//  game's publisher. Instead the player drops image files into the app's card
//  art folder and this store matches them to cards by filename, so adding a
//  set of images needs no edits to cards.json at all.
//
//  Those files are whatever the player had to hand, often multi-megapixel
//  photographs. Nothing here ever holds a full-size bitmap: images are
//  downsampled by ImageIO on the way in and the cache is given a hard budget,
//  because a collection grid draws dozens of them at once.
//

import ImageIO
import UIKit

/// The outcome of a bulk import, for reporting back in Settings.
struct ArtImportSummary {
    /// Files that were matched to a card and installed.
    var installed: [String] = []

    /// Filenames that did not correspond to any card in the pool.
    var unmatched: [String] = []

    /// Files that could not be read or copied, with the reason.
    var failed: [(filename: String, reason: String)] = []

    var installedCount: Int { installed.count }

    /// A one-line summary suitable for showing under the import button.
    var message: String {
        var parts: [String] = ["Installed \(installed.count) image\(installed.count == 1 ? "" : "s")"]
        if !unmatched.isEmpty { parts.append("\(unmatched.count) did not match a card") }
        if !failed.isEmpty    { parts.append("\(failed.count) could not be read") }
        return parts.joined(separator: " · ")
    }
}

@Observable
final class CardArtStore {

    /// Number of images currently installed. Observed so Settings updates live.
    private(set) var installedCount: Int = 0

    /// Downsampled images, keyed by card id and decode size. Cleared whenever
    /// art changes, and bounded so a large pool cannot grow it without limit.
    @ObservationIgnored
    private let cache = NSCache<NSString, UIImage>()

    /// Card id -> file URL, rebuilt from disk on demand.
    @ObservationIgnored
    private var manifest: [String: URL] = [:]

    /// Extensions we will attempt to load.
    private static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "gif",
    ]

    /// Decode sizes a request is rounded up to, largest last. Bucketing stops
    /// one card from filling the cache with a dozen near-identical bitmaps.
    private static let thumbnailSizes: [Int] = [128, 256, 512, 1024]

    /// What the plain `image(forCardID:)` decodes to: wide enough for the
    /// full-card inspector on a 3x screen, small enough that a grid of them is
    /// cheap. Callers that know they are drawing smaller can ask for less.
    private static let defaultMaxPixelSize = 1024

    /// Roughly 48 MB of decoded pixels — a few screens' worth of grid — after
    /// which the least recently used art is evicted rather than accumulated.
    private static let cacheCostLimit = 48 * 1024 * 1024

    /// A second ceiling, so a pool of tiny images cannot run up thousands of
    /// entries under the cost limit.
    private static let cacheCountLimit = 256

    init() {
        cache.countLimit = Self.cacheCountLimit
        cache.totalCostLimit = Self.cacheCostLimit
        rebuildManifest()
    }

    // MARK: - Location

    /// The folder illustrations live in.
    static var directoryURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("CardArt", isDirectory: true)
    }

    /// The folder path, for showing the player where to put files.
    var directoryPath: String {
        Self.directoryURL?.path ?? "unavailable"
    }

    private func ensureDirectory() throws {
        guard let directory = Self.directoryURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    // MARK: - Lookup

    /// The installed illustration for a card, if there is one, at the size the
    /// app draws cards at.
    func image(forCardID cardID: String) -> UIImage? {
        image(forCardID: cardID, maxPixelSize: Self.defaultMaxPixelSize)
    }

    /// The installed illustration, decoded no larger than `maxPixelSize` on its
    /// longest edge.
    ///
    /// An imported photograph is routinely 4000px across; drawing it 60pt wide
    /// in the collection grid would otherwise decode ~64 MB to fill a thumbnail.
    func image(forCardID cardID: String, maxPixelSize: Int) -> UIImage? {
        guard let url = manifest[normalize(cardID)] else { return nil }
        return image(at: url, cacheKey: "card:\(cardID)", maxPixelSize: maxPixelSize)
    }

    /// The illustration stored under an explicit filename, for card data that
    /// names its own art files instead of using the collector number.
    ///
    /// Shares the cache and the downsampling with the by-id path so the two
    /// sources cost the same to draw.
    func image(named filename: String) -> UIImage? {
        guard let directory = Self.directoryURL else { return nil }
        let url = directory.appendingPathComponent(filename)
        return image(at: url,
                     cacheKey: "file:\(filename)",
                     maxPixelSize: Self.defaultMaxPixelSize)
    }

    /// Whether a given card has art installed.
    func hasArt(forCardID cardID: String) -> Bool {
        manifest[normalize(cardID)] != nil
    }

    // MARK: - Decoding

    private func image(at url: URL, cacheKey: String, maxPixelSize: Int) -> UIImage? {
        let size = Self.thumbnailSize(fitting: maxPixelSize)
        let key = Self.cacheKey(cacheKey, size: size)

        if let cached = cache.object(forKey: key) { return cached }

        guard let image = Self.thumbnail(at: url, maxPixelSize: size) else { return nil }

        cache.setObject(image, forKey: key, cost: Self.decodedBytes(of: image))
        return image
    }

    /// Builds a downsampled image straight from the file. ImageIO reads only
    /// what it needs, so the full-resolution bitmap never exists in memory.
    private static func thumbnail(at url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour the EXIF orientation a photograph carries, so imported
            // camera shots are not installed sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode here rather than on the first draw, which would land on
            // the main thread mid-scroll.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        return UIImage(cgImage: cgImage)
    }

    /// Rounds a request up to the next bucket, capped at the largest one.
    private static func thumbnailSize(fitting maxPixelSize: Int) -> Int {
        thumbnailSizes.first { $0 >= maxPixelSize } ?? defaultMaxPixelSize
    }

    private static func cacheKey(_ base: String, size: Int) -> NSString {
        "\(base)@\(size)" as NSString
    }

    /// What the decoded bitmap costs the cache, in bytes.
    private static func decodedBytes(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Drops every decoded size held for one card. Art is replaced by card id,
    /// but cached per size, so all the buckets have to go together.
    private func purgeCache(forCardID cardID: String) {
        for size in Self.thumbnailSizes {
            cache.removeObject(forKey: Self.cacheKey("card:\(cardID)", size: size))
        }
    }

    // MARK: - Import

    /// Installs images, matching each file to a card by its filename.
    ///
    /// Matching is forgiving: `N-004.png`, `n004.PNG` and `N-004_alt.jpg` all
    /// resolve to card `N-004`. A file matching nothing is reported rather than
    /// silently dropped, so a mis-named batch is visible instead of mysterious.
    ///
    /// - Parameters:
    ///   - urls: files, or folders whose contents will be scanned one level deep.
    ///   - database: the pool to match ids against.
    @discardableResult
    func importArt(from urls: [URL], database: CardDatabase) -> ArtImportSummary {
        var summary = ArtImportSummary()

        do { try ensureDirectory() }
        catch {
            summary.failed.append((filename: "card art folder",
                                   reason: error.localizedDescription))
            return summary
        }

        // Build a lookup of every acceptable id spelling in the pool.
        let byNormalizedID = Dictionary(
            database.cards.map { (normalize($0.id), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        for url in expand(urls) {
            let filename = url.lastPathComponent

            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                continue    // not an image; skip quietly
            }

            guard let cardID = matchCardID(filename: filename, in: byNormalizedID) else {
                summary.unmatched.append(filename)
                continue
            }

            do {
                try install(url, forCardID: cardID)
                summary.installed.append(cardID)
            } catch {
                summary.failed.append((filename: filename,
                                       reason: error.localizedDescription))
            }
        }

        rebuildManifest()
        return summary
    }

    /// Installs a single image against a specific card, replacing any existing
    /// art for it. Used by the per-card picker on the card detail screen.
    @discardableResult
    func setArt(from url: URL, forCardID cardID: String) -> Result<Void, Error> {
        do {
            try ensureDirectory()
            try install(url, forCardID: cardID)
            rebuildManifest()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Copies a source file into the art folder under the card's id.
    /// Handles security-scoped URLs returned by the document picker.
    private func install(_ source: URL, forCardID cardID: String) throws {
        guard let directory = Self.directoryURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: source)

        // Reject anything that is not actually decodable as an image, so a
        // stray file cannot masquerade as art and render as a blank card.
        // Checked through ImageIO, which reads the header only — decoding a
        // folder of full-size photographs just to validate them is what made
        // importing a batch feel like a hang.
        guard
            let probe = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(probe) > 0,
            CGImageSourceCopyPropertiesAtIndex(probe, 0, nil) != nil
        else {
            throw NSError(domain: "CardArtStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Not a readable image.",
            ])
        }

        let ext = source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("\(cardID).\(ext)")

        // Remove any previous art for this card, whatever its extension.
        removeFiles(forCardID: cardID)
        try data.write(to: destination, options: .atomic)
        purgeCache(forCardID: cardID)
    }

    // MARK: - Removal

    /// Removes the art installed for one card.
    func removeArt(forCardID cardID: String) {
        removeFiles(forCardID: cardID)
        purgeCache(forCardID: cardID)
        rebuildManifest()
    }

    /// Deletes every installed illustration.
    func removeAllArt() {
        guard let directory = Self.directoryURL else { return }
        try? FileManager.default.removeItem(at: directory)
        cache.removeAllObjects()
        rebuildManifest()
    }

    private func removeFiles(forCardID cardID: String) {
        guard let directory = Self.directoryURL else { return }
        let matches = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in matches where url.deletingPathExtension().lastPathComponent == cardID {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Manifest

    /// Re-reads the art folder. Cheap enough to run after any change.
    func rebuildManifest() {
        var found: [String: URL] = [:]

        if let directory = Self.directoryURL,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: directory, includingPropertiesForKeys: nil
           ) {
            for url in contents
            where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                let stem = url.deletingPathExtension().lastPathComponent
                found[normalize(stem)] = url
            }
        }

        manifest = found
        installedCount = found.count
        cache.removeAllObjects()
    }

    // MARK: - Source expansion

    /// Flattens the picker's selection into a list of individual files.
    ///
    /// The document picker hands back whatever the player chose, which may be
    /// a folder. Folders are read one level deep — deep enough for the usual
    /// "a folder of card images" case, shallow enough that picking a home
    /// directory by accident does not walk the whole disk.
    private func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory
            )
            guard exists else { continue }

            if isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                files.append(contentsOf: contents.filter { child in
                    var childIsDirectory: ObjCBool = false
                    _ = FileManager.default.fileExists(
                        atPath: child.path, isDirectory: &childIsDirectory
                    )
                    return !childIsDirectory.boolValue
                })
            } else {
                files.append(url)
            }
        }

        return files
    }

    // MARK: - Filename matching

    /// Reduces an id or filename stem to a comparable key: uppercase, letters
    /// and digits only. `"N-004"`, `"n_004"` and `"N 004"` all become `"N004"`.
    ///
    /// Internal rather than private so the matching rules can be tested
    /// directly — they are the part most likely to surprise someone importing
    /// a large batch of files.
    func normalize(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Resolves a filename to a card id, trying an exact match first and then
    /// a longest-prefix match so decorated names like `N-004_alt` still land.
    ///
    /// Internal for the same reason as `normalize(_:)`.
    func matchCardID(filename: String, in pool: [String: String]) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        let key = normalize(stem)

        if let exact = pool[key] { return exact }

        // Longest matching id that the filename starts with — longest first so
        // `N-1` never wins over `N-104` for the file `N-104.png`.
        return pool.keys
            .filter { key.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
            .flatMap { pool[$0] }
    }
}
