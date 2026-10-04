// swift-tools-version: 6.3
import PackageDescription
import Foundation

// Swift 6.0 language mode on the Swift 6.4 toolchain (Xcode 27.0). Strict memory safety is
// a per-target opt-in (SE-0458): enabled on every first-party target that owns
// POSIX/SQLite/process boundaries so unsafe pointer use is visible at the call
// site.
//
// Deprecated-declaration promotion deliberately lives in two other places
// instead of a `.treatWarning` here: the app target sets
// SWIFT_WARNINGS_AS_ERRORS_GROUPS = DeprecatedDeclaration, and CI fails the
// SwiftPM build on any warning at all. Xcode builds package dependencies with
// `-suppress-warnings`, which hard-conflicts with `-Werror <group>` from a
// package manifest and breaks the app build outright.
let firstPartySwiftSettings: [SwiftSetting] = [
    .strictMemorySafety()
]

// AT-RUST-012 development override. The published immutable URL/checksum is
// frozen with the release artifact; there is no floating network fallback.
let nativeSDKPath = ProcessInfo.processInfo.environment["ARKTRACE_RUST_XCFRAMEWORK"]
let nativeSDKFixtures = ProcessInfo.processInfo.environment["ARKTRACE_RUST_SDK_FIXTURES"] == "1"
let nativeProducts: [Product] = nativeSDKPath == nil ? [] : [
    .library(name: "ArkTraceRustRuntime", targets: ["ArkTraceRustRuntime"])
]
let nativeTargets: [Target] = if let nativeSDKPath {
    [
        .binaryTarget(name: "CArkTrace", path: nativeSDKPath),
        .target(name: "ArkTraceRustRuntime", dependencies: ["ArkTraceCore", "CArkTrace"],
            swiftSettings: firstPartySwiftSettings + (nativeSDKFixtures ? [.define("ARKTRACE_RUST_PROCESS_FIXTURES")] : []),
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]),
        .testTarget(name: "ArkTraceRustRuntimeTests", dependencies: ["ArkTraceRustRuntime"],
            swiftSettings: firstPartySwiftSettings),
    ]
} else { [] }

let package = Package(
    name: "ArkTrace",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "ArkTraceCore", targets: ["ArkTraceCore"]),
        .library(name: "ArkTraceParser", targets: ["ArkTraceParser"]),
        .library(name: "ArkTraceStore", targets: ["ArkTraceStore"]),
        .library(name: "ArkTraceRuntime", targets: ["ArkTraceRuntime"]),
        .library(name: "ArkTraceAnalysis", targets: ["ArkTraceAnalysis"]),
        .library(name: "ArkTraceRendering", targets: ["ArkTraceRendering"]),
        .library(name: "ArkTraceAppSupport", targets: ["ArkTraceAppSupport"]),
        .library(name: "ArkTraceCapture", targets: ["ArkTraceCapture"]),
        .library(name: "ArkTraceCLI", targets: ["ArkTraceCLI"]),
        .executable(name: "arktrace", targets: ["arktrace"]),
    ] + nativeProducts,
    targets: [
        .target(name: "ArkTraceCore", swiftSettings: firstPartySwiftSettings),
        .target(
            name: "ArkTraceParser",
            dependencies: ["ArkTraceCore"],
            swiftSettings: firstPartySwiftSettings
        ),
        .target(
            name: "ArkTraceStore",
            dependencies: ["ArkTraceCore"],
            swiftSettings: firstPartySwiftSettings
        ),
        .target(
            name: "ArkTraceRuntime",
            dependencies: ["ArkTraceCore", "ArkTraceParser", "ArkTraceStore"],
            swiftSettings: firstPartySwiftSettings
        ),
        .target(
            name: "ArkTraceAnalysis",
            dependencies: ["ArkTraceCore"],
            swiftSettings: firstPartySwiftSettings
        ),
        .target(
            name: "ArkTraceRendering",
            dependencies: ["ArkTraceCore"],
            swiftSettings: firstPartySwiftSettings
        ),
        .target(
            name: "ArkTraceAppSupport",
            dependencies: [
                "ArkTraceCore", "ArkTraceParser", "ArkTraceRuntime",
                "ArkTraceAnalysis", "ArkTraceRendering",
            ],
            swiftSettings: firstPartySwiftSettings
        ),
        // Deliberately isolated from Core/Runtime/CLI. Device discovery and
        // capture are an explicit GUI capability; analysis products never
        // acquire an HDC dependency by transitivity.
        .target(
            name: "ArkTraceCapture",
            swiftSettings: firstPartySwiftSettings
        ),
        // C target: Swift settings (strict memory safety, warning groups) do
        // not apply. The shim stays deliberately tiny and reviewed by hand.
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
            swiftSettings: firstPartySwiftSettings
        ),
        // Test-only resource target. Keeping it outside the production CLI
        // dependency graph prevents SwiftPM's generated Bundle.module accessor
        // from embedding the build-machine path in the distributable binary.
        .target(
            name: "ArkTraceCLIResourceFixtures",
            resources: [
                .copy("../../Fixtures/traces/zlib.htrace"),
                .copy("../../LICENSE"),
                .copy("../../THIRD_PARTY_NOTICES.md"),
                .copy("../../ThirdParty/TraceStreamer/license-inventory.json"),
                .copy("../../ThirdParty/TraceStreamer/LICENSES"),
            ]
        ),
        .executableTarget(
            name: "arktrace",
            dependencies: ["ArkTraceCLI"],
            swiftSettings: firstPartySwiftSettings
        ),
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
            name: "ArkTraceCaptureTests",
            dependencies: ["ArkTraceCapture"]
        ),
        .testTarget(
            name: "ArkTraceCLITests",
            dependencies: [
                "ArkTraceCLI", "ArkTraceCore", "ArkTraceParser", "ArkTraceStore",
                "ArkTraceRuntime", "ArkTraceCLIResourceFixtures",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ArkTraceIntegrationTests",
            dependencies: [
                "ArkTraceCore", "ArkTraceParser", "ArkTraceStore", "ArkTraceRuntime",
                "ArkTraceAnalysis", "ArkTraceRendering", "ArkTraceAppSupport",
            ]
        ),
    ] + nativeTargets,
    swiftLanguageModes: [.v6]
)
