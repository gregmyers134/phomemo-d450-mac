// Decoders for the two page-raster formats a driverless print queue sends:
// PWG Raster ("RaS2", PWG 5102.4) and Apple Raster / URF ("UNIRAST").
// Both use the same run-length row coding; they differ in their headers.

public struct RasterPage {
    public var image: GrayImage
    public var dpiX: Int
    public var dpiY: Int
    /// Short description of what was received, for the log.
    public var source: String

    public init(image: GrayImage, dpiX: Int, dpiY: Int, source: String) {
        self.image = image
        self.dpiX = dpiX
        self.dpiY = dpiY
        self.source = source
    }
}

public enum RasterFormat: String { case pwg, urf }

public enum RasterError: Error, Equatable {
    case unknownFormat
    case truncated
    case unsupported(String)
}

public enum RasterDocument {
    /// Largest page accepted, in dots. Letter at 203 dpi is 1726 x 2233.
    static let maxWidth = 12_000
    static let maxHeight = 24_000

    public static func format(of data: [UInt8]) -> RasterFormat? {
        if data.count >= 4 && Array(data[0 ..< 4]) == Array("RaS2".utf8) { return .pwg }
        if data.count >= 8 && Array(data[0 ..< 8]) == Array("UNIRAST".utf8) + [0] { return .urf }
        return nil
    }

    /// Decodes pages one at a time and hands each to `body`. `body` returns
    /// false to stop early. Returns the number of pages handed over.
    @discardableResult
    public static func forEachPage(_ data: [UInt8], _ body: (RasterPage) throws -> Bool) throws -> Int {
        guard let format = format(of: data) else { throw RasterError.unknownFormat }
        var pos = format == .pwg ? 4 : 12     // URF: magic then a 4-byte page count
        if pos > data.count { throw RasterError.truncated }
        var pages = 0
        while pos < data.count {
            let page = try format == .pwg ? pwgPage(data, &pos) : urfPage(data, &pos)
            pages += 1
            if try !body(page) { break }
        }
        if pages == 0 { throw RasterError.truncated }
        return pages
    }

    private enum Pixel { case gray, black, rgb }

    private static func be32(_ d: [UInt8], _ at: Int) -> Int {
        Int(d[at]) << 24 | Int(d[at + 1]) << 16 | Int(d[at + 2]) << 8 | Int(d[at + 3])
    }

    private static func pwgPage(_ d: [UInt8], _ pos: inout Int) throws -> RasterPage {
        guard pos + 1796 <= d.count else { throw RasterError.truncated }
        let h = pos
        let (dpiX, dpiY) = (be32(d, h + 276), be32(d, h + 280))
        let (width, height) = (be32(d, h + 372), be32(d, h + 376))
        let bitsPerPixel = be32(d, h + 388)
        let bytesPerLine = be32(d, h + 392)
        let colorOrder = be32(d, h + 396)
        let colorSpace = be32(d, h + 400)
        pos += 1796
        let kind: Pixel
        switch colorSpace {
        case 0, 18: kind = .gray          // device grey, sGray: 0 = black
        case 3: kind = .black             // black: 1 (or 255) = ink
        case 1, 19, 20: kind = .rgb       // device RGB, sRGB, Adobe RGB
        default: throw RasterError.unsupported("PWG colour space \(colorSpace)")
        }
        guard colorOrder == 0 else { throw RasterError.unsupported("PWG colour order \(colorOrder)") }
        let image = try decode(d, &pos, width: width, height: height, bitsPerPixel: bitsPerPixel,
                               bytesPerLine: bytesPerLine, kind: kind)
        return RasterPage(image: image, dpiX: dpiX, dpiY: dpiY,
                          source: "PWG \(width)x\(height) \(dpiX)dpi \(bitsPerPixel)-bit colour space \(colorSpace)")
    }

