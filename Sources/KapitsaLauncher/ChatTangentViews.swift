import SwiftUI

/// What can be done to a side question from its thread.
enum ChatTangentAction {
    case collapse(UUID, Bool)
    case delete(UUID)
    /// Continue the side question as a new chat.
    case branch(UUID)
    /// Open the chat it was continued in.
    case open(UUID)
    case copy(UUID)
    case save(UUID)
}

/// The side questions under a reply, and the box for a new one when it's being asked.
struct ChatTangentsView: View {
    let tangents: [KapitsaTangent]
    /// Kapitsa is running and isn't writing anything else.
    let canAsk: Bool
    @ObservedObject var stream: KapitsaTangentStream
    @Binding var isAskingNew: Bool
    /// A follow-up in a side question, or a new one when the ID is nil.
    let onAsk: (UUID?, String) -> Void
    let onAction: (ChatTangentAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tangents) { tangent in
                ChatTangentThread(tangent: tangent, canAsk: canAsk,
                                  live: stream.tangentID == tangent.id ? stream.reply : nil,
                                  onAsk: { onAsk(tangent.id, $0) }, onAction: onAction)
            }
            if isAskingNew {
                ChatTangentBox {
                    ChatTangentComposer(placeholder: "Ask a side question about this reply", canAsk: canAsk,
                                        autofocus: true, onAsk: { text in
                                            isAskingNew = false
                                            onAsk(nil, text)
                                        }, onCancel: { isAskingNew = false })
                }
            }
        }
        .padding(.leading, 24)
    }
}

/// One side question: folded to its first question, or open to the thread and a follow-up box.
private struct ChatTangentThread: View {
    let tangent: KapitsaTangent
    let canAsk: Bool
    /// Its reply being written, if any.
    let live: KapitsaChatMessage?
    let onAsk: (String) -> Void
    let onAction: (ChatTangentAction) -> Void
    @State private var confirmDelete = false

    private var isCollapsed: Bool { tangent.isCollapsed == true && live == nil }

    var body: some View {
        ScrollViewReader { proxy in
        ChatTangentBox {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !isCollapsed {
                    ForEach(tangent.messages) { message in
                        if message.role == .user {
                            // On the right in a bubble, as in the main chat, so questions and
                            // answers can be told apart at a glance.
                            HStack {
                                Spacer(minLength: 40)
                                Text(message.text).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(KapitsaTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                            }
                        } else {
                            reply(message)
                        }
                    }
                    if let live {
                        if live.text.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(live.reasoning.isEmpty ? "Writing…" : "Thinking…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ChatMarkdownView(text: live.text)
                        }
                    }
                    if let chat = tangent.continuedIn {
                        continued(chat)
                    } else if live == nil {
                        ChatTangentComposer(placeholder: "Ask a follow-up", canAsk: canAsk, autofocus: false,
                                            onAsk: onAsk, onCancel: nil)
                    }
                    if live == nil {
                        // A long thread's header is far up; fold from here too, keeping the
                        // folded thread in view.
                        HStack {
                            Spacer()
                            Button {
                                onAction(.collapse(tangent.id, true))
                                DispatchQueue.main.async { withAnimation { proxy.scrollTo(tangent.id, anchor: .center) } }
                            } label: { Label("Fold", systemImage: "chevron.up") }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                .help("Fold this side question away")
                        }
                    }
                }
            }
        }
        .id(tangent.id)
        }
        .confirmationDialog("Delete this side question?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onAction(.delete(tangent.id)) }
        } message: {
            Text("Its question and replies are removed from this chat. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { onAction(.collapse(tangent.id, !isCollapsed)) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(KapitsaTheme.accent)
                    Text("Side question").font(.caption.weight(.semibold))
                    if isCollapsed, let first = tangent.messages.first {
                        Text(first.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show this side question" : "Fold this side question away")
            Spacer(minLength: 6)
            let replies = tangent.messages.filter { $0.role == .assistant }.count
            if isCollapsed {
                Text(tangent.continuedIn != nil ? "Continued in a new chat" : "\(replies) \(replies == 1 ? "reply" : "replies")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                if let chat = tangent.continuedIn {
                    Button("Open the New Chat") { onAction(.open(chat)) }
                } else {
                    Button("Continue as New Chat…") { onAction(.branch(tangent.id)) }
                        .disabled(!canAsk || replies == 0)
                }
                Divider()
                Button("Copy as Markdown") { onAction(.copy(tangent.id)) }.disabled(live != nil)
                Button("Save As…") { onAction(.save(tangent.id)) }.disabled(live != nil)
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(live != nil)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More: continue this side question as a new chat, copy or save it, or delete it")
        }
        .foregroundStyle(.secondary)
    }

    private func reply(_ message: KapitsaChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty { ChatMarkdownView(text: message.text) }
            if let error = message.errorMessage {
                Notice(error, symbol: "exclamationmark.triangle", isError: true)
            }
            HStack(spacing: 10) {
                if message.wasStopped { Text("Stopped") }
                CopyButton(text: message.text, help: "Copy the reply") { copied in
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(message.text.isEmpty)
                .accessibilityLabel("Copy reply")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func continued(_ chat: UUID) -> some View {
        HStack(spacing: 8) {
            Text("Continued in a new chat.").font(.caption).foregroundStyle(.secondary)
            Button("Open") { onAction(.open(chat)) }.controlSize(.small)
        }
    }
}

/// The box a side question sits in: set in from the reply, with a bar down its left side.
private struct ChatTangentBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KapitsaTheme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(KapitsaTheme.accent.opacity(0.6)).frame(width: 3)
            }
    }
}

/// A box to type a side question or a follow-up in. Return asks.
private struct ChatTangentComposer: View {
    let placeholder: String
    let canAsk: Bool
    let autofocus: Bool
    let onAsk: (String) -> Void
    let onCancel: (() -> Void)?
    @State private var text = ""
    @FocusState private var focused: Bool

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.callout).lineLimit(1...6)
                .focused($focused)
                .onSubmit(ask)
                .onExitCommand { onCancel?() }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? KapitsaTheme.accent : KapitsaTheme.border, lineWidth: 1))
            if let onCancel {
                Button("Cancel", action: onCancel).controlSize(.small)
            }
            Button("Ask", action: ask)
                .controlSize(.small)
                .disabled(!canAsk || isEmpty)
                .help(canAsk ? "Ask: the model reads the chat up to this reply, then this side question. It isn't added to the main conversation."
                             : "Wait for the reply being written, or start Kapitsa.")
        }
        .onAppear { if autofocus { focused = true } }
    }

    private func ask() {
        guard canAsk, !isEmpty else { return }
        onAsk(text)
        text = ""
    }
}
