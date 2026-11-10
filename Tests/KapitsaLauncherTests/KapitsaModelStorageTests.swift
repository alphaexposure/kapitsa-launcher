import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaModelStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ bytes: Int, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    func testFolderNamesBecomeKapitsaModelNames() {
        XCTAssertEqual(KapitsaModelStorage.modelName(folderName: "qwen3.8-27b-4bit"), "qwen3.8-27b:4bit")
        XCTAssertEqual(KapitsaModelStorage.modelName(folderName: "qwen3.6-35b-a3b-16gb"), "qwen3.6-35b-a3b:16gb")
        XCTAssertEqual(KapitsaModelStorage.modelName(folderName: "flint"), "flint")
        XCTAssertEqual(KapitsaModelStorage.modelName(folderName: "lmstudio-community--Qwen3.5-2B-MLX-4bit"),
                       "lmstudio-community/Qwen3.5-2B-MLX-4bit", "a Hugging Face repo")
        XCTAssertEqual(KapitsaModelStorage.modelName(folderName: "qwen3.8-27b-ud-q4_k_m"), "qwen3.8-27b-ud-q4_k_m", "a converted GGUF")
    }

    func testScanSizesModelsAndPrefixCache() throws {
        try write(1_000, to: "models/qwen3.8-27b-4bit/model.safetensors")
        try write(200, to: "models/qwen3.8-27b-4bit/dflash2/drafter.safetensors")
        try write(300, to: "models/qwen3.5-4b-4bit/model.safetensors")
        try write(50, to: "prefix-cache/abc/1.bin")
        let storage = KapitsaModelStorage.scan(modelsRoot: root.appendingPathComponent("models"),
                                               prefixCache: root.appendingPathComponent("prefix-cache"))
        XCTAssertEqual(storage.models.map(\.id), ["qwen3.5-4b:4bit", "qwen3.8-27b:4bit"])
        XCTAssertEqual(storage.models.map(\.bytes), [300, 1_200])
        XCTAssertEqual(storage.models.map(\.hasDrafter), [false, true])
        XCTAssertEqual(KapitsaModelStorage.drafters(in: root.appendingPathComponent("models")).map(\.model), ["qwen3.8-27b:4bit"])
        XCTAssertEqual(storage.prefixCacheBytes, 50)
        XCTAssertEqual(KapitsaModelStorage.installedModels(in: root.appendingPathComponent("models")),
                       ["qwen3.5-4b:4bit", "qwen3.8-27b:4bit"])
    }

    func testMissingFoldersScanAsEmpty() {
        let storage = KapitsaModelStorage.scan(modelsRoot: root.appendingPathComponent("none"),
                                               prefixCache: root.appendingPathComponent("none"))
        XCTAssertEqual(storage, KapitsaModelStorage(models: [], prefixCaches: []))
    }

    func testKapitsaHomeMovesTheDataFolder() {
        XCTAssertEqual(KapitsaModelStorage.home(environment: ["KAPITSA_HOME": "/Volumes/X/kapitsa"]).path,
                       "/Volumes/X/kapitsa")
        XCTAssertTrue(KapitsaModelStorage.home(environment: [:]).path.hasSuffix("/.cache/kapitsa"))
    }

    func testPrefixCachePartsNameTheirModelAndOnlyUnusedOnesAreCleared() throws {
        let caches = root.appendingPathComponent("prefix-cache")
        try write(500, to: "prefix-cache/aaa/kv/1.bin")
        try "Kapitsa SSD prefix cache, state format 1\nmodel: /Users/me/.cache/kapitsa/models/qwen3.8-27b-4bit\n  README.md 1 2\n"
            .write(to: caches.appendingPathComponent("aaa/about.txt"), atomically: true, encoding: .utf8)
        try write(0, to: "prefix-cache/aaa/lock")
        try write(80, to: "prefix-cache/bbb/kv/1.bin")
        try write(0, to: "prefix-cache/bbb/lock")

        // A running Kapitsa holds its part's lock.
        let held = open(caches.appendingPathComponent("bbb/lock").path, O_RDONLY)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        defer { close(held) }

        let storage = KapitsaModelStorage.scan(modelsRoot: root.appendingPathComponent("models"), prefixCache: caches)
        XCTAssertEqual(storage.prefixCaches.map(\.model), ["qwen3.8-27b:4bit", nil])
        XCTAssertEqual(storage.prefixCaches.last?.bytes, 80, "the largest part first")
        XCTAssertEqual(storage.prefixCacheBytes, storage.prefixCaches.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(storage.prefixCaches.map(\.inUse), [false, true])
        XCTAssertEqual(storage.prefixCaches.map(\.modelIsGone), [true, false], "/Users/me/… isn't on this Mac")
        XCTAssertEqual(SettingsPage.status(of: storage.prefixCaches[0]), "Model no longer on this Mac")
        XCTAssertEqual(SettingsPage.status(of: storage.prefixCaches[1]), "In use by a running Kapitsa")

        let result = KapitsaModelStorage.clearPrefixCaches(storage.prefixCaches)
        XCTAssertEqual(result.inUse.map(\.id), ["bbb"])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("aaa").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appendingPathComponent("bbb/kv/1.bin").path))
    }

    func testAModelsTwoPrefixCachePartsSayHowEachWroteReplies() throws {
        let caches = root.appendingPathComponent("prefix-cache")
        let model = "model: /Users/me/.cache/kapitsa/models/qwen3.8-27b-4bit\n"
        try write(300, to: "prefix-cache/aaa/kv/1.bin")
        try ("Kapitsa SSD prefix cache\n" + model + "states: qwen35\ndecoding: DFlash2 drafter (4-bit), its context ring\n")
            .write(to: caches.appendingPathComponent("aaa/about.txt"), atomically: true, encoding: .utf8)
        try write(200, to: "prefix-cache/bbb/kv/1.bin")
        try ("Kapitsa SSD prefix cache\n" + model + "decoding: MTP head: its KV rows and gathered draft rows\n")
            .write(to: caches.appendingPathComponent("bbb/about.txt"), atomically: true, encoding: .utf8)
        try write(100, to: "prefix-cache/ccc/kv/1.bin")
        try ("Kapitsa SSD prefix cache\nmodel: /x/qwen3.5-4b-4bit\ndecoding: no drafter\n")
            .write(to: caches.appendingPathComponent("ccc/about.txt"), atomically: true, encoding: .utf8)

        var parts = KapitsaModelStorage.scan(modelsRoot: root.appendingPathComponent("models"), prefixCache: caches).prefixCaches
        XCTAssertEqual(parts.map(\.model), ["qwen3.8-27b:4bit", "qwen3.8-27b:4bit", "qwen3.5-4b:4bit"])
        XCTAssertEqual(SettingsPage.details(of: parts[1])?.hasPrefix("With the model's MTP head · "), true,
                       "a model without a drafter only ever uses its MTP head")
        parts[1].modelHasDrafter = true
        XCTAssertEqual(parts.map(\.decoding), [.drafter, .mtp, .plain])
        XCTAssertNotNil(parts[0].lastUsed)

        let details = parts.map { SettingsPage.details(of: $0) ?? "" }
        XCTAssertTrue(details[0].hasPrefix("With the DFlash2 drafter · last used "), details[0])
        XCTAssertTrue(details[1].hasPrefix("Without the drafter (MTP), from a context too large for the drafter · last used "), details[1])
        XCTAssertTrue(details[2].hasPrefix("No drafter · last used "), details[2])
    }
}
