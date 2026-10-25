import AppKit
import SwiftUI

/// The Review view of the panel beside the chat: the chat's takeaways, which the model writes
/// and the person edits, and a short quiz on them. It follows the chat itself, unlike the rest
/// of the panel, since takeaways and quiz answers arrive while the chat doesn't change.
struct ChatReviewView: View {
    @ObservedObject var chat: KapitsaChatController
    let connection: KapitsaChatConnection?
    let contextTokens: Int?
    /// Question numbers by message ID, as the outline numbers them.
    let numbers: [UUID: Int]
    let onSelect: (UUID) -> Void
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var newTakeaway = ""
    @State private var confirmRedo = false
    @FocusState private var editFocused: Bool
    @AppStorage("chatPrepareQuiz") private var prepareQuiz = true

    /// What decides whether to write a quiz ahead; a change starts it again.
    private struct PrepareKey: Equatable {
        let takeaways: [KapitsaChatReview.Takeaway]
        let isIdle: Bool
        let connection: KapitsaChatConnection?
        let isOn: Bool
    }

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
            if let quiz = chat.quiz {
                ChatQuizView(chat: chat, quiz: quiz, connection: connection, numbers: numbers, onSelect: onSelect)
            } else {
                takeaways
            }
        }
        .task(id: PrepareKey(takeaways: chat.review.takeaways,
                             isIdle: !chat.isStreaming && chat.quiz == nil && chat.reviewWork == nil,
                             connection: connection, isOn: prepareQuiz)) {
            // A pause first, so a run of edits or pins asks once.
            guard prepareQuiz, let connection, !chat.review.takeaways.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            chat.prepareQuiz(connection: connection)
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
                    Button("Write Again…") { confirmRedo = true }.disabled(connection == nil)
                    Divider()
                    Toggle("Prepare Quiz in Background", isOn: $prepareQuiz)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More: copy the takeaways, write them again, or turn off writing the quiz ahead")
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
                Text("The main points of this chat, to look over later and quiz yourself on. You can edit, pin and add your own.")
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
                        ChatTakeawayRow(takeaway: takeaway, numbers: numbers, onSelect: onSelect,
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Button { if let connection { chat.startQuiz(connection: connection) } } label: {
                        if chat.reviewWork == .quiz {
                            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Writing questions…") }
                        } else {
                            Label("Quiz Me", systemImage: "questionmark.bubble")
                        }
                    }
                    .controlSize(.small)
                    .disabled(connection == nil || chat.reviewWork != nil)
                    .help(connection == nil ? "Start Kapitsa to take a quiz."
                          : "Up to \(KapitsaChatReview.quizLength) questions on these takeaways, pinned ones first. Answer in your own words and the model checks them against the chat.")
                    if chat.reviewWork == .quiz {
                        Button("Stop", action: chat.stopReviewWork)
                            .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                    }
                    Spacer()
                    Button { copy(takeaways) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Copy the takeaways as a Markdown list")
                        .accessibilityLabel("Copy takeaways")
                }
                if let last = chat.review.lastQuiz {
                    Text(ChatQuizView.resultLine(last, due: chat.review.reviewDue))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

    private func copy(_ takeaways: [KapitsaChatReview.Takeaway]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(KapitsaChatReview.markdown(takeaways), forType: .string)
    }
}

/// One takeaway: its text, the questions it comes from, which scroll the chat to them, and on
/// hover a pin. Double-click to edit; the context menu also edits, pins and deletes.
private struct ChatTakeawayRow: View {
    let takeaway: KapitsaChatReview.Takeaway
    let numbers: [UUID: Int]
    let onSelect: (UUID) -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        let sources = takeaway.questionIDs.compactMap { id in numbers[id].map { (id, $0) } }
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
                        ForEach(sources, id: \.0) { id, number in
                            Button("Q\(number)") { onSelect(id) }
                                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(KapitsaTheme.accent)
                                .help("Show question \(number) in the chat")
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
            .help(takeaway.pinned == true ? "Unpin" : "Pin: keep it when the takeaways are written again, and ask it first in quizzes")
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

/// A quiz on the takeaways, one question at a time: answer in your own words and the model
/// checks it, or show the answer and say whether you knew it. Then the results.
private struct ChatQuizView: View {
    @ObservedObject var chat: KapitsaChatController
    let quiz: KapitsaChatReview.Quiz
    let connection: KapitsaChatConnection?
    let numbers: [UUID: Int]
    let onSelect: (UUID) -> Void
    /// What's typed for each question, kept while moving between them.
    @State private var drafts: [UUID: String] = [:]
    @State private var showsResults = false
    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(showsResults ? "Results" : "Question \(quiz.current + 1) of \(quiz.questions.count)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
                    Button {
                        showsResults = false
                        chat.showQuestion(index)
                    } label: {
                        Circle().fill(Self.color(question.verdict))
                            .overlay(Circle().stroke(KapitsaTheme.accent, lineWidth: index == quiz.current && !showsResults ? 1.5 : 0).padding(-2))
                            .frame(width: 7, height: 7)
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .help("Question \(index + 1)" + (question.verdict.map { ": \($0.label.lowercased())" } ?? ""))
                }
                Button(showsResults || quiz.isFinished ? "Done" : "Stop", action: chat.closeQuiz)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(KapitsaTheme.accent)
                    .padding(.leading, 4)
                    .help(quiz.isFinished ? "Back to the takeaways" : "End the quiz; nothing is saved until every question is answered")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if showsResults { results } else if let question = quiz.questions[safe: quiz.current] { card(question) }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 12)
        .onAppear { answerFocused = true }
    }

    @ViewBuilder
    private func card(_ question: KapitsaChatReview.QuizQuestion) -> some View {
        Text(question.text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if question.verdict == nil && !question.isRevealed {
            // A plain field in a box three lines tall: a bordered field keeps to one line until
            // typed into. It grows to eight lines, then scrolls.
            TextField("Your answer", text: Binding(get: { drafts[question.id] ?? "" }, set: { drafts[question.id] = $0 }),
                      axis: .vertical)
                .textFieldStyle(.plain).font(.callout).lineLimit(3...8)
                .focused($answerFocused)
                .disabled(chat.reviewWork == .checking)
                .padding(7)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(answerFocused ? KapitsaTheme.accent : KapitsaTheme.border, lineWidth: answerFocused ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture { answerFocused = true }
            HStack(spacing: 8) {
                Button { check(question) } label: {
                    if chat.reviewWork == .checking {
                        HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Checking…") }
                    } else {
                        Text("Check")
                    }
                }
                .controlSize(.small).keyboardShortcut(.return, modifiers: .command)
                .disabled(connection == nil || chat.reviewWork != nil
                          || (drafts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(connection == nil ? "Start Kapitsa to check answers." : "The model compares your answer with the chat (⌘↩)")
                Button("Show Answer", action: chat.revealAnswer)
                    .controlSize(.small).disabled(chat.reviewWork != nil)
                    .help("See the answer and say whether you knew it, without the model checking")
            }
        } else {
            if !question.reply.isEmpty {
                Text(question.reply).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            if let verdict = question.verdict, let feedback = question.feedback {
                (Text(verdict.label + ". ").bold() + Text(feedback))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.color(verdict).opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
            if question.isRevealed || question.verdict != .right {
                VStack(alignment: .leading, spacing: 3) {
                    Text("From the chat").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(question.answer).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            HStack(spacing: 10) {
                ForEach(question.sourceIDs.compactMap { id in numbers[id].map { (id, $0) } }, id: \.0) { id, number in
                    Button("Q\(number)") { onSelect(id) }
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(KapitsaTheme.accent)
                        .help("Show question \(number) in the chat")
                }
                Spacer()
                if question.verdict == nil {
                    Button("I Knew It") { chat.markRevealed(knewIt: true); next() }.controlSize(.small)
                    Button("I Didn't") { chat.markRevealed(knewIt: false); next() }.controlSize(.small)
                } else {
                    Button(nextUnanswered == nil ? "See Results" : "Next", action: next)
                        .controlSize(.small).keyboardShortcut(.return, modifiers: .command)
                }
            }
            if question.verdict != nil && question.verdict != .right {
                Text("Its takeaway is pinned, so it comes up first next time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        Text("\(quiz.right) of \(quiz.questions.count) right" + (quiz.partly > 0 ? ", \(quiz.partly) partly" : ""))
            .font(.title3.weight(.semibold))
        if let due = chat.review.reviewDue {
            Text("Review again \(Self.dueText(due)). The chat is marked in your Chats list when it's time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
            Button {
                showsResults = false
                chat.showQuestion(index)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(Self.color(question.verdict)).frame(width: 7, height: 7)
                    Text(question.text).font(.caption).foregroundStyle(.primary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go back to this question")
        }
        Button("Done", action: chat.closeQuiz).controlSize(.small).padding(.top, 4)
    }

    private var nextUnanswered: Int? { Self.nextUnanswered(in: quiz) }

    /// The next question without an answer after the current one, wrapping round.
    static func nextUnanswered(in quiz: KapitsaChatReview.Quiz) -> Int? {
        let count = quiz.questions.count
        guard count > 0 else { return nil }
        return (1...count).map { (quiz.current + $0) % count }.first { quiz.questions[$0].verdict == nil }
    }

    private func next() {
        // An "I knew it" verdict has only just landed, so read the chat's quiz, not `quiz`.
        if let index = chat.quiz.flatMap(Self.nextUnanswered) {
            chat.showQuestion(index)
            answerFocused = true
        } else {
            showsResults = true
        }
    }

    private func check(_ question: KapitsaChatReview.QuizQuestion) {
        guard let connection else { return }
        chat.checkAnswer(drafts[question.id] ?? "", connection: connection)
    }

    static func color(_ verdict: KapitsaChatReview.Verdict?) -> Color {
        switch verdict {
        case .right: return .green
        case .partly: return .orange
        case .notQuite: return .red
        case nil: return Color.secondary.opacity(0.35)
        }
    }

    /// "tomorrow", a weekday within the week, or a date.
    static func dueText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "tomorrow" }
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return "on " + date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func resultLine(_ result: KapitsaChatReview.QuizResult, due: Date?, now: Date = Date()) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: result.date),
                                                   to: Calendar.current.startOfDay(for: now)).day ?? 0
        let when = days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        var line = "Last quiz \(when): \(result.right) of \(result.total) right"
        if let due { line += due <= now ? " · time to review" : " · review again \(dueText(due, now: now))" }
        return line
    }
}
