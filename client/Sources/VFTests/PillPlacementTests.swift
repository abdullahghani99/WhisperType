import Foundation
import WhisperTypeKit

final class PillPlacementTests: XCTestCase {
    func testFourEdgesKeepCompactAndExpandedCapsulesVisible() {
        let frame = CGRect(x: -1720, y: 38, width: 1720, height: 1030)
        for size in [CGSize(width: 44, height: 24), CGSize(width: 588, height: 58)] {
            for edge in [PillEdge.top, .bottom, .left, .right] {
                let point = PillGeometry.center(edge: edge, size: size, in: frame)
                let body = CGRect(x: point.x-size.width/2, y: point.y-size.height/2, width: size.width, height: size.height)
                XCTAssertTrue(frame.contains(body))
                if edge == .left || edge == .right { XCTAssertEqual(point.y, frame.midY) }
                else { XCTAssertEqual(point.x, frame.midX) }
                if edge == .left { XCTAssertEqual(body.minX, frame.minX + 14) }
                if edge == .right { XCTAssertEqual(body.maxX, frame.maxX - 14) }
                if edge == .top { XCTAssertEqual(body.maxY, frame.maxY - 14) }
                if edge == .bottom { XCTAssertEqual(body.minY, frame.minY + 14) }
            }
        }
    }
    func testLegacyFreeMigratesOnItsOwnDisplayAndStaysCentredAfterResolutionChange() {
        let name = "vf.pill.test." + UUID().uuidString; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let raw = #"{"display":"display-B","choices":{"display-A":{"edge":"free","x":0.1,"y":0.6},"display-B":{"edge":"free","x":0.9,"y":0.4}}}"#
        defaults.set(Data(raw.utf8), forKey: PillPlacement.key)
        let store = PillPlacement(store: defaults)
        XCTAssertNil(store.choice(for: "display-B")) // No migration using an unrelated screen.
        let frame = CGRect(x: -1600, y: -900, width: 1600, height: 900)
        XCTAssertEqual(store.choice(for: "display-B", in: frame)?.edge, .right)
        XCTAssertEqual(store.preferredDisplay, "display-B")
        let restored = PillPlacement(store: defaults)
        XCTAssertEqual(restored.choice(for: "display-B")?.edge, .right)
        XCTAssertEqual(restored.choice(for: "display-A", in: frame)?.edge, .left)
        XCTAssertEqual(restored.preferredDisplay, "display-B")
        let resized = CGRect(x: 2000, y: 60, width: 1200, height: 800)
        let point = PillGeometry.center(edge: .right, size: CGSize(width: 571, height: 40), in: resized)
        XCTAssertEqual(point.y, resized.midY)
        XCTAssertEqual(PillEdge.allCases.count, 4)
        XCTAssertNil(PillEdge(rawValue: "free"))
    }
    func testNearestEdgeHasStableCornerHysteresis() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(PillGeometry.nearestEdge(to: CGPoint(x: 720, y: 895), in: frame), .top)
        XCTAssertEqual(PillGeometry.nearestEdge(to: CGPoint(x: 4, y: 450), in: frame), .left)
        XCTAssertEqual(PillGeometry.nearestEdge(to: CGPoint(x: 1430, y: 450), in: frame), .right)
        XCTAssertEqual(PillGeometry.nearestEdge(to: CGPoint(x: 720, y: 5), in: frame), .bottom)
        XCTAssertEqual(PillGeometry.nearestEdge(to: CGPoint(x: 10, y: 15), in: frame, previous: .bottom), .bottom)
    }
    func testSmallVisibleFrameNeverProducesInvertedClamp() {
        let frame = CGRect(x: -40, y: 20, width: 80, height: 40)
        let p = PillGeometry.clamp(CGPoint(x: 10000, y: -10000), size: CGSize(width: 600, height: 100), in: frame)
        XCTAssertEqual(p.x, frame.midX); XCTAssertEqual(p.y, frame.midY)
    }
    func testSavedChoiceAndChosenDisplaySurviveRelaunch() {
        let name = "vf.pill.test." + UUID().uuidString; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PillPlacement(store: defaults)
        store.remember(.init(edge: .left), display: "display-A")
        store.remember(.init(edge: .right), display: "display-B")
        let restored = PillPlacement(store: defaults)
        XCTAssertEqual(restored.preferredDisplay, "display-B")
        XCTAssertEqual(restored.choice(for: "display-A")?.edge, .left)
        XCTAssertEqual(restored.choice(for: "display-B"), .init(edge: .right))
        XCTAssertNil(restored.choice(for: "disconnected-C"))
    }
    func testCorruptPreferenceAndNonfiniteInputCannotStrandPill() {
        let name = "vf.pill.test." + UUID().uuidString; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: PillPlacement.key)
        defaults.set(["legacy": ["x": 23.0, "y": 45.0]], forKey: "vf_dockPositions")
        let store = PillPlacement(store: defaults)
        XCTAssertNil(store.preferredDisplay)
        store.remember(.init(edge: .bottom, x: .infinity, y: 0), display: "bad")
        XCTAssertNil(store.choice(for: "bad"))
        XCTAssertNotNil(defaults.dictionary(forKey: "vf_dockPositions"))
    }
}
