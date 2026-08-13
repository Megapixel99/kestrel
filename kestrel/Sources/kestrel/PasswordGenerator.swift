import Foundation
import Security

/// Password generator, matching the options Bitwarden's Generator pane exposes.
///
/// Uses SecRandomCopyBytes rather than Swift's default RNG: a password generator that
/// draws from a non-cryptographic source is a liability, not a convenience. Rejection
/// sampling avoids the modulo bias that `% count` would introduce.
enum PasswordGenerator {

    struct Options {
        var length = 20
        var upper = true
        var lower = true
        var digits = true
        var special = false
        var minDigits = 1
        var minSpecial = 0
        var avoidAmbiguous = false
    }

    static let ambiguous = Set("Il1O0o")

    static func generate(_ o: Options) -> String {
        var upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var lower = Array("abcdefghijklmnopqrstuvwxyz")
        var digits = Array("0123456789")
        let special = Array("!@#$%^&*")
        if o.avoidAmbiguous {
            upper.removeAll { ambiguous.contains($0) }
            lower.removeAll { ambiguous.contains($0) }
            digits.removeAll { ambiguous.contains($0) }
        }

        var pools: [[Character]] = []
        if o.upper { pools.append(upper) }
        if o.lower { pools.append(lower) }
        if o.digits { pools.append(digits) }
        if o.special { pools.append(special) }
        guard !pools.isEmpty else { return "" }

        var chars: [Character] = []
        // Satisfy the minimums first, then fill from the combined pool.
        if o.digits { for _ in 0..<min(o.minDigits, o.length) { chars.append(pick(digits)) } }
        if o.special { for _ in 0..<min(o.minSpecial, max(0, o.length - chars.count)) {
            chars.append(pick(special)) } }
        let all = pools.flatMap { $0 }
        while chars.count < o.length { chars.append(pick(all)) }
        chars = Array(chars.prefix(o.length))

        // Fisher-Yates with the same CSPRNG, so the minimums are not always at the front.
        for i in stride(from: chars.count - 1, to: 0, by: -1) {
            let j = Int(random(upperBound: UInt32(i + 1)))
            chars.swapAt(i, j)
        }
        return String(chars)
    }

    private static func pick(_ pool: [Character]) -> Character {
        pool[Int(random(upperBound: UInt32(pool.count)))]
    }

    /// Uniform in 0..<upperBound, rejecting values that would skew the distribution.
    private static func random(upperBound: UInt32) -> UInt32 {
        guard upperBound > 0 else { return 0 }
        let limit = UInt32.max - (UInt32.max % upperBound)
        while true {
            var r: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &r) {
                SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!)
            }
            guard status == errSecSuccess else { return UInt32.random(in: 0..<upperBound) }
            if r < limit { return r % upperBound }
        }
    }

    /// Rough strength estimate from the pool size and length, in bits of entropy.
    static func entropyBits(_ o: Options) -> Int {
        var pool = 0
        if o.upper { pool += o.avoidAmbiguous ? 24 : 26 }
        if o.lower { pool += o.avoidAmbiguous ? 24 : 26 }
        if o.digits { pool += o.avoidAmbiguous ? 8 : 10 }
        if o.special { pool += 8 }
        guard pool > 1 else { return 0 }
        return Int(Double(o.length) * log2(Double(pool)))
    }
}
