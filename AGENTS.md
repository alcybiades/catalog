# Automated testing

- Run regression tests with `make test`; the test executables compile with
  `CATALOG_TESTING` and use isolated preferences and recovery drafts.
- For automated UI checks, launch a separate app instance with `--test-mode`
  (for example, `open -na /Applications/Catalog.app --args --test-mode`), or set
  `CATALOG_TEST_MODE=1` when launching the executable. Never create scratch tabs
  or type test content into the user's normal Catalog session.
- Use temporary fixture files for edits. Test mode isolates app state, but
  explicitly opened files still save to their supplied paths.
- A preview intended for the user to use with their own documents may launch
  normally; do not use that session for automated edits.
- Scripting flags for checking UI in a test-mode launch: `--wiki "Title"`
  opens an article, `--assistant` shows the assistant, `--ask "Question"`
  sends it one, `--assistant-model codex:<model>` (or `claude-code:opus`,
  `claude-api`, `apple`) picks its model, `--theme dark` (or `plasma`,
  `light`, `paper`) picks the theme, `--scroll N` scrolls the note (or to Wikipedia block N), `--move-tab` moves
  the current tab to a new window (other windows snapshot as `path-2.png`, …), and
  `--snapshot path.png` (`--snapshot-delay seconds`) captures the window's
  composite, glass included. `--theme plasma|dark|light|paper` picks the
  theme; `--frame x,y,w,h` sets the window frame in points from the primary
  screen's top-left; a folder path argument opens it as the workspace (add a
  note's path to show it too) and `--media` switches it to the media view;
  `--assistant` shows the floating panel and `--assistant-docked` the docked
  one; `--transcript file.json` (test mode only) preloads a canned
  conversation, as in `Support/Showcase/transcript.json`, without calling a
  model. Each test-mode launch gets its own preferences suite, so concurrent
  instances keep their own themes. `Support/Showcase/stage.sh [app] [shots]`
  tiles the four README showcase windows, optionally snapshotting each.
