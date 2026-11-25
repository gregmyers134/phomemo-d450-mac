import Foundation

/// Settings read from the JSON config file. Every key is optional; missing
/// keys keep the defaults below.
public struct ServiceConfig: Codable, Equatable {
    /// Loopback port the IPP endpoint listens on.
    public var port = 8631
    /// Name shown for the print queue.
    public var printerName = "D450"
    /// The printer is found by this Bluetooth name. Not used in dry-run mode.
    public var bluetoothName = "D450"
    public var density = 10          // 0 to 15
    public var speed = 1             // 1 to 8
    public var gapMm = 4.60
    /// Head column (0-based) where the label's left column goes.
    public var leftDot = 0
    /// Row of the print (0-based) where the label's top row goes.
    public var topDot = 10
    /// Grey values below this print black (when dither is off).
    public var threshold = 128
    /// Floyd-Steinberg dithering instead of a plain threshold.
    public var dither = false
    /// Direction a landscape page is turned to fit the label.
    public var rotateClockwise = true
    /// Pages with no ink are dropped instead of feeding a blank label.
    public var skipBlankPages = true
    /// Also offer Apple Raster (URF) to the print system. Off: PWG Raster only.
    public var advertiseURF = false
    /// Seconds to wait for the printer to report a page as done.
    public var doneTimeoutSeconds = 45

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServiceConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        printerName = try c.decodeIfPresent(String.self, forKey: .printerName) ?? d.printerName
        bluetoothName = try c.decodeIfPresent(String.self, forKey: .bluetoothName) ?? d.bluetoothName
        density = try c.decodeIfPresent(Int.self, forKey: .density) ?? d.density
        speed = try c.decodeIfPresent(Int.self, forKey: .speed) ?? d.speed
        gapMm = try c.decodeIfPresent(Double.self, forKey: .gapMm) ?? d.gapMm
        leftDot = try c.decodeIfPresent(Int.self, forKey: .leftDot) ?? d.leftDot
        topDot = try c.decodeIfPresent(Int.self, forKey: .topDot) ?? d.topDot
        threshold = try c.decodeIfPresent(Int.self, forKey: .threshold) ?? d.threshold
        dither = try c.decodeIfPresent(Bool.self, forKey: .dither) ?? d.dither
        rotateClockwise = try c.decodeIfPresent(Bool.self, forKey: .rotateClockwise) ?? d.rotateClockwise
        skipBlankPages = try c.decodeIfPresent(Bool.self, forKey: .skipBlankPages) ?? d.skipBlankPages
        advertiseURF = try c.decodeIfPresent(Bool.self, forKey: .advertiseURF) ?? d.advertiseURF
        doneTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .doneTimeoutSeconds) ?? d.doneTimeoutSeconds
    }

    public enum ConfigError: Error, Equatable { case invalid(String) }

    /// Reads and checks a config file. Unknown keys are refused so that a
    /// misspelt setting is not silently ignored.
    public static func load(json: Data) throws -> ServiceConfig {
        let known = Set(["port", "printerName", "bluetoothName", "density", "speed", "gapMm", "leftDot", "topDot",
                         "threshold", "dither", "rotateClockwise", "skipBlankPages", "advertiseURF",
                         "doneTimeoutSeconds"])
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ConfigError.invalid("the config file must be a JSON object")
        }
        if let stray = object.keys.sorted().first(where: { !known.contains($0) }) {
            throw ConfigError.invalid("unknown setting \"\(stray)\"")
        }
        let config = try JSONDecoder().decode(ServiceConfig.self, from: json)
        try config.validate()
        return config
    }

    public func validate() throws {
        func need(_ ok: Bool, _ why: String) throws { if !ok { throw ConfigError.invalid(why) } }
        try need((1024 ... 65535).contains(port), "port must be 1024 to 65535")
        try need((0 ... 15).contains(density), "density must be 0 to 15")
        try need((1 ... 8).contains(speed), "speed must be 1 to 8")
        try need(gapMm >= 0 && gapMm <= 20, "gapMm must be 0 to 20")
        let p = PrinterConfig()
        try need((0 ... p.headDots - p.labelWidthDots).contains(leftDot),
                 "leftDot must be 0 to \(p.headDots - p.labelWidthDots)")
        try need((0 ... 80).contains(topDot), "topDot must be 0 to 80")
        try need((1 ... 255).contains(threshold), "threshold must be 1 to 255")
        try need((5 ... 600).contains(doneTimeoutSeconds), "doneTimeoutSeconds must be 5 to 600")
        try need(!printerName.isEmpty && printerName.utf8.count <= 60, "printerName must be 1 to 60 characters")
        try need(!bluetoothName.isEmpty && bluetoothName.utf8.count <= 60, "bluetoothName must be 1 to 60 characters")
    }

    public func defaultJSON() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? e.encode(self)) ?? Data(), as: UTF8.self)
    }

    /// The printer-side settings used by the job builder.
    public var printer: PrinterConfig {
        var p = PrinterConfig()
        p.density = density
        p.speed = speed
        p.gapMm = gapMm
        p.leftDot = leftDot
        p.topDot = topDot
        return p
    }
}
