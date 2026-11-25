/// Minimal PNG writer for dry-run output. Pixel data is stored uncompressed
/// (deflate "stored" blocks), which needs no compression library.
public enum Png {
    /// 1-bit greyscale PNG of a bitmap. PNG and the printer agree: 1 = white.
    public static func encode(_ bitmap: MonoBitmap) -> [UInt8] {
        encode(width: bitmap.width, height: bitmap.height, bitDepth: 1,
               bytesPerRow: bitmap.bytesPerRow, rows: bitmap.data)
    }

    /// 8-bit greyscale PNG.
    public static func encode(_ image: GrayImage) -> [UInt8] {
        encode(width: image.width, height: image.height, bitDepth: 8,
               bytesPerRow: image.width, rows: image.pixels)
    }

    private static func encode(width: Int, height: Int, bitDepth: UInt8, bytesPerRow: Int, rows: [UInt8]) -> [UInt8] {
        var raw = [UInt8]()                     // each row prefixed with filter type 0
        raw.reserveCapacity((bytesPerRow + 1) * height)
        for y in 0 ..< height {
            raw.append(0)
            raw.append(contentsOf: rows[y * bytesPerRow ..< (y + 1) * bytesPerRow])
        }
        var z: [UInt8] = [0x78, 0x01]           // zlib header, no compression
        var pos = 0
        repeat {
            let len = min(65535, raw.count - pos)
            z.append(pos + len == raw.count ? 1 : 0)
            z.append(UInt8(len & 0xFF)); z.append(UInt8(len >> 8))
            z.append(UInt8(~len & 0xFF)); z.append(UInt8((~len >> 8) & 0xFF))
            z.append(contentsOf: raw[pos ..< pos + len])
            pos += len
        } while pos < raw.count
        z.append(contentsOf: be32(adler32(raw)))

        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        chunk(&png, "IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [bitDepth, 0, 0, 0, 0])
        chunk(&png, "IDAT", z)
        chunk(&png, "IEND", [])
        return png
    }

    private static func chunk(_ png: inout [UInt8], _ type: String, _ body: [UInt8]) {
        let typed = Array(type.utf8) + body
        png.append(contentsOf: be32(UInt32(body.count)))
        png.append(contentsOf: typed)
        png.append(contentsOf: be32(crc32(typed)))
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    public static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for v in bytes {
            a = (a + UInt32(v)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}
