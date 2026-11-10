#!/bin/bash
# Packs Deckhand.app into a disk image with an Applications shortcut and a short "how to open" note.
# Usage: ./scripts/make-dmg.sh [path/to/Deckhand.app] [output.dmg]

set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-.build/release/Deckhand.app}"
OUT="${2:-.build/release/Deckhand.dmg}"
[ -d "$APP" ] || { echo "error: $APP not found; run ./scripts/bundle.sh release first"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Deckhand.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open Deckhand.txt" <<'TXT'
1. Drag Deckhand to Applications.
2. Open Deckhand from Applications. macOS says it can't check the app, because Deckhand isn't
   signed by Apple. Click Done.
3. Open System Settings → Privacy & Security, scroll down and click "Open Anyway" next to Deckhand,
   then confirm with your password or Touch ID.
   Or, instead of steps 2–3, run once in Terminal:
       xattr -dr com.apple.quarantine /Applications/Deckhand.app
After that Deckhand opens normally and updates itself.

1. Перетащите Deckhand в «Программы».
2. Откройте Deckhand из «Программ». macOS скажет, что не может проверить программу: Deckhand
   не подписан в Apple. Нажмите «Готово».
3. Откройте «Системные настройки» → «Конфиденциальность и безопасность», пролистайте вниз и нажмите
   «Всё равно открыть» рядом с Deckhand, подтвердите паролем или Touch ID.
   Или вместо шагов 2–3 один раз выполните в Терминале:
       xattr -dr com.apple.quarantine /Applications/Deckhand.app
После этого Deckhand открывается как обычно и обновляется сам.
TXT

rm -f "$OUT"
hdiutil create -quiet -volname "Deckhand" -srcfolder "$STAGE" -format ULFO -ov "$OUT"
if [ -n "${SIGN_ID:-}" ] && [ "$SIGN_ID" != "-" ]; then codesign --force --sign "$SIGN_ID" "$OUT"; fi
echo "==> built $OUT"
