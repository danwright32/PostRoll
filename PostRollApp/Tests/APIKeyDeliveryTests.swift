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
        let delivery = PythonBridge.secretDelivery([(variable: "ANTHROPIC_API_KEY", value: secret)])

        XCTAssertFalse(delivery.scriptLines.contains(secret),
                       "the script becomes argv, which any process on this Mac can read")
    }

    func testTheKeyIsDeliveredThroughTheEnvironment() {
        let delivery = PythonBridge.secretDelivery([(variable: "ANTHROPIC_API_KEY", value: secret)])

        XCTAssertEqual(delivery.environment.values.first, secret)
        XCTAssertFalse(delivery.environment.isEmpty)
    }

    func testTheScriptPromotesTheCarrierAfterTheProfileIsSourced() {
        let delivery = PythonBridge.secretDelivery([(variable: "ANTHROPIC_API_KEY", value: secret)])

        XCTAssertTrue(delivery.scriptLines.contains("ANTHROPIC_API_KEY"),
                      "Python still reads the standard variable name")
        let carrier = try? XCTUnwrap(delivery.environment.keys.first)
        XCTAssertTrue(delivery.scriptLines.contains(carrier ?? "!"),
                      "the script has to read the carrier the environment sets")
        XCTAssertTrue(delivery.scriptLines.contains("unset"),
                      "the carrier is cleared so it isn't inherited further down")
    }

    func testNoKeyMeansNoEnvironmentEntryAndNoScriptLines() {
        let delivery = PythonBridge.secretDelivery([(variable: "ANTHROPIC_API_KEY", value: nil)])

        XCTAssertTrue(delivery.environment.isEmpty)
        XCTAssertTrue(delivery.scriptLines.isEmpty,
                      "with no stored key the shell profile's own export must stand")
    }

    func testAnEmptyStoredKeyIsTreatedAsNoKey() {
        // A blank Keychain entry must not export an empty ANTHROPIC_API_KEY over
        // whatever the user's profile provides: that turns a working setup into
        // an authentication failure.
        let delivery = PythonBridge.secretDelivery([(variable: "ANTHROPIC_API_KEY", value: "   ")])

        XCTAssertTrue(delivery.environment.isEmpty)
        XCTAssertTrue(delivery.scriptLines.isEmpty)
    }

    // MARK: - The Meta token travels the same way (#1002)

    private let metaToken = "EAA" + String(repeating: "x", count: 196)

    func testTheMetaTokenNeverAppearsInTheScriptEither() {
        // The same argv exposure #81 was about. A second secret delivered by
        // copying the shape rather than reusing it is how one of the two ends
        // up interpolated into the script text.
        let delivery = PythonBridge.secretDelivery([
            (variable: "ANTHROPIC_API_KEY", value: secret),
            (variable: "META_SYSTEM_USER_TOKEN", value: metaToken),
        ])

        XCTAssertFalse(delivery.scriptLines.contains(metaToken))
        XCTAssertFalse(delivery.scriptLines.contains(secret))
    }

    func testBothSecretsReachTheSubprocessUnderTheirOwnNames() {
        let delivery = PythonBridge.secretDelivery([
            (variable: "ANTHROPIC_API_KEY", value: secret),
            (variable: "META_SYSTEM_USER_TOKEN", value: metaToken),
        ])

        XCTAssertEqual(delivery.environment.values.sorted(), [metaToken, secret].sorted())
        XCTAssertTrue(delivery.scriptLines.contains("export ANTHROPIC_API_KEY="))
        XCTAssertTrue(delivery.scriptLines.contains("export META_SYSTEM_USER_TOKEN="))
    }

    func testOneSecretMissingDoesNotStopTheOtherBeingDelivered() {
        // The live case for a while: the Anthropic key is set up and the Meta
        // token is not. An all or nothing delivery would silently take away
        // generation from anybody who had not minted a token yet.
        let delivery = PythonBridge.secretDelivery([
            (variable: "ANTHROPIC_API_KEY", value: secret),
            (variable: "META_SYSTEM_USER_TOKEN", value: nil),
        ])

        XCTAssertEqual(delivery.environment.count, 1)
        XCTAssertEqual(delivery.environment.values.first, secret)
        XCTAssertFalse(delivery.scriptLines.contains("META_SYSTEM_USER_TOKEN"),
                       "a variable with no value must not be exported as empty: the "
                       + "fetch would then see a set but blank token and report it as "
                       + "rejected rather than as absent")
    }

    func testEachSecretCarriesItsOwnCarrierName() {
        // Two secrets sharing one carrier would have the second overwrite the
        // first in the environment, and the symptom is an authentication
        // failure in whichever ran second.
        let delivery = PythonBridge.secretDelivery([
            (variable: "ANTHROPIC_API_KEY", value: secret),
            (variable: "META_SYSTEM_USER_TOKEN", value: metaToken),
        ])

        XCTAssertEqual(Set(delivery.environment.keys).count, 2)
    }
}
