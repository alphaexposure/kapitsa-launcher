import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaChatTopicsTests: XCTestCase {
    func testParseKeepsShortUniqueConceptsWithoutListMarks() {
        let text = """
        1. Funchal
        2) 3BR rentals
        - **Sensitive skin**
        • "Residency permits"
        funchal
        This line is far too long to be a short concept that someone would look up later
        cost of living
        Schools
        Walkability
        Healthcare
        """
        XCTAssertEqual(KapitsaChatTopics.parse(text),
                       ["Funchal", "3BR rentals", "Sensitive skin", "Residency permits", "Cost of living", "Schools"])
    }

    func testEarlierTopicsAreOfferedForReuseNewestFirst() async throws {
        let reply = KapitsaChatMessage(role: .assistant, text: "Funchal again.")
        let messages = [
            KapitsaChatMessage(role: .assistant, text: "A", topics: ["Funchal", "Climate"]),
            KapitsaChatMessage(role: .assistant, text: "B", topics: ["Cost of living", "funchal"]),
            reply,
        ]
        let existing = KapitsaChatTopics.existing(in: messages, excluding: reply.id)
        XCTAssertEqual(existing, ["Cost of living", "funchal", "Climate"])
        let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: nil, model: "m")
        _ = try await KapitsaChatTopics.find(question: nil, reply: reply, existing: existing, connection: connection) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let instructions = ((body["messages"] as! [[String: String]])[0])["content"]!
            XCTAssertTrue(instructions.contains("Cost of living\nfunchal\nClimate\nList only what this exchange itself is about"))
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "Funchal"]]]])
        }
    }

    func testMergesOnlyKnownNamesAndApplyThem() {
        let known = ["Sensitive skin", "Temperature sensitive skin", "Skin sensitivity", "Funchal", "Cost of living"]
        let text = """
        Sensitive skin = Temperature sensitive skin | skin sensitivity
        Funchal = Madeira
        Invented = Cost of living
        Funchal = Cost of living
        """
        let merges = KapitsaChatTopics.parseMerges(text, known: known)
        XCTAssertEqual(merges, ["temperature sensitive skin": "Sensitive skin", "skin sensitivity": "Sensitive skin"])
        XCTAssertEqual(KapitsaChatTopics.applying(merges, to: ["Skin sensitivity", "Funchal", "Sensitive skin"]),
                       ["Sensitive skin", "Funchal"])
        XCTAssertTrue(KapitsaChatTopics.sharesWord("Daughter schooling", "Family schooling options"))
        XCTAssertTrue(KapitsaChatTopics.sharesWord("Budget constraint", "Budget constraints"))
        XCTAssertFalse(KapitsaChatTopics.sharesWord("Budget constraints", "Czech EU residency"))
    }

    func testIndexGroupsTopicsAcrossQuestionsAlphabetically() {
        let q1 = KapitsaChatMessage(role: .user, text: "Warm places?")
        let q2 = KapitsaChatMessage(role: .user, text: "Costs?")
        let messages = [
            q1, KapitsaChatMessage(role: .assistant, text: "Madeira.", topics: ["Funchal", "Climate"]),
            q2, KapitsaChatMessage(role: .assistant, text: "Cheaper.", topics: ["Cost of living", "funchal"]),
            KapitsaChatMessage(role: .user, text: "Pending?"), KapitsaChatMessage(role: .assistant, text: "Later."),
        ]
        let entries = KapitsaChatOutline.entries(from: messages)
        XCTAssertNil(entries[2].topics, "a reply whose topics aren't found yet")
        let index = KapitsaChatTopics.index(entries)
        XCTAssertEqual(index.map(\.name), ["Climate", "Cost of living", "Funchal"])
        XCTAssertEqual(index[2].mentions.map(\.id), [q1.id, q2.id])
        XCTAssertEqual(index[2].mentions.map(\.number), [1, 2])
    }

    func testRepliesWithoutTextNeedNoTopics() {
        XCTAssertFalse(KapitsaChatMessage(role: .assistant, text: "", errorMessage: "HTTP 500").needsTopics)
        XCTAssertFalse(KapitsaChatMessage(role: .assistant, text: "Hi", topics: []).needsTopics)
        XCTAssertFalse(KapitsaChatMessage(role: .user, text: "Hi").needsTopics)
        XCTAssertTrue(KapitsaChatMessage(role: .assistant, text: "Hi").needsTopics)
    }

    func testOldSavedChatsWithoutTheNewFieldsStillLoad() throws {
        let json = #"[{"id":"9B3E1C2A-7F4D-4E55-9A0B-1C2D3E4F5A6B","role":"user","text":"Hi","reasoning":"","attachments":[],"wasStopped":false}]"#
        let messages = try JSONDecoder().decode([KapitsaChatMessage].self, from: Data(json.utf8))
        XCTAssertNil(messages[0].topics)
        XCTAssertNil(messages[0].outlineCollapsed)
    }
}

