import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaConfigurationTests: XCTestCase {
    func testDefaultsAreValidAndLocal() {
        let configuration = KapitsaConfiguration()
        XCTAssertNil(configuration.validationError)
        XCTAssertEqual(configuration.model, "")
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8000)
        XCTAssertTrue(configuration.isLocalHost)
    }

    func testAcceptsKapitsaModelForms() {
        for model in ["27b", "35b:8bit", "qwen3.8-27b:4bit", "org/name@main", "/Users/me/model", "~/m.gguf"] {
            var configuration = KapitsaConfiguration()
            configuration.model = model
            XCTAssertNil(configuration.validationError, model)
        }
    }

    func testRejectsValuesThatWouldReadAsOptionsOrBreakArguments() {
        var configuration = KapitsaConfiguration()
        configuration.model = "--host"
        XCTAssertNotNil(configuration.validationError)
        configuration.model = "27b extra"
        XCTAssertNotNil(configuration.validationError)
        configuration = KapitsaConfiguration()
        configuration.modelID = "-x"
        XCTAssertNotNil(configuration.validationError)
        configuration = KapitsaConfiguration()
        configuration.host = "-0.0.0.0"
        XCTAssertNotNil(configuration.validationError)
    }

    func testValidatesNumericSettings() {
        func error(_ change: (inout KapitsaConfiguration) -> Void) -> String? {
            var configuration = KapitsaConfiguration()
            change(&configuration)
            return configuration.validationError
        }
        XCTAssertNil(error { $0.context = "128k" })
        XCTAssertNil(error { $0.context = "1m" })
        XCTAssertNil(error { $0.context = "max" })
        XCTAssertNil(error { $0.context = "32768" })
        XCTAssertNotNil(error { $0.context = "lots" })
        XCTAssertNil(error { $0.slots = "2" })
        XCTAssertNotNil(error { $0.slots = "0" })
        XCTAssertNil(error { $0.memBudget = "24.5" })
        XCTAssertNotNil(error { $0.memBudget = "24GB" })
        XCTAssertNil(error { $0.prefillChunk = "1024" })
        XCTAssertNotNil(error { $0.prefillChunk = "big" })
        XCTAssertNil(error { $0.diskCache = "16G" })
        XCTAssertNil(error { $0.diskCache = "0" })
        XCTAssertNil(error { $0.diskCache = "auto" })
        XCTAssertNotNil(error { $0.diskCache = "-1" })
        XCTAssertNotNil(error { $0.dflash = "/tmp/drafter" })
        XCTAssertNotNil(error { $0.port = 0 })
        XCTAssertNotNil(error { $0.host = " " })
    }

    func testSettingsRoundTripAndOldSettingsKeepDefaults() throws {
        let defaults = UserDefaults(suiteName: "KapitsaConfigurationTests")!
        defaults.removePersistentDomain(forName: "KapitsaConfigurationTests")
        let store = KapitsaSettingsStore(defaults: defaults)
        var configuration = KapitsaConfiguration()
        configuration.model = "35b"
        configuration.allowSwitch = true
        store.saveConfiguration(configuration)
        XCTAssertEqual(store.loadConfiguration(), configuration)

        let partial = try XCTUnwrap(#"{"model":"9b","port":9000}"#.data(using: .utf8))
        let decoded = try JSONDecoder().decode(KapitsaConfiguration.self, from: partial)
        XCTAssertEqual(decoded.model, "9b")
        XCTAssertEqual(decoded.port, 9000)
        XCTAssertEqual(decoded.host, "127.0.0.1")
        XCTAssertEqual(decoded.dflash, "auto")
    }

    func testCatalogMenuDescribesEachModelAndWarnsWhenItIsTooBig() throws {
        let model = try XCTUnwrap(KapitsaConfiguration.catalogModels.first { $0.name == "35b" })
        XCTAssertEqual(model.details(physicalMemoryGB: 32), "MoE, 3B active · 4-bit · 22.1 GB · 32 GB+ Mac")
        let flash = try XCTUnwrap(KapitsaConfiguration.catalogModels.first { $0.name == "flash" })
        XCTAssertTrue(flash.details(physicalMemoryGB: 32).hasSuffix("· too big for this Mac"))
        XCTAssertEqual(KapitsaConfiguration.catalogModel(forDownloaded: "qwen3.8-27b:4bit")?.name, "27b")
        XCTAssertNil(KapitsaConfiguration.catalogModel(forDownloaded: "someone/custom-model"))
        XCTAssertEqual(Set(KapitsaConfiguration.catalogModels.map(\.name)).count, KapitsaConfiguration.catalogModels.count)
    }
}
