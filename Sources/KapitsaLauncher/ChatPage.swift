import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A chat with the model this launcher started: streamed replies, a thinking level, the
/// model's reasoning in a collapsible section, and image and document attachments.
/// What the Chat page needs to know about the server, and nothing else: the status check runs
/// every second and the log grows with every request, and neither should redraw a long chat.
struct ChatServerFacts: Equatable {
    var connection: KapitsaChatConnection?
    var isRunning: Bool
    var contextTokens: Int?
    /// The model the thinking buttons are for: the one running, else the one that ran last.
    var thinkingModel: String?
    var thinking: KapitsaThinkingOptions = .onOff
    /// A model being downloaded before Kapitsa can load it.
    var download: KapitsaEngineInfo.Download?
}

struct ChatPage: View, Equatable {
    let server: ChatServerFacts
    /// For the model menu, which follows the server itself; the page doesn't, so status
    /// checks don't redraw the conversation.
    let processController: KapitsaProcessController
    @ObservedObject var chat: KapitsaChatController
    @ObservedObject var chats: KapitsaChatLibrary
    /// The ID of `chat`, which may have no file yet.
    let chatID: UUID
    /// The chat chosen in the Chats column, a frame ahead of `chat` while it opens.
    var selectedChat: UUID?
    /// Another chat was chosen and is about to be drawn.
    var isOpening = false
    /// Shows another chat, or a new one, in this window.
    let onSelectChat: (UUID) -> Void
    /// Shows a chat from a search in the Chats column, with Find open on the searched words.
    var onOpenSearchResult: (UUID, String) -> Void = { _, _ in }
    /// Words to open Find with, when the chat was opened from a search.
    var initialFind = ""
    @State private var isDropTargeted = false
    /// Whether every message is drawn yet; see `drawnMessages`.
    @State private var drawsAllMessages = false
    @State private var findShown = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @FocusState private var findFocused: Bool
    @State private var exportError: String?
    @State private var turnToDelete: UUID?
    /// The summary being written for an export, shown in a sheet that can cancel it.
    @State private var summaryTask: Task<Void, Never>?
    /// The summary being written to continue this chat in a new one.
    @State private var continueTask: Task<Void, Never>?
    @AppStorage(KapitsaChatLibrary.nameStyleKey) private var nameStyle = KapitsaChatLibrary.NameStyle.title
    @AppStorage("chatOutlineShown") private var outlineShown = true
    @AppStorage("chatListShown") private var chatListShown = true
    @AppStorage("chatAutoScroll") private var autoScroll = true
    private let endID = "chat-end"

