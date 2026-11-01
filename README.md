# Kapitsa Launcher

A native macOS app for running a local [Kapitsa](https://github.com/nace-ai/kapitsa) model
server and chatting with it, without the command line.

> **Unofficial.** Kapitsa Launcher is an independent project. It is not made by,
> affiliated with, or endorsed by the developers of Kapitsa. It controls an existing
> Kapitsa installation and never installs, updates or modifies Kapitsa itself.

![A chat comparing US beach cities, with its outline beside it](docs/screenshots/chat-outline.png)

## What it does

- **Runs Kapitsa for you.** Start, stop and restart the server with one click, switch
  models from a menu, and watch the first download's progress. A menu bar icon keeps it
  within reach when the window is closed.
- **Chats with your model.** Replies stream in with Markdown, tables and code; the model's
  thinking folds away once the answer starts. Thinking levels match the model you run.
- **Keeps your chats organised.** Saved chats are grouped by date and searchable by what
  was said in them. Each window or tab shows its own chat.
- **Helps you find your way around a long chat.** A side panel shows:
  - **Outline:** every question, with the headings of its reply. Click one to jump to it.
  - **Topics:** the places and themes the chat discussed, each linked to its questions.
  - **Review:** takeaways the model writes from the chat, which you can edit, pin or add to.
- **Lets you explore without derailing.** Ask a side question about any reply, edit and
  resend a question, or ask again for another reply and switch between the versions.
- **Exports to Markdown,** with an optional summary written by the model, and places and
  themes as tags for note apps such as Obsidian.
- **Shows what the server is doing:** loaded model, memory, context, token speeds, and the
  server's own log.

<p>
  <img src="docs/screenshots/topics-places.png" width="270" alt="The Topics panel, listing places and themes">
  &nbsp;
  <img src="docs/screenshots/review-takeaways.png" width="270" alt="The Review panel, with four takeaways">
</p>

![The Overview page, with the server running](docs/screenshots/overview.png)

## Install

1. **Install Kapitsa**, for example with Homebrew:

   ```bash
   brew install nace-ai/tap/kapitsa
   ```

   If Kapitsa Launcher can't find `kapitsa`, it says so and links to the project page.
2. **Build Kapitsa Launcher** with Xcode 15.3 or later, or the Command Line Tools:

   ```bash
   zsh Scripts/build-app.zsh
   open "dist/Kapitsa Launcher.app"
   ```

3. **Press Start.** The first start downloads the model, which can take a while; the
   Overview shows the progress.

## Requirements

- An Apple silicon Mac with macOS 14 or later.
- Kapitsa 0.2 or later. The launcher looks for `kapitsa` in `/opt/homebrew/bin` and
  `~/.local/bin`, or you can choose it in Settings.

## Privacy and safety

- **Everything stays on your Mac.** The server listens on `127.0.0.1:8000`, so only this
  Mac can connect, unless you change the host in Settings.
- **It only stops what it started.** A Kapitsa server started some other way, such as the
  Homebrew service, is never stopped.
- **No shell.** Kapitsa is launched directly with a fixed list of arguments.
- **Keys stay hidden.** An optional API key is kept in the macOS Keychain and hidden in the
  log.
- **Your chats are files you own,** one JSON file per chat in
  `~/Library/Application Support/KapitsaLauncher/Chats/`.

## Development

`Scripts/build-app.zsh` builds a release binary and packages it as
`dist/Kapitsa Launcher.app`, ad-hoc signed for local use. `swift build` and `swift test`
compile and test the code but don't update the app bundle. The tests need full Xcode,
because the Command Line Tools don't include XCTest.

```bash
swift test
```

## Credits

The mark, a flask of superfluid helium whose surface climbs the glass, is drawn in code from
a single source, [`KapitsaMark.swift`](Sources/KapitsaLauncher/KapitsaMark.swift), which
produces the app icon, the sidebar mark and the menu bar symbol.

## License

[MIT](LICENSE)
