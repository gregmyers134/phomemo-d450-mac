// Offline self-test for the LZO codec and the TSPL job builder.
// Nothing here talks to the printer.
//
//   swift run -c release d450-selftest                 run every check
//   swift run -c release d450-selftest sample <dir>    write a test page and its job to <dir>
//   swift run -c release d450-selftest lzo-c <in> <out>   compress a file
//   swift run -c release d450-selftest lzo-d <in> <out>   decompress a file

import D450Core
import Foundation

var checks = 0
var failures = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL (line \(line)): \(what())")
    }
}

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func bytes(_ n: Int, alphabet: Int = 256) -> [UInt8] {
        (0 ..< n).map { _ in UInt8(below(alphabet)) }
    }
}

func roundTrip(_ src: [UInt8], _ name: String, line: Int = #line) {
    let packed = Lzo.compress(src)
    do {
        let back = try Lzo.decompress(packed)
        check(back == src, "\(name): round trip differs (\(src.count) bytes)", line: line)
    } catch {
        check(false, "\(name): decompress threw \(error)", line: line)
    }
    if src.count >= 4 {
        // Labelife's decoder needs an opening run of at least 4 literals:
        // first byte 0 (long run) or 1...15 (run of 4...18).
        check(packed[0] <= 15, "\(name): stream opens with a short literal run", line: line)
    }
    check(Array(packed.suffix(3)) == [0x11, 0, 0], "\(name): end marker missing", line: line)
}

/// A page with a border on its outermost dots, bars, fine lines and a checkerboard.
func testPage(width: Int, height: Int) -> MonoBitmap {
    var p = MonoBitmap(width: width, height: height)
    p.fill(x: 0, y: 0, width: width, height: 4)
    p.fill(x: 0, y: height - 4, width: width, height: 4)
    p.fill(x: 0, y: 0, width: 4, height: height)
    p.fill(x: width - 4, y: 0, width: 4, height: height)
    p.fill(x: 60, y: 60, width: width - 120, height: 80)            // solid bar
    for k in 0 ..< 40 { p.fill(x: 60 + k * 16, y: 180, width: 1 + k % 4, height: 120) }  // barcode-like
    for y in 340 ..< 500 { for x in 60 ..< 380 where (x / 8 + y / 8) % 2 == 0 { p.set(x, y) } }
    for y in 340 ..< 500 { for x in 420 ..< 740 where (x + y) % 2 == 0 { p.set(x, y) } }  // 1-dot checker
    for k in 0 ..< 20 { p.fill(x: 60, y: 540 + k * 10, width: width - 120, height: 1) }  // 1-dot lines
    for k in 0 ..< 400 { p.fill(x: 60 + k, y: 780 + k, width: 3, height: 3) }           // diagonal
    return p
}