    /// Redrawn when what it shows changes; changes to the chat itself redraw it through `chat`.
    static func == (lhs: ChatPage, rhs: ChatPage) -> Bool {
        lhs.server == rhs.server && lhs.processController === rhs.processController && lhs.chat === rhs.chat && lhs.chatID == rhs.chatID
            && lhs.selectedChat == rhs.selectedChat && lhs.isOpening == rhs.isOpening && lhs.initialFind == rhs.initialFind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if server.connection == nil {
                Notice(server.download.map { "\($0.summary)\($0.percent.map { " (\($0)%)" } ?? ""). You can chat once it has downloaded and loaded." }
                       ?? (server.isRunning ? "Kapitsa is starting. You can chat once it's ready."
                       : "Start Kapitsa to chat with your model."),
                       symbol: server.download == nil ? "info.circle" : "arrow.down.circle")
            }
            if let exportError { Notice(exportError, symbol: "exclamationmark.triangle", isError: true) }
            conversation
            if showsContinueBanner {
                HStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(.orange)
                    Text("This chat is using most of the model's context. Continue in a new chat that starts from a summary of this one.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Continue in a New Chat", action: continueInNewChat)
                        .disabled(server.connection == nil || chat.isStreaming)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(KapitsaTheme.border, lineWidth: 1))
            }
            composer
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted, perform: handleDrop)
        .task(id: (server.thinkingModel ?? "") + "|" + chatID.uuidString) { applyThinking() }
        // A chat this one was continued in may have been deleted since.
        .task(id: [chatID] + chats.summaries.map(\.id)) {
            let existing = Set(chats.summaries.map(\.id))
            chat.forgetMissingChats { existing.contains($0) }
        }
        .confirmationDialog("Delete this question and its reply?",
                            isPresented: Binding(get: { turnToDelete != nil }, set: { if !$0 { turnToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = turnToDelete { chat.deleteTurn(endingWith: id) }
                turnToDelete = nil
            }
        } message: {
            Text("It's removed from the chat and from what the model sees in later replies."
                 + (turnHasOtherVersions ? " The question's other versions are deleted too." : "")
                 + " This can't be undone.")
        }
        .sheet(isPresented: Binding(get: { summaryTask != nil || continueTask != nil }, set: { _ in })) {
            VStack(spacing: 14) {
                ProgressView()
                Text(continueTask != nil ? "Kapitsa is summarising this chat for the new one…" : "Kapitsa is writing the summary…")
                    .font(.headline)
                Text("Thinking is off, so this usually takes a few seconds; a long chat is summarised in parts.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Cancel") {
                    summaryTask?.cancel()
                    summaryTask = nil
                    continueTask?.cancel()
                    continueTask = nil
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 340)
        }
    }

    /// Offered once the chat fills three quarters of the context, until it has been continued.
    private var showsContinueBanner: Bool {
        guard chat.continuedIn == nil, let context = server.contextTokens, context > 0,
              let tokens = KapitsaChatOutline.conversationTokens(in: chat.messages) else { return false }
        return Double(tokens) / Double(context) >= 0.75
    }

    /// Summarises this chat, then opens a new chat that starts from the summary, linked both ways.
    private func continueInNewChat() {
        guard let connection = server.connection, continueTask == nil, !chat.messages.isEmpty else { return }
        let messages = chat.messages, contextTokens = server.contextTokens
        let name = chats.summaries.first { $0.id == chatID }?.name(nameStyle) ?? "Earlier chat"
        exportError = nil
        continueTask = Task {
            do {
                let summary = try await KapitsaChatSummary.write(
                    for: messages, connection: connection, contextTokens: contextTokens,
                    send: chat.requestLabels.labelling(KapitsaChatSummary.urlSessionSend, as: .summary))
                guard !Task.isCancelled else { return }
                let newID = UUID()
                chats.controller(for: newID).startContinuation(
                    KapitsaChatContinuation(chatID: chatID, name: name, summary: summary.text))
                chat.markContinued(in: newID)
                continueTask = nil
                onSelectChat(newID)
            } catch {
                if !Task.isCancelled { exportError = error.localizedDescription }
                continueTask = nil
            }
        }
    }

    private func handleTangentAction(_ replyID: UUID, _ action: ChatTangentAction) {
        switch action {
        case .collapse(let id, let collapsed): chat.setTangentCollapsed(id, on: replyID, collapsed)
        case .delete(let id): chat.deleteTangent(id, on: replyID)
        case .branch(let id): continueTangent(id, on: replyID)
        case .open(let chatID): onSelectChat(chatID)
        case .copy(let id):
            guard let markdown = sideQuestionMarkdown(id, on: replyID) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        case .save(let id):
            guard let markdown = sideQuestionMarkdown(id, on: replyID),
                  let first = chat.messages.first(where: { $0.id == replyID })?.tangents?
                      .first(where: { $0.id == id })?.messages.first else { return }
            let panel = NSSavePanel()
            let name = KapitsaChatOutline.question(for: first)
                .replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression)
            panel.nameFieldStringValue = "Side question – \(name.prefix(60)).md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = "Couldn't save the side question: \(error.localizedDescription)"
            }
        }
    }

    /// A side question as Markdown, naming this chat and the question its reply answered.
    private func sideQuestionMarkdown(_ id: UUID, on replyID: UUID) -> String? {
        guard let replyIndex = chat.messages.firstIndex(where: { $0.id == replyID }),
              let tangent = chat.messages[replyIndex].tangents?.first(where: { $0.id == id }) else { return nil }
        let reply = chat.messages[replyIndex]
        let question = replyIndex > 0 && chat.messages[replyIndex - 1].role == .user
            ? (reply.title.flatMap { $0.isEmpty ? nil : $0 } ?? KapitsaChatOutline.question(for: chat.messages[replyIndex - 1]))
            : nil
        let name = chats.summaries.first { $0.id == chatID }?.name(nameStyle) ?? "Chat"
        return KapitsaChatExport.sideQuestion(tangent, chatName: name, about: question)
    }

    /// Summarises the chat up to the reply, then opens a new chat that starts from that summary
    /// with the side question's thread as its first messages, linked both ways.
    private func continueTangent(_ tangentID: UUID, on replyID: UUID) {
        guard let connection = server.connection, continueTask == nil,
              let replyIndex = chat.messages.firstIndex(where: { $0.id == replyID }),
              let tangent = chat.messages[replyIndex].tangents?.first(where: { $0.id == tangentID }) else { return }
        let messages = Array(chat.messages[...replyIndex]), contextTokens = server.contextTokens
        let name = chats.summaries.first { $0.id == chatID }?.name(nameStyle) ?? "Earlier chat"
        exportError = nil
        continueTask = Task {
            do {
                let summary = try await KapitsaChatSummary.write(
                    for: messages, connection: connection, contextTokens: contextTokens,
                    send: chat.requestLabels.labelling(KapitsaChatSummary.urlSessionSend, as: .summary))
                guard !Task.isCancelled else { return }
                let newID = UUID()
                chats.controller(for: newID).startBranch(
                    KapitsaChatContinuation(chatID: chatID, name: name, summary: summary.text, isBranch: true),
                    messages: tangent.messages)
                chat.markTangentContinued(tangentID, on: replyID, in: newID)
                continueTask = nil
                onSelectChat(newID)
            } catch {
                if !Task.isCancelled { exportError = error.localizedDescription }
                continueTask = nil
            }
        }
    }

    private var findMatches: [KapitsaChatFind.Match] {
        findShown ? KapitsaChatFind.matches(of: findQuery, in: chat.messages) : []
    }

    private var currentMatch: KapitsaChatFind.Match? {
        let matches = findMatches
        return matches.isEmpty ? nil : matches[min(findIndex, matches.count - 1)]
    }

    private func openFind() {
        findShown = true
        findFocused = true
    }

    /// Scrolls to match `index`, wrapping around at either end.
    private func showMatch(_ index: Int, _ proxy: ScrollViewProxy) {
        let matches = findMatches
        guard !matches.isEmpty else { return }
        findIndex = (index % matches.count + matches.count) % matches.count
        // Line up the point of the message where the match sits with the same point of the view,
        // so the word is in view, and the next match in the same message moves the view only a little.
        let match = matches[findIndex]
        let anchor = UnitPoint(x: 0.5, y: min(max(match.position, 0.1), 0.9))
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(match.messageID, anchor: anchor) }
    }

    /// Find in this chat: the words, how many matches, and buttons to step through them.
    private func findBar(_ proxy: ScrollViewProxy) -> some View {
        let matches = findMatches
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in chat", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { showMatch(findIndex + 1, proxy) }
                .onExitCommand { findShown = false }
                .onChange(of: findQuery) { findIndex = 0; showMatch(0, proxy) }
            Text(KapitsaChatFind.searchable(findQuery) == nil ? ""
                 : matches.isEmpty ? "No matches" : "\(min(findIndex, matches.count - 1) + 1) of \(matches.count)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Group {
                Button { showMatch(findIndex - 1, proxy) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Previous match (⇧⌘G)")
                Button { showMatch(findIndex + 1, proxy) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut("g")
                    .help("Next match (⌘G or Return)")
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            Button("Done") { findShown = false }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(KapitsaTheme.border, lineWidth: 1))
        .onAppear { findFocused = true }
    }

    /// Whether the question of the turn about to be deleted has other versions.
    private var turnHasOtherVersions: Bool {
        guard let id = turnToDelete else { return false }
        return KapitsaChatExport.turn(endingWith: id, in: chat.messages).contains { $0.versionCount > 1 }
    }

    /// Puts the level this chat's model last used, or its default, on the buttons.
    private func applyThinking() {
        guard let model = server.thinkingModel else { return }
        let level = server.thinking.valid(KapitsaThinkingChoice.saved(for: model))
        if chat.thinking != level { chat.thinking = level }
    }

    private func setThinking(_ level: KapitsaThinkingLevel) {
        chat.thinking = level
        if let model = server.thinkingModel { KapitsaThinkingChoice.save(level, for: model) }
    }

    /// The level the latest reply was written with.
    private var lastReplyLevel: KapitsaThinkingLevel? {
        chat.messages.last { $0.role == .assistant }?.thinking
    }

    /// Whether the next reply will read the whole chat again: a model whose level sits at the
    /// start of the prompt, set differently from the latest reply.
    private var rereadsChat: Bool {
        guard !chat.isStreaming, let last = lastReplyLevel else { return false }
        return server.thinking.changesPromptStart(from: last, to: chat.thinking)
    }

    private var thinkingHelp: String {
        let model = server.thinkingModel.map { " for \($0)" } ?? ""
        switch server.thinking.kind {
        case .onOff: return "Whether the model reasons before it answers\(model). Off answers at once. Applies to your next message; each model keeps its own choice."
        case .effort: return "How much the model reasons before it answers\(model): Off, or one of its effort levels. Changing it mid-chat makes the next reply read the whole chat again, since the level is at the start of the prompt. Each model keeps its own choice."
        case .shorterFull: return "How much the model reasons before it answers\(model): Off, Shorter (a note asks for efficient reasoning) or Full. Applies to your next message; each model keeps its own choice."
        case .none: return "This model's chat template has no thinking switch, so it decides for itself\(model.isEmpty ? "" : " (" + server.thinkingModel! + ")")."
        }
    }

    /// From the left: the Chats column's switch, the model with its thinking buttons, then
    /// Find, New chat and a menu for the rest, and the side panel's switch at the right.
    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $chatListShown) { Label("Chats", systemImage: "sidebar.left") }
                .toggleStyle(KapitsaPanelToggleStyle())
                .help("Chats: show or hide the list of your saved chats")
            Divider().frame(height: 18)
            ModelSwitcher(controller: processController, isBusy: chat.isStreaming)
            Text("Thinking").font(.callout)
            SettingHelpIcon(title: "Thinking", message: thinkingHelp)
            if server.thinking.levels.isEmpty {
                Text("Set by the model").font(.callout).foregroundStyle(.secondary)
            } else {
                KapitsaSegmentedPicker(options: server.thinking.levels,
                                       selection: Binding(get: { chat.thinking }, set: setThinking),
                                       label: server.thinking.label, segmentWidth: 76)
                    .accessibilityLabel("Thinking")
            }
            // Its place is kept for models whose level can re-read the chat, so the buttons
            // to the right don't move when it appears.
            if server.thinking.changeRereadsChat {
                Label("Next reply re-reads the chat", systemImage: "arrow.counterclockwise")
                    .font(.caption).foregroundStyle(KapitsaTheme.accent)
                    .opacity(rereadsChat ? 1 : 0)
                    .accessibilityHidden(!rereadsChat)
                    .help("This model's thinking level sits at the start of the prompt, so after a change Kapitsa can't reuse its cache: the next reply reads the whole chat again before it starts. Switching back to \(lastReplyLevel.map { server.thinking.label($0) } ?? "the earlier level") avoids it.")
            }
            Spacer(minLength: 10)
            // Labelled buttons when there's room, icons alone in a narrow window.
            ViewThatFits(in: .horizontal) {
                actions.labelStyle(.titleAndIcon)
                actions.labelStyle(.iconOnly)
            }
            Divider().frame(height: 18)
            Toggle(isOn: $outlineShown) { Label("Side panel", systemImage: "sidebar.right") }
                .toggleStyle(KapitsaPanelToggleStyle())
                .help("Side panel: show or hide the Outline, Topics and Review")
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: openFind) { Label("Find", systemImage: "magnifyingglass") }
                .keyboardShortcut("f")
                .disabled(chat.messages.isEmpty)
                .help("Find: search this chat for words (⌘F)")
            Button { onSelectChat(UUID()) } label: { Label("New chat", systemImage: "square.and.pencil") }
                .disabled(chat.messages.isEmpty)
                .help("New chat: start a new conversation; this one stays in your chats")
            Menu {
                Toggle("Auto-scroll", isOn: $autoScroll)
                Button("Export Chat…") { export(chat.messages) }
                    .disabled(chat.messages.isEmpty || chat.isStreaming)
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More: Auto-scroll, which follows a reply as it's written, and Export, which saves the whole chat as Markdown")
        }
        .fixedSize()
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 12) {
                if chatListShown {
                    ChatListView(chats: chats, selected: selectedChat ?? chatID, onSelect: onSelectChat,
                                 onOpenSearchResult: onOpenSearchResult)
                        .frame(width: 220)
                }
                messageColumn(proxy)
                if outlineShown && !chat.messages.isEmpty {
                    ChatOutlineView(
                        messages: chat.messages, contextTokens: server.contextTokens,
                        canFindTopics: server.connection != nil, topicProgress: chat.topicProgress,
                        topicThemes: chat.topicThemes,
                        onSelect: { proxy.scrollTo($0, anchor: .top) },
                        onCollapse: { chat.setOutlineCollapsed($0, questions: $1) },
                        onFindTopics: { if let connection = server.connection { chat.findMissingTopics(connection: connection) } },
                        onRedoTopics: { if let connection = server.connection { chat.redoAllTopics(connection: connection) } },
                        onStopFindingTopics: chat.stopFindingTopics,
                        onFoldSideQuestions: chat.setAllTangentsCollapsed,
                        onContinue: chat.continuedIn == nil ? continueInNewChat : nil,
                        chat: chat, connection: server.connection,
                        chatName: chats.summaries.first { $0.id == chatID }?.name(nameStyle) ?? "Chat")
                    .equatable()
                    .frame(width: 290)
                }
            }
        }
    }

    /// How much of the reply being written has arrived: cheap to compare, unlike the text.
    private var liveLength: Int {
        (chat.liveReply?.text.utf8.count ?? 0) + (chat.liveReply?.reasoning.utf8.count ?? 0)
    }

    /// The messages drawn: at first only the newest, where a chat opens, so a long chat shows
    /// at once; the earlier ones follow a moment later.
    private var drawnMessages: [KapitsaChatMessage] {
        drawsAllMessages ? chat.messages : Array(chat.messages.suffix(Self.firstDrawn))
    }

    private static let firstDrawn = 8

    /// The conversation's contents, inside its scroll view.
    private var messages: some View {
                    VStack(alignment: .leading, spacing: 18) {
                        if let continuation = chat.continuesFrom {
                            ContinuationCard(continuation: continuation,
                                             onOpen: chats.summaries.contains { $0.id == continuation.chatID }
                                                 ? { onSelectChat(continuation.chatID) } : nil)
                        }
                        if chat.messages.isEmpty && chat.liveReply == nil && chat.continuesFrom == nil {
                            VStack(spacing: 10) {
                                KapitsaMarkShape().fill(KapitsaTheme.accent.opacity(0.5)).frame(width: 34, height: 34)
                                Text("Ask anything. Drop images or documents here to include them.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        // Finished messages don't change while a reply streams; comparing them is
                        // cheap, so SwiftUI skips redrawing them on each update.
                        ChatHistory(messages: drawnMessages,
                                    canResend: server.connection != nil && !chat.isStreaming,
                                    findQuery: findShown ? findQuery : "",
                                    currentMatch: findShown ? currentMatch : nil,
                                    onExport: { id in export(KapitsaChatExport.turn(endingWith: id, in: chat.messages)) },
                                    onDelete: { turnToDelete = $0 },
                                    onResend: { id, text in
                                        if let connection = server.connection { chat.resend(id, text: text, connection: connection) }
                                    },
                                    onShowVersion: { chat.showVersion($1, of: $0) },
                                    tangentStream: chat.tangentStream,
                                    onAskTangent: { replyID, tangentID, text in
                                        if let connection = server.connection {
                                            chat.askTangent(about: replyID, in: tangentID, text: text, connection: connection)
                                        }
                                    },
                                    onTangentAction: handleTangentAction)
                        .equatable()
                        if let live = chat.liveReply {
                            ChatMessageView(message: live, isLive: true, onExport: {}, onDelete: {})
                                .id(live.id)
                        }
                        if let next = chat.continuedIn {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(KapitsaTheme.accent)
                                Text("Continued in a new chat that starts from a summary of this one.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Open") { onSelectChat(next) }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id(endID)
                    }
    }

    /// The find bar and the conversation itself, between the Chats column and the outline.
    private func messageColumn(_ proxy: ScrollViewProxy) -> some View {
                VStack(spacing: 8) {
                if findShown { findBar(proxy) }
                ScrollView {
                    // Not lazy: a lazy stack guesses the height of messages it hasn't drawn, so
                    // jumping to the end past long replies could land below the content and show
                    // a blank view until the next scroll. Finished messages aren't redrawn while
                    // a reply streams, so measuring them all costs little.
                    messages
                    .padding(18)
                }
                .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(isDropTargeted ? KapitsaTheme.accent : KapitsaTheme.border, lineWidth: isDropTargeted ? 2 : 1))
                .overlay { if isOpening { OpeningOverlay() } }
                .onAppear {
                    proxy.scrollTo(endID, anchor: .bottom)
                    // A search may land on an earlier message, so it needs them all at once.
                    guard initialFind.isEmpty, chat.messages.count > Self.firstDrawn else { drawsAllMessages = true; return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        drawsAllMessages = true
                        // The earlier messages go in above; stay at the end.
                        try? await Task.sleep(for: .milliseconds(10))
                        proxy.scrollTo(endID, anchor: .bottom)
                    }
                }
                // Cheap to compare: an ID and two byte lengths, not the whole conversation.
                // Sending always shows the new question; following the reply is optional.
                .onChange(of: chat.messages.last?.id) {
                    if autoScroll || chat.messages.last?.role == .user { proxy.scrollTo(endID, anchor: .bottom) }
                }
                .onChange(of: liveLength) {
                    if autoScroll { proxy.scrollTo(endID, anchor: .bottom) }
                }
                .onChange(of: autoScroll) { if autoScroll { proxy.scrollTo(endID, anchor: .bottom) } }
                }
                .onAppear {
                    guard !initialFind.isEmpty else { return }
                    findQuery = initialFind
                    findShown = true
                    // After the conversation's own jump to the end.
                    DispatchQueue.main.async { showMatch(0, proxy) }
                }
                // A search result for the chat already shown.
                .onChange(of: initialFind) {
                    guard !initialFind.isEmpty else { return }
                    findQuery = initialFind
                    findShown = true
                }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chat.pendingAttachments) { attachment in
                            AttachmentChip(attachment: attachment) { chat.removeAttachment(attachment.id) }
                        }
                    }
                }
            }
            if let error = chat.attachmentError {
                Notice(error, symbol: "exclamationmark.triangle", isError: true)
            }
            ChatInputRow(chat: chat, canConnect: server.connection != nil,
                         onAttach: chooseFiles, onSend: send)
        }
    }

    /// Asks where to save and what to include, then writes the Markdown and, beside it, a
    /// folder for any images. A summary is written by the model first, behind a progress sheet.
    private func export(_ messages: [KapitsaChatMessage]) {
        guard !messages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = KapitsaChatExport(messages: messages).suggestedFileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let accessory = ExportOptionsAccessory(canSummarize: server.connection != nil)
        panel.accessoryView = accessory.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accessory.remember()
        let options = accessory.options
        exportError = nil
        guard options.includeSummary, let connection = server.connection else {
            write(messages, to: url, options: options, summary: nil)
            return
        }
        let contextTokens = server.contextTokens
        summaryTask = Task {
            do {
                let summary = try await KapitsaChatSummary.write(
                    for: messages, connection: connection, contextTokens: contextTokens,
                    send: chat.requestLabels.labelling(KapitsaChatSummary.urlSessionSend, as: .summary))
                if !Task.isCancelled { write(messages, to: url, options: options, summary: summary) }
            } catch {
                if !Task.isCancelled { exportError = error.localizedDescription }
            }
            summaryTask = nil
        }
    }

    private func write(_ messages: [KapitsaChatMessage], to url: URL, options: KapitsaChatExport.Options,
                       summary: KapitsaChatSummary?) {
        do {
            try KapitsaChatExport.write(messages, to: url, options: options, summary: summary, topicThemes: chat.topicThemes)
        } catch {
            exportError = "Couldn't save the export: \(error.localizedDescription)"
        }
    }

    /// Sends `text` with any attachments; false when nothing was sent, so the box keeps it.
    private func send(_ text: String) -> Bool {
        guard let connection = server.connection else { return false }
        chat.draft = text
        guard chat.canSend else { return false }
        chat.send(to: connection)
        return true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        if panel.runModal() == .OK { attach(urls: panel.urls) }
    }

    private func attach(urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            do { chat.addAttachments([try KapitsaAttachmentLoader.load(url)]) }
            catch { errors.append(error.localizedDescription) }
        }
        chat.attachmentError = errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { attach(urls: [url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async {
                        do { chat.addAttachments([try KapitsaAttachmentLoader.imageAttachment(image, name: "Dropped image.jpg")]) }
                        catch { chat.attachmentError = error.localizedDescription }
                    }
                }
            }
        }
        return true
    }
}

