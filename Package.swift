// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LeftBarLyrics",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LeftBarLyrics", targets: ["LeftBarLyrics"])
    ],
    targets: [
        .executableTarget(
            name: "LeftBarLyrics",
            path: "Sources/LeftBarLyrics"
        )
    ]
)
