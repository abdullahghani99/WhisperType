// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperType",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "WhisperTypeKit",
            path: "Sources/WhisperTypeKit"
        ),
        .executableTarget(
            name: "WhisperType",
            dependencies: ["WhisperTypeKit"],
            path: "Sources/WhisperType",
            resources: [.process("Resources")]
        ),
        // The suite runs as an EXECUTABLE, not an XCTest target. XCTest ships
        // only inside Xcode; when Xcode left this machine all 78 tests became
        // unrunnable. They never needed the framework — pure logic, seven
        // assertions, no setUp/expectations/async — so `swift run vf-tests`
        // works with just the Command Line Tools, and still works if Xcode
        // returns.
        .executableTarget(
            name: "vf-tests",
            dependencies: ["WhisperTypeKit"],
            path: "Sources/VFTests"
        )
    ]
)
