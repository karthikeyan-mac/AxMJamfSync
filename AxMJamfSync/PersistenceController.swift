// PersistenceController.swift
// CoreData stack (NSPersistentContainer) + CDDevice ↔ Device conversion.
//
// Schema: single CDDevice entity — all fields Optional String/Bool/Date.
// Background contexts: newBackgroundContext() for all reads and batch writes.
//   viewContext is NEVER used for .toDevice() mapping (EXC_BAD_ACCESS risk).
// Upsert: NSBatchInsertRequest is NOT used — crashes on Binary Data attributes
//   on Apple Silicon. Devices are upserted one-by-one inside perform{}.
// WAL + history tracking enabled for safe concurrent read/write.

import CoreData
import Foundation
import os
import SQLite3

final class PersistenceController: Sendable {

    // MARK: - Singleton
    static let shared = PersistenceController()

    // MARK: - Preview instance (in-memory, seeded with sample data)
    @MainActor
    static let preview: PersistenceController = {
        let c = PersistenceController(inMemory: true)
        let ctx = c.container.viewContext
        for device in Device.sampleDevices {
            CDDevice.from(device: device, in: ctx)
        }
        try? ctx.save()
        return c
    }()

    // MARK: - Container
    // NSPersistentContainer is a class; marking the controller Sendable is safe
    // because we only mutate the container during init (before sharing).
    nonisolated let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    /// The actual on-disk URL of the SQLite store — derived from the container
    /// after stores are loaded, so it reflects the real sandbox path.
    var storeURL: URL? {
        container.persistentStoreCoordinator.persistentStores.first?.url
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }

    // MARK: - Init

