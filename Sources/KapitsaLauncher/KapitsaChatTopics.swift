import Foundation

/// The key concepts of one question and reply, found by the running model with thinking off,
/// and the index built from them: each concept with the questions where it came up.
enum KapitsaChatTopics {
    static let instructions = """
    List the key concepts this exchange between a person and an AI assistant is about, so the \
    person can find it again later. Give 3 to 6 short noun phrases of 1 to 4 words, most \
    important first, such as places, ideas, methods or decisions. Write them as you would in \
    a list of headings, for example: Sensitive skin, San Diego, EU residency, Cost of living. \
    Write one per line, with no numbering, bullets or other text.
    """

    static let mergeInstructions = """
    These are topic names from one conversation. Some may name the same concept in different \
    words. Group only names that mean the same thing, not names that are merely related. For \
    each group, write one line: the clearest name, then " = ", then the other names in the group \
    separated by " | ". Write nothing for names without a match, and no other text.
    """

    /// Added when the chat already has topics, so the same concept keeps one name.
    static func reuseInstructions(_ existing: [String]) -> String {
        "\n\nNames already used for earlier parts of this conversation:\n" + existing.joined(separator: "\n")
            + "\nList only what this exchange itself is about, starting with what is new in it. If one of "
            + "its concepts is the same as a name above, write that exact name instead of a new wording; "
            + "don't list a name above just because it appears there."
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
            // Models often answer in lower case; topics read as headings.
            if let first = topic.first, first.isLowercase { topic = first.uppercased() + topic.dropFirst() }
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

    /// Asks the model which of a chat's topics name the same concept. Returns, for each name
    /// to replace, the name to use instead.
    static func merges(for topics: [String], connection: KapitsaChatConnection,
                       send: KapitsaChatSummary.Send) async throws -> [String: String] {
        guard topics.count > 1 else { return [:] }
        var request = try KapitsaChatRequest.urlRequest(
            connection: connection,
            body: KapitsaChatSummary.requestBody(instructions: mergeInstructions,
                                                 text: topics.joined(separator: "\n"), model: connection.model))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return parseMerges(try KapitsaChatSummary.replyText(from: try await send(request)), known: topics)
    }

    /// Lines of "Name = other | other", keeping only names that were in the list, so the model
    /// can't invent topics, and only names that share a word, so related but different
    /// concepts ("Budget constraints", "Czech EU residency") stay apart. Merges run after every
    /// reply, so a loose one would compound. Keys are folded with `key(_:)`.
    static func parseMerges(_ text: String, known: [String]) -> [String: String] {
        let spellings = Dictionary(known.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var merges: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let target = spellings[key(clean(parts[0]))] else { continue }
            for other in parts[1].split(separator: "|").map({ key(clean(String($0))) })
            where other != key(target) && merges[key(target)] == nil
                && spellings[other].map({ sharesWord($0, target) }) == true {
                merges[other] = target
            }
        }
        return merges
    }

    /// Replaces merged names in a reply's topics, dropping any that become repeats.
    static func applying(_ merges: [String: String], to topics: [String]) -> [String] {
        var seen = Set<String>()
        return topics.map { merges[key($0)] ?? $0 }.filter { seen.insert(key($0)).inserted }
    }

    /// Whether two names have a word of three or more letters in common, ignoring case,
    /// accents and a plural "s".
    static func sharesWord(_ a: String, _ b: String) -> Bool {
        func words(_ name: String) -> Set<String> {
            Set(key(name).components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
                .map { $0.hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : $0 })
        }
        return !words(a).isDisjoint(with: words(b))
    }

    private static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*_-•"))
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
