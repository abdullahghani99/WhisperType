import XCTest
import SwiftUI
@testable import WhisperTypeKit

final class DesignSystemTests: XCTestCase {
    func testSpacingIsOnThe4pxGrid() {
        for v in [VF.Space.xs, VF.Space.sm, VF.Space.md, VF.Space.lg,
                  VF.Space.xl, VF.Space.xxl, VF.Space.xxxl, VF.Space.xxxxl] {
            XCTAssertEqual(v.truncatingRemainder(dividingBy: 4), 0, "\(v) is off the 4px grid")
        }
        XCTAssertEqual(VF.Space.xs, 4)
        XCTAssertEqual(VF.Space.xxxxl, 64)
    }

    func testRadiusScale() {
        XCTAssertEqual(VF.Radius.sm, 8)
        XCTAssertEqual(VF.Radius.md, 12)
        XCTAssertEqual(VF.Radius.lg, 16)
        XCTAssertEqual(VF.Radius.pill, 24)
    }

    func testReadTimeRoundsUpAndNeverShowsZero() {
        XCTAssertEqual(VF.readTime(wordCount: 0), "under a minute")
        XCTAssertEqual(VF.readTime(wordCount: 50), "under a minute")
        XCTAssertEqual(VF.readTime(wordCount: 300), "2 min read")   // 225 wpm -> 1.33 -> 2
        XCTAssertEqual(VF.readTime(wordCount: 2250), "10 min read")
    }

    func testSentenceCaseLowersInteriorWordsButKeepsAcronymsAndNames() {
        XCTAssertEqual(VF.sentenceCase("Revenue Recognition And Dividends"),
                       "Revenue recognition and dividends")
        XCTAssertEqual(VF.sentenceCase("Transfer Pricing Audit Review"),
                       "Transfer pricing audit review")
        // All-caps tokens are acronyms and must survive.
        XCTAssertEqual(VF.sentenceCase("VAT And ISO Review"), "VAT and ISO review")
        XCTAssertEqual(VF.sentenceCase(""), "")
    }

    func testShadowsAreWarmNotBlack() {
        // Warm shadow ink is #1A1714 — never pure black.
        let (color, radius, y) = VF.Shadow.layer1
        XCTAssertEqual(radius, 3)
        XCTAssertEqual(y, 1)
        XCTAssertNotEqual(String(describing: color), String(describing: Color.black))
    }
}
