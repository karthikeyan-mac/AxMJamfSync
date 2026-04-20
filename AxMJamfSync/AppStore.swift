// AppStore.swift
// Single source of truth for the UI — @MainActor ObservableObject.
//
// Device loading:
//   - loadDevicesFromCoreData(): throttled (200ms debounce), background context,
//     suppressed during sync (SyncEngine sets suppressAutoReload=true).
//   - loadDevicesFromCoreDataSync(): ungated version for mid-sync UI refreshes.
//   - fetchAllDevicesForMerge(): background context, bypasses suppressAutoReload,
//     used by SyncEngine merge and stop-sync partial save.
//
// Filtering: debounced 200ms, runs off main thread, applyFilterNowSync() for sync checkpoints.
// CoreData: background context for all reads to prevent EXC_BAD_ACCESS on viewContext crossing.
// Scope: activeScope persisted in both UserDefaults and Keychain (.axmScope).
//        wipeCache() resets both stores to "business" (ABM default).

import SwiftUI
import CoreData

@MainActor
final class AppStore: ObservableObject {

    // MARK: - Dependencies
    let persistence:   PersistenceController
    let prefs:         AppPreferences
    /// Non-nil when running in multi-environment mode (v2.0+).
    let environmentId: UUID?

    // MARK: - Credentials
    @Published var axmCredentials:  AxMCredentials
    @Published var jamfCredentials: JamfCredentials

    // MARK: - Device data
    @Published var devices:         [Device]        = []   // full list, main thread
    @Published var filteredDevices: [Device]        = []   // debounced filtered result
    @Published var stats:           DashboardStats  = DashboardStats()
    @Published var hasData:         Bool            = false  // false after wipeCache / before first sync

    /// Sentinel value used in mdmServerFilter to filter AxM devices with no MDM assignment.
    nonisolated static let mdmUnassignedSentinel = "__unassigned__"

    /// Sorted unique MDM server names present in the current device list — drives the filter dropdown.
    var allMdmServerNames: [String] {
        let names = devices.compactMap { $0.assignedMdmServerName }.filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }
    /// Set synchronously in init from a CoreData row count — available before the async
    /// loadDevicesFromCoreData completes. Used for scope-lock UI that must be correct
    /// on the very first render, before hasData becomes true.
    @Published var cacheIsPopulated: Bool           = false

    // MARK: - Auth status
    @Published var axmAuthStatus:  AuthTestStatus = .idle
    @Published var jamfAuthStatus: AuthTestStatus = .idle

    // MARK: - Filter state
    @Published var deviceSourceFilter: DeviceSource?   = nil { didSet { scheduleFilter() } }
    @Published var coverageFilter:     CoverageStatus? = nil { didSet { scheduleFilter() } }
    @Published var wbFilter:           WBStatus?       = nil { didSet { scheduleFilter() } }
    @Published var deviceTypeFilter:   DeviceKind?     = nil { didSet { scheduleFilter() } }
    @Published var mdmServerFilter:    String?         = nil { didSet { scheduleFilter() } }  // assignedMdmServerName
    @Published var deviceSearchText:   String          = "" { didSet { scheduleFilter() } }

    // MARK: - Export
    @Published var exportColumns: [ExportColumn] = []

    // MARK: - Private
    private var filterTask: Task<Void, Never>?
    private var loadThrottleTask: Task<Void, Never>?
    /// Set true during sync to suppress auto-reload after each upsert batch.
    /// SyncEngine calls loadDevicesFromCoreDataSync() explicitly at safe checkpoints.
    var suppressAutoReload: Bool = false

