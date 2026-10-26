import SwiftUI
import ImageIO

/// Downloads through the Wikipedia session (Wikimedia requires a real
/// User-Agent) and decodes downsampled pixels off the main thread.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 192 << 20
        return cache
    }()
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel))?.image
    }

    func image(for url: URL, maxPixel: Int) async -> CGImage? {
        let key = key(url, maxPixel)
        if let hit = cache.object(forKey: key) { return hit.image }
        if let running = inflight[key as String] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let (data, response) = try? await WikipediaClient.session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return Self.decode(data, maxPixel: maxPixel)
        }
        inflight[key as String] = task
        let image = await task.value
        inflight[key as String] = nil
        if let image { cache.setObject(Box(image), forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(maxPixel)|\(url.absoluteString)" as NSString }

    private static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension WikiImage {
    /// A larger standard Wikimedia rendition for full-screen viewing; never
    /// wider than the source file, which Wikimedia refuses to upscale.
    var largeURL: URL {
        let string = url.absoluteString
        guard string.contains("/thumb/"),
              let range = string.range(of: #"/\d+px-"#, options: .regularExpression) else { return url }
        let current = Int(string[range].dropFirst().prefix { $0.isNumber }) ?? 0
        let isVector = string.lowercased().contains(".svg/")
        let target = isVector ? 1920 : 1280
        guard current < target else { return url }
        if !isVector, let originalWidth, originalWidth <= Double(target) {
            // Small sources: the original file itself.
            var original = string[..<range.lowerBound].replacingOccurrences(of: "/thumb/", with: "/")
            original = original.replacingOccurrences(of: "//thumb.wikimedia.org/", with: "//upload.wikimedia.org/")
            return URL(string: original) ?? url
        }
        guard isVector || originalWidth != nil else { return url }
        return URL(string: string.replacingCharacters(in: range, with: "/\(target)px-")) ?? url
    }
}

/// Fills its frame with the image, fading in when it arrives.
struct RemoteImage: View {
    let url: URL
    var maxPixel: Int = 1400
    var contentMode: ContentMode = .fill
    /// Reports the decoded pixel size, for images whose size the page didn't give.
    var onLoad: ((CGSize) -> Void)? = nil

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(WikiTheme.wash.opacity(image == nil ? 0.05 : 0))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(WikiTheme.secondary.opacity(0.6))
            }
        }
        .task(id: url) {
            if let cached = await ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
                image = cached
                onLoad?(CGSize(width: cached.width, height: cached.height))
                return
            }
            let loaded = await ImagePipeline.shared.image(for: url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                image = loaded
                failed = loaded == nil
            }
            if let loaded { onLoad?(CGSize(width: loaded.width, height: loaded.height)) }
        }
    }
}

/// Full-window image viewer with pinch / scroll zoom.
struct ImageViewer: View {
    let image: WikiImage
    let caption: AttributedString?
    /// Closes an in-window viewer; a presented one dismisses itself.
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @AppStorage(WikiTheme.bodyFontKey, store: AppState.defaults) private var bodyFamily = WikiTheme.defaultBodyFamily

    var body: some View {
        ZStack {
            // The same translucent backdrop as the rest of the app: on the
            // Mac the window's own blur and tint show through.
            #if os(iOS)
            Backdrop()
            #else
            Color.clear.contentShape(Rectangle())
            #endif
            Color.clear
                .aspectRatio(image.aspectRatio, contentMode: .fit)
                .overlay { RemoteImage(url: image.largeURL, maxPixel: 2800, contentMode: .fit) }
                .clipShape(RoundedRectangle(cornerRadius: scale > 1.01 ? 0 : 12, style: .continuous))
                .scaleEffect(scale)
                .offset(offset)
                .padding(24)
                .gesture(magnify.simultaneously(with: drag))
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        if scale > 1.01 { resetZoom() } else { scale = 2.5; committedScale = 2.5 }
                    }
                }
            VStack {
                HStack {
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WikiTheme.foreground)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                }
                Spacer()
                if let caption, scale <= 1.01 {
                    Text(WikiTheme.styled(caption))
                        .font(WikiTheme.body(bodyFamily, size: 15))
                        .foregroundStyle(WikiTheme.foreground.opacity(0.9))
                        .tint(WikiTheme.link)
                        .lineSpacing(3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(20)
        }
        .preferredColorScheme(WikiTheme.colorScheme)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(committedScale * value.magnification, 1), 6) }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1.01 { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { resetZoom() } }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.01 {
                    offset = CGSize(width: committedOffset.width + value.translation.width,
                                    height: committedOffset.height + value.translation.height)
                } else {
                    offset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    committedOffset = offset
                } else if value.translation.height > 140 {
                    close()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { offset = .zero }
                }
            }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func resetZoom() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }
}
