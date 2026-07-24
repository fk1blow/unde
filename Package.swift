// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "unde",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "unde",
            path: "Sources/unde"
        )
    ]
)
