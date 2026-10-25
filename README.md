# Catalog

![Catalog — a translucent terminal-styled markdown editor for macOS](docs/catalog.png)

A catalog for creative and research work: browse a folder of notes and
images, read Wikipedia, write in Markdown, and ask Claude or Codex about any
of it ... with vibes. (Formerly Write; your settings, session, and drafts
carry over on first launch.)

## Build & install

```
make run       # build, bundle, and launch dist/Catalog.app
make install   # copy to /Applications
make test      # editing, workspace, and image regressions
```

Builds with Xcode Command Line Tools (`swift` + `make`). Xcode 26 or newer is
needed for Tahoe's native window styling; the Makefile prefers the full Xcode
installation when available. Set `DEVELOPER_DIR` to select a different Xcode.
The app icon is an Icon Composer document (`Support/AppIcon.icon`, shared
with Encyclopedia: a glass codex with a laurel wreath on graphite), compiled
into the bundle by `actool` with the build.

Tests and the gallery benchmark use isolated preferences and recovery storage.
For automated UI testing, launch a separate instance with
`open -na /Applications/Catalog.app --args --test-mode` (or set `CATALOG_TEST_MODE=1`
when launching the executable). Every test launch gets a fresh profile: test
drafts, tabs, recents, and preferences cannot enter your normal session, even
if the test crashes. Use temporary copies of files for testing edits; explicitly
opened files still save to their supplied paths. Normal launches retain your
usual session and settings.

Requires macOS 26 (Tahoe): the Wikipedia reader and the page chrome use
Liquid Glass.

## Home, tabs, and Wikipedia

- A new window opens on the **home page**: search Wikipedia, open a folder or
  file, or start a blank note. Opening anything replaces the home tab.
- The tab strip's **+** offers **New Note** (⌘T) or **New Wikipedia Page**
  (⇧⌘T). Wikipedia pages are ordinary tabs: several can be open, they detach
  into their own windows, and they restore with the session.