/// The finished messages. Equal when the array is unchanged, which Swift checks without
/// looking inside it, so a streaming reply doesn't make SwiftUI revisit the whole conversation.
private struct ChatHistory: View, Equatable {
    let messages: [KapitsaChatMessage]
    /// False while a reply streams or Kapitsa isn't running.
    let canResend: Bool
    /// Words to highlight, from Find, and the match Find is on.
    let findQuery: String
    let currentMatch: KapitsaChatFind.Match?
    let onExport: (UUID) -> Void
    let onDelete: (UUID) -> Void
    /// A question's ID and the text to send it with: edited, or unchanged to regenerate.
    let onResend: (UUID, String) -> Void
    let onShowVersion: (UUID, Int) -> Void
    let tangentStream: KapitsaTangentStream
    /// A reply's ID, the side question to follow up (nil for a new one), and the text.
    let onAskTangent: (UUID, UUID?, String) -> Void
    let onTangentAction: (UUID, ChatTangentAction) -> Void

    static func == (lhs: ChatHistory, rhs: ChatHistory) -> Bool {
        lhs.messages == rhs.messages && lhs.canResend == rhs.canResend
            && lhs.findQuery == rhs.findQuery && lhs.currentMatch == rhs.currentMatch
    }

    var body: some View {
        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            let question = index > 0 && messages[index - 1].role == .user ? messages[index - 1] : nil
            ChatMessageView(message: message, isLive: false, canResend: canResend,
                            findQuery: findQuery,
                            currentOccurrence: currentMatch?.messageID == message.id ? currentMatch?.occurrence : nil,
                            onExport: { onExport(message.id) }, onDelete: { onDelete(message.id) },
                            onResend: { onResend(message.id, $0) },
                            onRegenerate: question.map { question in { onResend(question.id, question.text) } },
                            onShowVersion: { onShowVersion(message.id, $0) },
                            tangentStream: tangentStream,
                            onAskTangent: { onAskTangent(message.id, $0, $1) },
                            onTangentAction: { onTangentAction(message.id, $0) })
                // Stepping through Find's matches redraws only the messages whose marks change.
                .equatable()
                .id(message.id)
        }
    }
}

