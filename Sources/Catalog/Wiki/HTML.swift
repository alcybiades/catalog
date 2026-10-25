import Foundation

/// A minimal DOM for MediaWiki's parser output, which is always serialized
/// well-formed (RemexHtml), so a tolerant stack parser is enough.
final class HTMLNode {
    let tag: String          // lowercase element name; "#text" for text nodes
    let attributes: [String: String]
    let text: String
    private(set) var children: [HTMLNode] = []
    private(set) weak var parent: HTMLNode?
    private lazy var classSet: Set<Substring> = Set((attributes["class"] ?? "").split(separator: " "))

    init(tag: String, attributes: [String: String] = [:], text: String = "") {
        self.tag = tag
        self.attributes = attributes
        self.text = text
    }

    var isText: Bool { tag == "#text" }

    func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    func hasClass(_ name: String) -> Bool { classSet.contains(Substring(name)) }

    func hasAnyClass(_ names: Set<Substring>) -> Bool { !classSet.isDisjoint(with: names) }

    func classContains(_ fragment: String) -> Bool {
        (attributes["class"] ?? "").contains(fragment)
    }

    subscript(attribute: String) -> String? { attributes[attribute] }

    var isHidden: Bool { styleContains("display:none") }

    /// Absolutely positioned content (timelines, charts, image overlays) only
    /// makes sense drawn in place; read as text it's a stream of labels.
    var isAbsolutelyPositioned: Bool { styleContains("position:absolute") }

    private func styleContains(_ declaration: String) -> Bool {
        guard let style = attributes["style"] else { return false }
        return style.replacingOccurrences(of: " ", with: "").lowercased().contains(declaration)
    }

    var textContent: String {
        if isText { return text }
        var out = ""
        collectText(into: &out)
        return out
    }

    private func collectText(into out: inout String) {
        for child in children {
            if child.isText { out += child.text } else { child.collectText(into: &out) }
        }
    }

    func first(where predicate: (HTMLNode) -> Bool) -> HTMLNode? {
        for child in children where !child.isText {
            if predicate(child) { return child }
            if let found = child.first(where: predicate) { return found }
        }
        return nil
    }

    func all(where predicate: (HTMLNode) -> Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        collect(where: predicate, into: &out)
        return out
    }

    private func collect(where predicate: (HTMLNode) -> Bool, into out: inout [HTMLNode]) {
        for child in children where !child.isText {
            if predicate(child) { out.append(child) }
            child.collect(where: predicate, into: &out)
        }
    }

    func isInside(_ predicate: (HTMLNode) -> Bool) -> Bool {
        var node = parent
        while let current = node {
            if predicate(current) { return true }
            node = current.parent
        }
        return false
    }
}

enum HTMLParser {
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    private static let rawTextElements: Set<String> = ["script", "style"]

    static func parse(_ html: String) -> HTMLNode {
        let bytes = Array(html.utf8)
        let count = bytes.count
        let root = HTMLNode(tag: "#root")
        var stack: [HTMLNode] = [root]
        var i = 0

        @inline(__always) func isNameByte(_ b: UInt8) -> Bool {
            (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x3A || b == 0x5F
        }
        @inline(__always) func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D || b == 0x0C }
        @inline(__always) func isLetter(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) }

        func string(_ start: Int, _ end: Int) -> String {
            String(decoding: bytes[start..<end], as: UTF8.self)
        }

        func find(_ needle: [UInt8], from start: Int) -> Int? {
            guard !needle.isEmpty, start < count else { return nil }
            var j = start
            let last = count - needle.count
            while j <= last {
                if bytes[j] == needle[0] {
                    var k = 1
                    while k < needle.count && bytes[j + k] == needle[k] { k += 1 }
                    if k == needle.count { return j }
                }
                j += 1
            }
            return nil
        }

        func findCaseInsensitive(_ needle: String, from start: Int) -> Int? {
            let lower = Array(needle.utf8)
            var j = start
            while j + lower.count <= count {
                var k = 0
                while k < lower.count {
                    var b = bytes[j + k]
                    if b >= 0x41 && b <= 0x5A { b += 0x20 }
                    if b != lower[k] { break }
                    k += 1
                }
                if k == lower.count { return j }
                j += 1
            }
            return nil
        }

