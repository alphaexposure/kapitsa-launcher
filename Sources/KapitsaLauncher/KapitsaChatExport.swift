import Foundation

/// A chat, or one turn of it, as Markdown. The model's replies are already Markdown, so they
/// are written as they are. Reasoning goes in a `<details>` block, which folds up in most
/// Markdown viewers, unless `includeThinking` is off for a shorter file. A model-written summary
/// can go at the top, or stand alone with a link to the full conversation's file. Replies
/// get places and topics lines, and an index at the end, grouped into places and themes,
/// links each to its questions; they can also go in front matter as tags. Images are saved as files beside
/// the Markdown; documents are listed by name.
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
        /// Topics as `tags` in YAML front matter, which note apps such as Obsidian read.
        var includeTopicTags = false
        /// Side questions, each under the reply it's about.
        var includeSideQuestions = true

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
    ///   - includeTopicTags: places and topics as tags in front matter.
    ///   - topicThemes: which theme each topic belongs to, by topic key.
    init(messages: [KapitsaChatMessage], includeThinking: Bool = true, summary: KapitsaChatSummary? = nil,
         includeConversation: Bool = true, fullConversationFileName: String? = nil, includeTopicTags: Bool = false,
         topicThemes: [String: String] = [:], includeSideQuestions: Bool = true, exportedAt: Date = Date(),
         imagesFolderName: String? = nil, timeZone: TimeZone = .current) {
        let fileName = Self.fileName(for: messages)
        let folder = imagesFolderName ?? Self.imagesFolderName(forMarkdownNamed: fileName)
        var images: [Image] = []
        let date = Self.format(exportedAt, timeZone: timeZone)
        let topics = KapitsaChatTopics.index(KapitsaChatOutline.entries(from: messages), themes: topicThemes)
        var lines: [String] = []
        if includeTopicTags && !topics.isEmpty {
            lines += ["---", "tags:"] + Self.tags(topics).map { "  - \($0)" } + ["---", ""]
        }
        lines += ["# \(Self.title(for: messages))", "", "_Exported from Kapitsa Launcher on \(date)_", ""]
        var question = 0

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
                question += 1
                // An anchor the topic index links to; only needed when there is an index.
                if !topics.isEmpty { lines.append("<a id=\"\(Self.anchor(question))\"></a>") }
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
                if let names = message.places, !names.isEmpty {
                    lines += ["_Places: " + names.joined(separator: " · ") + "_", ""]
                }
                if let names = message.topics, !names.isEmpty {
                    lines += ["_Topics: " + names.joined(separator: " · ") + "_", ""]
                }
                if message.wasStopped { lines += ["_Stopped before the reply finished._", ""] }
                if let error = message.errorMessage { lines += ["_Error: \(error)_", ""] }
                if let stats = Self.statsLine(message.stats) { lines += ["<sub>\(stats)</sub>", ""] }
                if includeSideQuestions {
                    for tangent in message.tangents ?? [] where !tangent.messages.isEmpty {
                        lines += Self.quoted(tangent) + [""]
                    }
                }
            }
        }

        if !topics.isEmpty {
            // Links go to this file's questions, to the full conversation's file beside a summary,
            // or nowhere when there is no conversation to link to.
            let target = includeConversation ? "" : fullConversationFileName.map(Self.encodedPath)
            func entry(_ topic: KapitsaChatTopics.Topic) -> String {
                let questions = topic.mentions.map { mention in
                    target.map { "[\(mention.number)](\($0)#\(Self.anchor(mention.number)))" } ?? "\(mention.number)"
                }
                let label = topic.mentions.count == 1 ? "Question" : "Questions"
                return "- **\(topic.name)**: \(label) " + questions.joined(separator: ", ")
            }
            lines += ["---", "", "## Topics", ""]
            // Headings only when there is more than one group; topics never grouped are a plain list.
            let ungroupedOnly = topics.places.isEmpty && topics.themes.map(\.name) == [KapitsaChatTopics.otherTheme]
            if !topics.places.isEmpty {
                lines += ["### Places", ""] + topics.places.map(entry) + [""]
            }
            for theme in topics.themes {
                if !ungroupedOnly { lines += ["### \(theme.name)", ""] }
                lines += theme.topics.map(entry) + [""]
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
                      summary: KapitsaChatSummary?, topicThemes: [String: String] = [:], exportedAt: Date = Date(),
                      timeZone: TimeZone = .current) throws -> [URL] {
        let fileName = url.lastPathComponent
        let images = imagesFolderName(forMarkdownNamed: fileName)
        let summary = options.includeSummary ? summary : nil
        // Exporting over an earlier export replaces its summary too; otherwise a file that
        // happens to have the summary's name is kept, and the summary gets a number.
        let replacingEarlierExport = FileManager.default.fileExists(atPath: url.path)
        guard options.savesSummarySeparately, let summary else {
            try KapitsaChatExport(messages: messages, includeThinking: options.includeThinking, summary: summary,
                                  includeConversation: options.includeConversation || summary == nil,
                                  includeTopicTags: options.includeTopicTags, topicThemes: topicThemes,
                                  includeSideQuestions: options.includeSideQuestions,
                                  exportedAt: exportedAt, imagesFolderName: images, timeZone: timeZone)
                .write(to: url)
            return [url]
        }
        try KapitsaChatExport(messages: messages, includeThinking: options.includeThinking,
                              includeTopicTags: options.includeTopicTags, topicThemes: topicThemes,
                              includeSideQuestions: options.includeSideQuestions,
                              exportedAt: exportedAt, imagesFolderName: images, timeZone: timeZone)
            .write(to: url)
        var summaryURL = url.deletingLastPathComponent().appendingPathComponent(summaryFileName(forMarkdownNamed: fileName))
        if !replacingEarlierExport {
            let base = summaryURL.deletingPathExtension().lastPathComponent
            var number = 2
            while FileManager.default.fileExists(atPath: summaryURL.path) {
                summaryURL = summaryURL.deletingLastPathComponent().appendingPathComponent("\(base) \(number).md")
                number += 1
            }
        }
        try KapitsaChatExport(messages: messages, summary: summary, includeConversation: false,
                              fullConversationFileName: fileName, includeTopicTags: options.includeTopicTags,
                              topicThemes: topicThemes, exportedAt: exportedAt, timeZone: timeZone)
            .write(to: summaryURL)
        return [url, summaryURL]
    }

    /// A side question as a quote under its reply: set apart from the conversation, which it
    /// was never part of.
    static func quoted(_ tangent: KapitsaTangent) -> [String] {
        var lines = ["**Side question**", ""] + thread(tangent)
        if tangent.continuedIn != nil { lines += ["_Continued in a new chat._", ""] }
        while lines.last == "" { lines.removeLast() }
        // Every line of a reply, not just its first, so its paragraphs stay in the quote.
        return lines.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false) }
            .map { $0.isEmpty ? ">" : "> " + $0 }
    }

    /// A side question's thread: each question marked as yours, each reply as written.
    static func thread(_ tangent: KapitsaTangent) -> [String] {
        var lines: [String] = []
        for message in tangent.messages {
            switch message.role {
            case .user: lines += ["**You:** " + message.text, ""]
            case .assistant:
                if !message.text.isEmpty { lines += [message.text, ""] }
                if message.wasStopped { lines += ["_Stopped before the reply finished._", ""] }
                if let error = message.errorMessage { lines += ["_Error: \(error)_", ""] }
            }
        }
        return lines
    }

    /// One side question as its own Markdown file, naming the chat and the reply it's about.
    static func sideQuestion(_ tangent: KapitsaTangent, chatName: String, about question: String?,
                             exportedAt: Date = Date(), timeZone: TimeZone = .current) -> String {
        let first = tangent.messages.first?.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Side question"
        var lines = ["# Side question: \(first)", ""]
        let about = question.map { ", about the reply to “\($0)”" } ?? ""
        lines += ["_From “\(chatName)”\(about). Exported from Kapitsa Launcher on \(format(exportedAt, timeZone: timeZone))._", ""]
        lines += thread(tangent)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
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

    /// The anchor before a question's heading, which the topic index links to.
    static func anchor(_ question: Int) -> String { "question-\(question)" }

    /// Places as "Places/…", which note apps such as Obsidian nest, and the chat's themes.
    /// Topics stay out: there are many and they rarely repeat across chats, so they would swell
    /// a tag list; themes are few and recur. A chat whose topics were never grouped tags them.
    static func tags(_ index: KapitsaChatTopics.Index) -> [String] {
        let themes = index.themes.filter { $0.name != KapitsaChatTopics.otherTheme }
        let rest = themes.isEmpty ? index.themes.flatMap(\.topics).map { tag($0.name) } : themes.map { tag($0.name) }
        return index.places.map { "Places/" + tag($0.name) } + rest
    }

    /// A topic as a tag: tags can't hold spaces in most note apps, so words join with hyphens.
    static func tag(_ topic: String) -> String {
        topic.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/")).inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
    }

    static func encodedPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? path
    }

    private static func escapedAltText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