/// The message box and the Send or Stop button. It keeps what's being typed in its own
/// state, so a keystroke redraws only this row, not the conversation and side panel.
private struct ChatInputRow: View {
    @ObservedObject var chat: KapitsaChatController
    let canConnect: Bool
    let onAttach: () -> Void
    let onSend: (String) -> Bool
    @State private var text: String
    @FocusState private var focused: Bool

    init(chat: KapitsaChatController, canConnect: Bool, onAttach: @escaping () -> Void, onSend: @escaping (String) -> Bool) {
        self.chat = chat
        self.canConnect = canConnect
        self.onAttach = onAttach
        self.onSend = onSend
        // An unsent message stays with its chat while another is shown.
        _text = State(initialValue: chat.draft)
    }

    private var canSend: Bool {
        canConnect && !chat.isStreaming
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.pendingAttachments.isEmpty)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button(action: onAttach) {
                Image(systemName: "paperclip").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Attach images or documents")
            .accessibilityLabel("Attach files")
            TextField("Message Kapitsa", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                // Not published, so typing doesn't redraw the page.
                .onChange(of: text) { chat.draft = text }
                .padding(.vertical, 6)
            if chat.isStreaming {
                Button(action: chat.stop) {
                    Image(systemName: "stop.fill").frame(width: 30, height: 30)
                }
                .buttonStyle(.borderedProminent).tint(KapitsaTheme.accentFill)
                .help("Stop the reply")
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.borderedProminent).tint(KapitsaTheme.accentFill)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return; Option-Return for a new line)")
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KapitsaTheme.border, lineWidth: 1))
        .onAppear { focused = true }
    }

    private func send() {
        guard canSend, onSend(text) else { return }
        text = ""
    }
}

