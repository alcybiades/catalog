import AppKit

precondition(AppState.isTesting, "Compile with -D CATALOG_TESTING before running behavior tests")

// Headless behavior tests for the editor's list/formatting logic.
// Run with `make test`.

_ = NSApplication.shared

func makeTV(_ content: String, caret: Int) -> EditorTextView {
    let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    tv.configure()
    tv.textStorage?.setAttributedString(NSAttributedString(string: content, attributes: Theme.baseAttributes))
    tv.setSelectedRange(NSRange(location: caret, length: 0))
    return tv
}

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  got:  \(got.debugDescription)\n  want: \(want.debugDescription)") }
}
func checkTrue(_ name: String, _ condition: Bool) {
    if condition { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)") }
}

let originalBodyFamily = Theme.fontFamily
let originalInterfaceFamily = Theme.interfaceFontFamily
Theme.fontFamily = "Body Test Family"
Theme.interfaceFontFamily = "Interface Test Family"
check("body and interface font preferences are independent", Theme.fontFamily, "Body Test Family")
check("interface font preference persists independently", Theme.interfaceFontFamily, "Interface Test Family")
Theme.fontFamily = originalBodyFamily
Theme.interfaceFontFamily = originalInterfaceFamily

let originalBoldColor = Theme.bold
let originalItalicColor = Theme.italic
Theme.bold = NSColor(hex: 0x123456)
Theme.italic = NSColor(hex: 0x654321)
check("bold semantic color persists", Theme.bold?.rgbHexString ?? "", "123456")
check("italic semantic color persists", Theme.italic?.rgbHexString ?? "", "654321")
Theme.bold = nil
checkTrue("semantic color supports no color", Theme.bold == nil)
Theme.bold = originalBoldColor
Theme.italic = originalItalicColor

var tv = makeTV("- hello", caret: 7)
tv.insertNewline(nil)
check("bullet continue", tv.string, "- hello\n- ")

tv = makeTV("- hello\n- ", caret: 10)
tv.insertNewline(nil)
check("empty bullet exits", tv.string, "- hello\n")

tv = makeTV("1. one", caret: 6)
tv.insertNewline(nil)
check("ordered increment", tv.string, "1. one\n2. ")

tv = makeTV("- [ ] task", caret: 10)
tv.insertNewline(nil)
check("task continue", tv.string, "- [ ] task\n- [ ] ")

tv = makeTV("> quoted", caret: 8)
tv.insertNewline(nil)
check("quote continue", tv.string, "> quoted\n> ")

tv = makeTV("plain text", caret: 10)
tv.insertNewline(nil)
check("plain newline", tv.string, "plain text\n")

tv = makeTV("# Heading\nBody", caret: 0)
tv.rehighlight()
let headingStyle = tv.textStorage?.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
checkTrue("heading has space before", (headingStyle?.paragraphSpacingBefore ?? 0) > 0)
checkTrue("heading has space after", (headingStyle?.paragraphSpacing ?? 0) > 0)

tv = makeTV("- one\n- two", caret: 0)
tv.rehighlight()
let firstListStyle = tv.textStorage?.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
let secondListStyle = tv.textStorage?.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
checkTrue("first list item has no leading list gap", (firstListStyle?.paragraphSpacingBefore ?? 0) == 0)
checkTrue("adjacent list items have slight spacing", (secondListStyle?.paragraphSpacingBefore ?? 0) > 0)
check("bullet glyph substitution preserves markdown source", tv.string, "- one\n- two")
checkTrue("unordered marker renders with a bullet glyph",
          tv.textStorage?.attribute(.glyphInfo, at: 0, effectiveRange: nil) is NSGlyphInfo)

