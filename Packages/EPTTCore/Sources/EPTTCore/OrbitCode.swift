import Foundation

/// The Orbit code: NXTPTT's own circular optical code for face-to-face pairing (PROTOCOL.md §12).
/// Everything here is custom: layout, error correction (`ReedSolomon`), and the reader.
///
/// Layout, in code units (the data rings end at radius 1), dark marks on a white disc:
/// - bullseye: dark disc to 0.18, light ring to 0.24, dark ring to 0.30. Across any diameter it
///   reads dark:light:dark:light:dark ≈ 1:1:6:1:1, which is how the reader finds it, and its
///   outline (an ellipse in the camera image) gives the tilt;
/// - light gap to 0.36, then 8 rings 0.075 thick. Ring 0 is a fixed 33-cell sync pattern (which
///   way round, and whether mirrored); rings 1–7 (406 cells) carry 50 bytes: 32 data bytes plus
///   18 Reed–Solomon bytes (corrects any 9), XORed with a fixed mask;
/// - light gap to 1.01, a solid dark ring to 1.06 and 24 dashes to 1.12 at known angles. The
///   dashes give 24 reference points for a full perspective (homography) fit; margin to 1.20.
///
/// The 32 data bytes: [kind:1 index:3 total:3 0:1] [session] [28 payload] [CRC-16].
public enum OrbitCode {
    public static let disc = 0.18, whiteRing = 0.24, blackRing = 0.30, quiet = 0.36
    public static let ringThickness = 0.075, rings = 8
    public static let frameIn = 1.01, frameOut = 1.06, dashOut = 1.12, dashes = 24, margin = 1.20
    public static let ringCells: [Int] = (0..<8).map { k in
        Int((2 * Double.pi * (0.36 + 0.075 * (Double(k) + 0.5)) / 0.075).rounded())
    }
    static let sync: [Bool] = "011010110011101010001011000101001".map { $0 == "1" }
    static let codewordBytes = 50, parityBytes = 18, dataBytes = 32
    public static let payloadBytes = 28

    static func ringMid(_ k: Int) -> Double { quiet + ringThickness * (Double(k) + 0.5) }

    static let mask: [UInt8] = {
        var state: UInt16 = 0xACE1
        return (0..<50).map { _ in
            var byte: UInt8 = 0
            for _ in 0..<8 {
                let lsb = state & 1
                state >>= 1
                if lsb != 0 { state ^= 0xB400 }
                byte = byte << 1 | UInt8(lsb)
            }
            return byte
        }
    }()

    static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// One code's content.
    public struct Frame: Equatable {
        public var kind: UInt8        // 0 or 1
        public var index: Int         // 0…7
        public var total: Int         // 1…7
        public var session: UInt8
        public var payload: [UInt8]   // 28 bytes

        public init(kind: UInt8, index: Int, total: Int, session: UInt8, payload: [UInt8]) {
            self.kind = kind
            self.index = index
            self.total = total
            self.session = session
            self.payload = Array((payload + [UInt8](repeating: 0, count: OrbitCode.payloadBytes)).prefix(OrbitCode.payloadBytes))
        }

        var bytes: [UInt8] {
            let head: UInt8 = kind << 7 | UInt8(index) << 4 | UInt8(total) << 1
            var b: [UInt8] = [head, session] + payload
            let crc = OrbitCode.crc16(b[...])
            b += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
            return b
        }

        init?(bytes b: [UInt8]) {
            guard b.count == OrbitCode.dataBytes,
                  OrbitCode.crc16(b[0..<30]) == UInt16(b[30]) << 8 | UInt16(b[31]) else { return nil }
            kind = b[0] >> 7
            index = Int(b[0] >> 4 & 7)
            total = Int(b[0] >> 1 & 7)
            session = b[1]
            payload = Array(b[2..<30])
            guard total > 0, index < total else { return nil }
        }
    }