/// The panel beside the chat, in two views. Outline: the questions asked so far, numbered,
/// each with the headings of its reply, which fold away with its chevron. Topics: the key
/// concepts of every reply, alphabetically, each with the questions where it came up. Clicking
/// a question scrolls the chat to it. Equatable for the same reason as `ChatHistory`.
private struct ChatOutlineView: View, Equatable {
    enum Mode: String { case outline, topics, review }

    let messages: [KapitsaChatMessage]
    /// The model's context per conversation, from Kapitsa's startup lines; nil when not running.
    let contextTokens: Int?
    /// False when Kapitsa isn't running, so there's no model to find topics.
    let canFindTopics: Bool
    let topicProgress: KapitsaChatController.TopicProgress?
    let topicThemes: [String: String]
    let onSelect: (UUID) -> Void
    let onCollapse: (Bool, Set<UUID>) -> Void
    let onFindTopics: () -> Void
    let onRedoTopics: () -> Void
    let onStopFindingTopics: () -> Void
    /// Folds (true) or opens every side question.
    let onFoldSideQuestions: (Bool) -> Void
    /// Continues the chat in a new one from a summary; nil once it has been continued.
    var onContinue: (() -> Void)?
    /// For the Review view, which follows the chat itself.
    let chat: KapitsaChatController
    let connection: KapitsaChatConnection?
    let chatName: String
    @AppStorage("chatPanelMode") private var mode = Mode.outline

    static func == (lhs: ChatOutlineView, rhs: ChatOutlineView) -> Bool {
        lhs.messages == rhs.messages && lhs.contextTokens == rhs.contextTokens
            && lhs.canFindTopics == rhs.canFindTopics && lhs.topicProgress == rhs.topicProgress
            && lhs.topicThemes == rhs.topicThemes && lhs.chat === rhs.chat && lhs.connection == rhs.connection
            && lhs.chatName == rhs.chatName
    }

