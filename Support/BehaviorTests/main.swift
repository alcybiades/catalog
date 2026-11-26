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

// Embedded quotes: copied with the note's file and heading, pasted with
// links relative to the destination note.
let quoteBoard = NSPasteboard(name: NSPasteboard.Name("catalog-behavior-quotes-\(UUID().uuidString)"))
let sourceNote = URL(fileURLWithPath: "/tmp/Catalog Fixture/Notes/Field Guide.md")
tv = makeTV("# Field Guide\n\n## Second Section\n\nSome **bold** text here.\n", caret: 0)
tv.documentURLProvider = { sourceNote }
tv.rehighlight()
let boldStart = (tv.string as NSString).range(of: "bold").location
tv.setSelectedRange(NSRange(location: boldStart + 2, length: 9)) // "ld** text"
checkTrue("copy as embedded quote needs a selection", tv.copyEmbeddedQuote(to: quoteBoard))
let copiedQuote = EmbeddedQuote.read(from: quoteBoard)
check("a partly selected span is quoted whole", copiedQuote?.body ?? "", "**bold** text")
check("the quote names its note and heading", copiedQuote?.label ?? "", "Field Guide § Second Section")
check("plain-text pastes elsewhere get an absolute link", quoteBoard.string(forType: .string) ?? "",
      "> **bold** text\n> — [Field Guide § Second Section](/tmp/Catalog%20Fixture/Notes/Field%20Guide.md#second-section)")
tv.setSelectedRange(NSRange(location: 0, length: 0))
checkTrue("no selection, no quote", !tv.copyEmbeddedQuote(to: quoteBoard))
tv = makeTV("Untitled text", caret: 0)
tv.setSelectedRange(NSRange(location: 0, length: 8))
var saveRequested = false
tv.onRequestSave = { saveRequested = true }
checkTrue("an untitled note asks to be saved before quoting", !tv.copyEmbeddedQuote(to: quoteBoard) && saveRequested)

tv = makeTV("Intro\nOutro", caret: 5)
tv.documentURLProvider = { URL(fileURLWithPath: "/tmp/Catalog Fixture/Boards/Plan.md") }
EmbeddedQuote.write(copiedQuote!, to: quoteBoard)
checkTrue("pasting a quote is handled", tv.pasteEmbeddedQuote(from: quoteBoard))
check("pasted quotes link relative to the destination note and stand apart", tv.string,
      "Intro\n\n> **bold** text\n> — [Field Guide § Second Section](../Notes/Field%20Guide.md#second-section)\n\nOutro")

// The caret entering a quote reveals its syntax; leaving conceals it again.
tv = makeTV("Before\n\n> Quoted line.\n> — [Guide](Guide.md)\n\nAfter", caret: 0)
tv.rehighlight()
let quotedAt = (tv.string as NSString).range(of: "Quoted").location
func markerHidden(_ tv: EditorTextView, _ location: Int) -> Bool {
    tv.textStorage?.attribute(.mdMarker, at: location, effectiveRange: nil) != nil
}
checkTrue("quote syntax is concealed away from the caret", markerHidden(tv, quotedAt - 2))
tv.setSelectedRange(NSRange(location: quotedAt + 3, length: 0))
checkTrue("quote syntax shows with the caret inside", !markerHidden(tv, quotedAt - 2))
tv.setSelectedRange(NSRange(location: 0, length: 0))
checkTrue("quote syntax hides again when the caret leaves", markerHidden(tv, quotedAt - 2))
tv.setSelectedRange(NSRange(location: quotedAt + 3, length: 0))
tv.insertText("x", replacementRange: tv.selectedRange())
check("typing in a revealed quote edits its text", tv.string, "Before\n\n> Quoxted line.\n> — [Guide](Guide.md)\n\nAfter")
var typedRun = NSRange()
let typedStorage = tv.textStorage!
_ = typedStorage.attribute(.mdQuoteCard, at: quotedAt, longestEffectiveRange: &typedRun,
                           in: NSRange(location: 0, length: typedStorage.length))
check("the card still spans its block after an edit", (tv.string as NSString).substring(with: typedRun),
      "> Quoxted line.\n> — [Guide](Guide.md)\n")
quoteBoard.releaseGlobally()


// MARK: - Live agent edits: diffs and their animation steps

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

