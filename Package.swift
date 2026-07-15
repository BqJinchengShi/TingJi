// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoubaoRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DoubaoRecorder",
            path: "Sources/DoubaoRecorder"
        ),
        .executableTarget(
            name: "doubao-recorder",
            dependencies: ["DoubaoRecorder"],
            path: "Sources/doubao-recorder"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
