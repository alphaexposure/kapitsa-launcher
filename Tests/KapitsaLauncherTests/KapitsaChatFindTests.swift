import Foundation
import SwiftUI
import XCTest
@testable import KapitsaLauncher

final class KapitsaChatFindTests: XCTestCase {
    private let messages = [
        KapitsaChatMessage(role: .user, text: "Is Málaga warm in winter?"),
        KapitsaChatMessage(role: .assistant, text: "**Malaga** stays mild; malaga's winters average 17°C."),
        KapitsaChatMessage(role: .user, text: "And Funchal?"),
    ]

    func testMatchesIgnoreCaseAndAccentsInOrder() {
        let matches = KapitsaChatFind.matches(of: " malaga ", in: messages)
        XCTAssertEqual(matches.map(\.messageID), [messages[0].id, messages[1].id, messages[1].id])
        XCTAssertEqual(matches.map(\.occurrence), [0, 0, 1])
        XCTAssertTrue(KapitsaChatFind.matches(of: "  ", in: messages).isEmpty)
        XCTAssertTrue(KapitsaChatFind.matches(of: "Lisbon", in: messages).isEmpty)
    }

    func testHighlightingMarksEveryMatchInRenderedText() {
        let rendered = ChatMarkdownView.inline(messages[1].text) // "Malaga stays mild; malaga's ..."
        let marked = KapitsaChatFind.highlighted(rendered, "MALAGA")
        let highlighted = marked.runs.filter { $0.backgroundColor != nil }.map { String(marked[$0.range].characters) }
        XCTAssertEqual(highlighted, ["Malaga", "malaga"])
        XCTAssertEqual(KapitsaChatFind.highlighted(rendered, ""), rendered)
    }

    func testTheCurrentMatchIsMarkedApartAndCopiesStayClean() {
        let text = messages[1].text // "**Malaga** stays mild; malaga's winters average 17°C."
        let marked = KapitsaChatFind.markingCurrent(text, "malaga", occurrence: 1)
        XCTAssertEqual(KapitsaChatFind.unmarked(marked), text)
        let drawn = KapitsaChatFind.highlighted(ChatMarkdownView.inline(marked), "malaga")
        XCTAssertEqual(String(drawn.characters), "Malaga stays mild; malaga's winters average 17°C.", "the marks aren't drawn")
        let runs = drawn.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(runs.map { String(drawn[$0.range].characters) }, ["Malaga", "malaga"])
        XCTAssertEqual(runs.map(\.backgroundColor), [KapitsaTheme.findHighlight, KapitsaTheme.findCurrent])
        // Positions run from the start of a message to its end, for scrolling near the word.
        let positions = KapitsaChatFind.matches(of: "malaga", in: [messages[1]]).map(\.position)
        XCTAssertEqual(positions.first, 2.0 / Double(text.utf16.count))
        XCTAssertGreaterThan(positions[1], 0.3)
    }

    func testAHitCountsMentionsAndShowsTheFirstOnOneLine() {
        let hit = KapitsaChatFind.hit(for: "malaga", in: messages)
        XCTAssertEqual(hit?.count, 3)
        XCTAssertEqual(hit?.snippet, "Is Málaga warm in winter?")
        XCTAssertNil(KapitsaChatFind.hit(for: "Lisbon", in: messages))
        let long = [KapitsaChatMessage(role: .assistant, text: String(repeating: "word ", count: 30) + "**Funchal**\nis mild" + String(repeating: " more", count: 30))]
        let snippet = KapitsaChatFind.hit(for: "funchal", in: long)?.snippet ?? ""
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("Funchal is mild"), "emphasis marks and line breaks are cleaned up")
    }
}

@MainActor
final class KapitsaChatLibrarySearchTests: XCTestCase {
    func testSearchFindsChatsByWhatWasSaid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = KapitsaChatLibrary(folder: folder, trash: { try? FileManager.default.removeItem(at: $0) }) { store, labels in
            KapitsaChatController(store: store, defaults: UserDefaults(suiteName: "KapitsaChatLibrarySearchTests")!,
                                  streamLines: { _ in AsyncThrowingStream { $0.finish() } }, requestLabels: labels)
        }
        let beach = UUID(), school = UUID()
        KapitsaChatStore(url: library.url(for: beach)).save([
            KapitsaChatMessage(role: .user, text: "Sandy beaches near Funchal?", sentAt: Date()),
            KapitsaChatMessage(role: .assistant, text: "Calheta has a sandy beach.", sentAt: Date()),
        ])
        KapitsaChatStore(url: library.url(for: school)).save([KapitsaChatMessage(role: .user, text: "Schools in Lagos?", sentAt: Date())])
        library.refresh()
        let hits = await library.search("sandy")
        XCTAssertEqual(Set(hits.keys), [beach])
        XCTAssertEqual(hits[beach]?.count, 2)
    }
}
