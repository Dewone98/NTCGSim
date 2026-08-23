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
//  The whole store exists to make one guarantee: a card face asked for during a
//  scroll or an animation must never touch the decoder. The printed art is
//  880x1248 at its largest and every screen draws it far smaller, so the store
//  decodes once into a size bucket, keeps the result, and hands the same
//  decoded bitmap back for every subsequent draw. What made that guarantee fail
//  before was cost, not correctness: a full-size decode is 4.2 MB of backing
//  store, so fifteen of them filled the cache and a board showing two dozen
//  cards evicted itself on every render pass. Bucketed thumbnails are a
//  twentieth of that, so a whole screen's worth stays resident.
//

import UIKit

@Observable
final class CardArtStore {

    /// How many illustrations the bundle carries.
    private(set) var installedCount: Int = 0

    /// Decoded images, keyed by card id plus the size they were decoded for.
    @ObservationIgnored
    private let cache = NSCache<NSString, UIImage>()

    /// Normalised card id -> bundled file URL. Read from the prewarm queue as
    /// well as the main thread, so it is only touched under `lock`.
    @ObservationIgnored
    private var manifest: [String: URL] = [:]

    /// Cache keys a background decode is already working on, so two views
    /// asking for the same warm-up do not decode the pool twice.
    @ObservationIgnored
    private var inFlight: Set<String> = []

    /// Guards `manifest` and `inFlight`. `NSCache` is already thread-safe and
    /// is deliberately left outside the lock.
    @ObservationIgnored
    private let lock = NSLock()

    /// Where prewarming happens. Utility, and serial: warming is never more
    /// urgent than the frame being drawn, and one decode at a time keeps the
    /// peak memory of a warm-up to a single full-resolution intermediate.
    @ObservationIgnored
    private let prewarmQueue = DispatchQueue(label: "ntcg.cardart.prewarm", qos: .utility)

    /// Extensions we will look for. AVIF is what a modern iPhone exports and
    /// what the shipped set uses; the rest are accepted so a replacement set
    /// need not be converted first.
    private static let supportedExtensions = [
        "avif", "AVIF", "png", "PNG", "jpg", "JPG", "jpeg", "heic", "HEIC", "webp",
    ]

    /// Folder inside the bundle holding the artwork.
    private static let bundleSubdirectory = "CardArt"

    init() {
        cache.countLimit = Self.entryLimit
        cache.totalCostLimit = Self.byteLimit
        rebuildManifest()
    }

    // MARK: - Cache budget

    /// Enough for the whole shipped pool at two buckets at once, which is what
    /// a phone at 3x actually asks for: the board draws at one bucket and the
    /// hand at the next one up.
    private static let entryLimit = 256

    /// Sized so that no screen can evict its own working set.
    ///
    /// That is the whole point of the number: an eviction inside the set a
    /// screen is currently drawing is not a memory saving, it is another
    /// synchronous decode on the next frame, and a screenful of those is what
    /// made the board stutter in the first place. So the limit is derived from
    /// the largest set the app can hold at once rather than picked round.
    ///
    /// The board is the worst case, because it draws two sizes together — the
    /// mat's slots and the larger faces in the hand — and warms both for the
    /// whole thirty-five card pool. At 3x that is the 512px and 768px buckets
    /// side by side:
    ///
    ///     35 x 361x512x4  ~= 25 MB
    ///     35 x 542x768x4  ~= 56 MB
    ///                        81 MB
    ///
    /// At 2x both sizes land on the same bucket and the same total is a third
    /// of that. The Collection grid is a subset of the larger half. Ninety-six
    /// megabytes clears the worst case with room for the inspector's full-size
    /// decode on top. `NSCache` still empties itself under real memory
    /// pressure, so this is a ceiling and not a reservation.
    private static let byteLimit = 96 * 1024 * 1024

    /// Longest-edge pixel sizes the store will decode at.
    ///
    /// Requests are rounded up to one of these rather than honoured exactly.
    /// A board slot is a fraction of a point wider on one device than another,
    /// and a scroll or a rotation moves it again; keying the cache on the exact
    /// size would mint a new key — and a new decode — for each of those. Four
    /// rungs cover every draw size in the app from a 30pt board slot to the
    /// inspector, and the gap between rungs costs nothing, because decode time
    /// is set by the source bitstream and is very nearly the same whichever
    /// thumbnail size is asked for.
    private static let buckets = [256, 512, 768, 1024]

    /// The bucket that will hold `longestEdge` device pixels without upscaling.
    ///
    /// Returns zero — the full printing — once the request outgrows the ladder,
    /// which is the inspector and nothing else. The art carries the printed name
    /// bar and the printed numbers as pixels, so undershooting would soften real
    /// lettering: the ladder always rounds up, never down.
    static func bucket(forLongestEdge longestEdge: Int) -> Int {
        guard longestEdge > 0 else { return 0 }
        return buckets.first { $0 >= longestEdge } ?? 0
    }

