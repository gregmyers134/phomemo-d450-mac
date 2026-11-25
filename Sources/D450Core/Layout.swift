/// Turns one received page into label-sized 1-bit pages.
///
/// - A page the size of the label prints as it is.
/// - A page the size of the label turned sideways is turned 90 degrees.
/// - Any other page (Letter, A4) is searched for its label. Dashed "cut here"
///   lines are taken out first. If they form a cut-out box (one side may be
///   missing), what is inside the box is the label: it is fitted to the label's full width and,
///   if it is then longer than a label, continued on further labels. Otherwise:
///   1. If everything on the page fits on the label, the blank space round it
///      is dropped and it is centred at its exact size (no resampling, so
///      barcodes stay sharp). Within 1% of fitting, the overhang is trimmed.
///   2. If everything on the page has the shape of a label but is bigger, it
///      is one enlarged label and is shrunk to fit, inside a 1.5 mm margin.
///   3. Otherwise the page is split into blocks at its blank bands. A block
///      that fits the label at exact size, upright or sideways, and fills at
///      least half of it is taken as a label; the rest of the page (cut
///      lines, instructions, receipts) is left out. A sheet with two such
///      labels gives two labels, unless the pair together has the shape of
///      one label, in which case rule 2 takes it for a single enlarged one.
///   4. Failing that, the largest block with the shape of a label is shrunk to
///      fit, and failing that, the whole page is.
public enum LabelLayout {
    public struct Result {
        public var page: MonoBitmap
        /// What was done, for the log.
        public var note: String
    }

    /// How far a page may differ from the label size and still count as that size.
    static let sizeTolerance = 3
    /// A blank band at least this wide (4 mm) separates two blocks.
    static let minGap = 32
    /// How far a block's width-to-height ratio may be from the label's and still count as label-shaped.
    static let shapeTolerance = 0.06
    /// Anything that has to be shrunk is fitted inside this margin (1.5 mm), so
    /// that none of it falls in the strips at the label's edges the printer
    /// cannot reach. Content kept at exact size is not given a margin.
    static let shrinkMargin = 12

    /// A rectangle on the page, in dots.
    struct Box: Equatable {
        var x: Int, y: Int, w: Int, h: Int
        var area: Int { w * h }
        func contains(_ o: Box) -> Bool { o.x >= x && o.y >= y && o.x + o.w <= x + w && o.y + o.h <= y + h }
        func overlaps(_ o: Box) -> Bool { o.x < x + w && x < o.x + o.w && o.y < y + h && y < o.y + o.h }
    }

    /// Where the ink is on a page.
    struct InkMap {
        let width: Int
        let height: Int
        let ink: [Bool]

        init(_ image: GrayImage, below level: UInt8) {
            width = image.width
            height = image.height
            ink = image.pixels.map { $0 < level }
        }

        /// For each row (or column) of `b`, whether it holds any ink.
        func profile(_ b: Box, rows: Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: rows ? b.h : b.w)
            ink.withUnsafeBufferPointer { p in
                for y in b.y ..< b.y + b.h {
                    let base = y * width
                    for x in b.x ..< b.x + b.w where p[base + x] {
                        out[rows ? y - b.y : x - b.x] = true
                    }
                }
            }
            return out
        }

