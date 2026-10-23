import Foundation

/// Splits a reply into Markdown blocks (headings, paragraphs, lists, quotes, code, tables,
/// rules) for the chat to draw; the text inside a block keeps its inline Markdown. Lenient
/// where models are sloppy, and safe on half-written text, since a streaming reply is parsed
/// again on every update: an unclosed code fence runs to the end, and a table shows as soon
/// as its header and the start of its alignment row are in.
enum KapitsaChatMarkdown {
    indirect enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(List)
        case quote([Block])
        case code(language: String, code: String)
        case table(Table)
        case rule
    }

    struct List: Equatable {
        var isOrdered: Bool
        var start: Int
        var items: [[Block]]
    }

    struct Table: Equatable {
        enum Alignment: Equatable { case leading, center, trailing }
        var alignments: [Alignment]
        var header: [String]
        /// Every row has a cell for each column, padded when the model left some out.
        var rows: [[String]]

        /// The table as a GitHub pipe table, its columns padded to line up in plain text.
        var markdown: String {
            let escaped = ([header] + rows).map { $0.map { $0.replacingOccurrences(of: "|", with: "\\|") } }
            let widths = alignments.indices.map { column in
                max(3, escaped.map { $0[column].count }.max() ?? 0)
            }
            func line(_ cells: [String]) -> String {
                "| " + cells.enumerated().map { column, cell in
                    let padding = String(repeating: " ", count: widths[column] - cell.count)
                    return alignments[column] == .trailing ? padding + cell : cell + padding
                }.joined(separator: " | ") + " |"
            }
            let delimiter = "| " + alignments.enumerated().map { column, alignment in
                let dashes = widths[column]
                switch alignment {
                case .leading: return String(repeating: "-", count: dashes)
                case .center: return ":" + String(repeating: "-", count: dashes - 2) + ":"
                case .trailing: return String(repeating: "-", count: dashes - 1) + ":"
                }
            }.joined(separator: " | ") + " |"
            return ([line(escaped[0]), delimiter] + escaped.dropFirst().map(line)).joined(separator: "\n")
        }

        /// The table as tab-separated plain text for spreadsheets: inline Markdown is dropped,
        /// and line breaks and tabs inside a cell become spaces so each row stays one line.
        var tabSeparated: String {
            ([header] + rows).map { row in
                row.map { cell in
                    KapitsaChatMarkdown.plainText(cell)
                        .components(separatedBy: CharacterSet(charactersIn: "\t\n\r\u{2028}"))
                        .joined(separator: " ")
                }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    static func blocks(in text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(expandingLeadingTabs)
        return blocks(lines[...])
    }

    // MARK: Blocks

    private static func blocks(_ lines: ArraySlice<String>) -> [Block] {
        var blocks: [Block] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            if isBlank(line) {
                index += 1
            } else if let fence = fence(line) {
                index = code(from: index, in: lines, fence: fence, into: &blocks)
            } else if let heading = heading(line) {
                if !heading.text.isEmpty { blocks.append(.heading(level: heading.level, text: heading.text)) }
                index += 1
            } else if isRule(line) {
                blocks.append(.rule)
                index += 1
            } else if quoteContent(line) != nil {
                var inner: [String] = []
                while index < lines.endIndex, let content = quoteContent(lines[index]) {
                    inner.append(content)
                    index += 1
                }
                blocks.append(.quote(self.blocks(inner[...])))
            } else if let marker = listMarker(line) {
                index = list(from: index, in: lines, first: marker, into: &blocks)
            } else if let table = tableStart(at: index, in: lines) {
                index = self.table(from: index, in: lines, alignments: table, into: &blocks)
            } else {
                var paragraph = [line.trimmingCharacters(in: .whitespaces)]
                index += 1
                while index < lines.endIndex, !isBlank(lines[index]), !startsBlock(at: index, in: lines) {
                    paragraph.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return blocks
    }

    /// Whether the line ends a paragraph by starting another kind of block.
    private static func startsBlock(at index: Int, in lines: ArraySlice<String>) -> Bool {
        let line = lines[index]
        return fence(line) != nil || heading(line) != nil || isRule(line) || quoteContent(line) != nil
            || listMarker(line) != nil || tableStart(at: index, in: lines) != nil
    }

    // MARK: Code

    private struct Fence { let character: Character; let length: Int; let indent: Int; let language: String }

    private static func fence(_ line: String) -> Fence? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix { $0 == character }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string can't hold a backtick (that's inline code instead).
        if character == "`" && info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        return Fence(character: character, length: length, indent: indent, language: language)
    }

    /// A fenced code block up to its closing fence, or to the end while it's still being written.
    private static func code(from start: Int, in lines: ArraySlice<String>, fence: Fence,
                             into blocks: inout [Block]) -> Int {
        var code: [String] = []
        var index = start + 1
        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if leadingSpaces(line) <= 3, trimmed.count >= fence.length, trimmed.allSatisfy({ $0 == fence.character }) {
                index += 1
                break
            }
            code.append(String(line.dropFirst(min(fence.indent, leadingSpaces(line)))))
            index += 1
        }
        blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
        return index
    }

    // MARK: Headings, rules, quotes

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // An optional closing run of #s, set off by a space.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing == text.count {
            text = ""
        } else if closing > 0, text.dropLast(closing).last == " " {
            text = text.dropLast(closing).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard leadingSpaces(line) <= 3 else { return false }
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func quoteContent(_ line: String) -> String? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard rest.first == ">" else { return nil }
        let content = rest.dropFirst()
        return String(content.first == " " ? content.dropFirst() : content)
    }

    // MARK: Lists

    private struct ListMarker {
        let indent: Int
        let isOrdered: Bool
        let number: Int
        /// Where the item's text starts; lines indented this far belong to the item.
        let contentIndent: Int
        let content: String
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        var markerLength: Int
        var number = 1
        let isOrdered: Bool
        if "-*+".contains(first) {
            markerLength = 1
            isOrdered = false
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let delimiter = rest.dropFirst(digits.count).first,
                  delimiter == "." || delimiter == ")" else { return nil }
            markerLength = digits.count + 1
            number = Int(digits) ?? 1
            isOrdered = true
        }
        let afterMarker = rest.dropFirst(markerLength)
        guard afterMarker.isEmpty || afterMarker.first == " " else { return nil }
        let spaces = afterMarker.prefix { $0 == " " }.count
        // Five or more spaces would start indented code in CommonMark; count just one.
        let gap = afterMarker.isEmpty ? 1 : (spaces > 4 ? 1 : spaces)
        markerLength += gap
        return ListMarker(indent: indent, isOrdered: isOrdered, number: number,
                          contentIndent: indent + markerLength,
                          content: String(afterMarker.dropFirst(min(spaces, gap))).trimmingCharacters(in: .whitespaces))
    }

    /// A list and its items. Lines indented under an item belong to it, and so does any list
    /// item indented past the item's own marker: models often nest by two spaces under "1.".
    private static func list(from start: Int, in lines: ArraySlice<String>, first: ListMarker,
                             into blocks: inout [Block]) -> Int {
        var items: [[Block]] = []
        var marker = first
        var index = start
        while true {
            var itemLines = [marker.content]
            index += 1
            var sawBlank = false
            while index < lines.endIndex {
                let line = lines[index]
                if isBlank(line) {
                    sawBlank = true
                    itemLines.append("")
                    index += 1
                    continue
                }
                let indent = leadingSpaces(line)
                let nested = listMarker(line).map { $0.indent > marker.indent } ?? false
                let drop = min(indent, marker.contentIndent)
                if indent > marker.indent, let fence = fence(String(line.dropFirst(drop))) {
                    // A code block in the item, which may be indented short of the item's
                    // text: keep every line to its closing fence, blank or not.
                    itemLines.append(String(line.dropFirst(drop)))
                    index += 1
                    while index < lines.endIndex {
                        let codeLine = String(lines[index].dropFirst(min(leadingSpaces(lines[index]), drop)))
                        itemLines.append(codeLine)
                        index += 1
                        let trimmed = codeLine.trimmingCharacters(in: .whitespaces)
                        if leadingSpaces(codeLine) <= 3, trimmed.count >= fence.length,
                           trimmed.allSatisfy({ $0 == fence.character }) { break }
                    }
                    sawBlank = false
                    continue
                } else if indent >= marker.contentIndent || nested {
                    itemLines.append(String(line.dropFirst(drop)))
                } else if !sawBlank, !startsBlock(at: index, in: lines) {
                    // A lazy continuation of the item's paragraph.
                    itemLines.append(line.trimmingCharacters(in: .whitespaces))
                } else {
                    break
                }
                sawBlank = false
                index += 1
            }
            items.append(self.blocks(itemLines[...]))
            guard index < lines.endIndex, let next = listMarker(lines[index]),
                  next.isOrdered == first.isOrdered else { break }
            marker = next
        }
        // Give back the blank lines the last item swallowed.
        while index > start + 1, isBlank(lines[index - 1]) { index -= 1 }
        blocks.append(.list(List(isOrdered: first.isOrdered, start: first.number, items: items)))
        return index
    }

    // MARK: Tables

    /// The column alignments when the line is a table's header row, followed by its alignment
    /// row. While a reply streams, a last line of just pipes and dashes counts already.
    private static func tableStart(at index: Int, in lines: ArraySlice<String>) -> [Table.Alignment]? {
        let header = lines[index]
        guard header.contains("|"), index + 1 < lines.endIndex else { return nil }
        let delimiter = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard !delimiter.isEmpty, delimiter.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let cells = self.cells(delimiter)
        let isComplete = delimiter.contains("-") && (delimiter.contains("|") || cells.count > 1)
            && cells.allSatisfy { $0.contains("-") }
        guard isComplete || index + 2 == lines.endIndex else { return nil }
        return cells.map { cell -> Table.Alignment in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":") && cell.count > 1) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    private static func table(from start: Int, in lines: ArraySlice<String>, alignments: [Table.Alignment],
                              into blocks: inout [Block]) -> Int {
        var header = cells(lines[start])
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.endIndex, !isBlank(lines[index]), lines[index].contains("|") {
            rows.append(cells(lines[index]))
            index += 1
        }
        // Ragged rows: as many columns as the widest row, empty cells filling the rest.
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        header += Array(repeating: "", count: columns - header.count)
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        let filled = alignments.prefix(columns) + Array(repeating: .leading, count: max(0, columns - alignments.count))
        blocks.append(.table(Table(alignments: Array(filled), header: header, rows: rows)))
        return index
    }

    /// A row's cells, split on pipes outside inline code; `\|` is a literal pipe.
    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)[...]
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row = row.dropLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for character in row {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|" && !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// A cell's inline Markdown as the plain text it shows, with HTML line breaks as newlines.
    static func plainText(_ inline: String) -> String {
        let text = inline.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        guard let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return text }
        return String(attributed.characters)
    }

    // MARK: Lines

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func expandingLeadingTabs(_ line: Substring) -> String {
        guard line.first == "\t" || (line.first == " " && line.contains("\t")) else { return String(line) }
        var result = ""
        var rest = line[...]
        while let character = rest.first, character == " " || character == "\t" {
            result += character == "\t" ? String(repeating: " ", count: 4 - result.count % 4) : " "
            rest = rest.dropFirst()
        }
        return result + rest
    }
}