// Typing restyles only the edited lines; random edits (fences opening and
// closing, their languages changing, comments and strings spanning lines,
// list items appearing) must leave exactly what a full pass does.
do {
    var seed: UInt64 = 0x5EED
    func random(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(max(n, 1)))
    }
    let pieces = ["```\n", "~~~\n", "```", "```swift\n", "```py\n", "~~~json\n", "sh", "- item\n", "1. one\n",
                  "  - [ ] task\n", "> quote *i*\n", "# Head\n", "text **b** `c` [l](x) [[w]]\n", "---\n", "\n",
                  "func f() {}\n", "import os\n", "{\"k\": 1}\n", "/* c", "*/", "\"\"\"", "# x\n",
                  "-", " ", "*", "`", "x", "\""]
    // NSGlyphInfo compares by identity; compare the glyph it draws.
    func normalized(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.glyphInfo, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let info = value as? NSGlyphInfo else { return }
            copy.addAttribute(.glyphInfo, value: "\(info.glyphID) \(info.baseString)", range: range)
        }
        return copy
    }
    let tv = makeTV((0..<40).map { _ in pieces[random(pieces.count)] }.joined(), caret: 0)
    tv.rehighlight()
    var mismatch: String?
    for step in 0..<300 where mismatch == nil {
        for _ in 0...random(3) {  // edits between passes accumulate
            let length = tv.textStorage!.length
            let location = random(length + 1)
            let range = NSRange(location: location, length: random(4) == 0 ? min(random(12), length - location) : 0)
            let replacement = range.length > 0 && random(2) == 0 ? "" : pieces[random(pieces.count)]
            tv.textStorage!.replaceCharacters(in: range, with: replacement)
        }
        tv.highlightEdits()
        let incremental = normalized(tv.textStorage!)
        tv.rehighlight()
        if !incremental.isEqual(to: normalized(tv.textStorage!)) { mismatch = "step \(step): \(tv.string.debugDescription)" }
    }
    check("incremental highlighting matches a full pass", mismatch ?? "", "")
}

check("code language from info string or a cautious guess",
      [CodeLanguage(info: "py title=x"), CodeLanguage(info: "TS"), CodeLanguage(info: "{.zsh}"),
       CodeLanguage(info: "haskell"), CodeLanguage(info: "  ")].map { $0.map { "\($0)" } ?? "none" }
          .joined(separator: " ") + " | " +
      ["{", "#!/bin/zsh", "import os", "import SwiftUI", "const x = 1", "package main",
       "let x = 1", "Hello there"].map { "\(CodeLanguage.guess(firstLine: $0))" }.joined(separator: " "),
      "python javascript shell plain none | json shell python swift javascript go plain plain")

tv = makeTV("*italic*", caret: 1) // visually before the first character
tv.rehighlight()
tv.insertNewline(nil)
check("newline at italic start stays outside opener", tv.string, "\n*italic*")

tv = makeTV("*italic*", caret: 7) // visually after the last character
tv.rehighlight()
tv.insertNewline(nil)
check("newline at italic end stays outside closer", tv.string, "*italic*\n")

let nestedStyledStart = "<span style=\"color:#FF8A7A\">**[3]**</span>"
tv = makeTV(nestedStyledStart, caret: (nestedStyledStart as NSString).range(of: "[3]").location)
tv.rehighlight()
tv.insertNewline(nil)
check("newline at nested styled start stays outside all openers", tv.string,
      "\n<span style=\"color:#FF8A7A\">**[3]**</span>")

tv = makeTV("make this bold", caret: 0)
tv.setSelectedRange(NSRange(location: 5, length: 4))
tv.toggleBoldMD(nil)
check("bold wrap", tv.string, "make **this** bold")
tv.toggleBoldMD(nil)
check("bold unwrap", tv.string, "make this bold")

tv = makeTV("hello world", caret: 8)
tv.toggleBoldMD(nil)
check("bold word at caret", tv.string, "hello **world**")

// Full-line selection includes the trailing newline; delimiters must hug
// the text, not spill onto the next line.
tv = makeTV("whole line\nnext", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 11))
tv.toggleBoldMD(nil)
check("bold full line trims newline", tv.string, "**whole line**\nnext")

tv = makeTV("  padded selection  ", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 20))
tv.toggleBoldMD(nil)
check("bold trims spaces", tv.string, "  **padded selection**  ")

// Inline modifiers are applied independently to the visible content of each
// selected list item. A cross-item partial selection must not absorb either
// list marker or unselected text at its edges.
let partialListSelection = NSRange(location: 8, length: 12) // "beta\n- gamma"
tv = makeTV("- alpha beta\n- gamma delta", caret: 0)
tv.setSelectedRange(partialListSelection)
tv.toggleBoldMD(nil)
check("bold applies to exact partial ranges across bullets", tv.string,
      "- alpha **beta**\n- **gamma** delta")

