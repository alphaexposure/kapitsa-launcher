import AppKit
import PDFKit
import XCTest
@testable import KapitsaLauncher

final class KapitsaChatRequestTests: XCTestCase {
    func testThinkingLevelsSelectTheRequestFields() {
        let off = KapitsaThinkingLevel.off.requestFields
        XCTAssertEqual((off["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertNil(off["reasoning_effort"])
        for level in [KapitsaThinkingLevel.low, .medium, .xhigh] {
            XCTAssertEqual((level.requestFields["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
            XCTAssertEqual(level.requestFields["reasoning_effort"] as? String, level.rawValue)
        }
    }

    func testBodyStreamsHistoryWithoutEarlierReasoning() throws {
        let history = [
            KapitsaChatMessage(role: .user, text: "Hi"),
            KapitsaChatMessage(role: .assistant, text: "Hello", reasoning: "greet back"),
            KapitsaChatMessage(role: .user, text: "Again"),
        ]
        let body = KapitsaChatRequest.body(history: history, thinking: .medium, model: "qwen3.8-27b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "qwen3.8-27b")
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"] as? String, "Hello")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testImagesBecomeDataURLPartsAndDocumentsBecomeText() throws {
        let image = KapitsaChatAttachment(name: "a.jpg", kind: .image, imageData: Data([1, 2, 3]), imageMIMEType: "image/jpeg")
        let document = KapitsaChatAttachment(name: "notes.txt", kind: .document, text: "Line one", truncated: true)
        let message = KapitsaChatMessage(role: .user, text: "Summarise", attachments: [image, document])
        let parts = try XCTUnwrap(KapitsaChatRequest.content(for: message) as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual((parts[0]["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,AQID")
        XCTAssertEqual(parts[1]["text"] as? String,
                       "<document name=\"notes.txt\" truncated=\"true\">\nLine one\n</document>\n\nSummarise")
        let textOnly = KapitsaChatMessage(role: .user, text: "Read this", attachments: [document])
        XCTAssertTrue((KapitsaChatRequest.content(for: textOnly) as? String)?.hasSuffix("Read this") == true)
    }

    func testRequestCarriesKeyOnlyInTheHeader() throws {
        let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: "secret", model: "m")
        let request = try KapitsaChatRequest.urlRequest(connection: connection, body: ["stream": true])
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8000/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertFalse(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("secret"))
    }

    func testParsesStreamEvents() {
        XCTAssertEqual(KapitsaChatEvent.parse(line: #"data: {"choices":[{"delta":{"reasoning_content":"Hmm"}}]}"#), [.reasoning("Hmm")])
        XCTAssertEqual(KapitsaChatEvent.parse(line: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#), [.content("Hi")])
        XCTAssertEqual(KapitsaChatEvent.parse(line: #"data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":9}}"#),
                       [.usage(promptTokens: 5, outputTokens: 9)])
        XCTAssertEqual(KapitsaChatEvent.parse(line: #"data: {"error":{"message":"too long"}}"#), [.failure("too long")])
        XCTAssertEqual(KapitsaChatEvent.parse(line: "data: [DONE]"), [.done])
        XCTAssertNil(KapitsaChatEvent.parse(line: ": keep-alive"))
    }
}

@MainActor
final class KapitsaChatControllerTests: XCTestCase {
    private let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: nil, model: "m")

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "KapitsaChatControllerTests")!
        defaults.removePersistentDomain(forName: "KapitsaChatControllerTests")
        return defaults
    }

    private func lines(_ lines: [String]) -> KapitsaChatController.LineStreamer {
        { _ in AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        } }
    }

    /// Topic requests fail, as if Kapitsa weren't there; the chat carries on without them.
    private let noTopics: KapitsaChatSummary.Send = { _ in throw URLError(.cannotConnectToHost) }

    nonisolated private static func topicsReply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
    }

    private func waitUntilIdle(_ chat: KapitsaChatController) async {
        for _ in 0..<200 where chat.isStreaming { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testDeletingATurnRemovesTheQuestionAndReplyAndSaves() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/chat.json")
        let store = KapitsaChatStore(url: file)
        let conversation = [
            KapitsaChatMessage(role: .user, text: "One"), KapitsaChatMessage(role: .assistant, text: "1"),
            KapitsaChatMessage(role: .user, text: "Two"), KapitsaChatMessage(role: .assistant, text: "2"),
        ]
        store.save(conversation)
        let chat = KapitsaChatController(store: store, defaults: makeDefaults(), streamLines: lines([]))
        chat.deleteTurn(endingWith: conversation[1].id)
        XCTAssertEqual(chat.messages.map(\.text), ["Two", "2"])
        XCTAssertEqual(store.load(), chat.messages)
        chat.deleteTurn(endingWith: UUID())
        XCTAssertEqual(chat.messages.count, 2)
    }

    func testStreamsReasoningThenAnswerAndSavesTheConversation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/chat.json")
        // Readings: question and reply sent, first reasoning, first answer token, finished.
        var times = [0.0, 0.0, 0.0, 1.0, 3.0].makeIterator()
        let chat = KapitsaChatController(
            store: KapitsaChatStore(url: file), defaults: makeDefaults(),
            send: { _ in Self.topicsReply("- Prime numbers\n2. Factoring") },
            streamLines: lines([
                #"data: {"choices":[{"delta":{"reasoning_content":"Let me see. "}}]}"#,
                #"data: {"choices":[{"delta":{"content":"No, "}}]}"#,
                #"data: {"choices":[{"delta":{"content":"17 × 23."}}]}"#,
                #"data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":40}}"#,
                "data: [DONE]",
            ]),
            now: { Date(timeIntervalSince1970: times.next() ?? 5) })
        chat.thinking = .low
        chat.draft = "Is 391 prime?"
        chat.send(to: connection)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(chat.draft, "")
        await waitUntilIdle(chat)

        let reply = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertEqual(reply.reasoning, "Let me see. ")
        XCTAssertEqual(reply.text, "No, 17 × 23.")
        XCTAssertEqual(reply.thinking, .low)
        XCTAssertEqual(reply.stats?.outputTokens, 40)
        XCTAssertEqual(reply.stats?.thinkingSeconds, 1)
        XCTAssertEqual(reply.stats?.generationSeconds, 3)
        // Topics follow in the background, then the chat is saved again.
        for _ in 0..<200 where chat.messages.last?.topics == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(chat.messages.last?.topics, ["Prime numbers", "Factoring"])
        XCTAssertEqual(KapitsaChatStore(url: file).load(), chat.messages)
    }

    func testEditingAQuestionKeepsTheEarlierVersionToSwitchBackTo() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/chat.json")
        let store = KapitsaChatStore(url: file)
        let first = KapitsaChatMessage(role: .user, text: "One")
        let second = KapitsaChatMessage(role: .user, text: "Two")
        store.save([first, KapitsaChatMessage(role: .assistant, text: "1"), second, KapitsaChatMessage(role: .assistant, text: "2")])
        let chat = KapitsaChatController(store: store, defaults: makeDefaults(), send: { _ in throw URLError(.cancelled) },
                                         streamLines: lines([#"data: {"choices":[{"delta":{"content":"New"}}]}"#, "data: [DONE]"]))

        // Editing the first question replaces everything from it on with a new version.
        chat.resend(first.id, text: "  One, edited ", connection: connection)
        await waitUntilIdle(chat)
        XCTAssertEqual(chat.messages.map(\.text), ["One, edited", "New"])
        XCTAssertEqual(chat.messages[0].versionCount, 2)
        XCTAssertEqual(chat.messages[0].versionIndex, 1)

        // Regenerating adds a third; the earlier versions keep what followed them.
        chat.resend(chat.messages[0].id, text: chat.messages[0].text, connection: connection)
        await waitUntilIdle(chat)
        XCTAssertEqual(chat.messages[0].versionCount, 3)
        chat.showVersion(0, of: chat.messages[0].id)
        XCTAssertEqual(chat.messages.map(\.text), ["One", "1", "Two", "2"])
        XCTAssertEqual(chat.messages[0].versionIndex, 0)
        XCTAssertEqual(store.load(), chat.messages, "the shown version and the others are saved")

        chat.showVersion(2, of: chat.messages[0].id)
        XCTAssertEqual(chat.messages.map(\.text), ["One, edited", "New"])
        // Only the shown version is sent to the model.
        let body = KapitsaChatRequest.body(history: chat.messages, thinking: .off, model: "m")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 2)
    }

    func testServerErrorIsShownOnTheReply() async throws {
        let chat = KapitsaChatController(store: nil, defaults: makeDefaults(), send: noTopics,
                                         streamLines: { _ in throw KapitsaChatError.httpStatus(401, "unauthorized") })
        chat.draft = "Hi"
        chat.send(to: connection)
        await waitUntilIdle(chat)
        XCTAssertEqual(chat.messages.last?.errorMessage, "Kapitsa answered HTTP 401: unauthorized")
    }

    func testStopMarksTheReplyStopped() async throws {
        let chat = KapitsaChatController(store: nil, defaults: makeDefaults(), send: noTopics, streamLines: { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(#"data: {"choices":[{"delta":{"content":"Partial"}}]}"#)
                // Never finishes on its own, like a long reply.
            }
        })
        chat.draft = "Write a novel"
        chat.send(to: connection)
        try await Task.sleep(for: .milliseconds(50))
        chat.stop()
        await waitUntilIdle(chat)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.messages.last?.wasStopped, true)
    }

    func testQuickTokensReachTheScreenInOneUpdate() async {
        let tokens = (0..<500).map { _ in #"data: {"choices":[{"delta":{"content":"t"}}]}"# } + ["data: [DONE]"]
        var updates: [KapitsaChatController.Batch] = []
        let outcome = await KapitsaChatController.consume(
            request: URLRequest(url: URL(string: "http://127.0.0.1:8000/")!), streamLines: lines(tokens), now: Date.init
        ) { updates.append($0) }
        XCTAssertEqual(updates.count, 1, "500 tokens arriving within 100 ms are drawn once")
        XCTAssertEqual(updates.first?.content.count, 500)
        XCTAssertFalse(outcome.wasStopped)
    }

    func testThinkingLevelIsRememberedAndSendNeedsContent() {
        let defaults = makeDefaults()
        let chat = KapitsaChatController(store: nil, defaults: defaults, streamLines: lines([]))
        XCTAssertEqual(chat.thinking, .xhigh)
        chat.thinking = .off
        XCTAssertEqual(KapitsaChatController(store: nil, defaults: defaults, streamLines: lines([])).thinking, .off)
        XCTAssertFalse(chat.canSend)
        chat.draft = "   "
        XCTAssertFalse(chat.canSend)
        chat.addAttachments([KapitsaChatAttachment(name: "x.txt", kind: .document, text: "x")])
        XCTAssertTrue(chat.canSend)
    }
}

final class KapitsaAttachmentLoaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testLoadsPlainTextAndMarkdown() throws {
        let url = folder.appendingPathComponent("notes.md")
        try "# Title\nBody".write(to: url, atomically: true, encoding: .utf8)
        let attachment = try KapitsaAttachmentLoader.load(url)
        XCTAssertEqual(attachment.kind, .document)
        XCTAssertEqual(attachment.text, "# Title\nBody")
    }

    func testLoadsWordAndRTFText() throws {
        let text = NSAttributedString(string: "Quarterly report")
        for (name, type) in [("r.docx", NSAttributedString.DocumentType.officeOpenXML), ("r.rtf", .rtf)] {
            let url = folder.appendingPathComponent(name)
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            try data.write(to: url)
            XCTAssertEqual(try KapitsaAttachmentLoader.load(url).text, "Quarterly report", name)
        }
    }

    func testLoadsPDFText() throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = "Superfluid helium"
        let url = folder.appendingPathComponent("doc.pdf")
        try view.dataWithPDF(inside: view.bounds).write(to: url)
        XCTAssertEqual(try KapitsaAttachmentLoader.load(url).text?.contains("Superfluid helium"), true)
    }

    func testScalesLargeImagesToJPEG() throws {
        let image = NSImage(size: NSSize(width: 4096, height: 1024))
        image.lockFocus(); NSColor.systemIndigo.setFill(); NSRect(x: 0, y: 0, width: 4096, height: 1024).fill(); image.unlockFocus()
        let attachment = try KapitsaAttachmentLoader.imageAttachment(image, name: "wide.png")
        XCTAssertEqual(attachment.imageMIMEType, "image/jpeg")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(attachment.imageData)))
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), KapitsaAttachmentLoader.maxImageSide)
    }

    func testCutsLongDocumentsAndRejectsEmptyOrBinaryFiles() throws {
        let long = try KapitsaAttachmentLoader.documentAttachment(String(repeating: "a", count: 250_000), name: "big.txt")
        XCTAssertTrue(long.truncated)
        XCTAssertEqual(long.text?.count, KapitsaAttachmentLoader.maxDocumentCharacters)
        XCTAssertThrowsError(try KapitsaAttachmentLoader.documentAttachment("  \n", name: "empty.txt"))
        let binary = folder.appendingPathComponent("blob.zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE]).write(to: binary)
        XCTAssertThrowsError(try KapitsaAttachmentLoader.load(binary))
    }
}
