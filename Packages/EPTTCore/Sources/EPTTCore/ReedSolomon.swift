import Foundation

/// Reed–Solomon error correction over GF(256) (primitive polynomial 0x11D, generator α = 2,
/// first root α⁰). `nsym` parity bytes correct up to `nsym / 2` wrong bytes anywhere in the
/// codeword; beyond that, decoding fails rather than returning something wrong (as far as the
/// syndromes can tell).
public enum ReedSolomon {
    private static let tables: (exp: [UInt8], log: [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512), log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return tables.exp[tables.log[Int(a)] + tables.log[Int(b)]]
    }

    static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        return tables.exp[(tables.log[Int(a)] + 255 - tables.log[Int(b)]) % 255]
    }

    static func pow(_ exponent: Int) -> UInt8 { tables.exp[((exponent % 255) + 255) % 255] }

    /// Evaluates a polynomial given highest degree first.
    static func eval(_ p: [UInt8], _ x: UInt8) -> UInt8 {
        var y = p[0]
        for c in p.dropFirst() { y = mul(y, x) ^ c }
        return y
    }

    static func generator(_ nsym: Int) -> [UInt8] {
        var g: [UInt8] = [1]
        for i in 0..<nsym {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() {
                next[j] ^= c
                next[j + 1] ^= mul(c, pow(i))
            }
            g = next
        }
        return g
    }

    /// `message` followed by `nsym` parity bytes.
    public static func encode(_ message: [UInt8], nsym: Int) -> [UInt8] {
        let g = generator(nsym)
        var out = message + [UInt8](repeating: 0, count: nsym)
        for i in 0..<message.count {
            let c = out[i]
            guard c != 0 else { continue }
            for j in 1..<g.count { out[i + j] ^= mul(g[j], c) }
        }
        return message + out[message.count...]
    }

    /// The message, corrected, or nil if there are more errors than can be fixed.
    public static func decode(_ codeword: [UInt8], nsym: Int) -> [UInt8]? {
        var cw = codeword
        let n = cw.count
        let syndromes = (0..<nsym).map { eval(cw, pow($0)) }
        if syndromes.allSatisfy({ $0 == 0 }) { return Array(cw.prefix(n - nsym)) }

        // Berlekamp–Massey: the error locator Λ(x), lowest degree first.
        var locator: [UInt8] = [1], previous: [UInt8] = [1]
        var errors = 0, shift = 1
        var lastDiscrepancy: UInt8 = 1
        for i in 0..<nsym {
            var d = syndromes[i]
            if errors > 0 { for j in 1...errors where j < locator.count { d ^= mul(locator[j], syndromes[i - j]) } }
            if d == 0 { shift += 1; continue }
            let saved = locator
            let coef = div(d, lastDiscrepancy)
            if locator.count < previous.count + shift {
                locator += [UInt8](repeating: 0, count: previous.count + shift - locator.count)
            }
            for (j, b) in previous.enumerated() { locator[j + shift] ^= mul(coef, b) }
            if 2 * errors <= i {
                errors = i + 1 - errors
                previous = saved
                lastDiscrepancy = d
                shift = 1
            } else {
                shift += 1
            }
        }
        locator = Array(locator.prefix(errors + 1))
        guard errors * 2 <= nsym else { return nil }

        // Chien search: positions whose inverse locator value is a root.
        func evalLow(_ p: [UInt8], _ x: UInt8) -> UInt8 {
            var y: UInt8 = 0, power: UInt8 = 1
            for c in p { y ^= mul(c, power); power = mul(power, x) }
            return y
        }
        var positions: [Int] = []
        for i in 0..<n {
            let xInverse = pow(255 - (n - 1 - i))
            if evalLow(locator, xInverse) == 0 { positions.append(i) }
        }
        guard positions.count == errors else { return nil }

        // Forney: Ω(x) = S(x) Λ(x) mod x^nsym; magnitude = X · Ω(X⁻¹) / Λ'(X⁻¹).
        var omega = [UInt8](repeating: 0, count: nsym)
        for i in 0..<nsym {
            for j in 0...min(i, locator.count - 1) { omega[i] ^= mul(syndromes[i - j], locator[j]) }
        }
        for i in positions {
            let x = pow(n - 1 - i), xInverse = div(1, x)
            let numerator = evalLow(omega, xInverse)
            var denominator: UInt8 = 0
            var j = 1
            while j < locator.count {
                denominator ^= mul(locator[j], pow(tables.log[Int(xInverse)] * (j - 1)))
                j += 2
            }
            guard denominator != 0 else { return nil }
            cw[i] ^= mul(x, div(numerator, denominator))
        }
        guard (0..<nsym).allSatisfy({ eval(cw, pow($0)) == 0 }) else { return nil }
        return Array(cw.prefix(n - nsym))
    }
}
