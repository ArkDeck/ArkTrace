import Foundation
import XCTest
@testable import ArkTraceRustRuntime

@MainActor
final class RetainedStorageTests: XCTestCase {
    func testFailedAdmissionRefundsOnlyItsOwnReservation() throws {
        let pool = RustRetainedStorage(maximumBytes: 128, maximumOwners: 1)
        let first = try pool.reserve(80)
        XCTAssertThrowsError(try pool.reserve(1)) { error in
            XCTAssertEqual(error as? RustAdmission, .capacity)
        }
        XCTAssertEqual(pool.retainedBytes, 80)
        XCTAssertEqual(pool.retainedOwners, 1)
        XCTAssertThrowsError(try pool.reserve(49)) { error in
            XCTAssertEqual(error as? RustAdmission, .outputLimit)
        }
        XCTAssertThrowsError(try pool.reserve(0))
        XCTAssertThrowsError(try pool.reserve(Int.max))
        withExtendedLifetime(first) {
            XCTAssertEqual(pool.retainedBytes, 80)
            XCTAssertEqual(pool.retainedOwners, 1)
        }
    }

    private func text(in pool: RustRetainedStorage) throws -> RustOwnedText {
        let bytes = Array(" x\0中文😀 ".utf8)
        let credit = try pool.reserve(bytes.capacity + 64)
        let storage = RustTextStorage(bytes: bytes, credit: credit)
        return RustOwnedText(storage: storage, range: 1..<(bytes.count - 1))
    }

    func testTextCopiesRetainOneCreditUntilTheLastViewAndCallerCopyIsIndependent() async throws {
        let pool = RustRetainedStorage(maximumBytes: 1024, maximumOwners: 2)
        var original: RustOwnedText? = try text(in: pool)
        var retained: RustOwnedText? = original
        let charged = pool.retainedBytes
        XCTAssertGreaterThan(charged, 0)
        XCTAssertEqual(pool.retainedOwners, 1)
        original = nil
        XCTAssertEqual(pool.retainedBytes, charged)
        XCTAssertEqual(retained!.withUTF8 { span in (0..<span.count).map { span[$0] } }, Array("x\0中文😀".utf8))
        let copied = await retained!.copyString()
        retained = nil
        XCTAssertEqual(pool.retainedBytes, 0)
        XCTAssertEqual(pool.retainedOwners, 0)
        XCTAssertEqual(copied, "x\0中文😀")
        // Failure and the last ARC drop leave admission usable again.
        var recovered: RustOwnedText? = try text(in: pool)
        XCTAssertEqual(recovered!.utf8Count, copied.utf8.count)
        recovered = nil
        XCTAssertEqual(pool.retainedBytes, 0)
    }

    func testEmptyTextBorrowKeepsItsOwnerAndReturnsAnEmptySpan() throws {
        let pool = RustRetainedStorage(maximumBytes: 64, maximumOwners: 1)
        var value: RustOwnedText? = RustOwnedText(storage: RustTextStorage(bytes: [], credit: try pool.reserve(64)), range: 0..<0)
        XCTAssertEqual(value!.withUTF8 { $0.count }, 0)
        XCTAssertEqual(pool.retainedOwners, 1)
        value = nil
        XCTAssertEqual(pool.retainedBytes, 0)
        XCTAssertEqual(pool.retainedOwners, 0)
    }

    func testConcurrentReservationsAndARCRefundsRemainBoundedAndRecover() async throws {
        let pool = RustRetainedStorage(maximumBytes: 1024, maximumOwners: 8)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    for _ in 0..<32 {
                        do {
                            let credit = try pool.reserve(128)
                            await Task.yield()
                            withExtendedLifetime(credit) {
                                precondition(pool.retainedBytes <= 1024 && pool.retainedOwners <= 8)
                            }
                        } catch RustAdmission.capacity {
                        } catch RustAdmission.outputLimit {
                        } catch {
                            preconditionFailure("unexpected storage admission")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(pool.retainedBytes, 0)
        XCTAssertEqual(pool.retainedOwners, 0)
        let credit = try pool.reserve(1024)
        XCTAssertEqual(pool.retainedBytes, 1024)
        withExtendedLifetime(credit) {}
    }
}