var rng = SeededRandom(state: 47)
let vocabulary = ["the", "quick", "brown", "fox", " ", " ", "\n", "\n\n", "# ", "**bold**", "- ", "> ", "`code`",
                  "naïve", "café", "日本語", "👍🏽", "e\u{301}", "\r\n", "[link](a.md)", ".", ",", "Ünïcödé", "🇯🇵"]
func randomText(_ count: Int) -> String {
    (0..<count).map { _ in vocabulary.randomElement(using: &rng)! }.joined()
}
/// A rewrite of `text`: words swapped, cut, and added at random spots.
func mutate(_ text: String) -> String {
    var pieces = Array(text)
    for _ in 0..<Int.random(in: 0...6, using: &rng) {
        let op = Int.random(in: 0...2, using: &rng)
        let at = pieces.isEmpty ? 0 : Int.random(in: 0...pieces.count, using: &rng)
        switch op {
        case 0: pieces.insert(contentsOf: Array(randomText(Int.random(in: 1...5, using: &rng))), at: at)
        case 1 where !pieces.isEmpty && at < pieces.count:
            pieces.removeSubrange(at..<min(pieces.count, at + Int.random(in: 1...12, using: &rng)))
        default:
            if !pieces.isEmpty && at < pieces.count {
                pieces.replaceSubrange(at..<min(pieces.count, at + Int.random(in: 1...6, using: &rng)),
                                       with: Array(randomText(Int.random(in: 1...3, using: &rng))))
            }
        }
    }
    return String(pieces)
}

var diffFailures = 0, stepFailures = 0, chunkFailures = 0, budgetFailures = 0
for round in 0..<600 {
    let old = round % 7 == 0 ? "" : randomText(Int.random(in: 0...80, using: &rng))
    let new = round % 11 == 0 ? randomText(Int.random(in: 0...80, using: &rng)) : mutate(old)
    let edits = TextDiff.edits(from: old, to: new)
    if TextDiff.apply(edits, to: old) != new { diffFailures += 1 }
    let steps = LiveEditPlan.steps(for: edits, in: old)
    if LiveEditPlan.run(steps, on: old) != new { stepFailures += 1 }
    // Every intermediate frame stays valid UTF-16: no split surrogate pairs.
    var live = old as NSString
    for step in steps {
        let next = NSMutableString(string: live as String)
        switch step {
        case .reveal: break
        case .delete(let range): next.deleteCharacters(in: range)
        case .insert(let location, let text): next.insert(text, at: location)
        }
        live = next
        if String(live).utf16.count != live.length || (live as String).unicodeScalars.contains(where: { $0.value == 0xFFFD }) {
            chunkFailures += 1; break
        }
    }
    if steps.count > LiveEditPlan.maxFrames * 2 { budgetFailures += 1 }
}
check("random edits: the diff rebuilds the target", "\(diffFailures)", "0")
check("random edits: animation frames end exactly on the target", "\(stepFailures)", "0")
check("random edits: frames never split a character", "\(chunkFailures)", "0")
check("random edits: animation stays within its frame budget", "\(budgetFailures)", "0")

let wordEdit = TextDiff.edits(from: "I like apple pie.\n", to: "I like banana pie.\n")
check("a changed word retypes whole", "\(wordEdit.map { "\($0.range.location),\($0.range.length)→\($0.replacement)" })", "[\"7,5→banana\"]")
let phrase = TextDiff.edits(from: "the quick brown fox", to: "a slow red fox")
check("nearby word changes read as one rewrite", "\(phrase.count)", "1")
let twoSpots = TextDiff.edits(from: "Alpha one.\n\nMiddle text stays.\n\nOmega two.\n", to: "Alpha 1.\n\nMiddle text stays.\n\nOmega 2.\n")
check("separate changes stay separate", "\(twoSpots.map(\.replacement))", "[\"1\", \"2\"]")
check("identical texts need no edits", "\(TextDiff.edits(from: "same", to: "same").count)", "0")

