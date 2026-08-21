// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LumaProfile",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LumaCore", targets: ["LumaCore"]),
        .executable(name: "LumaProfileApp", targets: ["LumaProfileApp"]),
    ],
    targets: [
        .target(name: "LumaCore"),
        .executableTarget(name: "LumaProfileApp", dependencies: ["LumaCore"]),
        .testTarget(
            name: "LumaCoreTests",
            dependencies: ["LumaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
