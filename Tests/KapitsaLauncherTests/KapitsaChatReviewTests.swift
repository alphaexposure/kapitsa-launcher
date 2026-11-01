import XCTest
@testable import KapitsaLauncher

final class KapitsaChatReviewTests: XCTestCase {
    func testParsesTakeawaysWithTheirQuestions() {
        let ids = [UUID(), UUID(), UUID()]
        let text = """
        Here are the takeaways:
        - **Coastal towns** swing less between day and night. [Q1, Q3]
        2. Humidity matters as much as heat [Q2].
        • Altitude raises UV.
        - Something from a question that isn't there [Q9]
        -
        """
        let takeaways = KapitsaChatReview.parseTakeaways(text, questionIDs: ids)
        XCTAssertEqual(takeaways.map(\.text), [
            "Coastal towns swing less between day and night.", "Humidity matters as much as heat",
            "Altitude raises UV.", "Something from a question that isn't there",
        ])
        XCTAssertEqual(takeaways.map(\.questionIDs), [[ids[0], ids[2]], [ids[1]], [], []])
    }

    func testTakeawaysWithoutBulletsCountWhenTheyNameTheirQuestions() {
        let ids = [UUID(), UUID()]
        let text = """
        San Diego has the driest summers. [Q2]
        Charleston has the best food, but humid summers. [Q1, Q2].
        Here are the takeaways:
        """
        let takeaways = KapitsaChatReview.parseTakeaways(text, questionIDs: ids)
        XCTAssertEqual(takeaways.map(\.text), ["San Diego has the driest summers.", "Charleston has the best food, but humid summers."])
        XCTAssertEqual(takeaways.map(\.questionIDs), [[ids[1]], [ids[0], ids[1]]])
    }

    func testSavedFileNamesTheChatAndEachTakeawaysQuestions() {
        let q3 = UUID(), q7 = UUID()
        let takeaways = [KapitsaChatReview.Takeaway(text: "Tenerife has the sandiest beaches.", questionIDs: [q3, q7]),
                         KapitsaChatReview.Takeaway(text: "Mine", isOwn: true)]
        let date = DateComponents(calendar: .current, year: 2026, month: 10, day: 25).date!
        XCTAssertEqual(KapitsaChatReview.document(takeaways, chatName: "Warm places",
                                                  questions: [q3: (3, "Beaches?"), q7: (7, "Back to Portugal")], date: date), """
        # Takeaways: Warm places

        Saved \(date.formatted(date: .long, time: .omitted))

        - Tenerife has the sandiest beaches.
          *From: 3. Beaches?; 7. Back to Portugal*
        - Mine

        """)
        XCTAssertEqual(KapitsaChatReview.fileName(chatName: "Spain: where/when?"), "Spain- where-when- takeaways.md")
    }

    func testTakeawayCountFollowsTheChatsLength() {
        XCTAssertEqual(KapitsaChatReview.takeawayCount(questions: 1, isUpdate: false), 3)
        XCTAssertEqual(KapitsaChatReview.takeawayCount(questions: 14, isUpdate: false), 7)
        XCTAssertEqual(KapitsaChatReview.takeawayCount(questions: 40, isUpdate: false), 10)
        XCTAssertEqual(KapitsaChatReview.takeawayCount(questions: 1, isUpdate: true), 1)
        XCTAssertEqual(KapitsaChatReview.takeawayCount(questions: 30, isUpdate: true), 5)
    }

    func testTranscriptOfSomeQuestionsKeepsTheChatsNumbers() {
        let q1 = KapitsaChatMessage(role: .user, text: "One"), q2 = KapitsaChatMessage(role: .user, text: "Two")
        let messages = [q1, KapitsaChatMessage(role: .assistant, text: "A1"), q2, KapitsaChatMessage(role: .assistant, text: "A2")]
        XCTAssertEqual(KapitsaChatSummary.transcript(messages, only: [q2.id]), ["Question 2:\nTwo", "Reply 2:\nA2"])
    }

    func testNewQuestionsAreTheOnesNotRead() {
        let q1 = KapitsaChatMessage(role: .user, text: "One"), q2 = KapitsaChatMessage(role: .user, text: "Two")
        let review = KapitsaChatReview(coveredQuestions: [q1.id])
        XCTAssertEqual(review.newQuestions(in: [q1, KapitsaChatMessage(role: .assistant, text: "A"), q2]), [q2.id])
    }
}

