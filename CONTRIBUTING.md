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

- `Deckhand --selftest` runs the built-in checks (editor, blur, text recognition, localization, shortcuts).
  Inside the app bundle: `/Applications/Deckhand.app/Contents/MacOS/Deckhand --selftest`.
- `./scripts/snapshot.sh` renders every panel tab, every Settings tab and the editor to PNG files, so you can
  review layout without screen recording. Add `--clean` for README images.
- Logs go to `~/Library/Logs/Deckhand/deckhand.log`.

## Style

- Code, comments and commit messages in English.
- Every user-facing string is localized: English is the key, add the Russian translation to
  `Localization/ru.lproj/Localizable.strings`.
- No secrets in code. API keys live in the Keychain.
- Keep dependencies MIT-compatible.

## Pull requests

One change per pull request, with a short description of what and why. Screenshots help for UI changes.
