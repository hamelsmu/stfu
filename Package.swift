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
        .target(
            name: "STFULib",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "stfu",
            dependencies: ["STFULib"]
        )
    ]
)