tv = makeTV("- alpha beta\n- gamma delta", caret: 0)
tv.setSelectedRange(partialListSelection)
tv.toggleItalicMD(nil)
check("italic applies to exact partial ranges across bullets", tv.string,
      "- alpha *beta*\n- *gamma* delta")

tv = makeTV("- alpha beta\n- gamma delta", caret: 0)
tv.setSelectedRange(partialListSelection)
tv.toggleCodeMD(nil)
check("code applies to exact partial ranges across bullets", tv.string,
      "- alpha `beta`\n- `gamma` delta")

tv = makeTV("- one\n- two\n- three", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
tv.toggleBoldMD(nil)
check("bold applies separately across complete bullet items", tv.string,
      "- **one**\n- **two**\n- **three**")

// Color spans: apply, swap, and remove by reapplying.
tv = makeTV("color me", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 8))
tv.applyColor(hex: "FF5C5C")
check("color wrap", tv.string, "<span style=\"color:#FF5C5C\">color me</span>")
tv.applyColor(hex: "72A7FF")
check("color swap", tv.string, "<span style=\"color:#72A7FF\">color me</span>")
tv.applyColor(hex: "72A7FF")
check("color remove on reapply", tv.string, "color me")

tv = makeTV("- one\n- two\n- three", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 19))
tv.applyColor(hex: "FF5C5C")
check("color applies separately across bullet items", tv.string,
      "- <span style=\"color:#FF5C5C\">one</span>\n" +
      "- <span style=\"color:#FF5C5C\">two</span>\n" +
      "- <span style=\"color:#FF5C5C\">three</span>")
tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
tv.applyColor(hex: "FF5C5C")
check("color removes separately across bullet items", tv.string, "- one\n- two\n- three")

tv = makeTV("- alpha beta\n- gamma delta", caret: 0)
tv.setSelectedRange(partialListSelection)
tv.applyColor(hex: "FF5C5C")
check("color applies to exact partial ranges across bullets", tv.string,
      "- alpha <span style=\"color:#FF5C5C\">beta</span>\n" +
      "- <span style=\"color:#FF5C5C\">gamma</span> delta")

tv = makeTV("muted text", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 10))
tv.applyHalfOpacity()
check("half opacity wrap", tv.string, "<span style=\"opacity:0.5\">muted text</span>")
tv.applyHalfOpacity()
check("half opacity remove on reapply", tv.string, "muted text")

tv = makeTV("- alpha beta\n- gamma delta", caret: 0)
tv.setSelectedRange(partialListSelection)
tv.applyHalfOpacity()
check("half opacity applies to exact partial ranges across bullets", tv.string,
      "- alpha <span style=\"opacity:0.5\">beta</span>\n" +
      "- <span style=\"opacity:0.5\">gamma</span> delta")

tv = makeTV("<span style=\"color:#FF5C5C\">muted</span>", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 40))
tv.applyHalfOpacity()
check("half opacity replaces color", tv.string, "<span style=\"opacity:0.5\">muted</span>")

// A block with mixed colors is repainted, not wrapped around its existing
// spans — wrapping would nest tags the highlighter can't read.
tv = makeTV("hello <span style=\"color:#FF5C5C\">red</span> world", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 50))
tv.applyColor(hex: "72A7FF")
check("color overrides mixed block", tv.string,
      "<span style=\"color:#72A7FF\">hello red world</span>")

// Two spans of one color read as uniform, so reapplying it strips both.
tv = makeTV("<span style=\"color:#FF5C5C\">a</span><span style=\"color:#FF5C5C\">b</span>", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 72))
tv.applyColor(hex: "FF5C5C")
check("color remove across sibling spans", tv.string, "ab")

// Half-covered span: the uncovered tail keeps its color under its own tag
// instead of having the shared close tag stranded.
tv = makeTV("one <span style=\"color:#FF5C5C\">two three</span>", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 35))
tv.applyColor(hex: "72A7FF")
check("color splits partly covered span", tv.string,
      "<span style=\"color:#72A7FF\">one two</span><span style=\"color:#FF5C5C\"> three</span>")

// Spans nested by an earlier version collapse to one on the next apply.
tv = makeTV("<span style=\"color:#FF5C5C\">a<span style=\"color:#55E6A5\">b</span></span>", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 72))
tv.applyColor(hex: "72A7FF")
check("color flattens nested spans", tv.string, "<span style=\"color:#72A7FF\">ab</span>")

