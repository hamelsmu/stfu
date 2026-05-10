// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stfu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "stfu", targets: ["stfu"])
    ],
    targets: [
        .executableTarget(
            name: "stfu",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
