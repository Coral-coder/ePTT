import CoreImage.CIFilterBuiltins
import SwiftUI

/// A scannable QR code drawn as liquid: modules are droplets that melt into their neighbours,
/// the finder patterns are soft glowing rings, and the whole thing breathes. The module layout is
/// a normal QR code (error correction M), so any QR reader still decodes it.
struct LiquidCode: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let matrix = QRMatrix.make(text)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                guard let matrix else { return }
                draw(matrix, in: &context, size: size, time: t)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Pairing code")
    }

    private func draw(_ m: QRMatrix, in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let quiet = 2.0
        let cell = min(size.width, size.height) / (Double(m.size) + quiet * 2)
        let origin = CGPoint(x: (size.width - cell * (Double(m.size) + quiet * 2)) / 2 + cell * quiet,
                             y: (size.height - cell * (Double(m.size) + quiet * 2)) / 2 + cell * quiet)
        let ink = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color(hex: 0x012A44), Color(hex: 0x05507A), Color(hex: 0x012A44)]),
            startPoint: origin, endPoint: CGPoint(x: origin.x + cell * Double(m.size), y: origin.y + cell * Double(m.size)))
        let center = Double(m.size) / 2

        func point(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: origin.x + (Double(x) + 0.5) * cell, y: origin.y + (Double(y) + 0.5) * cell)
        }

        var body = Path()
        for y in 0..<m.size {
            for x in 0..<m.size where m[x, y] && !m.isFinder(x, y) {
                // A ripple travelling out from the centre; droplets never shrink below 84 % of a
                // module, which keeps the code readable.
                let distance = hypot(Double(x) - center, Double(y) - center)
                let breath = 0.9 + 0.05 * sin(time * 3 - distance * 0.45)
                let r = cell * breath / 2
                let c = point(x, y)
                body.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                // Necks to the right and below melt neighbouring droplets together.
                let neck = cell * 0.64
                if x + 1 < m.size, m[x + 1, y], !m.isFinder(x + 1, y) {
                    body.addRect(CGRect(x: c.x, y: c.y - neck / 2, width: cell, height: neck))
                }
                if y + 1 < m.size, m[x, y + 1], !m.isFinder(x, y + 1) {
                    body.addRect(CGRect(x: c.x - neck / 2, y: c.y, width: neck, height: cell))
                }
            }
        }
        context.fill(body, with: ink)

        // Finder patterns: a rounded ring with a glowing core, same 1:1:3:1:1 proportions.
        for (fx, fy) in [(0, 0), (m.size - 7, 0), (0, m.size - 7)] {
            let tl = CGPoint(x: origin.x + Double(fx) * cell, y: origin.y + Double(fy) * cell)
            let outer = CGRect(x: tl.x, y: tl.y, width: cell * 7, height: cell * 7)
            var ring = Path(roundedRect: outer, cornerRadius: cell * 2.4, style: .continuous)
            ring.addPath(Path(roundedRect: outer.insetBy(dx: cell, dy: cell), cornerRadius: cell * 1.5, style: .continuous))
            context.fill(ring, with: ink, style: FillStyle(eoFill: true))
            let core = Path(roundedRect: outer.insetBy(dx: cell * 2, dy: cell * 2), cornerRadius: cell * 1.3, style: .continuous)
            var glow = context
            glow.addFilter(.shadow(color: NX.cyan.opacity(0.9), radius: cell * 0.9))
            glow.fill(core, with: ink)
        }
    }
}

/// The module grid of a QR code, read from Core Image's generator.
struct QRMatrix {
    let size: Int
    private let bits: [Bool]

    subscript(x: Int, y: Int) -> Bool { bits[y * size + x] }

    func isFinder(_ x: Int, _ y: Int) -> Bool {
        (x < 7 && y < 7) || (x >= size - 7 && y < 7) || (x < 7 && y >= size - 7)
    }

    private static let cache = NSCache<NSString, Box>()
    private final class Box { let matrix: QRMatrix; init(_ m: QRMatrix) { matrix = m } }

    static func make(_ text: String) -> QRMatrix? {
        if let hit = cache.object(forKey: text as NSString) { return hit.matrix }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Core Image draws one pixel per module plus a quiet zone; crop to the dark modules.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where pixels[y * width + x] < 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        let size = maxX - minX + 1
        guard size > 20, maxY - minY + 1 == size else { return nil }
        var bits = [Bool](repeating: false, count: size * size)
        for y in 0..<size { for x in 0..<size {
            bits[y * size + x] = pixels[(minY + y) * width + (minX + x)] < 128
        } }
        let matrix = QRMatrix(size: size, bits: bits)
        cache.setObject(Box(matrix), forKey: text as NSString)
        return matrix
    }
}
