import Foundation

/// The key concepts of one question and reply, found by the running model with thinking off,
/// and the index built from them: each concept with the questions where it came up.
enum KapitsaChatTopics {
    static let instructions = """
    List the key concepts this exchange between a person and an AI assistant is about, so the \
    person can find it again later. Give 3 to 6 short noun phrases of 1 to 4 words, most \
    important first, such as places, ideas, methods or decisions. Capitalise only the first \
    word and names. Write one per line, with no numbering, bullets or other text.
    """

    /// Added when the chat already has topics, so the same concept keeps one name.
    static func reuseInstructions(_ existing: [String]) -> String {
        "\n\nTopics already used in this conversation:\n" + existing.joined(separator: "\n")
            + "\nWhen a concept here matches one of these, use that exact wording instead of a new one."
    }

    /// At most this many earlier topics are sent, the most recent first, to keep the request short.
    static let maximumExisting = 80

    static let maximumCount = 6
    static let maximumLength = 40
    /// Enough of a long reply for its main concepts, while keeping the request quick.
    static let textBudget = 6_000

    static func find(question: KapitsaChatMessage?, reply: KapitsaChatMessage, existing: [String] = [],
                     connection: KapitsaChatConnection, send: KapitsaChatSummary.Send) async throws -> [String] {
        let existing = Array(existing.prefix(maximumExisting))
        let instructions = existing.isEmpty ? Self.instructions : Self.instructions + reuseInstructions(existing)
        let exchange = KapitsaChatSummary.transcript([question, reply].compactMap { $0 })
        let text = KapitsaChatSummary.sections(exchange, budget: textBudget).first ?? ""
        var request = try KapitsaChatRequest.urlRequest(
            connection: connection,
            body: KapitsaChatSummary.requestBody(instructions: instructions, text: text, model: connection.model))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return parse(try KapitsaChatSummary.replyText(from: try await send(request)))
    }

    /// One concept per line, without the bullets, numbers or quotes a model may add anyway.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var topics: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            // Bullets and list numbers ("-", "•", "1.", "2)"), but not a leading number such as "3BR".
            var topic = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(?:[-*•·]+|\d+[.)])\s*"#, with: "", options: .regularExpression)
            topic = topic.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*_.,;:"))
            guard !topic.isEmpty, topic.count <= maximumLength, seen.insert(key(topic)).inserted else { continue }
            topics.append(topic)
            if topics.count == maximumCount { break }
        }
        return topics
    }

    /// Topics that differ only in case or accents are the same entry.
    static func key(_ topic: String) -> String {
        topic.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    struct Mention: Equatable, Identifiable {
        /// The question, which the index scrolls to.
        let id: UUID
        let number: Int
        let question: String
    }

    struct Topic: Equatable, Identifiable {
        let id: String
        /// As first written; later spellings that differ only in case join it.
        let name: String
        var mentions: [Mention]
    }

    /// The chat's topics so far, newest first, one spelling each, for the model to reuse.
    static func existing(in messages: [KapitsaChatMessage], excluding replyID: UUID) -> [String] {
        var seen = Set<String>()
        return messages.reversed().filter { $0.id != replyID }.flatMap { $0.topics ?? [] }
            .filter { seen.insert(key($0)).inserted }
    }

    /// Every topic, alphabetically, with the questions whose replies mention it.
    static func index(_ entries: [KapitsaChatOutline.Entry]) -> [Topic] {
        var topics: [String: Topic] = [:]
        for entry in entries {
            for name in entry.topics ?? [] {
                let id = key(name)
                let mention = Mention(id: entry.id, number: entry.number, question: entry.question)
                if topics[id] == nil { topics[id] = Topic(id: id, name: name, mentions: []) }
                if topics[id]?.mentions.last?.id != entry.id { topics[id]?.mentions.append(mention) }
            }
        }
        return topics.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
