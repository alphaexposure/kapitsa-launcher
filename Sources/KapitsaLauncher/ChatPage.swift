import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A chat with the model this launcher started: streamed replies, a thinking level, the
/// model's reasoning in a collapsible section, and image and document attachments.
struct ChatPage: View {
    @ObservedObject var controller: KapitsaProcessController
    @ObservedObject var chat: KapitsaChatController
    @ObservedObject var chats: KapitsaChatLibrary
    /// The ID of `chat`, which may have no file yet.
    let chatID: UUID
    /// Shows another chat, or a new one, in this window.
    let onSelectChat: (UUID) -> Void
    @State private var isDropTargeted = false
    @State private var exportError: String?
    @State private var turnToDelete: UUID?
    /// The summary being written for an export, shown in a sheet that can cancel it.
    @State private var summaryTask: Task<Void, Never>?
    @AppStorage("chatOutlineShown") private var outlineShown = true
    @AppStorage("chatListShown") private var chatListShown = true
    @AppStorage("chatAutoScroll") private var autoScroll = true
    private let endID = "chat-end"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if controller.chatConnection == nil {
                Notice(controller.state.isRunning ? "Kapitsa is starting. You can chat once it's ready."
                       : "Start Kapitsa to chat with your model.", symbol: "info.circle")
            }
            if let exportError { Notice(exportError, symbol: "exclamationmark.triangle", isError: true) }
            conversation
            composer
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted, perform: handleDrop)
        .confirmationDialog("Delete this question and its reply?",
                            isPresented: Binding(get: { turnToDelete != nil }, set: { if !$0 { turnToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = turnToDelete { chat.deleteTurn(endingWith: id) }
                turnToDelete = nil
            }
        } message: {
            Text("It's removed from the chat and from what the model sees in later replies. This can't be undone.")
        }
        .sheet(isPresented: Binding(get: { summaryTask != nil }, set: { _ in })) {
            VStack(spacing: 14) {
                ProgressView()
                Text("Kapitsa is writing the summary…").font(.headline)
                Text("Thinking is off, so this usually takes a few seconds; a long chat is summarised in parts.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Cancel") {
                    summaryTask?.cancel()
                    summaryTask = nil
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 340)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Thinking").font(.callout)
            SettingHelpIcon(title: "Thinking", message: "How much the model reasons before it answers. Off answers at once. Low, Medium and Extra high are the Qwen3.8 27B's effort levels; other models may only tell Off from on. Applies to your next message.")
            Picker("Thinking", selection: $chat.thinking) {
                ForEach(KapitsaThinkingLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            Spacer(minLength: 10)
            // Labelled buttons when there's room, icons alone in a narrow window.
            ViewThatFits(in: .horizontal) {
                actions.labelStyle(.titleAndIcon)
                actions.labelStyle(.iconOnly)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $chatListShown) { Label("Chats", systemImage: "sidebar.left") }
                .toggleStyle(.button)
                .help("Chats: show or hide the list of your saved chats")
            Toggle(isOn: $autoScroll) { Label("Auto-scroll", systemImage: "arrow.down.to.line") }
                .toggleStyle(.button)
                .help("Auto-scroll: follow the reply as it's written. Turn off to read earlier turns while the model works.")
            Toggle(isOn: $outlineShown) { Label("Outline", systemImage: "sidebar.right") }
                .toggleStyle(.button)
                .help("Outline: show or hide the panel of questions and topics")
            Button { export(chat.messages) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(chat.messages.isEmpty || chat.isStreaming)
                .help("Export: save the whole chat as a Markdown file")
            Button { onSelectChat(UUID()) } label: { Label("New chat", systemImage: "square.and.pencil") }
                .disabled(chat.messages.isEmpty)
                .help("New chat: start a new conversation; this one stays in your chats")
        }
        .fixedSize()
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 12) {
                if chatListShown {
                    ChatListView(chats: chats, selected: chatID, onSelect: onSelectChat)
                        .frame(width: 220)
                }
                ScrollView {
                    // Not lazy: a lazy stack guesses the height of messages it hasn't drawn, so
                    // jumping to the end past long replies could land below the content and show
                    // a blank view until the next scroll. Finished messages aren't redrawn while
                    // a reply streams, so measuring them all costs little.
                    VStack(alignment: .leading, spacing: 18) {
                        if chat.messages.isEmpty && chat.liveReply == nil {
                            VStack(spacing: 10) {
                                KapitsaMarkShape().fill(KapitsaTheme.accent.opacity(0.5)).frame(width: 34, height: 34)
                                Text("Ask anything. Drop images or documents here to include them.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        // Finished messages don't change while a reply streams; comparing them is
                        // cheap, so SwiftUI skips redrawing them on each update.
                        ChatHistory(messages: chat.messages,
                                    onExport: { id in export(KapitsaChatExport.turn(endingWith: id, in: chat.messages)) },
                                    onDelete: { turnToDelete = $0 })
                        .equatable()
                        if let live = chat.liveReply {
                            ChatMessageView(message: live, isLive: true, onExport: {}, onDelete: {})
                                .id(live.id)
                        }
                        Color.clear.frame(height: 1).id(endID)
                    }
                    .padding(18)
                }
                .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(isDropTargeted ? KapitsaTheme.accent : KapitsaTheme.border, lineWidth: isDropTargeted ? 2 : 1))
                .onAppear { proxy.scrollTo(endID, anchor: .bottom) }
                // Cheap to compare: an ID and two byte lengths, not the whole conversation.
                // Sending always shows the new question; following the reply is optional.
                .onChange(of: chat.messages.last?.id) {
                    if autoScroll || chat.messages.last?.role == .user { proxy.scrollTo(endID, anchor: .bottom) }
                }
                .onChange(of: (chat.liveReply?.text.utf8.count ?? 0) + (chat.liveReply?.reasoning.utf8.count ?? 0)) {
                    if autoScroll { proxy.scrollTo(endID, anchor: .bottom) }
                }
                .onChange(of: autoScroll) { if autoScroll { proxy.scrollTo(endID, anchor: .bottom) } }
                if outlineShown && !chat.messages.isEmpty {
                    ChatOutlineView(
                        messages: chat.messages, contextTokens: controller.engine.contextTokens,
                        canFindTopics: controller.chatConnection != nil, topicProgress: chat.topicProgress,
                        topicThemes: chat.topicThemes,
                        onSelect: { proxy.scrollTo($0, anchor: .top) },
                        onCollapse: { chat.setOutlineCollapsed($0, questions: $1) },
                        onFindTopics: { if let connection = controller.chatConnection { chat.findMissingTopics(connection: connection) } },
                        onRedoTopics: { if let connection = controller.chatConnection { chat.redoAllTopics(connection: connection) } },
                        onStopFindingTopics: chat.stopFindingTopics)
                    .equatable()
                    .frame(width: 290)
                }
            }
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
            ChatInputRow(chat: chat, canConnect: controller.chatConnection != nil,
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
        let accessory = ExportOptionsAccessory(canSummarize: controller.chatConnection != nil)
        panel.accessoryView = accessory.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accessory.remember()
        let options = accessory.options
        exportError = nil
        guard options.includeSummary, let connection = controller.chatConnection else {
            write(messages, to: url, options: options, summary: nil)
            return
        }
        let contextTokens = controller.engine.contextTokens
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
        guard let connection = controller.chatConnection else { return false }
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
    let onExport: (UUID) -> Void
    let onDelete: (UUID) -> Void

    static func == (lhs: ChatHistory, rhs: ChatHistory) -> Bool { lhs.messages == rhs.messages }

    var body: some View {
        ForEach(messages) { message in
            ChatMessageView(message: message, isLive: false,
                            onExport: { onExport(message.id) }, onDelete: { onDelete(message.id) })
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
    enum Mode: String { case outline, topics }

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
    @AppStorage("chatPanelMode") private var mode = Mode.outline

    static func == (lhs: ChatOutlineView, rhs: ChatOutlineView) -> Bool {
        lhs.messages == rhs.messages && lhs.contextTokens == rhs.contextTokens
            && lhs.canFindTopics == rhs.canFindTopics && lhs.topicProgress == rhs.topicProgress
            && lhs.topicThemes == rhs.topicThemes
    }

    var body: some View {
        let entries = KapitsaChatOutline.entries(from: messages)
        VStack(alignment: .leading, spacing: 0) {
            Picker("View", selection: $mode) {
                Text("Outline").tag(Mode.outline)
                Text("Topics").tag(Mode.topics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            if let tokens = KapitsaChatOutline.conversationTokens(in: messages) {
                ConversationSize(tokens: tokens, contextTokens: contextTokens)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            switch mode {
            case .outline: outline(entries)
            case .topics:
                ChatTopicsView(entries: entries, themes: topicThemes, canFindTopics: canFindTopics, progress: topicProgress,
                               onSelect: onSelect, onFind: onFindTopics, onRedo: onRedoTopics,
                               onStop: onStopFindingTopics)
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
private struct ChatMessageView: View {
    let message: KapitsaChatMessage
    let isLive: Bool
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(message.attachments) { AttachmentChip(attachment: $0, onRemove: nil) }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(KapitsaTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.reasoning.isEmpty || (isLive && message.text.isEmpty && message.thinking != .off) {
                    ReasoningView(message: message, isLive: isLive)
                }
                if !message.text.isEmpty {
                    ChatMarkdownView(text: message.text)
                } else if isLive && message.thinking == .off {
                    ProgressView().controlSize(.small)
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = message.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Notice(error, symbol: "exclamationmark.triangle", isError: true)
                if !isLive { deleteButton.font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
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
                deleteButton
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
