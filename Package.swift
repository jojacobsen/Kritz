// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kritz",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kritz",
            path: "Sources/Kritz"
        )
    ]
)
