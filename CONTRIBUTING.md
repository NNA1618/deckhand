# Contributing to Deckhand

Thanks for helping. Deckhand is a small native macOS app, so the setup is short.

## Build

You need macOS 15 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./scripts/setup-signing.sh     # once: a local signing identity, so macOS keeps permissions across rebuilds
./scripts/bundle.sh debug      # builds Deckhand.app, installs it to /Applications and launches it
```

Liquid Glass needs the macOS 26 SDK. On older SDKs the app falls back to a regular blur.

## Check your change

- `./scripts/check.sh` builds the app without installing it and runs the self-test (`Deckhand --selftest`).
  It is safe next to an installed Deckhand: it never replaces or quits the running copy, and it builds with its own
  bundle id (`com.nna1618.deckhand.check`), so test runs start from default settings and never touch yours.
- `./scripts/check.sh --snapshot DIR` also renders every panel tab, the closed notch, every Settings section and the
  editor to PNG files in English (`DIR/en`) and Russian (`DIR/ru`). Snapshot runs use a temporary data folder and sample
  content. Add `--only panels,closed,settings,editor` to render part of it.
- `python3 scripts/l10n-check.py` lists user-facing strings that have no Russian translation; CI runs it too.
- `./scripts/snapshot.sh DIR` renders the same images for the README; the installed app keeps running.
- Logs go to `~/Library/Logs/Deckhand/deckhand.log`.

## Style

- Code, comments and commit messages in English.
- Every user-facing string is localized: English is the key, add the Russian translation to
  `Localization/ru.lproj/Localizable.strings`.
- No secrets in code. API keys live in the Keychain.
- Keep dependencies MIT-compatible.

## Pull requests

One change per pull request, with a short description of what and why. Screenshots help for UI changes.
