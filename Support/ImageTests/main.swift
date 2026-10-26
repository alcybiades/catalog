import AppKit
import ImageIO
import UniformTypeIdentifiers

_ = NSApplication.shared
var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
@discardableResult
func waitFor(_ name: String, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(15)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    if !condition() { check(name + " completed before timeout", false) }
    return condition()
}
func cgImage(_ image: NSImage?) -> CGImage? { image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("write-images-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixture) }
let original = fixture.appendingPathComponent("Original.png")
let cache = fixture.appendingPathComponent("cache")
func writeFixture(_ url: URL, red: CGFloat, orientation: Int = 1) {
    autoreleasepool {
        let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        context.setFillColor(CGColor(red: 0.1, green: 0.9, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 1800, y: 600, width: 1000, height: 1200))
        let type = url.pathExtension == "jpg" ? UTType.jpeg : .png
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
    }
}
writeFixture(original, red: 0.8)
let originalBytes = try Data(contentsOf: original)
let loader = ImageLoader(cacheDirectory: cache, memoryLimit: 1024 * 1024, diskLimit: 1024 * 1024)
check("retina thumbnail size is display-sized", ImageLoader.thumbnailPixels(points: 160, scale: 2) == 384)
var thumbnail: CGImage?
var loaded = false
let first = loader.thumbnail(original, pixels: 384) {
    check("thumbnail delivery is on main for view updates", Thread.isMainThread)
    thumbnail = $0; loaded = true
}
var duplicateLoaded = false
loader.thumbnail(original, pixels: 384) { duplicateLoaded = $0 != nil }
check("identical visible requests share one flight", loader.pendingThumbnailCount == 1)
waitFor("thumbnail", { loaded && duplicateLoaded })
check("thumbnail is bounded and keeps aspect ratio", thumbnail?.width == 384 && thumbnail?.height == 288)
check("duplicate requests decode source once", loader.statistics.thumbnailDecodes == 1)
let thumbCost = thumbnail.map { $0.bytesPerRow * $0.height } ?? 0
check("cache accounts for actual decoded bytes", loader.cachedThumbnailBytes == thumbCost)
loaded = false
loader.thumbnail(original, pixels: 384) { loaded = $0 != nil }
waitFor("memory hit", { loaded })
check("repeat scrolling uses decoded memory cache", loader.statistics.memoryHits == 1)
let warmLoader = ImageLoader(cacheDirectory: cache)
loaded = false
warmLoader.thumbnail(original, pixels: 384) { loaded = $0 != nil }
waitFor("disk hit", { loaded })
check("relaunch uses cached thumbnail without source decode", warmLoader.statistics.diskHits == 1 && warmLoader.statistics.thumbnailDecodes == 0)

var full: NSImage?
var fullLoaded = false
loader.original(original) { full = $0; fullLoaded = true }
waitFor("original", { fullLoaded })
let fullCG = cgImage(full)
check("viewer loads original native resolution above old 2800 cap", fullCG?.width == 4000 && fullCG?.height == 3000)
check("original does not enter thumbnail cache", loader.cachedThumbnailBytes == thumbCost)
func pixel(_ image: CGImage?, x: Int, y: Int) -> [UInt8] {
    guard let crop = image?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return [] }
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
}
autoreleasepool {
    let source = CGImageSourceCreateWithURL(original as CFURL, nil)!
    let originalCG = CGImageSourceCreateImageAtIndex(source, 0, nil)
    check("original preview preserves source pixels", pixel(fullCG, x: 100, y: 100) == pixel(originalCG, x: 100, y: 100) && pixel(fullCG, x: 2200, y: 1800) == pixel(originalCG, x: 2200, y: 1800))
}
print("DECODED BYTES: thumbnail=\(thumbCost), original=\(fullCG.map { $0.bytesPerRow * $0.height } ?? 0)")
full = nil
check("source file remains untouched", try Data(contentsOf: original) == originalBytes)

let rotated = fixture.appendingPathComponent("Portrait.jpg")
writeFixture(rotated, red: 0.8, orientation: 6)
loaded = false
loader.original(rotated) { image in
    check("original preserves native dimensions with EXIF rotation", cgImage(image)?.width == 3000 && cgImage(image)?.height == 4000)
    loaded = true
}
waitFor("oriented original", { loaded })
loaded = false
loader.thumbnail(rotated, pixels: 384) { image in
    check("thumbnail also applies EXIF rotation", image?.width == 288 && image?.height == 384)
    loaded = true
}
waitFor("oriented thumbnail", { loaded })

let changed = fixture.appendingPathComponent("Changed.png")
try FileManager.default.copyItem(at: original, to: changed)
var cancelledCallback = false
let cancelled = loader.thumbnail(changed, pixels: 384) { _ in cancelledCallback = true }
loaded = false
loader.thumbnail(changed, pixels: 384) { loaded = $0 != nil }
cancelled.cancel()
waitFor("remaining subscriber", { loaded })
check("cancelling one subscriber preserves another", !cancelledCallback)
let decodesBefore = loader.statistics.thumbnailDecodes
writeFixture(changed, red: 0.3)
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: changed.path)
loaded = false
loader.thumbnail(changed, pixels: 384) { loaded = $0 != nil }
waitFor("modified image", { loaded })
check("editing source invalidates thumbnail caches", loader.statistics.thumbnailDecodes == decodesBefore + 1)

// Exercise an eviction budget and a burst of offscreen requests against many
// original files, without keeping their decoded pixels in the test fixture.
var files: [URL] = []
for index in 0..<120 {
    let url = fixture.appendingPathComponent("Image-\(index).png")
    try FileManager.default.copyItem(at: original, to: url); files.append(url)
}
var completed = 0
let begin = Date()
for url in files.prefix(12) { loader.thumbnail(url, pixels: 384) { _ in completed += 1 } }
waitFor("cache eviction batch", { completed == 12 })
check("decoded thumbnail cache stays inside budget", loader.cachedThumbnailBytes <= 1024 * 1024)
let cacheFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])
let diskBytes = cacheFiles.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
check("disk thumbnail cache stays inside budget", diskBytes <= 1024 * 1024)
var offscreenCallbacks = 0
for url in files {
    let request = loader.thumbnail(url, pixels: 384) { _ in offscreenCallbacks += 1 }
    request.cancel()
}
check("offscreen cancellation clears pending requests immediately", loader.pendingThumbnailCount == 0)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
check("cancelled cells never receive late images", offscreenCallbacks == 0)
print(String(format: "12 original-to-thumbnail decodes: %.3fs; cached thumbnail bytes: %d", Date().timeIntervalSince(begin), loader.cachedThumbnailBytes))
check("original request cancellation is supported", { let request = loader.original(original) { _ in check("cancelled original callback suppressed", false) }; request.cancel(); return request.isCancelled }())
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
print(failures == 0 ? "ALL IMAGE TESTS PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
