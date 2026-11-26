#!/bin/zsh
# Stages the four README showcase windows, tiled on the main screen. Each is
# its own --test-mode instance, so their themes and state stay separate and
# the user's preferences are never touched.
#
#   Support/Showcase/stage.sh [path/to/Catalog.app] [snapshot-directory]
#
# With a snapshot directory, each window also writes <n>-<name>.png there.
# Quit them with: pkill -f "<app>/Contents/MacOS/Catalog --test-mode"
set -euo pipefail

app=${1:-/Applications/Catalog.app}
shots=${2:-}
here=${0:A:h}

# The main screen's visible area (below the menu bar, beside the Dock), in
# top-left-origin points: x y w h.
read x y w h < <(osascript -l JavaScript -e '
  ObjC.import("AppKit")
  const s = $.NSScreen.screens.objectAtIndex(0), f = s.frame, v = s.visibleFrame;
  [v.origin.x, f.size.height - v.origin.y - v.size.height, v.size.width, v.size.height].map(Math.round).join(" ")')

gap=16
cw=$(( (w - 3 * gap) / 2 ))
ch=$(( (h - 3 * gap) / 2 ))
frame() { echo "$(( x + gap + $1 * (cw + gap) )),$(( y + gap + $2 * (ch + gap) )),$cw,$ch"; }

launch() {
  local name=$1; shift
  local extra=()
  [[ -n $shots ]] && extra=(--snapshot "$shots/$name.png" --snapshot-delay 6)
  open -na "$app" --args --test-mode "$@" $extra
}

[[ -n $shots ]] && mkdir -p "$shots"
launch 1-note    --theme plasma --frame "$(frame 0 0)" "$here/Notebook" "$here/Notebook/Field Notes.md"
launch 2-gallery --theme dark   --frame "$(frame 1 0)" "$here/Notebook/Library" --media
launch 3-article --theme paper  --frame "$(frame 0 1)" --wiki "Saturn"
launch 4-chat    --theme light  --frame "$(frame 1 1)" --wiki "Kyoto" --transcript "$here/transcript.json"