        /// `b` shrunk to the ink inside it, or nil if it holds none.
        func tight(_ b: Box) -> Box? {
            let r = profile(b, rows: true), c = profile(b, rows: false)
            guard let y0 = r.firstIndex(of: true), let y1 = r.lastIndex(of: true),
                  let x0 = c.firstIndex(of: true), let x1 = c.lastIndex(of: true) else { return nil }
            return Box(x: b.x + x0, y: b.y + y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
        }

        /// Stretches of ink along one axis of `b`, split wherever a blank band is at least `minGap` wide.
        func stretches(_ b: Box, rows: Bool, minGap: Int = LabelLayout.minGap) -> [Box] {
            let flags = profile(b, rows: rows)
            var parts = [(Int, Int)]()
            var start = -1, last = -1
            for (i, on) in flags.enumerated() where on {
                if start < 0 { start = i } else if i - last > minGap { parts.append((start, last)); start = i }
                last = i
            }
            if start >= 0 { parts.append((start, last)) }
            return parts.compactMap { s, e in
                tight(rows ? Box(x: b.x, y: b.y + s, w: b.w, h: e - s + 1) : Box(x: b.x + s, y: b.y, w: e - s + 1, h: b.h))
            }
        }

        /// Blocks of the page: `b` is cut along its blank bands, across and then down (or the
        /// other way round), and every run of neighbouring pieces is a block, as is each
        /// piece cut again the other way.
        func blocks(in b: Box, rows: Bool, depth: Int = 0, triedOther: Bool = false) -> [Box] {
            let parts = stretches(b, rows: rows)
            if parts.count <= 1 {
                return triedOther || depth > 4 ? [] : blocks(in: b, rows: !rows, depth: depth, triedOther: true)
            }
            var out = [Box]()
            let n = min(parts.count, 12)
            for i in 0 ..< n {
                var run = parts[i]
                for j in i ..< n {
                    if j > i {
                        let p = parts[j]
                        let x0 = min(run.x, p.x), y0 = min(run.y, p.y)
                        run = Box(x: x0, y: y0, w: max(run.x + run.w, p.x + p.w) - x0, h: max(run.y + run.h, p.y + p.h) - y0)
                    }
                    if !(i == 0 && j == parts.count - 1) { out.append(run) }
                }
            }
            if depth < 4 { for p in parts.prefix(n) { out += blocks(in: p, rows: !rows, depth: depth + 1) } }
            return out
        }
    }

    /// The first label found on the page, or nil for a page with no ink when `skipBlankPages` is on.
    public static func layout(_ input: RasterPage, config: ServiceConfig) -> Result? {
        layoutAll(input, config: config).first
    }

    /// Every label found on the page, in reading order. Empty for a page with
    /// no ink when `skipBlankPages` is on.
    ///
    /// With `includeRest`, when a label is cut out of a page that holds other
    /// things too (rules 3 and 4), whatever is left of the page follows as one
    /// more label, shrunk to fit. Cut lines are left out of it.
    public static func layoutAll(_ input: RasterPage, config: ServiceConfig, includeRest: Bool = false) -> [Result] {
        let p = config.printer
        let (labelW, labelH) = (p.labelWidthDots, p.labelHeightDots)
        let printerDpi = 203

        var image = input.image
        var notes = [String]()
        if input.dpiX != printerDpi || input.dpiY != printerDpi, input.dpiX > 0, input.dpiY > 0 {
            let nw = max(1, (image.width * printerDpi + input.dpiX / 2) / input.dpiX)
            let nh = max(1, (image.height * printerDpi + input.dpiY / 2) / input.dpiY)
            image = image.resized(toWidth: nw, height: nh)
            notes.append("resampled from \(input.dpiX)x\(input.dpiY) dpi")
        }

        func finish(_ placed: GrayImage, _ notes: [String]) -> Result {
            let mono = config.dither ? dithered(placed) : thresholded(placed, level: UInt8(config.threshold))
            return Result(page: mono, note: (notes + (config.dither ? ["dithered"] : [])).joined(separator: "; "))
        }

        // With dithering, light greys still print dots, so they count as ink.
        let inkLevel = UInt8(config.dither ? 250 : config.threshold)
        var map = InkMap(image, below: inkLevel)
        let page = Box(x: 0, y: 0, w: image.width, h: image.height)
        let blank = config.skipBlankPages ? [] : [Result(page: MonoBitmap(width: labelW, height: labelH), note: "blank page")]
        guard var all = map.tight(page) else { return blank }

        func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= sizeTolerance }
        if near(image.width, labelW) && near(image.height, labelH) {
            return [finish(image.placed(onWidth: labelW, height: labelH, x: 0, y: 0),
                           notes + ["label-size page, printed as is"])]
        }
        if near(image.width, labelH) && near(image.height, labelW) {
            return [finish(image.rotated(clockwise: config.rotateClockwise).placed(onWidth: labelW, height: labelH, x: 0, y: 0),
                           notes + ["landscape label page, turned 90 degrees"])]
        }

