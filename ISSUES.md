# Issues

What has been built in Kapitsa Launcher, and ideas for later. Ticked items are done; open
ones are planned or being considered. Bugs and requests are welcome as GitHub issues.

## Chat navigation

- [ ] **Concept map.** The topic index drawn as a graph: concepts as nodes sized by how often
  they come up, linked when they appear in the same reply; clicking one highlights its
  questions. Build only if the index alone isn't enough.
- [x] **Tangents.** Side questions under a reply, with follow-ups, kept out of the main
  conversation; continued as a new chat that starts from a summary up to that reply.
- [x] **Side questions in exports.** Quoted under their replies, with a checkbox; one side
  question can be copied or saved on its own.
- [ ] **Side questions in Find and search.** Find and the Chats search read the main
  conversation only.
- [x] **Remember folded outline questions.** Folds are saved with the chat.
- [x] **Topic index.** The first step toward the concept map: a Topics view listing each
  reply's key concepts, found by the model, with the questions where they came up; names
  are reused across the chat. Exports include topic lines, a linked topic index and optional
  tags.
- [x] **Places and themes.** The index grew by 3 to 4 topics a reply, with near-duplicates
  and one-off names. Replies now get places plus 2 to 4 broad topics, and topics are filed
  into at most about 10 themes kept with the chat, replacing the name-merging step.
- [x] **Takeaways.** A Review view in the panel: takeaways the model writes and the person
  edits, pins and adds to, linked to their questions, updated for new ones, copied or saved
  as Markdown.
- [ ] **Quiz.** A first version was built and removed before shipping, since a quiz that
  grades badly does more harm than none. It asked up to 5 questions on the takeaways, had
  the model check the answers, pinned misses and marked review dates in the Chats list. The
  35B model's grading wasn't reliable: strict, it marked a right answer wrong; generous, it
  accepted "Because it is"; on plain facts it invented "why" questions. Next try: no model
  grading. The person recalls, shows the answer and marks "I knew it / I didn't".
- [ ] **Search takeaways.** The Chats search reads messages only; takeaways the person wrote
  themselves aren't found.
- [x] **Question titles.** The outline and topic index name each question by a short title
  the model writes with its topics, with the question as written on hover.

## Chats

- [x] **Chat history list.** Saved chats, one file each with a cached index, in a Chats column
  beside the conversation; each window or tab shows its own chat, and chats are named by
  their first question's title or as written.
- [x] **Edit and regenerate.** Edit a question or regenerate a reply; earlier versions of the
  conversation from that question on are kept and can be switched back to.
- [x] **Find and search.** ⌘F finds words in the chat with a match count and highlights;
  the Chats search box also finds chats by what was said in them, and opens a result with
  Find on those words.
- [x] **Continue in a new chat with a summary.** When a chat nears the context, a new chat
  starts from a summary of the old one, which the model reads first; the two link both ways.

## Chat view

- [x] **Render Markdown in replies.** Headings, lists, quotes, rules, code blocks and tables
  now render, in finished replies and while they stream.
- [x] **Copy buttons.** Tables and a reply's thinking have Copy buttons, like code blocks;
  code blocks in list items stay in the list.

## Overview

- [x] **Latest chat reply.** The Overview showed whatever finished last, usually a background
  topic request. It now shows the latest chat reply, or any request with what sent it, and
  topic requests read an outline of long replies.

## Small fixes

- [x] **Token count reads high after deleting a middle turn.** The outline's estimate starts
  from what the model read for the latest reply, so it overstated until the next reply. Each
  reply now notes what came before it, and deleted turns come off.
- [x] **Non-places listed as places.** The model sometimes lists things like "GPS satellites"
  as places, even though the request asks for places on a map. Places with ordinary lowercase
  words are now dropped; Rio de Janeiro-style connectors are allowed.

## Coding offline

- [ ] **Use with Claude Code.** A button that opens Terminal running Claude Code on the local
  model in a folder you pick, for coding without a connection or for experiments. Claude
  Code is trimmed for a local model: a small set of tools and no MCP servers. It asks before
  making changes, with an option to accept edits automatically, and reads the model and its
  context from `/v1/models`. In testing, both the 35B and 27B models completed five coding
  tasks this way; the 35B is the better default. Kapitsa's own `kapitsa claude` starts
  Claude Code untrimmed. To decide: how the button starts Terminal without passing anything
  through a shell.

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
