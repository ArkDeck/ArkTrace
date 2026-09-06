/// Checked Swift mirror of `Config/ArkTraceProduct.xcconfig`, shared by SPM and
/// the CLI. AppDistributionTests bind these values to the canonical Xcode
/// configuration so the App/CLI contract cannot drift silently.
package enum ArkTraceProduct {
    public static let commandName = "arktrace"
    public static let version = "0.1.0"
    public static let build = "1"
}