    // MARK: - Lookup

    /// The illustration for a card at its full printed size.
    ///
    /// Only the inspector wants this. Everything else goes through the
    /// size-aware variant, because a full decode is twenty times the memory of
    /// the bucket a board slot needs and evicts the rest of the screen with it.
    func image(forCardID cardID: String) -> UIImage? {
        image(forCardID: cardID, maxPixelSize: 0)
    }

    /// The illustration downsampled to `maxPixelSize` on its longest edge.
    ///
    /// Card art is printed far larger than any slot on the board draws it, so
    /// decoding at full size and letting the GPU shrink it wastes memory on
    /// every card. Zero means full size, for the inspector.
    func image(forCardID cardID: String, maxPixelSize: Int) -> UIImage? {
        let key = Self.cacheKey(cardID, maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }

        guard let url = url(forCardID: cardID) else { return nil }

        let decoded: UIImage?
        if maxPixelSize > 0 {
            decoded = Self.thumbnail(at: url, maxPixelSize: maxPixelSize)
        } else {
            decoded = Self.fullSize(at: url)
        }

        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * 4)
            cache.setObject(decoded, forKey: key as NSString, cost: cost)
        }
        return decoded
    }

    /// Whether the bundle carries art for a card.
    func hasArt(forCardID cardID: String) -> Bool {
        url(forCardID: cardID) != nil
    }

    private func url(forCardID cardID: String) -> URL? {
        let key = normalize(cardID)
        lock.lock()
        defer { lock.unlock() }
        return manifest[key]
    }

    private static func cacheKey(_ cardID: String, _ maxPixelSize: Int) -> String {
        "\(cardID)@\(maxPixelSize)"
    }

    // MARK: - Prewarming

    /// Decodes a set of cards into the cache off the main thread.
    ///
    /// A decode is around ten to thirty milliseconds — more than a whole frame
    /// at 60Hz — and it happens inside `body`, on the main thread, the first
    /// time a face is drawn. Dealing an opening hand asks for two dozen of them
    /// at once, which is most of a second of stalled main thread before the
    /// board appears. Warming the same cards on a utility queue moves that work
    /// off the frame entirely: by the time a face is drawn the answer is a
    /// cache hit, and a cache hit is a pointer.
    ///
    /// Safe to call repeatedly and from several views at once. Ids already
    /// decoded at this bucket, or already being decoded, are skipped, so the
    /// two board sides warming the same pool do the work once.
    func prewarm(cardIDs: [String], maxPixelSize: Int) {
        let pending = claim(cardIDs, maxPixelSize: maxPixelSize)
        guard !pending.isEmpty else { return }

        prewarmQueue.async { [weak self] in
            guard let self else { return }
            for cardID in pending {
                _ = self.image(forCardID: cardID, maxPixelSize: maxPixelSize)
            }
            self.release(pending, maxPixelSize: maxPixelSize)
        }
    }

    /// The ids this call is responsible for: not already decoded, and not
    /// already claimed by another warm-up.
    private func claim(_ cardIDs: [String], maxPixelSize: Int) -> [String] {
        var pending: [String] = []
        lock.lock()
        for cardID in cardIDs {
            let key = Self.cacheKey(cardID, maxPixelSize)
            guard !inFlight.contains(key) else { continue }
            guard manifest[normalize(cardID)] != nil else { continue }
            if cache.object(forKey: key as NSString) != nil { continue }
            inFlight.insert(key)
            pending.append(cardID)
        }
        lock.unlock()
        return pending
    }

    private func release(_ cardIDs: [String], maxPixelSize: Int) {
        lock.lock()
        for cardID in cardIDs {
            inFlight.remove(Self.cacheKey(cardID, maxPixelSize))
        }
        lock.unlock()
    }

    // MARK: - Decoding

    /// Decodes a size-appropriate thumbnail rather than the full image.
    ///
    /// `kCGImageSourceShouldCacheImmediately` is what makes the result usable
    /// from a background queue: without it ImageIO hands back an image whose
    /// pixels are produced lazily, and the decode simply moves to whichever
    /// thread first draws it — the main one, mid-frame, which is the cost this
    /// whole path is trying to avoid.
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
            return fullSize(at: url)
        }
        return UIImage(cgImage: cgImage)
    }

    /// The whole printing, decoded eagerly for the same reason the thumbnail is.
    private static func fullSize(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else {
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

        lock.lock()
        manifest = found
        lock.unlock()

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