// WYSIWYG deletion: backspace after concealed markers removes the visible
// character, not invisible syntax; at a heading start it un-formats.
tv = makeTV("see **bold**", caret: 12)
tv.rehighlight()
tv.deleteBackward(nil)
check("backspace skips hidden delimiters", tv.string, "see **bol**")

tv = makeTV("# Title", caret: 2)
tv.rehighlight()
tv.deleteBackward(nil)
check("backspace at heading start unformats", tv.string, "Title")

tv = makeTV("**bold** tail", caret: 0)
tv.rehighlight()
tv.deleteForward(nil)
check("forward delete skips hidden delimiters", tv.string, "**old** tail")

tv = makeTV("Title line", caret: 3)
let item = NSMenuItem(); item.tag = 2
tv.setHeading(item)
check("heading set", tv.string, "## Title line")
item.tag = 1
tv.setHeading(item)
check("heading switch", tv.string, "# Title line")
item.tag = 1
tv.setHeading(item)
check("heading toggle off", tv.string, "Title line")

tv = makeTV("word", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 4))
tv.toggleItalicMD(nil)
check("italic wrap", tv.string, "*word*")

// Bold and italic are layers on the same text, not opaque characters.
tv = makeTV("*word*", caret: 3)
tv.toggleBoldMD(nil)
check("bold on italic layers", tv.string, "***word***")
tv.toggleBoldMD(nil)
check("bold off keeps italic", tv.string, "*word*")

tv = makeTV("**word**", caret: 4)
tv.toggleItalicMD(nil)
check("italic on bold layers", tv.string, "***word***")
tv.toggleItalicMD(nil)
check("italic off keeps bold", tv.string, "**word**")

tv = makeTV("***word***", caret: 5)
tv.toggleBoldMD(nil)
check("unbold combined span", tv.string, "*word*")

tv = makeTV("**word**", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 8))
tv.toggleBoldMD(nil)
check("unwrap with markers selected", tv.string, "word")

tv = makeTV("**word**", caret: 0)
tv.setSelectedRange(NSRange(location: 3, length: 3))
tv.toggleBoldMD(nil)
check("unbold from partial selection", tv.string, "word")

// A selection spanning styled and plain text flattens, then wraps whole.
tv = makeTV("**word** and", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 12))
tv.toggleBoldMD(nil)
check("bold mixed selection", tv.string, "**word and**")

tv = makeTV("*word* and", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 10))
tv.toggleBoldMD(nil)
check("bold mixed keeps italic layer", tv.string, "***word* and**")

tv = makeTV("**word** and", caret: 0)
tv.setSelectedRange(NSRange(location: 4, length: 8))
tv.toggleBoldMD(nil)
check("selection crossing span grows to it", tv.string, "**word and**")

// Sub-range of a span: only that range gets the new layer.
tv = makeTV("**one two**", caret: 0)
tv.setSelectedRange(NSRange(location: 2, length: 3))
tv.toggleItalicMD(nil)
check("italic on part of bold", tv.string, "***one* two**")

// Code spans: unwrap from caret, unwrap from selections, merge across spans.
tv = makeTV("run npm now", caret: 0)
tv.setSelectedRange(NSRange(location: 4, length: 3))
tv.toggleCodeMD(nil)
check("code wrap", tv.string, "run `npm` now")

tv = makeTV("run `npm` now", caret: 6)
tv.toggleCodeMD(nil)
check("code unwrap from caret", tv.string, "run npm now")

tv = makeTV("run `npm` now", caret: 0)
tv.setSelectedRange(NSRange(location: 4, length: 5))
tv.toggleCodeMD(nil)
check("code unwrap with markers selected", tv.string, "run npm now")

tv = makeTV("`a` and b", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 9))
tv.toggleCodeMD(nil)
check("code merges across spans", tv.string, "`a and b`")

tv = makeTV("- item", caret: 6)
tv.insertTab(nil)
check("tab indents list", tv.string, "  - item")
tv.setSelectedRange(NSRange(location: 8, length: 0))
tv.insertBacktab(nil)
check("backtab outdents", tv.string, "- item")

// Typing at the concealed end of an inline span continues its style.
func type(_ tv: EditorTextView, _ s: String) {
    tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
}

