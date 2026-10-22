import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A chat with the model this launcher started: streamed replies, a thinking level, the
/// model's reasoning in a collapsible section, and image and document attachments.
struct ChatPage: View {
    @ObservedObject var controller: KapitsaProcessController
    @ObservedObject var chat: KapitsaChatController
    @State private var isDropTargeted = false
    @State private var exportError: String?
    @AppStorage("chatOutlineShown") private var outlineShown = true
    @FocusState private var composerFocused: Bool
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
            Spacer()
            Toggle(isOn: $outlineShown) { Label("Outline", systemImage: "sidebar.right") }
                .toggleStyle(.button)
                .help("Show or hide the list of questions")
            Button { export(chat.messages) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(chat.messages.isEmpty || chat.isStreaming)
                .help("Save the whole chat as a Markdown file")
            Button { chat.clear() } label: { Label("New chat", systemImage: "square.and.pencil") }
                .disabled(chat.messages.isEmpty)
                .help("Clear the conversation")
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
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
                        ChatHistory(messages: chat.messages) { id in
                            export(KapitsaChatExport.turn(endingWith: id, in: chat.messages))
                        }
                        .equatable()
                        if let live = chat.liveReply {
                            ChatMessageView(message: live, isLive: true, onExport: {})
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
                // Cheap to compare: a count and two byte lengths, not the whole conversation.
                .onChange(of: chat.messages.count) { proxy.scrollTo(endID, anchor: .bottom) }
                .onChange(of: (chat.liveReply?.text.utf8.count ?? 0) + (chat.liveReply?.reasoning.utf8.count ?? 0)) {
                    proxy.scrollTo(endID, anchor: .bottom)
                }
                if outlineShown && !chat.messages.isEmpty {
                    ChatOutlineView(messages: chat.messages) { id in
                        // The lazy list guesses the height of rows it hasn't drawn, so the first
                        // jump can land short; once those rows are drawn, a second one is exact.
                        proxy.scrollTo(id, anchor: .top)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .equatable()
                    .frame(width: 240)
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
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach images or documents")
                .accessibilityLabel("Attach files")
                TextField("Message Kapitsa", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit(send)
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
                    .disabled(!chat.canSend || controller.chatConnection == nil)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return; Option-Return for a new line)")
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(KapitsaTheme.border, lineWidth: 1))
        }
        .onAppear { composerFocused = true }
    }

    /// Asks where to save, then writes the Markdown and, beside it, a folder for any images.
    private func export(_ messages: [KapitsaChatMessage]) {
        guard !messages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = KapitsaChatExport(messages: messages).suggestedFileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Name the images folder after the file actually chosen.
        let export = KapitsaChatExport(
            messages: messages,
            imagesFolderName: KapitsaChatExport.imagesFolderName(forMarkdownNamed: url.lastPathComponent))
        do {
            try export.write(to: url)
            exportError = nil
        } catch {
            exportError = "Couldn't save the export: \(error.localizedDescription)"
        }
    }

    private func send() {
        guard let connection = controller.chatConnection else { return }
        chat.send(to: connection)
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

    static func == (lhs: ChatHistory, rhs: ChatHistory) -> Bool { lhs.messages == rhs.messages }

    var body: some View {
        ForEach(messages) { message in
            ChatMessageView(message: message, isLive: false) { onExport(message.id) }
                .id(message.id)
        }
    }
}

/// The questions asked so far, numbered, each with the headings of its reply. Clicking one
/// scrolls the chat to it, and each question's headings fold away with its chevron.
/// Equatable for the same reason as `ChatHistory`.
private struct ChatOutlineView: View, Equatable {
    let messages: [KapitsaChatMessage]
    let onSelect: (UUID) -> Void
    /// Questions whose headings are folded away. Kept here, not in the rows, so the lazy list
    /// doesn't forget them when a row scrolls out of view.
    @State private var collapsed: Set<UUID> = []

    static func == (lhs: ChatOutlineView, rhs: ChatOutlineView) -> Bool { lhs.messages == rhs.messages }

    var body: some View {
        let entries = KapitsaChatOutline.entries(from: messages)
        VStack(alignment: .leading, spacing: 0) {
            let foldable = entries.filter { !$0.headings.isEmpty }.map(\.id)
            let allCollapsed = !foldable.isEmpty && foldable.allSatisfy(collapsed.contains)
            HStack {
                Text("Outline · \(entries.count) \(entries.count == 1 ? "question" : "questions")")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !foldable.isEmpty {
                    Button(allCollapsed ? "Expand all" : "Collapse all") {
                        collapsed = allCollapsed ? [] : Set(foldable)
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        ChatOutlineRow(entry: entry, isCollapsed: collapsed.contains(entry.id),
                                       onToggle: { toggle(entry.id) }, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
        }
        .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KapitsaTheme.border, lineWidth: 1))
    }

    private func toggle(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
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
                item(entry.id, key: -1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(entry.number)").font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(KapitsaTheme.accent).frame(minWidth: 16, alignment: .trailing)
                        Text(entry.question).font(.callout).lineLimit(2)
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
    private func item(_ target: UUID, key: Int, @ViewBuilder content: () -> some View) -> some View {
        Button { onSelect(target) } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovered == key ? KapitsaTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
    }
}

/// One message: the user's on the right, the model's on the left with its reasoning above.
private struct ChatMessageView: View {
    let message: KapitsaChatMessage
    let isLive: Bool
    let onExport: () -> Void

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
                    Text(Self.markdown(message.text))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            Notice(error, symbol: "exclamationmark.triangle", isError: true)
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
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// Inline Markdown (bold, italics, code, links), keeping the model's line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
