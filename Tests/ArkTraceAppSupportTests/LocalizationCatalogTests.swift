import Foundation
import XCTest

@testable import ArkTraceAppSupport

/// Integrity checks for `Localizable.xcstrings` beyond the per-message
/// completeness `AppDistributionTests` already enforces:
///   - no orphan typed keys (catalog entries no enum case produces),
///   - typed keys are marked manually managed so Xcode's extractor cannot
///     prune keys that are referenced only through generated symbols,
///   - German localizations cover every typed key with the same placeholder
///     signature as English,
///   - the app's generated-symbol switch references every typed key.
final class LocalizationCatalogTests: XCTestCase {
    private static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Typed key → the Xcode-generated symbol name the app must reference.
    /// Keeping the table literal pins the exact camel-casing the generator
    /// produced (`a11y` → `a11Y`), so a silent rename regenerates as a diff
    /// here instead of an unnoticed dead branch.
    private static let typedKeySymbols: [String: String] = [
        "a11y.announce.openingTrace": "a11YAnnounceOpeningTrace",
        "a11y.announce.openingCancelled": "a11YAnnounceOpeningCancelled",
        "a11y.announce.traceClosed": "a11YAnnounceTraceClosed",
        "a11y.announce.traceCloseFailed": "a11YAnnounceTraceCloseFailed",
        "a11y.announce.traceOpenFailed": "a11YAnnounceTraceOpenFailed",
        "a11y.announce.operationFailed": "a11YAnnounceOperationFailed",
        "a11y.announce.rangeAnalysisComplete": "a11YAnnounceRangeAnalysisComplete",
        "a11y.announce.traceLoadedWithoutTimedEvents":
            "a11YAnnounceTraceLoadedWithoutTimedEvents",
        "a11y.announce.traceLoadedWithVisibleTracks":
            "a11YAnnounceTraceLoadedWithVisibleTracks",
        "a11y.announce.searchFoundResults": "a11YAnnounceSearchFoundResults",
        "a11y.announce.searchFoundAtLeastResults":
            "a11YAnnounceSearchFoundAtLeastResults",
        "a11y.timeline.label": "a11YTimelineLabel",
        "error.title.traceCouldNotBeOpened": "errorTitleTraceCouldNotBeOpened",
        "error.title.bundledParserUnavailable": "errorTitleBundledParserUnavailable",
        "error.title.cacheNeedsAttention": "errorTitleCacheNeedsAttention",
        "error.title.openingCancelled": "errorTitleOpeningCancelled",
        "error.title.couldNotFinish": "errorTitleCouldNotFinish",
        "ArkTrace and third-party license notices": "arkTraceAndThirdPartyLicenseNotices",
    ]

    private func loadCatalogStrings() throws -> [String: [String: Any]] {
        let url = Self.repositoryRoot.appending(path: "Apps/ArkTraceApp/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
        return try XCTUnwrap(catalog?["strings"] as? [String: [String: Any]])
    }

    private func format(
        of entry: [String: Any],
        language: String
    ) -> String? {
        let localizations = entry["localizations"] as? [String: Any]
        let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    /// Every typed-prefix catalog key must be produced by a known enum case.
    /// A key nothing produces is dead weight that would silently rot.
    func testCatalogHasNoOrphanTypedKeys() throws {
        let strings = try loadCatalogStrings()
        let producedKeys = Set(
            [
                TraceAccessibilityMessage.openingTrace, .openingCancelled, .traceClosed,
                .traceCloseFailed, .traceOpenFailed, .operationFailed,
                .rangeAnalysisComplete, .traceLoadedWithoutTimedEvents,
                .traceLoadedWithVisibleTracks(1), .searchFoundResults(1),
                .searchFoundAtLeastResults(1),
            ].map(\.localizationKey)
                + TraceAppErrorTitle.allCases.map(\.rawValue)
                + ["a11y.timeline.label"]
        )
        for key in strings.keys where key.hasPrefix("a11y.") || key.hasPrefix("error.title.") {
            XCTAssertTrue(
                producedKeys.contains(key),
                "catalog key '\(key)' is produced by no message or error case (orphan)"
            )
        }
    }

    /// Typed keys are referenced only through generated symbols, which the
    /// extractor cannot see; without `extractionState: manual` an Xcode sync
    /// would flag them stale and a cleanup could drop live announcements.
    func testTypedKeysAreMarkedManuallyManaged() throws {
        let strings = try loadCatalogStrings()
        for key in Self.typedKeySymbols.keys {
            let entry = try XCTUnwrap(strings[key], "catalog entry for '\(key)' is missing")
            XCTAssertEqual(
                entry["extractionState"] as? String,
                "manual",
                "'\(key)' must be manually managed; it is referenced only via generated symbols"
            )
        }
    }

    /// German must cover every typed key with the same `%lld` signature as
    /// English, and formatting with a representative count must succeed.
    func testGermanLocalizationsMatchEnglishPlaceholderSignatures() throws {
        let strings = try loadCatalogStrings()
        for key in Self.typedKeySymbols.keys {
            let entry = try XCTUnwrap(strings[key])
            let german = try XCTUnwrap(
                format(of: entry, language: "de"),
                "'\(key)' has no German localization"
            )
            // English may be implicit (source language) for plain literals;
            // typed keys carry it explicitly except the pane toggles.
            let english = format(of: entry, language: "en")
            let germanPlaceholders = german.components(separatedBy: "%lld").count - 1
            if let english {
                let englishPlaceholders = english.components(separatedBy: "%lld").count - 1
                XCTAssertEqual(
                    germanPlaceholders, englishPlaceholders,
                    "placeholder signature of '\(key)' differs between en and de"
                )
            }
            if germanPlaceholders == 1 {
                let rendered = String(format: german, 42)
                XCTAssertTrue(
                    rendered.contains("42"),
                    "German format for '\(key)' must render its count argument"
                )
                XCTAssertFalse(rendered.contains("%lld"))
            }
        }
    }

    /// The app resolves typed keys through generated symbols; every symbol in
    /// the table must appear in the app source, so a new catalog key cannot
    /// exist without a wired-up reference.
    func testAppReferencesEveryGeneratedTypedSymbol() throws {
        let appSource = try AppSource.read().text
        for (key, symbol) in Self.typedKeySymbols {
            XCTAssertTrue(
                appSource.contains(".\(symbol)"),
                "generated symbol '\(symbol)' (key '\(key)') is not referenced by the app"
            )
        }
        XCTAssertFalse(
            appSource.contains("NSLocalizedString"),
            "the app must not fall back to NSLocalizedString key lookups"
        )
        XCTAssertFalse(
            appSource.contains("String(format:"),
            "the app must not format localized text through C varargs"
        )
    }
}
