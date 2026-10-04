import Foundation

/// Fixed product-owned operations. Each backend owns its root and leases;
/// individual calls cannot supply paths or select another implementation.
package struct TraceCacheMaintenanceOperations: Sendable {
    private let inventoryOperation: @Sendable () async throws -> TraceCacheInventory
    private let maintainOperation: @Sendable () async throws -> TraceCacheMaintenanceReport
    private let purgeOperation: @Sendable () async throws -> TraceCacheMaintenanceReport

    package init(
        inventory: @escaping @Sendable () async throws -> TraceCacheInventory,
        maintain: @escaping @Sendable () async throws -> TraceCacheMaintenanceReport,
        purgeUnused: @escaping @Sendable () async throws -> TraceCacheMaintenanceReport
    ) {
        inventoryOperation = inventory
        maintainOperation = maintain
        purgeOperation = purgeUnused
    }

    package init(_ maintenance: TraceCacheMaintenance) {
        self.init(
            inventory: { try await maintenance.inventory() },
            maintain: { try await maintenance.maintain() },
            purgeUnused: { try await maintenance.purgeUnused() }
        )
    }

    package func inventory() async throws -> TraceCacheInventory { try await inventoryOperation() }
    package func maintain() async throws -> TraceCacheMaintenanceReport { try await maintainOperation() }
    package func purgeUnused() async throws -> TraceCacheMaintenanceReport { try await purgeOperation() }
}