@MainActor
final class KapitsaChatTopicsControllerTests: XCTestCase {
    private let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: nil, model: "m")

    private func controller(_ messages: [KapitsaChatMessage], file: URL,
                            send: @escaping KapitsaChatSummary.Send) -> KapitsaChatController {
        let store = KapitsaChatStore(url: file)
        store.save(messages)
        let defaults = UserDefaults(suiteName: "KapitsaChatTopicsControllerTests")!
        return KapitsaChatController(store: store, defaults: defaults, send: send,
                                     streamLines: { _ in AsyncThrowingStream { $0.finish() } })
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/chat.json")
    }

    func testFoldsAreSavedWithTheChat() {
        let file = temporaryFile()
        let question = KapitsaChatMessage(role: .user, text: "Q")
        let chat = controller([question, KapitsaChatMessage(role: .assistant, text: "# A")], file: file) { _ in Data() }
        chat.setOutlineCollapsed(true, questions: [question.id])
        XCTAssertEqual(KapitsaChatStore(url: file).load().first?.outlineCollapsed, true)
        XCTAssertEqual(KapitsaChatOutline.entries(from: chat.messages).first?.isCollapsed, true)
        chat.setOutlineCollapsed(false, questions: [question.id])
        XCTAssertNil(KapitsaChatStore(url: file).load().first?.outlineCollapsed)
    }

    func testFindsMissingTopicsOneAtATimeAndSavesThem() async throws {
        let file = temporaryFile()
        let messages = [
            KapitsaChatMessage(role: .user, text: "Q1"), KapitsaChatMessage(role: .assistant, text: "A1"),
            KapitsaChatMessage(role: .user, text: "Q2"), KapitsaChatMessage(role: .assistant, text: "A2", topics: ["Done"]),
            KapitsaChatMessage(role: .user, text: "Q3"), KapitsaChatMessage(role: .assistant, text: "A3"),
        ]
        let chat = controller(messages, file: file) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let text = ((body["messages"] as! [[String: String]])[1])["content"]!
            let topic = text.hasPrefix("Reply") || text.contains("Question") ? (text.contains("A1") ? "First topic" : "Third topic") : "First topic = Third topic"
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": topic]]]])
        }
        XCTAssertEqual(chat.repliesNeedingTopics, 2)
        chat.findMissingTopics(connection: connection)
        XCTAssertEqual(chat.topicProgress, .init(done: 0, total: 2))
        for _ in 0..<200 where chat.topicProgress != nil { try await Task.sleep(for: .milliseconds(5)) }
        // The merge request at the end said First and Third are the same concept.
        XCTAssertEqual(chat.messages.compactMap(\.topics), [["First topic"], ["Done"], ["First topic"]])
        XCTAssertEqual(chat.repliesNeedingTopics, 0)
        XCTAssertEqual(KapitsaChatStore(url: file).load(), chat.messages)
    }

    func testAFailedTopicRequestLeavesTheReplyToTryAgain() async {
        let reply = KapitsaChatMessage(role: .assistant, text: "A")
        let chat = controller([KapitsaChatMessage(role: .user, text: "Q"), reply], file: temporaryFile()) { _ in
            throw URLError(.cannotConnectToHost)
        }
        await chat.findTopics(replyID: reply.id, connection: connection)
        XCTAssertEqual(chat.repliesNeedingTopics, 1)
    }
}
