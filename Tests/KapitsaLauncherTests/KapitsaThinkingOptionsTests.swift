import XCTest
@testable import KapitsaLauncher

final class KapitsaThinkingOptionsTests: XCTestCase {
    /// The shape of the Qwen3.8 27B's template, trimmed to what the buttons read.
    private let effortTemplate = """
    {%- if enable_thinking is undefined or enable_thinking is true %}
        {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
        {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}{{- raise_exception('x') }}{%- endif %}
        {%- if resolved_reasoning_effort == 'xhigh' %}{%- set r = 'Reasoning effort is set to xhigh.' %}
        {%- elif resolved_reasoning_effort == 'low' %}{%- set r = 'Reasoning effort is set to low.' %}{%- endif %}
    {%- endif %}
    {%- if messages[0].role not in ('system', 'developer') %}{%- endif %}
    """

    func testReadsEachKindOfTemplate() {
        let effort = KapitsaThinkingOptions(template: effortTemplate)
        XCTAssertEqual(effort.kind, .effort)
        XCTAssertEqual(effort.levels, [.off, .low, .medium, .xhigh])
        XCTAssertEqual(effort.defaultLevel, .xhigh)
        XCTAssertEqual(effort.levelsWithStartText, [.low, .xhigh])

        let shorter = KapitsaThinkingOptions(template: "{%- set enable_thinking = true %}{%- set medium_effort = false %}")
        XCTAssertEqual(shorter.kind, .shorterFull)
        XCTAssertEqual(shorter.levels.map(shorter.label), ["Off", "Shorter", "Full"])
        XCTAssertFalse(shorter.changeRereadsChat)

        let onOff = KapitsaThinkingOptions(template: "{%- if enable_thinking is defined and enable_thinking is false %}")
        XCTAssertEqual(onOff, .onOff)
        XCTAssertEqual(onOff.levels.map(onOff.label), ["Off", "On"])

        let askedOnly = KapitsaThinkingOptions(template: "{%- if enable_thinking is defined and enable_thinking is true %}<think>{%- endif %}")
        XCTAssertEqual(askedOnly.levels, [.off, .on])
        XCTAssertEqual(askedOnly.defaultLevel, .off, "the Qwen3.5 2B thinks only when asked")
        XCTAssertEqual(KapitsaThinkingOptions(template: "{%- if enable_thinking is defined and enable_thinking is false %}").defaultLevel, .on)

        let none = KapitsaThinkingOptions(template: "{%- if add_generation_prompt -%}<|assistant|>{%- endif -%}")
        XCTAssertEqual(none.kind, .none)
        XCTAssertTrue(none.levels.isEmpty)
    }

    func testOnlyAChangeAtTheStartOfThePromptRereadsTheChat() {
        let effort = KapitsaThinkingOptions(template: effortTemplate)
        XCTAssertTrue(effort.changesPromptStart(from: .xhigh, to: .low))
        XCTAssertTrue(effort.changesPromptStart(from: .medium, to: .xhigh))
        XCTAssertFalse(effort.changesPromptStart(from: .off, to: .medium), "neither adds text at the start")
        XCTAssertFalse(effort.changesPromptStart(from: .low, to: .low))
        XCTAssertFalse(KapitsaThinkingOptions.onOff.changesPromptStart(from: .off, to: .on))
    }

    func testAnUnofferedLevelFallsBackToTheModelsDefault() {
        let effort = KapitsaThinkingOptions(template: effortTemplate)
        XCTAssertEqual(effort.valid(.on), .xhigh, "a 35B choice on the 27B")
        XCTAssertEqual(effort.valid(.low), .low)
        XCTAssertEqual(KapitsaThinkingOptions.onOff.valid(.xhigh), .on)
        XCTAssertEqual(KapitsaThinkingOptions.onOff.valid(nil), .on)
    }