tv = makeTV("**bold**", caret: 8)
type(tv, "x")
check("continue bold at end", tv.string, "**boldx**")
type(tv, "y")
check("keep continuing bold", tv.string, "**boldxy**")

tv = makeTV("*word*", caret: 6)
type(tv, "x")
check("continue italic at end", tv.string, "*wordx*")

tv = makeTV("`code`", caret: 6)
type(tv, "x")
check("continue code at end", tv.string, "`codex`")

tv = makeTV("**bold** tail", caret: 8)
type(tv, "x")
check("continue bold mid-line", tv.string, "**boldx** tail")

tv = makeTV("**bold**", caret: 8)
type(tv, " ")
check("space stays outside span", tv.string, "**bold** ")
type(tv, "x")
check("bold resumes after space without exposed markers", tv.string, "**bold** **x**")

// The visual end can also be represented immediately before the concealed
// closer (as happens after typing/clicking). Space must still go outside it.
tv = makeTV("**bold**", caret: 6)
tv.rehighlight()
type(tv, " ")
check("space at bold content end stays outside", tv.string, "**bold** ")
type(tv, "x")
check("bold mode survives content-end space", tv.string, "**bold** **x**")

tv = makeTV("**bold** and", caret: 12)
type(tv, "x")
check("plain text after span unaffected", tv.string, "**bold** andx")

tv = makeTV("<span style=\"color:#FF0000\">red</span>", caret: 38)
type(tv, "x")
check("continue color span at end", tv.string, "<span style=\"color:#FF0000\">redx</span>")

tv = makeTV("**bold**", caret: 0)
type(tv, "x")
check("typing before span unaffected", tv.string, "x**bold**")

tv = makeTV("***word***", caret: 10)
type(tv, "x")
check("continue combined span at end", tv.string, "***wordx***")

// Formatting an empty caret is pending editor state, never a visible empty
// Markdown skeleton. Layers compose before the first character is typed.
tv = makeTV("", caret: 0)
tv.toggleBoldMD(nil)
check("empty bold has no skeleton", tv.string, "")
tv.toggleItalicMD(nil)
check("empty italic layers without skeleton", tv.string, "")
type(tv, "x")
check("pending bold italic materializes balanced", tv.string, "***x***")
type(tv, "y")
check("pending style continues within span", tv.string, "***xy***")
type(tv, " ")
check("pending style space remains valid", tv.string, "***xy*** ")
type(tv, "z")
check("pending style resumes after space", tv.string, "***xy*** ***z***")
tv.toggleItalicMD(nil)
type(tv, "q")
check("pending layer toggles off without rewriting prior text", tv.string, "***xy*** ***z*****q**")

tv = makeTV("start ", caret: 6)
tv.toggleItalicMD(nil)
check("italic after space has no skeleton", tv.string, "start ")
type(tv, "word")
check("italic after space wraps first input", tv.string, "start *word*")

// One arrow press crosses a concealed closing delimiter and advances to the
// next visible caret stop; there is no raw-marker-only stop.
tv = makeTV("**a** b", caret: 3)
tv.rehighlight()
tv.moveRight(nil)
check("right arrow skips closer", "\(tv.selectedRange().location)", "6")
tv = makeTV("**a** b", caret: 5)
tv.rehighlight()
tv.moveLeft(nil)
check("left arrow skips closer", "\(tv.selectedRange().location)", "2")

// Spans are atomic: typing at a span's visual start lands before it.
tv = makeTV("see `code` here", caret: 5)  // content start, after hidden `
tv.rehighlight()
type(tv, " ")
check("space at chip start goes before", tv.string, "see  `code` here")

tv = makeTV("see `code` here", caret: 5)
tv.rehighlight()
type(tv, "x")
check("letter at chip start goes before", tv.string, "see x`code` here")

tv = makeTV("say **bold** now", caret: 6)
tv.rehighlight()
type(tv, "x")
check("letter at bold start goes before", tv.string, "say x**bold** now")

// Deleting a span's only content removes the whole span, never `` or ****.
tv = makeTV("a `x` b", caret: 4)
tv.rehighlight()
tv.deleteBackward(nil)
check("backspace sole code char removes span", tv.string, "a  b")

