
import WhisperTypeKit

final class SpeakerTextTests: XCTestCase {
    func testExtractsSpeakerNamesInFirstAppearanceOrder() {
        let t = """
        **Speaker 1:** hello there
        **Alex:** the reconciliation sheet is ready
        **Speaker 1:** good
        """
        XCTAssertEqual(SpeakerText.names(in: t), ["Speaker 1", "Alex"])
    }

    func testReturnsEmptyWhenThereAreNoLabels() {
        XCTAssertEqual(SpeakerText.names(in: "just prose, no labels"), [])
        XCTAssertEqual(SpeakerText.names(in: ""), [])
    }

    func testIgnoresBoldThatIsNotASpeakerLabel() {
        // Notes headings are bold but are not speakers.
        XCTAssertEqual(SpeakerText.names(in: "**Summary**\nsome text"), [])
    }
}
