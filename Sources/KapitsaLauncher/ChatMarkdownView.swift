import SwiftUI

/// A reply drawn from its Markdown: headings, paragraphs, lists, quotes, code blocks and tables.
/// Equatable on its text, so SwiftUI skips it when a message view is redrawn with the same reply.
struct ChatMarkdownView: View, Equatable {
    let text: String

    var body: some View {
        ChatMarkdownBlocks(blocks: KapitsaChatMarkdown.blocks(in: text), depth: 0)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown (bold, italics, code, links), keeping the model's line breaks.
    static func inline(_ text: String) -> AttributedString {
        // Models put HTML line breaks in table cells.
        let text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct ChatMarkdownBlocks: View {
    let blocks: [KapitsaChatMarkdown.Block]
    /// How deeply nested in lists, which picks the bullet.
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Blocks only grow at the end while a reply streams, so their positions are stable IDs.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, isFirst: index == 0)
            }
        }
    }

    @ViewBuilder
    private func view(for block: KapitsaChatMarkdown.Block, isFirst: Bool) -> some View {
        switch block {
        case let .heading(level, text):
            Text(ChatMarkdownView.inline(text))
                .font(Self.font(forHeading: level))
                .padding(.top, isFirst ? 0 : (level <= 2 ? 8 : 4))
        case let .paragraph(text):
            Text(ChatMarkdownView.inline(text))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(list):
            ChatMarkdownList(list: list, depth: depth)
        case let .quote(blocks):
            ChatMarkdownBlocks(blocks: blocks, depth: depth)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(KapitsaTheme.border).frame(width: 3) }
        case let .code(language, code):
            ChatMarkdownCode(language: language, code: code)
        case let .table(table):
            ChatMarkdownTable(table: table)
        case .rule:
            Rectangle().fill(KapitsaTheme.border).frame(height: 1).padding(.vertical, 4)
        }
    }

    private static func font(forHeading level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct ChatMarkdownList: View {
    let list: KapitsaChatMarkdown.List
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(at: index))
                        .foregroundStyle(list.isOrdered ? Color.secondary : KapitsaTheme.accent)
                        .monospacedDigit()
                        .frame(minWidth: list.isOrdered ? 18 : 10, alignment: .trailing)
                    ChatMarkdownBlocks(blocks: item, depth: depth + 1)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func marker(at index: Int) -> String {
        if list.isOrdered { return "\(list.start + index)." }
        return ["•", "◦", "▪︎"][depth % 3]
    }
}

/// A fenced code block: monospaced on an inset, scrolling sideways rather than wrapping.
private struct ChatMarkdownCode: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                Spacer()
                ChatMarkdownCopyButton(text: code, help: "Copy the code", accessibilityLabel: "Copy code")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 5)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(KapitsaTheme.border, lineWidth: 1))
    }
}

/// A table as a grid with a shaded header; wide tables scroll sideways instead of squashing.
/// Copy puts it on the clipboard as a Markdown table, and as tab-separated text for spreadsheets.
private struct ChatMarkdownTable: View {
    let table: KapitsaChatMarkdown.Table

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Table")
                Spacer()
                ChatMarkdownCopyButton(text: table.markdown, otherTypes: [.tabularText: table.tabSeparated],
                                       help: "Copy the table as Markdown (spreadsheets get tab-separated text)",
                                       accessibilityLabel: "Copy table")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            grid
        }
    }

    private var grid: some View {
        ScrollView(.horizontal) {
            // The border colour shows through the gaps between cells as grid lines.
            ChatTableLayout(columns: table.header.count, maxColumnWidth: 340, spacing: 1) {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                    cell(text, column: column)
                        .fontWeight(.semibold)
                        .background(KapitsaTheme.inset)
                }
                ForEach(Array(table.rows.joined().enumerated()), id: \.offset) { index, text in
                    cell(text, column: index % table.header.count).background(KapitsaTheme.panel)
                }
            }
            .background(KapitsaTheme.border)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(KapitsaTheme.border, lineWidth: 1))
            .padding(1)
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = table.alignments[column]
        return Text(ChatMarkdownView.inline(text))
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .lineSpacing(2)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment == .center ? .top : alignment == .trailing ? .topTrailing : .topLeading)
    }
}

/// The Copy button in a code block's or table's header, confirming with a checkmark.
private struct ChatMarkdownCopyButton: View {
    let text: String
    var otherTypes: [NSPasteboard.PasteboardType: String] = [:]
    let help: String
    let accessibilityLabel: String

    var body: some View {
        CopyButton(text: text, help: help, otherTypes: otherTypes) { copied in
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Cells in rows, left to right: each column as wide as its widest cell up to a limit (longer
/// text wraps), each row as tall as its tallest cell. A table in a sideways scroll view has no
/// width to wrap to, so without the limit a long cell would be one long line.
private struct ChatTableLayout: Layout {
    let columns: Int
    let maxColumnWidth: CGFloat
    let spacing: CGFloat

    struct Measure { var widths: [CGFloat]; var heights: [CGFloat] }

    func makeCache(subviews: Subviews) -> Measure {
        guard columns > 0 else { return Measure(widths: [], heights: []) }
        var widths = Array(repeating: CGFloat(0), count: columns)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width
            widths[index % columns] = max(widths[index % columns], min(ideal.rounded(.up), maxColumnWidth))
        }
        var heights = Array(repeating: CGFloat(0), count: (subviews.count + columns - 1) / columns)
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            heights[index / columns] = max(heights[index / columns], height.rounded(.up))
        }
        return Measure(widths: widths, heights: heights)
    }

    func updateCache(_ cache: inout Measure, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measure) -> CGSize {
        CGSize(width: cache.widths.reduce(0, +) + spacing * CGFloat(max(cache.widths.count - 1, 0)),
               height: cache.heights.reduce(0, +) + spacing * CGFloat(max(cache.heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measure) {
        var y = bounds.minY
        for row in cache.heights.indices {
            var x = bounds.minX
            for column in cache.widths.indices {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(width: cache.widths[column], height: cache.heights[row]))
                x += cache.widths[column] + spacing
            }
            y += cache.heights[row] + spacing
        }
    }
}