        // A dashed "cut here" line is not part of any label. Taking it out first
        // stops one that runs close to a label from being read as part of it.
        let (cleaned, linesAcross, linesDown) = withoutCutLines(image, below: inkLevel)
        let cutLines = linesAcross.count + linesDown.count
        if cutLines > 0 {
            image = cleaned
            map = InkMap(image, below: inkLevel)
            guard let rest = map.tight(page) else { return blank }
            all = rest
            notes.append(cutLines == 1 ? "cut line left out" : "\(cutLines) cut lines left out")
        }

        func fits(_ w: Int, _ h: Int, slack: Double) -> Bool {
            Double(w) <= Double(labelW) * slack && Double(h) <= Double(labelH) * slack
        }
        func fitsEitherWay(_ b: Box) -> Bool { fits(b.w, b.h, slack: 1.01) || fits(b.h, b.w, slack: 1.01) }
        func labelShaped(_ b: Box) -> Bool {
            let ratio = Double(b.w) / Double(b.h), label = Double(labelW) / Double(labelH)
            return abs(ratio / label - 1) <= shapeTolerance || abs(ratio * label - 1) <= shapeTolerance
        }

        /// Crops `b` out of `source` and fits it on the label: exact size when it fits, else shrunk.
        func label(from b: Box, _ why: String, in source: GrayImage? = nil) -> Result {
            var art = (source ?? image).cropped(x: b.x, y: b.y, width: b.w, height: b.h)
            var notes = notes + ["\(why): \(b.w)x\(b.h) at (\(b.x),\(b.y)) on a \(image.width)x\(image.height) page"]
            let (roomW, roomH) = (labelW - 2 * shrinkMargin, labelH - 2 * shrinkMargin)
            func scale(_ w: Int, _ h: Int) -> Double {
                min(1, min(Double(roomW) / Double(w), Double(roomH) / Double(h)))
            }
            let turn = { art = art.rotated(clockwise: config.rotateClockwise); notes.append("turned 90 degrees") }
            if fits(art.width, art.height, slack: 1) {
                notes.append("exact size")
            } else if fits(art.height, art.width, slack: 1) {
                turn()
                notes.append("exact size")
            } else if fits(art.width, art.height, slack: 1.01) {
                notes.append("exact size, overhang trimmed")
            } else if fits(art.height, art.width, slack: 1.01) {
                turn()
                notes.append("exact size, overhang trimmed")
            } else {
                if scale(art.height, art.width) > scale(art.width, art.height) { turn() }
                let s = scale(art.width, art.height)
                let nw = max(1, min(roomW, Int((Double(art.width) * s).rounded())))
                let nh = max(1, min(roomH, Int((Double(art.height) * s).rounded())))
                art = art.resized(toWidth: nw, height: nh)
                notes.append("shrunk to \(Int((s * 100).rounded()))% (\(nw)x\(nh))")
            }
            // Centre. A negative offset trims the overhang equally on both sides.
            return finish(art.placed(onWidth: labelW, height: labelH, x: (labelW - art.width) / 2, y: (labelH - art.height) / 2), notes)
        }

