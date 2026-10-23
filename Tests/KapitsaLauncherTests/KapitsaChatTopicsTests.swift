import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaChatTopicsTests: XCTestCase {
    func testParseSeparatesPlacesAndKeepsShortUniqueTopics() {
        let text = """
        Place: None
        Place: Funchal
        place: santa Cruz, Tenerife
        - Place: **Chania**
        Place: Funchal
        Place: Atlanta
        Place: Prague
        1. 3BR rentals
        - **Residency permits**
        • "cost of living"
        This line is far too long to be a short topic that someone would look up later
        Schooling
        Walkability
        """
        XCTAssertEqual(KapitsaChatTopics.parse(text), .init(
            places: ["Funchal", "Santa Cruz, Tenerife", "Chania", "Atlanta"],
            topics: ["3BR rentals", "Residency permits", "Cost of living", "Schooling"]))
    }

    func testEarlierNamesAreOfferedForReuseNewestFirst() async throws {
        let reply = KapitsaChatMessage(role: .assistant, text: "Funchal again.")
        let messages = [
            KapitsaChatMessage(role: .assistant, text: "A", topics: ["Climate"], places: ["Funchal"]),
            KapitsaChatMessage(role: .assistant, text: "B", topics: ["Cost of living"]),
            reply,
        ]
        let existing = KapitsaChatTopics.existing(in: messages, excluding: reply.id)
        XCTAssertEqual(existing, ["Cost of living", "Place: Funchal", "Climate"])
        let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: nil, model: "m")
        _ = try await KapitsaChatTopics.find(question: nil, reply: reply, existing: existing, connection: connection) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let instructions = ((body["messages"] as! [[String: String]])[0])["content"]!
            XCTAssertTrue(instructions.contains("Cost of living\nPlace: Funchal\nClimate\nList only what this exchange itself is about"))
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "Place: Funchal"]]]])
        }
    }

    func testThemesKeepOnlyKnownTopicsOnceEach() {
        let text = """
        Residency: EU family permit | czech citizenship | Invented topic
        Climate and skin: Sensitive skin | EU family permit
        Not a theme line
        """
        XCTAssertEqual(KapitsaChatTopics.parseThemes(text, topics: ["EU family permit", "Czech citizenship", "Sensitive skin"]), [
            "eu family permit": "Residency", "czech citizenship": "Residency", "sensitive skin": "Climate and skin",
        ])
    }

    func testIndexHasPlacesThenThemesMostDiscussedFirst() {
        let q1 = KapitsaChatMessage(role: .user, text: "Warm places?")
        let q2 = KapitsaChatMessage(role: .user, text: "Costs?")
        let messages = [
            q1, KapitsaChatMessage(role: .assistant, text: "Madeira.", topics: ["Climate", "Sensitive skin"], places: ["Funchal"]),
            q2, KapitsaChatMessage(role: .assistant, text: "Cheaper.", topics: ["Cost of living", "climate", "Rent"],
                                   places: ["Chania", "funchal"]),
            KapitsaChatMessage(role: .user, text: "Pending?"), KapitsaChatMessage(role: .assistant, text: "Later."),
        ]
        let entries = KapitsaChatOutline.entries(from: messages)
        XCTAssertNil(entries[2].topics, "a reply whose topics aren't found yet")
        let index = KapitsaChatTopics.index(entries, themes: [
            "climate": "Climate and skin", "sensitive skin": "Climate and skin", "cost of living": "Costs",
        ])
        XCTAssertEqual(index.places.map(\.name), ["Funchal", "Chania"])
        XCTAssertEqual(index.places[0].mentions.map(\.id), [q1.id, q2.id])
        // Climate and skin covers both questions, Costs one; ungrouped Rent goes under Other, last.
        XCTAssertEqual(index.themes.map(\.name), ["Climate and skin", "Costs", "Other"])
        XCTAssertEqual(index.themes[0].topics.map(\.name), ["Climate", "Sensitive skin"])
        XCTAssertEqual(index.themes[0].mentions.map(\.number), [1, 2])
        XCTAssertEqual(index.themes[2].topics.map(\.name), ["Rent"])
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
        // A file from before themes, a plain list of messages, loads into the new document.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(KapitsaChatStore(url: file).loadDocument(), .init(messages: messages, topicThemes: [:]))
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

    func testFindsMissingTopicsThenGroupsThemAndSaves() async throws {
        let file = temporaryFile()
        let messages = [
            KapitsaChatMessage(role: .user, text: "Q1"), KapitsaChatMessage(role: .assistant, text: "A1"),
            KapitsaChatMessage(role: .user, text: "Q2"), KapitsaChatMessage(role: .assistant, text: "A2", topics: ["Done"]),
            KapitsaChatMessage(role: .user, text: "Q3"), KapitsaChatMessage(role: .assistant, text: "A3"),
        ]
        let chat = controller(messages, file: file) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let parts = body["messages"] as! [[String: String]]
            let (instructions, text) = (parts[0]["content"]!, parts[1]["content"]!)
            let reply = instructions.hasPrefix("These are topics")
                ? "Ordinals: First topic | Third topic\nFinished: Done"
                : (text.contains("A1") ? "Place: Lisbon\nFirst topic" : "Third topic")
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": reply]]]])
        }
        XCTAssertEqual(chat.repliesNeedingTopics, 2)
        chat.findMissingTopics(connection: connection)
        XCTAssertEqual(chat.topicProgress, .init(done: 0, total: 2))
        for _ in 0..<200 where chat.topicProgress != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(chat.messages.compactMap(\.topics), [["First topic"], ["Done"], ["Third topic"]])
        XCTAssertEqual(chat.messages.compactMap(\.places), [["Lisbon"], []])
        XCTAssertEqual(chat.topicThemes, ["first topic": "Ordinals", "third topic": "Ordinals", "done": "Finished"])
        XCTAssertEqual(chat.repliesNeedingTopics, 0)
        XCTAssertEqual(KapitsaChatStore(url: file).loadDocument(), .init(messages: chat.messages, topicThemes: chat.topicThemes))
    }

    func testNewTopicsJoinExistingThemes() async throws {
        let file = temporaryFile()
        let store = KapitsaChatStore(url: file)
        store.save([KapitsaChatMessage(role: .assistant, text: "A", topics: ["Rent", "Schools"])],
                   topicThemes: ["rent": "Housing and costs"])
        var sentInstructions = ""
        let chat = KapitsaChatController(store: store, defaults: UserDefaults(suiteName: "KapitsaChatTopicsControllerTests")!,
                                         send: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let parts = body["messages"] as! [[String: String]]
            sentInstructions = parts[0]["content"]! + "\n--\n" + parts[1]["content"]!
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "Family: Schools"]]]])
        }, streamLines: { _ in AsyncThrowingStream { $0.finish() } })
        await chat.groupTopics(connection: connection)
        XCTAssertTrue(sentInstructions.contains("already has these themes:\nHousing and costs"))
        XCTAssertTrue(sentInstructions.hasSuffix("--\nSchools"), "only the new topic is sent")
        XCTAssertEqual(chat.topicThemes, ["rent": "Housing and costs", "schools": "Family"])
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