        while i < count {
            if bytes[i] == 0x3C /* < */, i + 1 < count {
                let next = bytes[i + 1]
                if next == 0x21 /* ! */ {
                    // Comment or doctype.
                    if i + 3 < count, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {
                        i = (find(Array("-->".utf8), from: i + 4).map { $0 + 3 }) ?? count
                    } else {
                        i = (find([0x3E], from: i).map { $0 + 1 }) ?? count
                    }
                    continue
                }
                if next == 0x2F /* / */ {
                    var j = i + 2
                    let nameStart = j
                    while j < count, isNameByte(bytes[j]) { j += 1 }
                    let name = string(nameStart, j).lowercased()
                    i = (find([0x3E], from: j).map { $0 + 1 }) ?? count
                    if let index = stack.lastIndex(where: { $0.tag == name }), index > 0 {
                        stack.removeSubrange(index...)
                    }
                    continue
                }
                if isLetter(next) {
                    var j = i + 1
                    let nameStart = j
                    while j < count, isNameByte(bytes[j]) { j += 1 }
                    let name = string(nameStart, j).lowercased()
                    var attributes: [String: String] = [:]
                    var selfClosing = false
                    // Attributes
                    while j < count {
                        while j < count, isSpace(bytes[j]) { j += 1 }
                        guard j < count else { break }
                        let b = bytes[j]
                        if b == 0x3E { j += 1; break }
                        if b == 0x2F { selfClosing = true; j += 1; continue }
                        let attrStart = j
                        while j < count, !isSpace(bytes[j]), bytes[j] != 0x3D, bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
                        let attrName = string(attrStart, j).lowercased()
                        while j < count, isSpace(bytes[j]) { j += 1 }
                        var value = ""
                        if j < count, bytes[j] == 0x3D {
                            j += 1
                            while j < count, isSpace(bytes[j]) { j += 1 }
                            if j < count, bytes[j] == 0x22 || bytes[j] == 0x27 {
                                let quote = bytes[j]
                                let valueStart = j + 1
                                var k = valueStart
                                while k < count, bytes[k] != quote { k += 1 }
                                value = HTMLEntities.decode(string(valueStart, k))
                                j = min(k + 1, count)
                            } else {
                                let valueStart = j
                                while j < count, !isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                                value = HTMLEntities.decode(string(valueStart, j))
                            }
                        }
                        if !attrName.isEmpty { attributes[attrName] = value }
                        if j == attrStart { j += 1 } // never stall on stray bytes
                    }
                    i = j
                    let node = HTMLNode(tag: name, attributes: attributes)
                    stack[stack.count - 1].append(node)
                    if rawTextElements.contains(name) {
                        // Skip the element's raw contents entirely.
                        if let end = findCaseInsensitive("</\(name)", from: i) {
                            i = (find([0x3E], from: end).map { $0 + 1 }) ?? count
                        } else {
                            i = count
                        }
                        continue
                    }
                    if !selfClosing && !voidElements.contains(name) {
                        stack.append(node)
                    }
                    continue
                }
            }
            // Text run up to the next tag.
            let start = i
            i += 1
            while i < count, bytes[i] != 0x3C { i += 1 }
            var text = string(start, i)
            if text.contains("&") { text = HTMLEntities.decode(text) }
            stack[stack.count - 1].append(HTMLNode(tag: "#text", text: text))
        }
        return root
    }
}

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "times": "×", "divide": "÷", "minus": "−",
        "plusmn": "±", "deg": "°", "prime": "′", "Prime": "″", "copy": "©", "reg": "®", "trade": "™",
        "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡", "thinsp": "\u{2009}", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{00AD}", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²",
        "sup3": "³", "micro": "µ", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "infin": "∞", "alpha": "α", "beta": "β",
        "gamma": "γ", "delta": "δ", "pi": "π", "sigma": "σ", "mu": "μ", "lambda": "λ", "theta": "θ",
        "omega": "ω", "Omega": "Ω", "Delta": "Δ", "Sigma": "Σ", "iexcl": "¡", "iquest": "¿",
    ]

    static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        output.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]
            if ch == "&",
               let semicolon = input[index...].prefix(12).firstIndex(of: ";") {
                let entity = input[input.index(after: index)..<semicolon]
                if let decoded = decodeEntity(entity) {
                    output += decoded
                    index = input.index(after: semicolon)
                    continue
                }
            }
            output.append(ch)
            index = input.index(after: index)
        }
        return output
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[String(entity)]
    }
}
