import Foundation

/// A JSON document kept as its original text, so an edit changes only the bytes it touches.
///
/// `JSONSerialization` re-sorts keys, reformats the file and rewrites numbers (`0.1` becomes
/// `0.10000000000000001`), which is not acceptable for a file the user maintains by hand,
/// such as `~/.claude/settings.json`. This parser records where every value starts and ends,
/// and the editing helpers splice text in and out around those ranges.
struct JSONDocument {
    struct Failure: Error, Equatable {
        let offset: Int
    }

    /// A parsed value and the byte range of its text.
    struct Node {
        enum Kind {
            case object([Member])
            case array([Node])
            case string(String)
            case scalar
        }
        let range: Range<Int>
        let kind: Kind

        var members: [Member]? { if case .object(let m) = kind { return m } else { return nil } }
        var elements: [Node]? { if case .array(let e) = kind { return e } else { return nil } }
        var string: String? { if case .string(let s) = kind { return s } else { return nil } }

        func member(_ key: String) -> Member? { members?.first { $0.key == key } }
    }

    struct Member {
        let key: String
        /// Where the key's opening quote is; a member spans `keyStart ..< value.range.upperBound`.
        let keyStart: Int
        let value: Node
        var range: Range<Int> { keyStart..<value.range.upperBound }
    }

    private(set) var bytes: [UInt8]
    private(set) var root: Node

    var text: String { String(decoding: bytes, as: UTF8.self) }

    init(_ text: String) throws {
        bytes = Array(text.utf8)
        var parser = Parser(bytes)
        root = try parser.document()
    }

    // MARK: - Editing

    /// Replaces a byte range with new text and parses the result again.
    mutating func replace(_ range: Range<Int>, with text: String) throws {
        bytes.replaceSubrange(range, with: Array(text.utf8))
        var parser = Parser(bytes)
        root = try parser.document()
    }

    /// Removes element `index` of an array, together with the comma that separated it.
    mutating func removeElement(_ index: Int, of array: Node) throws {
        guard let items = array.elements, items.indices.contains(index) else { return }
        try replace(Self.cut(index, in: items.map(\.range), container: array.range), with: "")
    }

    /// Removes a member of an object, together with the comma that separated it.
    mutating func removeMember(_ key: String, of object: Node) throws {
        guard let members = object.members, let index = members.firstIndex(where: { $0.key == key }) else { return }
        try replace(Self.cut(index, in: members.map(\.range), container: object.range), with: "")
    }

    /// The text to delete to remove item `index`: with the comma before it, or after it for the first item.
    private static func cut(_ index: Int, in items: [Range<Int>], container: Range<Int>) -> Range<Int> {
        if items.count == 1 { return (container.lowerBound + 1)..<(container.upperBound - 1) }
        if index > 0 { return items[index - 1].upperBound..<items[index].upperBound }
        return items[0].lowerBound..<items[1].lowerBound
    }

    /// Appends a value to an array, laid out like the array's other items.
    mutating func append(_ value: JSONValue, to array: Node) throws {
        try insert(item: { value.render(indent: $0, unit: $1, pretty: $2) }, into: array, last: array.elements?.last?.range)
    }

    /// Adds a member at the end of an object, laid out like the object's other members.
    mutating func add(_ key: String, _ value: JSONValue, to object: Node) throws {
        let item: (String, String, Bool) -> String = { indent, unit, pretty in
            JSONValue.quote(key) + ": " + value.render(indent: indent, unit: unit, pretty: pretty)
        }
        try insert(item: item, into: object, last: object.members?.last?.range)
    }

    private mutating func insert(item: (String, String, Bool) -> String, into container: Node, last: Range<Int>?) throws {
        let unit = indentUnit
        let multiline = bytes[container.range].contains(UInt8(ascii: "\n"))
        if let last {
            if multiline {
                let indent = startsLine(last.lowerBound) ? lineIndent(at: last.lowerBound) : lineIndent(at: container.range.lowerBound) + unit
                try replace(last.upperBound..<last.upperBound, with: ",\n" + indent + item(indent, unit, true))
            } else {
                try replace(last.upperBound..<last.upperBound, with: ", " + item("", unit, false))
            }
        } else {
            // An empty container: lay it out over several lines when the rest of the file is
            let pretty = bytes.contains(UInt8(ascii: "\n")) || bytes.count < 3
            let outer = lineIndent(at: container.range.lowerBound)
            let inner = (container.range.lowerBound + 1)..<(container.range.upperBound - 1)
            let text = pretty ? "\n" + outer + unit + item(outer + unit, unit, true) + "\n" + outer : item("", unit, false)
            try replace(inner, with: text)
        }
    }

    // MARK: - Layout

    /// The file's indent step: the leading whitespace of the first indented line, or two spaces.
    var indentUnit: String {
        var lineStart = true
        var current: [UInt8] = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") { lineStart = true; current = []; continue }
            if lineStart && (byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")) { current.append(byte); continue }
            if lineStart && !current.isEmpty && byte != UInt8(ascii: "\r") { return String(decoding: current, as: UTF8.self) }
            lineStart = false
        }
        return "  "
    }