@MainActor
final class KapitsaChatReviewControllerTests: XCTestCase {
    private let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: nil, model: "m")

    /// A chat with `messages`, or with what `file` already holds when they're nil.
    private func controller(_ messages: [KapitsaChatMessage]?, file: URL,
                            reply: @escaping @Sendable (String, String) -> String) -> KapitsaChatController {
        let store = KapitsaChatStore(url: file)
        if let messages { store.save(messages) }
        return KapitsaChatController(store: store, defaults: UserDefaults(suiteName: "KapitsaChatReviewControllerTests")!,
                                     send: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let parts = body["messages"] as! [[String: String]]
            return try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": reply(parts[0]["content"]!, parts[1]["content"]!)]]]])
        }, streamLines: { _ in AsyncThrowingStream { $0.finish() } })
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/chat.json")
    }

    private func waitForReviewWork(_ chat: KapitsaChatController) async throws {
        for _ in 0..<200 where chat.reviewWork != nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testWritesThenUpdatesTakeawaysKeepingTheOnesAlreadyThere() async throws {
        let file = temporaryFile()
        let q1 = KapitsaChatMessage(role: .user, text: "Q1"), q2 = KapitsaChatMessage(role: .user, text: "Q2")
        var messages = [q1, KapitsaChatMessage(role: .assistant, text: "A1")]
        let chat = controller(messages, file: file) { _, text in
            text.contains("Question 2") ? "- From the second [Q2]" : "- From the first [Q1]\n- Also first [Q1]"
        }
        chat.writeTakeaways(connection: connection, contextTokens: nil, update: false)
        try await waitForReviewWork(chat)
        XCTAssertEqual(chat.review.takeaways.map(\.text), ["From the first", "Also first"])
        XCTAssertEqual(chat.review.takeaways.first?.questionIDs, [q1.id])
        XCTAssertEqual(KapitsaChatStore(url: file).loadDocument().review, chat.review)

        // A second question, as if asked since; the update reads only that one.
        messages += [q2, KapitsaChatMessage(role: .assistant, text: "A2")]
        var document = KapitsaChatStore(url: file).loadDocument()
        document.messages = messages
        KapitsaChatStore(url: file).save(document)
        let reopened = controller(nil, file: file) { _, text in
            XCTAssertFalse(text.contains("Question 1"))
            XCTAssertTrue(text.contains("- From the first"), "existing takeaways aren't repeated")
            return "- From the second [Q2]"
        }
        reopened.addTakeaway("My own")
        XCTAssertEqual(reopened.review.newQuestions(in: reopened.messages), [q2.id])
        reopened.writeTakeaways(connection: connection, contextTokens: nil, update: true)
        try await waitForReviewWork(reopened)
        XCTAssertEqual(reopened.review.takeaways.map(\.text), ["From the first", "Also first", "My own", "From the second"])
        XCTAssertEqual(reopened.review.takeaways.last?.questionIDs, [q2.id])
        XCTAssertTrue(reopened.review.newQuestions(in: reopened.messages).isEmpty)
    }

    func testALongChatIsReadInSectionsSoLaterQuestionsCount() async throws {
        // A large context alone would fit this chat in one request; the cap splits it anyway.
        XCTAssertEqual(KapitsaChatSummary.readingBudget(contextTokens: 131_072), KapitsaChatSummary.maximumSectionTokens)
        XCTAssertEqual(KapitsaChatSummary.readingBudget(contextTokens: 8_192), KapitsaChatSummary.sectionBudget(contextTokens: 8_192))

        let long = String(repeating: "Lisbon rent and schools. ", count: 600)  // about 3,750 tokens
        var messages: [KapitsaChatMessage] = []
        for n in 1...8 {
            messages += [KapitsaChatMessage(role: .user, text: "Q\(n)"), KapitsaChatMessage(role: .assistant, text: long)]
        }
        var requests = 0
        let chat = controller(messages, file: temporaryFile()) { _, text in
            requests += 1
            let first = text.range(of: #"Question (\d+)"#, options: .regularExpression).map { String(text[$0]) } ?? "?"
            let line = "- From " + first + " [Q" + first.dropFirst("Question ".count) + "]"
            return Array(repeating: line, count: 6).joined(separator: "\n")  // more than its share
        }
        chat.writeTakeaways(connection: connection, contextTokens: 131_072, update: false)
        try await waitForReviewWork(chat)
        XCTAssertGreaterThan(requests, 1)
        let share = max(2, KapitsaChatReview.takeawayCount(questions: 8, isUpdate: false) / requests)
        XCTAssertEqual(chat.review.takeaways.count, share * requests, "each section gives only its share")
        XCTAssertTrue(chat.review.takeaways.contains { $0.text != "From Question 1" }, "later sections are read too")
    }

    func testWritingAgainKeepsPinnedAndOwnTakeaways() async throws {
        let file = temporaryFile()
        let chat = controller([KapitsaChatMessage(role: .user, text: "Q1"), KapitsaChatMessage(role: .assistant, text: "A1")],
                              file: file) { _, _ in "- Fresh [Q1]" }
        chat.writeTakeaways(connection: connection, contextTokens: nil, update: false)
        try await waitForReviewWork(chat)
        chat.addTakeaway("Mine")
        chat.writeTakeaways(connection: connection, contextTokens: nil, update: false)
        try await waitForReviewWork(chat)
        XCTAssertEqual(chat.review.takeaways.map(\.text), ["Mine", "Fresh"])
        chat.setTakeawayPinned(chat.review.takeaways[1].id, true)
        chat.editTakeaway(chat.review.takeaways[0].id, text: "  ")
        XCTAssertEqual(chat.review.takeaways.map(\.text), ["Fresh"], "blank text deletes")
        XCTAssertEqual(chat.review.takeaways.first?.pinned, true)
    }
}
