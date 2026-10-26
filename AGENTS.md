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
  `dark-glass`, `light`, `light-glass`, `paper`) picks the theme, `--browse
  /folder` opens the icon browser there (with a workspace folder also passed,
  Back leads up to it), `--scroll N` scrolls the note (or to Wikipedia block N), `--move-tab` moves
  the current tab to a new window (other windows snapshot as `path-2.png`, …), and
  `--snapshot path.png` (`--snapshot-delay seconds`) captures the window's
  composite, glass included.