// A big rewrite still finishes in the time budget, and quickly.
let bigOld = randomText(20000), bigNew = randomText(20000)
let started = Date()
let bigEdits = TextDiff.edits(from: bigOld, to: bigNew)
let bigSteps = LiveEditPlan.steps(for: bigEdits, in: bigOld)
check("a full rewrite diffs correctly", "\(TextDiff.apply(bigEdits, to: bigOld) == bigNew)", "true")
check("a full rewrite animates correctly", "\(LiveEditPlan.run(bigSteps, on: bigOld) == bigNew)", "true")
check("a full rewrite fits the frame budget", "\(bigSteps.count <= LiveEditPlan.maxFrames * 2)", "true")
check("a full rewrite plans in well under a second", "\(Date().timeIntervalSince(started) < 1.5)", "true")
let typing = LiveEditPlan.steps(for: TextDiff.edits(from: "", to: "Hello there"), in: "")
check("small insertions type at a natural pace", "\(typing.count)", "\(Int((11.0 / Double(LiveEditPlan.typePace)).rounded(.up)))")

// Three-way merge of unsaved edits with the assistant's.
check("merge keeps both sides' separate changes",
      TextDiff.merge(base: "One.\n\nTwo.\n\nThree.\n", mine: "One!\n\nTwo.\n\nThree.\n", theirs: "One.\n\nTwo.\n\nThree, four.\n") ?? "nil",
      "One!\n\nTwo.\n\nThree, four.\n")
check("merge refuses overlapping changes",
      TextDiff.merge(base: "I like apple pie.", mine: "I like pear pie.", theirs: "I like banana pie.") ?? "nil", "nil")
check("merge with no local edits takes theirs", TextDiff.merge(base: "a", mine: "a", theirs: "b") ?? "nil", "b")
check("caret after an insertion moves with it", "\(LiveEditPlan.map(10, through: .insert(location: 4, text: "abc")))", "13")
check("caret inside a deletion lands at its start", "\(LiveEditPlan.map(6, through: .delete(NSRange(location: 4, length: 5))))", "4")

// MARK: - Tables

do {
    func parse(_ text: String, at location: Int = 0, quoted: Bool = false) -> MarkdownTable.Table? {
        MarkdownTable.table(containing: location, in: text as NSString, quoted: quoted)
    }
    func cellTexts(_ text: String, _ row: MarkdownTable.Row) -> String {
        row.cells.map { (text as NSString).substring(with: $0.content) }.joined(separator: ",")
    }

    let aligned = "| a | b | c | d |\n| --- | :-- | :-: | --: |\n| 1 | 2 | 3 | 4 |\n"
    let alignedTable = parse(aligned)
    check("table alignments from the delimiter row",
          alignedTable.map { $0.alignments.map { "\($0)" }.joined(separator: ",") } ?? "nil", "none,left,center,right")
    check("table rows and cells", alignedTable.map { t in t.textRows.map { cellTexts(aligned, $0) }.joined(separator: " / ") } ?? "nil",
          "a,b,c,d / 1,2,3,4")
    check("table spans header through last body row", alignedTable.map { NSStringFromRange($0.range) } ?? "nil",
          NSStringFromRange(NSRange(location: 0, length: (aligned as NSString).length)))

    let escaped = "| a \\| b | `x \\| y` |\n|---|---|\n| one \\| two | three |"
    check("escaped pipes stay inside cells",
          parse(escaped).map { t in t.textRows.map { cellTexts(escaped, $0) }.joined(separator: " / ") } ?? "nil",
          "a \\| b,`x \\| y` / one \\| two,three")

    let ragged = "| h1 | h2 | h3 |\n| - | - | - |\n| only |\n| a | b | c | extra |\n|  | | |"
    let raggedTable = parse(ragged)
    check("ragged rows keep their own cells",
          raggedTable.map { t in t.bodyRows.map { cellTexts(ragged, $0) }.joined(separator: " / ") } ?? "nil",
          "only / a,b,c,extra / ,,")
    checkTrue("an empty cell's caret sits inside its padding",
              raggedTable.map { t in t.rows[4].cells.allSatisfy { $0.content.length == 0 && $0.content.location >= $0.range.location && $0.content.location <= NSMaxRange($0.range) } } ?? false)

    let bare = "Name | Role\n--- | ---\nAda | Engineer\nGrace | Admiral"
    check("tables without leading or trailing pipes",
          parse(bare, at: 30).map { t in t.textRows.map { cellTexts(bare, $0) }.joined(separator: " / ") } ?? "nil",
          "Name,Role / Ada,Engineer / Grace,Admiral")

    checkTrue("a pipe in a paragraph is not a table", parse("Either this | or that.\nAnd more text.") == nil)
    checkTrue("a setext heading is not a table", parse("Title | x\n---") == nil)
    checkTrue("a delimiter row must match the header's cells", parse("| a | b |\n| --- |\n| 1 | 2 |") == nil)
    checkTrue("a delimiter needs dashes", parse("| a | b |\n| x | y |") == nil)
    checkTrue("a list item with pipes is not a header", parse("- a | b\n--- | ---") == nil)
    let afterParagraph = "Intro line\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter | text"
    let found = parse(afterParagraph, at: 12)
    check("a table starts at its header and ends at a blank line",
          found.map { (afterParagraph as NSString).substring(with: $0.range) } ?? "nil", "| a | b |\n|---|---|\n| 1 | 2 |\n")
    checkTrue("the paragraph line above a table isn't in it", parse(afterParagraph, at: 2) == nil)
    checkTrue("text after the blank line isn't in it", parse(afterParagraph, at: (afterParagraph as NSString).length - 2) == nil)
    let blockEnd = "| a |\n| - |\n| 1 |\n# Heading | x"
    check("another block ends a table", parse(blockEnd).map { "\($0.rows.count)" } ?? "nil", "3")
    let fenced = "```\n| a | b |\n|---|---|\n```\n\n| c |\n|---|\n"
    check("tables in fenced code are skipped",
          MarkdownTable.tables(in: fenced as NSString).map { (fenced as NSString).substring(with: $0.range) }.joined(), "| c |\n|---|\n")
    let quotedTable = "> | q | r |\n> | :-: | -- |\n> | 1 | 2 |\n> — [Src](Src.md)"
    check("tables inside a blockquote", parse(quotedTable, at: 2, quoted: true).map { t in t.textRows.map { cellTexts(quotedTable, $0) }.joined(separator: " / ") } ?? "nil",
          "q,r / 1,2 / — [Src](Src.md)")
    check("an embedded quote's attribution ends its table",
          MarkdownTable.table(containing: 2, in: quotedTable as NSString, quoted: true,
                              limit: (quotedTable as NSString).range(of: "> —").location).map { "\($0.rows.count)" } ?? "nil", "3")
    check("cell text is escaped", MarkdownTable.escapeCellText("a|b\nc \\| d"), "a\\|b c \\| d")
}

