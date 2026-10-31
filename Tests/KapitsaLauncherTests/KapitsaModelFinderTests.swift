import XCTest
@testable import KapitsaLauncher

final class KapitsaModelFinderTests: XCTestCase {
    private func folder(config: [String: Any]?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let config { try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json")) }
        return url
    }

    func testAcceptsWhatKapitsaRunsAndExplainsWhatItDoesnt() throws {
        XCTAssertEqual(KapitsaModelFinder.check(try folder(config: ["model_type": "qwen3_5"])), .ok, "the 2B and 27B")
        XCTAssertEqual(KapitsaModelFinder.check(try folder(config: ["model_type": "qwen3_5_moe"])), .ok, "the 35B")
        XCTAssertEqual(KapitsaModelFinder.check(try folder(config: ["model_type": "x", "text_config": ["model_type": "qwen3_5_text"]])), .ok)

        guard case .problem(let gemma) = KapitsaModelFinder.check(try folder(config: ["model_type": "gemma4_unified"])) else {
            return XCTFail("Gemma is refused")
        }
        XCTAssertTrue(gemma.contains("gemma4_unified"))
        guard case .problem = KapitsaModelFinder.check(try folder(config: nil)) else { return XCTFail("no config.json") }
        guard case .note = KapitsaModelFinder.check(try folder(config: ["hidden_size": 1])) else { return XCTFail("unnamed") }
        guard case .note = KapitsaModelFinder.check(URL(fileURLWithPath: "/x/model-Q4_K_M.gguf")) else { return XCTFail("a GGUF") }
    }

    func testFindsTheModelInsideAFolderChosenHigherUp() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("models--unsloth--Qwen3.8-27B-GGUF")
        let blobs = repo.appendingPathComponent("blobs"), snapshot = repo.appendingPathComponent("snapshots/4ca7")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (name, blob) in [("Qwen3.8-27B-UD-Q4_K_M.gguf", "aaa"), ("mmproj-BF16.gguf", "bbb")] {
            try Data().write(to: blobs.appendingPathComponent(blob))
            try fm.createSymbolicLink(at: snapshot.appendingPathComponent(name), withDestinationURL: blobs.appendingPathComponent(blob))
        }
        XCTAssertEqual(try KapitsaModelFinder.resolve(repo).get().lastPathComponent, "Qwen3.8-27B-UD-Q4_K_M.gguf",
                       "three levels down, the image part and the hashed blobs left out")
        XCTAssertEqual(try KapitsaModelFinder.resolve(snapshot.appendingPathComponent("Qwen3.8-27B-UD-Q4_K_M.gguf")).get().lastPathComponent,
                       "Qwen3.8-27B-UD-Q4_K_M.gguf")
        XCTAssertThrowsError(try KapitsaModelFinder.resolve(snapshot.appendingPathComponent("mmproj-BF16.gguf")).get(), "the image part alone")

        // A folder of several models asks for one of them.
        let models = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["Qwen3.5-9B-MLX-4bit", "gemma-4-12B-it-MLX-4bit"] {
            let folder = models.appendingPathComponent("org").appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        }
        XCTAssertThrowsError(try KapitsaModelFinder.resolve(models).get())
        XCTAssertEqual(try KapitsaModelFinder.resolve(models.appendingPathComponent("org/Qwen3.5-9B-MLX-4bit")).get().lastPathComponent,
                       "Qwen3.5-9B-MLX-4bit")
    }

    func testSplitFilesCountOnce() {
        XCTAssertFalse(KapitsaModelFinder.isPart("model-00001-of-00003.gguf"))
        XCTAssertTrue(KapitsaModelFinder.isPart("model-00002-of-00003.gguf"))
        XCTAssertTrue(KapitsaModelFinder.isPart("mtp-model-Q4_0.gguf"))
    }
}