tv = makeTV("a **x** b", caret: 5)
tv.rehighlight()
tv.deleteBackward(nil)
check("backspace sole bold char removes span", tv.string, "a  b")

tv = makeTV("a <span style=\"color:#FF0000\">x</span> b", caret: 31)
tv.rehighlight()
tv.deleteBackward(nil)
check("backspace sole colored char removes span", tv.string, "a  b")

tv = makeTV("a `x` b", caret: 3)
tv.rehighlight()
tv.deleteForward(nil)
check("fwd delete sole code char removes span", tv.string, "a  b")

// Selection endpoints are projected onto rendered characters. Accidentally
// including a concealed delimiter never expands a partial edit to the span.
tv = makeTV("a `code` b", caret: 0)
tv.rehighlight()
tv.setSelectedRange(NSRange(location: 2, length: 3))  // "`co"
tv.deleteBackward(nil)
check("delete across opening marker edits visible text only", tv.string, "a `de` b")

tv = makeTV("a `code` b", caret: 0)
tv.rehighlight()
tv.setSelectedRange(NSRange(location: 3, length: 4))  // "code" (all content)
tv.deleteBackward(nil)
check("delete full content takes delimiters", tv.string, "a  b")

// Typing over the full content keeps the span and replaces its text.
tv = makeTV("a `code` b", caret: 0)
tv.rehighlight()
tv.setSelectedRange(NSRange(location: 3, length: 4))
type(tv, "npm")
check("typing over content keeps chip", tv.string, "a `npm` b")

// Regression: a visually partial selection in this real-world combination
// used to swallow the entire bold heading when its raw range touched `**`.
let styledHeading = "<span style=\"color:#FF8A7A\">**[3]**</span> **Great IP and storytelling is still fundamental to great films and franchises** -"
tv = makeTV(styledHeading, caret: 0)
tv.rehighlight()
let headingNS = styledHeading as NSString
let partialStart = headingNS.range(of: "**Great IP")
tv.setSelectedRange(partialStart) // includes hidden opener, but only two words
tv.deleteBackward(nil)
check("partial bold delete preserves unselected heading", tv.string,
      "<span style=\"color:#FF8A7A\">**[3]**</span>  **and storytelling is still fundamental to great films and franchises** -")

tv = makeTV(styledHeading, caret: 0)
tv.rehighlight()
let tail = headingNS.range(of: "films and franchises**")
tv.setSelectedRange(tail) // includes hidden closer
type(tv, "stories")
check("partial bold replacement preserves rest and delimiters", tv.string,
      "<span style=\"color:#FF8A7A\">**[3]**</span> **Great IP and storytelling is still fundamental to great stories** -")

tv = makeTV("<span style=\"color:#FF8A7A\">**[3]**</span>", caret: 0)
tv.rehighlight()
tv.setSelectedRange((tv.string as NSString).range(of: "[3]"))
tv.deleteBackward(nil)
check("deleting nested visible content removes all empty wrappers", tv.string, "")

tv = makeTV("**alpha** and *omega*", caret: 0)
tv.rehighlight()
tv.setSelectedRange(NSRange(location: 3, length: 13)) // "lpha** and *om"
tv.deleteBackward(nil)
check("cross-style delete preserves balanced syntax", tv.string, "**a***mega*")

// Code block toggle: wrap paragraphs, unwrap from inside or from selection.
tv = makeTV("one\ntwo\nthree\n", caret: 5)
tv.rehighlight()
tv.toggleCodeBlockMD(nil)
check("code block wraps paragraph", tv.string, "one\n```\ntwo\n```\nthree\n")

tv = makeTV("one\n```\ntwo\n```\nthree\n", caret: 9)
tv.rehighlight()
tv.toggleCodeBlockMD(nil)
check("code block unwraps from inside", tv.string, "one\ntwo\nthree\n")

tv = makeTV("one\n```\ntwo\n```\nthree\n", caret: 0)
tv.rehighlight()
tv.setSelectedRange(NSRange(location: 4, length: 11))  // fences + content
tv.toggleCodeBlockMD(nil)
check("code block unwraps from full selection", tv.string, "one\ntwo\nthree\n")

tv = makeTV("only line", caret: 4)
tv.rehighlight()
tv.toggleCodeBlockMD(nil)
check("code block wraps at EOF without newline", tv.string, "```\nonly line\n```")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