    /// The cells to draw, ring by ring (ring 0 is the sync pattern): true = dark.
    public static func cells(for frame: Frame) -> [[Bool]] {
        let codeword = ReedSolomon.encode(frame.bytes, nsym: parityBytes)
        let masked = zip(codeword, mask).map { $0 ^ $1 }
        var bits = masked.flatMap { (byte: UInt8) -> [Bool] in (0..<8).map { (i: Int) -> Bool in byte >> (7 - i) & 1 == 1 } }
        let dataCells = ringCells.dropFirst().reduce(0, +)
        bits += [Bool](repeating: false, count: dataCells - bits.count)
        var out: [[Bool]] = [sync]
        var i = 0
        for k in 1..<rings {
            out.append(Array(bits[i..<(i + ringCells[k])]))
            i += ringCells[k]
        }
        return out
    }

    /// Whether the code is dark at (x, y) in code units (y up; data rings end at radius 1).
    /// Outside the white margin (radius 1.20) it is dark: codes sit on a black screen.
    public static func isDark(x: Double, y: Double, cells: [[Bool]]) -> Bool {
        let r = (x * x + y * y).squareRoot()
        if r >= margin { return true }
        if r < disc { return true }
        if r < whiteRing { return false }
        if r < blackRing { return true }
        if r < quiet { return false }
        if r < quiet + ringThickness * Double(rings) {
            let k = min(rings - 1, Int((r - quiet) / ringThickness)), n = ringCells[k]
            var a = atan2(y, x)
            if a < 0 { a += 2 * .pi }
            return cells[k][min(n - 1, Int(a / (2 * .pi) * Double(n)))]
        }
        if r < frameIn { return false }
        if r < frameOut { return true }
        if r < dashOut {
            var degrees = atan2(y, x) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            return degrees.truncatingRemainder(dividingBy: 360 / Double(dashes)) < 180 / Double(dashes)
        }
        return false
    }

    /// The code as a `size × size` greyscale image (0 dark, 255 light), 2 × 2 supersampled.
    public static func render(_ frame: Frame, size: Int) -> [UInt8] {
        let cells = cells(for: frame)
        let scale = 2 * margin / Double(size)
        var out = [UInt8](repeating: 0, count: size * size)
        for py in 0..<size {
            for px in 0..<size {
                var light = 0
                for s in 0..<4 {
                    let x = (Double(px) + 0.25 + 0.5 * Double(s & 1)) * scale - margin
                    let y = margin - (Double(py) + 0.25 + 0.5 * Double(s >> 1)) * scale
                    if !isDark(x: x, y: y, cells: cells) { light += 1 }
                }
                out[py * size + px] = UInt8(light * 255 / 4)
            }
        }
        return out
    }

    // MARK: - Reading

    /// Finds and decodes an Orbit code in a greyscale image (any rotation, mirrored or not,
    /// tilted, blurred). `luma` is row-major, `width × height`, 0 dark … 255 light.
    public static func read(luma: [UInt8], width: Int, height: Int) -> Frame? {
        var reader = Reader(luma: luma, width: width, height: height)
        return reader.read()
    }

    struct Ellipse { var x: Double; var y: Double; var m: [[Double]] }   // m · unit circle + (x, y)

    struct Reader {
        let L: [UInt8], W: Int, H: Int
        var dark: [Bool] = []

        init(luma: [UInt8], width: Int, height: Int) {
            L = luma; W = width; H = height
        }

