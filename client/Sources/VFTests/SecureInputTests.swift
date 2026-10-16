import Foundation
import WhisperTypeKit

/// The secure-input message is the only thing the speaker gets when insertion
/// is blocked system-wide, and the previous wording sent them to the wrong
/// machine. It has to name the holder when macOS gives one and still read as a
/// sentence when it does not.
final class SecureInputTests: XCTestCase {

    func testItNamesTheAppHoldingTheLock() {
        let message = SecureInput.message(holder: "Warp")
        XCTAssertTrue(message.hasPrefix("Warp has macOS secure input on"), message)
    }

    func testItStillReadsAsASentenceWhenTheHolderIsUnknown() {
        let message = SecureInput.message(holder: nil)
        XCTAssertTrue(message.hasPrefix("An app has macOS secure input on"), message)
        XCTAssertFalse(message.contains("nil"), message)
    }

    func testItNoLongerGuessesAtTheCause() {
        // It used to say "often on the shared screen" and was wrong for six days.
        for holder in ["Warp", nil] {
            XCTAssertFalse(SecureInput.message(holder: holder).contains("shared screen"))
        }
    }

    func testItPointsAtTheRemedy() {
        XCTAssertTrue(SecureInput.message(holder: "Terminal").contains("Review result"))
    }
}
