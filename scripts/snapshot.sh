#!/bin/bash
# Renders README images: every panel tab, the closed notch, every Settings section and the editor, with a black
# notch, in English (DIR/en) and Russian (DIR/ru). Uses a check build with its own settings and sample content,
# so the installed Deckhand keeps running and its settings stay untouched.
# Usage: ./scripts/snapshot.sh [DIR]
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${1:-$(pwd)/.build/snapshots}"
./scripts/check.sh --snapshot "$DIR"