        mutating func read() -> Frame? {
            guard L.count >= W * H, W > 32, H > 32 else { return nil }
            binarize()
            // Bullseye candidates: rows every 2 px, confirmed down the column.
            var candidates: [(x: Double, y: Double, core: Double)] = []
            var row = [Bool](repeating: false, count: W), column = [Bool](repeating: false, count: H)
            for y in stride(from: 0, to: H, by: 2) {
                for x in 0..<W { row[x] = dark[y * W + x] }
                for (cx, c) in Self.finder(row) {
                    let x = Int(cx)
                    for yy in 0..<H { column[yy] = dark[yy * W + x] }
                    for (cy, c2) in Self.finder(column) where abs(cy - Double(y)) < c2 / 2 && c2 / c > 0.4 && c2 / c < 2.5 {
                        candidates.append((cx, cy, (c + c2) / 2))
                    }
                }
            }
            guard !candidates.isEmpty else { return nil }
            var clusters: [[(x: Double, y: Double, core: Double)]] = []
            for c in candidates {
                if let i = clusters.firstIndex(where: { hypot($0[0].x - c.x, $0[0].y - c.y) < c.core / 2 }) {
                    clusters[i].append(c)
                } else {
                    clusters.append([c])
                }
            }
            clusters.sort { $0.count > $1.count }
            for cluster in clusters.prefix(3) {
                let n = Double(cluster.count)
                let cx = cluster.reduce(0) { $0 + $1.x } / n, cy = cluster.reduce(0) { $0 + $1.y } / n
                let core = cluster.reduce(0) { $0 + $1.core } / n
                if let frame = decode(at: cx, cy, core: core) { return frame }
            }
            return nil
        }

        /// Adaptive threshold: darker than 92 % of the local mean.
        mutating func binarize() {
            var integral = [Int](repeating: 0, count: (W + 1) * (H + 1))
            for y in 0..<H {
                var sum = 0
                for x in 0..<W {
                    sum += Int(L[y * W + x])
                    integral[(y + 1) * (W + 1) + x + 1] = integral[y * (W + 1) + x + 1] + sum
                }
            }
            let win = max(8, W / 10)
            dark = [Bool](repeating: false, count: W * H)
            for y in 0..<H {
                let y0 = max(0, y - win), y1 = min(H, y + win + 1)
                for x in 0..<W {
                    let x0 = max(0, x - win), x1 = min(W, x + win + 1)
                    let total = integral[y1 * (W + 1) + x1] - integral[y0 * (W + 1) + x1]
                        - integral[y1 * (W + 1) + x0] + integral[y0 * (W + 1) + x0]
                    let mean = Double(total) / Double((x1 - x0) * (y1 - y0))
                    dark[y * W + x] = Double(L[y * W + x]) < mean * 0.92
                }
            }
        }

        /// Centres (and core lengths) of dark:light:dark:light:dark ≈ 1:1:6:1:1 along a line.
        static func finder(_ line: [Bool]) -> [(Double, Double)] {
            var runs: [(dark: Bool, start: Int, length: Int)] = []
            var start = 0
            for i in 1...line.count where i == line.count || line[i] != line[i - 1] {
                runs.append((line[start], start, i - start))
                start = i
            }
            var found: [(Double, Double)] = []
            guard runs.count >= 5 else { return found }
            for i in 0..<(runs.count - 4) where runs[i].dark {
                let c = Double(runs[i + 2].length)
                guard c >= 6 else { continue }
                let unit = c / 6
                let sides = [runs[i].length, runs[i + 1].length, runs[i + 3].length, runs[i + 4].length].map(Double.init)
                if sides.allSatisfy({ $0 >= 0.35 * unit && $0 <= 2.3 * unit }) {
                    found.append((Double(runs[i + 2].start) + c / 2, c))
                }
            }
            return found
        }

        func bilinear(_ x: Double, _ y: Double) -> Double? {
            guard x >= 0, y >= 0, x < Double(W - 1), y < Double(H - 1) else { return nil }
            let x0 = Int(x), y0 = Int(y), fx = x - Double(x0), fy = y - Double(y0)
            let a = Double(L[y0 * W + x0]), b = Double(L[y0 * W + x0 + 1])
            let c = Double(L[(y0 + 1) * W + x0]), d = Double(L[(y0 + 1) * W + x0 + 1])
            return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy
        }

