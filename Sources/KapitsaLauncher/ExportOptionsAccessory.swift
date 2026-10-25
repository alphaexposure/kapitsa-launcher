import AppKit

/// The export options shown in the Save dialog: a summary, the full conversation, whether the
/// two go in separate files, whether to leave out the model's thinking, and side questions. The choices are
/// remembered for the next export.
@MainActor
final class ExportOptionsAccessory: NSObject {
    let view: NSView
    private let summary = NSButton(checkboxWithTitle: "Include summary", target: nil, action: nil)
    private let conversation = NSButton(checkboxWithTitle: "Include full conversation", target: nil, action: nil)
    private let separate = NSButton(checkboxWithTitle: "Save the summary as a separate file", target: nil, action: nil)
    private let excludeThinking = NSButton(checkboxWithTitle: "Exclude thinking", target: nil, action: nil)
    private let topicTags = NSButton(checkboxWithTitle: "Add topics as tags", target: nil, action: nil)
    private let sideQuestions = NSButton(checkboxWithTitle: "Include side questions", target: nil, action: nil)
    private let defaults: UserDefaults

    private enum Key {
        static let summary = "exportIncludesSummary"
        static let conversation = "exportIncludesConversation"
        static let separate = "exportSeparatesSummary"
        static let excludeThinking = "exportExcludesThinking"
        static let topicTags = "exportTopicTags"
        static let sideQuestions = "exportIncludesSideQuestions"
    }

    /// - Parameter canSummarize: false when Kapitsa isn't running, so there's no model to ask.
    init(canSummarize: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stack = NSStackView(views: [summary, conversation, separate, excludeThinking, sideQuestions, topicTags])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()

        summary.state = canSummarize && defaults.bool(forKey: Key.summary) ? .on : .off
        summary.isEnabled = canSummarize
        summary.toolTip = canSummarize
            ? "Kapitsa writes a short summary of the chat, with thinking off. It takes a few seconds."
            : "Start Kapitsa to include a summary written by your model."
        conversation.state = defaults.object(forKey: Key.conversation) as? Bool ?? true ? .on : .off
        separate.state = defaults.bool(forKey: Key.separate) ? .on : .off
        separate.toolTip = "Saves the summary beside the full conversation as \"<name> – Summary.md\"."
        excludeThinking.state = defaults.bool(forKey: Key.excludeThinking) ? .on : .off
        excludeThinking.toolTip = "Leave out the model's reasoning for a shorter file"
        topicTags.state = defaults.bool(forKey: Key.topicTags) ? .on : .off
        topicTags.toolTip = "Put the chat's topics at the top of the file as tags, which note apps such as Obsidian use. Spaces in a topic become hyphens."
        sideQuestions.state = defaults.object(forKey: Key.sideQuestions) as? Bool ?? true ? .on : .off
        sideQuestions.toolTip = "Put each side question, with its replies, under the reply it's about, set apart as a quote"
        for button in [summary, conversation, separate, excludeThinking, sideQuestions, topicTags] {
            button.target = self
            button.action = #selector(changed(_:))
        }
        changed(nil)
    }

    var options: KapitsaChatExport.Options {
        KapitsaChatExport.Options(includeSummary: summary.state == .on,
                                  includeConversation: conversation.state == .on,
                                  separateFiles: separate.state == .on,
                                  includeThinking: excludeThinking.state == .off,
                                  includeTopicTags: topicTags.state == .on,
                                  includeSideQuestions: sideQuestions.state == .on)
    }

    func remember() {
        if summary.isEnabled { defaults.set(summary.state == .on, forKey: Key.summary) }
        defaults.set(conversation.state == .on, forKey: Key.conversation)
        defaults.set(separate.state == .on, forKey: Key.separate)
        defaults.set(excludeThinking.state == .on, forKey: Key.excludeThinking)
        defaults.set(topicTags.state == .on, forKey: Key.topicTags)
        defaults.set(sideQuestions.state == .on, forKey: Key.sideQuestions)
    }

    @objc private func changed(_ sender: NSButton?) {
        // Something has to be saved: unticking one of the two ticks the other.
        if summary.state == .off && conversation.state == .off {
            if sender === conversation && summary.isEnabled { summary.state = .on } else { conversation.state = .on }
        }
        separate.isEnabled = summary.state == .on && conversation.state == .on
        excludeThinking.isEnabled = conversation.state == .on
        sideQuestions.isEnabled = conversation.state == .on
    }
}
