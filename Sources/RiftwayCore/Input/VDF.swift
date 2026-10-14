import Foundation

/// Valve's KeyValues text format (`.vdf`): quoted keys and values, `{ }`
/// blocks, `//` comments. Keys repeat (`"group"` once per group), so a block
/// keeps its entries in order.
public indirect enum VDF: Equatable, Sendable {
    case value(String)
    case block([(key: String, value: VDF)])

    public static func == (a: VDF, b: VDF) -> Bool {
        switch (a, b) {
        case (.value(let x), .value(let y)): x == y
        case (.block(let x), .block(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unexpected(String, at: Int)
        case unterminated(at: Int)
        public var description: String {
            switch self {
            case .unexpected(let token, let offset): "unexpected \(token) at character \(offset)"
            case .unterminated(let offset): "unterminated text from character \(offset)"
            }
        }
    }

    public static func parse(_ text: String) throws -> VDF {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let entries = try parser.entries(topLevel: true)
        return .block(entries)
    }

    /// The first value for `key`.
    public subscript(key: String) -> VDF? {
        guard case .block(let entries) = self else { return nil }
        return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Every value for `key`, in order.
    public func all(_ key: String) -> [VDF] {
        guard case .block(let entries) = self else { return [] }
        return entries.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map(\.value)
    }

    public var string: String? { if case .value(let s) = self { s } else { nil } }
    public var entries: [(key: String, value: VDF)] { if case .block(let e) = self { e } else { [] } }

    struct Parser {
        let scalars: [Unicode.Scalar]
        var i = 0

        init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func skip() {
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" { i += 1; continue }
                if c == "/", i + 1 < scalars.count, scalars[i + 1] == "/" {
                    while i < scalars.count, scalars[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }

        mutating func token() throws -> String? {
            skip()
            guard i < scalars.count else { return nil }
            if scalars[i] == "{" || scalars[i] == "}" { defer { i += 1 }; return String(scalars[i]) }
            var out = String.UnicodeScalarView()
            if scalars[i] == "\"" {
                let start = i
                i += 1
                while true {
                    guard i < scalars.count else { throw ParseError.unterminated(at: start) }
                    let c = scalars[i]
                    i += 1
                    if c == "\"" { break }
                    if c == "\\", i < scalars.count {
                        let next = scalars[i]
                        i += 1
                        switch next {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(next)
                        }
                        continue
                    }
                    out.append(c)
                }
                return "\"" + String(out)
            }
            // Unquoted tokens end at whitespace or a brace.
            while i < scalars.count, !" \t\r\n{}\"".unicodeScalars.contains(scalars[i]) { out.append(scalars[i]); i += 1 }
            return "\"" + String(out)
        }

        mutating func entries(topLevel: Bool) throws -> [(key: String, value: VDF)] {
            var result: [(key: String, value: VDF)] = []
            while true {
                let start = i
                guard let key = try token() else {
                    if topLevel { return result }
                    throw ParseError.unterminated(at: start)
                }
                if key == "}" {
                    if topLevel { throw ParseError.unexpected("}", at: start) }
                    return result
                }
                guard key.hasPrefix("\"") else { throw ParseError.unexpected(key, at: start) }
                let valueStart = i
                guard let value = try token() else { throw ParseError.unterminated(at: valueStart) }
                if value == "{" {
                    result.append((String(key.dropFirst()), .block(try entries(topLevel: false))))
                } else if value.hasPrefix("\"") {
                    result.append((String(key.dropFirst()), .value(String(value.dropFirst()))))
                } else {
                    throw ParseError.unexpected(value, at: valueStart)
                }
            }
        }
    }
}
