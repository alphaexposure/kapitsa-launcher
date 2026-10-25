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
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every match of `query` in the messages' text, in order.
    static func matches(of query: String, in messages: [KapitsaChatMessage]) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return messages.flatMap { message in
            ranges(of: query, in: message.text).indices.map { Match(messageID: message.id, occurrence: $0) }
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

    /// `text` with every match of `query` marked, for drawing.
    static func highlighted(_ text: AttributedString, _ query: String) -> AttributedString {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return text }
        var text = text
        let plain = String(text.characters)
        for range in ranges(of: query, in: plain) {
            let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let start = text.characters.index(text.startIndex, offsetBy: lower)
            let end = text.characters.index(start, offsetBy: length)
            text[start..<end].backgroundColor = KapitsaTheme.findHighlight
            text[start..<end].foregroundColor = .black
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
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
