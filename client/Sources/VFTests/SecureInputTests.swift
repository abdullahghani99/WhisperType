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
        for holder in ["Terminal", "loginwindow", nil] {
            let message = SecureInput.message(holder: holder)
            XCTAssertTrue(message.contains("Review result"))
            XCTAssertTrue(message.contains("Copy result"))
            XCTAssertTrue(message.contains("dictation is saved"))
            XCTAssertFalse(message.contains("nothing can type"))
        }
    }

    func testLoginwindowGetsLockAdviceNotQuit() {
        // Quitting loginwindow logs the speaker out; lock/unlock is a recovery
        // attempt, not a guarantee about what macOS will do.
        let message = SecureInput.message(holder: "loginwindow")
        XCTAssertTrue(message.contains("Ctrl+Cmd+Q"), message)
        XCTAssertFalse(message.contains("quit"), message)
        XCTAssertTrue(message.contains("Try locking"), message)
    }
}
