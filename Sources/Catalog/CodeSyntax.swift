import Foundation

/// Languages fenced code blocks are colored in; anything else is `.plain`.
enum CodeLanguage: Int {
    case plain, swift, python, javascript, json, shell, go, rust, c

    private static let aliases: [String: CodeLanguage] = [
        "swift": .swift,
        "python": .python, "py": .python, "python3": .python,
        "javascript": .javascript, "js": .javascript, "jsx": .javascript, "mjs": .javascript,
        "cjs": .javascript, "node": .javascript, "typescript": .javascript, "ts": .javascript, "tsx": .javascript,
        "json": .json, "jsonc": .json, "json5": .json,
        "sh": .shell, "bash": .shell, "zsh": .shell, "shell": .shell, "console": .shell,
        "shellsession": .shell, "terminal": .shell,
        "go": .go, "golang": .go,
        "rust": .rust, "rs": .rust,
        "c": .c, "h": .c, "cpp": .c, "c++": .c, "cc": .c, "cxx": .c, "hpp": .c,
        "objc": .c, "objective-c": .c, "objectivec": .c, "objcpp": .c,
    ]

    /// The language a fence's info string names (its first word, so
    /// "```swift title=x" counts); nil when there is none, plain when it
    /// names something unsupported.
    init?(info: String) {
        let word = info.drop { $0 == "`" || $0 == "~" || $0.isWhitespace || $0 == "{" || $0 == "." }
            .prefix { !$0.isWhitespace && $0 != "{" && $0 != "," && $0 != "}" }
        guard !word.isEmpty else { return nil }
        self = Self.aliases[word.lowercased()] ?? .plain
    }

