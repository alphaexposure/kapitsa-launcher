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
  - Replies render their **Markdown**: headings, bulleted and numbered lists (nested), quotes,
    rules, code blocks (monospaced, scrolling sideways, with a Copy button) and tables (a grid
    with a shaded header and column alignment; wide tables scroll sideways). Half-written
    tables and code blocks show as they stream in. The parser is the launcher's own, with no
    third-party code.
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
    - **Add topics as tags:** places and themes as `tags` in front matter at the top of the
      file (`Places/Funchal`, `Climate`), for note apps such as Obsidian; spaces become
      hyphens. Topics stay out of tags, so tag lists don't swell; they are in the index.

    Replies get `Places:` and `Topics:` lines, and a **Topics** index at the end, grouped into
    places and themes, links each to its questions (in the full conversation's file, for a
    summary saved separately).
  - **Delete a turn:** the trash button under a reply removes it and its question, after asking,
    including from what the model sees in later replies.
  - **Auto-scroll:** follows the reply as it streams; turn it off to read earlier turns while
    the model works. Sending a message still shows it.
  - **Outline and Topics:** a panel beside the chat, hidden with the Outline button. Its header
    shows about how many tokens the model reads with your next message, against its context.
    - **Outline** lists each question, numbered, by a short title the model writes with the
      reply's topics (hover for the question as you wrote it), with the headings of its reply;
      click one to jump to it. Find titles fills them in for older chats. Fold a question's headings with its chevron, or all of them at once; folds
      are kept with the chat.
    - **Topics** is an index of the chat: **Places** it discussed, then **Themes**, each opening
      to its topics, and each place or topic to the questions where it came up, the most
      discussed first. After each reply the model names its places and 2 to 4 broad topics,
      reusing the chat's earlier names, then files new topics into the chat's themes (at most
      about 10), in two short background requests with thinking off. **Find topics** does the
      same for earlier replies; **Redo all** re-indexes the chat and regroups its themes. Filter
      the list to find a place or topic.
  - **Edit and regenerate:** the pencil under a question edits it and sends it again; the
    arrow under a reply asks again for a new reply. Either way the conversation from that
    question on becomes a new version, and **‹ 2 / 3 ›** under the question switches between
    versions. Only the version shown is sent to the model, indexed and exported.
  - **Find (⌘F):** finds words in the chat, ignoring case and accents, with highlights, a
    match count and ⌘G / ⇧⌘G or Return to step through them. A chat opened from a search starts
    with Find on the searched words.
  - **Chats:** a column of your saved chats, grouped by when you last used them (Today,
    Yesterday, Previous 7 days and so on), with a search box that finds chats by name and by
    what was said in them, showing a line around the first mention. New chat starts a new chat and keeps
    the old one. Chats are named by the short title of their first question, or by the
    question as you wrote it (the column's menu); double-click to give one a name of its own.
    Delete moves a chat to the Trash. Each window or tab shows its own chat, a reply keeps
    writing while you look at another chat, and an unsent message stays with its chat.
  - Chats are kept in `~/Library/Application Support/KapitsaLauncher/Chats/`, one JSON file
    each with its folds, places, topics and themes, plus `index.json`, a cache of names and
    dates rebuilt from the chat files when needed. The single `chat.json` of earlier versions
    is copied in as the first chat and left in place as a backup.
- **Settings:** model (best for this Mac, downloaded, catalog or custom), host, port, API
  model name, context, slots, speculative drafter, memory budget, prefill chunk, SSD prefix
  cache, model switching, and an optional API key stored in the macOS Keychain.
- **Live overview:**
  - Engine details Kapitsa prints at startup: loaded model, context and slots, memory
    allocated, memory budget, KV cache room, GPU and decoding mode.
  - Token activity for the whole server session, with prefix cache hits.
  - A **Latest chat reply** panel: prompt, cached and output tokens, prefill and decode time,
    speeds and tokens per draft cycle. Switch it to **Any request** to include the launcher's
    short background requests for the topic index, and export summaries, each labelled.
- **Downloaded models** with their size on disk, and the SSD prefix cache size.
- **Server output** log with auto-scroll, Copy, and any API key redacted.
- **Menu bar** control to reopen the window or stop the server.
- **Optional extras:** launch at login, and a light, dark or system appearance.

## DEVONthink

DEVONthink doesn't read the `tags:` block that Obsidian uses, and turning on its "Convert
hashtags to tags" setting would also turn colour codes in web clips into tags. Instead, a
smart rule script adds an export's tags to just that record:

1. Compile the script into DEVONthink's smart rule scripts folder:

   ```bash
   osacompile -o ~/Library/Application\ Scripts/com.devon-technologies.think/Smart\ Rules/Kapitsa\ Launcher\ Tags.scpt "Scripts/DEVONthink/Kapitsa Launcher Tags.applescript"
   ```

2. In DEVONthink, choose Tools > New Smart Rule and set:
   - **Search in:** Global Inbox (or wherever exports arrive)
   - **Kind** is **Markdown**, and **Content** contains `Exported from Kapitsa Launcher`
   - **Perform the following actions:** On Import, then **Apply Script** › *Kapitsa Launcher Tags*
3. Export with **Add topics as tags** ticked. `Places/Funchal` becomes the tag *Funchal*,
   and `Cost-of-living` becomes *Cost of living*; tags the record already has are kept.

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