    // MARK: - Init
    /// Placeholder init — uses an in-memory store so it never accidentally
    /// opens the v1 shared store. Replaced by buildServices() in EnvironmentStore.
    init(persistence: PersistenceController = PersistenceController(inMemory: true), prefs: AppPreferences? = nil) {
        self.persistence   = persistence
        self.prefs         = prefs ?? AppPreferences()
        self.environmentId = nil
        self.axmCredentials  = KeychainService.loadAxMCredentials()
        self.jamfCredentials = KeychainService.loadJamfCredentials()

        let saved = self.prefs.loadExportColumnEnabled()
        exportColumns = ExportColumn.defaultColumns.map { col in
            var c = col; if let on = saved[col.id] { c.enabled = on }; return c
        }

        // Synchronous CoreData row count — sets cacheIsPopulated and activeScope
        // BEFORE the async loadDevicesFromCoreData completes, so scope-lock UI
        // is correct on the very first render with no async race.
        let ctx = persistence.viewContext
        let countReq = NSFetchRequest<NSNumber>(entityName: "CDDevice")
        countReq.resultType = .countResultType
        let syncCount = (try? ctx.count(for: countReq)) ?? 0
        cacheIsPopulated = syncCount > 0

        loadDevicesFromCoreData()
        recomputeStats()

        // Restore the active scope (ABM vs ASM) on launch.
        //
        // The Keychain axm.scope key is the most reliable source — it is written
        // atomically with the credentials every time the user saves, so it always
        // reflects whichever scope actually has credentials stored.
        //
        // UserDefaults activeScope is only used as a tiebreaker when the Keychain
        // scope key is absent (e.g. first-ever launch or keychain wipe).
        //
        // Priority order:
        //   1. Keychain axm.scope — written with credentials, survives pref deletion & upgrades
        //   2. Infer from which scope has credentials in Keychain — handles legacy Keychain
        //      without axm.scope key (pre-scope-split versions)
        //   3. UserDefaults activeScope — last resort for edge cases
        //   4. Default to .business
        let persistedScope: AxMScope = {
            // 1. Keychain scope key — most reliable, written with credentials
            if let keychainScope = KeychainService.load(for: .axmScope),
               !keychainScope.isEmpty,
               let s = AxMScope(rawValue: keychainScope) { return s }
            // 2. Infer from which scope has credentials in Keychain
            let asmCreds = KeychainService.loadAxMCredentials(for: .school)
            let abmCreds = KeychainService.loadAxMCredentials(for: .business)
            if !asmCreds.clientId.isEmpty && abmCreds.clientId.isEmpty { return .school }
            if !abmCreds.clientId.isEmpty { return .business }
            // 3. UserDefaults — fallback when Keychain has no credentials at all
            if !self.prefs.activeScope.isEmpty,
               let s = AxMScope(rawValue: self.prefs.activeScope) { return s }
            // 4. Default
            return .business
        }()
        // Stamp resolved scope back to UserDefaults so it stays consistent
        if self.prefs.activeScope != persistedScope.rawValue {
            self.prefs.activeScope = persistedScope.rawValue
        }
        // If cache exists but dataCachedScope was lost (pref deletion), restore it
        // from the persisted scope so the scope-lock UI is correct immediately.
        if syncCount > 0 && self.prefs.dataCachedScope.isEmpty {
            self.prefs.dataCachedScope = persistedScope.rawValue
        }
        if axmCredentials.scope != persistedScope {
            var corrected = KeychainService.loadAxMCredentials(for: persistedScope)
            corrected.scope = persistedScope
            axmCredentials = corrected
        }
    }


    /// Per-environment init (v2.0) — uses isolated PersistenceController, AppPreferences,
    /// and credentials keyed by environment UUID.
    init(environment: AppEnvironment, persistence: PersistenceController, prefs: AppPreferences) {
        self.persistence   = persistence
        self.prefs         = prefs
        self.environmentId = environment.id

        self.axmCredentials  = KeychainService.loadAxMCredentialsForEnv(id: environment.id, scope: environment.scope)
        self.jamfCredentials = KeychainService.loadJamfCredentialsForEnv(id: environment.id)

        let saved = prefs.loadExportColumnEnabled()
        exportColumns = ExportColumn.defaultColumns.map { col in
            var c = col; if let on = saved[col.id] { c.enabled = on }; return c
        }

        let ctx       = persistence.viewContext
        let countReq  = NSFetchRequest<NSNumber>(entityName: "CDDevice")
        countReq.resultType = .countResultType
        let syncCount = (try? ctx.count(for: countReq)) ?? 0
        cacheIsPopulated = syncCount > 0

        if syncCount > 0 && prefs.dataCachedScope.isEmpty {
            prefs.dataCachedScope = environment.scope.rawValue
        }

        loadDevicesFromCoreData()
        recomputeStats()
    }