    private static let guesses: [(CodeLanguage, NSRegularExpression)] = [
        (.json, #"^(\{|\[\s*([\[{"\d\-\]]|$))"#),
        (.python, #"^#!.*python"#),
        (.javascript, #"^#!.*node"#),
        (.swift, #"^#!.*swift"#),
        (.shell, #"^(#!|\$ |(sudo|brew|npm|npx|pnpm|yarn|pip3?|git|cd|ls|mkdir|curl|wget|echo|export|cargo|make|docker|apt|apt-get|chmod|xcrun|swift (build|run|test|package)|go (run|build|get|mod|test|install)) )"#),
        (.go, #"^package \w+\s*$"#),
        (.c, #"^(#include\b|#import <|int main\()"#),
        (.rust, #"^(fn \w|pub (fn|struct|enum|mod|use) |use \w+::|impl\b|#!?\[|let mut )"#),
        (.python, #"^(def \w+\(|async def |from [\w.]+ import |import [a-z_][\w.]*( as \w+)?\s*$|class \w+(\(.*\))?:\s*$|if __name__)"#),
        (.swift, #"^(import [A-Z]\w*\s*$|func \w|@main|@MainActor|@Observable|extension [A-Z]|protocol [A-Z]|guard )"#),
        (.javascript, #"^(const |function\b|export |import .+ from |import ['"]|.*\brequire\(|console\.|async function|['"]use strict)"#),
    ].map { ($0, try! NSRegularExpression(pattern: $1)) }

    /// A cautious guess from a block's first line when its fence names no
    /// language: a wrong guess reads worse than none, so most code stays plain.
    static func guess(firstLine line: String) -> CodeLanguage {
        let trimmed = line.drop(while: \.isWhitespace)
        guard !trimmed.isEmpty else { return .plain }
        let text = String(trimmed)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return guesses.first { $0.1.firstMatch(in: text, range: range) != nil }?.0 ?? .plain
    }
}

enum CodeToken { case keyword, string, comment, number, type, function }

/// Fenced-code state carried line to line, and stored on `.mdCodeBlock`:
/// the block's language and a comment or string left open across lines.
struct CodeState: Equatable {
    enum Carry: Int { case none, blockComment, tripleDouble, tripleSingle, backtick }
    var language: CodeLanguage
    var carry = Carry.none

    var attributeValue: Int { language.rawValue << 3 | carry.rawValue }
    init(language: CodeLanguage) { self.language = language }
    init?(attributeValue: Any?) {
        guard let value = attributeValue as? Int,
              let language = CodeLanguage(rawValue: value >> 3),
              let carry = Carry(rawValue: value & 7) else { return nil }
        self.language = language
        self.carry = carry
    }
}

/// A small per-language scanner: keywords, strings, comments, numbers,
/// capitalized types and called functions. Line-local apart from block
/// comments, triple-quoted strings and backtick strings.
private struct Grammar {
    var keywords: Set<String> = []
    var literals: Set<String> = ["true", "false"]
    var types: Set<String> = []
    var lineComment: String? = "//"
    var blockComments = true
    var quotes: Set<UInt16> = [quote, apostrophe]
    var tripleQuotes: Set<UInt16> = []
    var backtickStrings = false
    var capitalizedTypes = true
    var functions = true
    /// `@attribute`, `#directive`.
    var sigils: Set<UInt16> = []

    static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }
}

private let quote = UInt16(UInt8(ascii: "\"")), apostrophe = UInt16(UInt8(ascii: "'"))
private let backtick = UInt16(UInt8(ascii: "`")), backslash = UInt16(UInt8(ascii: "\\"))
private let slash = UInt16(UInt8(ascii: "/")), star = UInt16(UInt8(ascii: "*"))
private let dollar = UInt16(UInt8(ascii: "$")), hash = UInt16(UInt8(ascii: "#"))
private let at = UInt16(UInt8(ascii: "@")), dot = UInt16(UInt8(ascii: "."))
private let openParen = UInt16(UInt8(ascii: "(")), colon = UInt16(UInt8(ascii: ":"))
private let openBrace = UInt16(UInt8(ascii: "{")), closeBrace = UInt16(UInt8(ascii: "}"))
private let bang = UInt16(UInt8(ascii: "!"))

private let grammars: [CodeLanguage: Grammar] = {
    var swift = Grammar()
    swift.keywords = Grammar.words("associatedtype actor any as async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect init inout internal is lazy let mutating nonisolated open operator override private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet")
    swift.literals = ["true", "false", "nil"]
    swift.quotes = [quote]
    swift.tripleQuotes = [quote]
    swift.sigils = [at, hash]

    var python = Grammar()
    python.keywords = Grammar.words("and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return self try while with yield")
    python.literals = ["True", "False", "None"]
    python.lineComment = "#"
    python.blockComments = false
    python.tripleQuotes = [quote, apostrophe]
    python.sigils = [at]

    var javascript = Grammar()
    javascript.keywords = Grammar.words("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function get if implements import in instanceof interface keyof let namespace new of private protected public readonly return satisfies set static super switch this throw try type typeof var void while with yield")
    javascript.literals = ["true", "false", "null", "undefined", "NaN"]
    javascript.types = Grammar.words("any bigint boolean never number object string symbol unknown")
    javascript.backtickStrings = true
    javascript.sigils = [at]

    var json = Grammar()
    json.literals = ["true", "false", "null"]
    json.quotes = [quote]
    json.capitalizedTypes = false
    json.functions = false

    var shell = Grammar()
    shell.keywords = Grammar.words("alias break case continue declare do done elif else esac exit export fi for function if in local readonly return select source then unset until while")
    shell.literals = []
    shell.lineComment = "#"
    shell.blockComments = false
    shell.capitalizedTypes = false
    shell.functions = false

    var go = Grammar()
    go.keywords = Grammar.words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
    go.literals = ["true", "false", "nil", "iota"]
    go.types = Grammar.words("any bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr")
    go.backtickStrings = true

    var rust = Grammar()
    rust.keywords = Grammar.words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while")
    rust.types = Grammar.words("bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize")
    // 'a lifetimes would read as unterminated strings.
    rust.quotes = [quote]
    rust.sigils = [hash]

    var c = Grammar()
    c.keywords = Grammar.words("auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern float for friend goto if inline int long namespace new operator private protected public register return short signed sizeof static struct switch template this throw try typedef typename union unsigned using virtual void volatile while")
    c.literals = ["true", "false", "NULL", "nullptr", "YES", "NO", "nil"]
    c.sigils = [at, hash]

    return [.swift: swift, .python: python, .javascript: javascript, .json: json,
            .shell: shell, .go: go, .rust: rust, .c: c]
}()

enum CodeSyntax {
    /// Reports the colored tokens of one line inside a fenced block (in
    /// UTF-16 offsets from the line start) and updates `state.carry`.
    static func tokenize(_ line: String, state: inout CodeState, emit: (CodeToken, NSRange) -> Void) {
        guard let g = grammars[state.language] else { return }
        let s = Array(line.utf16)
        let n = s.count
        func at(_ i: Int) -> UInt16 { i < n ? s[i] : 0 }
        func emitRange(_ token: CodeToken, _ from: Int, _ to: Int) {
            if to > from { emit(token, NSRange(location: from, length: to - from)) }
        }
        func matches(_ word: [UInt16], at i: Int) -> Bool {
            i + word.count <= n && word.indices.allSatisfy { s[i + $0] == word[$0] }
        }
        /// The index just past `close` (unescaped) from `i`, or nil.
        func find(_ close: [UInt16], from i: Int, escapes: Bool = true) -> Int? {
            var j = i
            while j + close.count <= n {
                if escapes && s[j] == backslash { j += 2; continue }
                if matches(close, at: j) { return j + close.count }
                j += 1
            }
            return nil
        }
        func closer(_ carry: CodeState.Carry) -> [UInt16] {
            switch carry {
            case .blockComment: return [star, slash]
            case .tripleDouble: return [quote, quote, quote]
            case .tripleSingle: return [apostrophe, apostrophe, apostrophe]
            case .backtick, .none: return [backtick]
            }
        }

        var i = 0
        if state.carry != .none {
            let carry = state.carry
            let end = find(closer(carry), from: 0, escapes: carry != .blockComment)
            emitRange(carry == .blockComment ? .comment : .string, 0, end ?? n)
            guard let end else { return }
            state.carry = .none
            i = end
        }
        let lineComment = g.lineComment.map { Array($0.utf16) }
        while i < n {
            let ch = s[i]
            if let lineComment, ch == lineComment[0], matches(lineComment, at: i),
               state.language != .shell || i == 0 || isSpace(s[i - 1]) {
                emitRange(.comment, i, n)
                return
            }
            if g.blockComments, ch == slash, at(i + 1) == star {
                let end = find([star, slash], from: i + 2, escapes: false)
                emitRange(.comment, i, end ?? n)
                guard let end else { state.carry = .blockComment; return }
                i = end
                continue
            }
            if g.tripleQuotes.contains(ch), at(i + 1) == ch, at(i + 2) == ch {
                let end = find([ch, ch, ch], from: i + 3)
                emitRange(.string, i, end ?? n)
                guard let end else { state.carry = ch == quote ? .tripleDouble : .tripleSingle; return }
                i = end
                continue
            }
            if g.backtickStrings, ch == backtick {
                let end = find([backtick], from: i + 1)
                emitRange(.string, i, end ?? n)
                guard let end else { state.carry = .backtick; return }
                i = end
                continue
            }
            if g.quotes.contains(ch) {
                let end = find([ch], from: i + 1, escapes: !(state.language == .shell && ch == apostrophe)) ?? n
                var next = end
                while next < n, isSpace(s[next]) { next += 1 }
                // JSON keys take the keyword color.
                emitRange(state.language == .json && at(next) == colon ? .keyword : .string, i, end)
                i = end
                continue
            }
            if isDigit(ch), i == 0 || !isIdentifier(s[i - 1]) {
                var j = i + 1
                while j < n, isIdentifier(s[j]) || (s[j] == dot && isDigit(at(j + 1))) { j += 1 }
                emitRange(.number, i, j)
                i = j
                continue
            }
            if state.language == .shell, ch == dollar {
                var j = i + 1
                if at(j) == openBrace {
                    while j < n, s[j] != closeBrace { j += 1 }
                    j = min(j + 1, n)
                } else {
                    while j < n, isIdentifier(s[j]) { j += 1 }
                }
                if j > i + 1 { emitRange(.type, i, j) }
                i = max(j, i + 1)
                continue
            }
            if g.sigils.contains(ch), isIdentifierStart(at(i + 1)) {
                var j = i + 1
                while j < n, isIdentifier(s[j]) { j += 1 }
                emitRange(.keyword, i, j)
                i = j
                continue
            }
            if isIdentifierStart(ch) || (ch == dollar && state.language == .javascript) {
                var j = i + 1
                while j < n, isIdentifier(s[j]) || (s[j] == dollar && state.language == .javascript) { j += 1 }
                let word = String(decoding: s[i..<j], as: UTF16.self)
                // A member (`x.type`) is never a keyword.
                let member = i > 0 && s[i - 1] == dot
                if !member, g.keywords.contains(word) {
                    emitRange(.keyword, i, j)
                } else if g.literals.contains(word) {
                    emitRange(.number, i, j)
                } else if g.functions, at(j) == openParen || (state.language == .rust && at(j) == bang) {
                    emitRange(.function, i, j)
                } else if g.types.contains(word) || (g.capitalizedTypes && isUppercase(ch)) {
                    emitRange(.type, i, j)
                }
                i = j
                continue
            }
            i += 1
        }
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isUppercase(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }
    private static func isIdentifier(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
}