    /// Default init — uses legacy single-env store (AxMJamfSync.sqlite).
    /// Used only for the Default (v1-migrated) environment.
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "AxMJamfSync")

        if inMemory {
            container.persistentStoreDescriptions.first?.url =
                URL(fileURLWithPath: "/dev/null")
        } else {
            guard let description = container.persistentStoreDescriptions.first else {
                os_log(.fault, "[CoreData] FATAL: no persistent store description found")
                return
            }
            // NSPersistentHistoryTrackingKey must stay ON because the store has already
            // been opened with it enabled. Disabling it after the fact causes CoreData to
            // detect a metadata mismatch and force the store into read-only mode with:
            //   "Store opened without NSPersistentHistoryTrackingKey but previously had
            //    been opened with NSPersistentHistoryTrackingKey — Forcing into Read Only"
            // The WAL checkpoint debug message ("checkpointed: 1007") is benign — it just
            // means SQLite flushed the WAL to the main database file at 1000 frames.
            // We keep tracking ON and purge history after every load to prevent unbounded
            // accumulation (see purgeHistoryTransactions() called after loadPersistentStores).
            description.setOption(true as NSNumber,
                forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber,
                forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            description.shouldMigrateStoreAutomatically      = true
            description.shouldInferMappingModelAutomatically = true
        }

        // Log CoreData load errors — don't fatalError in production (sandbox path issues
        // or migration failures should show an error, not a crash).
        container.loadPersistentStores { desc, error in
            if let error {
                os_log(.fault, "[CoreData] FATAL: failed to load store — %{public}@", error.localizedDescription)
                // Post notification so AppStore/UI can show an alert rather than crash
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .persistenceLoadFailed,
                        object: error.localizedDescription)
                }
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name        = "viewContext"

        // Purge history transactions older than 1 day on every launch.
        // NSPersistentHistoryTracking must stay enabled (see comment above) but the
        // accumulated transaction log grows indefinitely without cleanup. Deleting
        // transactions before `yesterday` keeps the WAL small while preserving any
        // in-flight changes from the current session.
        purgeHistoryTransactions()
    }

    /// Per-environment init — each environment gets its own isolated SQLite file.
    /// New environments start with an empty store. Only the Default environment
    /// (00000000-0000-0000-0000-000000000001) migrates data from v1 on first launch.
    convenience init(environmentId: UUID) {
        let fm = FileManager.default
        let envDir   = PersistenceController.environmentsDirectory
        try? fm.createDirectory(at: envDir, withIntermediateDirectories: true)
        let storeURL = envDir.appendingPathComponent("\(environmentId.uuidString).sqlite")

        // Normal launch — store already exists, open it directly.
        if fm.fileExists(atPath: storeURL.path) {
            self.init(storeURL: storeURL)
            return
        }

        // First v2.0 launch for the Default environment — copy v1 data.
        let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        if environmentId == defaultId {
            PersistenceController.copyV1Store(to: storeURL)
        }

        self.init(storeURL: storeURL)
    }

    /// Copies the v1 SQLite store to the destination URL.
    ///
    /// Strategy: open the v1 store via NSPersistentContainer (which forces a WAL
    /// checkpoint, flushing all pending writes into the main .sqlite file), then
    /// copy the .sqlite, -wal, and -shm files directly. Direct file copy is more
    /// reliable than migratePersistentStore across different option sets.
    private static func copyV1Store(to destURL: URL) {
        // Step 1: open v1 store to force WAL checkpoint
        let tempContainer = NSPersistentContainer(name: "AxMJamfSync")
        guard let desc = tempContainer.persistentStoreDescriptions.first else {
            os_log(.error, "[CoreData] copyV1Store: no store description found")
            return
        }
        desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        desc.shouldMigrateStoreAutomatically     = true
        desc.shouldInferMappingModelAutomatically = true

        var v1URL: URL? = nil
        var loadError: Error? = nil
        tempContainer.loadPersistentStores { _, error in
            if let error { loadError = error; return }
            v1URL = tempContainer.persistentStoreCoordinator.persistentStores.first?.url
        }

        if let loadError {
            os_log(.error, "[CoreData] copyV1Store: failed to load v1 store — %{public}@",
                   loadError.localizedDescription)
            return
        }
        guard let v1URL else {
            os_log(.error, "[CoreData] copyV1Store: could not resolve v1 store URL")
            return
        }

        // Step 2: checkpoint WAL by closing all contexts cleanly
        // Setting persistentStoreCoordinator to a fresh one forces SQLite to flush
        try? tempContainer.persistentStoreCoordinator.remove(
            tempContainer.persistentStoreCoordinator.persistentStores.first!
        )

        // Step 3: copy .sqlite, -wal, -shm to destination
        let fm = FileManager.default
        var copied = false
        for ext in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: v1URL.path + ext)
            let dst = URL(fileURLWithPath: destURL.path + ext)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                if ext.isEmpty { copied = true }
            } catch {
                os_log(.error, "[CoreData] copyV1Store: copy failed for %{public}@ — %{public}@",
                       ext.isEmpty ? ".sqlite" : ext, error.localizedDescription)
            }
        }

        if copied {
            os_log(.default, "[CoreData] v1 store copied to %{public}@", destURL.lastPathComponent)
        }
    }

    /// Returns the directory where all per-environment SQLite stores live.
    /// Derived from the sandbox-resolved Application Support path so it always
    /// lands inside the correct container on sandboxed builds.
    /// Cached sandbox-resolved path for environment stores.
    /// Computed once at app launch via NSPersistentContainer default URL resolution.
    static let environmentsDirectory: URL = {
        let probe = NSPersistentContainer(name: "AxMJamfSync")
        if let desc = probe.persistentStoreDescriptions.first, let url = desc.url {
            return url.deletingLastPathComponent().appendingPathComponent("environments", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AxM Jamf Sync/environments", isDirectory: true)
    }()

    /// Internal init for a specific store URL.
    init(storeURL: URL) {
        container = NSPersistentContainer(name: "AxMJamfSync")
        let desc  = NSPersistentStoreDescription(url: storeURL)
        desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        desc.shouldMigrateStoreAutomatically      = true
        desc.shouldInferMappingModelAutomatically  = true
        container.persistentStoreDescriptions = [desc]

        container.loadPersistentStores { _, error in
            if let error {
                os_log(.fault, "[CoreData] Failed to load store at %{public}@ — %{public}@",
                       storeURL.lastPathComponent, error.localizedDescription)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .persistenceLoadFailed,
                                                    object: error.localizedDescription)
                }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name        = "viewContext"
        purgeHistoryTransactions()
    }

    // MARK: - v2.0 Environment wipe

    /// Delete the SQLite store files for an environment (called on environment deletion).
    static func wipeEnvironment(id: UUID) {
        let envDir   = PersistenceController.environmentsDirectory
        let storeURL = envDir.appendingPathComponent("\(id.uuidString).sqlite")
        for ext in ["", "-wal", "-shm"] {
            let path = storeURL.path + ext
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Persistent history cleanup
    /// Delete NSPersistentHistoryTransaction records older than 24 hours.
    /// Safe to call from any context — uses a throw-away background context.
    func purgeHistoryTransactions() {
        // Skip inMemory stores — they have no history tracking and no persistent URL.
        guard let storeURL = container.persistentStoreCoordinator.persistentStores.first?.url,
              storeURL.path != "/dev/null" else { return }

        // Only purge once per day per store file.
        let lastPurgeKey = "coredata.lastHistoryPurge.\(storeURL.lastPathComponent)"
        let ud  = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard now - ud.double(forKey: lastPurgeKey) > 86_400 else { return }

        let yesterday = Date().addingTimeInterval(-86_400)
        let purgeReq  = NSPersistentHistoryChangeRequest.deleteHistory(before: yesterday)
        let bgCtx     = container.newBackgroundContext()
        bgCtx.perform {
            do {
                try bgCtx.execute(purgeReq)
                ud.set(now, forKey: lastPurgeKey)
                os_log(.debug, "[CoreData] Persistent history purged for %{public}@.", storeURL.lastPathComponent)
            } catch {
                os_log(.error, "[CoreData] History purge error: %{public}@", error.localizedDescription)
            }
        }
    }
    // Both save() variants are nonisolated and synchronous.
    // They use print() for error reporting so they can be called from any context
    // without crossing actor boundaries. The caller (AppStore, which IS @MainActor)
    // can forward errors to LogService after the call returns.

    func save() {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return }
        do   { try ctx.save() }
        catch { os_log(.error, "[CoreData] view-context save error: %{public}@", error.localizedDescription) }
    }

    func save(_ ctx: NSManagedObjectContext) {
        guard ctx.hasChanges else { return }
        do   { try ctx.save() }
        catch { os_log(.error, "[CoreData] background-context save error: %{public}@", error.localizedDescription) }
    }

    // MARK: - Batch delete (cache wipe)
    // Capture the container directly (not self) so the closure is Sendable.
    func deleteAllDevices() async {
        let container = self.container           // local copy — Sendable-safe
        let viewCtx   = container.viewContext    // retain reference before entering closure

        let bgCtx = container.newBackgroundContext()
        bgCtx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        await bgCtx.perform {
            let req    = NSFetchRequest<NSFetchRequestResult>(entityName: "CDDevice")
            let delete = NSBatchDeleteRequest(fetchRequest: req)
            delete.resultType = .resultTypeObjectIDs
            do {
                let result = try bgCtx.execute(delete) as? NSBatchDeleteResult
                let ids    = result?.result as? [NSManagedObjectID] ?? []
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: ids],
                    into: [viewCtx])
            } catch {
                os_log(.error, "[CoreData] batch delete error: %{public}@", error.localizedDescription)
            }
        }

        // VACUUM reclaims freed SQLite pages so the .sqlite file actually shrinks.
        // NSBatchDeleteRequest removes rows but SQLite keeps the pages in its free list.
        //
        // Safety: VACUUM requires exclusive access to the SQLite file. Opening a raw
        // sqlite3 connection while CoreData's coordinator holds the store is a race.
        // Fix: remove the persistent store from the coordinator before VACUUM, then
        // re-add it. CoreData flushes the WAL and releases its file lock on remove().
        let coordinator = container.persistentStoreCoordinator
        if let store = coordinator.persistentStores.first,
           let storeURL = store.url {
            do {
                try coordinator.remove(store)
                var db: OpaquePointer?
                if sqlite3_open(storeURL.path, &db) == SQLITE_OK {
                    sqlite3_exec(db, "VACUUM;", nil, nil, nil)
                    sqlite3_close(db)
                    os_log(.default, "[CoreData] VACUUM complete.")
                }
                // Re-add the store with the same configuration
                let type = NSSQLiteStoreType
                let options: [String: Any] = [
                    NSPersistentHistoryTrackingKey: true as NSNumber,
                    NSPersistentStoreRemoteChangeNotificationPostOptionKey: true as NSNumber,
                    NSMigratePersistentStoresAutomaticallyOption: true,
                    NSInferMappingModelAutomaticallyOption: true,
                ]
                try coordinator.addPersistentStore(ofType: type, configurationName: nil, at: storeURL, options: options)
            } catch {
                os_log(.error, "[CoreData] VACUUM store cycle error: %{public}@", error.localizedDescription)
            }
        }
    }
}

