import XCTest

/// The Anthropic API key used to be baked into the shell script as
/// `export ANTHROPIC_API_KEY='…'`, and that script is handed to zsh as a
/// process ARGUMENT. argv is readable by any process running as the same user
/// (`ps auxww`) and is captured in sysdiagnose bundles, crash logs and screen
/// recordings, which defeats storing the key in the Keychain at all (#81).
///
/// The value now travels in the subprocess environment; only the name of the
/// variable appears in the script.
final class APIKeyDeliveryTests: XCTestCase {

    private let secret = "sk-ant-test-SUPERSECRET-0123456789"

    func testTheKeyValueNeverAppearsInTheScript() {
        let delivery = PythonBridge.apiKeyDelivery(secret)

        XCTAssertFalse(delivery.scriptLines.contains(secret),
                       "the script becomes argv, which any process on this Mac can read")
    }

    func testTheKeyIsDeliveredThroughTheEnvironment() {
        let delivery = PythonBridge.apiKeyDelivery(secret)

        XCTAssertEqual(delivery.environment.values.first, secret)
        XCTAssertFalse(delivery.environment.isEmpty)
    }

    func testTheScriptPromotesTheCarrierAfterTheProfileIsSourced() {
        let delivery = PythonBridge.apiKeyDelivery(secret)

        XCTAssertTrue(delivery.scriptLines.contains("ANTHROPIC_API_KEY"),
                      "Python still reads the standard variable name")
        let carrier = try? XCTUnwrap(delivery.environment.keys.first)
        XCTAssertTrue(delivery.scriptLines.contains(carrier ?? "!"),
                      "the script has to read the carrier the environment sets")
        XCTAssertTrue(delivery.scriptLines.contains("unset"),
                      "the carrier is cleared so it isn't inherited further down")
    }

    func testNoKeyMeansNoEnvironmentEntryAndNoScriptLines() {
        let delivery = PythonBridge.apiKeyDelivery(nil)

        XCTAssertTrue(delivery.environment.isEmpty)
        XCTAssertTrue(delivery.scriptLines.isEmpty,
                      "with no stored key the shell profile's own export must stand")
    }

    func testAnEmptyStoredKeyIsTreatedAsNoKey() {
        // A blank Keychain entry must not export an empty ANTHROPIC_API_KEY over
        // whatever the user's profile provides: that turns a working setup into
        // an authentication failure.
        let delivery = PythonBridge.apiKeyDelivery("   ")

        XCTAssertTrue(delivery.environment.isEmpty)
        XCTAssertTrue(delivery.scriptLines.isEmpty)
    }
}
