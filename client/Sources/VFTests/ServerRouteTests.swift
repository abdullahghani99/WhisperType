import Foundation
import WhisperTypeKit

/// Choosing the route must be predictable: a test harness has to be able to
/// override it, the speaker's choice has to stick, and a machine that has never
/// chosen must land somewhere that works.
final class ServerRouteTests: XCTestCase {

    func testAnEnvironmentOverrideWinsOverEverything() {
        let (url, _, _) = ServerRoute.resolve(environment: ["VF_SERVER_URL": "http://127.0.0.1:18790"],
                                           stored: "tailscale")
        XCTAssertEqual(url, "http://127.0.0.1:18790")
    }

    func testTheOverrideIsRecognisedWhenItMatchesAKnownRoute() {
        let (_, route, _) = ServerRoute.resolve(environment: ["VF_SERVER_URL": ServerRoute.tailscale.url],
                                             stored: nil)
        XCTAssertEqual(route, .tailscale)
    }

    func testTheStoredChoiceIsHonoured() {
        let (url, route, _) = ServerRoute.resolve(environment: [:], stored: "tailscale")
        XCTAssertEqual(route, .tailscale)
        XCTAssertEqual(url, "http://198.51.100.10:8790")
    }

    func testWithNoChoiceTheRouteIsAutomatic() {
        // A pinned office route broke every dictation on 2026-11-12.
        for stored in [nil, ServerRoute.automatic, "carrier-pigeon"] {
            let (url, route, pinned) = ServerRoute.resolve(environment: [:], stored: stored)
            XCTAssertNil(route); XCTAssertFalse(pinned)
            XCTAssertEqual(url, ServerRoute.tailscale.url)
        }
    }

    func testTheSelectorTakesTheFirstRouteThatAnswers() {
        let routes = RouteSelector(candidates: ["a", "b"])
        // The runner has no async support; block on the probe instead.
        func probe(_ up: @escaping @Sendable (String) -> Bool) -> String {
            final class Box: @unchecked Sendable { var value = "" }
            let box = Box(), done = DispatchSemaphore(value: 0)
            Task { box.value = await routes.reselect { up($0) }; done.signal() }
            done.wait(); return box.value
        }
        XCTAssertEqual(probe { $0 == "b" }, "b")
        // Back up: preference order wins again.
        XCTAssertEqual(probe { _ in true }, "a")
        // Nothing answers (offline): stay put rather than flap.
        _ = probe { $0 == "b" }
        XCTAssertEqual(probe { _ in false }, "b")
    }

    func testEveryRouteHasAUsableURL() {
        for route in ServerRoute.allCases {
            XCTAssertNotNil(URL(string: route.url), "\(route) has an unusable URL")
            XCTAssertFalse(route.title.isEmpty)
        }
    }
}
