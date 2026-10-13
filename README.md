# CleanPaste

A tiny macOS menu bar app that strips formatting from text.

Click the menu bar icon, paste anything (web pages, Word, Google Docs, emails…), and copy it back as clean text.

## Features

- **Plain text** – removes fonts, colors, sizes, links and styles; keeps paragraphs, lists and tables (tab-separated).
- **Markdown mode** – turn the toggle on to convert the pasted formatting to Markdown instead:
  headings, **bold**, *italic*, ~~strikethrough~~, `inline code`, code blocks, links, nested lists and tables.
- Live preview of exactly what will be copied.
- `⌘↩` copies the result and (optionally) hands focus back to the previous app so you can paste right away.
- **Global shortcut `⌃⌥V`** (Control + Option + V) opens/closes the window from any app.
- Optional **Launch at login** (in the `…` menu).
- Right-click the menu bar icon to quit.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open "build/CleanPaste.app"
```

The app is ad-hoc signed. If macOS blocks it the first time, right-click the app and choose **Open**.

To start it at login, use the `…` menu → **Launch at login** (or add it manually in System Settings → General → Login Items).

## How it works

Pasted content lands in a rich-text view (`NSTextView`), so formatting is preserved long enough to be analysed.
`Converter.swift` walks the attributed string paragraph by paragraph and emits either plain text or Markdown.
Only a plain `String` is ever written to the pasteboard, which is what removes the formatting.

## License

[GPL-3.0](LICENSE)
