// Checks for the raster decoders, page layout, PNG writer, config file,
// IPP codec, IPP printer and the HTTP listener. Nothing here needs a printer.

import D450Core
import Foundation
#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
import Darwin
private let streamSocket = SOCK_STREAM
#endif

// MARK: Test helpers

/// Collects labels in memory instead of printing them.
final class MemorySink: LabelSink {
    struct Label { let jobId: Int; let label: Int; let canvas: MonoBitmap; let job: [UInt8] }
    private let lock = NSLock()
    private var stored = [Label]()
    private var documents = 0
    var failNext = false

    func received(jobId: Int, document: [UInt8], format: RasterFormat) {
        lock.lock(); documents += 1; lock.unlock()
    }
    func deliver(jobId: Int, label: Int, copies: Int, canvas: MonoBitmap, speed: [UInt8], job: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; throw SinkError.cannotWrite("test failure") }
        stored.append(Label(jobId: jobId, label: label, canvas: canvas, job: job))
    }
    var labels: [Label] { lock.lock(); defer { lock.unlock() }; return stored }
    var documentCount: Int { lock.lock(); defer { lock.unlock() }; return documents }
}

enum TestRaster { case sgray8, black1, srgb8 }

/// Run-length codes one row the way PWG Raster and URF do. `unit` is the bytes per pixel.
func packRow(_ row: [UInt8], unit: Int, urfWhiteFill: Bool) -> [UInt8] {
    var out = [UInt8]()
    let n = row.count / unit
    func px(_ i: Int) -> ArraySlice<UInt8> { row[i * unit ..< (i + 1) * unit] }
    var end = n
    if urfWhiteFill {       // URF: code 0x80 fills the rest of the row with white
        while end > 0 && px(end - 1).allSatisfy({ $0 == 0xFF }) { end -= 1 }
    }
    var i = 0
    while i < end {
        var run = 1
        while i + run < end && run < 128 && px(i + run) == px(i) { run += 1 }
        if run >= 2 {
            out.append(UInt8(run - 1)); out.append(contentsOf: px(i)); i += run
            continue
        }
        var lit = 1
        while i + lit < end && lit < 128 && !(i + lit + 1 < end && px(i + lit) == px(i + lit + 1)) { lit += 1 }
        if lit == 1 { out.append(0); out.append(contentsOf: px(i)) }
        else { out.append(UInt8(257 - lit)); out.append(contentsOf: row[i * unit ..< (i + lit) * unit]) }
        i += lit
    }
    if end < n { out.append(0x80) }
    return out
}

func rasterRows(_ image: GrayImage, _ kind: TestRaster) -> (rows: [[UInt8]], unit: Int, bitsPerPixel: Int) {
    var rows = [[UInt8]]()
    for y in 0 ..< image.height {
        let g = Array(image.pixels[y * image.width ..< (y + 1) * image.width])
        switch kind {
        case .sgray8: rows.append(g)
        case .srgb8: rows.append(g.flatMap { [$0, $0, $0] })
        case .black1:
            var r = [UInt8](repeating: 0, count: (image.width + 7) / 8)
            for x in 0 ..< image.width where g[x] < 128 { r[x / 8] |= 0x80 >> UInt8(x % 8) }
            rows.append(r)
        }
    }
    switch kind {
    case .sgray8: return (rows, 1, 8)
    case .srgb8: return (rows, 3, 24)
    case .black1: return (rows, 1, 1)
    }
}

func packRows(_ rows: [[UInt8]], unit: Int, urf: Bool) -> [UInt8] {
    var out = [UInt8]()
    var y = 0
    while y < rows.count {
        var same = 1
        while y + same < rows.count && same < 256 && rows[y + same] == rows[y] { same += 1 }
        out.append(UInt8(same - 1))
        out.append(contentsOf: packRow(rows[y], unit: unit, urfWhiteFill: urf))
        y += same
    }
    return out
}

func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

/// A PWG Raster document made from scratch, following PWG 5102.4.
func pwgDocument(_ pages: [GrayImage], _ kind: TestRaster, dpi: Int = 203) -> [UInt8] {
    var out = Array("RaS2".utf8)
    for image in pages {
        let (rows, unit, bpp) = rasterRows(image, kind)
        var h = [UInt8](repeating: 0, count: 1796)
        h.replaceSubrange(0 ..< 9, with: Array("PwgRaster".utf8))
        func put(_ at: Int, _ v: Int) { h.replaceSubrange(at ..< at + 4, with: be32(v)) }
        put(276, dpi); put(280, dpi)
        put(372, image.width); put(376, image.height)
        put(384, kind == .black1 ? 1 : 8)
        put(388, bpp)
        put(392, rows[0].count)
        put(396, 0)
        put(400, kind == .sgray8 ? 18 : kind == .black1 ? 3 : 19)
        out += h
        out += packRows(rows, unit: unit, urf: false)
    }
    return out
}

/// An Apple Raster (URF) document: 8-bit grey.
func urfDocument(_ pages: [GrayImage], dpi: Int = 203) -> [UInt8] {
    var out = Array("UNIRAST".utf8) + [0] + be32(pages.count)
    for image in pages {
        var h = [UInt8](repeating: 0, count: 32)
        h[0] = 8; h[1] = 0; h[2] = 1; h[3] = 4
        h.replaceSubrange(12 ..< 16, with: be32(image.width))
        h.replaceSubrange(16 ..< 20, with: be32(image.height))
        h.replaceSubrange(20 ..< 24, with: be32(dpi))
        out += h
        out += packRows(rasterRows(image, .sgray8).rows, unit: 1, urf: true)
    }
    return out
}

/// White image with a patterned block: border, a few bars, a diagonal and a mark near its top-left corner.
func blockImage(pageWidth: Int, pageHeight: Int, x: Int, y: Int, width w: Int, height h: Int) -> GrayImage {
    var img = GrayImage(width: pageWidth, height: pageHeight)
    func fill(_ fx: Int, _ fy: Int, _ fw: Int, _ fh: Int) {
        for yy in max(0, fy) ..< min(pageHeight, fy + fh) { for xx in max(0, fx) ..< min(pageWidth, fx + fw) { img[xx, yy] = 0 } }
    }
    fill(x, y, w, 3); fill(x, y + h - 3, w, 3); fill(x, y, 3, h); fill(x + w - 3, y, 3, h)
    fill(x + 10, y + 10, 40, 20)                               // mark near the top-left corner
    for k in 0 ..< min(w, h) / 3 { fill(x + w / 4 + k, y + h / 4 + k, 2, 2) }
    for k in 0 ..< 12 { fill(x + 20 + k * 9, y + h / 2, 1 + k % 3, h / 6) }
    return img
}

/// Number of cut lines the layout reports leaving out of a page.
func pr0(_ image: GrayImage) -> Int {
    let note = LabelLayout.layout(RasterPage(image: image, dpiX: 203, dpiY: 203, source: "test"), config: ServiceConfig())?.note ?? ""
    if note.contains("cut lines left out") { return 2 }
    return note.contains("cut line left out") ? 1 : 0
}

func ippRequest(_ op: UInt16, id: Int32 = 1, _ extra: [IppAttribute] = [], job: [IppAttribute] = [],
                data: [UInt8] = []) -> [UInt8] {
    var groups = [IppGroup(tag: IppGroup.operation, [
        IppAttribute("attributes-charset", .charset("utf-8")),
        IppAttribute("attributes-natural-language", .language("en")),
        IppAttribute("printer-uri", .uri("ipp://localhost:8631/ipp/print")),
    ] + extra)]
    if !job.isEmpty { groups.append(IppGroup(tag: IppGroup.job, job)) }
    var m = IppMessage(code: op, requestId: id, groups: groups)
    m.versionMajor = 2; m.versionMinor = 0
    return m.encoded() + data
}

func ippReply(_ printer: IppPrinter, _ request: [UInt8]) -> IppMessage {
    guard let bytes = printer.handle(request), let parsed = try? IppMessage.parse(bytes) else {
        check(false, "no IPP reply")
        return IppMessage(code: 0xFFFF, requestId: 0, groups: [])
    }
    check(parsed.dataOffset == bytes.count, "reply has bytes after the end tag")
    return parsed.message
}