    // MARK: - CoreData load (throttled — at most once per 0.5s)
    func loadDevicesFromCoreData() {
        guard !suppressAutoReload else { return }  // SyncEngine controls reload timing during sync
        loadThrottleTask?.cancel()
        loadThrottleTask = Task { [weak self] in
            guard let self else { return }
            // Small coalesce window so rapid upsert batches don't each trigger a full reload
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            guard !Task.isCancelled else { return }

            // Fetch on a private background context so we never block the main thread.
            // CDDevice managed objects must not cross context boundaries — toDevice()
            // is called inside perform{} on the same context that owns the objects,
            // producing plain Swift structs (Device) that are safe to pass anywhere.
            let bgCtx = persistence.newBackgroundContext()
            bgCtx.undoManager = nil
            let mapped: [Device] = await bgCtx.perform {
                let req = CDDevice.fetchRequest()
                req.sortDescriptors = [NSSortDescriptor(key: "serialNumber", ascending: true)]
                req.returnsObjectsAsFaults = false
                let rows = (try? bgCtx.fetch(req)) ?? []
                return rows.map { $0.toDevice() }
            }
            do {
                self.devices = mapped
                self.hasData = !mapped.isEmpty
                self.cacheIsPopulated = self.hasData
                LogService.shared.debug("CoreData: loaded \(mapped.count) devices.")
            }
            recomputeStats()  // recomputeStats calls applyFilterNow internally
        }
    }

