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
        XCTAssertEqual(storage.prefixCacheBytes, 50)
        XCTAssertEqual(KapitsaModelStorage.installedModels(in: root.appendingPathComponent("models")),
                       ["qwen3.5-4b:4bit", "qwen3.8-27b:4bit"])
    }

    func testMissingFoldersScanAsEmpty() {
        let storage = KapitsaModelStorage.scan(modelsRoot: root.appendingPathComponent("none"),
                                               prefixCache: root.appendingPathComponent("none"))
        XCTAssertEqual(storage, KapitsaModelStorage(models: [], prefixCacheBytes: 0))
    }

    func testKapitsaHomeMovesTheDataFolder() {
        XCTAssertEqual(KapitsaModelStorage.home(environment: ["KAPITSA_HOME": "/Volumes/X/kapitsa"]).path,
                       "/Volumes/X/kapitsa")
        XCTAssertTrue(KapitsaModelStorage.home(environment: [:]).path.hasSuffix("/.cache/kapitsa"))
    }
}
