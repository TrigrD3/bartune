import AppKit
import Foundation

struct ExtractedAlbumColors: Sendable {
    let accentR: Double
    let accentG: Double
    let accentB: Double
    let backdropR: Double
    let backdropG: Double
    let backdropB: Double

    var accentNSColor: NSColor {
        NSColor(srgbRed: accentR, green: accentG, blue: accentB, alpha: 1.0)
    }

    var backdropNSColor: NSColor {
        NSColor(srgbRed: backdropR, green: backdropG, blue: backdropB, alpha: 1.0)
    }
}

actor AlbumArtColorExtractor {
    private var cache = LRUMemoryCache<ExtractedAlbumColors>()

    func extractColors(from urlString: String?) async -> ExtractedAlbumColors? {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else {
            return nil
        }

        if let cached = cache[urlString] {
            return cached
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let colors = Self.analyzeImageData(data) else {
                return nil
            }
            cache[urlString] = colors
            return colors
        } catch {
            return nil
        }
    }

    private static func analyzeImageData(_ data: Data) -> ExtractedAlbumColors? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let size = 24
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var bestScore: Double = -1
        var bestR: Double = 0.4
        var bestG: Double = 0.7
        var bestB: Double = 1.0

        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        var count: Double = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            let a = Double(pixels[i + 3]) / 255.0
            guard a > 0.5 else { continue }

            sumR += r
            sumG += g
            sumB += b
            count += 1

            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let delta = maxC - minC
            let sat = maxC > 0 ? delta / maxC : 0
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b

            // Favor saturated, mid-to-bright colors that read well in the menu bar
            if lum > 0.12 && lum < 0.92 {
                let lumWeight = 1.0 - abs(lum - 0.55)
                let score = sat * 2.2 + lumWeight * 0.8
                if score > bestScore {
                    bestScore = score
                    bestR = r
                    bestG = g
                    bestB = b
                }
            }
        }

        guard count > 0 else { return nil }

        // Boost vibrant accent slightly so it pops nicely against dark/light menu bars
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var alpha: CGFloat = 0
        let rawAccent = NSColor(srgbRed: bestR, green: bestG, blue: bestB, alpha: 1.0)
        rawAccent.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)

        let tunedAccent = NSColor(
            hue: hue,
            saturation: min(1.0, max(sat, 0.55)),
            brightness: min(1.0, max(bri, 0.78)),
            alpha: 1.0
        ).usingColorSpace(.sRGB) ?? rawAccent

        // Deeper muted backdrop tint derived from average + vibrant hue
        let avgR = sumR / count
        let avgG = sumG / count
        let avgB = sumB / count
        let rawBack = NSColor(srgbRed: avgR * 0.5 + bestR * 0.5, green: avgG * 0.5 + bestG * 0.5, blue: avgB * 0.5 + bestB * 0.5, alpha: 1.0)
        var bHue: CGFloat = 0, bSat: CGFloat = 0, bBri: CGFloat = 0, bAlpha: CGFloat = 0
        rawBack.getHue(&bHue, saturation: &bSat, brightness: &bBri, alpha: &bAlpha)
        let tunedBack = NSColor(
            hue: bHue,
            saturation: min(0.65, max(bSat, 0.25)),
            brightness: min(0.32, max(bBri * 0.55, 0.14)),
            alpha: 1.0
        ).usingColorSpace(.sRGB) ?? rawBack

        return ExtractedAlbumColors(
            accentR: Double(tunedAccent.redComponent),
            accentG: Double(tunedAccent.greenComponent),
            accentB: Double(tunedAccent.blueComponent),
            backdropR: Double(tunedBack.redComponent),
            backdropG: Double(tunedBack.greenComponent),
            backdropB: Double(tunedBack.blueComponent)
        )
    }
}