// Rendering and editing a table in place.
do {
    let source = "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| Ada | 1 |\n| Grace | 22 |\n\nAfter"
    func tableView(caretAfter needle: String, in text: String = source) -> EditorTextView {
        let tv = makeTV(text, caret: 0)
        tv.rehighlight()
        let found = (text as NSString).range(of: needle)
        tv.setSelectedRange(NSRange(location: NSMaxRange(found), length: 0))
        return tv
    }
    func block(_ tv: EditorTextView) -> TableBlock? {
        let at = (tv.string as NSString).range(of: "| Name").location
        return tv.textStorage?.attribute(.mdTable, at: at, effectiveRange: nil) as? TableBlock
    }
    var tv = tableView(caretAfter: "Ada")
    let pipe = (source as NSString).range(of: "| Ada").location
    checkTrue("table pipes are concealed", tv.textStorage?.attribute(.mdMarker, at: pipe, effectiveRange: nil) != nil)
    checkTrue("cell text is visible", tv.textStorage?.attribute(.mdMarker, at: pipe + 2, effectiveRange: nil) == nil)
    checkTrue("the delimiter row is concealed",
              tv.textStorage?.attribute(.mdMarker, at: (source as NSString).range(of: ":---").location, effectiveRange: nil) != nil)
    checkTrue("rows don't wrap", (tv.textStorage?.attribute(.paragraphStyle, at: pipe, effectiveRange: nil) as? NSParagraphStyle)?.lineBreakMode == .byClipping)
    let qtyEdge = block(tv)?.edges ?? []
    check("a table lays out one column per header cell", "\(qtyEdge.count)", "3")

    tv.insertText("m Lovelace", replacementRange: NSRange(location: NSNotFound, length: 0))
    check("typing in a cell edits that cell", tv.string,
          "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| Adam Lovelace | 1 |\n| Grace | 22 |\n\nAfter")
    checkTrue("typing a longer cell widens its column", (block(tv)?.edges[1] ?? 0) > (qtyEdge.count > 1 ? qtyEdge[1] : .infinity))
    tv.insertText("|", replacementRange: NSRange(location: NSNotFound, length: 0))
    check("a typed pipe is escaped", tv.string,
          "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| Adam Lovelace\\| | 1 |\n| Grace | 22 |\n\nAfter")
    checkTrue("an escaped pipe keeps the row's cells", block(tv)?.table.rows[2].cells.count == 2)

    tv = tableView(caretAfter: "| Ada")
    tv.setSelectedRange(NSRange(location: (source as NSString).range(of: "Ada").location, length: 0))
    tv.deleteBackward(nil)
    check("backspace at a cell's start keeps the row", tv.string, source)
    tv = tableView(caretAfter: "Ada")
    tv.deleteForward(nil)
    check("forward delete at a cell's end keeps the row", tv.string, source)
    tv.deleteBackward(nil)
    check("backspace inside a cell deletes text", tv.string, source.replacingOccurrences(of: "| Ada |", with: "| Ad |"))

    tv = tableView(caretAfter: "Ada")
    tv.moveRight(nil)
    check("→ at a cell's end goes to the next cell", "\(tv.selectedRange().location)", "\((source as NSString).range(of: "1 |").location)")
    tv.moveLeft(nil)
    check("← at a cell's start goes back to the previous cell", "\(tv.selectedRange().location)", "\(NSMaxRange((source as NSString).range(of: "Ada")))")

    tv = tableView(caretAfter: "| Ada ")
    check("a caret on concealed pipes moves into a cell", "\(tv.selectedRange().location)",
          "\(NSMaxRange((source as NSString).range(of: "Ada")))")

    tv = tableView(caretAfter: "Ada")
    tv.insertTab(nil)
    check("Tab goes to the end of the next cell", "\(tv.selectedRange().location)", "\(NSMaxRange((source as NSString).range(of: "| 1")))")
    tv.insertTab(nil)
    check("Tab at a row's end goes to the next row", "\(tv.selectedRange().location)", "\(NSMaxRange((source as NSString).range(of: "Grace")))")
    tv.insertBacktab(nil)
    check("Shift-Tab goes back a cell", "\(tv.selectedRange().location)", "\(NSMaxRange((source as NSString).range(of: "| 1")))")

    tv = tableView(caretAfter: "22")
    tv.insertTab(nil)
    check("Tab past the last cell adds a row", tv.string,
          "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| Ada | 1 |\n| Grace | 22 |\n|   |   |\n\nAfter")
    tv.insertText("Hopper", replacementRange: NSRange(location: NSNotFound, length: 0))
    check("typing in the new row fills its first cell", tv.string,
          "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| Ada | 1 |\n| Grace | 22 |\n| Hopper  |   |\n\nAfter")

    tv = tableView(caretAfter: "Ada")
    tv.insertNewline(nil)
    check("Return goes to the same column in the next row", "\(tv.selectedRange().location)",
          "\(NSMaxRange((source as NSString).range(of: "Grace")))")
    tv.insertNewline(nil)
    check("Return in the last row adds a row", tv.string,
          "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| Ada | 1 |\n| Grace | 22 |\n|   |   |\n\nAfter")
    tv.insertNewline(nil)
    check("Return in an empty last row leaves the table", tv.string, source.replacingOccurrences(of: "22 |\n", with: "22 |\n\n"))

    tv = tableView(caretAfter: "Ada")
    let adaStart = (source as NSString).range(of: "Ada").location
    tv.setSelectedRange(NSRange(location: adaStart + 1, length: NSMaxRange((source as NSString).range(of: "Gra")) - adaStart - 1))
    tv.deleteBackward(nil)
    check("deleting across cells keeps pipes and rows", tv.string,
          "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| A |  |\n| ce | 22 |\n\nAfter")

    tv = tableView(caretAfter: "Intro")
    let rows = (source as NSString).range(of: "| Ada | 1 |\n| Grace | 22 |\n")
    tv.setSelectedRange(rows)
    tv.deleteBackward(nil)
    check("deleting whole body rows removes them", tv.string,
          "Intro\n\n| Name | Qty |\n| :--- | ---: |\n\nAfter")

    // Undo restores the source exactly.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    tv = tableView(caretAfter: "Grace")
    window.contentView = tv
    tv.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
    tv.insertTab(nil)
    tv.insertTab(nil)
    tv.undoManager?.undo()
    tv.undoManager?.undo()
    check("undo restores a table's source", tv.string, source)

    // Revealing the delimiter row while typing it, and concealing it after.
    tv = makeTV("| a | b |\n", caret: 10)
    tv.rehighlight()
    tv.insertText("|---|---|", replacementRange: NSRange(location: NSNotFound, length: 0))
    checkTrue("a delimiter row being typed shows", tv.textStorage?.attribute(.mdMarker, at: 12, effectiveRange: nil) == nil)
    tv.insertNewline(nil)
    check("Return after typing a delimiter row starts a body row", tv.string, "| a | b |\n|---|---|\n|   |   |")
    checkTrue("the delimiter row conceals once the caret leaves", tv.textStorage?.attribute(.mdMarker, at: 12, effectiveRange: nil) != nil)
    tv.insertText("x|y", replacementRange: NSRange(location: NSNotFound, length: 0))
    check("a new row's cells take typing", tv.string, "| a | b |\n|---|---|\n| x\\|y  |   |")
}

