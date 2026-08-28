import XCTest
@testable import WhisperTypeKit

/// Turning a process name into something a human wants to read. The shipped
/// version rendered "Microsoft Teams ModuleHost call" — and, when nothing was
/// detected, the string "a call call". Both are the kind of detail that decides
/// whether a product feels considered or careless.
final class CallSourceTests: XCTestCase {

    func testHelperProcessNamesBecomeTheAppTheyBelongTo() {
        XCTAssertEqual(CallSource.friendlyName("Microsoft Teams ModuleHost"), "Teams")
        XCTAssertEqual(CallSource.friendlyName("Microsoft Teams"), "Teams")
        XCTAssertEqual(CallSource.friendlyName("Microsoft Teams (work or school)"), "Teams")
        XCTAssertEqual(CallSource.friendlyName("zoom.us"), "Zoom")
        XCTAssertEqual(CallSource.friendlyName("Google Chrome Helper (Renderer)"), "Chrome")
        XCTAssertEqual(CallSource.friendlyName("Slack Helper"), "Slack")
        XCTAssertEqual(CallSource.friendlyName("FaceTime"), "FaceTime")
    }

    func testUnknownAppsKeepTheirNameRatherThanBecomingGeneric() {
        // Better to name something unfamiliar than to say "a call" and make the
        // human wonder what we actually heard.
        XCTAssertEqual(CallSource.friendlyName("Acme Meet"), "Acme Meet")
    }

    func testTrailingHelperSuffixesAreStripped() {
        XCTAssertEqual(CallSource.friendlyName("Webex Helper (Plugin)"), "Webex")
        XCTAssertEqual(CallSource.friendlyName("Discord Helper (Renderer)"), "Discord")
    }

    func testTheOfferLineNeverReadsLikeAGlitch() {
        // "a call call" shipped. The label builder must be incapable of it.
        XCTAssertEqual(CallSource.offerTitle(for: "Microsoft Teams ModuleHost"), "Teams call")
        XCTAssertEqual(CallSource.offerTitle(for: "FaceTime"), "FaceTime call")
        XCTAssertEqual(CallSource.offerTitle(for: ""), "Call detected")
        XCTAssertEqual(CallSource.offerTitle(for: "a call"), "Call detected")
        XCTAssertFalse(CallSource.offerTitle(for: "Zoom call").contains("call call"))
    }

    /// A background daemon has no app name, so we used to render "pid 3990 call"
    /// — Apple's Siri speech daemon, which holds the mic all day.
    func testAProcessIdIsNeverShownAsACall() {
        XCTAssertEqual(CallSource.offerTitle(for: "pid 3990"), "Call detected")
        XCTAssertEqual(CallSource.offerTitle(for: "pid 12"), "Call detected")
    }

    func testAppNamesAlreadyEndingInCallAreNotDoubled() {
        XCTAssertEqual(CallSource.offerTitle(for: "Zoom call"), "Zoom call")
    }
}
