/// 8-bit greyscale image, row by row. 0 = black, 255 = white.
public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    /// A white image.
    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "image must not be empty")
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 255, count: width * height)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height, "bad image size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Smallest rectangle holding every pixel darker than `level`, or nil if there is none.
    public func inkBounds(below level: UInt8) -> (x: Int, y: Int, width: Int, height: Int)? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        pixels.withUnsafeBufferPointer { p in
            for y in 0 ..< height {
                let row = y * width
                var first = -1, last = -1
                for x in 0 ..< width where p[row + x] < level {
                    if first < 0 { first = x }
                    last = x
                }
                if first >= 0 {
                    if first < minX { minX = first }
                    if last > maxX { maxX = last }
                    if y < minY { minY = y }
                    maxY = y
                }
            }
        }
        if maxX < 0 { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> GrayImage {
        precondition(x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= width && y + h <= height, "crop out of range")
        var out = [UInt8]()
        out.reserveCapacity(w * h)
        for yy in y ..< y + h { out.append(contentsOf: pixels[yy * width + x ..< yy * width + x + w]) }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Quarter turn. Clockwise: the left edge becomes the top edge.
    public func rotated(clockwise: Bool) -> GrayImage {
        var out = [UInt8](repeating: 255, count: width * height)
        let (nw, nh) = (height, width)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (nx, ny) = clockwise ? (height - 1 - y, x) : (y, width - 1 - x)
                out[ny * nw + nx] = pixels[y * width + x]
            }
        }
        return GrayImage(width: nw, height: nh, pixels: out)
    }

    /// Copies this image onto a white canvas with its top-left corner at
    /// (`x`, `y`), which may be negative. Parts outside the canvas are dropped.
    public func placed(onWidth cw: Int, height ch: Int, x: Int, y: Int) -> GrayImage {
        var canvas = GrayImage(width: cw, height: ch)
        let x0 = max(0, x), x1 = min(cw, x + width)
        let y0 = max(0, y), y1 = min(ch, y + height)
        guard x0 < x1 && y0 < y1 else { return canvas }
        for cy in y0 ..< y1 {
            let src = (cy - y) * width + (x0 - x)
            canvas.pixels.replaceSubrange(cy * cw + x0 ..< cy * cw + x1, with: pixels[src ..< src + (x1 - x0)])
        }
        return canvas
    }

    /// Resamples by area averaging: each output pixel is the mean of the
    /// source area it covers, with partial pixels weighted by coverage.
    public func resized(toWidth nw: Int, height nh: Int) -> GrayImage {
        precondition(nw > 0 && nh > 0, "bad target size")
        if nw == width && nh == height { return self }
        // Horizontal pass into floats, then vertical pass.
        let wx = GrayImage.weights(from: width, to: nw)
        var mid = [Float](repeating: 0, count: nw * height)
        for y in 0 ..< height {
            let row = y * width
            for ox in 0 ..< nw {
                var sum: Float = 0
                for (i, w) in wx[ox] { sum += Float(pixels[row + i]) * w }
                mid[y * nw + ox] = sum
            }
        }
        let wy = GrayImage.weights(from: height, to: nh)
        var out = [UInt8](repeating: 255, count: nw * nh)
        for oy in 0 ..< nh {
            for ox in 0 ..< nw {
                var sum: Float = 0
                for (i, w) in wy[oy] { sum += mid[i * nw + ox] * w }
                out[oy * nw + ox] = UInt8(max(0, min(255, sum.rounded())))
            }
        }
        return GrayImage(width: nw, height: nh, pixels: out)
    }

    /// For each output index, the source indexes it covers and their weights (summing to 1).
    private static func weights(from n: Int, to m: Int) -> [[(Int, Float)]] {
        let ratio = Double(n) / Double(m)
        return (0 ..< m).map { o in
            let start = Double(o) * ratio
            let end = min(Double(n), start + ratio)
            var list = [(Int, Float)]()
            var i = Int(start)
            while i < n && Double(i) < end {
                let cover = min(end, Double(i + 1)) - max(start, Double(i))
                if cover > 1e-9 { list.append((i, Float(cover / (end - start)))) }
                i += 1
            }
            if list.isEmpty { list.append((min(n - 1, Int(start)), 1)) }
            return list
        }
    }
}