func runTests() {
    var rng = SplitMix64(state: 450)

    // ---- LZO: fixed vectors worked out by hand from the format -------------
    check(Lzo.compress([]) == [0x11, 0, 0], "empty input")
    check(Lzo.compress([1, 2, 3]) == [20, 1, 2, 3, 0x11, 0, 0], "3-byte input")
    check(Lzo.compress([UInt8](repeating: 97, count: 8)) == [1, 97, 97, 97, 97, 34, 0, 0, 0x11, 0, 0],
          "8 equal bytes: 4 literals then an M3 match of 4 at distance 1")

    // ---- LZO: streams made by liblzo2 (lzo1x_1 and lzo1x_999) --------------
    // These use M1, M2 and M4 matches, which our compressor never emits.
    check(liblzoVectors.count == 8, "liblzo2 vectors present")
    for (i, v) in liblzoVectors.enumerated() {
        do {
            let got = try Lzo.decompress(v.packed)
            check(got == v.plain(), "liblzo2 vector \(i) (\(v.name)) decodes wrongly")
        } catch {
            check(false, "liblzo2 vector \(i) (\(v.name)) threw \(error)")
        }
    }

    // ---- LZO: round trips -------------------------------------------------
    for n in 0 ... 40 { roundTrip(rng.bytes(n), "random \(n)") }
    for n in 0 ... 40 { roundTrip([UInt8](repeating: 0xFF, count: n), "white \(n)") }
    // Match length extension boundaries (t = len - 2; one byte up to 31, then +255 steps).
    for len in [32, 33, 34, 35, 36, 37, 286, 287, 288, 289, 290, 291, 292, 541, 542, 543, 544, 545, 546, 547, 548] {
        roundTrip([UInt8](repeating: 7, count: len + 4), "run with match length \(len)")
    }
    // Literal run length boundaries (18 / 19, then 255-step extensions).
    for n in [17, 18, 19, 20, 272, 273, 274, 275, 527, 528, 529, 530, 4095, 4096, 4097] {
        roundTrip(rng.bytes(n), "literal run \(n)")
        roundTrip(rng.bytes(n) + [UInt8](repeating: 0, count: 50) + rng.bytes(3), "literals \(n) + run + 3")
    }
    // 1, 2 and 3 literals carried in the previous match.
    for tail in 0 ... 5 {
        roundTrip([UInt8](repeating: 9, count: 100) + rng.bytes(tail), "run + \(tail) literals")
        roundTrip([UInt8](repeating: 9, count: 100) + rng.bytes(tail) + [UInt8](repeating: 3, count: 100),
                  "run + \(tail) literals + run")
    }
    // Match distances around the 16384 limit.
    for dist in [1, 2, 3, 4, 5, 16382, 16383, 16384, 16385, 16386, 20000] {
        let block = rng.bytes(64)
        var src = block
        src += rng.bytes(max(0, dist - 64), alphabet: 255).map { $0 == block[0] ? 254 : $0 }
        src += block + rng.bytes(5)
        roundTrip(src, "repeat at distance \(dist)")
    }
    roundTrip([UInt8](repeating: 0xFF, count: 1 << 20), "1 MB of white")
    roundTrip([UInt8](repeating: 0, count: 1 << 20), "1 MB of black")
    roundTrip(rng.bytes(200_000), "200 kB random")
    roundTrip(rng.bytes(200_000, alphabet: 2), "200 kB two-symbol")
    roundTrip(rng.bytes(200_000, alphabet: 4).map { $0 == 0 ? 0x00 : 0xFF }, "200 kB mostly white")
    for _ in 0 ..< 400 {
        // Runs of random length mixed with random bytes.
        var src = [UInt8]()
        let target = rng.below(9000)
        while src.count < target {
            if rng.below(3) == 0 { src += rng.bytes(1 + rng.below(40)) }
            else { src += [UInt8](repeating: UInt8(rng.below(4) * 85), count: 1 + rng.below(700)) }
        }
        roundTrip(src, "mixed runs \(src.count)")
    }
    // The raster sizes used with this printer: 102 x 1218 (old narrow job) and 108 x 1218.
    let narrow = testPage(width: 812, height: 1218).placed(onCanvasWidth: 816, leftDot: 0)
    check(narrow.data.count == 124_236, "102-byte rows x 1218 = 124,236 bytes")
    roundTrip(narrow.data, "124,236-byte mostly white raster")
    let narrowPacked = Lzo.compress(narrow.data)
    check(narrowPacked.count < narrow.data.count / 4, "mostly white raster should compress well")

    // ---- LZO: malformed input must throw, not crash ------------------------
    let good = Lzo.compress(testPage(width: 812, height: 64).data)
    for cut in 0 ..< good.count {
        do { _ = try Lzo.decompress(Array(good.prefix(cut))); check(false, "truncated stream (\(cut)) decoded") }
        catch { checks += 1 }
    }
    do { _ = try Lzo.decompress(good + [0]); check(false, "trailing byte accepted") }
    catch { check(error as? LzoError == .trailingBytes, "trailing byte: wrong error \(error)") }
    do { _ = try Lzo.decompress([1, 1, 2, 3, 4, 34, 0xFC, 0xFF, 0x11, 0, 0]); check(false, "match before start accepted") }
    catch { check(error as? LzoError == .lookbehindOverrun, "lookbehind: wrong error \(error)") }
    do { _ = try Lzo.decompress(Lzo.compress([UInt8](repeating: 1, count: 5000)), maxOutput: 4096)
         check(false, "output limit ignored") }
    catch { check(error as? LzoError == .outputOverrun, "output limit: wrong error \(error)") }
    var survived = 0
    for _ in 0 ..< 50_000 {     // random garbage and corrupted real streams
        var junk: [UInt8]
        if rng.below(2) == 0 { junk = rng.bytes(rng.below(48)) }
        else { junk = good; for _ in 0 ... rng.below(3) { junk[rng.below(junk.count)] = UInt8(rng.below(256)) } }
        _ = try? Lzo.decompress(junk, maxOutput: 1 << 20)
        survived += 1
    }
    check(survived == 50_000, "fuzz loop")

    // ---- Bitmap -----------------------------------------------------------
    var bm = MonoBitmap(width: 812, height: 3)
    check(bm.bytesPerRow == 102 && bm.data.allSatisfy { $0 == 0xFF }, "new bitmap is white, 102 bytes per row")
    bm.set(0, 0); bm.set(7, 0); bm.set(8, 1); bm.set(811, 2); bm.set(812, 2); bm.set(-1, 0)
    check(bm.data[0] == 0b0111_1110, "MSB first, 0 = black")
    check(bm.data[102 + 1] == 0b0111_1111, "dot 8 is the top bit of byte 1")
    check(bm.data[2 * 102 + 101] == 0b1110_1111, "last dot of an 812-wide row; pad bits stay white")
    check(bm.isBlack(811, 2) && !bm.isBlack(810, 2), "isBlack")
    bm.set(0, 0, black: false)
    check(bm.data[0] == 0b1111_1110, "clearing a dot")
    bm.fill(x: 900, y: 1, width: 5, height: 5); bm.fill(x: 0, y: 9, width: 5, height: 5)
    bm.fill(x: -10, y: -10, width: 5, height: 5); bm.fill(x: 3, y: 1, width: 0, height: 1)
    check(bm.data[102] == 0xFF && bm.data[0] == 0b1111_1110, "fills outside the bitmap do nothing")
    bm.fill(x: 808, y: 1, width: 100, height: 100)
    check(bm.data[102 + 101] == 0x0F && bm.data[2 * 102 + 101] == 0x0F, "fill is clipped; pad bits stay white")

    // ---- TSPL job ---------------------------------------------------------
    var cfg = PrinterConfig()
    check(cfg.leftDot == 0 && cfg.topDot == 10, "default position is the one measured with the ruler")
    cfg.leftDot = 1; cfg.topDot = 0     // fixed values for the checks below
    let page = testPage(width: cfg.labelWidthDots, height: cfg.labelHeightDots)
    let canvas = Tspl.canvas(for: page, config: cfg)
    check(canvas.width == 864 && canvas.bytesPerRow == 108 && canvas.height == 1218, "canvas is 864 x 1218")
    check(canvas.data.count == 131_544, "canvas raster is 131,544 bytes")
    var placedOK = true
    for y in stride(from: 0, to: 1218, by: 7) {
        if canvas.isBlack(0, y) { placedOK = false }                 // head dot 0 unused
        for x in 0 ..< 812 where canvas.isBlack(x + 1, y) != page.isBlack(x, y) { placedOK = false }
        for x in 813 ..< 864 where canvas.isBlack(x, y) { placedOK = false }
    }
    check(placedOK, "page sits at head dots 1...812, the rest is white")
    check(canvas.isBlack(1, 600) && canvas.isBlack(812, 600) && !canvas.isBlack(813, 600),
          "page border lands on head dots 1 and 812")

    check(Tspl.speedCommand(cfg) == Array("SPEED 1\r\n".utf8), "SPEED command")
    do {
        let job = try Tspl.job(canvas: canvas, config: cfg, copies: 1)
        let expectedHead = "SIZE 108 mm,152.4 mm\r\nREFERENCE 0,0\r\nGAP 4.60 mm,0.00 mm\r\nOFFSET 0 mm\r\n"
            + "DIRECTION 0,0\r\nDENSITY 10\r\nCLS\r\nBITMAP 0,0,108,1218,4,"
        check(Array(job.prefix(expectedHead.utf8.count)) == Array(expectedHead.utf8), "job header bytes")
        let expectedTail = Array("\r\nPRINT 1,1\r\n".utf8)
        check(Array(job.suffix(expectedTail.count)) == expectedTail, "job trailer bytes")
        let term = job[(job.count - expectedTail.count - 4) ..< (job.count - expectedTail.count)]
        check(Array(term) == [0, 0, 0, 0], "four zero bytes after the last piece")

        let parsed = try Tspl.parseJob(job)
        check(parsed.raster == canvas.data, "job parses back to the same raster")
        check(parsed.pieceSizes.count == 33, "131,544 bytes = 32 full pieces + 1 of 472 (got \(parsed.pieceSizes.count))")
        check(parsed.widthBytes == 108 && parsed.heightDots == 1218 && parsed.mode == 4, "BITMAP parameters")
        check(parsed.headerLines == ["SIZE 108 mm,152.4 mm", "REFERENCE 0,0", "GAP 4.60 mm,0.00 mm",
                                     "OFFSET 0 mm", "DIRECTION 0,0", "DENSITY 10", "CLS"], "header lines")
        check(parsed.trailerLines == ["", "PRINT 1,1"], "trailer lines")

        // Walk the payload by hand, independently of parseJob.
        var pos = expectedHead.utf8.count
        var pieces = 0, total = 0
        while true {
            let len = Int(job[pos]) | Int(job[pos + 1]) << 8 | Int(job[pos + 2]) << 16 | Int(job[pos + 3]) << 24
            pos += 4
            if len == 0 { break }
            let piece = try Lzo.decompress(Array(job[pos ..< pos + len]))
            check(piece.count == (pieces < 32 ? 4096 : 472), "piece \(pieces) is \(piece.count) bytes")
            check(piece == Array(canvas.data[total ..< total + piece.count]), "piece \(pieces) content")
            pieces += 1; total += piece.count; pos += len
        }
        check(pieces == 33 && total == 131_544, "manual walk: 33 pieces, 131,544 bytes")
        check(pos == job.count - expectedTail.count, "manual walk ends at the trailer")

        // An all-white label and a 3-copy job.
        let blank = MonoBitmap(width: 864, height: 1218)
        let blankJob = try Tspl.job(canvas: blank, config: cfg, copies: 3)
        check(try Tspl.parseJob(blankJob).raster == blank.data, "blank label round trip")
        check(try Tspl.parseJob(blankJob).trailerLines == ["", "PRINT 1,3"], "copies")

        // Changed settings show up in the commands.
        var other = PrinterConfig()
        other.density = 12; other.speed = 3; other.gapMm = 3; other.leftDot = 0
        let otherJob = try Tspl.job(canvas: Tspl.canvas(for: page, config: other), config: other)
        let otherParsed = try Tspl.parseJob(otherJob)
        check(otherParsed.headerLines.contains("DENSITY 12") && otherParsed.headerLines.contains("GAP 3.00 mm,0.00 mm"),
              "density and gap settings")
        check(Tspl.speedCommand(other) == Array("SPEED 3\r\n".utf8), "speed setting")
        check(otherParsed.raster != canvas.data, "leftDot moves the page")

        // A page pushed past the right edge of the head is clipped, not wrapped.
        var far = PrinterConfig(); far.leftDot = 60; far.topDot = 0
        let clipped = Tspl.canvas(for: page, config: far)
        check(clipped.isBlack(60, 600) && clipped.isBlack(863, 0) && !clipped.isBlack(0, 1), "clipping at the head edge")

        // topDot moves the page down; the rows pushed past the bottom are dropped.
        var low = PrinterConfig(); low.leftDot = 0; low.topDot = 10
        let lowered = Tspl.canvas(for: page, config: low)
        check(lowered.height == 1218 && lowered.data.count == 131_544, "topDot keeps the canvas size")
        var loweredOK = !lowered.isBlack(0, 9) && lowered.isBlack(0, 10) && lowered.isBlack(811, 10)
        for y in stride(from: 0, to: 1208, by: 11) {
            for x in stride(from: 0, to: 812, by: 3) where lowered.isBlack(x, y + 10) != page.isBlack(x, y) { loweredOK = false }
        }
        for x in 0 ..< 864 where lowered.isBlack(x, 5) { loweredOK = false }
        check(loweredOK, "topDot 10: page row 0 lands on canvas row 10, rows above are blank")
        check((try? Tspl.parseJob(try Tspl.job(canvas: lowered, config: low)))?.heightDots == 1218, "job height unchanged by topDot")

        // Wrong inputs are refused.
        do { _ = try Tspl.job(canvas: narrow, config: cfg); check(false, "narrow canvas accepted") }
        catch { check(error as? TsplError == .canvasWidth(expected: 864, got: 816), "narrow canvas error") }
        do { _ = try Tspl.job(canvas: canvas, config: cfg, copies: 0); check(false, "0 copies accepted") }
        catch { check(error as? TsplError == .copies(0), "copies error") }
        // A job without the terminator, or cut short, does not parse.
        var noTerm = job
        noTerm.removeSubrange((job.count - expectedTail.count - 4) ..< (job.count - expectedTail.count))
        check((try? Tspl.parseJob(noTerm)) == nil, "job without the four zero bytes is rejected")
        check((try? Tspl.parseJob(Array(job.prefix(job.count / 2)))) == nil, "half a job is rejected")
    } catch {
        check(false, "TSPL section threw \(error)")
    }
}

