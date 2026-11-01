// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kritz",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Kritz",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Kritz",
            linkerSettings: [
                // Find embedded frameworks (Sparkle) in the app bundle's Frameworks dir.
                // SwiftPM executables don't get this app-bundle rpath by default.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "KritzTests",
            dependencies: ["Kritz"],
            path: "Tests/KritzTests"
        )
    ]
)
