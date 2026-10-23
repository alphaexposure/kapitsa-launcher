import XCTest
@testable import KapitsaLauncher

final class KapitsaChatMarkdownTests: XCTestCase {
    private typealias Block = KapitsaChatMarkdown.Block

    func testHeadingsParagraphsAndRules() {
        let text = """
        # Title
        Some **bold** text
        on two lines.

        ### Closed heading ###
        ####### Not a heading
        #hashtag
        ## C#
        ---
        * * *
        """
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: text), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\non two lines."),
            .heading(level: 3, text: "Closed heading"),
            .paragraph("####### Not a heading\n#hashtag"),
            .heading(level: 2, text: "C#"),
            .rule,
            .rule,
        ])
    }

    func testNestedLists() {
        let text = """
        1. First
           - inner a
           - inner b
             - deepest
        2. Second
          - nested by two spaces
        3. Third

        - Bullet
        - Another
        """
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: text), [
            .list(.init(isOrdered: true, start: 1, items: [
                [.paragraph("First"), .list(.init(isOrdered: false, start: 1, items: [
                    [.paragraph("inner a")],
                    [.paragraph("inner b"), .list(.init(isOrdered: false, start: 1, items: [[.paragraph("deepest")]]))],
                ]))],
                [.paragraph("Second"), .list(.init(isOrdered: false, start: 1, items: [[.paragraph("nested by two spaces")]]))],
                [.paragraph("Third")],
            ])),
            .list(.init(isOrdered: false, start: 1, items: [[.paragraph("Bullet")], [.paragraph("Another")]])),
        ])
    }

    func testLooseListKeepsItsParagraphsAndStartNumber() {
        let text = """
        3. **Step**

           Details here.

        4. Next
        After the list.
        """
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: text), [
            .list(.init(isOrdered: true, start: 3, items: [
                [.paragraph("**Step**"), .paragraph("Details here.")],
                [.paragraph("Next\nAfter the list.")],
            ])),
        ])
    }

    func testQuotes() {
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: "> Quoted\n> - item\n\nAfter"), [
            .quote([.paragraph("Quoted"), .list(.init(isOrdered: false, start: 1, items: [[.paragraph("item")]]))]),
            .paragraph("After"),
        ])
    }

    func testTableWithAlignmentAndRaggedRows() {
        let text = """
        Intro
        | Name | Mass | Note |
        |:-----|-----:|:----:|
        | Helium | 4.0 | `a|b` |
        | Neon | 20.2 |
        | Argon | 39.9 | noble | extra |
        Escaped \\| pipe | row
        """
        guard case let .table(table) = KapitsaChatMarkdown.blocks(in: text)[1] else { return XCTFail("No table") }
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: text)[0], .paragraph("Intro"))
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center, .leading])
        XCTAssertEqual(table.header, ["Name", "Mass", "Note", ""])
        XCTAssertEqual(table.rows, [
            ["Helium", "4.0", "`a|b`", ""],
            ["Neon", "20.2", "", ""],
            ["Argon", "39.9", "noble", "extra"],
            ["Escaped | pipe", "row", "", ""],
        ])
    }

    func testCodeFences() {
        let text = """
        ```swift
        let x = 1
            indented()

        # not a heading
        ```
        ~~~
        tilde ``` inside
        ~~~
        """
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: text), [
            .code(language: "swift", code: "let x = 1\n    indented()\n\n# not a heading"),
            .code(language: "", code: "tilde ``` inside"),
        ])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: "Here:\n```python\nprint(1)\n| a | b |"), [
            .paragraph("Here:"),
            .code(language: "python", code: "print(1)\n| a | b |"),
        ])
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: "```"), [.code(language: "", code: "")])
    }

    /// A reply is parsed again on every streaming update; each prefix must parse sensibly.
    func testHalfTypedTableWhileStreaming() {
        let full = "## Gases\n| Gas | Boils |\n|---|--:|\n| He | 4.2 K |\n| Ne | 27"
        for end in full.indices {
            _ = KapitsaChatMarkdown.blocks(in: String(full[..<end]))
        }
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: "| Gas | Boils |"), [.paragraph("| Gas | Boils |")])
        for partial in ["| Gas | Boils |\n|", "| Gas | Boils |\n|--", "| Gas | Boils |\n|---|-"] {
            guard case let .table(table) = KapitsaChatMarkdown.blocks(in: partial).first else {
                return XCTFail("No table for \(partial)")
            }
            XCTAssertEqual(table.header, ["Gas", "Boils"])
            XCTAssertEqual(table.rows, [])
        }
        guard case let .table(table) = KapitsaChatMarkdown.blocks(in: full).last else { return XCTFail("No table") }
        XCTAssertEqual(table.alignments, [.leading, .trailing])
        XCTAssertEqual(table.rows, [["He", "4.2 K"], ["Ne", "27"]])
    }

    func testPipeTextWithoutAlignmentRowStaysAParagraph() {
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: "a | b\nc | d\n\nmore"), [
            .paragraph("a | b\nc | d"),
            .paragraph("more"),
        ])
    }

    func testTabsAndWindowsLineEndings() {
        XCTAssertEqual(KapitsaChatMarkdown.blocks(in: "- a\r\n\t- b\r\n"), [
            .list(.init(isOrdered: false, start: 1, items: [
                [.paragraph("a"), .list(.init(isOrdered: false, start: 1, items: [[.paragraph("b")]]))],
            ])),
        ])
    }
}