        func decode(at cx: Double, _ cy: Double, core: Double) -> Frame? {
            // Outer edge of the bullseye's dark ring along 96 rays.
            var points: [(Double, Double)] = []
            for k in 0..<96 {
                let a = 2 * Double.pi * Double(k) / 96, ca = cos(a), sa = sin(a)
                var state = 0, r = 0.0
                while r < core * 3 {
                    let x = Int(cx + ca * r), y = Int(cy + sa * r)
                    guard x >= 0, y >= 0, x < W, y < H else { break }
                    let d = dark[y * W + x]
                    if state == 0 && !d { state = 1 }
                    else if state == 1 && d { state = 2 }
                    else if state == 2 && !d { points.append((cx + ca * r, cy + sa * r)); break }
                    r += 0.5
                }
            }
            guard points.count >= 24, let inner = OrbitCode.fitEllipse(points, cx, cy) else { return nil }
            return decode(inner: inner)
        }

        func decode(inner: Ellipse) -> Frame? {
            let toImage = OrbitCode.affine(inner, radius: OrbitCode.blackRing)
            func lum(_ r: Double, _ theta: Double) -> Double? {
                let p = toImage(r * cos(theta), r * sin(theta)); return bilinear(p.0, p.1)
            }
            var darks: [Double] = [], lights: [Double] = []
            for i in 0..<24 {
                let t = 2 * Double.pi * Double(i) / 24
                for r in [0.08, 0.27] { guard let v = lum(r, t) else { return nil }; darks.append(v) }
                for r in [0.21, 0.33] { guard let v = lum(r, t) else { return nil }; lights.append(v) }
            }
            darks.sort(); lights.sort()
            let black = darks[darks.count / 2], white = lights[lights.count / 2]
            guard white - black >= 15 else { return nil }
            let threshold = (black + white) / 2, half = (white - black) / 2

            // The solid outer ring's inner edge along each ray: the outermost short dark band that
            // has a light gap before it and a light margin after it.
            var outerPoints: [(Double, Double)] = []
            for k in 0..<96 {
                let theta = 2 * Double.pi * Double(k) / 96
                var runs: [(dark: Bool, a: Double, b: Double)] = []
                var r = 0.80, current: Bool?, start = 0.80
                while r < 1.45 {
                    guard let v = lum(r, theta) else { break }
                    let d = v < threshold
                    if d != current {
                        if let current { runs.append((current, start, r)) }
                        current = d; start = r
                    }
                    r += 0.006
                }
                if let current { runs.append((current, start, r)) }
                var best: Double?
                for i in runs.indices where i > 0 && i + 1 < runs.count {
                    let run = runs[i], next = runs[i + 1], previous = runs[i - 1]
                    guard run.dark, (0.03...0.16).contains(run.b - run.a),
                          !next.dark, (0.04...0.3).contains(next.b - next.a),
                          !previous.dark, previous.b - previous.a >= 0.03 else { continue }
                    best = run.a
                }
                if let best { outerPoints.append(toImage(best * cos(theta), best * sin(theta))) }
            }
            let outer = outerPoints.count >= 24 ? OrbitCode.fitEllipse(outerPoints, inner.x, inner.y) : nil

            func soft(_ v: Double?) -> Double { v.map { max(-1, min(1, (threshold - $0) / half)) } ?? 0 }

            // Sync ring: which way round, and mirrored or not.
            let n0 = OrbitCode.ringCells[0], steps = n0 * 8
            let fine = (0..<steps).map { soft(lum(OrbitCode.ringMid(0), 2 * Double.pi * Double($0) / Double(steps))) }
            var best = (score: -Double.infinity, mirror: 1, shift: 0)
            for mirror in [1, -1] {
                for t in 0..<steps {
                    var score = 0.0
                    for j in 0..<n0 {
                        let index = ((t + mirror * (j * 8 + 4)) % steps + steps) % steps
                        score += (OrbitCode.sync[j] ? 1 : -1) * fine[index]
                    }
                    if score > best.score { best = (score, mirror, t) }
                }
            }
            guard best.score >= 0.45 * Double(n0) else { return nil }
            let phi = 2 * Double.pi * Double(best.shift) / Double(steps), m = Double(best.mirror)

            // Perspective from the dashes, when we can find them.
            let h = outer.flatMap { dashHomography(outer: $0, toImage: toImage, phi: phi, mirror: m, threshold: threshold) }
            func cell(_ r: Double, _ alpha: Double) -> Double {
                if let h {
                    let p = OrbitCode.apply(h, r * cos(alpha), r * sin(alpha))
                    return soft(bilinear(p.0, p.1))
                }
                return soft(lum(r, phi + m * alpha))
            }
            var bits: [Bool] = []
            for k in 1..<OrbitCode.rings {
                let n = OrbitCode.ringCells[k]
                for j in 0..<n { bits.append(cell(OrbitCode.ringMid(k), 2 * Double.pi * (Double(j) + 0.5) / Double(n)) > 0) }
            }
            let codeword: [UInt8] = (0..<OrbitCode.codewordBytes).map { i in
                var byte: UInt8 = 0
                for b in 0..<8 where bits[i * 8 + b] { byte |= 0x80 >> UInt8(b) }
                return byte ^ OrbitCode.mask[i]
            }
            guard let data = ReedSolomon.decode(codeword, nsym: OrbitCode.parityBytes) else { return nil }
            return Frame(bytes: data)
        }

