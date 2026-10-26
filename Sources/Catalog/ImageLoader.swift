import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Owned by a visible cell/viewer. Cancellation also removes its completion,
/// so a long scroll never leaves a queue of requests retaining old cells.
final class ImageRequest {
    private(set) var isCancelled = false
    fileprivate var onCancel: (() -> Void)?
    func cancel() {
        precondition(Thread.isMainThread)
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}

private final class ThumbnailMemoryCache {
    private struct Entry { let image: CGImage; let cost: Int; var access: UInt64 }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    let limit: Int
    init(limit: Int) { self.limit = limit }
    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    func image(for key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry
        return entry.image
    }
    func insert(_ image: CGImage, for key: String) {
        let cost = image.bytesPerRow * image.height
        guard cost <= limit else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { bytes -= old.cost }
        while bytes + cost > limit, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            bytes -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
        }
        clock &+= 1
        entries[key] = Entry(image: image, cost: cost, access: clock); bytes += cost
    }
    func removeAll() { lock.lock(); entries.removeAll(); bytes = 0; lock.unlock() }
}

/// Lossless thumbnail files only. Access and eviction run off the main thread;
/// build the directory index once rather than rescanning it on every scroll.
private final class ThumbnailDiskCache {
    private struct Entry { let bytes: Int; var access: Date }
    private let queue = DispatchQueue(label: "Catalog.thumbnail-disk", qos: .utility)
    private let directory: URL
    private let limit: Int
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var indexed = false
    init(directory: URL, limit: Int) { self.directory = directory; self.limit = limit }
    private func index() {
        guard !indexed else { return }
        indexed = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        for url in urls where url.pathExtension == "png" && url.deletingPathExtension().lastPathComponent.count == 64 {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize else { continue }
            entries[url.lastPathComponent] = Entry(bytes: size, access: values.contentModificationDate ?? .distantPast)
            bytes += size
        }
        evict(to: limit)
    }
    private func evict(to target: Int) {
        while bytes > target, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldest.key))
            bytes -= oldest.value.bytes; entries.removeValue(forKey: oldest.key)
        }
    }
    func read(_ key: String) -> Data? {
        queue.sync {
            index()
            let name = key + ".png"
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            let now = Date()
            entries[name]?.access = now
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: directory.appendingPathComponent(name).path)
            return data
        }
    }
    func write(_ data: Data, key: String) {
        guard data.count <= limit else { return }
        queue.sync {
            index()
            let name = key + ".png"
            if let old = entries.removeValue(forKey: name) { bytes -= old.bytes }
            evict(to: limit - data.count)
            if (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil {
                entries[name] = Entry(bytes: data.count, access: Date()); bytes += data.count
            }
        }
    }
}

/// Separate budgets and queues: opening an original never waits behind browser
/// thumbnails, and original pixels never enter either thumbnail cache.
final class ImageLoader {
    static let shared = ImageLoader()
    static let thumbnailMemoryLimit = 64 * 1024 * 1024
    static let thumbnailDiskLimit = 256 * 1024 * 1024
    private let memory: ThumbnailMemoryCache
    private let disk: ThumbnailDiskCache
    private let thumbnails = OperationQueue()
    private let originals = OperationQueue()
    private var flights: [String: Flight] = [:] // main-thread confined
    private var pressure: DispatchSourceMemoryPressure?
    struct Statistics {
        var memoryHits = 0
        var diskHits = 0
        var thumbnailDecodes = 0
        var originalDecodes = 0
    }
    private let statisticsLock = NSLock()
    private var counts = Statistics()
    var statistics: Statistics {
        statisticsLock.lock(); defer { statisticsLock.unlock() }; return counts
    }
    private func record(_ update: (inout Statistics) -> Void) {
        statisticsLock.lock(); update(&counts); statisticsLock.unlock()
    }
    private final class Flight {
        let id = UUID()
        let operation = BlockOperation()
        var subscribers: [UUID: (ImageRequest, (CGImage?) -> Void)] = [:]
    }
    var cachedThumbnailBytes: Int { memory.byteCount }
    var pendingThumbnailCount: Int { flights.count }

