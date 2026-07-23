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
            path: "Sources/WhisperType"
        ),
        .testTarget(
            name: "WhisperTypeKitTests",
            dependencies: ["WhisperTypeKit"],
            path: "Tests/WhisperTypeKitTests"
        )
    ]
)
