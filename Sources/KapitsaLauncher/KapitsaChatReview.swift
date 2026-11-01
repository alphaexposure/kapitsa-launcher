import Foundation

/// Reviewing what a chat taught: takeaways the model writes, with thinking off, and the
/// person edits, pins and adds to, each linked to the questions it came from.
struct KapitsaChatReview: Codable, Equatable {
    struct Takeaway: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        /// The questions it comes from, by their messages' IDs, to scroll to.
        var questionIDs: [UUID] = []
        /// Kept when the takeaways are written again.
        var pinned: Bool?
        /// Written by the person rather than the model; kept like a pinned one.
        var isOwn: Bool?

        var isKept: Bool { pinned == true || isOwn == true }
    }

    var takeaways: [Takeaway] = []
    /// The questions the takeaways have read, by their messages' IDs; any others are new.
    var coveredQuestions: [UUID] = []

    var isEmpty: Bool { takeaways.isEmpty && coveredQuestions.isEmpty }

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
                                                budget: KapitsaChatSummary.readingBudget(contextTokens: contextTokens))
        let share = parts.count > 1 ? max(2, count / parts.count) : count
        let questionIDs = messages.filter { $0.role == .user }.map(\.id)
        var takeaways: [Takeaway] = []
        for part in parts {
            try Task.checkCancellation()
            // The fixed instructions come first, so Kapitsa can reuse them from its cache.
            let text = part + (existing.isEmpty ? "" : existingInstructions(existing))
            let reply = try await ask(String(format: takeawayInstructions, share), text, connection: connection, send: send)
            // Models often write more than asked for; the first are the most important.
            takeaways += parseTakeaways(reply, questionIDs: questionIDs).prefix(share)
        }
        guard !takeaways.isEmpty else { throw KapitsaChatSummary.Failure.emptyReply }
        return takeaways
    }

    /// One takeaway per line, with the questions named in its brackets; bullets, numbers and
    /// bold marks are dropped. A line without a bullet counts when it ends with its questions,
    /// since models sometimes leave the bullets off.
    static func parseTakeaways(_ text: String, questionIDs: [UUID]) -> [Takeaway] {
        var takeaways: [Takeaway] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var line = String(line).trimmingCharacters(in: .whitespaces)
            let isListed = line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") || line.first?.isNumber == true
            guard isListed || line.range(of: #"\[Q?\d[^\]]*\]\.?$"#, options: .regularExpression) != nil else { continue }
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

    /// The takeaways as a Markdown file: the chat's name and the date, then each takeaway
    /// with the questions it came from, by number and title.
    static func document(_ takeaways: [Takeaway], chatName: String, questions: [UUID: (number: Int, title: String)],
                         date: Date = Date()) -> String {
        var lines = ["# Takeaways: \(chatName)", "", "Saved \(date.formatted(date: .long, time: .omitted))", ""]
        for takeaway in takeaways {
            lines.append("- " + takeaway.text)
            let sources = takeaway.questionIDs.compactMap { questions[$0] }.map { "\($0.number). \($0.title)" }
            if !sources.isEmpty { lines.append("  *From: " + sources.joined(separator: "; ") + "*") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "<chat name> takeaways.md", without characters a file name can't hold.
    static func fileName(chatName: String) -> String {
        let name = chatName.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(name.prefix(80)) + " takeaways.md"
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
