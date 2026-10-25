import SwiftUI

/// The saved chats, beside the conversation: grouped by when they were last used, searched by
/// name and by what was said in them, renamed with a double-click, and deleted to the Trash.
struct ChatListView: View {
    @ObservedObject var chats: KapitsaChatLibrary
    let selected: UUID
    let onSelect: (UUID) -> Void
    /// Opens a chat found by what was said in it, with Find open on the searched words.
    var onOpenSearchResult: (UUID, String) -> Void = { _, _ in }
    @AppStorage(KapitsaChatLibrary.nameStyleKey) private var nameStyle = KapitsaChatLibrary.NameStyle.title
    /// Kept per window, since the page starts afresh when another chat is shown.
    @SceneStorage("KapitsaLauncher.chatListFilter") private var filter = ""
    /// Chats whose messages mention the search, found shortly after typing stops.
    @State private var hits: [UUID: KapitsaChatFind.Hit] = [:]
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var toDelete: KapitsaChatLibrary.Summary?
    @FocusState private var renameFocused: Bool

    var body: some View {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? chats.summaries
            : chats.summaries.filter { $0.name(nameStyle).localizedCaseInsensitiveContains(query) || hits[$0.id] != nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chats").font(.callout.weight(.semibold))
                Text("\(chats.summaries.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Name chats by", selection: $nameStyle) {
                        ForEach(KapitsaChatLibrary.NameStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Name chats by a short title the model writes for the first question, or by the first question as you wrote it. A chat you rename keeps your name.")
            }
            .padding(.horizontal, 12).padding(.top, 12)
            TextField("Search chats", text: $filter)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .onExitCommand { filter = "" }
                .overlay(alignment: .trailing) {
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 5)
                        .help("Clear the search and show all chats (Esc)")
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .help("Finds chats by name and by what was said in them. Click a result to open it with Find on those words.")
                .task(id: query) {
                    hits = [:]
                    // Names match from the first letter; what was said, from two.
                    guard KapitsaChatFind.searchable(query) != nil else { return }
                    // Wait for typing to stop before reading every chat.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    let found = await chats.search(query)
                    if !Task.isCancelled { hits = found }
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(KapitsaChatLibrary.groups(shown), id: \.title) { group in
                        Text(group.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
                        ForEach(group.chats) { chat in row(chat) }
                    }
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Your chats appear here once you send a message."
                             : "No chats mention “\(query)”.")
                            .font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
        }
        .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KapitsaTheme.border, lineWidth: 1))
        .confirmationDialog("Delete “\(toDelete?.name(nameStyle) ?? "")”?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let chat = toDelete { delete(chat.id) }
                toDelete = nil
            }
        } message: {
            Text("The chat's file goes to the Trash, so you can get it back from there.")
        }
    }

    @ViewBuilder
    private func row(_ chat: KapitsaChatLibrary.Summary) -> some View {
        let isSelected = chat.id == selected
        let hit = filter.trimmingCharacters(in: .whitespaces).isEmpty ? nil : hits[chat.id]
        HStack(alignment: .top, spacing: 6) {
            if renaming == chat.id {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .focused($renameFocused)
                    .onSubmit { finishRenaming(chat.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { if !renameFocused { finishRenaming(chat.id) } }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.name(nameStyle)).font(.callout).lineLimit(1)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    if let hit {
                        Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if let hit {
                    Text("\(hit.count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .help("\(hit.count) \(hit.count == 1 ? "mention" : "mentions") in this chat")
                }
                if chat.isReviewDue() {
                    Image(systemName: "arrow.clockwise.circle").font(.caption).foregroundStyle(KapitsaTheme.accent)
                        .help("Time to review: take the quiz in the Review panel again")
                        .accessibilityLabel("Review due")
                }
                if chats.streaming.contains(chat.id) {
                    ProgressView().controlSize(.mini).help("Writing a reply")
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? KapitsaTheme.inset : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRenaming(chat) }
        // Alongside the double-click rather than after it, so a click selects at once.
        .simultaneousGesture(TapGesture().onEnded {
            guard renaming != chat.id else { return }
            if hit != nil { onOpenSearchResult(chat.id, filter.trimmingCharacters(in: .whitespaces)) } else { onSelect(chat.id) }
        })
        .help(chat.firstQuestion.isEmpty ? chat.name(nameStyle) : chat.firstQuestion)
        .contextMenu {
            Button("Rename…") { startRenaming(chat) }
            if chat.customName != nil {
                Button("Use Automatic Name") { chats.rename(chat.id, to: nil) }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { toDelete = chat }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // VoiceOver and other assistive tools open a chat as a click would.
        .accessibilityAction {
            if hit != nil { onOpenSearchResult(chat.id, filter.trimmingCharacters(in: .whitespaces)) } else { onSelect(chat.id) }
        }
    }

    private func startRenaming(_ chat: KapitsaChatLibrary.Summary) {
        newName = chat.name(nameStyle)
        renaming = chat.id
        renameFocused = true
    }

    private func finishRenaming(_ id: UUID) {
        guard renaming == id else { return }
        renaming = nil
        let current = chats.summaries.first { $0.id == id }
        // An unchanged automatic name isn't made a name of the chat's own.
        if newName.trimmingCharacters(in: .whitespacesAndNewlines) != current?.name(nameStyle) {
            chats.rename(id, to: newName)
        }
    }

    /// Deleting the chat this window shows moves it to the next most recent, or a new chat.
    private func delete(_ id: UUID) {
        chats.delete(id)
        if id == selected { onSelect(chats.summaries.first?.id ?? UUID()) }
    }
}