    private static func urfPage(_ d: [UInt8], _ pos: inout Int) throws -> RasterPage {
        guard pos + 32 <= d.count else { throw RasterError.truncated }
        let h = pos
        let bitsPerPixel = Int(d[h])
        let colorSpace = Int(d[h + 1])
        let (width, height, dpi) = (be32(d, h + 12), be32(d, h + 16), be32(d, h + 20))
        pos += 32
        let kind: Pixel
        switch colorSpace {
        case 0, 4: kind = .gray           // sGray, device grey
        case 1, 3, 5: kind = .rgb         // sRGB, Adobe RGB, device RGB
        default: throw RasterError.unsupported("URF colour space \(colorSpace)")
        }
        guard width <= maxWidth else { throw RasterError.unsupported("page \(width) dots wide") }
        let image = try decode(d, &pos, width: width, height: height, bitsPerPixel: bitsPerPixel,
                               bytesPerLine: width * bitsPerPixel / 8, kind: kind)
        return RasterPage(image: image, dpiX: dpi, dpiY: dpi,
                          source: "URF \(width)x\(height) \(dpi)dpi \(bitsPerPixel)-bit colour space \(colorSpace)")
    }

    private static func decode(_ d: [UInt8], _ pos: inout Int, width: Int, height: Int, bitsPerPixel: Int,
                               bytesPerLine: Int, kind: Pixel) throws -> GrayImage {
        guard width >= 1 && height >= 1 && width <= maxWidth && height <= maxHeight else {
            throw RasterError.unsupported("page size \(width)x\(height)")
        }
        // The run-length unit is one pixel, or one byte (8 pixels) for 1-bit data.
        let unit: Int
        switch (bitsPerPixel, kind) {
        case (1, .gray), (1, .black), (8, .gray), (8, .black): unit = 1
        case (24, .rgb): unit = 3
        default: throw RasterError.unsupported("\(bitsPerPixel) bits per pixel")
        }
        guard bytesPerLine == (width * bitsPerPixel + 7) / 8 else {
            throw RasterError.unsupported("bytes per line \(bytesPerLine) for width \(width)")
        }
        let blank: UInt8 = kind == .black ? 0x00 : 0xFF
        var image = GrayImage(width: width, height: height)
        var row = [UInt8](repeating: blank, count: bytesPerLine)
        let n = d.count
        var y = 0
        while y < height {
            guard pos < n else { throw RasterError.truncated }
            let repeats = Int(d[pos]) + 1
            pos += 1
            var filled = 0
            while filled < bytesPerLine {
                guard pos < n else { throw RasterError.truncated }
                let c = Int(d[pos])
                pos += 1
                if c == 128 {                       // rest of the line is blank
                    for i in filled ..< bytesPerLine { row[i] = blank }
                    filled = bytesPerLine
                } else if c < 128 {                 // one unit repeated c + 1 times
                    guard pos + unit <= n else { throw RasterError.truncated }
                    let count = min((c + 1) * unit, bytesPerLine - filled)
                    for i in 0 ..< count { row[filled + i] = d[pos + i % unit] }
                    pos += unit
                    filled += count
                } else {                            // 257 - c literal units
                    let want = (257 - c) * unit
                    guard pos + want <= n else { throw RasterError.truncated }
                    let count = min(want, bytesPerLine - filled)
                    for i in 0 ..< count { row[filled + i] = d[pos + i] }
                    pos += want
                    filled += count
                }
            }
            // Convert the row to grey once, then copy it for each repeat.
            let base = y * width
            switch (bitsPerPixel, kind) {
            case (8, .gray):
                for x in 0 ..< width { image.pixels[base + x] = row[x] }
            case (8, .black):
                for x in 0 ..< width { image.pixels[base + x] = 255 - row[x] }
            case (1, _):
                for x in 0 ..< width {
                    let bit = row[x / 8] & (0x80 >> UInt8(x % 8)) != 0
                    image.pixels[base + x] = (bit == (kind == .black)) ? 0 : 255
                }
            default:    // 24-bit RGB to luma
                for x in 0 ..< width {
                    let (r, g, b) = (Int(row[x * 3]), Int(row[x * 3 + 1]), Int(row[x * 3 + 2]))
                    image.pixels[base + x] = UInt8((r * 77 + g * 150 + b * 29 + 128) >> 8)
                }
            }
            var copies = 1
            while copies < repeats && y + copies < height {
                let dst = (y + copies) * width
                image.pixels.replaceSubrange(dst ..< dst + width, with: image.pixels[base ..< base + width])
                copies += 1
            }
            y += repeats
        }
        return image
    }
}
