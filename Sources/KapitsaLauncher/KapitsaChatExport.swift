import Foundation

/// A chat, or one turn of it, as Markdown. The model's replies are already Markdown, so they
/// are written as they are. Reasoning goes in a `<details>` block, which folds up in most
/// Markdown viewers, unless `includeThinking` is off for a shorter file. Images are saved as files beside the Markdown; documents are listed by name.
struct KapitsaChatExport: Equatable {
    struct Image: Equatable {
        /// The path the Markdown links to, relative to the Markdown file.
        let relativePath: String
        let data: Data
    }

    let markdown: String
    let images: [Image]
    let suggestedFileName: String

    init(messages: [KapitsaChatMessage], includeThinking: Bool = true, exportedAt: Date = Date(),
         imagesFolderName: String? = nil, timeZone: TimeZone = .current) {
        let fileName = Self.fileName(for: messages)
        let folder = imagesFolderName ?? Self.imagesFolderName(forMarkdownNamed: fileName)
        var images: [Image] = []
        var lines = ["# \(Self.title(for: messages))", "",
                     "_Exported from Kapitsa Launcher on \(Self.format(exportedAt, timeZone: timeZone))_", ""]

        for message in messages {
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

    /// The folder that holds a Markdown file's images: "<name> images", beside it.
    static func imagesFolderName(forMarkdownNamed fileName: String) -> String {
        (fileName as NSString).deletingPathExtension + " images"
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

    private static func encodedPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? path
    }

    private static func escapedAltText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