func readFile(_ path: String) -> [UInt8] {
    guard let d = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); exit(2) }
    return [UInt8](d)
}

func writeFile(_ path: String, _ bytes: [UInt8]) {
    guard FileManager.default.createFile(atPath: path, contents: Data(bytes)) else { print("cannot write \(path)"); exit(2) }
}

let args = CommandLine.arguments
if args.count == 4 && args[1] == "lzo-c" {
    writeFile(args[3], Lzo.compress(readFile(args[2])))
} else if args.count == 4 && args[1] == "lzo-d" {
    do { writeFile(args[3], try Lzo.decompress(readFile(args[2]))) }
    catch { print("decompress failed: \(error)"); exit(1) }
} else if args.count == 3 && args[1] == "sample" {
    let cfg = PrinterConfig()
    let canvas = Tspl.canvas(for: testPage(width: cfg.labelWidthDots, height: cfg.labelHeightDots), config: cfg)
    do {
        let job = try Tspl.job(canvas: canvas, config: cfg)
        try FileManager.default.createDirectory(atPath: args[2], withIntermediateDirectories: true)
        writeFile(args[2] + "/canvas.pbm", canvas.pbm())
        writeFile(args[2] + "/job.bin", job)
        writeFile(args[2] + "/raster.bin", canvas.data)
        // Decode the job again and save what a printer would see.
        let parsed = try Tspl.parseJob(job)
        var seen = MonoBitmap(width: parsed.widthBytes * 8, height: parsed.heightDots)
        for y in 0 ..< seen.height { for x in 0 ..< seen.width
            where parsed.raster[y * parsed.widthBytes + x / 8] & (0x80 >> UInt8(x % 8)) == 0 { seen.set(x, y) } }
        writeFile(args[2] + "/decoded.pbm", seen.pbm())
        print("wrote canvas.pbm, decoded.pbm, raster.bin and job.bin (\(job.count) bytes) to \(args[2])")
    } catch { print("sample failed: \(error)"); exit(1) }
} else if args.count == 1 {
    runTests()
    runStep3Tests()
    print("\(checks) checks, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
} else {
    print("usage: d450-selftest [sample <dir> | lzo-c <in> <out> | lzo-d <in> <out>]")
    exit(2)
}
