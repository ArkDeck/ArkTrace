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
        .library(name: "ArkTraceRendering", targets: ["ArkTraceRendering"]),
        .library(name: "ArkTraceAppSupport", targets: ["ArkTraceAppSupport"]),
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
            name: "ArkTraceRendering",
            dependencies: ["ArkTraceCore"]
        ),
        .target(
            name: "ArkTraceAppSupport",
            dependencies: [
                "ArkTraceCore", "ArkTraceParser", "ArkTraceRuntime",
                "ArkTraceAnalysis", "ArkTraceRendering",
            ]
        ),
        .target(
            name: "ArkTraceSignalShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ArkTraceCLI",
            dependencies: [
                "ArkTraceCore", "ArkTraceParser", "ArkTraceStore", "ArkTraceRuntime",
                "ArkTraceAnalysis", "ArkTraceSignalShim",
            ],
            resources: [
                .copy("../../Fixtures/traces/zlib.htrace"),
                .copy("../../Fixtures/traces/LICENSE.Apache-2.0.txt"),
                .copy("../../Fixtures/traces/NOTICE.md"),
                .copy("../../LICENSE"),
                .copy("../../THIRD_PARTY_NOTICES.md"),
                .copy("../../ThirdParty/TraceStreamer/license-inventory.json"),
                .copy("../../ThirdParty/TraceStreamer/LICENSES"),
            ]
        ),
        .executableTarget(name: "arktrace", dependencies: ["ArkTraceCLI"]),
        .testTarget(name: "ArkTraceCoreTests", dependencies: ["ArkTraceCore"]),
        .testTarget(name: "ArkTraceParserTests", dependencies: ["ArkTraceCore", "ArkTraceParser"]),
        .testTarget(
            name: "ArkTraceStoreTests",
            dependencies: ["ArkTraceStore", "ArkTraceCLI"]
        ),
        .testTarget(name: "ArkTraceAnalysisTests", dependencies: ["ArkTraceAnalysis"]),
        .testTarget(
            name: "ArkTraceRenderingTests",
            dependencies: ["ArkTraceRendering"]
        ),
        .testTarget(
            name: "ArkTraceAppSupportTests",
            dependencies: [
                "ArkTraceAppSupport", "ArkTraceCore", "ArkTraceParser",
                "ArkTraceRuntime", "ArkTraceAnalysis", "ArkTraceRendering",
            ]
        ),
        .testTarget(
            name: "ArkTraceCLITests",
            dependencies: [
                "ArkTraceCLI", "ArkTraceCore", "ArkTraceParser", "ArkTraceStore",
                "ArkTraceRuntime",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ArkTraceIntegrationTests",
            dependencies: [
                "ArkTraceCore", "ArkTraceParser", "ArkTraceStore", "ArkTraceRuntime",
                "ArkTraceAnalysis", "ArkTraceRendering",
            ]
        ),
    ]
)