        /// What is left of the page once the `taken` boxes are cut out, as one more label.
        func rest(without taken: [Box]) -> [Result] {
            var left = image
            func blank(_ b: Box) {
                for y in max(0, b.y - 2) ..< min(left.height, b.y + b.h + 2) {
                    for x in max(0, b.x - 2) ..< min(left.width, b.x + b.w + 2) { left[x, y] = 255 }
                }
            }
            taken.forEach(blank)
            // Cut lines: thin, and at least half the page long.
            let whole = Box(x: 0, y: 0, w: left.width, h: left.height)
            for rows in [true, false] {
                for line in InkMap(left, below: inkLevel).stretches(whole, rows: rows, minGap: 6) {
                    let (thin, long, span) = rows ? (line.h, line.w, left.width) : (line.w, line.h, left.height)
                    if thin <= 6 && long * 2 >= span { blank(line) }
                }
            }
            // A header or footer line alone is not worth a label: ask for half an inch of inked rows.
            let remains = InkMap(left, below: inkLevel)
            guard let box = remains.tight(whole),
                  remains.profile(whole, rows: true).filter({ $0 }).count >= 100 else { return [] }
            return [label(from: box, "rest of the page", in: left)]
        }

        /// Fits `b` to the label's width and, if it is then longer than a label,
        /// carries on onto further labels. Each break is made at the widest blank
        /// band in the lower half of the label, so that nothing is cut through.
        func fullWidth(from b: Box, _ why: String) -> [Result] {
            if fitsEitherWay(b) { return [label(from: b, why)] }
            let (roomW, roomH) = (labelW - 2 * shrinkMargin, labelH - 2 * shrinkMargin)
            let s = min(1, Double(roomW) / Double(b.w))
            let nw = max(1, min(roomW, Int((Double(b.w) * s).rounded())))
            let nh = max(1, Int((Double(b.h) * s).rounded()))
            if nh <= roomH { return [label(from: b, why)] }
            let art = image.cropped(x: b.x, y: b.y, width: b.w, height: b.h).resized(toWidth: nw, height: nh)
            let inked = InkMap(art, below: inkLevel).profile(Box(x: 0, y: 0, w: nw, h: nh), rows: true)

            var parts = [(from: Int, to: Int)]()
            var pos = 0
            while pos < nh {
                while pos < nh && !inked[pos] { pos += 1 }          // skip blank rows at the top of a part
                if pos >= nh { break }
                var cut = min(nh, pos + roomH)
                if cut < nh {
                    // Widest blank band (8 rows or more) that reaches into the lower half of this label.
                    var widest = (from: 0, length: 0)
                    var r = pos + roomH / 2
                    while r < cut {
                        if inked[r] { r += 1; continue }
                        var start = r
                        while start > pos && !inked[start - 1] { start -= 1 }
                        var end = r
                        while end < nh && !inked[end] { end += 1 }
                        if end - start >= 8 && end - start >= widest.length { widest = (start, end - start) }
                        r = end
                    }
                    if widest.length > 0 { cut = min(cut, widest.from + widest.length / 2) }
                }
                parts.append((pos, cut))
                pos = cut
            }
            let scaled = "\(why): \(b.w)x\(b.h) at (\(b.x),\(b.y)) on a \(image.width)x\(image.height) page; "
                + (s < 1 ? "fitted to the label's width at \(Int((s * 100).rounded()))%" : "exact size")
            return parts.enumerated().map { i, part in
                let piece = art.cropped(x: 0, y: part.from, width: nw, height: part.to - part.from)
                let placed = piece.placed(onWidth: labelW, height: labelH, x: (labelW - nw) / 2, y: shrinkMargin)
                return finish(placed, notes + [scaled + (parts.count > 1 ? "; part \(i + 1) of \(parts.count)" : "")])
            }
        }

        // 0. A dashed cut-out box marks the label: what is inside it is the label,
        //    at the label's full width, and what is outside it is the rest of the page.
        if let box = LabelLayout.cutBox(across: linesAcross, down: linesDown), let inside = map.tight(box) {
            return fullWidth(from: inside, "label in a cut-out box") + (includeRest ? rest(without: [box]) : [])
        }

