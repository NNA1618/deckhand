<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/Brand/mark-white.svg">
    <img src="Resources/Brand/mark-black.svg" width="72" alt="Deckhand">
  </picture>
</p>

<p align="center"><sub>NNA1618</sub></p>

<h1 align="center">Deckhand</h1>

<p align="center">Your MacBook notch, put to work.</p>

<p align="center"><a href="README.ru.md">Русский</a></p>

---

Deckhand lives in the notch. Rest the pointer on it and a glass panel grows out of the cutout with your clipboard, a translator, Claude, saved prompts, music, a file shelf and recent media. Move away and it disappears. While the panel is closed, the notch shows what matters right now: Claude Code at work, a timer, the playing track.

It is a native macOS app written in Swift and SwiftUI. No Electron, no account, no telemetry.

<p align="center"><img src="docs/images/panel.png" width="760" alt="The Deckhand panel"></p>

## Features

**The notch**
- Opens when the pointer rests on the cutout, not when it passes by on its way to the menu bar. Hover area, delay, opening on click or only with the shortcut, and the close delay are all in Settings.
- Doesn't take the keyboard when it opens on hover, and stays closed over full-screen apps if you like.
- Notices for screenshots, the timer, the battery and Claude drop below the notch; the ones that need you stay until you look.
- Works on external displays and Macs without a notch, with a virtual notch.

**Claude Code in the notch**
- Every Claude Code session at a glance: the project, what it's doing right now and for how long. Works for Claude Code in Terminal, editors and the Claude app.
- While Claude works, its icon and the time spent show around the closed notch. When it needs a permission or an answer, the notch shows a raised hand and plays a sound. When a task is done, you get a short notice. You can turn on approving permission requests right from the notch.
- Click a session to bring it forward: the exact tab in Terminal and iTerm, the project window in VS Code and Cursor.
- Connect it in Settings → Claude with one click. Deckhand adds its own entries to `~/.claude/settings.json` (or the folder in `CLAUDE_CONFIG_DIR`), changes nothing else in the file and keeps a copy of the original next to it.

<p align="center"><img src="docs/images/claude-code.png" width="500" alt="Claude Code working, shown around the notch"></p>

**Codex in the notch**
- OpenAI Codex sessions show the same way, with Codex's icon: in the closed notch, on Home, in the session list and in notices. Works for the Codex CLI, editors and the ChatGPT app (formerly the Codex app), from Codex 0.124 on.
- Connect it in Settings → Codex. Deckhand adds its hooks after your own in `~/.codex/hooks.json` (or the folder in `CODEX_HOME`), changes nothing else in the file and keeps a copy of the original next to it. Codex runs hooks it didn't create only after you approve them: type `/hooks` in the CLI or use Review hooks in the ChatGPT app, then start a new session.
- Deckhand keeps only the session id, project folder, event and tool name. Prompts, code and output never leave Codex, and Deckhand never reads Codex's session files.
- Approving from the notch is off by default. When on, Allow and Deny answer one request at a time; there is no "always allow", and Codex shows its own prompt if you don't answer in time.

**Clipboard**
- History of text, links, images and files with search in any language, filters and pinning. Copying something again moves it to the top.
- Type to search, pick with the arrows, Return pastes into the app you were using, `⌥Return` pastes without formatting, `⌘1`–`⌘9` paste one of the first nine, Space previews.
- Pause the history or clear it. Passwords copied from password managers, including Apple Passwords, paste normally but stay out of the history.

**Screenshots and text**
- Capture an area, a window or the whole screen straight to the clipboard, optionally open it in the editor or save it.
- Copy the text from a screen area or from any image, recognized on device. QR codes and barcodes are copied as their content.
- The editor: crop, pen, highlighter, shapes, arrows, text, blur and redact, zoom, and Ask Claude about the image.

<p align="center"><img src="docs/images/editor.png" width="760" alt="The image editor"></p>

**Translate**
- On-device translation through Apple Translation, as you type. Detects the language, or pick both languages yourself; favorite languages are one click away.
- Copy the translation, paste it into the app you were using, or have it read aloud.
- Select text in any app and press `⌃⌥⇧T` to translate it.