/// Polls Get-Job-Attributes until the job reaches a final state.
func waitForJob(_ printer: IppPrinter, _ id: Int) -> IppMessage {
    var last = IppMessage(code: 0xFFFF, requestId: 0, groups: [])
    for _ in 0 ..< 600 {
        // Parsed directly so the number of checks does not depend on how long the job takes.
        guard let bytes = printer.handle(ippRequest(0x0009, [IppAttribute("job-id", .integer(Int32(id)))])),
              let parsed = try? IppMessage.parse(bytes) else { break }
        last = parsed.message
        if let s = last.attribute("job-state", in: IppGroup.job)?.values.first?.intValue, s >= 7 { return last }
        usleep(20_000)
    }
    check(false, "job \(id) did not finish")
    return last
}

func jobState(_ m: IppMessage) -> Int { m.attribute("job-state", in: IppGroup.job)?.values.first?.intValue ?? -1 }
func jobId(_ m: IppMessage) -> Int { m.attribute("job-id", in: IppGroup.job)?.values.first?.intValue ?? -1 }

// MARK: Tests

func runStep3Tests() {
    var rng = SplitMix64(state: 4506)

    // ---- Raster decoding --------------------------------------------------
    var noisy = blockImage(pageWidth: 300, pageHeight: 180, x: 20, y: 15, width: 200, height: 120)
    for y in 100 ..< 170 { for x in 230 ..< 295 { noisy[x, y] = UInt8(rng.below(256)) } }   // literal runs
    let crisp = GrayImage(width: noisy.width, height: noisy.height, pixels: noisy.pixels.map { $0 < 128 ? 0 : 255 })
    for (kind, name, source) in [(TestRaster.sgray8, "sgray_8", noisy), (.black1, "black_1", crisp), (.srgb8, "srgb_8", noisy)] {
        do {
            var got = [RasterPage]()
            let n = try RasterDocument.forEachPage(pwgDocument([source, crisp], kind)) { got.append($0); return true }
            check(n == 2 && got.count == 2, "PWG \(name): two pages")
            check(got.first?.image == source, "PWG \(name): page 1 decodes to the source image")
            check(got.last?.image == crisp, "PWG \(name): page 2 decodes to the source image")
            check(got.first?.dpiX == 203 && got.first?.dpiY == 203, "PWG \(name): resolution")
        } catch { check(false, "PWG \(name) threw \(error)") }
    }
    do {
        var got = [RasterPage]()
        try RasterDocument.forEachPage(urfDocument([noisy, crisp])) { got.append($0); return true }
        check(got.count == 2 && got[0].image == noisy && got[1].image == crisp, "URF: both pages decode to the source")
        var first = 0
        try RasterDocument.forEachPage(urfDocument([noisy, crisp])) { _ in first += 1; return false }
        check(first == 1, "returning false stops after one page")
    } catch { check(false, "URF threw \(error)") }
    check(RasterDocument.format(of: Array("RaS2".utf8)) == .pwg && RasterDocument.format(of: Array("UNIRAST".utf8) + [0, 0]) == .urf
          && RasterDocument.format(of: Array("%PDF-1.4".utf8)) == nil, "format detection")
    do { try RasterDocument.forEachPage(Array("%PDF-1.4 not a raster".utf8)) { _ in true }; check(false, "PDF accepted as raster") }
    catch { check(error as? RasterError == .unknownFormat, "unknown format error") }
    // Cut-off and corrupted documents must throw or decode, never crash.
    let goodPwg = pwgDocument([noisy], .sgray8)
    for cut in stride(from: 0, to: goodPwg.count, by: 97) {
        do { try RasterDocument.forEachPage(Array(goodPwg.prefix(cut))) { _ in true }; check(false, "truncated PWG (\(cut)) decoded") }
        catch { checks += 1 }
    }
    for _ in 0 ..< 3000 {
        var bad = rng.below(2) == 0 ? goodPwg : urfDocument([noisy])
        for _ in 0 ... rng.below(4) { bad[rng.below(bad.count)] = UInt8(rng.below(256)) }
        _ = try? RasterDocument.forEachPage(bad) { _ in true }
    }
    checks += 1
    var huge = goodPwg
    huge.replaceSubrange(4 + 376 ..< 4 + 380, with: be32(2_000_000_000))
    do { try RasterDocument.forEachPage(huge) { _ in true }; check(false, "absurd page height accepted") }
    catch { check(error as? RasterError == .unsupported("page size 300x2000000000"), "absurd page size is refused, got \(error)") }

    // ---- Image operations --------------------------------------------------
    let two = GrayImage(width: 2, height: 2, pixels: [0, 255, 255, 0])
    check(two.resized(toWidth: 1, height: 1).pixels == [128], "2x2 averages to one mid-grey pixel")
    check(GrayImage(width: 7, height: 5, pixels: [UInt8](repeating: 40, count: 35)).resized(toWidth: 3, height: 2).pixels
          == [UInt8](repeating: 40, count: 6), "a flat image stays flat when shrunk")
    let ramp = GrayImage(width: 4, height: 1, pixels: [0, 100, 200, 250])
    check(ramp.resized(toWidth: 2, height: 1).pixels == [50, 225], "pairs of pixels average")
    let small = GrayImage(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])
    check(small.rotated(clockwise: true).pixels == [4, 1, 5, 2, 6, 3], "clockwise quarter turn")
    check(small.rotated(clockwise: false).pixels == [3, 6, 2, 5, 1, 4], "counter-clockwise quarter turn")
    check(small.rotated(clockwise: true).rotated(clockwise: false) == small, "turning back restores the image")
    check(small.placed(onWidth: 2, height: 2, x: -1, y: 0).pixels == [2, 3, 5, 6], "placing with a negative offset trims")
    check(small.placed(onWidth: 4, height: 3, x: 1, y: 1).pixels == [255, 255, 255, 255, 255, 1, 2, 3, 255, 4, 5, 6], "placing with a positive offset pads")
    let b = noisy.inkBounds(below: 128)
    check(b?.x == 20 && b?.y == 15, "ink bounds start at the block")
    check(GrayImage(width: 5, height: 5).inkBounds(below: 128) == nil, "no ink on a white image")

    // ---- Page layout --------------------------------------------------------
    var cfg = ServiceConfig()
    func page(_ image: GrayImage, dpi: Int = 203) -> RasterPage { RasterPage(image: image, dpiX: dpi, dpiY: dpi, source: "test") }
    func bw(_ image: GrayImage) -> MonoBitmap { LabelLayout.thresholded(image, level: 128) }

    // A label-size page prints as it is.
    let exact = blockImage(pageWidth: 812, pageHeight: 1218, x: 0, y: 0, width: 812, height: 1218)
    let r1 = LabelLayout.layout(page(exact), config: cfg)
    check(r1?.page == bw(exact), "4x6 page: printed dot for dot")
    check(r1?.note.contains("as is") == true, "4x6 page: note")
    // One dot off in size still counts as a label-size page.
    let near = blockImage(pageWidth: 813, pageHeight: 1217, x: 0, y: 0, width: 812, height: 1217)
    check(LabelLayout.layout(page(near), config: cfg)?.page == bw(near.placed(onWidth: 812, height: 1218, x: 0, y: 0)), "813x1217 page treated as label size")

    // A 6x4 landscape page is turned.
    let wide = blockImage(pageWidth: 1218, pageHeight: 812, x: 0, y: 0, width: 1218, height: 812)
    let r2 = LabelLayout.layout(page(wide), config: cfg)
    check(r2?.page == bw(wide.rotated(clockwise: true)), "6x4 page: turned clockwise")
    check(r2?.page.isBlack(812 - 1 - 20, 30) == true && r2?.page.isBlack(30, 30) == false, "6x4 page: top-left mark ends up top-right")
    cfg.rotateClockwise = false
    check(LabelLayout.layout(page(wide), config: cfg)?.page == bw(wide.rotated(clockwise: false)), "6x4 page: counter-clockwise when configured")
    cfg.rotateClockwise = true

    // Letter page with a 3.98 x 5.8 in label at the top-left: cropped and centred, not resampled.
    let letter = blockImage(pageWidth: 1726, pageHeight: 2233, x: 40, y: 50, width: 808, height: 1177)
    let art = letter.cropped(x: 40, y: 50, width: 808, height: 1177)
    let r3 = LabelLayout.layout(page(letter), config: cfg)
    check(r3?.page == bw(art.placed(onWidth: 812, height: 1218, x: 2, y: 20)), "label on Letter: exact size, centred")
    check(r3?.note.contains("exact size") == true && r3?.note.contains("shrunk") == false, "label on Letter: note says exact size")
    // The same on A4.
    let a4 = blockImage(pageWidth: 1678, pageHeight: 2374, x: 300, y: 700, width: 808, height: 1177)
    check(LabelLayout.layout(page(a4), config: cfg)?.page == r3?.page, "label on A4: same result wherever it sits on the page")

    // Within 1% of fitting: exact size, overhang trimmed equally.
    let over = blockImage(pageWidth: 1726, pageHeight: 2233, x: 100, y: 100, width: 818, height: 1225)
    let r4 = LabelLayout.layout(page(over), config: cfg)
    check(r4?.page == bw(over.cropped(x: 100, y: 100, width: 818, height: 1225).placed(onWidth: 812, height: 1218, x: -3, y: -3)),
          "1% oversize: kept at exact size and trimmed")
    check(r4?.note.contains("overhang trimmed") == true, "1% oversize: note")

    // Too big: shrunk to fit, keeping its shape.
    let big = blockImage(pageWidth: 1726, pageHeight: 2233, x: 60, y: 100, width: 1600, height: 2000)
    let r5 = LabelLayout.layout(page(big), config: cfg)
    check(r5?.note.contains("shrunk to 49% (788x985)") == true, "full page: shrunk to 788x985, inside the margin, got \(r5?.note ?? "nil")")
    if let p = r5?.page {
        var top = 0, bottom = 1217
        while top < 1218 && !p.isBlack(406, top) { top += 1 }
        while bottom > 0 && !p.isBlack(406, bottom) { bottom -= 1 }
        check(abs(top - 116) <= 1 && abs(bottom - 1101) <= 1, "full page: centred top to bottom (rows \(top) to \(bottom))")
        check((p.isBlack(12, 600) || p.isBlack(13, 600)) && !p.isBlack(10, 600), "full page: starts at the left margin")
        check((p.isBlack(799, 600) || p.isBlack(798, 600)) && !p.isBlack(801, 600), "full page: ends at the right margin")
    }

    // A landscape label on Letter is turned and kept at exact size.
    let lying = blockImage(pageWidth: 2233, pageHeight: 1726, x: 30, y: 30, width: 1177, height: 808)
    let r6 = LabelLayout.layout(page(lying), config: cfg)
    check(r6?.page == bw(lying.cropped(x: 30, y: 30, width: 1177, height: 808).rotated(clockwise: true)
        .placed(onWidth: 812, height: 1218, x: 2, y: 20)), "landscape label on Letter: turned, exact size")
    // Wide artwork that must shrink is turned first when that prints larger.
    let banner = blockImage(pageWidth: 2233, pageHeight: 1726, x: 100, y: 100, width: 2000, height: 1000)
    check(LabelLayout.layout(page(banner), config: cfg)?.note.contains("turned 90 degrees; shrunk to 60% (597x1194)") == true,
          "wide artwork: turned then shrunk, got \(LabelLayout.layout(page(banner), config: cfg)?.note ?? "nil")")

    // ---- Finding the label on a page that holds other things too ---------------
    func paste(_ art: GrayImage, onto page: inout GrayImage, x: Int, y: Int) {
        for yy in 0 ..< art.height { for xx in 0 ..< art.width where art[xx, yy] < 128 { page[x + xx, y + yy] = 0 } }
    }
    func textBlock(on page: inout GrayImage, x: Int, y: Int, width: Int, lines: Int) {
        for l in 0 ..< lines { for xx in stride(from: x, to: x + width - (l * 37) % 90, by: 2) { for yy in 0 ..< 9 { page[xx, y + l * 22 + yy] = 0 } } }
    }
    // A sideways 6x4 label at exact size at the top, a dashed cut line, instructions below.
    let sideways = blockImage(pageWidth: 1217, pageHeight: 813, x: 0, y: 0, width: 1217, height: 813)
    var mixed = GrayImage(width: 1726, height: 2233)
    paste(sideways, onto: &mixed, x: 255, y: 152)
    for xx in stride(from: 43, to: 1683, by: 30) { for k in 0 ..< 18 { mixed[xx + k, 1116] = 0; mixed[xx + k, 1117] = 0 } }
    textBlock(on: &mixed, x: 117, y: 1243, width: 700, lines: 30)
    textBlock(on: &mixed, x: 900, y: 1300, width: 700, lines: 12)
    let m = LabelLayout.layoutAll(page(mixed), config: cfg)
    check(m.count == 1, "label plus instructions: one label found, got \(m.count)")
    check(m.first?.page == bw(sideways.rotated(clockwise: true).placed(onWidth: 812, height: 1218, x: 0, y: 0)),
          "label plus instructions: the label alone, turned, at exact size")
    check(m.first?.note.contains("label found on the page: 1217x813 at (255,152)") == true && m.first?.note.contains("shrunk") == false,
          "label plus instructions: note, got \(m.first?.note ?? "nil")")
    // Asked for everything, the instructions follow as a second label and the cut line is left out.
    let mr = LabelLayout.layoutAll(page(mixed), config: cfg, includeRest: true)
    check(mr.count == 2 && mr.first?.page == m.first?.page, "label plus instructions, everything: the label first, unchanged")
    check(mr.last?.note.contains("rest of the page: 1482x647 at (117,1243)") == true && mr.last?.note.contains("turned 90 degrees; shrunk to 81%") == true,
          "label plus instructions, everything: the rest shrunk onto a second label, got \(mr.last?.note ?? "nil")")
    var restOnly = GrayImage(width: 1726, height: 2233)
    textBlock(on: &restOnly, x: 117, y: 1243, width: 700, lines: 30)
    textBlock(on: &restOnly, x: 900, y: 1300, width: 700, lines: 12)
    check(mr.last?.page == LabelLayout.layout(page(restOnly), config: cfg)?.page, "the rest is exactly the page without its label and cut line")
    check(LabelLayout.layoutAll(page(letter), config: cfg, includeRest: true).count == 1, "a page that is only a label has no rest")
    // A dashed cut line with a scissors mark 2 mm under the label is not taken for part of it.
    var snug = GrayImage(width: 1679, height: 2374)
    paste(sideways, onto: &snug, x: 404, y: 56)
    for xx in stride(from: 56, to: 1622, by: 13) { for k in 0 ..< 8 { for yy in 887 ..< 893 { snug[xx + k, yy] = 0 } } }
    for k in 0 ..< 20 { for t in 0 ..< 4 { snug[160 + k + t, 870 + k] = 0; snug[160 + k + t, 910 - k] = 0 } }   // scissors-like cross
    let sn = LabelLayout.layoutAll(page(snug), config: cfg, includeRest: true)
    check(sn.count == 1 && sn.first?.page == m.first?.page, "label with a cut line close under it: the label alone at exact size, got \(sn.first?.note ?? "nil")")
    check(sn.first?.note.contains("cut line left out") == true, "label with a cut line close under it: note")
    // The same with the cut line running down the page beside the label.
    let down = LabelLayout.layoutAll(page(snug.rotated(clockwise: true)), config: cfg)
    check(down.count == 1 && down.first?.note.contains("cut line left out") == true && down.first?.note.contains("exact size") == true,
          "cut line running down the page: left out, got \(down.first?.note ?? "nil")")
    // Rows of text and a label's own solid rules are not taken for cut lines.
    check(m.first?.note.contains("cut line") == true && pr0(mixed) == 1, "the dashed line between label and instructions counts as one cut line")
    // A dashed cut-out box holding a label longer than 6 in, under a page heading that
    // shares a column with the box's left side. The inside of the box is the label: full
    // width, continued on a second label, broken at the blank band and not through the content.
    var boxed = GrayImage(width: 1679, height: 2374)
    textBlock(on: &boxed, x: 143, y: 90, width: 400, lines: 1)                 // heading
    func dashes(_ img: inout GrayImage, x: Int, y: Int, length: Int, across: Bool) {
        for d in stride(from: 0, to: length, by: 17) { for k in 0 ..< 8 where d + k < length { for t in 0 ..< 3 {
            if across { img[x + d + k, y + t] = 0 } else { img[x + t, y + d + k] = 0 }
        } } }
    }
    dashes(&boxed, x: 287, y: 168, length: 1105, across: true); dashes(&boxed, x: 287, y: 2316, length: 1105, across: true)
    dashes(&boxed, x: 287, y: 168, length: 2151, across: false); dashes(&boxed, x: 1389, y: 168, length: 2151, across: false)
    let upper = blockImage(pageWidth: 1040, pageHeight: 1480, x: 0, y: 0, width: 1040, height: 1480)
    let lower = blockImage(pageWidth: 600, pageHeight: 380, x: 0, y: 0, width: 600, height: 380)
    paste(upper, onto: &boxed, x: 320, y: 230)
    paste(lower, onto: &boxed, x: 540, y: 1820)
    let bx = LabelLayout.layoutAll(page(boxed), config: cfg, includeRest: true)
    check(bx.count == 2, "cut-out box: the label on two labels and no label for the heading, got \(bx.count): \(bx.map { $0.note })")
    check(bx.first?.note.contains("label in a cut-out box: 1040x1970 at (320,230)") == true
          && bx.first?.note.contains("fitted to the label's width at 76%; part 1 of 2") == true, "cut-out box: note, got \(bx.first?.note ?? "nil")")
    if bx.count == 2 {
        func inkRows(_ p: MonoBitmap) -> (first: Int, last: Int, left: Int, right: Int) {
            var (f, l, lx, rx) = (-1, -1, 812, -1)
            for y in 0 ..< p.height { for x in 0 ..< p.width where p.isBlack(x, y) { if f < 0 { f = y }; l = y; lx = min(lx, x); rx = max(rx, x) } }
            return (f, l, lx, rx)
        }
        let (a, b) = (inkRows(bx[0].page), inkRows(bx[1].page))
        check(a.left == 12 && a.right == 799, "cut-out box: part 1 spans the label's width inside the margin (\(a.left)...\(a.right))")
        check(a.first == 12 && abs(a.last - (12 + 1121)) <= 2, "cut-out box: part 1 is the whole upper block (rows \(a.first)...\(a.last))")
        check(b.first == 12 && abs(b.last - (12 + 287)) <= 2, "cut-out box: part 2 is the whole lower block (rows \(b.first)...\(b.last))")
    }
    check(LabelLayout.layoutAll(page(boxed), config: cfg).count == 2, "cut-out box: the same two labels on the label-only queue")
    // The same page printed on shorter paper: its bottom is cut off, and with it the
    // bottom side of the box and the ends of the left and right sides.
    let cutShort = boxed.cropped(x: 0, y: 70, width: 1679, height: 2233)
    let cs = LabelLayout.layoutAll(page(cutShort), config: cfg)
    check(cs.count == 2 && cs.first?.note.contains("3 cut lines left out; label in a cut-out box: 1040x1970 at (320,160)") == true,
          "cut-out box with its bottom side off the page: still the label, got \(cs.map { $0.note })")
    check(cs.first?.page == bx.first?.page && cs.last?.page == bx.last?.page, "cut-out box with its bottom side off the page: the same two labels")
    // Three dashed lines that do not meet are not a box.
    var loose = GrayImage(width: 1679, height: 2374)
    dashes(&loose, x: 287, y: 168, length: 1105, across: true)
    dashes(&loose, x: 100, y: 900, length: 1300, across: false); dashes(&loose, x: 1600, y: 900, length: 1300, across: false)
    paste(art, onto: &loose, x: 430, y: 300)
    check(LabelLayout.layoutAll(page(loose), config: cfg).first?.note.contains("cut-out box") == false, "dashed lines that do not meet are not a box")
    // A cut-out box round a label that fits is printed at exact size, as before.
    var boxedExact = GrayImage(width: 1679, height: 2374)
    dashes(&boxedExact, x: 287, y: 168, length: 1105, across: true); dashes(&boxedExact, x: 287, y: 1500, length: 1105, across: true)
    dashes(&boxedExact, x: 287, y: 168, length: 1335, across: false); dashes(&boxedExact, x: 1389, y: 168, length: 1335, across: false)
    paste(art, onto: &boxedExact, x: 430, y: 240)
    check(LabelLayout.layoutAll(page(boxedExact), config: cfg).first?.page == r3?.page, "cut-out box round a label that fits: exact size")
    // The same with the label upright on the left and a receipt on the right.
    var beside = GrayImage(width: 2233, height: 1726)
    paste(art, onto: &beside, x: 60, y: 200)
    textBlock(on: &beside, x: 1000, y: 220, width: 1100, lines: 45)
    let bs = LabelLayout.layoutAll(page(beside), config: cfg)
    check(bs.count == 1 && bs.first?.page == r3?.page, "label beside a receipt: the label alone at exact size")
    // A true-size label with wide blank bands inside it, close to a footer: still found whole.
    var gappy = GrayImage(width: 808, height: 1177)
    for (gy, gh) in [(0, 300), (380, 250), (700, 120), (900, 277)] {
        paste(blockImage(pageWidth: 808, pageHeight: gh, x: 0, y: 0, width: 808, height: gh), onto: &gappy, x: 0, y: gy)
    }
    var footed = GrayImage(width: 1726, height: 2233)
    paste(gappy, onto: &footed, x: 400, y: 100)
    textBlock(on: &footed, x: 100, y: 1340, width: 1500, lines: 20)
    let ft = LabelLayout.layoutAll(page(footed), config: cfg)
    check(ft.count == 1 && ft.first?.page == bw(gappy.placed(onWidth: 812, height: 1218, x: 2, y: 20)),
          "label with blank bands inside it, footer close below: the whole label, exact size")
    // Two labels close together on one sheet give two labels, left one first.
    var twoUp = GrayImage(width: 2233, height: 1726)
    paste(art, onto: &twoUp, x: 150, y: 250)
    paste(sideways.rotated(clockwise: false), onto: &twoUp, x: 1018, y: 250)
    let tw = LabelLayout.layoutAll(page(twoUp), config: cfg)
    check(tw.count == 2, "two labels on a sheet: two labels, got \(tw.count)")
    check(tw.first?.page == r3?.page && tw.last?.page == bw(sideways.rotated(clockwise: false).placed(onWidth: 812, height: 1218, x: 0, y: 0)),
          "two labels on a sheet: both at exact size, left one first")
    check(tw.first?.note.contains("one of 2 labels") == true, "two labels on a sheet: note")
    // One label drawn larger than life, with blank bands inside it: taken whole and shrunk.
    let enlarged = gappy.resized(toWidth: 1192, height: 1736)
    var bigPage = GrayImage(width: 1726, height: 2233)
    paste(GrayImage(width: 1192, height: 1736, pixels: enlarged.pixels.map { $0 < 128 ? 0 : 255 }), onto: &bigPage, x: 266, y: 205)
    let en = LabelLayout.layoutAll(page(bigPage), config: cfg)
    check(en.count == 1 && en.first?.note.contains("enlarged label") == true && en.first?.note.contains("shrunk to 66%") == true,
          "enlarged label: one label, shrunk to fit, got \(en.first?.note ?? "nil")")
    // An ordinary page of text is not mistaken for labels.
    var prose = GrayImage(width: 1726, height: 2233)
    textBlock(on: &prose, x: 150, y: 150, width: 1400, lines: 25)
    textBlock(on: &prose, x: 150, y: 800, width: 1400, lines: 40)
    let pr = LabelLayout.layoutAll(page(prose), config: cfg)
    check(pr.count == 1 && pr.first?.note.contains("auto-crop") == true && pr.first?.note.contains("shrunk") == true,
          "page of text: one label, the whole page shrunk, got \(pr.first?.note ?? "nil")")
    check(pr0(prose) == 0 && pr0(letter) == 0 && pr0(big) == 0, "text and solid rules are not taken for cut lines")

    // Blank pages.
    let blank = GrayImage(width: 1726, height: 2233)
    check(LabelLayout.layout(page(blank), config: cfg) == nil, "blank page is skipped")
    cfg.skipBlankPages = false
    check(LabelLayout.layout(page(blank), config: cfg)?.page == MonoBitmap(width: 812, height: 1218), "blank page kept when configured")
    cfg.skipBlankPages = true

    // A page at another resolution is brought to 203 dpi first.
    let doubled = exact.resized(toWidth: 1624, height: 2436)
    let r7 = LabelLayout.layout(page(doubled, dpi: 406), config: cfg)
    check(r7?.page == bw(exact), "406 dpi page: resampled to the same label")

    // Threshold and dithering.
    func flat(_ v: UInt8) -> GrayImage { GrayImage(width: 200, height: 200, pixels: [UInt8](repeating: v, count: 40_000)) }
    func blackShare(_ m: MonoBitmap) -> Double {
        var n = 0
        for y in 0 ..< m.height { for x in 0 ..< m.width where m.isBlack(x, y) { n += 1 } }
        return Double(n) / Double(m.width * m.height)
    }
    check(blackShare(LabelLayout.thresholded(flat(127), level: 128)) == 1 && blackShare(LabelLayout.thresholded(flat(128), level: 128)) == 0,
          "threshold: 127 is black, 128 is white")
    check(blackShare(LabelLayout.dithered(flat(0))) == 1 && blackShare(LabelLayout.dithered(flat(255))) == 0, "dither: pure black and white stay pure")
    for (grey, want) in [(UInt8(64), 0.749), (128, 0.498), (191, 0.251)] {
        let share = blackShare(LabelLayout.dithered(flat(grey)))
        check(abs(share - want) < 0.02, "dither: grey \(grey) prints \(Int(share * 100))% black")
    }
    cfg.dither = true
    let pale = GrayImage(width: 812, height: 1218, pixels: [UInt8](repeating: 230, count: 812 * 1218))
    check((LabelLayout.layout(page(pale), config: cfg).map { blackShare($0.page) } ?? 0) > 0.05, "dither: pale grey still prints dots")
    cfg.dither = false
    check(LabelLayout.layout(page(pale), config: cfg) == nil, "threshold: pale grey page counts as blank")

    // ---- PNG ----------------------------------------------------------------
    check(Png.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC-32 check value")
    check(Png.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398, "Adler-32 check value")
    let png = Png.encode(MonoBitmap(width: 864, height: 1218))
    check(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
    check(Array(png[12 ..< 16]) == Array("IHDR".utf8) && Array(png[16 ..< 24]) == be32(864) + be32(1218) && png[24] == 1 && png[25] == 0,
          "PNG header: 864 x 1218, 1 bit, greyscale")
    check(Array(png.suffix(8)) == Array("IEND".utf8) + [0xAE, 0x42, 0x60, 0x82], "PNG end chunk")

    // ---- Dry-run output ------------------------------------------------------
    let tmp = NSTemporaryDirectory() + "d450-selftest-\(UInt32(truncatingIfNeeded: rng.next()))"
    do {
        let dry = try DryRunSink(directory: tmp) { _ in }
        check(dry.highestJobNumber() == 0, "dry run: empty folder has no jobs")
        let canvas = Tspl.canvas(for: bw(exact), config: PrinterConfig())
        let bytes = try Tspl.job(canvas: canvas, config: PrinterConfig())
        try dry.deliver(jobId: 7, label: 2, copies: 1, canvas: canvas, speed: Tspl.speedCommand(PrinterConfig()), job: bytes)
        dry.received(jobId: 7, document: [1, 2, 3], format: .pwg)
        let files = try FileManager.default.contentsOfDirectory(atPath: tmp).sorted()
        check(files == ["job-0007-label-02.png", "job-0007-label-02.tspl", "job-0007-received.pwg"], "dry run: file names, got \(files)")
        let tspl = [UInt8](FileManager.default.contents(atPath: tmp + "/job-0007-label-02.tspl") ?? Data())
        check(tspl == Array("SPEED 1\r\n".utf8) + bytes, "dry run: .tspl holds the SPEED command then the job")
        check([UInt8](FileManager.default.contents(atPath: tmp + "/job-0007-label-02.png") ?? Data()) == Png.encode(canvas), "dry run: PNG of the canvas")
        check(dry.highestJobNumber() == 7, "dry run: next start continues after job 7")
    } catch { check(false, "dry-run sink threw \(error)") }
    try? FileManager.default.removeItem(atPath: tmp)

    // ---- Calibration ruler -----------------------------------------------------
    let ruler = Ruler.page()
    check(ruler.width == 864 && ruler.height == 1218, "ruler covers the full head width and label height")
    var barsOK = true
    for (k, dot) in Ruler.leftMarks().enumerated() {        // each left bar starts exactly at its dot
        let y = 150 + k * 24 + 10
        if !ruler.isBlack(dot, y) || (dot > 0 && ruler.isBlack(dot - 1, y)) { barsOK = false }
    }
    for (k, dot) in Ruler.rightMarks(width: 864).enumerated() {   // each right bar ends exactly at its dot
        let y = 150 + k * 24 + 10
        if !ruler.isBlack(dot, y) || (dot < 863 && ruler.isBlack(dot + 1, y)) { barsOK = false }
    }
    for (k, row) in Ruler.topMarks().enumerated() {         // each top bar starts exactly at its row
        let x = 40 + k * 48 + 15
        if !ruler.isBlack(x, row) || (row > 0 && ruler.isBlack(x, row - 1)) { barsOK = false }
    }
    for (k, row) in Ruler.bottomMarks(height: 1218).enumerated() {   // each bottom bar ends exactly at its row
        let x = 40 + k * 86 + 35
        if !ruler.isBlack(x, row) || (row < 1217 && ruler.isBlack(x, row + 1)) { barsOK = false }
    }
    check(barsOK, "ruler bars start and end exactly at the dots and rows printed beside them")
    check(Ruler.leftMarks().first == 0 && Ruler.rightMarks(width: 864).first == 863 && Ruler.bottomMarks(height: 1218).first == 1217,
          "ruler reaches the first and last head dot and the last row")
    var scaleDots = 0
    for x in 0 ..< 864 where ruler.isBlack(x, 904) { scaleDots += 1 }
    check(scaleDots == 80, "scale bar is 80 dots long")

    // ---- Config file --------------------------------------------------------
    do {
        let c = try ServiceConfig.load(json: Data(#"{"density": 12, "leftDot": 3, "topDot": 4, "dither": true}"#.utf8))
        check(c.density == 12 && c.leftDot == 3 && c.dither && c.speed == 1 && c.port == 8631, "config: given keys override, the rest keep defaults")
        check(c.printer.density == 12 && c.printer.leftDot == 3 && c.printer.topDot == 4, "config: printer settings carried over")
        check(ServiceConfig().printer == PrinterConfig(), "config: defaults agree with the printer defaults")
        check(try ServiceConfig.load(json: Data(ServiceConfig().defaultJSON().utf8)) == ServiceConfig(), "config: default JSON loads back")
    } catch { check(false, "config threw \(error)") }
    for (json, why) in [(#"{"densty": 12}"#, "misspelt key"), (#"{"speed": 9}"#, "speed out of range"),
                        (#"{"leftDot": 53}"#, "leftDot out of range"), (#"{"topDot": 81}"#, "topDot out of range"), (#"{"bluetoothName": ""}"#, "empty Bluetooth name"), (#"[1]"#, "not an object"), (#"{"port": "x"}"#, "wrong type")] {
        check((try? ServiceConfig.load(json: Data(json.utf8))) == nil, "config: \(why) is refused")
    }

    // ---- IPP codec ----------------------------------------------------------
    let everything = IppMessage(code: 0x000B, requestId: 77, groups: [
        IppGroup(tag: IppGroup.operation, [
            IppAttribute("attributes-charset", .charset("utf-8")),
            IppAttribute("requested-attributes", [.keyword("all"), .keyword("media-col-database")]),
        ]),
        IppGroup(tag: IppGroup.printer, [
            IppAttribute("n", .integer(-5)), IppAttribute("b", [.boolean(true), .boolean(false)]),
            IppAttribute("e", .enumeration(9)), IppAttribute("res", .resolution(203, 203, units: 3)),
            IppAttribute("r", .range(1, 99)), IppAttribute("none", .outOfBand(0x13)),
            IppAttribute("raw", .octets(tag: 0x30, [0, 1, 2, 255])), IppAttribute("t", .text("héllo")),
            IppAttribute("col", [
                .collection([IppAttribute("media-size", .collection([IppAttribute("x-dimension", .integer(10160)),
                                                                     IppAttribute("y-dimension", .integer(15240))])),
                             IppAttribute("kw", [.keyword("a"), .keyword("b")])]),
                .collection([IppAttribute("empty", .collection([]))]),
            ]),
        ]),
    ])
    do {
        let bytes = everything.encoded() + [9, 9, 9]
        let (back, offset) = try IppMessage.parse(bytes)
        check(back == everything, "IPP: every value type survives a round trip")
        check(offset == bytes.count - 3, "IPP: document data offset")
        for cut in 0 ..< bytes.count - 3 { check((try? IppMessage.parse(Array(bytes.prefix(cut)))) == nil, "IPP: message cut at \(cut) parsed") }
        for _ in 0 ..< 20_000 {
            var bad = bytes
            for _ in 0 ... rng.below(3) { bad[rng.below(bad.count)] = UInt8(rng.below(256)) }
            _ = try? IppMessage.parse(bad)
        }
        checks += 1
    } catch { check(false, "IPP codec threw \(error)") }
    // A Get-Printer-Attributes request written out byte by byte from RFC 8010.
    var hand: [UInt8] = [1, 1, 0, 0x0B, 0, 0, 0, 1, 0x01]
    hand += [0x47, 0, 18]
    hand += Array("attributes-charset".utf8)
    hand += [0, 5]
    hand += Array("utf-8".utf8)
    hand += [0x48, 0, 27]
    hand += Array("attributes-natural-language".utf8)
    hand += [0, 5]
    hand += Array("en-us".utf8)
    hand += [0x03]
    let handParsed = try? IppMessage.parse(hand)
    check(handParsed?.message.attribute("attributes-natural-language", in: 1)?.values == [.language("en-us")], "IPP: hand-written request parses")
    check(handParsed?.message.code == 0x000B && handParsed?.message.requestId == 1, "IPP: operation and request id")
    let rebuilt = IppMessage(code: 0x000B, requestId: 1, groups: [IppGroup(tag: 1, [
        IppAttribute("attributes-charset", .charset("utf-8")), IppAttribute("attributes-natural-language", .language("en-us"))])])
    check(rebuilt.encoded() == hand, "IPP: encoder produces the same bytes")

    // ---- IPP printer ----------------------------------------------------------
    let sink = MemorySink()
    var logLines = [String]()
    let logLock = NSLock()
    let printer = IppPrinter(config: ServiceConfig(), sink: sink) { line in logLock.lock(); logLines.append(line); logLock.unlock() }

    let attrs = ippReply(printer, ippRequest(0x000B))
    check(attrs.code == 0 && attrs.versionMajor == 2 && attrs.requestId == 1, "Get-Printer-Attributes: ok, version and id echoed")
    func printerAttr(_ name: String) -> [IppValue]? { attrs.attribute(name, in: IppGroup.printer)?.values }
    check(printerAttr("document-format-supported") == [.mime("image/pwg-raster"), .mime("application/octet-stream")], "formats: PWG Raster only by default")
    check(printerAttr("urf-supported") == nil, "URF is not advertised by default")
    check(printerAttr("pwg-raster-document-resolution-supported") == [.resolution(203, 203, units: 3)], "203 dpi")
    check(printerAttr("pwg-raster-document-type-supported") == [.keyword("black_1"), .keyword("sgray_8")], "raster types")
    check(printerAttr("media-default") == [.keyword("na_index-4x6_4x6in")], "default media is 4x6")
    check(printerAttr("media-supported")?.count == 3 && printerAttr("media-col-database")?.count == 3 && printerAttr("media-size-supported")?.count == 3, "three sizes")
    check(printerAttr("ipp-features-supported") == [.keyword("ipp-everywhere")], "IPP Everywhere")
    check(printerAttr("printer-state") == [.enumeration(3)], "printer idle")
    for required in ["charset-configured", "charset-supported", "compression-supported", "copies-supported", "ipp-versions-supported",
                     "media-col-default", "media-col-ready", "media-ready", "natural-language-configured", "operations-supported",
                     "print-color-mode-supported", "print-quality-supported", "printer-is-accepting-jobs", "printer-make-and-model",
                     "printer-name", "printer-resolution-supported", "printer-state-reasons", "printer-up-time", "printer-uri-supported",
                     "printer-uuid", "sides-supported", "orientation-requested-default", "orientation-requested-supported", "uri-authentication-supported", "uri-security-supported"] {
        check(printerAttr(required) != nil, "printer attribute \(required) present")
    }
    let few = ippReply(printer, ippRequest(0x000B, [IppAttribute("requested-attributes", [.keyword("printer-name"), .keyword("media-default")])]))
    check(few.groups.last?.attributes.map { $0.name } == ["media-default", "printer-name"], "requested-attributes limits the reply")
    let template = ippReply(printer, ippRequest(0x000B, [IppAttribute("requested-attributes", .keyword("job-template"))]))
    let names = Set(template.groups.last?.attributes.map { $0.name } ?? [])
    check(names.contains("media-supported") && names.contains("copies-default") && !names.contains("printer-name"), "job-template group")
    var urfConfig = ServiceConfig(); urfConfig.advertiseURF = true
    let urfPrinter = IppPrinter(config: urfConfig, sink: MemorySink()) { _ in }
    let urfAttrs = ippReply(urfPrinter, ippRequest(0x000B))
    check(urfAttrs.attribute("document-format-supported", in: IppGroup.printer)?.values.contains(.mime("image/urf")) == true
          && urfAttrs.attribute("urf-supported", in: IppGroup.printer)?.values.contains(.keyword("RS203")) == true, "URF advertised when configured")

    // Bad requests.
    check(ippReply(printer, ippRequest(0x4002)).code == 0x0501, "unknown operation refused")
    var v3 = IppMessage(code: 0x000B, requestId: 1, groups: []); v3.versionMajor = 3
    check(ippReply(printer, v3.encoded()).code == 0x0503, "IPP version 3 refused")
    check(ippReply(printer, IppMessage(code: 0x000B, requestId: 1, groups: []).encoded()).code == 0x0400, "missing operation attributes refused")
    let noTarget = IppMessage(code: 0x000B, requestId: 1, groups: [IppGroup(tag: IppGroup.operation, [
        IppAttribute("attributes-charset", .charset("utf-8")), IppAttribute("attributes-natural-language", .language("en"))])])
    check(ippReply(printer, noTarget.encoded()).code == 0x0400, "request without printer-uri refused")
    check(printer.handle([1, 2, 3]) == nil, "garbage is not answered as IPP")
    check(ippReply(printer, [2, 0, 0, 0x0B, 0, 0, 0, 1, 0x01, 0x47, 0xFF]).code == 0x0400, "malformed IPP gets bad-request")
    let pdf = ippReply(printer, ippRequest(0x0004, [IppAttribute("document-format", .mime("application/pdf"))]))
    check(pdf.code == 0x040A && pdf.groups.contains { $0.tag == IppGroup.unsupported }, "Validate-Job refuses PDF")
    check(ippReply(printer, ippRequest(0x0004, [IppAttribute("document-format", .mime("image/pwg-raster"))])).code == 0, "Validate-Job accepts PWG Raster")
    check(ippReply(printer, ippRequest(0x0002, [IppAttribute("document-format", .mime("image/pwg-raster"))])).code == 0x0400, "Print-Job without data refused")
    check(ippReply(printer, ippRequest(0x0009, [IppAttribute("job-id", .integer(999))])).code == 0x0406, "unknown job not found")
    check(ippReply(printer, ippRequest(0x003C)).code == 0, "Identify-Printer accepted")

    // Print-Job: a label on a Letter page, then a blank page.
    let doc = pwgDocument([letter, blank], .sgray8)
    let pj = ippReply(printer, ippRequest(0x0002, [IppAttribute("job-name", .name("test label")), IppAttribute("requesting-user-name", .name("tester")),
                                                   IppAttribute("document-format", .mime("image/pwg-raster"))], data: doc))
    check(pj.code == 0 && jobId(pj) == 1 && [3, 5, 9].contains(jobState(pj)), "Print-Job accepted with a job id")
    check(pj.attribute("job-uri", in: IppGroup.job)?.values == [.uri("ipp://localhost:8631/ipp/print/1")], "job-uri")
    let done = waitForJob(printer, 1)
    check(jobState(done) == 9, "job 1 completed (state \(jobState(done)))")
    check(done.attribute("job-state-reasons", in: IppGroup.job)?.values == [.keyword("job-completed-successfully")], "job 1 reasons")
    check(done.attribute("job-impressions-completed", in: IppGroup.job)?.values == [.integer(1)], "job 1: one label, the blank page skipped")
    check(done.attribute("job-name", in: IppGroup.job)?.values == [.name("test label")], "job name kept")
    check(sink.labels.count == 1 && sink.documentCount == 1, "sink got one label")
    if let label = sink.labels.first {
        check(label.canvas == Tspl.canvas(for: r3!.page, config: PrinterConfig()), "label matches the layout result on the 864-dot canvas")
        check((try? Tspl.parseJob(label.job))?.raster == label.canvas.data, "job bytes decode back to the canvas")
        check((try? Tspl.parseJob(label.job))?.trailerLines == ["", "PRINT 1,1"], "one copy")
    }

    // Create-Job + Send-Document with copies, in URF.
    let cj = ippReply(printer, ippRequest(0x0005, job: [IppAttribute("copies", .integer(3))]))
    check(cj.code == 0 && jobId(cj) == 2 && jobState(cj) == 3, "Create-Job gives a pending job")
    let sd = ippReply(printer, ippRequest(0x0006, [IppAttribute("job-id", .integer(2)), IppAttribute("last-document", .boolean(true))],
                                          data: urfDocument([exact])))
    check(sd.code == 0, "Send-Document accepted")
    check(jobState(waitForJob(printer, 2)) == 9, "job 2 completed")
    check(sink.labels.count == 2 && sink.labels.last?.canvas == Tspl.canvas(for: bw(exact), config: PrinterConfig()), "URF page printed as is")
    check((try? Tspl.parseJob(sink.labels.last?.job ?? []))?.trailerLines == ["", "PRINT 1,3"], "copies passed to PRINT")
    check(ippReply(printer, ippRequest(0x0006, [IppAttribute("job-id", .integer(2)), IppAttribute("last-document", .boolean(true))], data: doc)).code == 0x0509,
          "second document refused")
    check(ippReply(printer, ippRequest(0x0008, [IppAttribute("job-id", .integer(2))])).code == 0x0404, "cancelling a finished job is not possible")
    check(ippReply(printer, ippRequest(0x003B, [IppAttribute("job-id", .integer(2))])).code == 0, "Close-Job accepted")
    check(ippReply(printer, ippRequest(0x0006, [IppAttribute("job-id", .integer(2))], data: doc)).code == 0x0400, "Send-Document without last-document refused")

    // A document that is not a raster aborts the job.
    _ = ippReply(printer, ippRequest(0x0002, data: Array("%PDF-1.7 this is not a raster".utf8)))
    let aborted = waitForJob(printer, 3)
    check(jobState(aborted) == 8 && aborted.attribute("job-state-reasons", in: IppGroup.job)?.values.contains(.keyword("document-format-error")) == true,
          "non-raster document: job aborted with document-format-error")
    // A printer failure aborts the job.
    sink.failNext = true
    _ = ippReply(printer, ippRequest(0x0002, data: pwgDocument([exact], .black1)))
    check(jobState(waitForJob(printer, 4)) == 8, "sink failure: job aborted")
    // A cut-off document aborts the job.
    _ = ippReply(printer, ippRequest(0x0002, data: Array(doc.prefix(doc.count / 3))))
    check(jobState(waitForJob(printer, 5)) == 8, "truncated document: job aborted")
    // Create-Job then cancel before any document.
    let cj2 = ippReply(printer, ippRequest(0x0005))
    check(ippReply(printer, ippRequest(0x0008, [IppAttribute("job-uri", .uri("ipp://localhost:8631/ipp/print/\(jobId(cj2))"))])).code == 0, "Cancel-Job by job-uri")
    check(jobState(waitForJob(printer, jobId(cj2))) == 7, "cancelled job is in state canceled")

    // The second queue: same printer, but the rest of the page is printed too.
    func allRequest(_ op: UInt16, _ extra: [IppAttribute] = [], data: [UInt8] = []) -> IppMessage {
        guard let bytes = printer.handle(ippRequest(op, extra, data: data), path: "/ipp/all"), let parsed = try? IppMessage.parse(bytes) else {
            return IppMessage(code: 0xFFFF, requestId: 0, groups: [])
        }
        return parsed.message
    }
    let allAttrsQ = allRequest(0x000B)
    check(allAttrsQ.attribute("printer-uri-supported", in: IppGroup.printer)?.values == [.uri("ipp://localhost:8631/ipp/all")], "second queue: its own URI")
    check(allAttrsQ.attribute("printer-name", in: IppGroup.printer)?.values == [.name("D450_all")]
          && allAttrsQ.attribute("printer-uuid", in: IppGroup.printer)?.values != printerAttr("printer-uuid"), "second queue: its own name and id")
    let before = sink.labels.count
    let mixedDoc = pwgDocument([mixed], .sgray8)
    let onlyLabel = ippReply(printer, ippRequest(0x0002, data: mixedDoc))
    check(jobState(waitForJob(printer, jobId(onlyLabel))) == 9 && sink.labels.count == before + 1, "first queue: label only, one label")
    let both = allRequest(0x0002, data: mixedDoc)
    check(both.attribute("job-uri", in: IppGroup.job)?.values.first?.stringValue?.hasPrefix("ipp://localhost:8631/ipp/all/") == true, "second queue: job URI")
    check(jobState(waitForJob(printer, jobId(both))) == 9 && sink.labels.count == before + 3, "second queue: label and the rest, two labels")
    check(sink.labels.last?.label == 2 && sink.labels.dropLast().last?.canvas == sink.labels.dropLast(2).last?.canvas, "second queue: same label first, then the rest")
    check(allRequest(0x000A, [IppAttribute("which-jobs", .keyword("completed"))]).groups.filter { $0.tag == IppGroup.job }.count == 1,
          "second queue lists only its own jobs")

    // Get-Jobs.
    let finished = ippReply(printer, ippRequest(0x000A, [IppAttribute("which-jobs", .keyword("completed"))]))
    check(finished.groups.filter { $0.tag == IppGroup.job }.count == 7, "Get-Jobs completed lists the seven finished jobs of the first queue")
    check(finished.groups.last?.attributes.map { $0.name } == ["job-id", "job-uri"], "Get-Jobs default attributes")
    check(ippReply(printer, ippRequest(0x000A)).groups.filter { $0.tag == IppGroup.job }.isEmpty, "Get-Jobs: nothing still active")
    check(ippReply(printer, ippRequest(0x000A, [IppAttribute("which-jobs", .keyword("completed")), IppAttribute("limit", .integer(2))]))
        .groups.filter { $0.tag == IppGroup.job }.count == 2, "Get-Jobs honours limit")
    let allAttrs = ippReply(printer, ippRequest(0x000A, [IppAttribute("which-jobs", .keyword("completed")), IppAttribute("requested-attributes", .keyword("all"))]))
    check(allAttrs.groups.last?["job-state"] != nil && allAttrs.groups.last?["time-at-completed"] != nil, "Get-Jobs with requested-attributes all gives full job attributes")
    func jobCount(_ extra: [IppAttribute]) -> Int {
        ippReply(printer, ippRequest(0x000A, [IppAttribute("which-jobs", .keyword("completed"))] + extra)).groups.filter { $0.tag == IppGroup.job }.count
    }
    check(jobCount([IppAttribute("requesting-user-name", .name("tester")), IppAttribute("my-jobs", .boolean(true))]) == 1, "Get-Jobs my-jobs: only that user's job")
    check(jobCount([IppAttribute("requesting-user-name", .name("someone-else")), IppAttribute("my-jobs", .boolean(true))]) == 0, "Get-Jobs my-jobs: nothing for another user")
    check(ippReply(printer, ippRequest(0x0039)).code == 0, "Cancel-My-Jobs accepted")
    check(sink.labels.count == 5, "no extra labels from failed jobs")

    runHttpTests(document: doc, expected: Tspl.canvas(for: r3!.page, config: PrinterConfig()))
}

// MARK: HTTP

/// A bare TCP client, so the listener is tested exactly as a print system would use it.
final class TestClient {
    private var fd: Int32 = -1
    private var buffer = [UInt8]()

    init?(port: Int) {
        fd = socket(AF_INET, streamSocket, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        #if !canImport(Glibc)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if fd < 0 || ok != 0 { return nil }
    }

    deinit { if fd >= 0 { close(fd) } }

    func send(_ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n <= 0 { return }
            sent += n
        }
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    private func more() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return false }
        buffer += chunk[0 ..< n]
        return true
    }

    /// Reads one response. Returns nil if the connection closes first.
    func response() -> (status: Int, headers: String, body: [UInt8])? {
        while true {
            var end = -1
            if buffer.count >= 4 { for i in 0 ... buffer.count - 4 where Array(buffer[i ..< i + 4]) == [13, 10, 13, 10] { end = i; break } }
            if end < 0 { if !more() { return nil }; continue }
            let head = String(decoding: buffer[0 ..< end], as: UTF8.self)
            let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
            var length = 0
            for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            while buffer.count < end + 4 + length { if !more() { return nil } }
            let body = Array(buffer[end + 4 ..< end + 4 + length])
            buffer.removeSubrange(0 ..< end + 4 + length)
            return (status, head, body)
        }
    }

    /// True when the server has closed the connection.
    func closed() -> Bool { buffer.isEmpty && !more() }
}

func chunked(_ body: [UInt8], sizes: [Int]) -> [UInt8] {
    var out = [UInt8]()
    var pos = 0, k = 0
    while pos < body.count {
        let n = min(sizes[k % sizes.count], body.count - pos)
        out += Array(String(n, radix: 16).utf8) + [13, 10] + body[pos ..< pos + n] + [13, 10]
        pos += n; k += 1
    }
    return out + Array("0\r\n\r\n".utf8)
}

func runHttpTests(document: [UInt8], expected: MonoBitmap) {
    let sink = MemorySink()
    var config = ServiceConfig()
    var service: D450Service?
    for port in [18631, 28631, 38631, 48631] {       // first free port
        config.port = port
        let s = D450Service(config: config, sink: sink) { _ in }
        if (try? s.start()) != nil { service = s; break }
    }
    guard service != nil else { check(false, "could not start the listener on any test port"); return }
    let port = config.port
    let host = "Host: localhost:\(port)\r\n"

    func open() -> TestClient {
        guard let c = TestClient(port: port) else { check(false, "cannot connect to the listener"); exit(1) }
        return c
    }

    var c = open()
    c.send("GET / HTTP/1.1\r\n\(host)\r\n")
    let home = c.response()
    check(home?.status == 200 && String(decoding: home?.body ?? [], as: UTF8.self).contains("ipp://localhost:\(port)/ipp/print"), "GET / describes the service")
    // Keep-alive: a second request on the same connection.
    let gpa = ippRequest(0x000B, id: 5)
    c.send("POST /ipp/print HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nContent-Length: \(gpa.count)\r\n\r\n")
    c.send(gpa)
    let r = c.response()
    check(r?.status == 200 && r?.headers.contains("Content-Type: application/ipp") == true, "POST answers with application/ipp")
    let parsed = try? IppMessage.parse(r?.body ?? [])
    check(parsed?.message.code == 0 && parsed?.message.requestId == 5, "IPP reply over HTTP: ok, request id echoed")
    check(parsed?.message.attribute("printer-uri-supported", in: IppGroup.printer)?.values == [.uri("ipp://localhost:\(port)/ipp/print")], "printer URI carries the port")

    // Chunked bodies with Expect: 100-continue, several on one connection, cut at awkward places.
    for (round, sizes) in [[1, 2, 3, 5, 700], [4096], [7], [1]].enumerated() {
        c.send("POST /ipp/print HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n")
        let interim = c.response()
        check(interim?.status == 100, "round \(round): 100 Continue sent")
        let body = chunked(ippRequest(0x000B, id: Int32(100 + round)), sizes: sizes)
        // Send in two parts so a chunk header can straddle a read.
        c.send(Array(body.prefix(body.count / 2))); usleep(20_000); c.send(Array(body.suffix(from: body.count / 2)))
        let reply = c.response()
        check((try? IppMessage.parse(reply?.body ?? []))?.message.requestId == Int32(100 + round), "round \(round): chunked request answered on the same connection")
    }

    // A whole print job, chunked, the way CUPS sends it.
    c.send("POST /ipp/print HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n")
    check(c.response()?.status == 100, "print job: 100 Continue")
    c.send(chunked(ippRequest(0x0002, id: 9, [IppAttribute("document-format", .mime("image/pwg-raster"))], data: document), sizes: [3, 1000, 65536]))
    let printed = try? IppMessage.parse(c.response()?.body ?? [])
    check(printed?.message.code == 0, "print job accepted over HTTP")
    var state = 0
    for _ in 0 ..< 500 where state < 7 {
        let q = ippRequest(0x0009, [IppAttribute("job-id", .integer(1))])
        c.send("POST /ipp/print/1 HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nContent-Length: \(q.count)\r\n\r\n"); c.send(q)
        state = (try? IppMessage.parse(c.response()?.body ?? [])).map { jobState($0.message) } ?? 99
        usleep(20_000)
    }
    check(state == 9, "print job completed over HTTP (state \(state))")
    check(sink.labels.count == 1 && sink.labels.first?.canvas == expected, "label from the HTTP job matches the direct one")

    // Refusals. Each closes the connection.
    func refused(_ request: String, _ want: Int, _ what: String) {
        let k = open()
        k.send(request)
        check(k.response()?.status == want, "\(what) gets \(want)")
        check(k.closed(), "\(what): connection closed")
    }
    refused("GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n", 403, "foreign Host header")
    refused("GET / HTTP/1.1\r\n\r\n", 403, "missing Host header")
    refused("POST /ipp/print HTTP/1.1\r\n\(host)Content-Type: text/plain\r\nContent-Length: 3\r\n\r\nabc", 415, "POST that is not application/ipp")
    refused("POST /other HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nContent-Length: 0\r\n\r\n", 404, "POST to another path")
    refused("DELETE / HTTP/1.1\r\n\(host)\r\n", 405, "other method")
    refused("OPTIONS /ipp/print HTTP/1.1\r\n\(host)Origin: http://evil.example\r\n\r\n", 405, "browser preflight")
    refused("nonsense\r\n\r\n", 400, "garbage request line")
    refused("POST /ipp/print HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nContent-Length: 999999999999\r\n\r\n", 413, "oversized body")
    refused("POST /ipp/print HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", 400, "bad chunk size")
    c = open()
    c.send("POST /ipp/print HTTP/1.1\r\n\(host)Content-Type: application/ipp\r\nContent-Length: 3\r\n\r\nabc")
    check(c.response()?.status == 400, "POST body that is not IPP gets 400")
    c.send("GET / HTTP/1.1\r\n\(host)Connection: close\r\n\r\n")
    check(c.response()?.status == 200 && c.closed(), "Connection: close is honoured")
    check(sink.labels.count == 1, "refused requests printed nothing")
}
