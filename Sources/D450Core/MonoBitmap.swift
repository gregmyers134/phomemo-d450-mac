/// 1-bit raster in the printer's own layout: rows of `bytesPerRow` bytes,
/// most significant bit first, 1 = white, 0 = black. Pad bits are white.
public struct MonoBitmap: Equatable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public private(set) var data: [UInt8]

    /// A white bitmap.
    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "bitmap must not be empty")
        self.width = width
        self.height = height
        self.bytesPerRow = (width + 7) / 8
        self.data = [UInt8](repeating: 0xFF, count: bytesPerRow * height)
    }

    public func isBlack(_ x: Int, _ y: Int) -> Bool {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel out of range")
        return data[y * bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) == 0
    }

    /// Sets one dot. Coordinates outside the bitmap are ignored.
    public mutating func set(_ x: Int, _ y: Int, black: Bool = true) {
        guard x >= 0 && x < width && y >= 0 && y < height else { return }
        let mask = UInt8(0x80) >> UInt8(x % 8)
        if black { data[y * bytesPerRow + x / 8] &= ~mask }
        else { data[y * bytesPerRow + x / 8] |= mask }
    }

    /// Fills a rectangle, clipped to the bitmap.
    public mutating func fill(x: Int, y: Int, width w: Int, height h: Int, black: Bool = true) {
        let (x0, x1) = (max(0, x), min(width, x + w))
        let (y0, y1) = (max(0, y), min(height, y + h))
        guard x0 < x1 && y0 < y1 else { return }
        for yy in y0 ..< y1 {
            for xx in x0 ..< x1 { set(xx, yy, black: black) }
        }
    }

    /// Copies this page onto a white canvas `canvasWidth` dots wide and as tall
    /// as the page, with the page's top-left dot at canvas column `leftDot`,
    /// row `topDot` (both 0-based). Dots that fall outside the canvas are dropped.
    public func placed(onCanvasWidth canvasWidth: Int, leftDot: Int, topDot: Int = 0) -> MonoBitmap {
        var canvas = MonoBitmap(width: canvasWidth, height: height)
        for y in 0 ..< height {
            for x in 0 ..< width where isBlack(x, y) { canvas.set(x + leftDot, y + topDot) }
        }
        return canvas
    }

    /// Binary PBM (P4), for looking at a bitmap in dry runs. PBM uses 1 = black.
    public func pbm() -> [UInt8] {
        var out = Array("P4\n\(width) \(height)\n".utf8)
        let padBits = bytesPerRow * 8 - width
        let padMask: UInt8 = padBits == 0 ? 0xFF : ~UInt8((1 << padBits) - 1)
        for y in 0 ..< height {
            for b in 0 ..< bytesPerRow {
                var v = ~data[y * bytesPerRow + b]
                if b == bytesPerRow - 1 { v &= padMask }
                out.append(v)
            }
        }
        return out
    }
}
