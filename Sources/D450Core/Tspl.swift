import Foundation

/// Settings for one D450 and one label stock (4x6" die-cut labels). Density,
/// speed and gap are the values Labelife uses. `leftDot` and `topDot` come
/// from a ruler print made from the Mac: the label's left edge lay about 18
/// dots to the left of head dot 0, out of the head's reach, its right edge at
/// head dot 808, and its top edge at row 10 of the print.
public struct PrinterConfig: Equatable {
    public var density = 10          // DENSITY
    public var speed = 1             // SPEED, 1 to 8
    public var gapMm = 4.60          // gap between labels
    public var gapOffsetMm = 0.0
    public var dotsPerMm = 8         // 203 dpi
    public var headDots = 864        // print head width (108 mm)
    public var labelWidthDots = 812  // 4"
    public var labelHeightDots = 1218 // 6"
    public var labelHeightMm = 152.4
    /// Canvas column (0-based) where the page's left column goes.
    public var leftDot = 0
    /// Canvas row (0-based) where the page's top row goes. The printer starts
    /// printing a little above the label's top edge; this skips those rows.
    /// The same number of rows at the bottom of the page is not printed.
    public var topDot = 10

    public init() {}
}

public enum TsplError: Error, Equatable {
    case canvasWidth(expected: Int, got: Int)
    case copies(Int)
    case malformedJob(String)
}

public struct ParsedJob: Equatable {
    public var headerLines: [String]   // commands before BITMAP
    public var widthBytes: Int
    public var heightDots: Int
    public var mode: Int
    public var pieceSizes: [Int]       // compressed size of each piece
    public var raster: [UInt8]
    public var trailerLines: [String]  // commands after the bitmap
}

public enum Tspl {
    /// BITMAP mode 4 splits the raster into pieces of this many bytes.
    public static let pieceSize = 4096

    /// Sent on its own just before the job.
    public static func speedCommand(_ config: PrinterConfig) -> [UInt8] {
        Array("SPEED \(config.speed)\r\n".utf8)
    }

    /// The page placed on a full-head-width canvas at (`leftDot`, `topDot`).
    /// Always sending the full head width stops the printer centring the job
    /// (which lands it about 5 mm too far right).
    public static func canvas(for page: MonoBitmap, config: PrinterConfig) -> MonoBitmap {
        page.placed(onCanvasWidth: config.headDots, leftDot: config.leftDot, topDot: config.topDot)
    }

    /// One complete job for one canvas. `canvas` must be `config.headDots` wide.
    public static func job(canvas: MonoBitmap, config: PrinterConfig, copies: Int = 1) throws -> [UInt8] {
        guard canvas.width == config.headDots else {
            throw TsplError.canvasWidth(expected: config.headDots, got: canvas.width)
        }
        guard copies >= 1 else { throw TsplError.copies(copies) }
        let widthMm = Double(config.headDots) / Double(config.dotsPerMm)
        var out = [UInt8]()
        func line(_ s: String) { out.append(contentsOf: Array((s + "\r\n").utf8)) }
        line("SIZE \(short(widthMm)) mm,\(short(config.labelHeightMm)) mm")
        line("REFERENCE 0,0")
        line("GAP \(fixed2(config.gapMm)) mm,\(fixed2(config.gapOffsetMm)) mm")
        line("OFFSET 0 mm")
        line("DIRECTION 0,0")
        line("DENSITY \(config.density)")
        line("CLS")
        out.append(contentsOf: Array("BITMAP 0,0,\(canvas.bytesPerRow),\(canvas.height),4,".utf8))
        out.append(contentsOf: encodeBitmapMode4(canvas.data))
        line("")
        line("PRINT 1,\(copies)")
        return out
    }

    /// Mode 4 payload: each 4096-byte piece (the last may be shorter) is
    /// compressed on its own and sent as a 4-byte little-endian compressed
    /// length plus the compressed bytes. Four zero bytes end the payload;
    /// without them the printer accepts the job and prints nothing.
    public static func encodeBitmapMode4(_ raster: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var pos = 0
        while pos < raster.count {
            let end = min(pos + pieceSize, raster.count)
            let packed = Lzo.compress(Array(raster[pos ..< end]))
            appendLE32(&out, packed.count)
            out.append(contentsOf: packed)
            pos = end
        }
        appendLE32(&out, 0)
        return out
    }

    /// Reads a job back into its raster. Used by tests and by dry-run mode.
    public static func parseJob(_ job: [UInt8]) throws -> ParsedJob {
        var pos = 0
        func fail(_ why: String) -> TsplError { .malformedJob("\(why) at byte \(pos)") }
        func readLine() throws -> String {
            var end = pos
            while end + 1 < job.count && !(job[end] == 13 && job[end + 1] == 10) { end += 1 }
            guard end + 1 < job.count else { throw fail("missing CR LF") }
            defer { pos = end + 2 }
            return String(decoding: job[pos ..< end], as: UTF8.self)
        }
        let marker = Array("BITMAP ".utf8)
        var header = [String]()
        while !(pos + marker.count <= job.count && Array(job[pos ..< pos + marker.count]) == marker) {
            header.append(try readLine())
        }
        pos += marker.count
        // Five numeric fields, each ended by a comma: x, y, width bytes, height, mode.
        var fields = [Int]()
        while fields.count < 5 {
            var digits = ""
            while pos < job.count && job[pos] != UInt8(ascii: ",") {
                digits.append(Character(UnicodeScalar(job[pos])))
                pos += 1
            }
            guard pos < job.count, let v = Int(digits) else { throw fail("bad BITMAP field") }
            fields.append(v)
            pos += 1
        }
        let (widthBytes, heightDots, mode) = (fields[2], fields[3], fields[4])
        guard mode == 4 else { throw fail("unsupported BITMAP mode \(mode)") }
        let total = widthBytes * heightDots
        var raster = [UInt8]()
        var sizes = [Int]()
        while true {
            guard pos + 4 <= job.count else { throw fail("missing piece length") }
            let len = Int(job[pos]) | Int(job[pos + 1]) << 8 | Int(job[pos + 2]) << 16 | Int(job[pos + 3]) << 24
            pos += 4
            if len == 0 { break }
            guard pos + len <= job.count else { throw fail("piece runs past end of job") }
            guard raster.count < total else { throw fail("more pieces than the raster needs") }
            let piece: [UInt8]
            do { piece = try Lzo.decompress(Array(job[pos ..< pos + len]), maxOutput: pieceSize) }
            catch { throw fail("piece \(sizes.count) does not decompress (\(error))") }
            guard piece.count == min(pieceSize, total - raster.count) else {
                throw fail("piece \(sizes.count) has the wrong size \(piece.count)")
            }
            raster.append(contentsOf: piece)
            sizes.append(len)
            pos += len
        }
        guard raster.count == total else { throw fail("raster is \(raster.count) bytes, expected \(total)") }
        var trailer = [String]()
        while pos < job.count { trailer.append(try readLine()) }
        return ParsedJob(headerLines: header, widthBytes: widthBytes, heightDots: heightDots,
                         mode: mode, pieceSizes: sizes, raster: raster, trailerLines: trailer)
    }

    private static func appendLE32(_ out: inout [UInt8], _ v: Int) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }

    /// 4.6 -> "4.60"
    private static func fixed2(_ v: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    /// 108.0 -> "108", 152.4 -> "152.4"
    private static func short(_ v: Double) -> String {
        var s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
