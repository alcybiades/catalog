import Foundation

/// Turns Wikipedia's TeX (the alt text of its math images) into readable
/// Unicode: `a^{2}+b^{2}=c^{2}` → `a²+b²=c²`, `\frac{1}{2}` → `1/2`.
enum MathText {
    static func latex(from node: HTMLNode) -> String {
        if let math = node.first(where: { $0.tag == "math" }), let alt = math["alttext"], !alt.isEmpty { return alt }
        if let img = node.first(where: { $0.tag == "img" }), let alt = img["alt"], !alt.isEmpty { return alt }
        if node.tag == "img", let alt = node["alt"] { return alt }
        return node.textContent
    }

    static func readable(_ tex: String) -> String {
        var source = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        for wrapper in ["{\\displaystyle", "{\\textstyle", "{\\scriptstyle"] where source.hasPrefix(wrapper) && source.hasSuffix("}") {
            source = String(source.dropFirst(wrapper.count).dropLast())
            break
        }
        var parser = Parser(Array(source))
        let output = parser.parseSequence(until: nil)
        return output
            // Breathing room around relations: "e = mc²", "x → ∞".
            .replacingOccurrences(of: "\\s*([=<>≤≥≠≈≡→←⇒⇐⇔↔↦∼≃≅∝∈∉⊂⊆⊃⊇])\\s*", with: " $1 ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Super/subscripts

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ",
        "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ",
        "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
        "z": "ᶻ", "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ",
        "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
        " ": " ", "′": "′", "∗": "*", "*": "*",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ",
        "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ", " ": " ",
    ]

    /// Unicode superscript form of `text`, or nil when a character has none.
    static func superscripted(_ text: String) -> String? { map(text, superscripts) }
    static func subscripted(_ text: String) -> String? { map(text, subscripts) }

    private static func map(_ text: String, _ table: [Character: Character]) -> String? {
        var out = ""
        for ch in text {
            guard let mapped = table[ch] else { return nil }
            out.append(mapped)
        }
        return out
    }

    // MARK: TeX parsing

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ",
        "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ",
        "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω", "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤",
        "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑",
        "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "implies": "⇒", "Leftrightarrow": "⇔", "iff": "⇔",
        "leftrightarrow": "↔", "mapsto": "↦", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂",
        "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩", "bigcup": "⋃",
        "bigcap": "⋂", "forall": "∀", "exists": "∃", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧",
        "lor": "∨", "vee": "∨", "oplus": "⊕", "otimes": "⊗", "emptyset": "∅", "varnothing": "∅",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "hbar": "ℏ", "ell": "ℓ",
        "circ": "∘", "angle": "∠", "perp": "⊥", "parallel": "∥", "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "vert": "|", "Vert": "‖", "mid": "∣",
        "aleph": "ℵ", "Re": "ℜ", "Im": "ℑ", "prime": "′", "star": "⋆", "ast": "∗", "bullet": "•",
        "degree": "°", "lbrace": "{", "rbrace": "}", "quad": "  ", "qquad": "    ", "colon": ":",
        "ll": "≪", "gg": "≫", "therefore": "∴", "because": "∵", "top": "⊤", "bot": "⊥", "dagger": "†",
        "sqcup": "⊔", "setminus": "∖", "smallsetminus": "∖", "wp": "℘", "S": "§", "P": "¶",
    ]
    private static let operators: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log",
        "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "dim", "ker", "deg",
        "gcd", "lcm", "arg", "mod", "bmod", "pmod", "Pr", "hom", "tr",
    ]
    private static let passthrough: Set<String> = [
        "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathscr", "mathfrak", "boldsymbol", "bm",
        "text", "textrm", "textbf", "textit", "textsf", "texttt", "operatorname", "mbox", "hbox", "mathnormal",
        "underline", "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "ensuremath", "mathord",
        "mathop", "mathrel", "mathbin", "overbrace", "underbrace", "phantom", "boxed",
    ]
    private static let textCommands: Set<String> = [
        "text", "textrm", "textbf", "textit", "textsf", "texttt", "mbox", "hbox", "operatorname", "mathrm",
    ]
    private static let ignored: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr",
        "Biggl", "Biggr", "limits", "nolimits", "middle", "begin", "end", "label", "nonumber", "notag",
    ]
    private static let blackboard: [Character: String] = [
        "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ", "H": "ℍ", "E": "𝔼", "F": "𝔽",
    ]
    private static let accents: [String: String] = [
        "vec": "\u{20D7}", "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0305}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}", "dot": "\u{0307}", "ddot": "\u{0308}",
    ]

    private struct Parser {
        let chars: [Character]
        var index = 0
        /// TeX ignores spaces in math; only text commands keep them.
        var preserveSpaces = false

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }

        mutating func parseSequence(until terminator: Character?) -> String {
            var out = ""
            while !atEnd {
                let ch = chars[index]
                if let terminator, ch == terminator { index += 1; return out }
                switch ch {
                case "{":
                    index += 1
                    out += parseSequence(until: "}")
                case "}":
                    index += 1
                case "^", "_":
                    index += 1
                    // TeX ignores the space in "\\sum _{i}"; so do we.
                    while out.last == " " { out.removeLast() }
                    let argument = parseArgument()
                    out += script(argument, superscript: ch == "^")
                case "\\":
                    out += parseCommand()
                case "&", "~":
                    index += 1
                    out += " "
                case " ", "\n", "\t":
                    index += 1
                    if preserveSpaces { out += " " }
                default:
                    index += 1
                    out.append(ch == "-" ? "−" : ch)
                }
            }
            return out
        }

        /// One TeX argument: a braced group, a command, or a single character.
        mutating func parseArgument() -> String {
            while !atEnd, chars[index] == " " { index += 1 }
            guard !atEnd else { return "" }
            let ch = chars[index]
            if ch == "{" {
                index += 1
                return parseSequence(until: "}")
            }
            if ch == "\\" { return parseCommand() }
            index += 1
            return String(ch == "-" ? "−" : ch)
        }

        mutating func parseOptionalArgument() -> String? {
            guard !atEnd, chars[index] == "[" else { return nil }
            index += 1
            return parseSequence(until: "]")
        }

        mutating func parseCommand() -> String {
            index += 1 // backslash
            guard !atEnd else { return "" }
            let first = chars[index]
            if !first.isLetter {
                index += 1
                switch first {
                case ",", ":", ";", " ": return " "
                case "!": return ""
                case "\\": return " "
                case "{", "}", "|", "%", "$", "#", "_", "&": return String(first)
                default: return String(first)
                }
            }
            var name = ""
            while !atEnd, chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            if name == "frac" || name == "dfrac" || name == "tfrac" {
                let numerator = parseArgument()
                let denominator = parseArgument()
                return "\(wrap(numerator))/\(wrap(denominator))"
            }
            if name == "sqrt" {
                let degree = parseOptionalArgument()
                let radicand = parseArgument()
                let root = "√" + wrap(radicand)
                if let degree, let small = MathText.superscripted(degree) { return small + root }
                return root
            }
            if name == "binom" {
                let n = parseArgument()
                let k = parseArgument()
                return "C(\(n), \(k))"
            }
            if name == "mathbb" {
                let argument = parseArgument()
                return argument.map { MathText.blackboard[$0] ?? String($0) }.joined()
            }
            if let accent = MathText.accents[name] {
                let argument = parseArgument()
                return argument.count == 1 ? argument + accent : argument
            }
            if MathText.textCommands.contains(name) {
                let saved = preserveSpaces
                preserveSpaces = true
                defer { preserveSpaces = saved }
                return parseArgument()
            }
            if MathText.passthrough.contains(name) { return parseArgument() }
            if name == "begin" || name == "end" {
                _ = parseArgument()
                return " "
            }
            if MathText.ignored.contains(name) { return "" }
            if MathText.operators.contains(name) { return " " + name + " " }
            if let symbol = MathText.symbols[name] { return symbol }
            return name
        }

        func wrap(_ text: String) -> String {
            let simple = text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || "²³¹⁰⁴⁵⁶⁷⁸⁹".contains($0) }
            return simple ? text : "(\(text))"
        }

        func script(_ text: String, superscript: Bool) -> String {
            let converted = superscript ? MathText.superscripted(text) : MathText.subscripted(text)
            if let converted { return converted }
            if text.count == 1 { return (superscript ? "^" : "_") + text }
            return (superscript ? "^(" : "_(") + text + ")"
        }
    }
}
