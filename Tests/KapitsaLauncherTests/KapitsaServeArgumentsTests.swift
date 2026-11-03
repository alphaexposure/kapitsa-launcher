import XCTest
@testable import KapitsaLauncher

final class KapitsaServeArgumentsTests: XCTestCase {
    func testDefaultsLeaveTheModelChoiceToKapitsa() {
        XCTAssertEqual(KapitsaServeArguments.serveArguments(KapitsaConfiguration()),
                       ["serve", "--host", "127.0.0.1", "--port", "8000"])
    }

    func testEverySettingBecomesItsOwnArgument() {
        var configuration = KapitsaConfiguration()
        configuration.model = "27b:8bit"
        configuration.host = "0.0.0.0"
        configuration.port = 9001
        configuration.modelID = "qwen"
        configuration.context = "128k"
        configuration.slots = "2"
        configuration.dflash = "none"
        configuration.memBudget = "24"
        configuration.prefillChunk = "1024"
        configuration.diskCache = "16G"
        configuration.allowSwitch = true
        XCTAssertEqual(KapitsaServeArguments.serveArguments(configuration), [
            "serve", "--model", "27b:8bit", "--host", "0.0.0.0", "--port", "9001",
            "--model-id", "qwen", "--context", "128k", "--slots", "2", "--dflash", "none",
            "--mem-budget", "24", "--prefill-chunk", "1024", "--disk-cache", "16G", "--allow-switch",
        ])
    }

    func testModelPathWithSpacesStaysOneArgument() {
        var configuration = KapitsaConfiguration()
        configuration.model = "/Users/me/My Models/x.gguf"
        let arguments = KapitsaServeArguments.serveArguments(configuration)
        XCTAssertEqual(arguments[1...2], ["--model", "/Users/me/My Models/x.gguf"])
    }

    func testAPIKeyIsNeverAnArgument() {
        XCTAssertFalse(KapitsaServeArguments.serveArguments(KapitsaConfiguration()).contains("--api-key"))
    }

    func testADownloadedCatalogModelStartsByItsFullName() {
        let installed = ["lmstudio-community/Qwen3.5-2B-MLX-4bit", "qwen3.6-35b-a3b:16gb", "qwen3.6-35b-a3b:4bit"]
        // The default precision when it's here, by the short name or Kapitsa's.
        XCTAssertEqual(KapitsaServeArguments.modelArgument("35b", installed: installed), "qwen3.6-35b-a3b:4bit")
        XCTAssertEqual(KapitsaServeArguments.modelArgument("qwen3.6-35b-a3b", installed: installed), "qwen3.6-35b-a3b:4bit")
        // Else the precision that is here.
        XCTAssertEqual(KapitsaServeArguments.modelArgument("35b", installed: ["qwen3.6-35b-a3b:16gb"]), "qwen3.6-35b-a3b:16gb")
        // Not downloaded yet: Kapitsa picks what fits.
        XCTAssertEqual(KapitsaServeArguments.modelArgument("27b", installed: installed), "27b")
        // A chosen precision, a repo or a path stays as it is.
        XCTAssertEqual(KapitsaServeArguments.modelArgument("35b:8bit", installed: installed), "35b:8bit")
        XCTAssertEqual(KapitsaServeArguments.modelArgument("lmstudio-community/Qwen3.5-2B-MLX-4bit", installed: installed),
                       "lmstudio-community/Qwen3.5-2B-MLX-4bit")

        var configuration = KapitsaConfiguration()
        configuration.model = "35b"
        XCTAssertEqual(KapitsaServeArguments.serveArguments(configuration, installed: installed)[1...2],
                       ["--model", "qwen3.6-35b-a3b:4bit"])
    }
}