// MARK: - CDDevice ↔ Device bridge

extension CDDevice {

    /// Single-device upsert — used only for seeding previews with a few records.
    /// For bulk syncs use batchUpsert(devices:in:) which pre-fetches all serials at once.
    @discardableResult
    static func from(device: Device, in ctx: NSManagedObjectContext) -> CDDevice {
        let req = CDDevice.fetchRequest()
        req.predicate  = NSPredicate(format: "serialNumber == %@", device.serialNumber)
        req.fetchLimit = 1
        let cd: CDDevice
        if let existing = (try? ctx.fetch(req))?.first {
            cd = existing
        } else {
            cd = CDDevice(context: ctx)
            cd.serialNumber = device.serialNumber
            cd.createdAt    = Date()
            cd.deviceSource = DeviceSource.axmOnly.rawValue
        }
        cd.apply(from: device)
        return cd
    }

    /// Batch upsert — pre-fetches ALL existing serials in ONE query, then
    /// updates existing objects or inserts new ones. O(n) instead of O(n²).
    /// Called by AppStore.upsertDevices() for all sync pipeline writes.
    static func batchUpsert(devices: [Device], in ctx: NSManagedObjectContext) {
        guard !devices.isEmpty else { return }
        let serials = devices.map { $0.serialNumber }

        // One fetch for all serials — vastly cheaper than 60k individual fetches
        let req = CDDevice.fetchRequest()
        req.predicate    = NSPredicate(format: "serialNumber IN %@", serials)
        req.fetchBatchSize = 500
        let existing = (try? ctx.fetch(req)) ?? []
        var bySerial = Dictionary(uniqueKeysWithValues: existing.compactMap { cd -> (String, CDDevice)? in
            guard let s = cd.serialNumber else { return nil }
            return (s, cd)
        })

        let now = Date()
        for d in devices {
            let cd: CDDevice
            if let ex = bySerial[d.serialNumber] {
                cd = ex
            } else {
                cd = CDDevice(context: ctx)
                cd.serialNumber = d.serialNumber
                cd.createdAt    = now
                cd.deviceSource = DeviceSource.axmOnly.rawValue
                bySerial[d.serialNumber] = cd
            }
            cd.apply(from: d)
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // P3: Second static for the non-fractional fallback (Jamf dates without milliseconds).
    // Previously this was allocated fresh on every parseISO call — at 50k devices × 3 date
    // fields = 150k allocations per sync. Static allocation pays once at first use.
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // Tries fractional seconds first (Jamf), then without (Apple/legacy)
    private static func parseISO(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        return isoNoFrac.date(from: s)
    }

    func apply(from d: Device) {
        updatedAt           = Date()
        deviceSource        = d.deviceSource.rawValue
        axmDeviceId         = d.axmDeviceId
        axmDeviceStatus     = d.axmDeviceStatus
        axmPurchaseSource   = d.axmPurchaseSource
        axmPurchaseSourceId = d.axmPurchaseSourceId
        axmOrderNumber      = d.axmOrderNumber
        axmOrderDate        = d.axmOrderDate
        axmModel            = d.axmModel
        axmDeviceModel      = d.axmDeviceModel
        axmDeviceClass      = d.axmDeviceClass
        axmProductFamily    = d.axmProductFamily
        axmCoverageStatus   = d.axmCoverageStatus
        axmCoverageEndDate  = d.axmCoverageEndDate
        axmAgreementNumber  = d.axmAgreementNumber
        wbStatus            = d.wbStatus?.rawValue
        wbNote              = d.wbNote
        jamfId              = d.jamfId
        jamfName            = d.jamfName
        jamfManaged         = d.isManaged
        jamfModel           = d.jamfModel
        jamfModelIdentifier = d.jamfModelIdentifier
        jamfMacAddress      = d.jamfMacAddress
        jamfWarrantyDate    = d.jamfWarrantyDate
        jamfVendor          = d.jamfVendor
        jamfAppleCareId     = d.jamfAppleCareId
        jamfOsVersion       = d.jamfOsVersion
        jamfFileVaultStatus = d.jamfFileVaultStatus
        jamfUsername        = d.jamfUsername
        jamfDeviceType      = d.jamfDeviceType
        assignedMdmServerId   = d.assignedMdmServerId
        assignedMdmServerName = d.assignedMdmServerName
        mdmServerType         = d.mdmServerType

        // Raw Apple API JSON — only overwrite when the incoming value is non-nil
        // so a Jamf-only merge pass doesn't null out previously stored Apple blobs.
        if let json = d.axmRawJson         { axmRawJson         = json }
        if let json = d.axmCoverageRawJson { axmCoverageRawJson = json }

        let parseISO = CDDevice.parseISO
        axmDeviceFetchedAt   = d.axmDeviceFetchedAt.flatMap  { parseISO($0) }
        axmCoverageFetchedAt = d.axmCoverageFetchedAt.flatMap { parseISO($0) }
        wbPushedAt           = d.wbPushedAt.flatMap          { parseISO($0) }
        jamfReportDate       = d.jamfReportDate.flatMap       { parseISO($0) }
        jamfLastContact      = d.jamfLastContact.flatMap      { parseISO($0) }
        jamfLastEnrolled     = d.jamfLastEnrolled.flatMap     { parseISO($0) }
    }

    func toDevice() -> Device {
        let iso = CDDevice.iso
        func fmt(_ d: Date?) -> String? { d.map { iso.string(from: $0) } }
        return Device(
            serialNumber:         serialNumber         ?? "",
            deviceSource:         DeviceSource(rawValue: deviceSource ?? "") ?? .axmOnly,
            axmDeviceId:          axmDeviceId,
            axmDeviceStatus:      axmDeviceStatus,
            axmDeviceFetchedAt:   fmt(axmDeviceFetchedAt),
            axmPurchaseSource:    axmPurchaseSource,
            axmPurchaseSourceId:  axmPurchaseSourceId,
            axmOrderNumber:       axmOrderNumber,
            axmOrderDate:         axmOrderDate,
            axmModel:             axmModel,
            axmDeviceModel:       axmDeviceModel,
            axmDeviceClass:       axmDeviceClass,
            axmProductFamily:     axmProductFamily,
            axmCoverageStatus:    axmCoverageStatus,
            axmCoverageEndDate:   axmCoverageEndDate,
            axmCoverageFetchedAt: fmt(axmCoverageFetchedAt),
            axmAgreementNumber:   axmAgreementNumber,
            wbStatus:             WBStatus(rawValue: wbStatus ?? ""),
            wbPushedAt:           fmt(wbPushedAt),
            wbNote:               wbNote,
            jamfId:               jamfId,
            jamfName:             jamfName,
            jamfManaged:          jamfManaged ? "True" : "False",
            jamfModel:            jamfModel,
            jamfModelIdentifier:  jamfModelIdentifier,
            jamfMacAddress:       jamfMacAddress,
            jamfReportDate:       fmt(jamfReportDate),
            jamfLastContact:      fmt(jamfLastContact),
            jamfLastEnrolled:     fmt(jamfLastEnrolled),
            jamfWarrantyDate:     jamfWarrantyDate,
            jamfVendor:           jamfVendor,
            jamfAppleCareId:      jamfAppleCareId,
            jamfOsVersion:        jamfOsVersion,
            jamfFileVaultStatus:  jamfFileVaultStatus,
            jamfUsername:         jamfUsername,
            jamfDeviceType:       jamfDeviceType,
            assignedMdmServerId:  assignedMdmServerId,
            assignedMdmServerName: assignedMdmServerName,
            mdmServerType:        mdmServerType,
            axmRawJson:           axmRawJson,
            axmCoverageRawJson:   axmCoverageRawJson
        )
    }
}

// MARK: - CDSyncRun helpers
extension CDSyncRun {
    static func create(in ctx: NSManagedObjectContext) -> CDSyncRun {
        let r       = CDSyncRun(context: ctx)
        r.id        = UUID()
        r.startedAt = Date()
        r.phase     = SyncPhase.idle.rawValue
        return r
    }
}

extension Notification.Name {
    static let persistenceLoadFailed = Notification.Name("com.karthikmac.axmjamfsync.persistenceLoadFailed")
}
