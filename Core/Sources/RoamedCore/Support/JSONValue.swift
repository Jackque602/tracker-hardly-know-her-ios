import Foundation

/**
 A JSON tree that remembers the order its keys were written in.

 `JSONSerialization` would be less code, but it hands back a `Dictionary`, and a dictionary has no
 order. The Timeline reader walks unknown objects looking for anything shaped like a coordinate,
 and the order it finds them in is the order of the resulting path - so an unordered tree would
 scramble a journey differently on every run. Numbers are kept as their literal text for the same
 reason the Kotlin original reads `JsonPrimitive.content`: an export may quote them or not, and
 either way the digits are what matter.
 */
public indirect enum JSONValue {
    case null
    case bool(Bool)
    /// The number exactly as it was written, so it can be read as an integer or a double.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    /// True only for a JSON string, which is what tells `"geo:1,2"` from a bare number.
    public var isString: Bool {
        if case .string = self { return true }
        return false
    }

    /// The primitive's text, or nil for arrays and objects.
    public var content: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array, .object: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectEntries: [(key: String, value: JSONValue)]? {
        if case .object(let entries) = self { return entries }
        return nil
    }

    /// First entry with this key, the way a JSON object is normally read.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    public var longValue: Int64? { content.flatMap { Int64($0) } }

    public var doubleValue: Double? { content.flatMap { Double($0) } }
}

public struct JSONParseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public var localizedDescription: String { message }
}

/// A small recursive-descent JSON reader. Strict enough to reject rubbish, ordered by design.
public enum JSONParser {

    public static func parse(_ text: String) throws -> JSONValue {
        var scanner = Scanner(Array(text.utf8))
        scanner.skipWhitespace()
        let value = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.atEnd else { throw JSONParseError(message: "unexpected trailing content") }
        return value
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private var index: Int = 0
        /// Guards against a pathological file blowing the stack rather than failing cleanly.
        private var depth: Int = 0
        private static let maxDepth = 256

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            guard index < bytes.count else { throw JSONParseError(message: "unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        private mutating func parseObject() throws -> JSONValue {
            try enter()
            defer { depth -= 1 }
            index += 1 // {
            var entries: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { index += 1; return .object(entries) }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else {
                    throw JSONParseError(message: "expected a key at byte \(index)")
                }
                let key = try parseString()
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else {
                    throw JSONParseError(message: "expected ':' at byte \(index)")
                }
                index += 1
                skipWhitespace()
                let value = try parseValue()
                entries.append((key: key, value: value))
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"): index += 1; return .object(entries)
                default: throw JSONParseError(message: "expected ',' or '}' at byte \(index)")
                }
            }
        }

        private mutating func parseArray() throws -> JSONValue {
            try enter()
            defer { depth -= 1 }
            index += 1 // [
            var items: [JSONValue] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                let item = try parseValue()
                items.append(item)
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"): index += 1; return .array(items)
                default: throw JSONParseError(message: "expected ',' or ']' at byte \(index)")
                }
            }
        }

        private mutating func parseString() throws -> String {
            index += 1 // opening quote
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard let text = String(bytes: out, encoding: .utf8) else {
                        throw JSONParseError(message: "string is not valid UTF-8")
                    }
                    return text
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else { break }
                    switch bytes[index] {
                    case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); index += 1
                    case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); index += 1
                    case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); index += 1
                    case UInt8(ascii: "b"): out.append(0x08); index += 1
                    case UInt8(ascii: "f"): out.append(0x0C); index += 1
                    case UInt8(ascii: "n"): out.append(0x0A); index += 1
                    case UInt8(ascii: "r"): out.append(0x0D); index += 1
                    case UInt8(ascii: "t"): out.append(0x09); index += 1
                    case UInt8(ascii: "u"):
                        index += 1
                        let scalar = try parseUnicodeEscape()
                        out.append(contentsOf: Array(String(scalar).utf8))
                    default: throw JSONParseError(message: "bad escape at byte \(index)")
                    }
                    continue
                }
                out.append(byte)
                index += 1
            }
            throw JSONParseError(message: "unterminated string")
        }

        /// Reads `\uXXXX`, pairing surrogates so emoji and the like survive.
        private mutating func parseUnicodeEscape() throws -> Character {
            let first = try readHex4()
            if first >= 0xD800 && first <= 0xDBFF,
               index + 1 < bytes.count,
               bytes[index] == UInt8(ascii: "\\"),
               bytes[index + 1] == UInt8(ascii: "u") {
                index += 2
                let second = try readHex4()
                if second >= 0xDC00 && second <= 0xDFFF {
                    let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    guard let scalar = Unicode.Scalar(UInt32(combined)) else {
                        throw JSONParseError(message: "bad surrogate pair")
                    }
                    return Character(scalar)
                }
                guard let scalar = Unicode.Scalar(UInt32(second)) else {
                    throw JSONParseError(message: "bad escape")
                }
                return Character(scalar)
            }
            guard let scalar = Unicode.Scalar(UInt32(first)) else {
                throw JSONParseError(message: "bad escape")
            }
            return Character(scalar)
        }

        private mutating func readHex4() throws -> Int {
            guard index + 4 <= bytes.count else { throw JSONParseError(message: "truncated escape") }
            var value = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: Int
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = Int(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = Int(byte - UInt8(ascii: "A")) + 10
                default: throw JSONParseError(message: "bad hex escape")
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        private mutating func parseNumber() throws -> String {
            let start = index
            if peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+") { index += 1 }
            var sawDigit = false
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    sawDigit = true
                    index += 1
                case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                     UInt8(ascii: "+"), UInt8(ascii: "-"):
                    index += 1
                default:
                    guard sawDigit else { throw JSONParseError(message: "expected a value at byte \(start)") }
                    return String(bytes: bytes[start..<index], encoding: .utf8) ?? ""
                }
            }
            guard sawDigit else { throw JSONParseError(message: "expected a value at byte \(start)") }
            return String(bytes: bytes[start..<index], encoding: .utf8) ?? ""
        }

        private mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else {
                    throw JSONParseError(message: "expected \(literal) at byte \(index)")
                }
                index += 1
            }
        }

        private mutating func enter() throws {
            depth += 1
            guard depth <= Scanner.maxDepth else { throw JSONParseError(message: "nested too deeply") }
        }

        private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
    }
}
