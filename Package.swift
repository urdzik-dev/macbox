// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacBox",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macbox", targets: ["MacBoxCLI"]),
        .executable(name: "macbox-guest", targets: ["MacBoxGuest"]),
        .library(name: "MacBoxCore", targets: ["MacBoxCore"]),
    ],
    targets: [
        .target(
            name: "MacBoxCore",
            dependencies: ["MacBoxProtocol"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("Security"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(name: "MacBoxProtocol"),
        .executableTarget(name: "MacBoxGuest", dependencies: ["MacBoxProtocol", "MacBoxCore"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement")
        ]),
        .executableTarget(
            name: "MacBoxCLI",
            dependencies: ["MacBoxCore", "MacBoxProtocol"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "MacBoxCoreTests",
            dependencies: ["MacBoxCore", "MacBoxProtocol"]
        ),
    ]
)
