// LZO1X codec for the Phomemo D450 (TSPL BITMAP mode 4).
//
// compress() is a port of the C# compressor from the Windows service. It emits
// only literal runs and M3 matches, and always opens a stream of 4 or more
// bytes with at least 4 literals (Labelife's decoder crashes on a shorter
// opening run).
//
// decompress() is a full LZO1X decoder (M1 to M4), so it also reads streams
// produced by other LZO1X compressors such as miniLZO.

public enum LzoError: Error, Equatable {
    case inputOverrun        // stream ended before the end marker
    case lookbehindOverrun   // match points before the start of the output
    case outputOverrun       // output would exceed maxOutput
    case trailingBytes       // bytes left after the end marker
}

public enum Lzo {
    /// Largest match distance the compressor uses (M3 reaches 16384).
    static let maxDistance = 16384

    public static func compress(_ src: [UInt8]) -> [UInt8] {
        let n = src.count
        var out = [UInt8]()
        out.reserveCapacity(n / 4 + 16)
        var table = [Int32](repeating: -1, count: 1 << 13)
        var i = 0
        var litStart = 0
        var lastMatch = -1   // index in `out` of the last match's distance low byte

        while i + 4 <= n {
            let v = UInt32(src[i]) | UInt32(src[i + 1]) << 8
                | UInt32(src[i + 2]) << 16 | UInt32(src[i + 3]) << 24
            // Unsigned 32-bit multiply with wraparound, top 13 bits.
            let h = Int((v &* 2_654_435_761) >> 19)
            let c = Int(table[h])
            table[h] = Int32(i)
            let hit = i >= 4 && c >= 0 && i - c <= maxDistance
                && src[c] == src[i] && src[c + 1] == src[i + 1]
                && src[c + 2] == src[i + 2] && src[c + 3] == src[i + 3]
            if !hit { i += 1; continue }

            var len = 4
            while i + len < n && src[c + len] == src[i + len] { len += 1 }
            literals(&out, src, litStart, i - litStart, &lastMatch)

            // M3 match: 001LLLLL [extension bytes] then a 16-bit distance.
            var t = len - 2
            if t <= 31 {
                out.append(UInt8(32 | t))
            } else {
                out.append(32)
                t -= 31
                while t > 255 { out.append(0); t -= 255 }
                out.append(UInt8(t))
            }
            // Low 2 bits of the distance word = count of literals that follow.
            let d = (i - c - 1) << 2
            lastMatch = out.count
            out.append(UInt8(d & 0xFF))
            out.append(UInt8(d >> 8))
            i += len
            litStart = i
        }
        literals(&out, src, litStart, n - litStart, &lastMatch)
        out.append(0x11); out.append(0); out.append(0)   // end-of-stream marker
        return out
    }

    private static func literals(_ out: inout [UInt8], _ src: [UInt8], _ start: Int,
                                 _ count: Int, _ lastMatch: inout Int) {
        if count == 0 { return }
        if count <= 3 {
            if lastMatch >= 0 {
                out[lastMatch] |= UInt8(count)        // ride on the previous match
            } else if out.isEmpty {
                out.append(UInt8(17 + count))         // only for inputs under 4 bytes
            } else {
                // Unreachable: a short run always follows a match or opens the stream.
                preconditionFailure("LZO encoder state error")
            }
        } else if count <= 18 {
            out.append(UInt8(count - 3))
        } else {
            out.append(0)
            var t = count - 18
            while t > 255 { out.append(0); t -= 255 }
            out.append(UInt8(t))
        }
        out.append(contentsOf: src[start ..< start + count])
        lastMatch = -1
    }

    private enum State { case top, afterLiteralRun, match, matchDone, matchNext }

    /// Decodes one LZO1X stream. Throws on malformed input; never reads or
    /// writes out of bounds.
    public static func decompress(_ src: [UInt8], maxOutput: Int = 1 << 26) throws -> [UInt8] {
        let n = src.count
        var out = [UInt8]()
        var ip = 0
        var t = 0

        func next() throws -> Int {
            guard ip < n else { throw LzoError.inputOverrun }
            defer { ip += 1 }
            return Int(src[ip])
        }
        func next16() throws -> Int {
            let lo = try next()
            let hi = try next()
            return lo | hi << 8
        }
        // Length extension: each zero byte adds 255, the first non-zero byte ends it.
        func extended(_ base: Int) throws -> Int {
            var v = 0
            while true {
                let b = try next()
                if b != 0 { return v + base + b }
                v += 255
                if v > maxOutput { throw LzoError.outputOverrun }
            }
        }
        func copyLiterals(_ count: Int) throws {
            guard ip + count <= n else { throw LzoError.inputOverrun }
            guard out.count + count <= maxOutput else { throw LzoError.outputOverrun }
            out.append(contentsOf: src[ip ..< ip + count])
            ip += count
        }
        func copyMatch(_ dist: Int, _ len: Int) throws {
            guard dist >= 1 && dist <= out.count else { throw LzoError.lookbehindOverrun }
            guard out.count + len <= maxOutput else { throw LzoError.outputOverrun }
            var from = out.count - dist
            for _ in 0 ..< len {       // byte by byte: source and target may overlap
                out.append(out[from])
                from += 1
            }
        }

        var state = State.top
        if n > 0 && src[0] > 17 {
            ip = 1
            t = Int(src[0]) - 17
            if t < 4 {
                state = .matchNext
            } else {
                try copyLiterals(t)
                state = .afterLiteralRun
            }
        }

        decode: while true {
            switch state {
            case .top:
                t = try next()
                if t >= 16 { state = .match; continue }
                if t == 0 { t = try extended(15) }
                try copyLiterals(t + 3)
                state = .afterLiteralRun

            case .afterLiteralRun:
                t = try next()
                if t >= 16 { state = .match; continue }
                // M1 after a literal run: 3 bytes, distance 2049 to 3072.
                let dist = try 1 + 0x0800 + (t >> 2) + (next() << 2)
                try copyMatch(dist, 3)
                state = .matchDone

            case .match:
                if t >= 64 {            // M2: 3 to 8 bytes, distance up to 2048
                    let dist = try 1 + ((t >> 2) & 7) + (next() << 3)
                    try copyMatch(dist, (t >> 5) + 1)
                } else if t >= 32 {     // M3: distance up to 16384
                    t &= 31
                    if t == 0 { t = try extended(31) }
                    let dist = try 1 + (next16() >> 2)
                    try copyMatch(dist, t + 2)
                } else if t >= 16 {     // M4: distance 16385 to 49151, or end marker
                    var dist = (t & 8) << 11
                    t &= 7
                    if t == 0 { t = try extended(7) }
                    dist += try next16() >> 2
                    if dist == 0 { break decode }
                    try copyMatch(dist + 0x4000, t + 2)
                } else {                // M1 after a match: 2 bytes, distance up to 1024
                    let dist = try 1 + (t >> 2) + (next() << 2)
                    try copyMatch(dist, 2)
                }
                state = .matchDone

            case .matchDone:
                // Low 2 bits of the byte two back = literals that follow the match.
                t = Int(src[ip - 2]) & 3
                state = t == 0 ? .top : .matchNext

            case .matchNext:
                try copyLiterals(t)
                t = try next()
                state = .match
            }
        }
        guard ip == n else { throw LzoError.trailingBytes }
        return out
    }
}
