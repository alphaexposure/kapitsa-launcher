import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Review view of the panel beside the chat: the chat's takeaways, which the model writes
/// and the person edits. It follows the chat itself, unlike the rest of the panel, since
/// takeaways arrive while the chat doesn't change.
struct ChatReviewView: View {
    @ObservedObject var chat: KapitsaChatController
    let connection: KapitsaChatConnection?
    let contextTokens: Int?
    /// Question numbers and titles by message ID, as the outline shows them.
    let questions: [UUID: (number: Int, title: String)]
    /// The chat's name, for a saved file.
    let chatName: String
    let onSelect: (UUID) -> Void
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var newTakeaway = ""
    @State private var confirmRedo = false
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = chat.reviewError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { chat.reviewError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
            }
            takeaways
        }
    }

    // MARK: Takeaways

    @ViewBuilder
    private var takeaways: some View {
        let takeaways = chat.review.takeaways
        let newCount = chat.review.newQuestions(in: chat.messages).count
        HStack(spacing: 8) {
            Text(takeaways.isEmpty ? "Takeaways" : "\(takeaways.count) \(takeaways.count == 1 ? "takeaway" : "takeaways")")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if !takeaways.isEmpty && chat.reviewWork == nil {
                if newCount > 0 && !chat.review.coveredQuestions.isEmpty {
                    Button("Update for \(newCount) new") { write(update: true) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                        .disabled(connection == nil)
                        .help(connection == nil ? "Start Kapitsa to update the takeaways."
                              : "Add takeaways for the \(newCount) \(newCount == 1 ? "question" : "questions") asked since; yours stay as they are.")
                }
                Menu {
                    Button("Copy as Markdown") { copy(takeaways) }
                    Button("Save As…") { save(takeaways) }
                    Divider()
                    Button("Write Again…") { confirmRedo = true }.disabled(connection == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More: copy or save the takeaways, or write them again")
            }
        }
        .padding(.horizontal, 12)
        .confirmationDialog("Write the takeaways again?", isPresented: $confirmRedo) {
            Button("Write Again") { write(update: false) }
        } message: {
            Text("The model reads the whole chat again. Pinned takeaways and your own are kept; the others are replaced.")
        }
        if chat.reviewWork == .takeaways {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Writing takeaways…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop", action: chat.stopReviewWork)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
            }
            .padding(.horizontal, 12)
        }
        if takeaways.isEmpty && chat.reviewWork == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("The main points of this chat, to look over later. You can edit, pin and add your own.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Make Takeaways") { write(update: false) }
                    .controlSize(.small)
                    .disabled(connection == nil)
                    .help(connection == nil ? "Start Kapitsa to make takeaways."
                          : "The model reads the chat with thinking off; a long chat is read in parts.")
            }
            .padding(.horizontal, 12).padding(.top, 2)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(takeaways) { takeaway in
                    if editing == takeaway.id {
                        TextField("Takeaway", text: $editText, axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(.callout).lineLimit(1...6)
                            .focused($editFocused)
                            .onSubmit(finishEditing)
                            .onExitCommand { editing = nil }
                            .onChange(of: editFocused) { if !editFocused { finishEditing() } }
                            .padding(.vertical, 2)
                    } else {
                        ChatTakeawayRow(takeaway: takeaway, questions: questions, onSelect: onSelect,
                                        onEdit: { startEditing(takeaway) },
                                        onPin: { chat.setTakeawayPinned(takeaway.id, takeaway.pinned != true) },
                                        onDelete: { chat.deleteTakeaway(takeaway.id) })
                    }
                }
                if !takeaways.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.caption).foregroundStyle(.tertiary).frame(width: 14)
                        TextField("Add your own", text: $newTakeaway, axis: .vertical)
                            .textFieldStyle(.plain).font(.callout).lineLimit(1...4)
                            .onSubmit {
                                chat.addTakeaway(newTakeaway)
                                newTakeaway = ""
                            }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        if !takeaways.isEmpty {
            HStack(spacing: 8) {
                Button { copy(takeaways) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the takeaways as a Markdown list")
                Button { save(takeaways) } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
                    .help("Save the takeaways as a Markdown file, with the questions they came from")
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    private func write(update: Bool) {
        guard let connection else { return }
        chat.writeTakeaways(connection: connection, contextTokens: contextTokens, update: update)
    }

    private func startEditing(_ takeaway: KapitsaChatReview.Takeaway) {
        editText = takeaway.text
        editing = takeaway.id
        editFocused = true
    }

    private func finishEditing() {
        guard let id = editing else { return }
        editing = nil
        chat.editTakeaway(id, text: editText)
    }

    /// Asks where to save, then writes the takeaways as Markdown.
    private func save(_ takeaways: [KapitsaChatReview.Takeaway]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = KapitsaChatReview.fileName(chatName: chatName)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try KapitsaChatReview.document(takeaways, chatName: chatName, questions: questions)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            chat.reviewError = "Couldn't save the takeaways: \(error.localizedDescription)"
        }
    }

    private func copy(_ takeaways: [KapitsaChatReview.Takeaway]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(KapitsaChatReview.markdown(takeaways), forType: .string)
    }
}

/// One takeaway: its text, the questions it comes from, which scroll the chat to them, and on
/// hover a pin. Double-click to edit; the context menu also edits, pins and deletes.
private struct ChatTakeawayRow: View {
    let takeaway: KapitsaChatReview.Takeaway
    let questions: [UUID: (number: Int, title: String)]
    let onSelect: (UUID) -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        let sources = takeaway.questionIDs.compactMap { id in questions[id].map { (id, $0) } }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: takeaway.pinned == true ? "pin.fill" : takeaway.isOwn == true ? "person" : "circle.fill")
                .font(.system(size: takeaway.pinned == true || takeaway.isOwn == true ? 10 : 4))
                .foregroundStyle(takeaway.pinned == true ? AnyShapeStyle(KapitsaTheme.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(takeaway.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !sources.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(sources, id: \.0) { id, question in
                            Button("Q\(question.number)") { onSelect(id) }
                                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(KapitsaTheme.accent)
                                .help("Show question \(question.number) in the chat: \(question.title)")
                        }
                    }
                }
            }
            Spacer(minLength: 2)
            Button(action: onPin) {
                Image(systemName: takeaway.pinned == true ? "pin.slash" : "pin").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0)
            .help(takeaway.pinned == true ? "Unpin" : "Pin: keep it when the takeaways are written again")
            .accessibilityLabel(takeaway.pinned == true ? "Unpin" : "Pin")
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(hovered ? KapitsaTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button(takeaway.pinned == true ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: takeaway.pinned == true ? "Unpin" : "Pin", onPin)
    }
}
