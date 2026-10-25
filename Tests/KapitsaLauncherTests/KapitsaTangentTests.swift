import XCTest
@testable import KapitsaLauncher

@MainActor
final class KapitsaTangentTests: XCTestCase {
    private let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: nil, model: "m")

    private func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "KapitsaTangentTests")!
        defaults.removePersistentDomain(forName: "KapitsaTangentTests")
        return defaults
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/chat.json")
    }

    /// A chat of two turns whose streams answer "Side answer", recording what each request sent.
    private func chat(file: URL, sent: SentRequests) -> KapitsaChatController {
        let store = KapitsaChatStore(url: file)
        store.save([KapitsaChatMessage(role: .user, text: "Q1"), KapitsaChatMessage(role: .assistant, text: "A1"),
                    KapitsaChatMessage(role: .user, text: "Q2"), KapitsaChatMessage(role: .assistant, text: "A2")])
        return KapitsaChatController(store: store, defaults: defaults(), send: { _ in throw URLError(.cannotConnectToHost) },
                                     streamLines: { request in
            sent.append(request)
            return AsyncThrowingStream { continuation in
                continuation.yield(#"data: {"choices":[{"delta":{"content":"Side answer"}}]}"#)
                continuation.yield("data: [DONE]")
                continuation.finish()
            }
        })
    }

    private func waitUntilIdle(_ chat: KapitsaChatController) async {
        for _ in 0..<200 where chat.isStreaming { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testSideQuestionReadsTheChatUpToItsReplyAndStaysOutOfTheConversation() async throws {
        let file = temporaryFile()
        let sent = SentRequests()
        let chat = chat(file: file, sent: sent)
        let firstReply = chat.messages[1].id
        chat.askTangent(about: firstReply, text: "What's A1?", connection: connection)
        XCTAssertTrue(chat.isStreaming, "the main chat waits while a side question is answered")
        XCTAssertFalse(chat.canSend)
        await waitUntilIdle(chat)

        XCTAssertEqual(sent.contents.last, ["Q1", "A1", KapitsaTangent.marker + "\n\nWhat's A1?"],
                       "the conversation up to that reply, then the side question; not Q2 or A2")
        let tangent = try XCTUnwrap(chat.messages[1].tangents?.first)
        XCTAssertEqual(tangent.messages.map(\.text), ["What's A1?", "Side answer"], "the marker is only sent, not kept")
        XCTAssertEqual(chat.messages.count, 4)

        // A follow-up carries the thread; the next main message doesn't.
        chat.askTangent(about: firstReply, in: tangent.id, text: "And then?", connection: connection)
        await waitUntilIdle(chat)
        XCTAssertEqual(sent.contents.last, ["Q1", "A1", KapitsaTangent.marker + "\n\nWhat's A1?", "Side answer", "And then?"])
        chat.draft = "Q3"
        chat.send(to: connection)
        await waitUntilIdle(chat)
        XCTAssertEqual(sent.contents.last, ["Q1", "A1", "Q2", "A2", "Q3"])
        XCTAssertEqual(KapitsaChatStore(url: file).load()[1].tangents?.first?.messages.count, 4, "saved with the chat")
    }

    func testFoldingAndDeletingASideQuestion() async throws {
        let chat = chat(file: temporaryFile(), sent: SentRequests())
        let reply = chat.messages[3].id
        chat.askTangent(about: reply, text: "Why?", connection: connection)
        await waitUntilIdle(chat)
        let id = try XCTUnwrap(chat.messages[3].tangents?.first?.id)
        chat.setTangentCollapsed(id, on: reply, true)
        XCTAssertEqual(chat.messages[3].tangents?.first?.isCollapsed, true)
        chat.deleteTangent(id, on: reply)
        XCTAssertNil(chat.messages[3].tangents)
    }

    func testLinksToDeletedChatsAreForgotten() async throws {
        let file = temporaryFile()
        let chat = chat(file: file, sent: SentRequests())
        let reply = chat.messages[1].id
        chat.askTangent(about: reply, text: "Why?", connection: connection)
        await waitUntilIdle(chat)
        let tangent = try XCTUnwrap(chat.messages[1].tangents?.first?.id)
        let kept = UUID(), deleted = UUID()
        chat.markTangentContinued(tangent, on: reply, in: deleted)
        chat.markContinued(in: kept)
        chat.forgetMissingChats { $0 == kept }
        XCTAssertEqual(chat.continuedIn, kept)
        XCTAssertNil(chat.messages[1].tangents?.first?.continuedIn, "the side question can be continued again")
        chat.forgetMissingChats { _ in false }
        XCTAssertNil(chat.continuedIn)
        XCTAssertNil(KapitsaChatStore(url: file).loadDocument().continuedIn)
    }

    func testFoldAllFoldsEverySideQuestion() async throws {
        let chat = chat(file: temporaryFile(), sent: SentRequests())
        chat.askTangent(about: chat.messages[1].id, text: "One?", connection: connection)
        await waitUntilIdle(chat)
        chat.askTangent(about: chat.messages[3].id, text: "Two?", connection: connection)
        await waitUntilIdle(chat)
        chat.setAllTangentsCollapsed(true)
        XCTAssertEqual(chat.messages.compactMap { $0.tangents?.first?.isCollapsed }, [true, true])
        chat.setAllTangentsCollapsed(false)
        XCTAssertEqual(chat.messages.compactMap { $0.tangents?.first }.compactMap(\.isCollapsed), [])
    }

    func testExportsPutSideQuestionsUnderTheirReplyAsQuotes() {
        var reply = KapitsaChatMessage(role: .assistant, text: "A1")
        reply.tangents = [KapitsaTangent(messages: [KapitsaChatMessage(role: .user, text: "What's A1?"),
                                                    KapitsaChatMessage(role: .assistant, text: "Line one.\n\nLine two.")])]
        let messages = [KapitsaChatMessage(role: .user, text: "Q1"), reply]
        let markdown = KapitsaChatExport(messages: messages).markdown
        XCTAssertTrue(markdown.contains("""
        A1

        > **Side question**
        >
        > **You:** What's A1?
        >
        > Line one.
        >
        > Line two.
        """), markdown)
        XCTAssertFalse(KapitsaChatExport(messages: messages, includeSideQuestions: false).markdown.contains("Side question"))

        let single = KapitsaChatExport.sideQuestion(reply.tangents![0], chatName: "Warm places", about: "Q1",
                                                    exportedAt: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        XCTAssertTrue(single.hasPrefix("# Side question: What's A1?\n\n_From “Warm places”, about the reply to “Q1”."), single)
        XCTAssertTrue(single.hasSuffix("**You:** What's A1?\n\nLine one.\n\nLine two.\n"), single)
    }

    func testBranchStartsFromTheSummaryWithTheThreadAsItsFirstMessages() throws {
        let thread = [KapitsaChatMessage(role: .user, text: "What's A1?"), KapitsaChatMessage(role: .assistant, text: "Side answer")]
        let file = temporaryFile()
        let branch = KapitsaChatController(store: KapitsaChatStore(url: file), defaults: defaults(),
                                           streamLines: { _ in AsyncThrowingStream { $0.finish() } })
        let old = UUID()
        branch.startBranch(KapitsaChatContinuation(chatID: old, name: "Warm places", summary: "We compared towns.", isBranch: true),
                           messages: thread)
        XCTAssertEqual(branch.messages.map(\.text), ["What's A1?", "Side answer"])
        XCTAssertNotEqual(branch.messages.first?.id, thread.first?.id, "copies get their own IDs")
        let body = KapitsaChatRequest.body(history: branch.messages, thinking: .off, model: "m", continuing: branch.continuesFrom)
        let first = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["content"] as? String, KapitsaChatContinuation.branchInstructions + "\n\nWe compared towns.")

        let summary = KapitsaChatLibrary.summary(id: UUID(), document: KapitsaChatStore(url: file).loadDocument(), fileDate: Date())
        XCTAssertNil(summary?.continues, "a branch is named by its own first question")
        XCTAssertEqual(summary?.name(.title), "What's A1?")
    }
}

/// The requests a test's streams were asked for, and the text of each one's messages.
private final class SentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }

    var contents: [[String]] {
        lock.withLock { requests }.map { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return (body["messages"] as! [[String: Any]]).compactMap { $0["content"] as? String }
        }
    }
}
