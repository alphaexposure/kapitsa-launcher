import Foundation

/// The places and topics of one question and reply, found by the running model with thinking
/// off; the themes that group a chat's topics; and the index built from them, with each place,
/// theme and topic leading to the questions where it came up.
enum KapitsaChatTopics {
    static let instructions = """
    Describe this exchange between a person and an AI assistant, so the person can find it \
    again later. Answer with labelled lines only, in this order:
    Title: 3 to 7 words naming what the person asked, leaving out any story or context around \
    it. For example, "I was out walking and wondered what quantum mechanics is" becomes \
    "Title: What is quantum mechanics?". If the question is already short and clear, keep its \
    wording.
    Topic: 2 to 4 lines, each one broad subject the exchange covers, such as a need, a \
    decision, a method or a practical matter, named so it could apply to other questions too \
    (for example: Residency permits, Cost of living, Schooling), not a summary of this answer.
    Place: up to 4 lines, each a specific place on a map that it discusses, such as a city, \
    island, region or country, never an object, technology or idea. Leave these lines out \
    when it discusses no such place.
    Write topics and places as headings, capitalising the first word and proper names.
    """

    /// Added when the chat already has names, so the same place or topic keeps one name.
    static func reuseInstructions(_ existing: [String]) -> String {
        "\n\nNames already used for earlier parts of this conversation:\n" + existing.joined(separator: "\n")
            + "\nList only what this exchange itself is about. If one of its places or topics is the "
            + "same as a name above, write that exact name instead of a new wording; don't list a name "
            + "above just because it appears there."
    }

    static let groupInstructions = """
    These are topics from one conversation. Group them into at most 10 themes, each a short, \
    broad name of 1 to 3 words, for example: Climate, Residency, Housing and costs. Put every \
    topic in exactly one theme. Write one line per theme: the theme's name, then ": ", then its \
    topics separated by " | ". No other text.
    """

    /// Added when the chat already has themes, so new topics join them instead of reshuffling.
    static func existingThemesInstructions(_ themes: [String]) -> String {
        "\n\nThe conversation already has these themes:\n" + themes.joined(separator: "\n")
            + "\nPut each topic in one of these themes, or in a new theme only if none fits."
    }

    static let placePrefix = "place:"
    static let titlePrefix = "title:"
    static let maximumTitleLength = 80
    static let maximumPlaces = 4
    static let maximumTopics = 4
    static let maximumLength = 40
    /// At most this many earlier names are sent, the most recent first, to keep the request short.
    static let maximumExisting = 50
    /// Characters of the question and of the reply the request reads. A longer reply is cut to
    /// its outline, which names its subjects and places in far fewer tokens: these requests run
    /// after every reply, and none of their text is in Kapitsa's cache.
    static let questionBudget = 1_000
    static let replyBudget = 2_500

    struct Found: Equatable {
        /// Empty when the model gave none, so the reply isn't asked again.
        var title = ""
        var places: [String] = []
        var topics: [String] = []
    }

    static func find(question: KapitsaChatMessage?, reply: KapitsaChatMessage, existing: [String] = [],
                     connection: KapitsaChatConnection, send: KapitsaChatSummary.Send) async throws -> Found {
        let existing = Array(existing.prefix(maximumExisting))
        var question = question, reply = reply
        if let text = question?.text { question?.text = String(text.prefix(questionBudget)) }
        reply.text = outline(reply.text, budget: replyBudget)
        // The names go after the exchange, so the fixed instructions are the same at the start
        // of every request and Kapitsa can reuse them from its cache.
        let text = KapitsaChatSummary.transcript([question, reply].compactMap { $0 }).joined(separator: "\n\n")
            + (existing.isEmpty ? "" : reuseInstructions(existing))
        return parse(try await ask(instructions, text, connection: connection, send: send))
    }

