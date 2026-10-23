import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaChatExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let sent = Date(timeIntervalSince1970: 1_792_684_800)   // 2026-10-22 16:00 UTC

    private func conversation() -> [KapitsaChatMessage] {
        let image = KapitsaChatAttachment(name: "flask (1).png", kind: .image, imageData: Data([0xFF, 0xD8]), imageMIMEType: "image/jpeg")
        let document = KapitsaChatAttachment(name: "lab-notes.docx", kind: .document, text: "BLUE FOUNTAIN 42", truncated: false)
        return [
            KapitsaChatMessage(role: .user, text: "What is in the picture?", attachments: [image, document], sentAt: sent),
            KapitsaChatMessage(role: .assistant, text: "| A | B |\n|---|---|\n| 1 | 2 |", reasoning: "Look closely.\n",
                               thinking: .medium, model: "qwen3.8-27b", sentAt: sent,
                               stats: .init(outputTokens: 288, thinkingSeconds: 11.6, generationSeconds: 13.5)),
            KapitsaChatMessage(role: .user, text: "Thanks", sentAt: sent),
            KapitsaChatMessage(role: .assistant, text: "You're welcome.", thinking: .off, model: "qwen3.8-27b", wasStopped: true),
        ]
    }

    func testWholeChatAsMarkdown() {
        let export = KapitsaChatExport(messages: conversation(), exportedAt: sent, timeZone: utc)
        XCTAssertEqual(export.markdown, """
        # What is in the picture?

        _Exported from Kapitsa Launcher on 2026-10-22 16:00_

        ## You · 2026-10-22 16:00

        ![flask (1).png](What%20is%20in%20the%20picture%20images/01-flask%20%281%29.jpg)

        - Attached document: `lab-notes.docx` (16 characters)

        What is in the picture?

        ## Kapitsa · qwen3.8-27b · Thinking: Medium · 2026-10-22 16:00

        <details><summary>Thought for 11.6 s</summary>

        Look closely.

        </details>

        | A | B |
        |---|---|
        | 1 | 2 |

        <sub>288 tokens · 21.3 tok/s</sub>

        ## You · 2026-10-22 16:00

        Thanks

        ## Kapitsa · qwen3.8-27b · Thinking: Off

        You're welcome.

        _Stopped before the reply finished._

        """)
        XCTAssertEqual(export.suggestedFileName, "What is in the picture.md")
        XCTAssertEqual(export.images.map(\.relativePath), ["What is in the picture images/01-flask (1).jpg"])
    }

    func testExcludingThinkingDropsTheReasoningOnly() {
        let export = KapitsaChatExport(messages: conversation(), includeThinking: false, exportedAt: sent, timeZone: utc)
        XCTAssertFalse(export.markdown.contains("<details>"))
        XCTAssertFalse(export.markdown.contains("Look closely."))
        XCTAssertTrue(export.markdown.contains("## Kapitsa · qwen3.8-27b · Thinking: Medium · 2026-10-22 16:00\n\n| A | B |"))
        XCTAssertTrue(export.markdown.contains("<sub>288 tokens · 21.3 tok/s</sub>"))
    }

    private func topicConversation() -> [KapitsaChatMessage] {
        [
            KapitsaChatMessage(role: .user, text: "Warm places?"),
            KapitsaChatMessage(role: .assistant, text: "Madeira.", topics: ["Funchal Madeira", "Sensitive skin"]),
            KapitsaChatMessage(role: .user, text: "Costs?"),
            KapitsaChatMessage(role: .assistant, text: "Cheaper.", topics: ["Cost of living", "Funchal Madeira"]),
        ]
    }

    func testTopicsGetALineUnderEachReplyAndAnIndexLinkingToQuestions() {
        let markdown = KapitsaChatExport(messages: topicConversation(), exportedAt: sent, timeZone: utc).markdown
        XCTAssertTrue(markdown.hasPrefix("# Warm places?"), "no tags unless asked for")
        XCTAssertTrue(markdown.contains("<a id=\"question-2\"></a>\n## You"))
        XCTAssertTrue(markdown.contains("Madeira.\n\n_Topics: Funchal Madeira · Sensitive skin_"))
        XCTAssertTrue(markdown.hasSuffix("""
        ## Topics

        - **Funchal Madeira**: Questions [1](#question-1), [2](#question-2)
        - **Cost of living**: Question [2](#question-2)
        - **Sensitive skin**: Question [1](#question-1)

        """))
    }

    func testTopicTagsGoInFrontMatterWithoutSpaces() {
        let markdown = KapitsaChatExport(messages: topicConversation(), includeTopicTags: true,
                                         exportedAt: sent, timeZone: utc).markdown
        XCTAssertTrue(markdown.hasPrefix("""
        ---
        tags:
          - Funchal-Madeira
          - Cost-of-living
          - Sensitive-skin
        ---

        # Warm places?
        """))
        XCTAssertEqual(KapitsaChatExport.tag("3BR rentals (Lisbon)"), "3BR-rentals-Lisbon")
    }

    func testPlacesAndThemesGroupTheIndexAndNestTheTags() {
        var messages = topicConversation()
        messages[1].places = ["Funchal"]
        let themes = ["funchal madeira": "Places to live", "cost of living": "Costs"]
        let markdown = KapitsaChatExport(messages: messages, includeTopicTags: true, topicThemes: themes,
                                         exportedAt: sent, timeZone: utc).markdown
        XCTAssertTrue(markdown.contains("Madeira.\n\n_Places: Funchal_\n\n_Topics: Funchal Madeira · Sensitive skin_"))
        XCTAssertTrue(markdown.hasPrefix("""
        ---
        tags:
          - Places/Funchal
          - Places-to-live
          - Costs
        ---
        """))
        XCTAssertTrue(markdown.hasSuffix("""
        ## Topics

        ### Places

        - **Funchal**: Question [1](#question-1)

        ### Places to live

        - **Funchal Madeira**: Questions [1](#question-1), [2](#question-2)

        ### Costs

        - **Cost of living**: Question [2](#question-2)

        ### Other

        - **Sensitive skin**: Question [1](#question-1)

        """))
    }

    func testASeparateSummaryLinksTopicsToTheFullConversation() {
        let markdown = KapitsaChatExport(messages: topicConversation(),
                                         summary: KapitsaChatSummary(text: "Short.", model: "m"),
                                         includeConversation: false, fullConversationFileName: "Warm chat.md").markdown
        XCTAssertTrue(markdown.contains("- **Funchal Madeira**: Questions [1](Warm%20chat.md#question-1), [2](Warm%20chat.md#question-2)"))
        XCTAssertFalse(markdown.contains("<a id="))
        let alone = KapitsaChatExport(messages: topicConversation(), summary: KapitsaChatSummary(text: "Short.", model: "m"),
                                      includeConversation: false).markdown
        XCTAssertTrue(alone.contains("- **Funchal Madeira**: Questions 1, 2"))
    }

    func testSingleTurnTakesTheQuestionAndItsReply() {
        let messages = conversation()
        let turn = KapitsaChatExport.turn(endingWith: messages[3].id, in: messages)
        XCTAssertEqual(turn.map(\.text), ["Thanks", "You're welcome."])
        let export = KapitsaChatExport(messages: turn, exportedAt: sent, timeZone: utc)
        XCTAssertTrue(export.markdown.hasPrefix("# Thanks\n"))
        XCTAssertTrue(export.images.isEmpty)
        XCTAssertEqual(KapitsaChatExport.turn(endingWith: UUID(), in: messages), [])
    }

    func testFileNamesAreSafeAndShort() {
        func name(_ text: String) -> String {
            KapitsaChatExport.fileName(for: [KapitsaChatMessage(role: .user, text: text)])
        }
        XCTAssertEqual(name("a/b: c?"), "a b  c.md")
        XCTAssertEqual(name(""), "Kapitsa chat.md")
        XCTAssertEqual(name("one two three four five six seven eight nine ten"), "one two three four five six seven eight.md")
        XCTAssertLessThanOrEqual(name(String(repeating: "x", count: 200)).count, 63)
    }

    func testWritesMarkdownAndImagesBesideIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("My chat.md")
        let export = KapitsaChatExport(messages: conversation(),
                                       imagesFolderName: KapitsaChatExport.imagesFolderName(forMarkdownNamed: url.lastPathComponent))
        try export.write(to: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("](My%20chat%20images/01-flask%20%281%29.jpg)"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("My chat images/01-flask (1).jpg")), Data([0xFF, 0xD8]))
    }
}