// Incremental passes over text with tables match a full pass.
do {
    var seed: UInt64 = 0x7AB1E
    func random(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(max(n, 1)))
    }
    let pieces = ["| a | b |\n", "|---|:-:|\n", "| **x** | `y` |\n", "c | d\n", "--- | ---\n", "\n", "text\n", "|", " ",
                  "```\n", "> | q |\n", "> | - |\n", "> — [S](S.md)\n", "x", "-", "\\|", "# H\n"]
    func normalized(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.glyphInfo, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let info = value as? NSGlyphInfo else { return }
            copy.addAttribute(.glyphInfo, value: "\(info.glyphID) \(info.baseString)", range: range)
        }
        copy.enumerateAttribute(.mdQuoteCard, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let card = value as? QuoteCard else { return }
            copy.addAttribute(.mdQuoteCard, value: "card \(card.destination)", range: range)
        }
        copy.enumerateAttribute(.mdQuoteSource, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if value != nil { copy.addAttribute(.mdQuoteSource, value: "source", range: range) }
        }
        return copy
    }
    let tv = makeTV((0..<40).map { _ in pieces[random(pieces.count)] }.joined(), caret: 0)
    tv.rehighlight()
    var mismatch: String?
    for step in 0..<300 where mismatch == nil {
        for _ in 0...random(3) {
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
    check("incremental highlighting of tables matches a full pass", mismatch ?? "", "")
}

// A table wider than the page scrolls sideways within its frame.
do {
    let wide = (1...12).map { "Column \($0)" }
    let headerRow: String = "| " + wide.joined(separator: " | ") + " |"
    let delimiterRow: String = "|" + String(repeating: " --- |", count: 12)
    let cells: [String] = (1...12).map { "cell \($0)" }
    let bodyRow: String = "| " + cells.joined(separator: " | ") + " |"
    let source = "Intro\n\n\(headerRow)\n\(delimiterRow)\n\(bodyRow)\n\nAfter"
    let layout = CodeBackgroundLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    let storage = NSTextStorage()
    storage.addLayoutManager(layout)
    let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
    tv.configure()
    tv.textStorage?.setAttributedString(NSAttributedString(string: source, attributes: Theme.baseAttributes))
    tv.rehighlight()
    let ns = source as NSString
    let header = ns.range(of: "| Column 1 ").location
    func fragmentX(_ needle: String) -> CGFloat {
        let glyph = layout.glyphIndexForCharacter(at: ns.range(of: needle).location)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
    }
    let block = layout.tableBlock(at: header)?.block
    let limits = block.flatMap { layout.tableScrollLimits($0) }
    checkTrue("a wide table can scroll", (limits?.maxOffset ?? 0) > 100)
    check("an unscrolled table lays out in place", "\(fragmentX("cell 1"))", "0.0")
    checkTrue("scrolling a table shifts its rows", layout.setTableOffset(60, forTableAt: header))
    check("its rows lay out shifted", "\(fragmentX("cell 1"))", "-60.0")
    check("text outside the table stays put", "\(fragmentX("After"))", "0.0")
    layout.setTableOffset(1_000_000, forTableAt: header)
    check("scrolling stops at the table's last column",
          "\(layout.tableOffset(at: header, in: tv.textStorage!))", "\((limits?.maxOffset ?? 0).rounded())")
    tv.setSelectedRange(NSRange(location: ns.range(of: "cell 1 ").location + 2, length: 0))
    check("the caret entering a hidden cell scrolls it into view", "\(layout.tableOffset(at: header, in: tv.textStorage!))", "0.0")
    tv.setSelectedRange(NSRange(location: ns.range(of: "cell 12").location + 3, length: 0))
    checkTrue("the caret in the last column scrolls right", layout.tableOffset(at: header, in: tv.textStorage!) > 100)
    let before = layout.tableOffset(at: header, in: tv.textStorage!)
    tv.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "More ")
    check("an edit above the table keeps its scroll", "\(layout.tableOffset(at: header + 5, in: tv.textStorage!))", "\(before)")
    // The page itself never scrolls sideways, whatever asks it to.
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    scroll.contentView = VerticalClipView()
    scroll.hasVerticalScroller = true
    scroll.documentView = tv
    tv.frame = NSRect(x: 0, y: 0, width: 400, height: 2000)
    tv.scrollToVisible(NSRect(x: -900, y: 300, width: 10, height: 10))
    check("the page stays put sideways when asked to show text off its left", "\(scroll.contentView.bounds.origin.x)", "0.0")
    checkTrue("it still scrolls down", scroll.contentView.bounds.origin.y > 100)
    scroll.contentView.scroll(to: NSPoint(x: 700, y: 0))
    check("the page stays put sideways when scrolled directly", "\(scroll.contentView.bounds.origin.x)", "0.0")
    // Its own horizontal scroll view lies over it and drives the offset.
    tv.frame = NSRect(x: 0, y: 0, width: 400, height: 2000)
    tv.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 5), with: "")
    layout.setTableOffset(0, forTableAt: header)
    tv.tableScrollers.attach()
    tv.tableScrollers.update()
    let overlay = tv.tableScrollers.scrollViews[header]
    checkTrue("a wide table gets its own scroll view", overlay != nil && tv.tableScrollers.scrollViews.count == 1)
    checkTrue("the scroll view lies over the table, inside the page",
              (overlay?.frame.width ?? 0) <= tv.bounds.width && overlay?.superview === tv)
    if let overlay, let table = layout.tableBlock(at: header) {
        var rows = NSRect.null
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: table.range, actualCharacterRange: nil)) { rect, _, _, _, _ in rows = rows.union(rect) }
        let tableBottom = rows.maxY - table.block.bottomMargin + tv.textContainerOrigin.y
        check("its scroller hangs just below the table's bottom rule",
              "\((overlay.frame.maxY - tableBottom).rounded())", "\((TableScrollView.scrollerHeight + 3).rounded())")
    }
    check("its content is as wide as the table",
          "\(overlay?.documentView?.frame.width ?? 0)", "\(layout.tableBlock(at: header)?.block.edges.last ?? -1)")
    overlay?.contentView.scroll(to: NSPoint(x: 120, y: 0))
    check("scrolling it scrolls the table", "\(layout.tableOffset(at: header, in: tv.textStorage!))", "120.0")
    check("the page doesn't move", "\(scroll.contentView.bounds.origin.x)", "0.0")
    tv.textContainerInset = NSSize(width: 28, height: 10)
    layout.ensureLayout(for: container)
    check("the text column stays at its inset while a table is scrolled", "\(tv.textContainerOrigin.x)", "28.0")
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "cell 1 ").location + 2, length: 0))
    tv.tableScrollers.update()
    check("the caret moving the table moves its scroll view", "\(overlay?.contentView.bounds.origin.x ?? -1)", "0.0")
    let narrow = makeTV("| a | b |\n| - | - |\n| 1 | 2 |\n", caret: 0)
    narrow.rehighlight()
    checkTrue("a table that fits doesn't scroll",
              !((narrow.layoutManager as? CodeBackgroundLayoutManager)?.setTableOffset(10, forTableAt: 0) ?? false))
    narrow.tableScrollers.update()
    checkTrue("a table that fits gets no scroll view", narrow.tableScrollers.scrollViews.isEmpty)
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
