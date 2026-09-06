import Foundation
import WhisperTypeKit

final class SpokenListTests: XCTestCase {
    private let example = "Then I want to talk about two things. One, how do we achieve it? Two, when do we achieve it?"

    func testExplicitQuestionsKeepWordingAndDoNotAnswer() {
        XCTAssertEqual(SpokenListFormatter.format(example, destinationName: "ChatGPT"), "Then I want to talk about two things.\n\n1. how do we achieve it?\n2. when do we achieve it?")
    }

    func testCompleteThreeItemSequencePreservesNumbersAndUnicode() {
        XCTAssertTrue(SpokenListFormatter.format(example, destinationName: "Codex").contains("\n1. "))
        XCTAssertEqual(SpokenListFormatter.format("Three points: One, café costs 20. Two, keep 2 copies. Three, ask María.", destinationName: "TextEdit"), "Three points:\n\n1. café costs 20.\n2. keep 2 copies.\n3. ask María.")
    }

    func testAmbiguousIncompleteOrAlreadyFormattedTextStaysUnchanged() {
        for text in ["One, how? Two, when?", "I have two things and one is blue, two are red.", "Two things. One, how?", "Two things. Two, when? One, how?", "Two things. One, how? Two, when? Three, why?", "Two things.\n1. How?\n2. When?", "Two things. One, how?\nTwo, when?"] {
            XCTAssertEqual(SpokenListFormatter.format(text, destinationName: "ChatGPT"), text)
        }
    }

    func testCodeTerminalAndUnknownDestinationsStayUnchanged() {
        for app in ["Warp", "Terminal", "iTerm2", "Visual Studio Code", "Xcode", "Cursor", "Zed", "PyCharm"] {
            XCTAssertEqual(SpokenListFormatter.format(example, destinationName: app), example)
        }
        XCTAssertEqual(SpokenListFormatter.format(example, destinationName: nil), example)
        for prefix in ["Run this command. ", "Here is code. ", "`example` ", "$ ", "<tag> "] {
            XCTAssertEqual(SpokenListFormatter.format(prefix + example, destinationName: "ChatGPT"), prefix + example)
        }
    }
}
