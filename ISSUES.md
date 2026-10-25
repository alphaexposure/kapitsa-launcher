# Issues

Open work for Kapitsa Launcher. This repository has no remote yet, so issues are tracked
here; move them to GitHub issues if the project is published. Tick an item when its change
is committed, and note the commit.

## Chat navigation

- [ ] **Concept map.** The topic index drawn as a graph: concepts as nodes sized by how often
  they come up, linked when they appear in the same reply; clicking one highlights its
  questions. Build only if the index alone isn't enough.
- [ ] **Tangents.** Ask a side question about part of a reply without derailing the main
  conversation; from the original navigation ideas (outline, concept map, tangents,
  takeaways).
- [x] **Remember folded outline questions.** Folds are saved with the chat in `chat.json`.
  (87c1a6c)
- [x] **Topic index.** The first step toward the concept map: a Topics view listing each
  reply's key concepts, found by the model, with the questions where they came up; names
  are reused across the chat. Exports include topic lines, a linked topic index and optional
  tags. (87c1a6c, a0077fc, 42b4ba7, 9063160)
- [x] **Places and themes.** The index grew by 3 to 4 topics a reply, with near-duplicates
  and one-off names. Replies now get places plus 2 to 4 broad topics, and topics are filed
  into at most about 10 themes kept with the chat, replacing the name-merging step.

- [x] **Question titles.** The outline and topic index name each question by a short title
  the model writes with its topics, with the question as written on hover. (b54b794, 2d79306)

## Chats

- [x] **Chat history list.** Saved chats, one file each with a cached index, in a Chats column
  beside the conversation; each window or tab shows its own chat, and chats are named by
  their first question's title or as written. (f63d934, 877cf5a)
- [x] **Edit and regenerate.** Edit a question or regenerate a reply; earlier versions of the
  conversation from that question on are kept and can be switched back to.
- [x] **Find and search.** ⌘F finds words in the chat with a match count and highlights;
  the Chats search box also finds chats by what was said in them, and opens a result with
  Find on those words.
- [ ] **Continue in a new chat with a summary.** When a chat nears the context, start a new
  chat that opens with a summary of the old one.

## Chat view

- [x] **Render Markdown in replies.** Headings, lists, quotes, rules, code blocks and tables
  now render, in finished replies and while they stream.

- [x] **Copy buttons.** Tables and a reply's thinking have Copy buttons, like code blocks;
  code blocks in list items stay in the list. (9e392ba, 50bc047)

- [x] **Tags in DEVONthink.** DEVONthink ignores front matter tags; a smart rule script in
  `Scripts/DEVONthink/` applies them, and exports tag only places and themes.

## Overview

- [x] **Latest chat reply.** The Overview showed whatever finished last, usually a background
  topic request. It now shows the latest chat reply, or any request with what sent it, and
  topic requests read an outline of long replies. (4fda784)

## Small fixes

- [x] **Token count reads high after deleting a middle turn.** The outline's estimate starts
  from what the model read for the latest reply, so it overstated until the next reply. Each
  reply now notes what came before it, and deleted turns come off.
- [x] **Non-places listed as places.** The model sometimes lists things like "GPS satellites"
  as places, even though the request asks for places on a map. Places with ordinary lowercase
  words are now dropped; Rio de Janeiro-style connectors are allowed.

## Notes for the GitHub README

- **Selecting reply text:** each block of a reply (a paragraph, a list item, a table cell)
  selects on its own; a drag can't select across blocks. Use the reply's Copy button for
  the whole reply. This is a SwiftUI text limitation.

## Coding offline

- [ ] **Use with Claude Code.** A button that opens Terminal running Claude Code on the local
  model in a folder you pick, for outages, hotspots and experiments (not a replacement for
  Claude). The recipe is tested and kept outside this repo in `~/apps/claude-local`
  (`Claude-Local-Kapitsa.command`, `small-model-guide.md` and notes with test results):
  `--bare`, six tools, no MCP servers, approval mode forced to default (the user's global
  auto mode otherwise applies), edits optionally accepted, model and context read from
  `/v1/models`. Both the 35B and 27B passed five test tasks; the 35B is the better default.
  Open questions: whether to ship the script with the app, and how the button runs it
  without shell interpolation. Kapitsa also has `kapitsa claude`, which doesn't trim tools
  or prompts.

## Porting

- [ ] **Port the Chat page to Splash Launcher.** Bring the native chat (streaming, thinking
  levels, reasoning, attachments, outline, export and summary, auto-scroll, delete) to Splash
  Launcher. Check how Splash's server takes thinking settings and reports usage, and keep
  Splash Launcher's own colour scheme.
- [ ] **Chat from other devices (maybe).** The launcher serves a small web version of its Chat
  page, sharing the same saved chats, outline, topics and versions, reachable over Tailscale
  (for example with `tailscale serve`) and never the open internet. Today a phone can reach
  only Kapitsa's own web chat, whose chats are separate, or the whole Mac by Screen Sharing.
- [ ] **A standalone chat app.** A separate chat app that can point at any OpenAI-compatible
  engine (Kapitsa, Splash, LM Studio, oMLX and others) by URL, model and API key, without
  being built into a server launcher. The launchers could keep their built-in chats or
  hand off to it.
