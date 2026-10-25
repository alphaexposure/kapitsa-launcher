import Foundation
import SwiftUI

/// Finding words in a chat (⌘F) and across saved chats: matches ignore case and accents, and
/// only the shown version of each question counts, as it's the one on screen.
enum KapitsaChatFind {
    struct Match: Equatable {
        /// The message the match is in, which the conversation scrolls to.
        let messageID: UUID
        /// Which match within that message, from 0.
        let occurrence: Int
        /// Where the match sits in the message, from 0 (start) to 1 (end), to scroll near it.
        var position: Double = 0
    }

    /// Wrap the current match in the text before it's drawn, so it can be told apart from the
    /// others after Markdown has been applied. Private-use characters, never in a reply.
    static let currentStart: Character = "\u{E000}"
    static let currentEnd: Character = "\u{E001}"

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    /// Searching starts at two characters: one floods the chat with highlights, while two still
    /// finds short terms such as "AI", "UK" or "17".
    static let minimumLength = 2

    /// The words to search for, or nil while they're too short.
    static func searchable(_ query: String) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count >= minimumLength ? query : nil
    }

    /// Every match of `query` in the messages' text, in order.
    static func matches(of query: String, in messages: [KapitsaChatMessage]) -> [Match] {
        guard let query = searchable(query) else { return [] }
        return messages.flatMap { message in
            let length = Double(max(message.text.utf16.count, 1))
            return ranges(of: query, in: message.text).enumerated().map { index, range in
                Match(messageID: message.id, occurrence: index,
                      position: Double(range.lowerBound.utf16Offset(in: message.text)) / length)
            }
        }
    }

    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: options, range: start..<text.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }

    /// `text` with match `occurrence` of `query` wrapped in the current-match markers.
    static func markingCurrent(_ text: String, _ query: String, occurrence: Int?) -> String {
        guard let occurrence else { return text }
        let found = ranges(of: query.trimmingCharacters(in: .whitespacesAndNewlines), in: text)
        guard found.indices.contains(occurrence) else { return text }
        let range = found[occurrence]
        return String(text[..<range.lowerBound]) + String(currentStart) + text[range]
            + String(currentEnd) + text[range.upperBound...]
    }

    static func unmarked(_ text: String) -> String {
        text.filter { $0 != currentStart && $0 != currentEnd }
    }

    /// `text` with every match of `query` marked, for drawing, and the current match (between
    /// the markers, which are removed) marked more strongly.
    static func highlighted(_ text: AttributedString, _ query: String) -> AttributedString {
        guard let query = searchable(query) else { return text }
        var text = text
        // Where the current match starts, once the markers are taken out.
        var current: Int?
        if let start = text.characters.firstIndex(of: currentStart) {
            current = text.characters.distance(from: text.startIndex, to: start)
            text.characters.remove(at: start)
        }
        if let end = text.characters.firstIndex(of: currentEnd) { text.characters.remove(at: end) }
        let plain = String(text.characters)
        for range in ranges(of: query, in: plain) {
            let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let start = text.characters.index(text.startIndex, offsetBy: lower)
            let end = text.characters.index(start, offsetBy: length)
            let isCurrent = current == lower
            text[start..<end].backgroundColor = isCurrent ? KapitsaTheme.findCurrent : KapitsaTheme.findHighlight
            text[start..<end].foregroundColor = isCurrent ? .white : .black
        }
        return text
    }

    /// A chat that mentions the words: how often, and a line around the first mention.
    struct Hit: Equatable {
        let count: Int
        let snippet: String
    }

    /// The first mention of `query` with some text either side, on one line.
    static func hit(for query: String, in messages: [KapitsaChatMessage]) -> Hit? {
        guard let query = searchable(query) else { return nil }
        var count = 0
        var snippet: String?
        for message in messages {
            let found = ranges(of: query, in: message.text)
            guard let first = found.first else { continue }
            count += found.count
            if snippet == nil {
                let text = message.text
                let before = text[..<first.lowerBound].suffix(40)
                let after = text[first.upperBound...].prefix(70)
                let line = (before.count == 40 ? "…" : "") + before + text[first] + after + (after.count == 70 ? "…" : "")
                snippet = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"[*_`#|>]+"#, with: "", options: .regularExpression)
            }
        }
        return snippet.map { Hit(count: count, snippet: $0) }
    }
}
