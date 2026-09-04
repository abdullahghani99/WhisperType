import Foundation

/// A hand-rolled stand-in for the handful of XCTest APIs this suite uses.
///
/// XCTest is bundled inside Xcode and ships with nothing else — not the Command
/// Line Tools, not a standalone toolchain. When Xcode left this machine, all 78
/// tests became unrunnable, and audio concurrency code got changed for a whole
/// evening with no safety net. That dependency was never worth it: the suite is
/// pure logic and uses exactly seven assertions, none of the framework's real
/// machinery (no setUp/tearDown, no expectations, no async, no skips).
///
/// So the tests now run as a plain executable — `swift run vf-tests` — which
/// works with or without Xcode installed. If Xcode comes back, this still works.
enum VFTestLog {
    static var failures: [String] = []
    static var current = ""
    static var assertions = 0
}

/// The tests subclass this. It exists only so their declarations compile
/// unchanged; it carries no behaviour, because none was used.
open class XCTestCase {
    public init() {}
}

private func vfFail(_ message: String, _ file: StaticString, _ line: UInt) {
    let where_ = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
    VFTestLog.failures.append("  ✘ \(VFTestLog.current)\n      \(message)\n      at \(where_)")
}

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                                  file: StaticString = #file, line: UInt = #line) {
    VFTestLog.assertions += 1
    if a != b {
        vfFail("expected \(b), got \(a)\(message.isEmpty ? "" : " — \(message)")", file, line)
    }
}

func XCTAssertEqual<T: FloatingPoint>(_ a: T, _ b: T, accuracy: T, _ message: String = "",
                                      file: StaticString = #file, line: UInt = #line) {
    VFTestLog.assertions += 1
    if abs(a - b) > accuracy {
        vfFail("expected \(b) ± \(accuracy), got \(a)\(message.isEmpty ? "" : " — \(message)")", file, line)
    }
}

func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                                     file: StaticString = #file, line: UInt = #line) {
    VFTestLog.assertions += 1
    if a == b { vfFail("expected NOT \(b)\(message.isEmpty ? "" : " — \(message)")", file, line) }
}

func XCTAssertTrue(_ condition: Bool, _ message: String = "",
                   file: StaticString = #file, line: UInt = #line) {
    VFTestLog.assertions += 1
    if !condition { vfFail("expected true\(message.isEmpty ? "" : " — \(message)")", file, line) }
}

func XCTAssertFalse(_ condition: Bool, _ message: String = "",
                    file: StaticString = #file, line: UInt = #line) {
    VFTestLog.assertions += 1
    if condition { vfFail("expected false\(message.isEmpty ? "" : " — \(message)")", file, line) }
}

func XCTAssertNil<T>(_ value: T?, _ message: String = "",
                     file: StaticString = #file, line: UInt = #line) {
    VFTestLog.assertions += 1
    if value != nil { vfFail("expected nil, got \(value!)\(message.isEmpty ? "" : " — \(message)")", file, line) }
}

func XCTAssertNotNil<T>(_ value: T?, _ message: String = "",
                        file: StaticString = #file, line: UInt = #line) {
    VFTestLog.assertions += 1
    if value == nil { vfFail("expected non-nil\(message.isEmpty ? "" : " — \(message)")", file, line) }
}

/// Callable as `return XCTFail(...)` from a Void function, which is how the
/// suite uses it inside `guard ... else`.

func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) -> Void {
    VFTestLog.assertions += 1
    vfFail(message.isEmpty ? "XCTFail()" : message, file, line)
}
