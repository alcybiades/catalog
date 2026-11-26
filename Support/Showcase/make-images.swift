// Regenerates the showcase image library: `swift Support/Showcase/make-images.swift`.
import AppKit

let size = CGSize(width: 1200, height: 900)
let library = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "Support/Showcase/Notebook/Library")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ c: CGContext, _ colors: [UInt32], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors.map { color($0) } as CFArray, locations: nil)!
    c.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func glow(_ c: CGContext, _ hex: UInt32, at p: CGPoint, radius: CGFloat, alpha: CGFloat = 0.85) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}

/// Layered hills under a sky with a low sun.
func horizon(_ c: CGContext, sky: [UInt32], sun: UInt32, hills: [UInt32], seed: Double) {
    linear(c, sky, from: CGPoint(x: 0, y: size.height), to: .zero)
    let sunCenter = CGPoint(x: size.width * (0.3 + 0.4 * seed), y: size.height * 0.46)
    glow(c, sun, at: sunCenter, radius: 420, alpha: 0.55)
    c.setFillColor(color(sun, 0.95))
    c.fillEllipse(in: CGRect(x: sunCenter.x - 70, y: sunCenter.y - 70, width: 140, height: 140))
    for (i, hex) in hills.enumerated() {
        let base = size.height * (0.42 - 0.11 * Double(i))
        let path = CGMutablePath()
        path.move(to: .zero)
        for x in stride(from: 0.0, through: size.width, by: 8) {
            let t = x / size.width
            let y = base + 46 * sin(t * (3 + Double(i)) + seed * 7 + Double(i)) + 22 * sin(t * 11 + Double(i) * 2)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: 0))
        path.closeSubpath()
        c.addPath(path); c.setFillColor(color(hex)); c.fillPath()
    }
}

/// Soft overlapping color fields.
func aura(_ c: CGContext, base: UInt32, glows: [UInt32], seed: Double) {
    c.setFillColor(color(base)); c.fill(CGRect(origin: .zero, size: size))
    for (i, hex) in glows.enumerated() {
        let a = seed * 6 + Double(i) * 2.4
        let p = CGPoint(x: size.width * (0.5 + 0.36 * cos(a)), y: size.height * (0.5 + 0.36 * sin(a * 1.3)))
        glow(c, hex, at: p, radius: 560)
    }
}

/// Concentric rings around an off-center point.
func orbit(_ c: CGContext, base: [UInt32], ring: UInt32, seed: Double) {
    linear(c, base, from: .zero, to: CGPoint(x: size.width, y: size.height))
    let center = CGPoint(x: size.width * (0.35 + 0.3 * seed), y: size.height * 0.55)
    for i in 0..<14 {
        let r = 40 + CGFloat(i) * 34
        c.setStrokeColor(color(ring, 0.5 - CGFloat(i) * 0.03))
        c.setLineWidth(i % 3 == 0 ? 3 : 1.2)
        c.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }
    glow(c, ring, at: center, radius: 140, alpha: 0.7)
}

let images: [(String, (CGContext) -> Void)] = [
    ("Horizons/dawn.jpg", { horizon($0, sky: [0xFAD0C4, 0xF6A6A1, 0x8E7CC3], sun: 0xFFF1D6, hills: [0x7A6AA8, 0x5B4E8C, 0x3C3466], seed: 0.2) }),
    ("Horizons/dusk.jpg", { horizon($0, sky: [0xFF9A62, 0xD9576B, 0x3A2D5C], sun: 0xFFE3A3, hills: [0x6B2E59, 0x4A2148, 0x2A1433], seed: 0.7) }),
    ("Horizons/mist.jpg", { horizon($0, sky: [0xE8EEF2, 0xC9D6DF, 0x9FB4C3], sun: 0xFFFFFF, hills: [0x8EA5B5, 0x6E8798, 0x4F6878], seed: 0.5) }),
    ("Horizons/meadow.jpg", { horizon($0, sky: [0xFDF6D8, 0xC8E6C9, 0x7FB7A4], sun: 0xFFF8E1, hills: [0x6FA77D, 0x4E8A62, 0x2F6B4A], seed: 0.1) }),
    ("Horizons/desert.jpg", { horizon($0, sky: [0xFCE8C8, 0xF2B880, 0xD9825B], sun: 0xFFFDF5, hills: [0xC96F4A, 0xA2533A, 0x7A3B2B], seed: 0.85) }),
    ("Horizons/night.jpg", { horizon($0, sky: [0x3B4A7A, 0x1E2547, 0x0C1024], sun: 0xE8ECFF, hills: [0x26305A, 0x1A2142, 0x0E132B], seed: 0.35) }),
    ("Studies/aurora.jpg", { aura($0, base: 0x0B1F2A, glows: [0x2EC4B6, 0x7B5CFF, 0x00A6FB], seed: 0.1) }),
    ("Studies/peach.jpg", { aura($0, base: 0xFFE5D9, glows: [0xFFB4A2, 0xE5989B, 0xFFCDB2], seed: 0.4) }),
    ("Studies/lagoon.jpg", { aura($0, base: 0x022C43, glows: [0x00B4D8, 0x48CAE4, 0x90E0EF], seed: 0.7) }),
    ("Studies/ember.jpg", { aura($0, base: 0x1A0A0A, glows: [0xFF5F1F, 0xFFB627, 0xC81D25], seed: 0.25) }),
    ("Studies/orbit.jpg", { orbit($0, base: [0x16213E, 0x533483], ring: 0xF2E9E4, seed: 0.3) }),
    ("Studies/halo.jpg", { orbit($0, base: [0xF4F1DE, 0xE07A5F], ring: 0x3D405B, seed: 0.7) }),
]

for (name, draw) in images {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.current = nil
    let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])!
    try! data.write(to: library.appendingPathComponent(name))
}
