// Cache-only observation seam: original repository bytes are the exact prefix.
extension SQLiteTraceRepository {
    package static func summaryCanonicalObserving(
        databaseURL: URL, parser: TraceParserIdentity, source: TraceSourceDescriptor,
        preparation: TraceDatabasePreparationResult,
        observer: @escaping @Sendable (String, Int) -> Void
    ) throws -> SQLiteTraceRepository {
        try SQLiteTraceRepository(databaseURL: databaseURL, parser: parser, source: source,
            expectedPreparation: preparation, diagnosticQueryObserver: observer)
    }
}