- Wikipedia articles render natively (from Encyclopedia): infobox card,
  figures, tables, diagrams, math. In-article links open in the same tab;
  **Go** has Back (⌘[), Search Wikipedia (⌘L), and Random Article (⌥⌘R).
  On a Wikipedia page, ⌘= / ⌘− size the article text.
- Every note, image, and Wikipedia page has the same bar under the tabs: Back
  (Wikipedia), the title once it scrolls away, and a glass cluster at right —
  **Contents** (the article's sections, or a note's headings), **Share** (the
  article link, the image, or the note with or without its embedded images),
  and **Assistant**. Pages scroll up under the tabs and bar, behind a Liquid
  Glass fade that appears only while content is beneath them.

## Assistant

The chat bubble (or ⌘J) opens the assistant in a right sidebar, beside
whatever tab is open. It sees the open article, note, or image, and works in
a **working directory**: the open folder, or `~/Documents` without one.

The model menu at the bottom of the sidebar picks who answers:

- **Claude** (Opus or Sonnet) through your Claude subscription, by running
  [Claude Code](https://claude.com/product/claude-code) headless
  (`claude -p --output-format stream-json`, edits auto-accepted in the working
  directory).
- **Codex** (any model your account lists) through your ChatGPT subscription,
  by running `codex exec --json` sandboxed to the working directory.
- **Claude API** with an Anthropic API key from Settings (⌘,).
- **Apple Intelligence**, on device; answers questions but can't edit files.

Claude Code and Codex must be installed; Catalog finds them on your login
shell's PATH (npm, Homebrew, and nvm installs all work). If one isn't signed
in, the menu offers **Sign In**, which runs `claude auth login` or
`codex login` in Terminal. Catalog never handles those credentials. Each
conversation keeps its CLI session and resumes it on every turn; the title
menu at the top of the sidebar lists the window's conversations, and
**New Conversation** starts another. Picking a different model starts a new
conversation once the current one has messages.

Changes appear live: unsaved notes are saved before each message, so the
assistant reads what you see; after each file step, open notes reload in
place (⌘Z undoes an edit) and the sidebar refreshes. Notes without unsaved
edits also reload when the window becomes key.

The first time the assistant works in `~/Documents`, macOS asks whether
Catalog may access that folder.

## Editing

- Click anywhere to place the cursor, like Word or Pages.
- Obsidian-style live preview: markdown renders in place and syntax markers
  (`#`, `**`, backticks, link URLs) are hidden except on the paragraph the
  cursor is on, where they reappear dimmed for editing.
- Windows and tabs: ⌘N opens a window, ⌘T a note tab; ⌘W or the hover × closes a
  tab, ⇧⌘W the window; ⌘⇧] / ⌘⇧[ or ⌃⇥ cycle tabs. Drag a tab out of the bar
  to detach it into its own window. Each tab keeps its own undo history and
  autosave; the session (windows, tabs, frames) restores on relaunch.
- Bullet / numbered / task lists and quotes continue on Enter; Enter on an
  empty item exits the list. Tab / Shift-Tab indent and outdent list items.
- Type `/` at the start of a line for the slash command menu.
- Typing at the end of a bold/italic/code/colored span continues the style,
  Word-style: the caret may sit past the concealed closing marker, but new
  characters land inside it. Typing a space exits the span.
- Documents autosave 0.8s after you stop typing (once a file has a path).
- Crash recovery: every edited buffer — including untitled ones — is mirrored
  to `~/Library/Application Support/Catalog/Recovery/` as you type. If the app
  crashes, is force-quit, or you just quit (⌘Q, which never prompts), your
  drafts reappear on the next launch. Closing a tab or window still asks
  before discarding an unsaved untitled buffer.
- `Catalog.app/Contents/MacOS/Catalog a.md b.md` opens each file in a tab.

## Folders, media, and file references

Use **File → Open Folder…** (⌥⌘O), choose a folder in Open (⌘O), or pass a
folder on the command line. Opening a folder adds a gallery tab and a sidebar;
existing tabs, including files outside that folder, stay open. Each window has
one active folder. Opening another folder replaces its sidebar and adds a tab.
The folder, sidebar width, collapsed state, and Files/Media mode restore with
the session. **File → Close Folder** removes the sidebar and keeps your tabs.

- **Files** (document symbol) shows the directory tree. Click a Markdown or text
  file to edit it, an image to view it fitted to the window with its aspect ratio
  preserved, or another file to see “Rendering not yet supported.”
- Sidebar navigation reuses the most recently active tab whose file or folder
  is inside the sidebar's root. Unrelated files and untitled tabs stay open;
  if no associated tab remains, a new one opens. If the clicked item already
  has a tab, that tab is selected instead.
- Drag the sidebar's right edge to resize it. The leftmost tab-bar button
  collapses or expands it without moving. Dragging nearly closed also collapses it.
- **Media** (image symbol) shows folders only. Click a folder to browse images
  throughout its subtree, grouped by containing folder under clickable breadcrumb
  headings. Click an image to animate into its own preview tab; click a folder in
  its breadcrumb to return to that gallery. Galleries remember their scroll position.
  In Files mode, image previews have no title or breadcrumb.
- Galleries decode only visible thumbnails, sized for the display's pixel density.
  Offscreen requests are cancelled and reusable cells release their images. A 64 MB
  decoded thumbnail cache and a 256 MB disk cache under `~/Library/Caches/com.grant.catalog/`
  avoid repeated decoding; editing a source invalidates its cached thumbnail.
  Workers deliver decoded `CGImage` pixels directly; loading/error symbols are
  rasterized once on the gallery scan queue. Cells never convert or rasterize
  images on the main thread. Memory-pressure cache cleanup also runs off main.
  Fixed-size tiles present those pixels directly to Core Animation; breadcrumb
  widths are measured once when configured, keeping scrolling out of Auto Layout.
  Opened images use a separate queue and the original native resolution, with no
  lossy re-encoding or preview-size cap. Original pixels are released on leaving
  the viewer and never stored in the thumbnail caches.
- Sidebar controls align with the tabs; the collapse control points in the direction
  it will move. Overflowing tabs scroll horizontally through the window's right edge.
- In **Files**, right-click a row or empty space for **New Folder…** or **New File…**.
  The expanded root row also has **New Folder** and **New Markdown** icons. They
  create inside the selected folder, or beside the selected file; with no selection,
  they use the root. New files open immediately. Collapsing the root hides its icons.
  The sidebar backdrop reveals from the left while content fades into its final
  position; the toggle stays visible. This respects the macOS Reduce Motion setting.
- The tree refreshes when the window regains focus. Right-click it and choose
  **Refresh Folder** to update it while working. Hidden files and directories are
  omitted; the reference index does not follow symlinks or enter app packages.

With a folder open, type **@** after whitespace or at the start of a line, or
type **`[[`** anywhere, then search by filename or path. Use ↑/↓ and Return/Tab,
or click a result; Escape cancels. Any file type can be referenced. Unsaved
notes ask for a save location before inserting a reference. `@` inserts a
Markdown link (bold royal blue); `[[` inserts a wiki link.

## Links between documents

Catalog uses the two syntaxes you already know — GitHub-flavored Markdown links
and Obsidian wiki links — and nothing else. Both are plain text in the file, so
the same links keep working in GitHub, Obsidian, and any other Markdown tool.

```markdown
[Design notes](../notes/Design.md)          relative path, like GitHub
[Design notes](../notes/Design.md#palette)  …at a heading
[the brief](#project-brief)                 a heading in this document
[@Design.md](../notes/Design.md)            an @ reference (a Markdown link)
[[Design]]                                  wiki link by note name
[[Design|the design notes]]                 …with different link text
[[Design#Palette]]                          …at a heading
[[Media/Sketch.png]]                        …by workspace path
<https://example.com> and https://example.com   auto-linked URLs
```

**Click a link to follow it**; Option-click places the editing caret inside it
instead. Links to Markdown or images open in a tab (or focus the tab already
showing them); web addresses open in your browser; files Catalog cannot display
are handed to the system. A `#fragment` scrolls to its heading, and matches
either spelling — `#My Heading` (Obsidian) or `#my-heading` (GitHub).

**Markdown destinations are paths**, resolved relative to the file containing
the link, with special characters percent-encoded — exactly how GitHub renders
them. The opened folder defines the **search scope**, not the link's origin, so
opening a higher-level folder needs no migration and moving a whole project
preserves its links. Agents can parse these links, decode their paths, resolve
them against the source file's directory, and traverse the graph without Catalog
or a separate index.

**Wiki-link targets are note names**, resolved against the open folder: a bare
`[[Design]]` finds `Design.md` anywhere in the workspace, preferring the copy
nearest the linking document, and a target containing a slash is a path
(relative to the note, then to the workspace root). The `.md` extension is
optional. Without a folder open, wiki links look beside the file itself. A wiki
link that names nothing is drawn dimmed with a dotted underline and does not
navigate, so broken links are visible rather than silently dead.

Moving or renaming individual files externally requires updating Markdown link
paths, just as with ordinary Markdown; wiki links by name survive a move within
the workspace.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘B / ⌘I / ⌘E | bold / italic / inline code (wraps selection or word at caret) |
| ⌘K | insert link |
| @ / `[[` | reference another file (Markdown link / wiki link) |
| ⌘1–⌘6, ⌘0 | set / clear heading level |
| ⌘= / ⌘− | bigger / smaller text |
| ⌘N ⌘T ⇧⌘T | new window / new note / new Wikipedia page |
| ⌘O ⌘S ⇧⌘S | open / save / save as |
| ⌘J | show or hide the assistant |
| ⌘[ ⌘L ⌥⌘R | Wikipedia back / search / random article |
| ⌘W / ⇧⌘W | close tab / close window |
| ⌘F | find |

## Gallery scrolling benchmark

Run `make benchmark-gallery GALLERY="/path/to/folder"` to exercise rapid scrolling
through a real folder in a separate test window. It reads the files without editing
them and reports main-thread timing percentiles over ten passes. Timer intervals
measure responsiveness, not display FPS; compare runs at the same window size and
cache state without other CPU-heavy work running.
