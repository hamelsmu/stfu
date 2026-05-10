// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stfu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "STFULib", targets: ["STFULib"]),
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
        ),
        .testTarget(
            name: "STFULibTests",
            dependencies: ["STFULib"]
        )
    ]
)
