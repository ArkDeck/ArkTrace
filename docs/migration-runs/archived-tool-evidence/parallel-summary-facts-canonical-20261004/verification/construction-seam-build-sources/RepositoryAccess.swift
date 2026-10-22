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
    // Internal TraceDatabase is reached only for owned controlled fixture construction.
    package static func summaryCanonicalConstruct(databaseURL: URL, sql: String) throws -> TraceDatabasePreparationResult {
        do {
            let writer = try TraceDatabase(url: databaseURL, readOnly: false)
            try writer.execute(sql)
        }
        return try TraceDatabaseStagingPreparer.prepare(databaseURL: databaseURL)
    }
}
