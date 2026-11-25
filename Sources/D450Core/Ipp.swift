// IPP message encoding and decoding (RFC 8010).

public enum IppValue: Equatable {
    case integer(Int32)                    // 0x21
    case boolean(Bool)                     // 0x22
    case enumeration(Int32)                // 0x23
    case string(tag: UInt8, String)        // text, name, keyword, uri, charset, language, MIME type
    case octets(tag: UInt8, [UInt8])       // octetString, dateTime and anything not decoded
    case resolution(Int32, Int32, units: UInt8)   // 0x32; units 3 = dots per inch
    case range(Int32, Int32)               // 0x33
    case collection([IppAttribute])        // 0x34
    case outOfBand(UInt8)                  // 0x10 unsupported, 0x12 unknown, 0x13 no-value

    public static func text(_ s: String) -> IppValue { .string(tag: 0x41, s) }
    public static func name(_ s: String) -> IppValue { .string(tag: 0x42, s) }
    public static func keyword(_ s: String) -> IppValue { .string(tag: 0x44, s) }
    public static func uri(_ s: String) -> IppValue { .string(tag: 0x45, s) }
    public static func uriScheme(_ s: String) -> IppValue { .string(tag: 0x46, s) }
    public static func charset(_ s: String) -> IppValue { .string(tag: 0x47, s) }
    public static func language(_ s: String) -> IppValue { .string(tag: 0x48, s) }
    public static func mime(_ s: String) -> IppValue { .string(tag: 0x49, s) }

    public var stringValue: String? { if case .string(_, let s) = self { return s } else { return nil } }
    public var intValue: Int? {
        switch self {
        case .integer(let v), .enumeration(let v): return Int(v)
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .boolean(let b) = self { return b } else { return nil } }
}

public struct IppAttribute: Equatable {
    public var name: String
    public var values: [IppValue]
    public init(_ name: String, _ values: [IppValue]) { self.name = name; self.values = values }
    public init(_ name: String, _ value: IppValue) { self.name = name; self.values = [value] }
}

public struct IppGroup: Equatable {
    public static let operation: UInt8 = 0x01
    public static let job: UInt8 = 0x02
    public static let printer: UInt8 = 0x04
    public static let unsupported: UInt8 = 0x05

    public var tag: UInt8
    public var attributes: [IppAttribute]
    public init(tag: UInt8, _ attributes: [IppAttribute]) { self.tag = tag; self.attributes = attributes }
    public subscript(name: String) -> IppAttribute? { attributes.first { $0.name == name } }
}

public enum IppError: Error, Equatable {
    case truncated
    case malformed(String)
}

public struct IppMessage: Equatable {
    public var versionMajor: UInt8 = 1
    public var versionMinor: UInt8 = 1
    /// Operation id in a request, status code in a response.
    public var code: UInt16
    public var requestId: Int32
    public var groups: [IppGroup]

    public init(code: UInt16, requestId: Int32, groups: [IppGroup]) {
        self.code = code
        self.requestId = requestId
        self.groups = groups
    }

    /// First attribute with this name in the first group with this tag.
    public func attribute(_ name: String, in tag: UInt8) -> IppAttribute? {
        for g in groups where g.tag == tag { if let a = g[name] { return a } }
        return nil
    }

    // MARK: Encoding

    public func encoded() -> [UInt8] {
        var out: [UInt8] = [versionMajor, versionMinor, UInt8(code >> 8), UInt8(code & 0xFF)]
        IppMessage.put32(&out, requestId)
        for g in groups {
            out.append(g.tag)
            for a in g.attributes { IppMessage.encode(a, into: &out) }
        }
        out.append(0x03)
        return out
    }

    private static func put16(_ out: inout [UInt8], _ v: Int) {
        out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
    }

    private static func put32(_ out: inout [UInt8], _ v: Int32) {
        let u = UInt32(bitPattern: v)
        out.append(UInt8(u >> 24)); out.append(UInt8((u >> 16) & 0xFF))
        out.append(UInt8((u >> 8) & 0xFF)); out.append(UInt8(u & 0xFF))
    }

    private static func encode(_ a: IppAttribute, into out: inout [UInt8]) {
        for (i, v) in a.values.enumerated() { encode(v, name: i == 0 ? a.name : "", into: &out) }
    }

    /// One value with its tag, name and length. Extra values of an attribute carry an empty name.
    private static func encode(_ v: IppValue, name: String, into out: inout [UInt8]) {
        func head(_ tag: UInt8, _ body: [UInt8]) {
            out.append(tag)
            let n = Array(name.utf8)
            put16(&out, n.count); out.append(contentsOf: n)
            put16(&out, body.count); out.append(contentsOf: body)
        }
        var b = [UInt8]()
        switch v {
        case .integer(let x): put32(&b, x); head(0x21, b)
        case .boolean(let x): head(0x22, [x ? 1 : 0])
        case .enumeration(let x): put32(&b, x); head(0x23, b)
        case .string(let tag, let s): head(tag, Array(s.utf8))
        case .octets(let tag, let bytes): head(tag, bytes)
        case .resolution(let x, let y, let units): put32(&b, x); put32(&b, y); b.append(units); head(0x32, b)
        case .range(let lo, let hi): put32(&b, lo); put32(&b, hi); head(0x33, b)
        case .outOfBand(let tag): head(tag, [])
        case .collection(let members):
            head(0x34, [])
            for m in members {
                out.append(0x4A); put16(&out, 0)            // member name, sent as a value
                let n = Array(m.name.utf8)
                put16(&out, n.count); out.append(contentsOf: n)
                for mv in m.values { encode(mv, name: "", into: &out) }
            }
            out.append(0x37); put16(&out, 0); put16(&out, 0)
        }
    }

