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

    func testParsesQuizQuestionsAndAnswers() {
        let text = """
        **Question 1:** Why are coastal towns steadier?
        Answer 1: The sea holds heat,
        so nights stay mild.
        Question 2: What does altitude do to UV?
        Question 3: Unanswered?
        Answer 2: It raises it.
        """
        let parsed = KapitsaChatReview.parseQuiz(text)
        XCTAssertEqual(parsed.map(\.0), [1, 2])
        XCTAssertEqual(parsed.map(\.1), ["Why are coastal towns steadier?", "What does altitude do to UV?"])
        XCTAssertEqual(parsed.map(\.2), ["The sea holds heat, so nights stay mild.", "It raises it."])
    }

    func testParsesTheCheckersVerdict() {
        XCTAssertEqual(KapitsaChatReview.parseCheck("Right. You got it.").0, .right)
        XCTAssertEqual(KapitsaChatReview.parseCheck("Right. You got it.").1, "You got it.")
        XCTAssertEqual(KapitsaChatReview.parseCheck("**Partly.** You missed the UV.").0, .partly)
        XCTAssertEqual(KapitsaChatReview.parseCheck("Not quite. It's the sea.").0, .notQuite)
        XCTAssertEqual(KapitsaChatReview.parseCheck("Hmm, hard to say.").0, .partly, "no verdict brings it up again")
    }

    func testReviewIntervalGrowsWhileEveryAnswerIsRight() {
        XCTAssertEqual(KapitsaChatReview.nextInterval(right: 5, total: 5, previous: nil), 3)
        XCTAssertEqual(KapitsaChatReview.nextInterval(right: 5, total: 5, previous: 3), 6)
        XCTAssertEqual(KapitsaChatReview.nextInterval(right: 5, total: 5, previous: 1), 3)
        XCTAssertEqual(KapitsaChatReview.nextInterval(right: 5, total: 5, previous: 40), 60)
        XCTAssertEqual(KapitsaChatReview.nextInterval(right: 3, total: 5, previous: 12), 3)
        XCTAssertEqual(KapitsaChatReview.nextInterval(right: 1, total: 5, previous: 12), 1)
    }

    func testExcerptHasEveryQuestionTheTakeawayComesFrom() {
        let q1 = KapitsaChatMessage(role: .user, text: "Which is steadiest?"), q2 = KapitsaChatMessage(role: .user, text: "Beaches?")
        let messages = [q1, KapitsaChatMessage(role: .assistant, text: "Funchal is most stable."),
                        q2, KapitsaChatMessage(role: .assistant, text: "Tenerife has the best balance.")]
        let excerpt = KapitsaChatReview.excerpt(for: [q1.id, q2.id], in: messages)
        XCTAssertEqual(excerpt, """
        Question 1: Which is steadiest?
        Reply: Funchal is most stable.

        Question 2: Beaches?
        Reply: Tenerife has the best balance.
        """)
    }

    func testQuizAsksPinnedTakeawaysFirst() {
        let takeaways = (1...7).map { KapitsaChatReview.Takeaway(text: "T\($0)", pinned: $0 == 6 ? true : nil) }
        XCTAssertEqual(KapitsaChatReview.quizTakeaways(takeaways, shuffle: { $0 }).map(\.text), ["T6", "T1", "T2", "T3", "T4"])
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

    func testQuizChecksAnswersPinsMissesAndSchedulesTheNextReview() async throws {
        let file = temporaryFile()
        let chat = controller([KapitsaChatMessage(role: .user, text: "Q1"), KapitsaChatMessage(role: .assistant, text: "A1")],
                              file: file) { instructions, text in
            if instructions.hasPrefix("From this conversation") { return "- First [Q1]\n- Second [Q1]" }
            if instructions.hasPrefix("Write one practice") {
                return "Question 1: Why first?\nAnswer 1: Because.\nQuestion 2: Why second?\nAnswer 2: Also because."
            }
            return text.contains("Their answer: good") ? "Right. Well done." : "Not quite. It was because."
        }
        chat.writeTakeaways(connection: connection, contextTokens: nil, update: false)
        try await waitForReviewWork(chat)
        chat.startQuiz(connection: connection)
        try await waitForReviewWork(chat)
        let quiz = try XCTUnwrap(chat.quiz)
        XCTAssertEqual(quiz.questions.count, 2)

        chat.checkAnswer("good", connection: connection)
        try await waitForReviewWork(chat)
        XCTAssertEqual(chat.quiz?.questions[0].verdict, .right)
        XCTAssertEqual(chat.quiz?.questions[0].feedback, "Well done.")
        XCTAssertNil(chat.review.lastQuiz, "nothing is saved until every question is answered")

        chat.showQuestion(1)
        chat.revealAnswer()
        chat.markRevealed(knewIt: false)
        XCTAssertEqual(chat.quiz?.isFinished, true)
        let missed = try XCTUnwrap(chat.review.takeaways.first { $0.id == quiz.questions[1].takeawayID })
        XCTAssertEqual(missed.pinned, true)
        XCTAssertEqual(chat.review.lastQuiz?.right, 1)
        XCTAssertEqual(chat.review.lastQuiz?.intervalDays, 3)
        XCTAssertNotNil(chat.review.reviewDue)
        XCTAssertEqual(KapitsaChatStore(url: file).loadDocument().review?.lastQuiz, chat.review.lastQuiz)
        XCTAssertTrue(KapitsaChatReview.checkInstructions.contains("never comment on it"))
        let summary = KapitsaChatLibrary.summary(id: UUID(), document: KapitsaChatStore(url: file).loadDocument(), fileDate: Date())
        XCTAssertEqual(summary?.reviewDue, chat.review.reviewDue)
        XCTAssertEqual(summary?.isReviewDue(), false)
    }

    func testQuizWrittenAheadOpensAtOnceUntilTheTakeawaysChange() async throws {
        let file = temporaryFile()
        let counter = Counter()
        let chat = controller([KapitsaChatMessage(role: .user, text: "Q1"), KapitsaChatMessage(role: .assistant, text: "A1")],
                              file: file) { instructions, _ in
            if instructions.hasPrefix("From this conversation") { return "- First [Q1]" }
            counter.increment()
            return "Question 1: Why?\nAnswer 1: Because."
        }
        chat.writeTakeaways(connection: connection, contextTokens: nil, update: false)
        try await waitForReviewWork(chat)
        chat.prepareQuiz(connection: connection)
        chat.prepareQuiz(connection: connection)
        chat.startQuiz(connection: connection)
        XCTAssertEqual(chat.reviewWork, .quiz, "waits for the quiz being written ahead")
        try await waitForReviewWork(chat)
        XCTAssertEqual(chat.quiz?.questions.count, 1)
        XCTAssertEqual(counter.value, 1, "asked once")

        chat.closeQuiz()
        chat.prepareQuiz(connection: connection)
        for _ in 0..<200 where counter.value < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        chat.startQuiz(connection: connection)
        XCTAssertNotNil(chat.quiz, "opens at once")
        chat.closeQuiz()

        chat.addTakeaway("Mine")
        chat.startQuiz(connection: connection)
        XCTAssertNil(chat.quiz, "an edit means a new quiz is written")
        try await waitForReviewWork(chat)
        XCTAssertEqual(counter.value, 3)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
