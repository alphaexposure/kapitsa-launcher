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

- [ ] **Chat history list.** Several saved chats, each with its own file, outline and export,
  in a list beside the conversation; separate windows or tabs could then show different
  chats. Today every window and tab shows the same single chat, and New chat clears it
  everywhere. Kapitsa's slots already allow concurrent conversations.

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

- [ ] **Token count reads high after deleting a middle turn.** The outline's estimate starts
  from what the model read for the latest reply, so it overstates until the next reply.
- [ ] **Non-places listed as places.** The model sometimes lists things like "GPS satellites"
  as places, even though the request asks for places on a map.

## Notes for the GitHub README

- **Selecting reply text:** each block of a reply (a paragraph, a list item, a table cell)
  selects on its own; a drag can't select across blocks. Use the reply's Copy button for
  the whole reply. This is a SwiftUI text limitation.

## Porting

- [ ] **Port the Chat page to Splash Launcher.** Bring the native chat (streaming, thinking
  levels, reasoning, attachments, outline, export and summary, auto-scroll, delete) to Splash
  Launcher. Check how Splash's server takes thinking settings and reports usage, and keep
  Splash Launcher's own colour scheme.
- [ ] **A standalone chat app.** A separate chat app that can point at any OpenAI-compatible
  engine (Kapitsa, Splash, LM Studio, oMLX and others) by URL, model and API key, without
  being built into a server launcher. The launchers could keep their built-in chats or
  hand off to it.