    var body: some View {
        let entries = KapitsaChatOutline.entries(from: messages)
        VStack(alignment: .leading, spacing: 0) {
            KapitsaSegmentedPicker(options: [Mode.outline, .topics, .review], selection: $mode) { mode in
                switch mode {
                case .outline: return "Outline"
                case .topics: return "Topics"
                case .review: return "Review"
                }
            }
            .accessibilityLabel("Side panel view")
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            if let tokens = KapitsaChatOutline.conversationTokens(in: messages) {
                VStack(alignment: .leading, spacing: 4) {
                    ConversationSize(tokens: tokens, contextTokens: contextTokens)
                    if let onContinue {
                        Button("Continue in a new chat…", action: onContinue)
                            .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                            .disabled(!canFindTopics)
                            .help("Start a new chat that begins from a summary of this one, for when this chat nears the model's context.")
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            switch mode {
            case .outline: outline(entries)
            case .topics:
                ChatTopicsView(entries: entries, themes: topicThemes, canFindTopics: canFindTopics, progress: topicProgress,
                               onSelect: onSelect, onFind: onFindTopics, onRedo: onRedoTopics,
                               onStop: onStopFindingTopics)
            case .review:
                ChatReviewView(chat: chat, connection: connection, contextTokens: contextTokens,
                               questions: Dictionary(entries.map { ($0.id, (number: $0.number, title: $0.displayTitle)) },
                                                     uniquingKeysWith: { first, _ in first }),
                               chatName: chatName, onSelect: onSelect)
            }
        }
        .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KapitsaTheme.border, lineWidth: 1))
    }

    @ViewBuilder
    private func outline(_ entries: [KapitsaChatOutline.Entry]) -> some View {
        let foldable = entries.filter { !$0.headings.isEmpty }
        let allCollapsed = !foldable.isEmpty && foldable.allSatisfy(\.isCollapsed)
        let untitled = entries.filter(\.needsTopics).count
        HStack(spacing: 8) {
            Text("\(entries.count) \(entries.count == 1 ? "question" : "questions")")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let topicProgress {
                Text("Titling \(topicProgress.done) of \(topicProgress.total)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else if untitled > 0 {
                // Titles come with each reply's topics; older chats find them here.
                Button("Find titles", action: onFindTopics)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                    .disabled(!canFindTopics)
                    .help(canFindTopics ? "Ask the model for a short title for the \(untitled) \(untitled == 1 ? "question" : "questions") without one, with its places and topics, one at a time, with thinking off."
                                        : "Start Kapitsa to find titles.")
            }
            Spacer()
            if !foldable.isEmpty {
                Button(allCollapsed ? "Expand all" : "Collapse all") {
                    onCollapse(!allCollapsed, Set(foldable.map(\.id)))
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        let tangents = messages.flatMap { $0.tangents ?? [] }
        if !tangents.isEmpty {
            let allFolded = tangents.allSatisfy { $0.isCollapsed == true }
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(KapitsaTheme.accent)
                Text("\(tangents.count) side \(tangents.count == 1 ? "question" : "questions")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(allFolded ? "Show all" : "Fold all") { onFoldSideQuestions(!allFolded) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                    .help(allFolded ? "Open every side question in the chat" : "Fold every side question in the chat away")
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    ChatOutlineRow(entry: entry, isCollapsed: entry.isCollapsed,
                                   onToggle: { onCollapse(!entry.isCollapsed, [entry.id]) }, onSelect: onSelect)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 10)
        }
    }
}

/// The topic index: the places the replies discussed, then themes, each opening to its topics
/// (a theme of one topic shows just the topic), and each place or topic to the questions
/// where it came up; the most discussed first. A
/// filter flattens it to the matching themes, places and topics.
private struct ChatTopicsView: View {
    let entries: [KapitsaChatOutline.Entry]
    let themes: [String: String]
    let canFindTopics: Bool
    let progress: KapitsaChatController.TopicProgress?
    let onSelect: (UUID) -> Void
    let onFind: () -> Void
    let onRedo: () -> Void
    let onStop: () -> Void
    @State private var filter = ""
    @State private var confirmRedo = false
    @State private var expanded: Set<String> = []
    @AppStorage("chatTopicsPlacesFolded") private var placesFolded = false
    @AppStorage("chatTopicsTopicsFolded") private var topicsFolded = false

    var body: some View {
        let index = KapitsaChatTopics.index(entries, themes: themes)
        let missing = entries.filter(\.needsTopics).count
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter places, themes and topics", text: $filter)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .padding(.horizontal, 12)
            HStack {
                Text(counts(index)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !index.isEmpty && progress == nil {
                    Button("Redo all") { confirmRedo = true }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                        .disabled(!canFindTopics)
                        .help(canFindTopics ? "Find every reply's places and topics again, and regroup the themes."
                                            : "Start Kapitsa to find topics.")
                }
            }
            .padding(.horizontal, 12)
            .confirmationDialog("Find all topics again?", isPresented: $confirmRedo) {
                Button("Redo all", action: onRedo)
            } message: {
                Text("Each reply's places and topics are replaced, one reply at a time, and the themes are regrouped.")
            }
            if let progress {
                HStack(spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear).controlSize(.small)
                    Text("\(progress.done) of \(progress.total)").font(.caption).monospacedDigit()
                    Button("Stop", action: onStop).buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                }
                .padding(.horizontal, 12)
            } else if missing > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(missing) \(missing == 1 ? "reply has" : "replies have") no topics or title yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Find topics", action: onFind)
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(KapitsaTheme.accent)
                        .disabled(!canFindTopics)
                        .help(canFindTopics ? "Ask the model for the titles, places and topics of those replies, one at a time, with thinking off."
                                            : "Start Kapitsa to find topics.")
                }
                .padding(.horizontal, 12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filter.isEmpty {
                        if !index.places.isEmpty {
                            section("Places", count: index.places.count, folded: $placesFolded)
                            if !placesFolded { ForEach(index.places) { place in
                                ChatTopicRow(topic: place, symbol: "mappin.and.ellipse", isExpanded: isExpanded("place:" + place.id),
                                             onToggle: { toggle("place:" + place.id) }, onSelect: onSelect)
                            } }
                        }
                        if !index.themes.isEmpty {
                            section("Topics", count: index.themes.reduce(0) { $0 + $1.topics.count }, folded: $topicsFolded)
                            if !topicsFolded { ForEach(index.themes) { theme in
                                // A theme of one topic would only add a click; show the topic itself.
                                if theme.topics.count == 1, let topic = theme.topics.first {
                                    ChatTopicRow(topic: topic, isExpanded: isExpanded("topic:" + topic.id),
                                                 onToggle: { toggle("topic:" + topic.id) }, onSelect: onSelect)
                                } else {
                                    ChatThemeRow(theme: theme, expanded: $expanded, onSelect: onSelect)
                                }
                            } }
                        }
                    } else {
                        filtered(index)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
        }
    }

    /// Themes whose name matches, open to all their topics, then the other matching places and topics.
    @ViewBuilder
    private func filtered(_ index: KapitsaChatTopics.Index) -> some View {
        let themes = index.themes.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let inThemes = Set(themes.flatMap(\.topics).map(\.id))
        let topics = index.all.filter { $0.name.localizedCaseInsensitiveContains(filter) && !inThemes.contains($0.id) }
        ForEach(themes) { theme in
            let key = "theme:" + theme.name
            ChatThemeRow(theme: theme, expanded: Binding(get: { expanded.union([key]) }, set: { expanded = $0 }),
                         onSelect: onSelect)
        }
        ForEach(topics) { topic in
            ChatTopicRow(topic: topic, isExpanded: true, onToggle: {}, onSelect: onSelect)
        }
        if themes.isEmpty && topics.isEmpty {
            Text("Nothing matches “\(filter)”.").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.top, 6)
        }
    }

    private func counts(_ index: KapitsaChatTopics.Index) -> String {
        let topics = index.themes.reduce(0) { $0 + $1.topics.count }
        var parts: [String] = []
        if !index.places.isEmpty { parts.append("\(index.places.count) \(index.places.count == 1 ? "place" : "places")") }
        parts.append("\(topics) \(topics == 1 ? "topic" : "topics")")
        return parts.joined(separator: " · ")
    }

    /// A section heading that folds its list away; the choice is remembered.
    private func section(_ title: String, count: Int, folded: Binding<Bool>) -> some View {
        Button { folded.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(folded.wrappedValue ? 0 : 90))
                Text(title.uppercased()).font(.caption2.weight(.semibold))
                Text("\(count)").font(.caption2).monospacedDigit()
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folded.wrappedValue ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
        .accessibilityLabel("\(title), \(count), \(folded.wrappedValue ? "folded" : "open")")
    }

    private func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// A theme: its name and how many questions it covers, opening to its topics.
private struct ChatThemeRow: View {
    let theme: KapitsaChatTopics.Theme
    @Binding var expanded: Set<String>
    let onSelect: (UUID) -> Void
    @State private var hovered = false

    private var key: String { "theme:" + theme.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(key) ? 90 : 0))
                        .frame(width: 12)
                    Text(theme.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(theme.mentions.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(hovered ? KapitsaTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
            .accessibilityLabel("\(theme.name), \(theme.topics.count) topics, \(theme.mentions.count) questions")
            if expanded.contains(key) {
                ForEach(theme.topics) { topic in
                    let id = "topic:" + topic.id
                    ChatTopicRow(topic: topic, isExpanded: expanded.contains(id),
                                 onToggle: { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } },
                                 onSelect: onSelect)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

/// A place or topic: its name and how many questions mention it, opening to those questions.
private struct ChatTopicRow: View {
    let topic: KapitsaChatTopics.Topic
    var symbol: String?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSelect: (UUID) -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row(key: -1, action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    if let symbol {
                        Image(systemName: symbol).font(.caption).foregroundStyle(KapitsaTheme.accent)
                    }
                    Text(topic.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(topic.mentions.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("\(topic.name), \(topic.mentions.count) questions")
            if isExpanded {
                ForEach(Array(topic.mentions.enumerated()), id: \.offset) { index, mention in
                    row(key: index, help: mention.fullQuestion, action: { onSelect(mention.id) }) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(mention.number)").font(.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(KapitsaTheme.accent).frame(minWidth: 16, alignment: .trailing)
                            Text(mention.question).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func row(key: Int, help: String = "", action: @escaping () -> Void,
                     @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .background(hovered == key ? KapitsaTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
    }
}

/// About how much the model reads for the next message, against its context when known.
/// Over the conversation while another chosen chat is about to be drawn.
private struct OpeningOverlay: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Opening…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KapitsaTheme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// At the top of a chat that continues another: which one, a link back, and the summary the
/// model starts from.
private struct ContinuationCard: View {
    let continuation: KapitsaChatContinuation
    /// Nil once the earlier chat has been deleted; the summary still stands in for it.
    let onOpen: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.up.left").foregroundStyle(KapitsaTheme.accent)
                Text(continuation.isBranch == true ? "Branched from a side question in “\(continuation.name)”"
                     : "Continues “\(continuation.name)”").font(.callout.weight(.medium))
                Spacer()
                if let onOpen {
                    Button("Open", action: onOpen).help("Open the earlier chat")
                } else {
                    Text("Deleted").font(.caption).foregroundStyle(.secondary)
                        .help("The earlier chat was deleted. The model still reads its summary.")
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                ChatMarkdownView(text: continuation.summary).padding(.top, 4)
            } label: {
                Text("The summary the model starts from").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ConversationSize: View {
    let tokens: Int
    let contextTokens: Int?

    private var fraction: Double? { contextTokens.map { min(1, Double(tokens) / Double(max($0, 1))) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(fraction > 0.8 ? .orange : KapitsaTheme.accent)
                    .controlSize(.small)
            }
        }
        .help("About how many tokens the model reads with your next message: the questions and replies so far, without the reasoning. Estimated from the latest reply's usage. When it nears the context, Kapitsa can't fit the whole chat; start a new chat or export a summary.")
    }

    private var label: String {
        let size = "≈ " + Self.compact(tokens) + " tokens"
        guard let contextTokens else { return size }
        return size + " of " + Self.compact(contextTokens)
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}

private struct ChatOutlineRow: View {
    let entry: KapitsaChatOutline.Entry
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onSelect: (UUID) -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 0) {
                if entry.headings.isEmpty {
                    Color.clear.frame(width: 18, height: 1)
                } else {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Show this reply's headings" : "Hide this reply's headings")
                    .accessibilityLabel(isCollapsed ? "Expand question \(entry.number)" : "Collapse question \(entry.number)")
                }
                // The tooltip goes on the title's own button: macOS doesn't reliably show one set
                // on a row that holds buttons.
                item(entry.id, key: -1, help: entry.fullQuestion) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(entry.number)").font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(KapitsaTheme.accent).frame(minWidth: 16, alignment: .trailing)
                        Text(entry.displayTitle).font(.callout).lineLimit(2)
                        if entry.attachmentCount > 0 {
                            Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let replyID = entry.replyID, !isCollapsed {
                ForEach(Array(entry.headings.enumerated()), id: \.offset) { index, heading in
                    item(replyID, key: index) {
                        Text(heading).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.leading, 40)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// A row that scrolls to `target` when clicked; headings jump to the start of their reply.
    private func item(_ target: UUID, key: Int, help: String = "",
                      @ViewBuilder content: () -> some View) -> some View {
        Button { onSelect(target) } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .background(hovered == key ? KapitsaTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
    }
}

/// One message: the user's on the right, the model's on the left with its reasoning above.
private struct ChatMessageView: View, Equatable {
    let message: KapitsaChatMessage
    let isLive: Bool
    var canResend = false
    var findQuery = ""
    /// Which match of `findQuery` in this message Find is on, if any.
    var currentOccurrence: Int?
    let onExport: () -> Void
    let onDelete: () -> Void
    var onResend: (String) -> Void = { _ in }
    /// Sends the question before this reply again; nil for a reply without one.
    var onRegenerate: (() -> Void)?
    var onShowVersion: (Int) -> Void = { _ in }
    /// For a reply: its side questions' reply being written, and what to do with them.
    var tangentStream: KapitsaTangentStream?
    var onAskTangent: ((UUID?, String) -> Void)?
    var onTangentAction: (ChatTangentAction) -> Void = { _ in }
    @State private var editing = false
    @State private var editedText = ""
    @State private var askingTangent = false

    /// Only what's drawn; the callbacks don't change what a message shows.
    static func == (lhs: ChatMessageView, rhs: ChatMessageView) -> Bool {
        lhs.message == rhs.message && lhs.isLive == rhs.isLive && lhs.canResend == rhs.canResend
            && lhs.findQuery == rhs.findQuery && lhs.currentOccurrence == rhs.currentOccurrence
    }

    /// The text with Find's current match marked, for drawing; copies use `message.text`.
    private var shownText: String {
        KapitsaChatFind.markingCurrent(message.text, findQuery, occurrence: currentOccurrence)
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(message.attachments) { AttachmentChip(attachment: $0, onRemove: nil) }
                        }
                    }
                    if editing {
                        editor
                    } else {
                        if !message.text.isEmpty {
                            Text(KapitsaChatFind.highlighted(AttributedString(shownText), findQuery))
                                .textSelection(.enabled)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(KapitsaTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        }
                        questionFooter
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.reasoning.isEmpty || (isLive && message.text.isEmpty && message.thinking != .off) {
                    ReasoningView(message: message, isLive: isLive)
                }
                if !message.text.isEmpty {
                    ChatMarkdownView(text: shownText, findQuery: findQuery)
                } else if isLive && message.thinking == .off {
                    ProgressView().controlSize(.small)
                }
                footer
                if let tangentStream, let onAskTangent, !(message.tangents ?? []).isEmpty || askingTangent {
                    ChatTangentsView(tangents: message.tangents ?? [], canAsk: canResend, stream: tangentStream,
                                     isAskingNew: $askingTangent, onAsk: onAskTangent, onAction: onTangentAction)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = message.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Notice(error, symbol: "exclamationmark.triangle", isError: true)
                if !isLive {
                    HStack(spacing: 10) {
                        regenerateButton
                        deleteButton
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
        } else if !isLive {
            HStack(spacing: 10) {
                if message.wasStopped { Text("Stopped") }
                if let level = message.thinking { Text("Thinking: \(level.label)") }
                if let tokens = message.stats?.outputTokens { Text("\(tokens.formatted()) tokens") }
                if let rate = message.stats?.tokensPerSecond {
                    Text(rate.formatted(.number.precision(.fractionLength(1))) + " tok/s")
                }
                CopyButton(text: message.text, help: "Copy the reply") { copied in
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(message.text.isEmpty)
                .accessibilityLabel("Copy reply")
                Button(action: onExport) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .help("Save this question and reply as a Markdown file")
                    .accessibilityLabel("Export this turn as Markdown")
                if onAskTangent != nil {
                    Button { askingTangent = true } label: { Image(systemName: "arrow.turn.down.right") }
                        .buttonStyle(.plain)
                        .disabled(!canResend || message.text.isEmpty)
                        .help("Side question: ask about this reply without adding to the main conversation")
                        .accessibilityLabel("Ask a side question")
                }
                regenerateButton
                deleteButton
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// The version switcher and Edit, under a question.
    private var questionFooter: some View {
        HStack(spacing: 8) {
            if message.versionCount > 1 {
                let index = message.versionIndex ?? 0
                Button { onShowVersion(index - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0 || !canResend)
                    .help("Show the previous version of this question and what followed it")
                    .accessibilityLabel("Previous version")
                Text("\(index + 1) / \(message.versionCount)").monospacedDigit()
                    .accessibilityLabel("Version \(index + 1) of \(message.versionCount)")
                Button { onShowVersion(index + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= message.versionCount || !canResend)
                    .help("Show the next version of this question and what followed it")
                    .accessibilityLabel("Next version")
            }
            Button {
                editedText = message.text
                editing = true
            } label: { Image(systemName: "pencil") }
                .disabled(!canResend)
                .help("Edit this question and send it again. The conversation from here on becomes a new version; the current one is kept.")
                .accessibilityLabel("Edit question")
        }
        .buttonStyle(.plain)
        .font(.caption).foregroundStyle(.secondary)
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Question", text: $editedText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(KapitsaTheme.accent, lineWidth: 1))
                .onExitCommand { editing = false }
            HStack(spacing: 8) {
                Button("Cancel") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    editing = false
                    onResend(editedText)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canResend || (editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         && message.attachments.isEmpty))
            }
            .controlSize(.small)
        }
        .frame(minWidth: 320)
    }

    @ViewBuilder
    private var regenerateButton: some View {
        if let onRegenerate {
            Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .disabled(!canResend)
                .help("Regenerate: send this question again for a new reply. This reply is kept as an earlier version.")
                .accessibilityLabel("Regenerate reply")
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) { Image(systemName: "trash") }
            .buttonStyle(.plain)
            .help("Delete this question and reply")
            .accessibilityLabel("Delete this turn")
    }
}

/// The model's reasoning: open while it thinks, then folded away unless the reader opens it.
private struct ReasoningView: View {
    let message: KapitsaChatMessage
    let isLive: Bool
    @State private var userExpanded: Bool?

    private var isThinkingNow: Bool { isLive && message.text.isEmpty }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { userExpanded ?? isThinkingNow }, set: { userExpanded = $0 })) {
            Text(message.reasoning.isEmpty ? "…" : message.reasoning)
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(KapitsaTheme.border).frame(width: 2) }
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                if isThinkingNow { ProgressView().controlSize(.mini) }
                Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                // The thinking is often too long to select in one go.
                if !isLive && !message.reasoning.isEmpty {
                    CopyButton(text: message.reasoning, help: "Copy the model's thinking") { copied in
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                    .accessibilityLabel("Copy thinking")
                }
            }
        }
    }

    private var label: String {
        if isThinkingNow { return "Thinking…" }
        guard let seconds = message.stats?.thinkingSeconds else { return "Thoughts" }
        return "Thought for " + seconds.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}

/// An attachment's name and type, with an image thumbnail; removable before sending.
private struct AttachmentChip: View {
    let attachment: KapitsaChatAttachment
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            if let data = attachment.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "doc.text").foregroundStyle(KapitsaTheme.accent).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: 220, alignment: .leading)
        .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 9))
    }

    private var detail: String {
        switch attachment.kind {
        case .image: return "Image"
        case .document:
            let characters = attachment.text?.count ?? 0
            return "\(characters.formatted()) characters" + (attachment.truncated ? " · cut to fit" : "")
        }
    }
}
