# Issues

Open work for Kapitsa Launcher. This repository has no remote yet, so issues are tracked
here; move them to GitHub issues if the project is published. Tick an item when its change
is committed, and note the commit.

## Chat navigation

- [ ] **Concept map.** A map of the ideas a conversation covers and how they connect, as a way
  to navigate and review a long chat. Next in the agreed order after the outline.
- [ ] **Tangents.** Ask a side question about part of a reply without derailing the main
  conversation; from the original navigation ideas (outline, concept map, tangents,
  takeaways).
- [ ] **Remember folded outline questions.** Which questions are collapsed in the outline is
  lost when the app relaunches.

## Chats

- [ ] **Chat history list.** Several saved chats, each with its own file, outline and export,
  in a list beside the conversation; separate windows or tabs could then show different
  chats. Today every window and tab shows the same single chat, and New chat clears it
  everywhere. Kapitsa's slots already allow concurrent conversations.

## Chat view

- [ ] **Render Markdown in replies.** Headings show as `###` and tables as raw pipes; only
  inline Markdown (bold, italics, code, links) is rendered. Exports already keep the full
  Markdown.

## Small fixes

- [ ] **Token count reads high after deleting a middle turn.** The outline's estimate starts
  from what the model read for the latest reply, so it overstates until the next reply.

## Porting

- [ ] **Port the Chat page to Splash Launcher.** Bring the native chat (streaming, thinking
  levels, reasoning, attachments, outline, export and summary, auto-scroll, delete) to Splash
  Launcher. Check how Splash's server takes thinking settings and reports usage, and keep
  Splash Launcher's own colour scheme.
- [ ] **A standalone chat app.** A separate chat app that can point at any OpenAI-compatible
  engine (Kapitsa, Splash, LM Studio, oMLX and others) by URL, model and API key, without
  being built into a server launcher. The launchers could keep their built-in chats or
  hand off to it.
