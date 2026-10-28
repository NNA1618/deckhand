#!/bin/bash
# Renders every panel tab, Settings tab and the editor to PNGs: ./scripts/snapshot.sh [DIR]
# Briefly opens the panel on screen. Uses the installed /Applications/Deckhand.app.
set -euo pipefail
DIR="${1:-$(pwd)/.build/snapshots}"
rm -rf "$DIR"
pkill -x Deckhand 2>/dev/null || true
sleep 0.5
/Applications/Deckhand.app/Contents/MacOS/Deckhand --snapshot "$DIR"
echo "==> $(ls "$DIR" | wc -l | tr -d ' ') images in $DIR"
open /Applications/Deckhand.app