        // 1. Everything on the page fits on the label. 2. Everything is one enlarged label.
        if fitsEitherWay(all) { return [label(from: all, "auto-crop")] }
        if labelShaped(all) { return [label(from: all, "auto-crop, enlarged label")] }

        // 3. Blocks that are a label at exact size. Larger ones win; ones inside or across them are dropped.
        let blocks = map.blocks(in: all, rows: true)
        var found = [Box]()
        for b in blocks.filter({ fitsEitherWay($0) && $0.area * 2 >= labelW * labelH }).sorted(by: { $0.area > $1.area })
        where !found.contains(where: { $0.overlaps(b) }) {
            found.append(b)
        }
        if !found.isEmpty {
            found.sort { ($0.y, $0.x) < ($1.y, $1.x) }
            let why = found.count == 1 ? "label found on the page" : "one of \(found.count) labels found on the page"
            return found.map { label(from: $0, why) } + (includeRest ? rest(without: found) : [])
        }

        // 4. The largest label-shaped block, if it is a good part of the page; else the whole page.
        if let b = blocks.filter({ labelShaped($0) && $0.area * 3 >= all.area }).max(by: { $0.area < $1.area }) {
            return [label(from: b, "enlarged label found on the page")] + (includeRest ? rest(without: [b]) : [])
        }
        return [label(from: all, "auto-crop")]
    }

    /// Blanks dashed "cut here" lines that run across or down the page, with
    /// any small mark sitting on them such as a scissors symbol. Returns the
    /// cleaned image and the number of lines taken out.
    static func withoutCutLines(_ image: GrayImage, below level: UInt8) -> (GrayImage, across: [Box], down: [Box]) {
        var out = image
        let across = blankDashedRows(&out, below: level)
        // Lines running down the page: the same search on the page turned sideways.
        var turned = out.rotated(clockwise: true)
        let sideways = blankDashedRows(&turned, below: level)
        if !sideways.isEmpty { out = turned.rotated(clockwise: false) }
        // Turned clockwise, page dot (x, y) sits at (height - 1 - y, x).
        let down = sideways.map { Box(x: $0.y, y: image.height - $0.x - $0.w, w: $0.h, h: $0.w) }
        return (out, across, down)
    }

    /// The inside of a dashed cut-out box. Two cut lines down the page joined at
    /// their ends by at least one across it make a box, and so do two across
    /// joined by at least one down. A side may be missing: a page printed on
    /// shorter paper loses its bottom edge, and the box's bottom side with it.
    /// The largest box wins.
    static func cutBox(across: [Box], down: [Box]) -> Box? {
        let slack = 40      // 5 mm: the corner dashes belong to one line or the other
        func close(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= slack }
        var best: Box?
        func offer(_ b: Box) {
            if b.w >= 300 && b.h >= 300 && b.area > (best?.area ?? 0) { best = b }
        }
        // Left and right sides, with a top, a bottom or both.
        for left in down {
            for right in down where right.x > left.x + left.w {
                guard close(left.y, right.y), close(left.y + left.h, right.y + right.h) else { continue }
                func spans(_ line: Box) -> Bool { close(line.x, left.x) && close(line.x + line.w, right.x + right.w) }
                let top = across.first { spans($0) && close($0.y, min(left.y, right.y)) }
                let bottom = across.first { spans($0) && close($0.y + $0.h, max(left.y + left.h, right.y + right.h)) }
                guard top != nil || bottom != nil else { continue }
                let y0 = top.map { $0.y + $0.h } ?? min(left.y, right.y)
                let y1 = bottom.map { $0.y } ?? max(left.y + left.h, right.y + right.h)
                offer(Box(x: left.x + left.w, y: y0, w: right.x - left.x - left.w, h: y1 - y0))
            }
        }
        // Top and bottom sides, with a left, a right or both.
        for top in across {
            for bottom in across where bottom.y > top.y + top.h {
                guard close(top.x, bottom.x), close(top.x + top.w, bottom.x + bottom.w) else { continue }
                func spans(_ line: Box) -> Bool { close(line.y, top.y) && close(line.y + line.h, bottom.y + bottom.h) }
                let left = down.first { spans($0) && close($0.x, min(top.x, bottom.x)) }
                let right = down.first { spans($0) && close($0.x + $0.w, max(top.x + top.w, bottom.x + bottom.w)) }
                guard left != nil || right != nil else { continue }
                let x0 = left.map { $0.x + $0.w } ?? min(top.x, bottom.x)
                let x1 = right.map { $0.x } ?? max(top.x + top.w, bottom.x + bottom.w)
                offer(Box(x: x0, y: top.y + top.h, w: x1 - x0, h: bottom.y - top.y - top.h))
            }
        }
        return best
    }

    /// A row is part of a dashed line when it is made of at least 8 dashes of
    /// equal length at equal spacing that together span half the page or more.
    /// Up to 10 such rows in a row, with next to nothing just above and below
    /// them, make a cut line.
    private static func blankDashedRows(_ img: inout GrayImage, below level: UInt8) -> [Box] {
        let (w, h) = (img.width, img.height)
        var span = [(x0: Int, x1: Int)?](repeating: nil, count: h)
        for y in 0 ..< h {
            var runs = [(start: Int, length: Int)]()
            var x = 0
            while x < w {
                if img.pixels[y * w + x] < level {
                    let s = x
                    while x < w && img.pixels[y * w + x] < level { x += 1 }
                    runs.append((s, x - s))
                } else {
                    x += 1
                }
            }
            guard runs.count >= 8 else { continue }
            let gaps = (1 ..< runs.count).map { runs[$0].start - runs[$0 - 1].start - runs[$0 - 1].length }
            let gap = gaps.sorted()[gaps.count / 2]
            guard gap >= 2 else { continue }
            // Stretches of evenly spaced runs. The line is the longest one, joined with
            // any neighbour of 3 dashes or more that lies within 1.5 cm of it: a scissors
            // mark sitting on the line breaks it in two. Other ink in the same row, such
            // as a letter of a heading, is left out.
            var stretches = [(from: Int, to: Int)]()
            var start = 0
            for i in 1 ... runs.count where i == runs.count || abs(gaps[i - 1] - gap) > 3 {
                stretches.append((start, i - 1))
                start = i
            }
            guard var k = stretches.indices.max(by: { stretches[$0].to - stretches[$0].from < stretches[$1].to - stretches[$1].from })
            else { continue }
            var (from, to) = stretches[k]
            guard to - from + 1 >= 8 else { continue }
            func near(_ a: Int, _ b: Int) -> Bool {      // run a ends within 1.5 cm of where run b starts
                runs[b].start - runs[a].start - runs[a].length <= 120
            }
            let main = k
            while k > 0, stretches[k - 1].to - stretches[k - 1].from >= 2, near(stretches[k - 1].to, from) {
                k -= 1
                from = stretches[k].from
            }
            k = main
            while k + 1 < stretches.count, stretches[k + 1].to - stretches[k + 1].from >= 2, near(to, stretches[k + 1].from) {
                k += 1
                to = stretches[k].to
            }
            let (x0, x1) = (runs[from].start, runs[to].start + runs[to].length - 1)
            guard (x1 - x0 + 1) * 2 >= w else { continue }
            let (mainFrom, mainTo) = stretches[main]
            let lengths = runs[mainFrom ... mainTo].map { $0.length }.sorted()
            let dash = lengths[lengths.count / 2]
            guard dash <= 60, lengths.filter({ abs($0 - dash) <= 2 }).count * 5 >= lengths.count * 4 else { continue }
            span[y] = (x0, x1)
        }

        var removed = [Box]()
        var y = 0
        while y < h {
            guard let top = span[y] else { y += 1; continue }
            var y1 = y
            var (x0, x1) = (top.x0, top.x1)
            while y1 + 1 < h, let next = span[y1 + 1] {
                x0 = min(x0, next.x0); x1 = max(x1, next.x1); y1 += 1
            }
            let y0 = y
            y = y1 + 1
            guard y1 - y0 + 1 <= 10 else { continue }
            func ink(inRow r: Int) -> Int {
                guard r >= 0 && r < h else { return 0 }
                var n = 0
                for x in x0 ... x1 where img.pixels[r * w + x] < level { n += 1 }
                return n
            }
            let quiet = (x1 - x0 + 1) / 20
            guard (1 ... 3).allSatisfy({ ink(inRow: y0 - $0) <= quiet && ink(inRow: y1 + $0) <= quiet }) else { continue }
            for yy in y0 ... y1 { for x in x0 ... x1 { img.pixels[yy * w + x] = 255 } }
            // Small marks sitting on the line, such as a scissors symbol.
            for r in [y0 - 3, y0 - 2, y0 - 1, y1 + 1, y1 + 2, y1 + 3] where r >= 0 && r < h {
                // A mark at the end of the line can sit just outside the run of dashes: look 1 cm further.
                for x in max(0, x0 - 80) ... min(w - 1, x1 + 80) where img.pixels[r * w + x] < level {
                    eraseSmallMark(&img, x, r, below: level)
                }
            }
            removed.append(Box(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1))
        }
        return removed
    }

    /// Blanks the connected patch of ink at (`x`, `y`) if it is no larger than about 1 cm.
    private static func eraseSmallMark(_ img: inout GrayImage, _ x: Int, _ y: Int, below level: UInt8) {
        let (w, h) = (img.width, img.height)
        var seen: Set<Int> = [y * w + x]
        var stack = [y * w + x]
        var (minX, maxX, minY, maxY) = (x, x, y, y)
        while let at = stack.popLast() {
            let (cx, cy) = (at % w, at / w)
            minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
            if maxX - minX > 90 || maxY - minY > 90 || seen.count > 4000 { return }    // too big to be a mark
            for ny in max(0, cy - 1) ... min(h - 1, cy + 1) {
                for nx in max(0, cx - 1) ... min(w - 1, cx + 1) where img.pixels[ny * w + nx] < level {
                    if seen.insert(ny * w + nx).inserted { stack.append(ny * w + nx) }
                }
            }
        }
        for at in seen { img.pixels[at] = 255 }
    }

    /// Black where the grey value is below `level`.
    public static func thresholded(_ image: GrayImage, level: UInt8) -> MonoBitmap {
        var out = MonoBitmap(width: image.width, height: image.height)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width where image.pixels[y * image.width + x] < level { out.set(x, y) }
        }
        return out
    }

    /// Floyd-Steinberg error diffusion.
    public static func dithered(_ image: GrayImage) -> MonoBitmap {
        let (w, h) = (image.width, image.height)
        var out = MonoBitmap(width: w, height: h)
        var current = [Int](repeating: 0, count: w + 2)   // error carried into this row, offset by 1
        var next = [Int](repeating: 0, count: w + 2)
        for y in 0 ..< h {
            for i in 0 ..< w + 2 { next[i] = 0 }
            for x in 0 ..< w {
                // Values are kept in sixteenths to avoid rounding drift.
                let value = Int(image.pixels[y * w + x]) * 16 + current[x + 1]
                let white = value >= 128 * 16
                if !white { out.set(x, y) }
                let error = value - (white ? 255 * 16 : 0)
                current[x + 2] += error * 7 / 16
                next[x] += error * 3 / 16
                next[x + 1] += error * 5 / 16
                next[x + 2] += error * 1 / 16
            }
            swap(&current, &next)
        }
        return out
    }
}