    // MARK: - CoreData load (synchronous wait — for use mid-pipeline when fresh data is needed)
    /// Synchronous CoreData reload used by SyncEngine at safe checkpoints.
    /// Unlike loadDevicesFromCoreData() this is NOT gated by suppressAutoReload,
    /// and it applies filters inline (not in a detached task) so Dashboard and
    /// Devices UI reflect new data immediately after each coverage/WB batch flush.
    func loadDevicesFromCoreDataSync() async {
        let bgCtx = persistence.newBackgroundContext()
        bgCtx.undoManager = nil
        let mapped: [Device] = await bgCtx.perform {
            let req = CDDevice.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "serialNumber", ascending: true)]
            req.returnsObjectsAsFaults = false
            let rows = (try? bgCtx.fetch(req)) ?? []
            return rows.map { $0.toDevice() }
        }
        self.devices = mapped
        self.hasData = !mapped.isEmpty
        self.cacheIsPopulated = self.hasData
        // recomputeStats then apply filters synchronously so UI updates immediately.
        // Do NOT use scheduleFilter() here — that debounces 200ms and runs detached,
        // which means the result may arrive after the next batch starts.
        recomputeStats()
        applyFilterNowSync()
    }

    /// Inline (synchronous) filter application — used only from loadDevicesFromCoreDataSync()
    /// so mid-sync batch flushes immediately update filteredDevices on the main thread.
    private func applyFilterNowSync() {
        let snapshot   = devices
        let srcFilter  = deviceSourceFilter
        let covFilter  = coverageFilter
        let wbF        = wbFilter
        let typeFilter = deviceTypeFilter
        let mdmFilter  = mdmServerFilter
        let searchText = deviceSearchText.lowercased()

        let result: [Device]
        if srcFilter == nil && covFilter == nil && wbF == nil && typeFilter == nil && mdmFilter == nil && searchText.isEmpty {
            result = snapshot
        } else {
            result = snapshot.filter { d in
                if let src  = srcFilter,  d.deviceSource  != src          { return false }
                if let cov  = covFilter,  d.coverageStatus != cov         { return false }
                if let kind = typeFilter, d.deviceKind    != kind         { return false }
                if let mdm = mdmFilter {
                    if mdm == AppStore.mdmUnassignedSentinel {
                        if d.axmAssignmentStatus != "Unassigned" { return false }
                    } else {
                        if d.assignedMdmServerName != mdm { return false }
                    }
                }
                if let wb = wbF {
                    if d.deviceSource == .axmOnly { return false }
                    if d.wbStatus != wb { return false }
                }
                if !searchText.isEmpty {
                    let serial = d.serialNumber.lowercased()
                    let name   = d.jamfName?.lowercased()  ?? ""
                    let model  = (d.jamfModel ?? d.axmModel)?.lowercased() ?? ""
                    if !serial.contains(searchText) &&
                       !name.contains(searchText)   &&
                       !model.contains(searchText)  { return false }
                }
                return true
            }
        }
        self.filteredDevices = result
    }

    // MARK: - CoreData upsert (background context, chunked batch — O(n) at 60k scale)
    func upsertDevices(_ incoming: [Device]) async {
        guard !incoming.isEmpty else { return }
        let ctx = persistence.newBackgroundContext()
        let chunkSize = 1_000
        let chunks = stride(from: 0, to: incoming.count, by: chunkSize).map {
            Array(incoming[$0 ..< min($0 + chunkSize, incoming.count)])
        }
        for chunk in chunks {
            await ctx.perform {
                CDDevice.batchUpsert(devices: chunk, in: ctx)
                self.persistence.save(ctx)
            }
        }
        // Force viewContext to merge the saved changes immediately.
        // automaticallyMergesChangesFromParent fires asynchronously via notification;
        // refreshAllObjects() makes it synchronous so loadDevicesFromCoreDataSync()
        // (called right after upsertDevices by SyncEngine) reads fresh data.
        persistence.viewContext.refreshAllObjects()
        LogService.shared.debug("CoreData: upserted \(incoming.count) device(s) in \(chunks.count) chunk(s).")
        loadDevicesFromCoreData()  // throttled — only fires when suppressAutoReload=false
    }

    /// Direct CoreData fetch for the sync merge step.
    /// Unlike store.devices (which depends on the throttled UI reload chain),
    /// this always reads the latest committed data from a fresh background context.
    /// Used exclusively by SyncEngine to get the correct existing-device snapshot
    /// for merging, regardless of suppressAutoReload or async timing.
    func fetchAllDevicesForMerge() async -> [Device] {
        let ctx = persistence.newBackgroundContext()
        return await ctx.perform {
            let req = CDDevice.fetchRequest()
            req.returnsObjectsAsFaults = false   // pre-fault all properties in one trip
            let rows = (try? ctx.fetch(req)) ?? []
            return rows.map { $0.toDevice() }
        }
    }

    // MARK: - Wipe
    func wipeCache() async {
        await persistence.deleteAllDevices()
        prefs.resetSyncTimestamps()
        prefs.activeScope     = AxMScope.business.rawValue
        prefs.dataCachedScope = ""   // release scope lock
        // Write scope reset to env-namespaced key in v2, flat key in v1
        if let envId = environmentId {
            KeychainService.saveForEnv(AxMScope.business.rawValue, key: "axm.scope", envId: envId)
        } else {
            KeychainService.save(AxMScope.business.rawValue, for: .axmScope)
        }
        hasData            = false
        cacheIsPopulated   = false
        devices            = []
        stats              = DashboardStats()
        filteredDevices    = []
        deviceSourceFilter = nil
        coverageFilter     = nil
        wbFilter           = nil
        deviceTypeFilter   = nil
        mdmServerFilter    = nil
        deviceSearchText   = ""
        // Reset auth so Sync tab becomes disabled (user must re-test auth to re-enable)
        axmAuthStatus      = .idle
        jamfAuthStatus     = .idle
        LogService.shared.info("Cache reset: CoreData wiped, timestamps cleared.")
    }

    // MARK: - Filtering (debounced 200ms, runs off main thread)
    func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms debounce
            guard !Task.isCancelled else { return }
            applyFilterNow()
        }
    }

    private func applyFilterNow() {
        let snapshot   = devices
        let srcFilter  = deviceSourceFilter
        let covFilter  = coverageFilter
        let wbF        = wbFilter
        let typeFilter = deviceTypeFilter
        let mdmFilter  = mdmServerFilter
        let searchText = deviceSearchText.lowercased()

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: [Device]
            if srcFilter == nil && covFilter == nil && wbF == nil && typeFilter == nil && mdmFilter == nil && searchText.isEmpty {
                result = snapshot
            } else {
                result = snapshot.filter { d in
                    if let src  = srcFilter,  d.deviceSource  != src  { return false }
                    if let cov  = covFilter,  d.coverageStatus != cov  { return false }
                    if let kind = typeFilter, d.deviceKind    != kind  { return false }
                    if let mdm = mdmFilter {
                        if mdm == AppStore.mdmUnassignedSentinel {
                            if d.axmAssignmentStatus != "Unassigned" { return false }
                        } else {
                            if d.assignedMdmServerName != mdm { return false }
                        }
                    }
                    if let wb = wbF {
                        if d.deviceSource == .axmOnly { return false }
                        if d.wbStatus != wb { return false }
                    }
                    if !searchText.isEmpty {
                        let serial = d.serialNumber.lowercased()
                        let name   = d.jamfName?.lowercased()  ?? ""
                        let model  = (d.jamfModel ?? d.axmModel ?? d.axmDeviceModel)?.lowercased() ?? ""
                        if !serial.contains(searchText) &&
                           !name.contains(searchText)   &&
                           !model.contains(searchText)  { return false }
                    }
                    return true
                }
            }
            await MainActor.run { [weak self] in self?.filteredDevices = result }
        }
    }

    // MARK: - Stats (single O(n) pass — no redundant .filter calls)
    func recomputeStats() {
        var s = DashboardStats()
        s.total = devices.count

        for d in devices {
            switch d.deviceSource {
            case .both:     s.both    += 1; s.axmTotal  += 1; s.jamfTotal += 1
            case .axmOnly:  s.axmOnly += 1; s.axmTotal  += 1
            case .jamfOnly: s.jamfOnly += 1; s.jamfTotal += 1
            }

            // AxM stats
            if d.deviceSource != .jamfOnly {
                let status = d.axmDeviceStatus?.uppercased() ?? ""
                if status == "ACTIVE"   { s.axmActive   += 1; s.exportActiveCount  += 1 }
                if status == "RELEASED" { s.axmReleased += 1; s.exportReleasedCount += 1 }
            }

            // Jamf stats
            if d.deviceSource != .axmOnly {
                if d.isManaged { s.jamfManaged += 1 } else { s.jamfUnmanaged += 1 }
            }

            // Coverage stats + P11 export preset counts (same pass, no extra filter)
            switch d.coverageStatus {
            case .active:
                s.coverageActive      += 1
                s.exportCovFoundCount  += 1
                s.exportCovActiveCount += 1
            case .inactive, .expired, .cancelled:
                s.coverageInactive      += 1
                s.exportCovFoundCount   += 1
                s.exportCovInactiveCount += 1
            case .noCoverage:
                s.coverageNoPlan  += 1
                s.exportNoCovCount += 1
            case .notFetched where d.deviceSource != .jamfOnly:
                s.coverageNeverFetched += 1
            default: break
            }

            // Write-back stats
            switch d.wbStatus {
            case .synced:  s.wbSynced  += 1
            case .pending: s.wbPending += 1
            case .failed:  s.wbFailed  += 1
            case .skipped: s.wbSkipped += 1
            case .none:    break
            }

            // MDM assignment stats — only for AxM devices
            if d.deviceSource != .jamfOnly, d.axmDeviceId != nil {
                if let serverName = d.assignedMdmServerName, !serverName.isEmpty {
                    s.mdmAssigned += 1
                    s.mdmServerBreakdown[serverName, default: 0] += 1
                } else {
                    s.mdmUnassigned += 1
                }
            }
        }

        s.lastAxmSync      = prefs.display(prefs.lastAxmSync)
        s.lastJamfSync     = prefs.display(prefs.lastJamfSync)
        s.lastCoverageSync = prefs.display(prefs.lastCoverageSync)

        stats = s
        // Also refresh filtered list after stats recalc (devices may have changed)
        applyFilterNow()
    }

    // MARK: - Credentials
    func saveAxMCredentials() {
        if let envId = environmentId {
            KeychainService.saveAxMCredentialsForEnv(axmCredentials, id: envId)
        } else {
            KeychainService.saveAxMCredentials(axmCredentials)
        }
    }
    func saveJamfCredentials() {
        if let envId = environmentId {
            KeychainService.saveJamfCredentialsForEnv(jamfCredentials, id: envId)
        } else {
            KeychainService.saveJamfCredentials(jamfCredentials)
        }
    }

    // MARK: - Export columns
    func saveExportColumns() { prefs.saveExportColumns(exportColumns) }

    // MARK: - Auth tests
    func testAxMAuth() async {
        guard !axmCredentials.clientId.isEmpty,
              !axmCredentials.keyId.isEmpty,
              !axmCredentials.privateKeyContent.isEmpty else {
            axmAuthStatus = .failure("Fill in Client ID, Key ID, and choose a private key file.")
            return
        }
        axmAuthStatus = .testing
        let svc = ABMService(credentials: axmCredentials)
        do {
            _ = try await svc.validToken()
            axmAuthStatus = .success("Token obtained successfully")
        } catch {
            axmAuthStatus = .failure(error.localizedDescription)
        }
    }

    func testJamfAuth() async {
        jamfAuthStatus = .testing
        do {

            guard !jamfCredentials.url.isEmpty,
                  !jamfCredentials.clientId.isEmpty,
                  !jamfCredentials.clientSecret.isEmpty else {
                jamfAuthStatus = .failure("Fill in all Jamf fields"); return
            }
            // S1: Use URLComponents to safely construct the URL — avoids broken URLs
            // when the base URL has a trailing slash or unexpected query characters.
            let base = jamfCredentials.url.hasSuffix("/")
                ? String(jamfCredentials.url.dropLast()) : jamfCredentials.url
            guard var components = URLComponents(string: base) else {
                jamfAuthStatus = .failure("Invalid Jamf URL"); return
            }
            components.path = "/api/v1/oauth/token"
            guard let url = components.url else {
                jamfAuthStatus = .failure("Invalid Jamf URL"); return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            func pct(_ s: String) -> String {
                s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                    .replacingOccurrences(of: "+", with: "%2B")
                    .replacingOccurrences(of: "&", with: "%26")
                    .replacingOccurrences(of: "=", with: "%3D") ?? s
            }
            req.httpBody = "grant_type=client_credentials&client_id=\(pct(jamfCredentials.clientId))&client_secret=\(pct(jamfCredentials.clientSecret))".data(using: .utf8)
            req.timeoutInterval = 15
            // P4: Use URLSession.shared instead of creating an ephemeral session per test.
            // The previous ephemeral session was never invalidated, leaking a connection pool
            // and background thread on every auth test.
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                jamfAuthStatus = http.statusCode == 200
                    ? .success("Authentication successful")
                    : .failure("HTTP \(http.statusCode) — check credentials")
            } else {
                jamfAuthStatus = .failure("No response from server")
            }
        } catch { jamfAuthStatus = .failure(error.localizedDescription) }
    }

    // MARK: - CSV builder
    /// Build CSV from an explicit device list (used by ExportView presets)
    func buildCSVData(from list: [Device]) -> Data {
        let enabled = exportColumns.filter(\.enabled)
        let nl      = Data([0x0A])  // \n byte
        let comma   = Data([0x2C])  // , byte
        var out     = Data()
        out.reserveCapacity(list.count * enabled.count * 12)  // rough pre-size

        func appendField(_ v: String) {
            if v.contains(",") || v.contains("\"") || v.contains("\n") {
                let escaped = "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\""
                out += escaped.data(using: .utf8) ?? Data()
            } else {
                out += v.data(using: .utf8) ?? Data()
            }
        }

        // Header row
        for (i, col) in enabled.enumerated() {
            if i > 0 { out += comma }
            appendField(col.label)
        }
        out += nl

        // Data rows — use list order (caller is responsible for sorting)
        for d in list {
            for (i, col) in enabled.enumerated() {
                if i > 0 { out += comma }
                appendField(d.value(for: col.id) ?? "")
            }
            out += nl
        }
        return out
    }

    func buildCSVData(allDevices: Bool) -> Data {
        buildCSVData(from: allDevices ? devices : filteredDevices)
    }

    func loadSampleData() { Task { await upsertDevices(Device.sampleDevices) } }
}