        /// Dash centres (known code angles) ↔ where they are in the image, then a least-squares
        /// homography from code coordinates to image coordinates.
        func dashHomography(outer: Ellipse, toImage: (Double, Double) -> (Double, Double),
                            phi: Double, mirror m: Double, threshold: Double) -> [Double]? {
            let scale = (OrbitCode.frameOut + OrbitCode.dashOut) / 2 / OrbitCode.frameIn
            let steps = 720
            var path: [(x: Double, y: Double, dark: Bool)] = []
            for i in 0..<steps {
                let psi = 2 * Double.pi * Double(i) / Double(steps)
                let qx = cos(psi) * scale, qy = -sin(psi) * scale
                let x = outer.x + outer.m[0][0] * qx + outer.m[0][1] * qy
                let y = outer.y + outer.m[1][0] * qx + outer.m[1][1] * qy
                path.append((x, y, bilinear(x, y).map { $0 < threshold } ?? false))
            }
            guard let start = path.firstIndex(where: { !$0.dark }) else { return nil }
            var centres: [(Double, Double)] = []
            var current: [(x: Double, y: Double, dark: Bool)] = []
            for k in 0...steps {
                let p = path[(start + k) % steps]
                if p.dark && k < steps { current.append(p) }
                else if !current.isEmpty {
                    if (4...45).contains(current.count) {   // longer: the path is riding the solid ring
                        centres.append((current.reduce(0) { $0 + $1.x } / Double(current.count),
                                        current.reduce(0) { $0 + $1.y } / Double(current.count)))
                    }
                    current = []
                }
            }
            guard centres.count >= 8 else { return nil }
            let step = 2 * Double.pi / Double(OrbitCode.dashes), rr = (OrbitCode.frameOut + OrbitCode.dashOut) / 2
            let s0 = toImage(rr, 0), s1 = toImage(rr * cos(step), rr * sin(step))
            let spacing = hypot(s1.0 - s0.0, s1.1 - s0.1)
            var pairs: [((Double, Double), (Double, Double))] = []
            var used = Set<Int>()
            for k in 0..<OrbitCode.dashes {
                let a = step * Double(k) + step / 4
                let p = toImage(rr * cos(phi + m * a), rr * sin(phi + m * a))
                guard let bestIndex = centres.indices.min(by: {
                    hypot(centres[$0].0 - p.0, centres[$0].1 - p.1) < hypot(centres[$1].0 - p.0, centres[$1].1 - p.1)
                }) else { continue }
                let c = centres[bestIndex]
                if hypot(c.0 - p.0, c.1 - p.1) < spacing * 0.5, !used.contains(bestIndex) {
                    used.insert(bestIndex)
                    pairs.append(((rr * cos(a), rr * sin(a)), c))
                }
            }
            guard pairs.count >= 8, var h = OrbitCode.fitHomography(pairs) else { return nil }
            // Refine: walk the dash circle through the homography itself, where each dark stretch's
            // code angle says which dash it is, and refit. Corrects what the ellipses got wrong
            // under strong perspective.
            let n = 720
            for _ in 0..<2 {
                let samples: [(x: Double, y: Double, dark: Bool)] = (0..<n).map { i in
                    let angle = 2 * Double.pi * (Double(i) + 0.5) / Double(n)
                    let p = OrbitCode.apply(h, rr * cos(angle), rr * sin(angle))
                    return (p.0, p.1, bilinear(p.0, p.1).map { $0 < threshold } ?? false)
                }
                var refined: [((Double, Double), (Double, Double))] = []
                for k in 0..<OrbitCode.dashes {
                    // Dash k spans code angles step·k … step·k + step/2; look a little either side.
                    let lo = Int((step * Double(k) - step / 8) / (2 * Double.pi) * Double(n))
                    let hi = Int((step * Double(k) + step / 2 + step / 8) / (2 * Double.pi) * Double(n))
                    let dark = (lo..<hi).map { samples[($0 % n + n) % n] }.filter(\.dark)
                    guard dark.count >= 4 else { continue }
                    let a = step * Double(k) + step / 4
                    refined.append(((rr * cos(a), rr * sin(a)),
                                     (dark.reduce(0) { $0 + $1.x } / Double(dark.count), dark.reduce(0) { $0 + $1.y } / Double(dark.count))))
                }
                guard refined.count >= 8, let better = OrbitCode.fitHomography(refined) else { break }
                h = better
            }
            return h
        }
    }