    // MARK: Decoding

    /// Parses a message. `dataOffset` is where any document data starts.
    public static func parse(_ d: [UInt8]) throws -> (message: IppMessage, dataOffset: Int) {
        guard d.count >= 9 else { throw IppError.truncated }
        var msg = IppMessage(code: UInt16(d[2]) << 8 | UInt16(d[3]), requestId: get32(d, 4), groups: [])
        msg.versionMajor = d[0]
        msg.versionMinor = d[1]
        var pos = 8
        while true {
            guard pos < d.count else { throw IppError.truncated }
            let tag = d[pos]
            if tag == 0x03 { pos += 1; break }
            if tag < 0x10 {
                pos += 1
                msg.groups.append(IppGroup(tag: tag, []))
                continue
            }
            guard !msg.groups.isEmpty else { throw IppError.malformed("attribute before any group") }
            let (name, value) = try value(d, &pos, depth: 0)
            let g = msg.groups.count - 1
            if name.isEmpty {
                guard !msg.groups[g].attributes.isEmpty else { throw IppError.malformed("extra value without an attribute") }
                msg.groups[g].attributes[msg.groups[g].attributes.count - 1].values.append(value)
            } else {
                msg.groups[g].attributes.append(IppAttribute(name, value))
            }
        }
        return (msg, pos)
    }

    private static func get16(_ d: [UInt8], _ pos: inout Int) throws -> Int {
        guard pos + 2 <= d.count else { throw IppError.truncated }
        defer { pos += 2 }
        return Int(d[pos]) << 8 | Int(d[pos + 1])
    }

    private static func get32(_ d: [UInt8], _ at: Int) -> Int32 {
        Int32(bitPattern: UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3]))
    }

    private static func bytes(_ d: [UInt8], _ pos: inout Int, _ n: Int) throws -> [UInt8] {
        guard pos + n <= d.count else { throw IppError.truncated }
        defer { pos += n }
        return Array(d[pos ..< pos + n])
    }

    /// A 2-byte length followed by that many bytes.
    private static func field(_ d: [UInt8], _ pos: inout Int) throws -> [UInt8] {
        let n = try get16(d, &pos)
        return try bytes(d, &pos, n)
    }

    /// Reads one tagged value at `pos`, returning its name (empty for an extra value).
    private static func value(_ d: [UInt8], _ pos: inout Int, depth: Int) throws -> (String, IppValue) {
        guard pos < d.count else { throw IppError.truncated }
        let tag = d[pos]
        pos += 1
        let name = String(decoding: try field(d, &pos), as: UTF8.self)
        let body = try field(d, &pos)
        func need(_ n: Int) throws {
            if body.count != n { throw IppError.malformed("value of tag \(tag) has length \(body.count)") }
        }
        switch tag {
        case 0x21: try need(4); return (name, .integer(get32(body, 0)))
        case 0x22: try need(1); return (name, .boolean(body[0] != 0))
        case 0x23: try need(4); return (name, .enumeration(get32(body, 0)))
        case 0x32: try need(9); return (name, .resolution(get32(body, 0), get32(body, 4), units: body[8]))
        case 0x33: try need(8); return (name, .range(get32(body, 0), get32(body, 4)))
        case 0x41, 0x42, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49:
            return (name, .string(tag: tag, String(decoding: body, as: UTF8.self)))
        case 0x34:
            guard depth < 8 else { throw IppError.malformed("collections nested too deeply") }
            var members = [IppAttribute]()
            while true {
                guard pos < d.count else { throw IppError.truncated }
                if d[pos] == 0x37 {                       // end of collection
                    pos += 1
                    _ = try field(d, &pos)
                    _ = try field(d, &pos)
                    return (name, .collection(members))
                }
                if d[pos] == 0x4A {                       // member name
                    pos += 1
                    _ = try field(d, &pos)
                    let memberName = String(decoding: try field(d, &pos), as: UTF8.self)
                    members.append(IppAttribute(memberName, []))
                    continue
                }
                guard !members.isEmpty else { throw IppError.malformed("collection value without a member name") }
                let (_, v) = try value(d, &pos, depth: depth + 1)
                members[members.count - 1].values.append(v)
            }
        case 0x10 ..< 0x20: return (name, .outOfBand(tag))
        default: return (name, .octets(tag: tag, body))
        }
    }
}