// MARK: - AuthTestStatus
enum AuthTestStatus: Equatable {
    case idle, testing, success(String), failure(String)
    var label: String {
        switch self {
        case .idle:           return ""
        case .testing:        return "Testing…"
        case .success(let m): return m
        case .failure(let m): return m
        }
    }
    var color: Color {
        switch self {
        case .idle, .testing: return .secondary
        case .success:        return .green
        case .failure:        return .red
        }
    }
    var icon: String? {
        switch self {
        case .idle, .testing: return nil
        case .success:        return "checkmark.circle.fill"
        case .failure:        return "xmark.circle.fill"
        }
    }
}

// MARK: - ExportColumn defaults + CSV accessor
extension ExportColumn {
    static let defaultColumns: [ExportColumn] = [
        .init(id: "serialNumber",          label: "Serial Number",           enabled: true),
        .init(id: "deviceSource",          label: "Device Source",           enabled: true),
        .init(id: "axmDeviceStatus",       label: "AxM Device Status",       enabled: true),
        .init(id: "axmAssignmentStatus",   label: "MDM Assignment",          enabled: true),
        .init(id: "assignedMdmServerName", label: "MDM Server",              enabled: true),
        .init(id: "mdmServerType",         label: "MDM Server Type",         enabled: false),
        .init(id: "axmCoverageStatus",     label: "Coverage Status",         enabled: true),
        .init(id: "axmCoverageEndDate",    label: "Coverage End Date",       enabled: true),
        .init(id: "axmAgreementNumber",    label: "AppleCare Agreement #",   enabled: true),
        .init(id: "axmPurchaseSource",     label: "Purchase Source",         enabled: true),
        .init(id: "wbStatus",              label: "Jamf Update Status",      enabled: true),
        .init(id: "wbPushedAt",            label: "Jamf Update Pushed At",   enabled: false),
        .init(id: "jamfName",              label: "Jamf Device Name",        enabled: true),
        .init(id: "jamfManaged",           label: "Managed",                 enabled: true),
        .init(id: "jamfModel",             label: "Model",                   enabled: true),
        .init(id: "jamfModelIdentifier",   label: "Model Identifier",        enabled: false),
        .init(id: "jamfMacAddress",        label: "MAC Address",             enabled: false),
        .init(id: "jamfReportDate",        label: "Report Date",             enabled: false),
        .init(id: "jamfLastContact",       label: "Last Contact",            enabled: true),
        .init(id: "jamfLastEnrolled",      label: "Last Enrolled",           enabled: false),
        .init(id: "jamfWarrantyDate",      label: "Jamf Warranty Date",      enabled: false),
        .init(id: "jamfVendor",            label: "Jamf Vendor",             enabled: false),
        .init(id: "jamfAppleCareId",       label: "Jamf AppleCare ID",       enabled: true),
        .init(id: "jamfId",                label: "Jamf ID",                 enabled: false),
        .init(id: "wbNote",                label: "Jamf Update Note",        enabled: false),
    ]
}