    /// A reply that fits the budget whole; otherwise its headings, and the first sentence of
    /// each paragraph, list item and table row, without code, up to the budget.
    static func outline(_ text: String, budget: Int) -> String {
        guard text.count > budget else { return text }
        var lines: [String] = []
        var inCode = false
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            // Blank lines, rules and table separators such as |---|---|.
            guard !inCode, line.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            lines.append(line.hasPrefix("#") ? line : firstSentence(line))
        }
        return String(lines.joined(separator: "\n").prefix(budget))
    }

    /// Up to the first full stop, question or exclamation mark after a few words, or 160 characters.
    private static func firstSentence(_ line: String) -> String {
        let limit = 160
        var end = line.startIndex
        var count = 0
        for index in line.indices {
            count += 1
            end = line.index(after: index)
            if count >= 30, ".?!".contains(line[index]), end == line.endIndex || line[end] == " " { break }
            if count >= limit { return String(line[..<end]) + "…" }
        }
        return String(line[..<end])
    }

    /// Asks which theme each topic belongs to. With `existingThemes`, topics join those where
    /// they fit. Returns each topic's key with its theme.
    static func themes(for topics: [String], existingThemes: [String] = [], connection: KapitsaChatConnection,
                       send: KapitsaChatSummary.Send) async throws -> [String: String] {
        guard !topics.isEmpty else { return [:] }
        let instructions = existingThemes.isEmpty
            ? groupInstructions : groupInstructions + existingThemesInstructions(existingThemes)
        return parseThemes(try await ask(instructions, topics.joined(separator: "\n"), connection: connection, send: send),
                           topics: topics)
    }

    private static func ask(_ instructions: String, _ text: String, connection: KapitsaChatConnection,
                            send: KapitsaChatSummary.Send) async throws -> String {
        var request = try KapitsaChatRequest.urlRequest(
            connection: connection,
            body: KapitsaChatSummary.requestBody(instructions: instructions, text: text, model: connection.model))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try KapitsaChatSummary.replyText(from: try await send(request))
    }

    /// One name per line, places marked "Place:", without the bullets, numbers or quotes a model
    /// may add anyway.
    static func parse(_ text: String) -> Found {
        var seen = Set<String>()
        var found = Found()
        for line in text.split(whereSeparator: \.isNewline) {
            var name = clean(String(line))
            if name.lowercased().hasPrefix(titlePrefix) {
                let title = String(name.dropFirst(titlePrefix.count)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_"))
                if found.title.isEmpty, title.count <= maximumTitleLength { found.title = title }
                continue
            }
            // Models sometimes label topics too.
            for label in ["topics:", "topic:"] where name.lowercased().hasPrefix(label) {
                name = clean(String(name.dropFirst(label.count)))
            }
            let isPlace = name.lowercased().hasPrefix(placePrefix)
            if isPlace { name = clean(String(name.dropFirst(placePrefix.count))) }
            // A chat without places (mathematics, say) may still get "Place: none".
            if ["none", "n/a", "na", "-", "no places", "none mentioned"].contains(name.lowercased()) { continue }
            guard !name.isEmpty, name.count <= maximumLength, seen.insert(key(name)).inserted else { continue }
            // Models often answer in lower case; names read as headings.
            if let first = name.first, first.isLowercase { name = first.uppercased() + name.dropFirst() }
            if isPlace {
                if found.places.count < maximumPlaces { found.places.append(name) }
            } else if found.topics.count < maximumTopics {
                found.topics.append(name)
            }
        }
        return found
    }

    /// Lines of "Theme: topic | topic", keeping only topics that were asked about, so the model
    /// can't invent them. A topic named twice stays in its first theme.
    static func parseThemes(_ text: String, topics: [String]) -> [String: String] {
        let known = Set(topics.map(key))
        var themes: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { clean(String($0)) }
            guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= maximumLength else { continue }
            for topic in parts[1].split(separator: "|").map({ key(clean(String($0))) })
            where known.contains(topic) && themes[topic] == nil {
                themes[topic] = parts[0]
            }
        }
        return themes
    }

    /// Bullets and list numbers ("-", "•", "1.", "2)"), but not a leading number such as "3BR",
    /// and stray quotes or emphasis.
    private static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^(?:[-*•·]+|\d+[.)])\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*_.,;:"))
    }

    /// Names that differ only in case or accents are the same entry.
    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The chat's places and topics so far, newest first, one spelling each, for the model to reuse.
    static func existing(in messages: [KapitsaChatMessage], excluding replyID: UUID) -> [String] {
        var seen = Set<String>()
        return messages.reversed().filter { $0.id != replyID }
            .flatMap { ($0.places ?? []).map { "Place: " + $0 } + ($0.topics ?? []) }
            .filter { seen.insert(key($0)).inserted }
    }

    // MARK: - Index

    struct Mention: Equatable, Identifiable {
        /// The question, which the index scrolls to.
        let id: UUID
        let number: Int
        /// The question's title, or its first line until it has one.
        let question: String
        /// For hovering.
        let fullQuestion: String
    }

    struct Topic: Equatable, Identifiable {
        let id: String
        /// As first written; later spellings that differ only in case join it.
        let name: String
        var mentions: [Mention]
    }

    struct Theme: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let topics: [Topic]
        /// Every question that mentions any of its topics, in order.
        let mentions: [Mention]
    }

    struct Index: Equatable {
        var places: [Topic] = []
        var themes: [Theme] = []
        /// Every place and topic, for filtering.
        var all: [Topic] { places + themes.flatMap(\.topics) }
        var isEmpty: Bool { places.isEmpty && themes.isEmpty }
    }

    /// Theme name for topics the model hasn't grouped yet.
    static let otherTheme = "Other"

    /// Places, then themes with their topics; the most discussed first throughout.
    static func index(_ entries: [KapitsaChatOutline.Entry], themes: [String: String]) -> Index {
        let places = collect(entries) { $0.places }
        let topics = collect(entries) { $0.topics ?? [] }
        var groups: [String: [Topic]] = [:]
        for topic in topics { groups[themes[topic.id] ?? otherTheme, default: []].append(topic) }
        let grouped = groups.map { name, topics -> Theme in
            var seen = Set<UUID>()
            let mentions = topics.flatMap(\.mentions).filter { seen.insert($0.id).inserted }
            return Theme(name: name, topics: topics, mentions: mentions.sorted { $0.number < $1.number })
        }
        return Index(places: places, themes: grouped.sorted { a, b in
            // Other last; otherwise by how many questions a theme covers, then by name.
            if (a.name == otherTheme) != (b.name == otherTheme) { return b.name == otherTheme }
            if a.mentions.count != b.mentions.count { return a.mentions.count > b.mentions.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        })
    }

    private static func collect(_ entries: [KapitsaChatOutline.Entry],
                                _ names: (KapitsaChatOutline.Entry) -> [String]) -> [Topic] {
        var topics: [String: Topic] = [:]
        for entry in entries {
            for name in names(entry) {
                let id = key(name)
                if topics[id] == nil { topics[id] = Topic(id: id, name: name, mentions: []) }
                if topics[id]?.mentions.last?.id != entry.id {
                    topics[id]?.mentions.append(Mention(id: entry.id, number: entry.number, question: entry.displayTitle,
                                                        fullQuestion: entry.fullQuestion))
                }
            }
        }
        return topics.values.sorted {
            $0.mentions.count != $1.mentions.count
                ? $0.mentions.count > $1.mentions.count
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
