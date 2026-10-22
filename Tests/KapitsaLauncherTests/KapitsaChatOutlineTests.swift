import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaChatOutlineTests: XCTestCase {
    func testOneEntryPerQuestionWithItsReplyHeadings() {
        let image = KapitsaChatAttachment(name: "flask.png", kind: .image, imageData: Data([0xFF]), imageMIMEType: "image/jpeg")
        let messages = [
            KapitsaChatMessage(role: .user, text: "\n  Why is helium superfluid?\nPlease be brief."),
            KapitsaChatMessage(role: .assistant, text: "# Short answer\nBose statistics.\n## **Lambda point**\n2.17 K"),
            KapitsaChatMessage(role: .user, text: "", attachments: [image]),
            KapitsaChatMessage(role: .assistant, text: "A flask."),
            KapitsaChatMessage(role: .user, text: "Thanks"),
        ]
        let entries = KapitsaChatOutline.entries(from: messages)
        XCTAssertEqual(entries.map(\.number), [1, 2, 3])
        XCTAssertEqual(entries.map(\.question), ["Why is helium superfluid?", "flask.png", "Thanks"])
        XCTAssertEqual(entries.map(\.id), [messages[0].id, messages[2].id, messages[4].id])
        XCTAssertEqual(entries.map(\.replyID), [messages[1].id, messages[3].id, nil])
        XCTAssertEqual(entries[0].headings, ["Short answer", "Lambda point"])
        XCTAssertEqual(entries[1].attachmentCount, 1)
    }

    func testHeadingsSkipCodeBlocksAndDeepLevels() {
        let text = """
        ## Setup
        ```python
        # not a heading
        ```
        #### Too deep
        #hashtag
        ### `swift build` ###
        """
        XCTAssertEqual(KapitsaChatOutline.headings(in: text), ["Setup", "swift build"])
    }

    func testLongQuestionsAreShortened() {
        let long = String(repeating: "word ", count: 40)
        let question = KapitsaChatOutline.question(for: KapitsaChatMessage(role: .user, text: long))
        XCTAssertTrue(question.hasSuffix("…"))
        XCTAssertLessThanOrEqual(question.count, KapitsaChatOutline.questionLength + 1)
    }

    func testReplyWithoutQuestionGetsItsOwnEntry() {
        let reply = KapitsaChatMessage(role: .assistant, text: "Hello")
        let entries = KapitsaChatOutline.entries(from: [reply])
        XCTAssertEqual(entries.map(\.question), ["Reply"])
        XCTAssertEqual(entries.first?.replyID, reply.id)
    }
}