    /// The whitespace at the start of the line that contains `offset`.
    private func lineIndent(at offset: Int) -> String {
        var start = offset
        while start > 0 && bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        var end = start
        while end < bytes.count && (bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t")) { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Whether only whitespace comes before `offset` on its line.
    private func startsLine(_ offset: Int) -> Bool {
        var i = offset
        while i > 0 {
            let b = bytes[i - 1]
            if b == UInt8(ascii: "\n") { return true }
            if b != UInt8(ascii: " ") && b != UInt8(ascii: "\t") { return false }
            i -= 1
        }
        return true
    }
}

/// A value Deckhand writes into a JSON document. Objects keep their key order.
enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case bool(Bool)

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let x), .array(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        default: return false
        }
    }

    /// The value as Foundation objects, to compare with what `JSONSerialization` reads.
    var foundation: Any {
        switch self {
        case .object(let pairs): return Dictionary(pairs.map { ($0.0, $0.1.foundation) }) { a, _ in a }
        case .array(let items): return items.map(\.foundation)
        case .string(let s): return s
        case .int(let n): return n
        case .bool(let b): return b
        }
    }

    /// JSON text. When `pretty`, nested lines start with `indent` plus one `unit` per level.
    func render(indent: String, unit: String, pretty: Bool) -> String {
        switch self {
        case .string(let s): return Self.quote(s)
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items):
            if items.isEmpty { return "[]" }
            if !pretty { return "[" + items.map { $0.render(indent: "", unit: unit, pretty: false) }.joined(separator: ", ") + "]" }
            let inner = indent + unit
            return "[\n" + items.map { inner + $0.render(indent: inner, unit: unit, pretty: true) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            if !pretty {
                return "{" + pairs.map { Self.quote($0.0) + ": " + $0.1.render(indent: "", unit: unit, pretty: false) }.joined(separator: ", ") + "}"
            }
            let inner = indent + unit
            return "{\n" + pairs.map { inner + Self.quote($0.0) + ": " + $0.1.render(indent: inner, unit: unit, pretty: true) }
                .joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

// MARK: - Parser

private struct Parser {
    let b: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { b = bytes }

    mutating func document() throws -> JSONDocument.Node {
        // A UTF-8 byte order mark stays in the text untouched
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        skip()
        let node = try value()
        skip()
        guard i == b.count else { throw JSONDocument.Failure(offset: i) }
        return node
    }

    private mutating func skip() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private func fail() -> JSONDocument.Failure { JSONDocument.Failure(offset: i) }

    private mutating func value() throws -> JSONDocument.Node {
        guard i < b.count else { throw fail() }
        let start = i
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [JSONDocument.Member] = []
            skip()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .init(range: start..<i, kind: .object(members)) }
            while true {
                skip()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail() }
                let keyStart = i
                let key = try string()
                skip()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail() }
                i += 1
                skip()
                members.append(.init(key: key, keyStart: keyStart, value: try value()))
                skip()
                guard i < b.count else { throw fail() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .init(range: start..<i, kind: .object(members)) }
                throw fail()
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JSONDocument.Node] = []
            skip()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .init(range: start..<i, kind: .array(items)) }
            while true {
                skip()
                items.append(try value())
                skip()
                guard i < b.count else { throw fail() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .init(range: start..<i, kind: .array(items)) }
                throw fail()
            }
        case UInt8(ascii: "\""):
            let s = try string()
            return .init(range: start..<i, kind: .string(s))
        case UInt8(ascii: "t"): try literal("true"); return .init(range: start..<i, kind: .scalar)
        case UInt8(ascii: "f"): try literal("false"); return .init(range: start..<i, kind: .scalar)
        case UInt8(ascii: "n"): try literal("null"); return .init(range: start..<i, kind: .scalar)
        default:
            try number()
            return .init(range: start..<i, kind: .scalar)
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { throw fail() }
        i += w.count
    }

    private mutating func number() throws {
        func digits() -> Int { let s = i; while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }; return i - s }
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw fail() }
        if b[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { throw fail() }
        if i < b.count, b[i] == UInt8(ascii: ".") { i += 1; if digits() == 0 { throw fail() } }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            if digits() == 0 { throw fail() }
        }
    }

    /// Reads a string starting at its opening quote and returns it decoded.
    private mutating func string() throws -> String {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
            if c < 0x20 { throw fail() }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { throw fail() }
            switch b[i] {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800..<0xDC00).contains(code), i + 2 < b.count, b[i + 1] == UInt8(ascii: "\\"), b[i + 2] == UInt8(ascii: "u") {
                    i += 2
                    let low = try hex4()
                    if (0xDC00..<0xE000).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) }
                }
                out.append(contentsOf: Array(String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}").utf8))
            default: throw fail()
            }
            i += 1
        }
        throw fail()
    }

    /// Reads the four hex digits after `\u`; leaves `i` on the last one.
    private mutating func hex4() throws -> UInt32 {
        guard i + 4 < b.count else { throw fail() }
        var v: UInt32 = 0
        for k in 1...4 {
            let c = b[i + k]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw fail()
            }
            v = v * 16 + d
        }
        i += 4
        return v
    }
}
