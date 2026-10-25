import Foundation
import XCTest
@testable import KapitsaLauncher

@MainActor
final class KapitsaChatLibraryTests: XCTestCase {
    private var root: URL!
    private var folder: URL { root.appendingPathComponent("Chats") }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func library(legacy: KapitsaChatStore? = nil) -> KapitsaChatLibrary {
        // Removed outright: tests shouldn't fill the Trash.
        KapitsaChatLibrary(folder: folder, legacy: legacy, trash: { try? FileManager.default.removeItem(at: $0) }) { store, labels in
            KapitsaChatController(store: store, defaults: UserDefaults(suiteName: "KapitsaChatLibraryTests")!,
                                  streamLines: { _ in AsyncThrowingStream { $0.finish() } }, requestLabels: labels)
        }
    }

    private func turn(_ question: String, title: String? = nil, at date: Date) -> [KapitsaChatMessage] {
        [KapitsaChatMessage(role: .user, text: question, sentAt: date),
         KapitsaChatMessage(role: .assistant, text: "Answer", sentAt: date, title: title)]
    }

    private func write(_ messages: [KapitsaChatMessage], id: UUID = UUID(), in library: KapitsaChatLibrary) -> UUID {
        KapitsaChatStore(url: library.url(for: id)).save(messages)
        return id
    }

    func testTheEarlierSingleChatIsMovedInOnceAndKept() throws {
        let legacy = KapitsaChatStore(url: root.appendingPathComponent("chat.json"))
        let messages = turn("I went to tie my shoe and wondered what quantum mechanics is.",
                            title: "What is quantum mechanics?", at: Date(timeIntervalSince1970: 1_000))
        legacy.save(messages)
        let library = library(legacy: legacy)
        XCTAssertEqual(library.summaries.count, 1)
        let chat = library.summaries[0]
        XCTAssertEqual(chat.name(.title), "What is quantum mechanics?")
        XCTAssertEqual(chat.name(.original), "I went to tie my shoe and wondered what quantum mechanics is.")
        XCTAssertEqual(chat.createdAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(library.controller(for: chat.id).messages, messages)
        XCTAssertEqual(legacy.load(), messages, "the original file is left as a backup")

        // Once the Chats folder exists, deleting every chat doesn't bring the old one back.
        library.delete(chat.id)
        XCTAssertTrue(library.summaries.isEmpty)
        XCTAssertTrue(self.library(legacy: legacy).summaries.isEmpty)
    }

    func testANewChatHasNoFileUntilItHasMessages() {
        let library = library()
        let id = UUID()
        library.rename(id, to: "Ideas")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: id).path))
        XCTAssertTrue(library.summaries.isEmpty)
    }

    func testChatsAreListedMostRecentFirstAndFollowChanges() {
        let library = library()
        let old = write(turn("Old question", at: Date(timeIntervalSince1970: 100)), in: library)
        let new = write(turn("New question", title: "New title", at: Date(timeIntervalSince1970: 200)), in: library)
        library.refresh()
        XCTAssertEqual(library.summaries.map(\.id), [new, old])

        // A change to the older chat moves it to the top; a rename sticks over the automatic name.
        let chat = library.controller(for: old)
        chat.deleteTurn(endingWith: chat.messages[1].id)
        XCTAssertTrue(library.summaries.isEmpty == false && library.summaries.allSatisfy { $0.id != old },
                      "a chat with no messages left isn't listed")
        library.rename(new, to: "  My name  ")
        XCTAssertEqual(library.summaries.first { $0.id == new }?.name(.title), "My name")
        library.rename(new, to: "")
        XCTAssertEqual(library.summaries.first { $0.id == new }?.name(.title), "New title")
    }

    func testTheIndexIsACacheRebuiltFromTheFiles() throws {
        let first = library()
        let id = write(turn("Question", at: Date(timeIntervalSince1970: 100)), in: first)
        first.refresh()
        let index = folder.appendingPathComponent("index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))

        // A deleted index is rebuilt; an entry for a missing file is dropped.
        try FileManager.default.removeItem(at: index)
        XCTAssertEqual(library().summaries.map(\.id), [id])
        try FileManager.default.removeItem(at: first.url(for: id))
        XCTAssertTrue(library().summaries.isEmpty)
    }

    func testChatsAreGroupedByWhenTheyWereLastUsed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21, 14:13 UTC
        let day: TimeInterval = 86_400
        func chat(_ daysAgo: Double) -> KapitsaChatLibrary.Summary {
            let date = now.addingTimeInterval(-daysAgo * day)
            return .init(id: UUID(), firstQuestion: "Q", createdAt: date, updatedAt: date, fileDate: date)
        }
        let groups = KapitsaChatLibrary.groups([chat(0), chat(0.2), chat(1), chat(3), chat(20), chat(60), chat(400)],
                                               now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title).prefix(4), ["Today", "Yesterday", "Previous 7 days", "Previous 30 days"])
        XCTAssertEqual(groups.map(\.chats.count), [2, 1, 1, 1, 1, 1])
    }

    func testAContinuedChatStartsFromTheSummaryAndLinksBothWays() {
        let library = library()
        let old = write(turn("I went to tie my shoe and wondered what quantum mechanics is.",
                             title: "What is quantum mechanics?", at: Date(timeIntervalSince1970: 100)), in: library)
        library.refresh()
        let newID = UUID()
        let continuation = KapitsaChatContinuation(chatID: old, name: "What is quantum mechanics?", summary: "We covered superposition.")
        library.controller(for: newID).startContinuation(continuation)
        library.controller(for: old).markContinued(in: newID)

        // Listed straight away, before its first message, under the earlier chat's name.
        XCTAssertEqual(library.summaries.first?.id, newID)
        XCTAssertEqual(library.summaries.first?.name(.title), "What is quantum mechanics? (continued)")
        let reloaded = self.library()
        XCTAssertEqual(reloaded.controller(for: newID).continuesFrom, continuation)
        XCTAssertEqual(reloaded.controller(for: old).continuedIn, newID)

        // The model reads the summary first.
        let body = KapitsaChatRequest.body(history: [KapitsaChatMessage(role: .user, text: "And entanglement?")],
                                           thinking: .off, model: "m", continuing: continuation.summary)
        let sent = body["messages"] as? [[String: Any]]
        XCTAssertEqual(sent?.first?["role"] as? String, "system")
        XCTAssertTrue((sent?.first?["content"] as? String)?.hasSuffix("We covered superposition.") == true)
        XCTAssertEqual(sent?.count, 2)
    }

    func testDeletingRemovesTheFileAndEntry() {
        let library = library()
        let id = write(turn("Question", at: Date()), in: library)
        library.refresh()
        library.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: id).path))
        XCTAssertTrue(library.summaries.isEmpty)
    }
}