extension Device {
    func value(for col: String) -> String? {
        switch col {
        case "serialNumber":          return serialNumber
        case "deviceSource":          return deviceSource.label
        case "axmDeviceStatus":       return axmDeviceStatus
        case "axmAssignmentStatus":   return axmAssignmentStatus
        case "assignedMdmServerName": return assignedMdmServerName
        case "mdmServerType":         return mdmServerType.flatMap { MdmServerType(rawValue: $0)?.label } ?? mdmServerType
        case "axmCoverageStatus":     return coverageStatus.label
        case "axmCoverageEndDate":    return axmCoverageEndDate
        case "axmAgreementNumber":    return axmAgreementNumber
        case "axmPurchaseSource":     return axmPurchaseSource
        case "wbStatus":              return wbStatus?.label
        case "wbPushedAt":            return wbPushedAt
        case "wbNote":                return wbNote
        case "jamfName":              return jamfName
        case "jamfManaged":           return isManaged ? "Yes" : "No"
        case "jamfModel":             return jamfModel
        case "jamfModelIdentifier":   return jamfModelIdentifier
        case "jamfMacAddress":        return jamfMacAddress
        case "jamfReportDate":        return jamfReportDate
        case "jamfLastContact":       return jamfLastContact
        case "jamfLastEnrolled":      return jamfLastEnrolled
        case "jamfWarrantyDate":      return jamfWarrantyDate
        case "jamfVendor":            return jamfVendor
        case "jamfAppleCareId":       return jamfAppleCareId
        case "jamfId":                return jamfId
        default:                      return nil
        }
    }
}
