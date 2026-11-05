#!/bin/bash
# Builds Deckhand.app in this checkout without installing it and runs the self-test.
# With --snapshot DIR it also renders screenshots of this build, in English (DIR/en) and Russian (DIR/ru).
# Safe next to the installed Deckhand and in several worktrees at once: it never kills or replaces
# the running app, and snapshot runs keep their data in a temporary folder.
# Usage: ./scripts/check.sh [--snapshot DIR] [--only panels,closed,settings,editor]
set -euo pipefail
cd "$(dirname "$0")/.."

SNAP=""
ONLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot) SNAP="$2"; shift 2 ;;
        --only) ONLY=(--only "$2"); shift 2 ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done

LOG=$(mktemp -t deckhand-check)
if ! NO_INSTALL=1 ./scripts/bundle.sh debug >"$LOG" 2>&1; then
    grep -E "error|warning:" "$LOG" | head -40 || tail -40 "$LOG"
    echo "==> build failed (full log: $LOG)"
    exit 1
fi
WARN=$(grep -c "warning:" "$LOG" || true)
echo "==> build ok, $WARN warning lines"
grep "warning:" "$LOG" | sort -u | head -20 || true

APP=.build/debug/Deckhand.app/Contents/MacOS/Deckhand
OUT=$(mktemp -t deckhand-selftest)
if "$APP" --selftest >"$OUT" 2>&1; then
    echo "==> selftest: $(grep -c '^ok' "$OUT") passed"
else
    grep -v '^ok' "$OUT"
    echo "==> selftest FAILED: $(grep -c '^FAIL' "$OUT") failed, $(grep -c '^ok' "$OUT") passed"
    exit 1
fi

if [ -n "$SNAP" ]; then
    mkdir -p "$SNAP/en" "$SNAP/ru"
    find "$SNAP/en" "$SNAP/ru" -name '*.png' -delete
    "$APP" --snapshot "$SNAP/en" --clean ${ONLY[@]+"${ONLY[@]}"} -AppleLanguages "(en)" >/dev/null 2>&1 || true
    "$APP" --snapshot "$SNAP/ru" --clean ${ONLY[@]+"${ONLY[@]}"} -AppleLanguages "(ru)" >/dev/null 2>&1 || true
    echo "==> snapshots: $(ls "$SNAP/en" | wc -l | tr -d ' ') in $SNAP/en, $(ls "$SNAP/ru" | wc -l | tr -d ' ') in $SNAP/ru"
fi
