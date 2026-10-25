import Foundation

/// Reviewing what a chat taught: takeaways the model writes and the person edits, and a short
/// quiz on them whose answers the model checks against the chat. Both are asked for with
/// thinking off. Quizzing yourself helps you remember far more than reading again, and a
/// date to review again turns it into spaced repetition without reminders.
struct KapitsaChatReview: Codable, Equatable {
    struct Takeaway: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        /// The questions it comes from, by their messages' IDs, to scroll to.
        var questionIDs: [UUID] = []
        /// Kept when the takeaways are written again, and asked first in a quiz. Missed quiz
        /// answers pin their takeaway.
        var pinned: Bool?
        /// Written by the person rather than the model; kept like a pinned one.
        var isOwn: Bool?

        var isKept: Bool { pinned == true || isOwn == true }
    }

    struct QuizResult: Codable, Equatable {
        var date: Date
        var right: Int
        var partly: Int
        var total: Int
        /// Days until the next review, which grow while every answer is right.
        var intervalDays: Int
    }

    var takeaways: [Takeaway] = []
    /// The questions the takeaways have read, by their messages' IDs; any others are new.
    var coveredQuestions: [UUID] = []
    var lastQuiz: QuizResult?
    /// When to quiz again, shown in the Chats list once it's reached.
    var reviewDue: Date?

    var isEmpty: Bool { takeaways.isEmpty && coveredQuestions.isEmpty && lastQuiz == nil }

    /// The chat's questions the takeaways haven't read yet.
    func newQuestions(in messages: [KapitsaChatMessage]) -> [UUID] {
        let covered = Set(coveredQuestions)
        return messages.filter { $0.role == .user && !covered.contains($0.id) }.map(\.id)
    }

    // MARK: Takeaways

    static let takeawayInstructions = """
    From this conversation between a person and an AI assistant, write the key takeaways: what \
    the person learned or decided, for them to review later. Write one per line, starting with \
    "- ". Each is one sentence of at most 25 words that makes sense on its own, using only what \
    the conversation says. End each line with the numbers of the questions it comes from in \
    square brackets, for example [Q3] or [Q3, Q5]. Write at most %d, the most important first. \
    No other text.
    """

    /// Added when updating, so the new takeaways don't repeat the ones the person has.
    static func existingInstructions(_ existing: [String]) -> String {
        "\n\nThe person already has these takeaways; don't repeat them:\n"
            + existing.map { "- " + $0 }.joined(separator: "\n")
    }

    /// About one takeaway for every two questions, from 3 to 10; an update adds 1 to 5.
    static func takeawayCount(questions: Int, isUpdate: Bool) -> Int {
        isUpdate ? min(max(questions / 2, 1), 5) : min(max(questions / 2, 3), 10)
    }

    /// Asks for takeaways from `questions` (every question when nil), numbered as in the whole
    /// chat. A chat too long for one request is read in sections, each giving its share.
    static func writeTakeaways(from messages: [KapitsaChatMessage], questions: Set<UUID>?, existing: [String],
                               connection: KapitsaChatConnection, contextTokens: Int?,
                               send: KapitsaChatSummary.Send) async throws -> [Takeaway] {
        let questionCount = questions?.count ?? messages.filter { $0.role == .user }.count
        let count = takeawayCount(questions: questionCount, isUpdate: questions != nil)
        let parts = KapitsaChatSummary.sections(KapitsaChatSummary.transcript(messages, only: questions),
                                                budget: KapitsaChatSummary.sectionBudget(contextTokens: contextTokens))
        let share = parts.count > 1 ? max(2, count / parts.count) : count
        let questionIDs = messages.filter { $0.role == .user }.map(\.id)
        var takeaways: [Takeaway] = []
        for part in parts {
            try Task.checkCancellation()
            // The fixed instructions come first, so Kapitsa can reuse them from its cache.
            let text = part + (existing.isEmpty ? "" : existingInstructions(existing))
            let reply = try await ask(String(format: takeawayInstructions, share), text, connection: connection, send: send)
            takeaways += parseTakeaways(reply, questionIDs: questionIDs)
        }
        guard !takeaways.isEmpty else { throw KapitsaChatSummary.Failure.emptyReply }
        return takeaways
    }

    /// One takeaway per line, with the questions named in its brackets; bullets, numbers and
    /// bold marks are dropped.
    static func parseTakeaways(_ text: String, questionIDs: [UUID]) -> [Takeaway] {
        var takeaways: [Takeaway] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var line = String(line).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") || line.first?.isNumber == true else { continue }
            line = line.replacingOccurrences(of: #"^(?:[-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            var numbers: [Int] = []
            if let range = line.range(of: #"\s*\[[^\]]*\d[^\]]*\]\s*\.?$"#, options: .regularExpression) {
                numbers = line[range].split { !$0.isNumber }.compactMap { Int($0) }
                line.removeSubrange(range)
            }
            line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard line.contains(where: \.isLetter) else { continue }
            var seen = Set<UUID>()
            let ids = numbers.compactMap { questionIDs.indices.contains($0 - 1) ? questionIDs[$0 - 1] : nil }
                .filter { seen.insert($0).inserted }
            takeaways.append(Takeaway(text: line, questionIDs: ids))
        }
        return takeaways
    }

    /// The takeaways as a Markdown list, to copy.
    static func markdown(_ takeaways: [Takeaway]) -> String {
        takeaways.map { "- " + $0.text }.joined(separator: "\n")
    }

    // MARK: Quiz

    enum Verdict: String, Codable, Equatable {
        case right, partly, notQuite

        var label: String {
            switch self {
            case .right: return "Right"
            case .partly: return "Partly"
            case .notQuite: return "Not quite"
            }
        }
    }

    struct QuizQuestion: Equatable, Identifiable {
        var id = UUID()
        let takeawayID: UUID
        let text: String
        /// The answer the model wrote from the chat.
        let answer: String
        /// The chat's questions it comes from, to scroll to and to check answers against.
        let sourceIDs: [UUID]
        /// What the person wrote.
        var reply = ""
        var verdict: Verdict?
        var feedback: String?
        /// The answer was shown without checking; the person then says whether they knew it.
        var isRevealed = false
    }

    struct Quiz: Equatable {
        var questions: [QuizQuestion]
        var current = 0
        /// Whether the result has been saved, once every question is answered.
        var isRecorded = false

        var isFinished: Bool { questions.allSatisfy { $0.verdict != nil } }
        var right: Int { questions.filter { $0.verdict == .right }.count }
        var partly: Int { questions.filter { $0.verdict == .partly }.count }
    }

    static let quizLength = 5

    /// Up to five takeaways to ask about: pinned ones first (missed before, or marked by the
    /// person), then the rest in a different order each time.
    static func quizTakeaways(_ takeaways: [Takeaway], shuffle: ([Takeaway]) -> [Takeaway] = { $0.shuffled() }) -> [Takeaway] {
        Array((shuffle(takeaways.filter { $0.pinned == true }) + shuffle(takeaways.filter { $0.pinned != true }))
            .prefix(quizLength))
    }

    static let quizInstructions = """
    Write one practice question for each numbered takeaway below, to help a person check they \
    remember what they learned in a conversation. Ask about one thing only, never two questions \
    joined by "and". Ask why or how where you can, not only for a fact, and don't give the \
    answer away in the question. Answer each in one or two sentences, from the conversation \
    excerpts given with it. Use exactly this shape, with no other text:
    Question 1: ...
    Answer 1: ...
    """

    static let excerptQuestionBudget = 400
    /// Characters of replies for one takeaway, shared by the questions it comes from.
    static let excerptReplyBudget = 5_000
    static let maximumExcerpts = 3

    /// The questions a takeaway comes from, up to three, and their replies, cut to their
    /// outlines, for the model to write and check answers from. Every one is needed: a
    /// takeaway can join what several replies said, and they don't always agree.
    static func excerpt(for questionIDs: [UUID], in messages: [KapitsaChatMessage]) -> String {
        let indices = questionIDs.prefix(maximumExcerpts).compactMap { id in messages.firstIndex { $0.id == id } }
        guard !indices.isEmpty else { return "" }
        let replyBudget = excerptReplyBudget / indices.count
        return indices.map { index in
            var parts = ["Question \(messages[...index].filter { $0.role == .user }.count): "
                         + String(messages[index].text.prefix(excerptQuestionBudget))]
            if let reply = messages.dropFirst(index + 1).prefix(while: { $0.role == .assistant }).last {
                parts.append("Reply: " + KapitsaChatTopics.outline(reply.text, budget: replyBudget))
            }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func writeQuiz(on takeaways: [Takeaway], messages: [KapitsaChatMessage], connection: KapitsaChatConnection,
                          send: KapitsaChatSummary.Send) async throws -> Quiz {
        let text = takeaways.enumerated().map { index, takeaway in
            let excerpt = excerpt(for: takeaway.questionIDs, in: messages)
            return "Takeaway \(index + 1): \(takeaway.text)" + (excerpt.isEmpty ? "" : "\nFrom the conversation:\n" + excerpt)
        }.joined(separator: "\n\n")
        let written = parseQuiz(try await ask(quizInstructions, text, connection: connection, send: send))
        let questions = written.compactMap { number, question, answer -> QuizQuestion? in
            guard takeaways.indices.contains(number - 1) else { return nil }
            let takeaway = takeaways[number - 1]
            return QuizQuestion(takeawayID: takeaway.id, text: question, answer: answer, sourceIDs: takeaway.questionIDs)
        }
        guard !questions.isEmpty else { throw KapitsaChatSummary.Failure.emptyReply }
        return Quiz(questions: questions)
    }

    /// "Question n:" and "Answer n:" lines, a line without a label continuing the one before.
    static func parseQuiz(_ text: String) -> [(Int, String, String)] {
        var questions: [Int: String] = [:], answers: [Int: String] = [:]
        var order: [Int] = []
        var last: (number: Int, isAnswer: Bool)?
        let pattern = try! NSRegularExpression(pattern: #"^\**\s*(Question|Answer)\s*(\d+)\s*\**\s*[:.]\s*\**\s*(.*)$"#,
                                               options: .caseInsensitive)
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = pattern.firstMatch(in: line, range: range),
               let kind = Range(match.range(at: 1), in: line), let digits = Range(match.range(at: 2), in: line),
               let rest = Range(match.range(at: 3), in: line), let number = Int(line[digits]) {
                let isAnswer = line[kind].lowercased() == "answer"
                let text = String(line[rest]).trimmingCharacters(in: .whitespaces)
                if isAnswer { answers[number] = text } else {
                    questions[number] = text
                    if !order.contains(number) { order.append(number) }
                }
                last = (number, isAnswer)
            } else if let last, !line.isEmpty {
                if last.isAnswer { answers[last.number, default: ""] += " " + line } else { questions[last.number, default: ""] += " " + line }
            }
        }
        return order.compactMap { number in
            guard let question = questions[number], let answer = answers[number], !question.isEmpty, !answer.isEmpty else { return nil }
            return (number, question, answer)
        }
    }

    static let checkInstructions = """
    You check a person's answer to a practice question about a conversation they had with an AI \
    assistant. Judge only their answer, against the conversation excerpts; the expected answer \
    is a guide, not the only right answer, so never comment on it. Judge the idea, not the \
    wording. Accept anything that any part of the excerpts supports, even where parts of the \
    conversation disagree. Start your reply with exactly one of these: "Right." when they have \
    the main point; "Partly." when they have some of it; "Not quite." only when they have none \
    of it or say something the excerpts contradict. Then in one or two sentences say what they \
    got and anything they missed. Speak to the person as "you".
    """

    static func check(_ question: QuizQuestion, messages: [KapitsaChatMessage], connection: KapitsaChatConnection,
                      send: KapitsaChatSummary.Send) async throws -> (Verdict, String) {
        var text = "Question: \(question.text)\nExpected answer: \(question.answer)\nTheir answer: \(question.reply)"
        let excerpt = excerpt(for: question.sourceIDs, in: messages)
        if !excerpt.isEmpty { text += "\n\nConversation excerpt:\n" + excerpt }
        return parseCheck(try await ask(checkInstructions, text, connection: connection, send: send))
    }

    /// The verdict the reply starts with, and the rest as feedback. A reply with no verdict
    /// counts as partly right, so the takeaway comes up again.
    static func parseCheck(_ text: String) -> (Verdict, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = trimmed.replacingOccurrences(of: "*", with: "")
        for (prefix, verdict) in [("not quite", Verdict.notQuite), ("partly", .partly), ("right", .right)]
        where plain.lowercased().hasPrefix(prefix) {
            let rest = plain.dropFirst(prefix.count).drop { ".,:!- ".contains($0) }
            return (verdict, String(rest).trimmingCharacters(in: .whitespaces))
        }
        return (.partly, trimmed)
    }

    /// Days to the next review: doubling from 3 while every answer is right, up to 60; 3 when
    /// at least half are right, otherwise tomorrow.
    static func nextInterval(right: Int, total: Int, previous: Int?) -> Int {
        if total > 0 && right == total { return previous.map { min(max($0 * 2, 3), 60) } ?? 3 }
        return right * 2 >= total ? 3 : 1
    }

    private static func ask(_ instructions: String, _ text: String, connection: KapitsaChatConnection,
                            send: KapitsaChatSummary.Send) async throws -> String {
        var request = try KapitsaChatRequest.urlRequest(
            connection: connection,
            body: KapitsaChatSummary.requestBody(instructions: instructions, text: text, model: connection.model))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try KapitsaChatSummary.replyText(from: try await send(request))
    }
}