    func testRequestFieldsForTheNewLevels() {
        XCTAssertEqual((KapitsaThinkingLevel.on.requestFields["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
        XCTAssertNil(KapitsaThinkingLevel.on.requestFields["reasoning_effort"], "the template's own default")
        XCTAssertEqual(KapitsaThinkingLevel.shorter.requestFields["reasoning_effort"] as? String, "medium",
                       "Kapitsa turns the medium effort into Nemotron's medium_effort")
        XCTAssertEqual(KapitsaThinkingLevel.xhigh.requestFields["reasoning_effort"] as? String, "xhigh")
    }

    func testFindsTheTemplateInAModelFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jinja = root.appendingPathComponent("qwen3.8-27b-4bit"), tokenizer = root.appendingPathComponent("someone-model")
        try FileManager.default.createDirectory(at: jinja, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try effortTemplate.write(to: jinja.appendingPathComponent("chat_template.jinja"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["chat_template": "{{ enable_thinking }}"])
            .write(to: tokenizer.appendingPathComponent("tokenizer_config.json"))

        XCTAssertEqual(KapitsaThinkingOptions.folder(forModel: "qwen3.8-27b", configured: "27b", modelsDirectory: root)?.lastPathComponent,
                       "qwen3.8-27b-4bit")
        XCTAssertEqual(KapitsaThinkingOptions.folder(forModel: "anything", configured: tokenizer.path, modelsDirectory: root)?.standardizedFileURL.path,
                       tokenizer.standardizedFileURL.path,
                       "a folder given to --model")
        XCTAssertNil(KapitsaThinkingOptions.folder(forModel: "qwen3.5-4b", configured: nil, modelsDirectory: root))
        let repo = root.appendingPathComponent("lmstudio-community--Qwen3.5-2B-MLX-4bit")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(KapitsaThinkingOptions.folder(forModel: "Qwen3.5-2B-MLX-4bit", configured: "lmstudio-community/Qwen3.5-2B-MLX-4bit",
                                                     modelsDirectory: root)?.lastPathComponent, repo.lastPathComponent, "a Hugging Face repo")
        XCTAssertEqual(KapitsaThinkingOptions.template(in: tokenizer), "{{ enable_thinking }}")
    }

    /// The catalog's real templates, when a folder of them is given (they aren't kept in the
    /// repository): KAPITSA_TEMPLATES=<folder of <name>.jinja files>.
    func testCatalogTemplatesWhenGiven() throws {
        guard let folder = ProcessInfo.processInfo.environment["KAPITSA_TEMPLATES"] else { throw XCTSkip("KAPITSA_TEMPLATES not set") }
        let expected: [String: [KapitsaThinkingLevel]] = [
            "4b": [.off, .on], "9b": [.off, .on], "35b": [.off, .on],
            "27b": [.off, .low, .medium, .xhigh], "flash": [.off, .low, .medium, .xhigh],
            "lightning": [.off, .on], "nano-4b": [.off, .on], "nano-9b": [.off, .on],
            "bolt": [.off, .shorter, .on], "super": [.off, .shorter, .on], "dory": [.off, .shorter, .on],
            "flint": [],
        ]
        for (name, levels) in expected {
            let text = try String(contentsOfFile: folder + "/" + name + ".jinja", encoding: .utf8)
            let options = KapitsaThinkingOptions(template: text)
            XCTAssertEqual(options.levels, levels, name)
            if options.kind == .effort {
                XCTAssertEqual(options.defaultLevel, .xhigh, name)
                XCTAssertEqual(options.levelsWithStartText, [.low, .xhigh], name)
            }
        }
    }
}

final class KapitsaKnownModelsTests: XCTestCase {
    func testRemembersModelsThatLoadAndForgetsOnesThatFailOrMove() {
        let defaults = UserDefaults(suiteName: "KapitsaKnownModelsTests")!
        defaults.removePersistentDomain(forName: "KapitsaKnownModelsTests")
        KapitsaKnownModels.remember("/Users/me/.lmstudio/models/org/Qwen3.5-9B-MLX-4bit", defaults: defaults)
        KapitsaKnownModels.remember("someone/Qwen3.5-Fine-Tune", defaults: defaults)
        KapitsaKnownModels.remember("35b", defaults: defaults)
        KapitsaKnownModels.remember("35b:8bit", defaults: defaults)
        XCTAssertEqual(KapitsaKnownModels.all(defaults: defaults, fileExists: { _ in true }),
                       ["someone/Qwen3.5-Fine-Tune", "/Users/me/.lmstudio/models/org/Qwen3.5-9B-MLX-4bit"],
                       "the newest first; catalog names aren't remembered")
        XCTAssertEqual(KapitsaKnownModels.all(defaults: defaults, fileExists: { _ in false }), ["someone/Qwen3.5-Fine-Tune"],
                       "a folder that has gone is left out")
        KapitsaKnownModels.forget("someone/Qwen3.5-Fine-Tune", defaults: defaults)
        XCTAssertEqual(KapitsaKnownModels.all(defaults: defaults, fileExists: { _ in true }), ["/Users/me/.lmstudio/models/org/Qwen3.5-9B-MLX-4bit"])
        XCTAssertEqual(KapitsaKnownModels.title("/Users/me/x/Qwen3.5-9B-MLX-4bit").components(separatedBy: " · ").first, "Qwen3.5-9B-MLX-4bit")
    }

    func testOtherModelsLeaveOutDownloadedAndCatalogOnes() {
        XCTAssertEqual(ModelSwitcher.otherModels(known: ["a/b", "/x/y", "qwen3.8-27b:4bit"], current: "a/b",
                                                 installed: ["qwen3.8-27b:4bit"]), ["a/b", "/x/y"])
        XCTAssertEqual(ModelSwitcher.otherModels(known: [], current: "35b", installed: []), [])
    }
}
