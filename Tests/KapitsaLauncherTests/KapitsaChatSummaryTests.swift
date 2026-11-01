import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaChatSummaryTests: XCTestCase {
    private let connection = KapitsaChatConnection(baseURL: URL(string: "http://127.0.0.1:8000/")!, apiKey: nil, model: "qwen")
    private let utc = TimeZone(identifier: "UTC")!
    private let sent = Date(timeIntervalSince1970: 1_792_684_800)

    private func conversation() -> [KapitsaChatMessage] {
        let image = KapitsaChatAttachment(name: "map.png", kind: .image, imageData: Data([0xFF]), imageMIMEType: "image/jpeg")
        return [
            KapitsaChatMessage(role: .user, text: "Where is it warm?", attachments: [image]),
            KapitsaChatMessage(role: .assistant, text: "Funchal.", reasoning: "Secret reasoning",
                               stats: .init(outputTokens: 50, promptTokens: 1_000)),
            KapitsaChatMessage(role: .user, text: "Thanks"),
            KapitsaChatMessage(role: .assistant, text: ""),
        ]
    }

    private static func reply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
    }

    func testTranscriptLeavesOutReasoningAndNamesAttachments() {
        XCTAssertEqual(KapitsaChatSummary.transcript(conversation()), [
            "Question 1:\n[Attached image: map.png]\nWhere is it warm?",
            "Reply 1:\nFunchal.",
            "Question 2:\nThanks",
        ])
    }

    func testSectionsFitTheBudgetAndCutOversizedTurns() {
        let turns = [String(repeating: "a", count: 40), String(repeating: "b", count: 40), String(repeating: "c", count: 400)]
        let sections = KapitsaChatSummary.sections(turns, budget: 15)
        guard sections.count == 3 else { return XCTFail("\(sections.count) sections") }
        XCTAssertEqual(sections[0], turns[0])
        XCTAssertTrue(sections[2].hasSuffix("[…cut]"))
        XCTAssertEqual(KapitsaChatSummary.sections(turns, budget: 1_000).count, 1)
        XCTAssertEqual(KapitsaChatSummary.sectionBudget(contextTokens: 32_768), 19_660)
        XCTAssertEqual(KapitsaChatSummary.sectionBudget(contextTokens: 100), 2_000)
    }

    func testRequestTurnsThinkingOffAndDoesNotStream() {
        let body = KapitsaChatSummary.requestBody(instructions: "Summarise", text: "Q", model: "qwen")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user"])
    }

    func testReplyTextDropsStrayThinkingAndReportsErrors() throws {
        XCTAssertEqual(try KapitsaChatSummary.replyText(from: Self.reply("<think>hmm</think>\n\nShort.")), "Short.")
        let error = try JSONSerialization.data(withJSONObject: ["error": ["message": "context too long"]])
        XCTAssertThrowsError(try KapitsaChatSummary.replyText(from: error)) {
            XCTAssertEqual($0 as? KapitsaChatSummary.Failure, .server("context too long"))
        }
        XCTAssertThrowsError(try KapitsaChatSummary.replyText(from: Self.reply("  ")))
    }

    func testShortChatIsOneRequest() async throws {
        let calls = Counter()
        let summary = try await KapitsaChatSummary.write(for: conversation(), connection: connection, contextTokens: 32_768) { request in
            await calls.add()
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let text = ((body["messages"] as! [[String: String]])[1])["content"]!
            XCTAssertFalse(text.contains("Secret reasoning"))
            return Self.reply("Warm places.")
        }
        XCTAssertEqual(summary, KapitsaChatSummary(text: "Warm places.", model: "qwen"))
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testLongChatIsSummarisedInPartsThenCombined() async throws {
        let long = (1...6).flatMap { index in [
            KapitsaChatMessage(role: .user, text: "Question \(index) " + String(repeating: "x", count: 4_000)),
            KapitsaChatMessage(role: .assistant, text: String(repeating: "y", count: 4_000)),
        ] }
        let calls = Counter()
        let summary = try await KapitsaChatSummary.write(for: long, connection: connection, contextTokens: 3_000) { request in
            let number = await calls.add()
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let instructions = ((body["messages"] as! [[String: String]])[0])["content"]!
            return Self.reply(instructions == KapitsaChatSummary.combineInstructions ? "Combined" : "Part \(number)")
        }
        XCTAssertEqual(summary.text, "Combined")
        let count = await calls.value
        XCTAssertGreaterThan(count, 2)
    }

    func testALongChatIsReadInSectionsEvenWhenTheContextWouldTakeItWhole() async throws {
        // About 30,000 tokens: one request under the old rule on a 131k model, three now.
        let long = (1...8).flatMap { index in [
            KapitsaChatMessage(role: .user, text: "Question \(index)"),
            KapitsaChatMessage(role: .assistant, text: String(repeating: "Lisbon rent. ", count: 1_150)),
        ] }
        let calls = Counter()
        let summary = try await KapitsaChatSummary.write(for: long, connection: connection, contextTokens: 131_072) { request in
            _ = await calls.add()
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let instructions = ((body["messages"] as! [[String: String]])[0])["content"]!
            return Self.reply(instructions == KapitsaChatSummary.combineInstructions ? "Combined" : "Part")
        }
        XCTAssertEqual(summary.text, "Combined")
        let count = await calls.value
        XCTAssertEqual(count, 4, "three sections, then one request to combine them")
    }

    func testOneFileHasTheSummaryThenTheConversation() throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("Warm.md")
        let summary = KapitsaChatSummary(text: "Funchal wins.", model: "qwen")
        let options = KapitsaChatExport.Options(includeSummary: true, includeConversation: true, includeThinking: false)
        let written = try KapitsaChatExport.write(conversation(), to: url, options: options, summary: summary,
                                                  exportedAt: sent, timeZone: utc)
        XCTAssertEqual(written, [url])
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Summary\n\n_Written by qwen from the questions and replies. It may miss or misstate details; the full conversation follows._\n\nFunchal wins.\n\n---\n\n## You"))
        XCTAssertFalse(markdown.contains("Secret reasoning"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Warm images/01-map.jpg").path))
    }

    func testSeparateFilesLinkTheSummaryToTheConversation() throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("Warm chat.md")
        let options = KapitsaChatExport.Options(includeSummary: true, includeConversation: true, separateFiles: true)
        let written = try KapitsaChatExport.write(conversation(), to: url, options: options,
                                                  summary: KapitsaChatSummary(text: "Funchal wins.", model: "qwen"))
        let summaryURL = folder.appendingPathComponent("Warm chat – Summary.md")
        XCTAssertEqual(written, [url, summaryURL])
        let full = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(full.contains("## Summary"))
        XCTAssertTrue(full.contains("Secret reasoning"))
        let summary = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertTrue(summary.contains("the full conversation is in [Warm chat.md](Warm%20chat.md)._"))
        XCTAssertTrue(summary.contains("Funchal wins."))
        XCTAssertFalse(summary.contains("## You"))
        XCTAssertFalse(summary.contains("!["))
    }

    func testASeparateSummaryKeepsAnUnrelatedFileOfItsNameButReplacesItsOwn() throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("Warm chat.md")
        let mine = folder.appendingPathComponent("Warm chat – Summary.md")
        try "My own notes".write(to: mine, atomically: true, encoding: .utf8)
        let options = KapitsaChatExport.Options(includeSummary: true, includeConversation: true, separateFiles: true)
        let summary = KapitsaChatSummary(text: "Funchal wins.", model: "qwen")

        let written = try KapitsaChatExport.write(conversation(), to: url, options: options, summary: summary)
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "My own notes")
        XCTAssertEqual(written.last, folder.appendingPathComponent("Warm chat – Summary 2.md"))

        // Exporting again over that export: the save panel confirmed replacing it, summary and all.
        try FileManager.default.removeItem(at: written.last!)
        let again = try KapitsaChatExport.write(conversation(), to: url, options: options, summary: summary)
        XCTAssertEqual(again.last, mine)
    }

    func testSummaryOnlyIsOneFileWithoutTheConversation() throws {
        let url = try temporaryFolder().appendingPathComponent("Only.md")
        let options = KapitsaChatExport.Options(includeSummary: true, includeConversation: false, separateFiles: true)
        let written = try KapitsaChatExport.write(conversation(), to: url, options: options,
                                                  summary: KapitsaChatSummary(text: "Funchal wins.", model: "qwen"))
        XCTAssertEqual(written, [url])
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("It may miss or misstate details._"))
        XCTAssertFalse(markdown.contains("## You"))
    }

    func testConversationTokensStartFromTheLatestReportedPrompt() {
        let messages = conversation()
        // 1,000 read for the first reply, plus "Funchal." (2), "Thanks" (2) and the empty reply (0).
        XCTAssertEqual(KapitsaChatOutline.conversationTokens(in: messages), 1_004)
        XCTAssertNil(KapitsaChatOutline.conversationTokens(in: [KapitsaChatMessage(role: .user, text: "Hi")]))
    }

    func testDeletingAnEarlierTurnLowersTheCount() {
        let early = [KapitsaChatMessage(role: .user, text: String(repeating: "a", count: 400)),
                     KapitsaChatMessage(role: .assistant, text: String(repeating: "b", count: 400))]
        var reply = KapitsaChatMessage(role: .assistant, text: "Done")
        // Sent with the early turn (200) and the question (1): 1,000 tokens read in all.
        reply.stats = .init(promptTokens: 1_000, historyTokens: 201)
        let question = KapitsaChatMessage(role: .user, text: "Q?")
        XCTAssertEqual(KapitsaChatOutline.conversationTokens(in: early + [question, reply]), 1_001)
        XCTAssertEqual(KapitsaChatOutline.conversationTokens(in: [question, reply]), 801)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult func add() -> Int { value += 1; return value }
}