**Mac conveniences**
- **Keep Awake.** Stops the Mac from sleeping for an hour, two, four or until you turn it off, like Amphetamine, and can turn itself off when the battery runs low. A cup and the time left show around the closed notch.
- **Timer.** Presets or any length, pause and +1 minute, and an alert that can keep ringing until you dismiss it.
- **Quick toggles.** Dark Mode, Mute, hide the desktop icons (handy before a screen share) and hidden files in Finder, one click each.
- **Battery.** Plugging in the charger shows the level in the notch, and so does the battery dropping to 20% and 10%.

<p align="center"><img src="docs/images/keep-awake.png" width="500" alt="Keep Awake around the notch"></p>

**Everything else**
- **Claude.** One-click actions for text: rewrite, shorten, fix grammar, explain, review code, improve a prompt. They run through Claude Code with your Claude plan, so no API key is needed; an API key in the Keychain works too. Chat opens the Claude app.
- **Prompts.** A searchable library of prompts by category, with `{{variables}}` you fill in before pasting, and import/export.
- **Music.** Knows what's really playing in Music, Spotify and browser tabs, shows the track around the notch and hides it when you pause.
- **Shelf.** Drop files on the notch to keep them at hand, then drag them out, share them or send them with AirDrop. Moved files are followed.
- **Recents.** Fresh images and videos from folders you choose, handy for AI generations you just downloaded.
- **Color picker.** Copies any pixel on screen as hex, rgb, hsl or SwiftUI.

<p align="center"><img src="docs/images/now-playing.png" width="500" alt="The playing track around the notch"></p>

English and Russian. Pick the language in Settings → General, or let it follow macOS.

## Requirements

- A Mac with Apple silicon. The notch is the best place for Deckhand; other displays get a virtual notch.
- macOS 15 Sequoia or later. Liquid Glass appears on macOS 26 Tahoe.

## Install

1. Download `Deckhand.zip` from [Releases](https://github.com/NNA1618/deckhand/releases) and move `Deckhand.app` to Applications.
2. Deckhand is not notarized yet, so macOS blocks the first launch. Run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Deckhand.app
   ```

3. Open Deckhand. Its icon appears in the menu bar.

## Shortcuts

All shortcuts use `⌃⌥⇧` so they don't collide with macOS input-source switching, Save As in other apps or window managers like Rectangle.

| Action | Default |
|---|---|
| Open or close Deckhand | `⌃⌥⇧D` |
| Capture area to clipboard | `⌃⌥⇧S` |
| Copy text from screen area | `⌃⌥⇧E` |
| Pick a color from screen | `⌃⌥⇧C` |
| Keep Mac awake | `⌃⌥⇧A` |
| Translate selected text | `⌃⌥⇧T` |
| Clipboard | `⌃⌥⇧V` |
| Translate | `⌃⌥⇧L` |
| Claude | `⌃⌥⇧K` |
| Prompts | `⌃⌥⇧P` |
| Music | `⌃⌥⇧M` |
| Shelf | `⌃⌥⇧F` |
| Recents | `⌃⌥⇧H` |

Every shortcut can be changed in Settings → Shortcuts. Deckhand warns when a shortcut is already taken by macOS or another app. Window capture, full-screen capture, delayed capture and capture-and-edit have no default shortcut; set one if you use them.

<p align="center"><img src="docs/images/settings.png" width="640" alt="Deckhand Settings"></p>

## Privacy

Everything stays on your Mac. The clipboard history lives in `~/Library/Application Support/Deckhand`. Deckhand itself never talks to the network. Claude actions go through your local Claude Code, or to the Anthropic API if you chose an API key. The Claude Code hook writes small event files to that folder only while Deckhand is running, and Deckhand deletes each one as soon as it has read it. A file holds the session id, the event, the project folder, the tool with the file name or the first word of a command, and the app the session runs in. Prompts, code, full commands, tool output and Claude's replies are never written to disk.

Permissions macOS may ask for, all listed with their status in Settings → Privacy & Permissions:

- **Screen Recording**, for screenshots and text capture.
- **Accessibility**, to paste into another app, read selected text for translation and use media keys.
- **Automation**, to read the track from Music, Spotify or a browser tab, switch Dark Mode, and select a Terminal or iTerm tab when you click a Claude session.

## Build from source

You only need the Xcode Command Line Tools, not the full Xcode.

```bash
git clone https://github.com/NNA1618/deckhand.git
cd deckhand
./scripts/setup-signing.sh      # once: a local signing identity so permissions survive rebuilds
./scripts/bundle.sh release     # builds, installs to /Applications and launches
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and screenshots.

## License

[MIT](LICENSE) © 2026 NNA1618
