import Foundation

/// A chat, or one turn of it, as Markdown. The model's replies are already Markdown, so they
/// are written as they are. Reasoning goes in a `<details>` block, which folds up in most
/// Markdown viewers, unless `includeThinking` is off for a shorter file. A model-written summary
/// can go at the top, or stand alone with a link to the full conversation's file. Images are saved as files beside the Markdown; documents are listed by name.
struct KapitsaChatExport: Equatable {
    struct Image: Equatable {
        /// The path the Markdown links to, relative to the Markdown file.
        let relativePath: String
        let data: Data
    }

    /// What the Save dialog asked for.
    struct Options: Equatable {
        var includeSummary = false
        var includeConversation = true
        var separateFiles = false
        var includeThinking = true

        /// The summary goes in its own file only when there's a full conversation to go beside.
        var savesSummarySeparately: Bool { includeSummary && includeConversation && separateFiles }
    }

    let markdown: String
    let images: [Image]
    let suggestedFileName: String

    /// - Parameters:
    ///   - includeConversation: false for a summary on its own.
    ///   - fullConversationFileName: the file holding the full conversation, linked from a
    ///     summary saved on its own.
    init(messages: [KapitsaChatMessage], includeThinking: Bool = true, summary: KapitsaChatSummary? = nil,
         includeConversation: Bool = true, fullConversationFileName: String? = nil, exportedAt: Date = Date(),
         imagesFolderName: String? = nil, timeZone: TimeZone = .current) {
        let fileName = Self.fileName(for: messages)
        let folder = imagesFolderName ?? Self.imagesFolderName(forMarkdownNamed: fileName)
        var images: [Image] = []
        let date = Self.format(exportedAt, timeZone: timeZone)
        var lines = ["# \(Self.title(for: messages))", "", "_Exported from Kapitsa Launcher on \(date)_", ""]

        if let summary {
            var note = "_Written by \(summary.model) from the questions and replies. It may miss or misstate details"
            if includeConversation {
                note += "; the full conversation follows._"
            } else if let fullConversationFileName {
                note += "; the full conversation is in [\(fullConversationFileName)](\(Self.encodedPath(fullConversationFileName)))._"
            } else {
                note += "._"
            }
            lines += ["## Summary", "", note, "", summary.text, ""]
            if includeConversation { lines += ["---", ""] }
        }

        for message in includeConversation ? messages : [] {
            switch message.role {
            case .user:
                lines.append(Self.heading("You", detail: [], sentAt: message.sentAt, timeZone: timeZone))
                lines.append("")
                for attachment in message.attachments {
                    switch attachment.kind {
                    case .image:
                        guard let data = attachment.imageData else { continue }
                        let name = String(format: "%02d-", images.count + 1) + Self.imageFileName(attachment.name)
                        let path = folder + "/" + name
                        images.append(Image(relativePath: path, data: data))
                        lines.append("![\(Self.escapedAltText(attachment.name))](\(Self.encodedPath(path)))")
                    case .document:
                        let length = (attachment.text?.count ?? 0).formatted()
                        let cut = attachment.truncated ? ", cut to fit" : ""
                        lines.append("- Attached document: `\(attachment.name)` (\(length) characters\(cut))")
                    }
                    lines.append("")
                }
                if !message.text.isEmpty { lines += [message.text, ""] }
            case .assistant:
                var detail: [String] = []
                if let model = message.model { detail.append(model) }
                if let level = message.thinking { detail.append("Thinking: \(level.label)") }
                lines.append(Self.heading("Kapitsa", detail: detail, sentAt: message.sentAt, timeZone: timeZone))
                lines.append("")
                if includeThinking && !message.reasoning.isEmpty {
                    let summary = message.stats?.thinkingSeconds.map {
                        "Thought for " + $0.formatted(.number.precision(.fractionLength(1))) + " s"
                    } ?? "Thoughts"
                    lines += ["<details><summary>\(summary)</summary>", "",
                              message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines), "", "</details>", ""]
                }
                if !message.text.isEmpty { lines += [message.text, ""] }
                if message.wasStopped { lines += ["_Stopped before the reply finished._", ""] }
                if let error = message.errorMessage { lines += ["_Error: \(error)_", ""] }
                if let stats = Self.statsLine(message.stats) { lines += ["<sub>\(stats)</sub>", ""] }
            }
        }

        markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        self.images = images
        suggestedFileName = fileName
    }

    /// The user message that asked for `replyID` and the reply itself.
    static func turn(endingWith replyID: UUID, in messages: [KapitsaChatMessage]) -> [KapitsaChatMessage] {
        guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return [] }
        let start = index > 0 && messages[index - 1].role == .user ? index - 1 : index
        return Array(messages[start...index])
    }

    /// The summary saved beside a full export: "<name> – Summary.md".
    static func summaryFileName(forMarkdownNamed fileName: String) -> String {
        (fileName as NSString).deletingPathExtension + " – Summary.md"
    }

    /// The folder that holds a Markdown file's images: "<name> images", beside it.
    static func imagesFolderName(forMarkdownNamed fileName: String) -> String {
        (fileName as NSString).deletingPathExtension + " images"
    }

    /// Writes what `options` asks for to `url`: one file, or the full conversation there and the
    /// summary beside it. Returns the files written.
    @discardableResult
    static func write(_ messages: [KapitsaChatMessage], to url: URL, options: Options,
                      summary: KapitsaChatSummary?, exportedAt: Date = Date(),
                      timeZone: TimeZone = .current) throws -> [URL] {
        let fileName = url.lastPathComponent
        let images = imagesFolderName(forMarkdownNamed: fileName)
        let summary = options.includeSummary ? summary : nil
        guard options.savesSummarySeparately, let summary else {
            try KapitsaChatExport(messages: messages, includeThinking: options.includeThinking, summary: summary,
                                  includeConversation: options.includeConversation || summary == nil,
                                  exportedAt: exportedAt, imagesFolderName: images, timeZone: timeZone)
                .write(to: url)
            return [url]
        }
        try KapitsaChatExport(messages: messages, includeThinking: options.includeThinking,
                              exportedAt: exportedAt, imagesFolderName: images, timeZone: timeZone)
            .write(to: url)
        let summaryURL = url.deletingLastPathComponent().appendingPathComponent(summaryFileName(forMarkdownNamed: fileName))
        try KapitsaChatExport(messages: messages, summary: summary, includeConversation: false,
                              fullConversationFileName: fileName, exportedAt: exportedAt, timeZone: timeZone)
            .write(to: summaryURL)
        return [url, summaryURL]
    }

    /// Writes the Markdown to `url`, and any images to a folder beside it.
    func write(to url: URL) throws {
        if !images.isEmpty {
            let base = url.deletingLastPathComponent()
            for image in images {
                let target = base.appendingPathComponent(image.relativePath)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try image.data.write(to: target, options: .atomic)
            }
        }
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Pieces

    /// The first words of the first message, else a generic title.
    static func title(for messages: [KapitsaChatMessage]) -> String {
        let first = messages.first { $0.role == .user && !$0.text.isEmpty }?.text ?? ""
        let words = first.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        guard !words.isEmpty else { return "Kapitsa chat" }
        return words.count < first.count ? words + "…" : words
    }

    static func fileName(for messages: [KapitsaChatMessage]) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var name = title(for: messages).replacingOccurrences(of: "…", with: "")
            .components(separatedBy: unsafe).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return (name.isEmpty ? "Kapitsa chat" : name) + ".md"
    }

    private static func heading(_ who: String, detail: [String], sentAt: Date?, timeZone: TimeZone) -> String {
        var parts = [who] + detail
        if let sentAt { parts.append(format(sentAt, timeZone: timeZone)) }
        return "## " + parts.joined(separator: " · ")
    }

    private static func statsLine(_ stats: KapitsaChatMessage.Stats?) -> String? {
        guard let stats else { return nil }
        var parts: [String] = []
        if let tokens = stats.outputTokens { parts.append("\(tokens.formatted()) tokens") }
        if let rate = stats.tokensPerSecond { parts.append(rate.formatted(.number.precision(.fractionLength(1))) + " tok/s") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Images are saved as JPEG, whatever they were called.
    private static func imageFileName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
        return (base.isEmpty ? "image" : base) + ".jpg"
    }

    static func encodedPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? path
    }

    private static func escapedAltText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