    /// Least-squares homography (h33 = 1) from code points to image points, with the image
    /// points normalised for conditioning.
    static func fitHomography(_ pairs: [((Double, Double), (Double, Double))]) -> [Double]? {
        let n = Double(pairs.count)
        let mx = pairs.reduce(0) { $0 + $1.1.0 } / n, my = pairs.reduce(0) { $0 + $1.1.1 } / n
        let sc = pairs.reduce(0) { $0 + hypot($1.1.0 - mx, $1.1.1 - my) } / n
        guard sc > 0 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8), b = [Double](repeating: 0, count: 8)
        for ((X, Y), (px, py)) in pairs {
            let x = (px - mx) / sc, y = (py - my) / sc
            let rows: [([Double], Double)] = [([X, Y, 1, 0, 0, 0, -x * X, -x * Y], x), ([0, 0, 0, X, Y, 1, -y * X, -y * Y], y)]
            for (row, rhs) in rows {
                for i in 0..<8 {
                    b[i] += row[i] * rhs
                    for j in 0..<8 { a[i][j] += row[i] * row[j] }
                }
            }
        }
        guard let h = solve(a, b) else { return nil }
        return [h[0] * sc + h[6] * mx, h[1] * sc + h[7] * mx, h[2] * sc + mx,
                h[3] * sc + h[6] * my, h[4] * sc + h[7] * my, h[5] * sc + my, h[6], h[7]]
    }

    static func apply(_ h: [Double], _ x: Double, _ y: Double) -> (Double, Double) {
        let w = h[6] * x + h[7] * y + 1
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// Code coordinates (y up) → image, for an ellipse that is the image of the circle `radius`.
    static func affine(_ e: Ellipse, radius: Double) -> (Double, Double) -> (Double, Double) {
        { px, py in
            let qx = px / radius, qy = -py / radius
            return (e.x + e.m[0][0] * qx + e.m[0][1] * qy, e.y + e.m[1][0] * qx + e.m[1][1] * qy)
        }
    }

    /// An ellipse through points, refitted up to twice without the points far off it (a ray that
    /// caught the wrong edge).
    static func fitEllipse(_ points: [(Double, Double)], _ cx: Double, _ cy: Double) -> Ellipse? {
        var points = points
        guard var ellipse = fitEllipseOnce(points, cx, cy) else { return nil }
        for _ in 0..<2 {
            let residuals = points.map { residual(ellipse, $0) }
            let median = residuals.sorted()[residuals.count / 2]
            let keep = zip(points, residuals).filter { $0.1 <= max(1.5, 3 * median) }.map(\.0)
            guard keep.count < points.count, keep.count >= max(12, points.count / 2),
                  let refit = fitEllipseOnce(keep, cx, cy) else { break }
            points = keep
            ellipse = refit
        }
        return ellipse
    }

    /// Roughly how far a point is from the ellipse, in pixels, along its radius.
    static func residual(_ e: Ellipse, _ p: (Double, Double)) -> Double {
        let det = e.m[0][0] * e.m[1][1] - e.m[0][1] * e.m[1][0]
        let dx = p.0 - e.x, dy = p.1 - e.y
        let qx = (e.m[1][1] * dx - e.m[0][1] * dy) / det, qy = (-e.m[1][0] * dx + e.m[0][0] * dy) / det
        let rq = hypot(qx, qy)
        return abs(rq - 1) * hypot(dx, dy) / max(rq, 1e-9)
    }

    /// Least-squares ellipse through points (conic a u² + b uv + c v² + d u + e v = 1 around
    /// (cx, cy)), returned as centre plus the symmetric matrix mapping the unit circle onto it.
    static func fitEllipseOnce(_ points: [(Double, Double)], _ cx: Double, _ cy: Double) -> Ellipse? {
        var a = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 5), b = [Double](repeating: 0, count: 5)
        for (x, y) in points {
            let u = x - cx, v = y - cy
            let row = [u * u, u * v, v * v, u, v]
            for i in 0..<5 {
                b[i] += row[i]
                for j in 0..<5 { a[i][j] += row[i] * row[j] }
            }
        }
        guard let s = solve(a, b) else { return nil }
        let (qa, qb, qc, qd, qe) = (s[0], s[1], s[2], s[3], s[4])
        let det = qa * qc - qb * qb / 4
        guard det > 0 else { return nil }
        let inv = [[qc / det, -qb / 2 / det], [-qb / 2 / det, qa / det]]
        let u0 = -0.5 * (inv[0][0] * qd + inv[0][1] * qe), v0 = -0.5 * (inv[1][0] * qd + inv[1][1] * qe)
        let k = 1 + (qa * u0 * u0 + qb * u0 * v0 + qc * v0 * v0)
        let q = [[inv[0][0] * k, inv[0][1] * k], [inv[1][0] * k, inv[1][1] * k]]
        let trace = q[0][0] + q[1][1], d = q[0][0] * q[1][1] - q[0][1] * q[0][1]
        let disc = sqrt(max(0, trace * trace / 4 - d))
        let l1 = trace / 2 + disc, l2 = trace / 2 - disc
        guard l2 > 0 else { return nil }
        var v1: (Double, Double) = abs(q[0][1]) > 1e-9 ? (l1 - q[1][1], q[0][1]) : (q[0][0] >= q[1][1] ? (1, 0) : (0, 1))
        let n1 = hypot(v1.0, v1.1)
        v1 = (v1.0 / n1, v1.1 / n1)
        let v2 = (-v1.1, v1.0)
        let s1 = sqrt(l1), s2 = sqrt(l2)
        let m = [[v1.0 * v1.0 * s1 + v2.0 * v2.0 * s2, v1.0 * v1.1 * s1 + v2.0 * v2.1 * s2],
                 [v1.1 * v1.0 * s1 + v2.1 * v2.0 * s2, v1.1 * v1.1 * s1 + v2.1 * v2.1 * s2]]
        return Ellipse(x: cx + u0, y: cy + v0, m: m)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = a.count
        var m = zip(a, b).map { $0 + [$1] }
        for i in 0..<n {
            guard let p = (i..<n).max(by: { abs(m[$0][i]) < abs(m[$1][i]) }), abs(m[p][i]) > 1e-12 else { return nil }
            m.swapAt(i, p)
            for k in 0..<n where k != i {
                let f = m[k][i] / m[i][i]
                guard f != 0 else { continue }
                for j in i...n { m[k][j] -= f * m[i][j] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}
