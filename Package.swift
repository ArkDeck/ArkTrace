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
        .library(name: "ArkTraceAnalysis", targets: ["ArkTraceAnalysis"]),
        .library(name: "ArkTraceCLI", targets: ["ArkTraceCLI"]),
        .executable(name: "arktrace", targets: ["arktrace"]),
    ],
    targets: [
        .target(name: "ArkTraceCore"),
        .target(name: "ArkTraceParser", dependencies: ["ArkTraceCore"]),
        .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"]),
        .target(name: "ArkTraceRuntime", dependencies: ["ArkTraceCore", "ArkTraceParser", "ArkTraceStore"]),
        .target(name: "ArkTraceAnalysis", dependencies: ["ArkTraceCore"]),
        .target(
            name: "ArkTraceCLI",
            dependencies: [
                "ArkTraceCore", "ArkTraceParser", "ArkTraceRuntime", "ArkTraceAnalysis",
            ]
        ),
        .executableTarget(name: "arktrace", dependencies: ["ArkTraceCLI"]),
        .testTarget(name: "ArkTraceCoreTests", dependencies: ["ArkTraceCore"]),
        .testTarget(name: "ArkTraceParserTests", dependencies: ["ArkTraceCore", "ArkTraceParser"]),
        .testTarget(name: "ArkTraceStoreTests", dependencies: ["ArkTraceStore"]),
        .testTarget(name: "ArkTraceAnalysisTests", dependencies: ["ArkTraceAnalysis"]),
        .testTarget(
            name: "ArkTraceCLITests",
            dependencies: ["ArkTraceCLI", "ArkTraceCore", "ArkTraceParser"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ArkTraceIntegrationTests",
            dependencies: [
                "ArkTraceCore", "ArkTraceParser", "ArkTraceStore", "ArkTraceRuntime",
                "ArkTraceAnalysis",
            ]
        ),
    ]
)
