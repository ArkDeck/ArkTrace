// swift-tools-version: 6.3
import PackageDescription

// Compile-only consumer that lives OUTSIDE the ArkTrace package boundary, the
// way the Xcode app target does. It pins the promised public API: if an
// access-level tightening in the main package removes a symbol the app relies
// on, this package stops compiling — before the change ever reaches the app
// project or an external consumer.
let package = Package(
    name: "ArkTraceAPIBaseline",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // Explicit name: the checkout directory name must not leak into the
        // package identity (worktrees and CI use arbitrary directory names).
        .package(name: "ArkTrace", path: "../..")
    ],
    targets: [
        .target(
            name: "ArkTraceAPIBaseline",
            dependencies: [
                .product(name: "ArkTraceCore", package: "ArkTrace"),
                .product(name: "ArkTraceAnalysis", package: "ArkTrace"),
                .product(name: "ArkTraceRendering", package: "ArkTrace"),
                .product(name: "ArkTraceAppSupport", package: "ArkTrace"),
            ]
        )
    ]
)
