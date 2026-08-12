// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArkTrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ArkTraceCore", targets: ["ArkTraceCore"]),
        .library(name: "ArkTraceParser", targets: ["ArkTraceParser"]),
        .library(name: "ArkTraceStore", targets: ["ArkTraceStore"]),
        .library(name: "ArkTraceRuntime", targets: ["ArkTraceRuntime"]),
    ],
    targets: [
        .target(name: "ArkTraceCore"),
        .target(name: "ArkTraceParser", dependencies: ["ArkTraceCore"]),
        .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"]),
        .target(name: "ArkTraceRuntime", dependencies: ["ArkTraceCore", "ArkTraceParser", "ArkTraceStore"]),
        .testTarget(name: "ArkTraceCoreTests", dependencies: ["ArkTraceCore"]),
        .testTarget(name: "ArkTraceParserTests", dependencies: ["ArkTraceCore", "ArkTraceParser"]),
        .testTarget(name: "ArkTraceStoreTests", dependencies: ["ArkTraceStore"]),
        .testTarget(
            name: "ArkTraceIntegrationTests",
            dependencies: ["ArkTraceCore", "ArkTraceParser", "ArkTraceStore", "ArkTraceRuntime"]
        ),
    ]
)
