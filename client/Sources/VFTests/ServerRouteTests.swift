import Foundation
import WhisperTypeKit

/// Choosing the route must be predictable: a test harness has to be able to
/// override it, the speaker's choice has to stick, and a machine that has never
/// chosen must land somewhere that works.
final class ServerRouteTests: XCTestCase {

    func testAnEnvironmentOverrideWinsOverEverything() {
        let (url, _) = ServerRoute.resolve(environment: ["VF_SERVER_URL": "http://127.0.0.1:18790"],
                                           stored: "tailscale")
        XCTAssertEqual(url, "http://127.0.0.1:18790")
    }

    func testTheOverrideIsRecognisedWhenItMatchesAKnownRoute() {
        let (_, route) = ServerRoute.resolve(environment: ["VF_SERVER_URL": ServerRoute.tailscale.url],
                                             stored: nil)
        XCTAssertEqual(route, .tailscale)
    }

    func testTheStoredChoiceIsHonoured() {
        let (url, route) = ServerRoute.resolve(environment: [:], stored: "tailscale")
        XCTAssertEqual(route, .tailscale)
        XCTAssertEqual(url, "http://198.51.100.10:8790")
    }

    func testWithNoChoiceItUsesTheOfficeRoute() {
        // Office works on the LAN and, through WARP, away from it. Tailscale was
        // the old default and is the one that failed.
        let (url, route) = ServerRoute.resolve(environment: [:], stored: nil)
        XCTAssertEqual(route, .office)
        XCTAssertEqual(url, "http://192.0.2.10:8790")
    }

    func testAnUnknownStoredValueDoesNotStrandTheClient() {
        let (_, route) = ServerRoute.resolve(environment: [:], stored: "carrier-pigeon")
        XCTAssertEqual(route, .office)
    }

    func testEveryRouteHasAUsableURL() {
        for route in ServerRoute.allCases {
            XCTAssertNotNil(URL(string: route.url), "\(route) has an unusable URL")
            XCTAssertFalse(route.title.isEmpty)
        }
    }
}
