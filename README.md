<p align="center"><sub>NNA1618</sub></p>

<h1 align="center">Deckhand</h1>

<p align="center">Your MacBook notch, put to work.</p>

---

Deckhand lives in the notch. Hover over it and a dark glass panel grows out of the cutout with your clipboard, a translator, Claude, saved prompts, music controls, a file shelf and recent media. Move away and it disappears.

It is a native macOS app written in Swift and SwiftUI. No Electron, no account, no telemetry.

## Features

- **Clipboard history.** Text, images and files with search and pinning. Passwords copied from password managers paste normally but stay out of the history.
- **Screenshots.** `⇧⌘S` captures an area straight to the clipboard: no file on the desktop, no floating thumbnail.
- **Mini editor.** Click any image in the clipboard to crop it and mark it up with a pen, highlighter, rectangles, ellipses, lines, arrows and text in any color.
- **Translate.** On-device translation through Apple's Translation framework. Detects the language and picks the direction.
- **Claude.** One-click presets for selected text (rewrite, shorten, fix grammar, explain, review code, improve a prompt) and a quick chat. Uses your own Anthropic API key, stored in the Keychain.
- **Prompts.** A searchable library of prompts by category. Click to copy.
- **Music.** Play, pause and skip for any player, and the current track from Music, Spotify, Yandex Music and browser tabs.
- **Shelf.** Drop files on the notch to keep them at hand, then drag them out anywhere or send them with AirDrop.
- **Recents.** Fresh images and videos from folders you choose, handy for AI generations you just downloaded.
- **Shortcuts you can change.** Every action has a global shortcut, editable in Settings.

English and Russian. The app follows your system language.

## Requirements

- A MacBook with a notch (Apple silicon)
- macOS 15 Sequoia or later. Liquid Glass appears on macOS 26 Tahoe.

## Install

1. Download `Deckhand.zip` from [Releases](https://github.com/nna1618/deckhand/releases) and move `Deckhand.app` to Applications.
2. Deckhand is not notarized yet, so macOS blocks the first launch. Run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Deckhand.app
   ```

3. Open Deckhand. Its icon appears in the menu bar.

## Build from source

You only need the Xcode Command Line Tools, not the full Xcode.

```bash
git clone https://github.com/nna1618/deckhand.git
cd deckhand
./scripts/bundle.sh release
```

The script builds the app, installs it to `/Applications` and launches it. `Deckhand --selftest` runs the built-in checks.

## Default shortcuts

| Action | Shortcut |
|---|---|
| Open or close Deckhand | `⌃⌥ Space` |
| Capture area to clipboard | `⇧⌘S` |
| Clipboard | `⌃⌥V` |
| Translate | `⌃⌥T` |
| Claude | `⌃⌥K` |
| Prompts | `⌃⌥P` |
| Music | `⌃⌥M` |
| Shelf | `⌃⌥F` |
| Recents | `⌃⌥H` |

Change them in Settings → Shortcuts.

## Privacy

Everything stays on your Mac. The clipboard history lives in `~/Library/Application Support/Deckhand`. Deckhand talks to the network only when you use Claude, and then only to the Anthropic API with your key.

Permissions macOS may ask for:

- **Screen Recording**, for screenshots.
- **Automation**, to read the current track from Music, Spotify or a browser.

## License

[MIT](LICENSE) © 2026 NNA1618