    init(cacheDirectory: URL? = nil, memoryLimit: Int = ImageLoader.thumbnailMemoryLimit,
         diskLimit: Int = ImageLoader.thumbnailDiskLimit) {
        memory = ThumbnailMemoryCache(limit: memoryLimit)
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.grant.catalog/Thumbnails-v1", isDirectory: true)
        disk = ThumbnailDiskCache(directory: directory, limit: diskLimit)
        thumbnails.name = "Catalog.thumbnails"; thumbnails.maxConcurrentOperationCount = 2; thumbnails.qualityOfService = .userInitiated
        originals.name = "Catalog.originals"; originals.maxConcurrentOperationCount = 1; originals.qualityOfService = .userInitiated
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure?.setEventHandler { [weak self] in self?.memory.removeAll() }
        pressure?.resume()
    }
    deinit { pressure?.cancel(); thumbnails.cancelAllOperations(); originals.cancelAllOperations() }

    /// Bucket pixel sizes to reuse previews across displays with the same scale.
    static func thumbnailPixels(points: CGFloat, scale: CGFloat) -> Int {
        min(768, max(128, Int(ceil(points * scale / 128)) * 128))
    }

    @discardableResult
    func thumbnail(_ url: URL, pixels: Int, completion: @escaping (CGImage?) -> Void) -> ImageRequest {
        precondition(Thread.isMainThread)
        let request = ImageRequest()
        let pixels = min(768, max(128, pixels))
        // URL normalization and filesystem metadata belong to versionKey on
        // the worker. The in-flight key only needs a cheap request identity.
        let key = url.absoluteString + "#\(pixels)"
        let subscriber = UUID()
        let flight = flights[key] ?? Flight()
        flight.subscribers[subscriber] = (request, completion)
        request.onCancel = { [weak self, weak flight] in
            guard let self, let flight else { return }
            flight.subscribers.removeValue(forKey: subscriber)
            if flight.subscribers.isEmpty {
                flight.operation.cancel()
                if self.flights[key]?.id == flight.id { self.flights.removeValue(forKey: key) }
            }
        }
        if flights[key] != nil { return request }
        flights[key] = flight
        let id = flight.id
        let operation = flight.operation
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, operation?.isCancelled == false else { return }
            let image: CGImage? = autoreleasepool {
                precondition(!Thread.isMainThread)
                guard let version = Self.versionKey(url, pixels: pixels) else { return nil }
                if let cached = self.memory.image(for: version) { self.record { $0.memoryHits += 1 }; return cached }
                if let data = self.disk.read(version), let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let cached = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                   max(cached.width, cached.height) <= pixels {
                    self.record { $0.diskHits += 1 }
                    self.memory.insert(cached, for: version); return cached
                }
                guard operation?.isCancelled == false,
                      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = Self.decode(source, pixels: pixels), operation?.isCancelled == false else { return nil }
                self.record { $0.thumbnailDecodes += 1 }
                self.memory.insert(image, for: version)
                if let data = Self.png(image), operation?.isCancelled == false { self.disk.write(data, key: version) }
                return image
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let completed = self.flights[key], completed.id == id else { return }
                self.flights.removeValue(forKey: key)
                for (request, completion) in completed.subscribers.values where !request.isCancelled {
                    request.onCancel = nil; completion(image)
                }
            }
        }
        thumbnails.addOperation(operation)
        return request
    }

    @discardableResult
    func original(_ url: URL, completion: @escaping (NSImage?) -> Void) -> ImageRequest {
        precondition(Thread.isMainThread)
        let request = ImageRequest()
        let operation = BlockOperation()
        request.onCancel = { [weak operation] in operation?.cancel() }
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            self?.record { $0.originalDecodes += 1 }
            let image: CGImage? = autoreleasepool {
                precondition(!Thread.isMainThread)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                if orientation == 1 {
                    return CGImageSourceCreateImageAtIndex(source, 0, [
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceShouldAllowFloat: true,
                    ] as CFDictionary)
                }
                // Apply EXIF orientation at the full source dimensions.
                // No 2,800px limit, lossy re-encoding, or original disk cache.
                return Self.decode(source, pixels: max(width, height))
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async {
                guard !request.isCancelled else { return }
                request.onCancel = nil
                completion(image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
            }
        }
        originals.addOperation(operation)
        return request
    }

    private static func decode(_ source: CGImageSource, pixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
    private static func versionKey(_ url: URL, pixels: Int) -> String? {
        // Fresh metadata, off the main thread; NSURL resource caches can retain
        // an old modification date after another app edits the file.
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        let value = "v1|\(url.standardizedFileURL.path)|\(modified)|\(size)|\(pixels)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
