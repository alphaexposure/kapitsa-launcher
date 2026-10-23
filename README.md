# Kapitsa Launcher

A native macOS app for starting, stopping and monitoring a local
[Kapitsa](https://github.com/nace-ai/kapitsa) model server, without the command line.

> **Unofficial.** Kapitsa Launcher is an independent project. It is not made by,
> affiliated with, or endorsed by the developers of Kapitsa. It controls an existing
> Kapitsa installation and never installs, updates or modifies Kapitsa itself.

## Install

1. **Install Kapitsa**, for example with Homebrew:

   ```bash
   brew install nace-ai/tap/kapitsa
   ```

   Kapitsa Launcher doesn't install Kapitsa for you; if it can't find `kapitsa`, it says so
   and links to the project page.
2. **Build Kapitsa Launcher** with Xcode 15.3 or later, or the Command Line Tools:

   ```bash
   zsh Scripts/build-app.zsh
   open "dist/Kapitsa Launcher.app"
   ```

## How it fits together

- **Kapitsa** runs Qwen and Nemotron models on Apple silicon and serves OpenAI- and
  Anthropic-compatible APIs plus a chat page.
- **Kapitsa Launcher** (this app) starts `kapitsa serve`, stops it, and shows what it is
  doing. It doesn't run models itself; your chat apps and coding agents talk to Kapitsa
  directly.

## Features

- **Start, stop and restart** Kapitsa with one click, and open its chat page.
- **Chat page:** a native chat with the running model.
  - Replies stream in, with the model's reasoning in a section that folds away once the
    answer starts ("Thought for 11.6 s").
  - A **Thinking** picker: Off, Low, Medium or Extra high. Kapitsa's own chat page only offers
    on or off; the launcher sends `reasoning_effort`, which the Qwen3.8 27B reads.
  - **Attachments:** drop or attach images, which Kapitsa reads itself, and documents (PDF,
    Word, RTF, HTML, OpenDocument, text, Markdown, code), whose text the launcher extracts and
    adds to the message. Scanned PDFs without a text layer can't be read.
  - **Export as Markdown:** the whole chat (Export) or one question and reply (the button
    under each reply). Replies keep their full Markdown, tables and code blocks included;
    reasoning goes in a foldable `<details>` block; images are saved in a folder beside the
    file; documents are listed by name. The Save dialog offers:
    - **Include summary:** the running model writes a short summary (an overview, main points,
      open questions) with thinking off, from the questions and replies only. A chat too long
      for the model's context is summarised in parts, then combined. The summary is labelled
      with the model that wrote it. Needs Kapitsa running.
    - **Include full conversation**, on by default.
    - **Save the summary as a separate file:** `<name>.md` and `<name> – Summary.md` side by
      side, the summary linking to the full file.
    - **Exclude thinking**, for a shorter full conversation.
  - **Delete a turn:** the trash button under a reply removes it and its question, after asking,
    including from what the model sees in later replies.
  - **Auto-scroll:** follows the reply as it streams; turn it off to read earlier turns while
    the model works. Sending a message still shows it.
  - **Outline and Topics:** a panel beside the chat, hidden with the Outline button. Its header
    shows about how many tokens the model reads with your next message, against its context.
    - **Outline** lists each question, numbered, with the headings of its reply; click one to
      jump to it. Fold a question's headings with its chevron, or all of them at once; folds
      are kept with the chat.
    - **Topics** is an index of the key concepts the replies covered, alphabetically, each with
      the questions where it came up. After each reply the model names its 3 to 6 concepts in
      a short background request with thinking off; **Find topics** does the same for earlier
      replies, one at a time. Filter the list to find a concept.
  - The conversation is kept between launches, in
    `~/Library/Application Support/KapitsaLauncher/chat.json`.
- **Settings:** model (best for this Mac, downloaded, catalog or custom), host, port, API
  model name, context, slots, speculative drafter, memory budget, prefill chunk, SSD prefix
  cache, model switching, and an optional API key stored in the macOS Keychain.
- **Live overview:**
  - Engine details Kapitsa prints at startup: loaded model, context and slots, memory
    allocated, memory budget, KV cache room, GPU and decoding mode.
  - Token activity for the whole server session, with prefix cache hits.
  - A **Latest request** panel: prompt, cached and output tokens, prefill and decode time,
    speeds and tokens per draft cycle.
- **Downloaded models** with their size on disk, and the SSD prefix cache size.
- **Server output** log with auto-scroll, Copy, and any API key redacted.
- **Menu bar** control to reopen the window or stop the server.
- **Optional extras:** launch at login, and a light, dark or system appearance.

## Requirements

- macOS 14 or later on Apple silicon.
- Kapitsa 0.2 or later. The launcher looks for `kapitsa` in `/opt/homebrew/bin` and
  `~/.local/bin`, or you can choose the executable in Settings.
- To build: Xcode 15.3+ or a Swift 5.10+ toolchain.

## Development

`Scripts/build-app.zsh` builds a release binary and packages it as
`dist/Kapitsa Launcher.app`, ad-hoc signed for local use. `swift build` and `swift test`
compile and test the code but don't update the app bundle. Running the tests needs full
Xcode, because the Command Line Tools don't include XCTest.

```bash
swift test
```

## How it behaves

- **Local by default:** binds to `127.0.0.1` on port `8000`, so only this Mac can
  connect. Change the host deliberately if you want other devices to reach it.
- **Only stops what it started:** the launcher stops a Kapitsa process only if it
  launched that process itself. A server started elsewhere, such as the Homebrew service,
  is never stopped; the launcher reports the port as in use instead.
- **No shell:** Kapitsa is launched directly with an explicit argument list, never
  through a shell.
- **Keys stay hidden:** the API key is kept in the Keychain, passed to Kapitsa through
  `KAPITSA_API_KEY` in its environment (never as `--api-key`), and redacted from the log view.
- **Overview numbers come from Kapitsa's output:** Kapitsa's `/health` endpoint only says
  whether it is serving, so engine details and request figures are read from the lines it
  prints. They only appear for servers this app started. Values marked "≈" are calculated.

## Credits

The mark, a flask of superfluid helium whose surface climbs the glass, is drawn in code from a single source,
[`KapitsaMark.swift`](Sources/KapitsaLauncher/KapitsaMark.swift), which produces the app icon,
the sidebar mark and the menu bar symbol.

## License

[MIT](LICENSE)
