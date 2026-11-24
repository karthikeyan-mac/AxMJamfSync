// PersistenceController.swift
// CoreData stack (NSPersistentContainer) + CDDevice ↔ Device conversion.
//
// Schema: single CDDevice entity — all fields Optional String/Bool/Date.
// Background contexts: newBackgroundContext() for all reads and batch writes.
//   viewContext is NEVER used for .toDevice() mapping (EXC_BAD_ACCESS risk).
// Upsert: NSBatchInsertRequest is NOT used — crashes on Binary Data attributes
//   on Apple Silicon. Devices are upserted one-by-one inside perform{}.
// WAL + history tracking enabled for safe concurrent read/write.

@preconcurrency import CoreData
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

    /// Environment this store belongs to (nil for the in-memory placeholder and the
    /// legacy single-env store). Used by the deletion path to detach before wiping.
    nonisolated let environmentId: UUID?

    /// S7: non-nil when `loadPersistentStores` reported a failure. Written once, in
    /// init's load callback (synchronous for SQLite), on the same "mutated only
    /// around init" basis as `container` — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private(set) var storeLoadError: String? = nil
    var isStoreReady: Bool { storeLoadError == nil }

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

    /// Every device serial number in this store — single-column dictionary fetch,
    /// no object faulting. Used by DiagnosticsExporter to mask serials before a
    /// log file leaves the Mac in a shared bundle.
    func allSerialNumbers() -> [String] {
        let ctx = newBackgroundContext()
        return ctx.performAndWait {
            let req = NSFetchRequest<NSDictionary>(entityName: "CDDevice")
            req.resultType = .dictionaryResultType
            req.propertiesToFetch = ["serialNumber"]
            let rows = (try? ctx.fetch(req)) ?? []
            return rows.compactMap { $0["serialNumber"] as? String }
        }
    }

    // MARK: - Init

    /// Default init — uses legacy single-env store (AxMJamfSync.sqlite).
    /// Used only for the Default (v1-migrated) environment.
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "AxMJamfSync")
        environmentId = nil

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
        container.loadPersistentStores { [self] desc, error in
            if let error {
                os_log(.fault, "[CoreData] FATAL: failed to load store — %{public}@", error.localizedDescription)
                storeLoadError = error.localizedDescription
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
            self.init(storeURL: storeURL, environmentId: environmentId)
            return
        }

        // First v2.0 launch for the Default environment — copy v1 data.
        // Best-effort only: the authoritative, verify-before-commit migration runs in
        // EnvironmentStore.runMigration() and will normally have put the store in place
        // already. On failure stageAndVerifyV1Copy leaves no partial file behind, so
        // init(storeURL:) below just opens a fresh empty store.
        let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        if environmentId == defaultId {
            do {
                try PersistenceController.stageAndVerifyV1Copy(to: storeURL)
            } catch {
                os_log(.error, "[CoreData] first-launch v1 copy skipped — %{public}@", error.localizedDescription)
            }
        }

        self.init(storeURL: storeURL, environmentId: environmentId)
    }

    /// S4: copy the v1 SQLite store into `destURL` as a verified, complete set.
    ///
    /// The copy is staged next to the destination, loaded via NSPersistentContainer
    /// to prove it opens and holds the same number of devices as the v1 store, and
    /// only then moved atomically into place. On any failure the staging files are
    /// removed and the v1 store is left completely untouched — a half-written
    /// destination can never be mistaken for a finished one (and, because a present
    /// destination is what makes later launches skip the copy, that would otherwise
    /// be permanent). Returns the verified device count.
    @discardableResult
    static func stageAndVerifyV1Copy(to destURL: URL) throws -> Int {
        let fm   = FileManager.default
        let exts = ["", "-wal", "-shm"]
        let stagingURL = destURL.deletingPathExtension().appendingPathExtension("staging.sqlite")

        // Clear staging files left by a previously interrupted attempt.
        for ext in exts {
            let p = stagingURL.path + ext
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }

        // ── Open the v1 store: forces a WAL checkpoint and gives us its device count.
        let srcContainer = NSPersistentContainer(name: "AxMJamfSync")
        guard let desc = srcContainer.persistentStoreDescriptions.first else {
            throw MigrationError.storeCopyFailed("no store description")
        }
        desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        desc.shouldMigrateStoreAutomatically      = true
        desc.shouldInferMappingModelAutomatically = true

        var loadError: Error?
        srcContainer.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            throw MigrationError.storeCopyFailed("v1 store did not open: \(loadError.localizedDescription)")
        }
        guard let v1URL = srcContainer.persistentStoreCoordinator.persistentStores.first?.url else {
            throw MigrationError.storeCopyFailed("v1 store URL unresolved")
        }
        let v1Count = deviceCount(in: srcContainer)
        if v1Count < 0 { throw MigrationError.storeVerifyFailed("could not count v1 devices") }

        // Release the coordinator's lock so the file bytes are quiescent for copying.
        if let store = srcContainer.persistentStoreCoordinator.persistentStores.first {
            try? srcContainer.persistentStoreCoordinator.remove(store)
        }

        // ── Stage a copy of every sidecar file that exists.
        for ext in exts {
            let src = v1URL.path + ext
            guard fm.fileExists(atPath: src) else { continue }
            do {
                try fm.copyItem(atPath: src, toPath: stagingURL.path + ext)
            } catch {
                for e in exts { try? fm.removeItem(atPath: stagingURL.path + e) }
                throw MigrationError.storeCopyFailed(
                    "\(ext.isEmpty ? ".sqlite" : ext): \(error.localizedDescription)")
            }
        }

        // ── Verify the staged set actually loads and holds the expected count.
        do {
            let check = NSPersistentContainer(name: "AxMJamfSync")
            let cd    = NSPersistentStoreDescription(url: stagingURL)
            cd.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            cd.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            cd.shouldMigrateStoreAutomatically      = true
            cd.shouldInferMappingModelAutomatically = true
            check.persistentStoreDescriptions = [cd]

            var checkError: Error?
            check.loadPersistentStores { _, error in checkError = error }
            if let checkError {
                throw MigrationError.storeVerifyFailed("staged store did not open: \(checkError.localizedDescription)")
            }
            let stagedCount = deviceCount(in: check)
            guard stagedCount == v1Count else {
                throw MigrationError.storeVerifyFailed("device count \(stagedCount) != expected \(v1Count)")
            }
            if let store = check.persistentStoreCoordinator.persistentStores.first {
                try? check.persistentStoreCoordinator.remove(store)
            }
        } catch {
            for e in exts { try? fm.removeItem(atPath: stagingURL.path + e) }
            throw error
        }

        // ── Move the verified set into place: sidecars first, main file last, so an
        // interrupted move never leaves a valid-looking destination without its data.
        do {
            for ext in exts where !ext.isEmpty {
                let dst = destURL.path + ext
                if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                if fm.fileExists(atPath: stagingURL.path + ext) {
                    try fm.moveItem(atPath: stagingURL.path + ext, toPath: dst)
                }
            }
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(atPath: destURL.path) }
            try fm.moveItem(atPath: stagingURL.path, toPath: destURL.path)
        } catch {
            for e in exts { try? fm.removeItem(atPath: stagingURL.path + e) }
            throw MigrationError.storeCopyFailed("final move: \(error.localizedDescription)")
        }

        os_log(.default, "[CoreData] v1 store staged, verified (%d device(s)) and moved to %{public}@",
               v1Count, destURL.lastPathComponent)
        return v1Count
    }

    /// CDDevice row count for a loaded container, or -1 on failure.
    private static func deviceCount(in container: NSPersistentContainer) -> Int {
        let ctx = container.newBackgroundContext()
        return ctx.performAndWait {
            let req = NSFetchRequest<NSNumber>(entityName: "CDDevice")
            req.resultType = .countResultType
            return (try? ctx.count(for: req)) ?? -1
        }
    }

    /// On-disk URL of a specific environment's SQLite store.
    static func environmentStoreURL(_ id: UUID) -> URL {
        environmentsDirectory.appendingPathComponent("\(id.uuidString).sqlite")
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
    init(storeURL: URL, environmentId: UUID? = nil) {
        container = NSPersistentContainer(name: "AxMJamfSync")
        self.environmentId = environmentId
        let desc  = NSPersistentStoreDescription(url: storeURL)
        desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        desc.shouldMigrateStoreAutomatically      = true
        desc.shouldInferMappingModelAutomatically  = true
        container.persistentStoreDescriptions = [desc]

        container.loadPersistentStores { [self] _, error in
            if let error {
                os_log(.fault, "[CoreData] Failed to load store at %{public}@ — %{public}@",
                       storeURL.lastPathComponent, error.localizedDescription)
                storeLoadError = error.localizedDescription
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
        if let environmentId, storeLoadError == nil { PersistenceController.register(self, for: environmentId) }
    }

    // MARK: - v2.0 Environment teardown (S5)

    /// Process-wide weak registry of loaded per-environment stores, so the deletion
    /// path can detach a store's persistent coordinator BEFORE its SQLite files are
    /// removed — even when EnvironmentStore holds no strong reference to it (e.g. a
    /// store still retained by a background engine the user switched away from).
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var loadedStores: [UUID: WeakBox] = [:]
    private final class WeakBox { weak var value: PersistenceController?; init(_ v: PersistenceController) { value = v } }

    private static func register(_ controller: PersistenceController, for id: UUID) {
        registryLock.lock(); defer { registryLock.unlock() }
        loadedStores[id] = WeakBox(controller)
    }

    /// The live store for an environment, if one is still loaded anywhere in-process.
    static func loadedStore(for id: UUID) -> PersistenceController? {
        registryLock.lock(); defer { registryLock.unlock() }
        return loadedStores[id]?.value
    }

    /// Detach the persistent store from its coordinator and flush the WAL, releasing
    /// the file lock so the SQLite files can be safely deleted. Idempotent.
    func detach() {
        if let store = container.persistentStoreCoordinator.persistentStores.first {
            try? container.persistentStoreCoordinator.remove(store)
        }
        if let environmentId {
            PersistenceController.registryLock.lock()
            PersistenceController.loadedStores.removeValue(forKey: environmentId)
            PersistenceController.registryLock.unlock()
        }
    }

    /// Delete the SQLite store files for an environment (called on environment deletion).
    /// S5: throws on failure so the deletion path can refuse to drop the registry
    /// entry while data is still (partially) on disk. Detach the coordinator first.
    static func wipeEnvironment(id: UUID) throws {
        let envDir   = PersistenceController.environmentsDirectory
        let storeURL = envDir.appendingPathComponent("\(id.uuidString).sqlite")
        for ext in ["", "-wal", "-shm"] {
            let path = storeURL.path + ext
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
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

        let yesterday   = Date().addingTimeInterval(-86_400)
        let logFileName = storeURL.lastPathComponent
        let bgCtx       = container.newBackgroundContext()
        bgCtx.perform {
            // Build the request and touch UserDefaults inside the closure so no
            // non-Sendable value is captured across the @Sendable boundary.
            let purgeReq = NSPersistentHistoryChangeRequest.deleteHistory(before: yesterday)
            do {
                try bgCtx.execute(purgeReq)
                UserDefaults.standard.set(now, forKey: lastPurgeKey)
                os_log(.debug, "[CoreData] Persistent history purged for %{public}@.", logFileName)
            } catch {
                os_log(.error, "[CoreData] History purge error: %{public}@", error.localizedDescription)
            }
        }
    }
    // Both save() variants are nonisolated and synchronous.
    // They use print() for error reporting so they can be called from any context
    // without crossing actor boundaries. The caller (AppStore, which IS @MainActor)
    // can forward errors to LogService after the call returns.

    /// S7: returns whether the save succeeded (or was a no-op). Still logs on failure.
    @discardableResult
    func save() -> Bool {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return true }
        do   { try ctx.save(); return true }
        catch { os_log(.error, "[CoreData] view-context save error: %{public}@", error.localizedDescription); return false }
    }

    /// S7: returns whether the save succeeded (or was a no-op). Callers that persist
    /// sync results (AppStore.upsertDevices) MUST check this — a swallowed failure
    /// here is exactly how a partial run used to report success.
    @discardableResult
    func save(_ ctx: NSManagedObjectContext) -> Bool {
        guard ctx.hasChanges else { return true }
        do   { try ctx.save(); return true }
        catch { os_log(.error, "[CoreData] background-context save error: %{public}@", error.localizedDescription); return false }
    }

    /// S3: throwing counterpart of `save(_:)`. The resume-cursor checkpoint path
    /// advances the cursor only after this returns without throwing, so a failed
    /// batch commit can never leave the cursor ahead of the data on disk.
    func saveOrThrow(_ ctx: NSManagedObjectContext) throws {
        guard ctx.hasChanges else { return }
        try ctx.save()
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

    // MARK: - S2: Jamf mapping revalidation gate
    /// Mark every device that carries a Jamf-ID mapping as pending revalidation.
    /// Called by AppStore.saveJamfCredentials() the instant the Jamf URL/clientId
    /// changes — until each serial is re-matched against the newly configured host,
    /// write-back must not PATCH by the (now untrusted) cached jamfId.
    /// One NSBatchUpdateRequest; changes are merged straight into viewContext.
    func markJamfMappingsPendingRevalidation() async {
        let container = self.container
        let viewCtx   = container.viewContext
        let bgCtx     = container.newBackgroundContext()
        bgCtx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        await bgCtx.perform {
            let req = NSBatchUpdateRequest(entityName: "CDDevice")
            req.predicate = NSPredicate(format: "jamfId != nil")
            req.propertiesToUpdate = [
                "jamfValidationStatus": JamfValidationStatus.pendingRevalidation.rawValue
            ]
            req.resultType = .updatedObjectIDsResultType
            do {
                let result = try bgCtx.execute(req) as? NSBatchUpdateResult
                let ids    = result?.result as? [NSManagedObjectID] ?? []
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSUpdatedObjectsKey: ids],
                    into: [viewCtx])
                os_log(.default, "[CoreData] S2: %d device mapping(s) marked pendingRevalidation.", ids.count)
            } catch {
                os_log(.error, "[CoreData] S2 batch update error: %{public}@", error.localizedDescription)
            }
        }
        viewCtx.refreshAllObjects()
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

    // ISO8601DateFormatter is not Sendable-audited by Apple — nonisolated(unsafe) per
    // the ARCHITECTURE.md "Swift 6 concurrency" rule (the formatter is only read).
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // P3: Second static for the non-fractional fallback (Jamf dates without milliseconds).
    // Previously this was allocated fresh on every parseISO call — at 50k devices × 3 date
    // fields = 150k allocations per sync. Static allocation pays once at first use.
    nonisolated(unsafe) private static let isoNoFrac: ISO8601DateFormatter = {
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
        axmAddedToOrgDate   = d.axmAddedToOrgDate
        axmModel            = d.axmModel
        axmDeviceModel      = d.axmDeviceModel
        axmDeviceClass      = d.axmDeviceClass
        axmProductFamily    = d.axmProductFamily
        axmCoverageStatus   = d.axmCoverageStatus
        axmCoverageEndDate  = d.axmCoverageEndDate
        axmAgreementNumber  = d.axmAgreementNumber
        axmWifiMacAddress      = d.axmWifiMacAddress
        axmBluetoothMacAddress = d.axmBluetoothMacAddress
        axmEthernetMacAddress  = d.axmEthernetMacAddress
        axmImei                = d.axmImei
        axmMeid                = d.axmMeid
        axmEid                 = d.axmEid
        // Written to axmMdmMigrationCapableRaw (String), not axmMdmMigrationCapable
        // (Boolean) — see the schema comment on axmMdmMigrationCapableRaw for why.
        axmMdmMigrationCapableRaw = d.axmMdmMigrationCapable
        axmMdmMigrationStatus  = d.axmMdmMigrationStatus
        axmMdmMigrationDeadline = d.axmMdmMigrationDeadline
        axmActivationLock = d.axmActivationLock
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
        jamfProcessorType   = d.jamfProcessorType
        jamfInitialEntryDate = d.jamfInitialEntryDate
        jamfRamGB           = d.jamfRamGB
        // Written to jamfMdmCertExpirationRaw (String), not the legacy jamfMdmCertExpiration
        // (Date) attribute — see the schema comment on jamfMdmCertExpirationRaw for why.
        jamfMdmCertExpirationRaw = d.jamfMdmCertExpiration
        assignedMdmServerId   = d.assignedMdmServerId
        assignedMdmServerName = d.assignedMdmServerName
        mdmServerType         = d.mdmServerType
        jamfValidationStatus     = d.jamfValidationStatus
        lastValidatedJamfOrigin  = d.lastValidatedJamfOrigin

        // Raw Apple API JSON — only overwrite when the incoming value is non-nil
        // so a Jamf-only merge pass doesn't null out previously stored Apple blobs.
        if let json = d.axmRawJson         { axmRawJson         = json }
        if let json = d.axmCoverageRawJson { axmCoverageRawJson = json }

        let parseISO = CDDevice.parseISO
        axmDeviceFetchedAt   = d.axmDeviceFetchedAt.flatMap  { parseISO($0) }
        axmCoverageFetchedAt = d.axmCoverageFetchedAt.flatMap { parseISO($0) }
        axmActivationLockFetchedAt = d.axmActivationLockFetchedAt.flatMap { parseISO($0) }
        wbPushedAt           = d.wbPushedAt.flatMap          { parseISO($0) }
        jamfReportDate       = d.jamfReportDate.flatMap       { parseISO($0) }
        jamfLastContact      = d.jamfLastContact.flatMap      { parseISO($0) }
        jamfLastEnrolled     = d.jamfLastEnrolled.flatMap     { parseISO($0) }
        // Legacy jamfMdmCertExpiration (Date) attribute is intentionally never
        // written to anymore — see jamfMdmCertExpirationRaw above and its schema comment.
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
            axmAddedToOrgDate:    axmAddedToOrgDate,
            axmModel:             axmModel,
            axmDeviceModel:       axmDeviceModel,
            axmDeviceClass:       axmDeviceClass,
            axmProductFamily:     axmProductFamily,
            axmCoverageStatus:    axmCoverageStatus,
            axmCoverageEndDate:   axmCoverageEndDate,
            axmCoverageFetchedAt: fmt(axmCoverageFetchedAt),
            axmAgreementNumber:   axmAgreementNumber,
            axmWifiMacAddress:    axmWifiMacAddress,
            axmBluetoothMacAddress: axmBluetoothMacAddress,
            axmEthernetMacAddress: axmEthernetMacAddress,
            axmImei:              axmImei,
            axmMeid:              axmMeid,
            axmEid:               axmEid,
            axmMdmMigrationCapable: axmMdmMigrationCapableRaw,
            axmMdmMigrationStatus: axmMdmMigrationStatus,
            axmMdmMigrationDeadline: axmMdmMigrationDeadline,
            axmActivationLock: axmActivationLock,
            axmActivationLockFetchedAt: fmt(axmActivationLockFetchedAt),
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
            jamfMdmCertExpiration: jamfMdmCertExpirationRaw,
            jamfInitialEntryDate: jamfInitialEntryDate,
            jamfProcessorType:    jamfProcessorType,
            jamfRamGB:            jamfRamGB,
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
            jamfValidationStatus:   jamfValidationStatus,
            lastValidatedJamfOrigin: lastValidatedJamfOrigin,
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
