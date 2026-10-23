import Foundation

/// A table of contents for a chat: one entry per question, with the headings of its reply,
/// so a long conversation can be scanned and jumped through.
enum KapitsaChatOutline {
    struct Entry: Equatable, Identifiable {
        /// The question's message, which the outline scrolls to.
        let id: UUID
        let number: Int
        /// The question's first line, shortened.
        let question: String
        /// The whole question, up to `fullQuestionLength`, shown on hover.
        var fullQuestion = ""
        /// A few words naming what was asked, found with the reply's topics; nil until then.
        var title: String?
        var replyID: UUID?
        var headings: [String] = []
        var attachmentCount = 0
        /// Whether the question's headings are folded away, as saved with the chat.
        var isCollapsed = false
        /// The reply's topics; nil while they're still to be found.
        var topics: [String]? = []
        /// Whether the reply's topics or the title are still to be found.
        var needsTopics = false

        var displayTitle: String { title ?? question }
        /// The reply's places.
        var places: [String] = []
    }

    static let questionLength = 90
    static let fullQuestionLength = 600

    static func entries(from messages: [KapitsaChatMessage]) -> [Entry] {
        var entries: [Entry] = []
        for message in messages {
            switch message.role {
            case .user:
                entries.append(Entry(id: message.id, number: entries.count + 1, question: question(for: message),
                                     fullQuestion: fullQuestion(for: message), attachmentCount: message.attachments.count,
                                     isCollapsed: message.outlineCollapsed ?? false))
            case .assistant:
                // A reply belongs to the question before it; one without a question gets its own entry.
                if entries.last?.replyID != nil || entries.isEmpty {
                    entries.append(Entry(id: message.id, number: entries.count + 1, question: "Reply"))
                }
                entries[entries.count - 1].replyID = message.id
                entries[entries.count - 1].headings = headings(in: message.text)
                entries[entries.count - 1].topics = message.topics ?? (message.needsTopics ? nil : [])
                entries[entries.count - 1].places = message.places ?? []
                entries[entries.count - 1].needsTopics = message.needsTopics
                entries[entries.count - 1].title = message.title.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        return entries
    }

    /// About how many tokens the model reads for the next message: what it read for the latest
    /// reply, plus that reply and anything after it, estimated from their length. Reasoning
    /// isn't sent back, so it doesn't count. Turns deleted before that reply since it was
    /// written come off. Nil until a reply has reported its usage.
    static func conversationTokens(in messages: [KapitsaChatMessage]) -> Int? {
        guard let index = messages.lastIndex(where: { $0.role == .assistant && $0.stats?.promptTokens != nil }),
              let stats = messages[index].stats, let prompt = stats.promptTokens else { return nil }
        var total = messages[index...].reduce(prompt) { $0 + KapitsaChatSummary.estimatedTokens($1.text) }
        if let sent = stats.historyTokens {
            let remaining = messages[..<index].reduce(0) { $0 + KapitsaChatSummary.estimatedTokens($1.text) }
            total -= max(0, sent - remaining)
        }
        return max(0, total)
    }

    /// The first line of the question, shortened; attachment names when there is no text.
    static func question(for message: KapitsaChatMessage) -> String {
        let firstLine = message.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else {
            return message.attachments.map(\.name).joined(separator: ", ").nonEmpty ?? "Empty message"
        }
        guard firstLine.count > questionLength else { return firstLine }
        return String(firstLine.prefix(questionLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func fullQuestion(for message: KapitsaChatMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > fullQuestionLength else { return text.isEmpty ? question(for: message) : text }
        return String(text.prefix(fullQuestionLength)) + "…"
    }

    /// Markdown headings (#, ## and ###) outside code blocks, with their emphasis marks removed.
    static func headings(in text: String) -> [String] {
        var headings: [String] = []
        var inCodeBlock = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeBlock.toggle()
                continue
            }
            guard !inCodeBlock else { continue }
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1...3).contains(hashes), trimmed.dropFirst(hashes).first == " " else { continue }
            let heading = trimmed.dropFirst(hashes)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            if !heading.isEmpty { headings.append(heading) }
        }
        return headings
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
