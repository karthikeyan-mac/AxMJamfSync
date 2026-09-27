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
    // S9: per-environment log (shared singleton only for the non-environment placeholder).
    let log:           LogService
    /// Non-nil when running in multi-environment mode (v2.0+).
    let environmentId: UUID?
    /// For log readability only (SyncEngine's run header) — never used for any
    /// lookup or identity decision, environmentId is. Captured once at construction,
    /// so a same-session rename doesn't retroactively update it until this
    /// environment's services are next rebuilt (switching to it, or relaunch) —
    /// acceptable since it's cosmetic, and log files stay UUID-stemmed regardless
    /// (S9 — names are mutable/can collide, UUIDs are the stable identity).
    let environmentName: String

    // MARK: - Credentials
    @Published var axmCredentials:  AxMCredentials
    @Published var jamfCredentials: JamfCredentials

    // MARK: - Device data
    @Published var devices:         [Device]        = []   // full list, main thread
    @Published var filteredDevices: [Device]        = []   // debounced filtered result
    /// Bumped every time filteredDevices is reassigned after a filter/search change.
    /// DeviceListPanel keys its List on this so SwiftUI remounts fresh instead of
    /// diffing old-vs-new row identities — the diff itself (not its animation) is
    /// what beachballs when the array swings from a small filtered set back to a
    /// large unfiltered one (e.g. clearing a filter on a 20k+ device environment).
    @Published private(set) var filterGeneration: Int = 0
    @Published var stats:           DashboardStats  = DashboardStats()
    @Published var hasData:         Bool            = false  // false after wipeCache / before first sync

    /// S7: set true by `upsertDevices` the moment any Core Data save fails, and left
    /// true until `resetPersistenceFailureFlag()` clears it at the start of the next
    /// run. SyncEngine reads it at the end of a run so a swallowed save failure can
    /// never let the run report `.success`.
    @Published private(set) var persistenceFailure: Bool = false
    func resetPersistenceFailureFlag() { persistenceFailure = false }

    /// S7: false when this environment's Core Data store failed to load. SyncEngine
    /// refuses to start a run against an unavailable store.
    var isStoreReady: Bool { persistence.isStoreReady }

    /// Sentinel value used in mdmServerFilter to filter AxM devices with no MDM assignment.
    nonisolated static let mdmUnassignedSentinel = "__unassigned__"
    /// Sentinel value used in mdmServerFilter to filter AxM devices assigned to ANY MDM
    /// server — used by the Dashboard's "Assigned" drill-down, which has no single server
    /// name to match against.
    nonisolated static let mdmAssignedSentinel   = "__assigned__"

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

    // MARK: - Dashboard drill-down filter state
    // These don't have their own dropdown in the Devices tab's filter bar (see
    // DevicesView's dashboardDrillDownDescription) — they exist purely so a tap on a
    // Dashboard data point can land on a pre-filtered Devices list. Each is matched
    // against the exact same per-device classification recomputeStats() uses (see the
    // static helpers below), so a drill-down always shows precisely the devices that
    // were counted in the number that was tapped.
    @Published var axmStatusFilter:        String?  = nil { didSet { scheduleFilter() } }  // raw axmDeviceStatus, e.g. "ACTIVE"/"RELEASED"
    @Published var productFamilyFilter:    String?  = nil { didSet { scheduleFilter() } }  // AppStore.productFamilyLabel(for:)
    @Published var purchaseSourceFilter:   String?  = nil { didSet { scheduleFilter() } }  // AppStore.purchaseSourceLabel(for:)
    @Published var addedToOrgYearFilter:   String?  = nil { didSet { scheduleFilter() } }  // AppStore.addedToOrgYearLabel(for:)
    @Published var jamfManagedFilter:      Bool?    = nil { didSet { scheduleFilter() } }
    @Published var osVersionFilter:        String?  = nil { didSet { scheduleFilter() } }  // AppStore.osMajorVersionLabel(for:) — pair with deviceTypeFilter to pick Mac vs Mobile
    @Published var fileVaultFilter:        String?  = nil { didSet { scheduleFilter() } }  // AppStore.fileVaultLabel(for:)
    @Published var checkinFreshnessFilter: String?  = nil { didSet { scheduleFilter() } }  // AppStore.checkinBucketLabel(for:)
    @Published var expiringWindowFilter:   String?  = nil { didSet { scheduleFilter() } }  // AppStore.expiringWindowLabel(for:)
    @Published var mdmMigrationCapableFilter: String? = nil { didSet { scheduleFilter() } }  // AppStore.mdmMigrationCapableLabel(for:)
    @Published var certExpiringWindowFilter: String? = nil { didSet { scheduleFilter() } }  // AppStore.certExpiringWindowLabel(for:)
    @Published var architectureFilter:       String? = nil { didSet { scheduleFilter() } }  // AppStore.architectureLabel(for:)
    @Published var ramFilter:                String? = nil { didSet { scheduleFilter() } }  // AppStore.ramLabel(for:)
    @Published var osBehindFilter:           String? = nil { didSet { scheduleFilter() } }  // AppStore.osBehindLabel(for:latestVersion:) — paired with osBehindLatestVersionFilter
    @Published var osBehindLatestVersionFilter: Int? = nil { didSet { scheduleFilter() } }  // fleet-latest major version captured at tap time, so the drill-down classifies devices against the exact same "latest" the tapped card counted
    @Published var axmMigrationStatusFilter: String? = nil { didSet { scheduleFilter() } }  // AppStore.axmMigrationStatusLabel(for:)
    @Published var migrationDeadlineWindowFilter: String? = nil { didSet { scheduleFilter() } }  // AppStore.migrationDeadlineWindowLabel(for:)

    /// Resets every device-list filter, old and new — used by "Clear all filters" in
    /// DevicesView and by wipeCache().
    func clearDeviceFilters() {
        deviceSourceFilter    = nil
        coverageFilter        = nil
        wbFilter              = nil
        deviceTypeFilter      = nil
        mdmServerFilter       = nil
        deviceSearchText      = ""
        axmStatusFilter       = nil
        productFamilyFilter   = nil
        purchaseSourceFilter  = nil
        addedToOrgYearFilter  = nil
        jamfManagedFilter     = nil
        osVersionFilter       = nil
        fileVaultFilter       = nil
        checkinFreshnessFilter = nil
        expiringWindowFilter  = nil
        mdmMigrationCapableFilter = nil
        certExpiringWindowFilter = nil
        architectureFilter    = nil
        ramFilter             = nil
        osBehindFilter        = nil
        osBehindLatestVersionFilter = nil
        axmMigrationStatusFilter = nil
        migrationDeadlineWindowFilter = nil
    }

    /// Human-readable description of the Dashboard drill-down filters specifically —
    /// the ones that don't have their own dropdown in the Devices tab's filter bar (see
    /// DevicesView), so a chip banner is the only way to show the user why the list
    /// looks the way it does after a Dashboard tap. Filters that DO have a dropdown
    /// (source, coverage, write-back, type, MDM server) show their own state in that
    /// dropdown already, so they're not repeated here.
    var dashboardDrillDownDescription: String? {
        if let v = axmStatusFilter       { return "AxM Status: \(v.capitalized)" }
        if let v = productFamilyFilter   { return "Product Family: \(v)" }
        if let v = purchaseSourceFilter  { return "Purchase Source: \(v)" }
        if let v = addedToOrgYearFilter  { return "Added to Org: \(v)" }
        if let v = jamfManagedFilter     { return v ? "Jamf: Managed" : "Jamf: Unmanaged" }
        if let v = osVersionFilter       { return "OS Version: \(v)" }
        if let v = fileVaultFilter       { return "FileVault: \(v)" }
        if let v = checkinFreshnessFilter { return "Check-in: \(v)" }
        if let v = expiringWindowFilter  { return "Expiring: \(v) days" }
        if let v = mdmMigrationCapableFilter { return "MDM Migration: \(v)" }
        if let v = certExpiringWindowFilter { return "MDM Cert Expiring: \(v) days" }
        if let v = architectureFilter    { return "Architecture: \(v)" }
        if let v = ramFilter             { return "RAM: \(v)" }
        if let v = osBehindFilter        { return "OS Version: \(v)" }
        if let v = axmMigrationStatusFilter { return "Migration Status: \(v)" }
        if let v = migrationDeadlineWindowFilter { return "Migration Deadline: \(v) days" }
        return nil
    }

    /// Clears only the Dashboard drill-down filters (see dashboardDrillDownDescription),
    /// leaving the Devices tab's own dropdown filters untouched.
    func clearDrillDownFilters() {
        axmStatusFilter        = nil
        productFamilyFilter    = nil
        purchaseSourceFilter   = nil
        addedToOrgYearFilter   = nil
        jamfManagedFilter      = nil
        osVersionFilter        = nil
        fileVaultFilter        = nil
        checkinFreshnessFilter = nil
        expiringWindowFilter   = nil
        mdmMigrationCapableFilter = nil
        certExpiringWindowFilter = nil
        architectureFilter     = nil
        ramFilter              = nil
        osBehindFilter         = nil
        osBehindLatestVersionFilter = nil
        axmMigrationStatusFilter = nil
        migrationDeadlineWindowFilter = nil
    }

    /// Convenience for Dashboard drill-down taps: clears every existing filter first,
    /// then applies only the dimension(s) passed in — so a tap always lands on exactly
    /// the devices it counted, with no leftover filter from wherever the person was
    /// before. Pass only the parameter(s) relevant to the tapped element.
    func drillDown(source: DeviceSource? = nil, coverage: CoverageStatus? = nil, wb: WBStatus? = nil,
                   deviceType: DeviceKind? = nil, mdmServer: String? = nil,
                   axmStatus: String? = nil, productFamily: String? = nil, purchaseSource: String? = nil,
                   addedToOrgYear: String? = nil, jamfManaged: Bool? = nil, osVersion: String? = nil,
                   fileVault: String? = nil, checkin: String? = nil, expiringWindow: String? = nil,
                   mdmMigrationCapable: String? = nil, certExpiringWindow: String? = nil,
                   architecture: String? = nil, ram: String? = nil,
                   osBehind: String? = nil, osBehindLatestVersion: Int? = nil,
                   axmMigrationStatus: String? = nil, migrationDeadlineWindow: String? = nil) {
        clearDeviceFilters()
        deviceSourceFilter     = source
        coverageFilter         = coverage
        wbFilter               = wb
        deviceTypeFilter       = deviceType
        mdmServerFilter        = mdmServer
        axmStatusFilter        = axmStatus
        productFamilyFilter    = productFamily
        purchaseSourceFilter   = purchaseSource
        addedToOrgYearFilter   = addedToOrgYear
        jamfManagedFilter      = jamfManaged
        osVersionFilter        = osVersion
        fileVaultFilter        = fileVault
        checkinFreshnessFilter = checkin
        expiringWindowFilter   = expiringWindow
        mdmMigrationCapableFilter = mdmMigrationCapable
        certExpiringWindowFilter = certExpiringWindow
        architectureFilter     = architecture
        ramFilter              = ram
        osBehindFilter         = osBehind
        osBehindLatestVersionFilter = osBehindLatestVersion
        axmMigrationStatusFilter = axmMigrationStatus
        migrationDeadlineWindowFilter = migrationDeadlineWindow
    }

    // MARK: - Export
    @Published var exportColumns: [ExportColumn] = []

    /// S2: invoked by saveJamfCredentials() when the Jamf URL/clientId change invalidates
    /// the cached serial→Jamf-ID mapping. Wired by EnvironmentStore.buildServices() to
    /// queue a full Jamf inventory re-fetch. nil in the placeholder / v1 store.
    var onJamfRebindingDetected: (() -> Void)?

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
        self.persistence     = persistence
        self.prefs           = prefs ?? AppPreferences()
        self.environmentId   = nil
        self.environmentName = "Default"
        self.log             = .shared
        self.axmCredentials  = KeychainService.loadAxMCredentials()
        self.jamfCredentials = KeychainService.loadJamfCredentials()

        exportColumns = self.prefs.loadExportColumns()

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
        self.persistence     = persistence
        self.prefs           = prefs
        self.environmentId   = environment.id
        self.environmentName = environment.name
        self.log             = LogService.makeForEnvironment(id: environment.id)

        self.axmCredentials  = KeychainService.loadAxMCredentialsForEnv(id: environment.id, scope: environment.scope)
        self.jamfCredentials = KeychainService.loadJamfCredentialsForEnv(id: environment.id)

        // S2: seed the validated-origin baseline from whatever Jamf host is currently
        // configured. Pre-fix behaviour trusted the cached serial→Jamf-ID map
        // unconditionally, so on first run after upgrade the existing mapping is
        // considered validated against the current host — a later URL/clientId change
        // is what trips revalidation, not the upgrade itself.
        if prefs.jamfValidatedOrigin.isEmpty, !jamfCredentials.url.isEmpty {
            prefs.jamfValidatedOrigin = jamfCredentials.canonicalOrigin
        }

        exportColumns = prefs.loadExportColumns()

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
                log.debug("CoreData: loaded \(mapped.count) devices.")
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
    // Drill-down filters only — factored out so applyFilterNowSync and applyFilterNow
    // (which otherwise duplicate their whole predicate) can't drift out of sync on
    // these newer checks. Each guard mirrors the exact same deviceSource scoping
    // recomputeStats() uses for that field, so a drill-down always shows precisely
    // the devices the tapped number was counting.
    private nonisolated static func matchesDrillDownFilters(_ d: Device,
        axmStatus: String?, productFamily: String?, purchaseSource: String?,
        addedToOrgYear: String?, jamfManaged: Bool?, osVersion: String?,
        fileVault: String?, checkin: String?, expiringWindow: String?,
        mdmMigrationCapable: String?, certExpiringWindow: String?,
        architecture: String?, ram: String?,
        osBehind: String?, osBehindLatestVersion: Int?,
        axmMigrationStatus: String?, migrationDeadlineWindow: String?
    ) -> Bool {
        if let st = axmStatus {
            guard d.deviceSource != .jamfOnly, (d.axmDeviceStatus?.uppercased() ?? "") == st else { return false }
        }
        if let pf = productFamily {
            guard d.deviceSource != .jamfOnly, Self.productFamilyLabel(for: d) == pf else { return false }
        }
        if let ps = purchaseSource {
            guard d.deviceSource != .jamfOnly, Self.purchaseSourceLabel(for: d) == ps else { return false }
        }
        if let yr = addedToOrgYear {
            guard d.deviceSource != .jamfOnly, Self.addedToOrgYearLabel(for: d) == yr else { return false }
        }
        if let jm = jamfManaged {
            guard d.deviceSource != .axmOnly, d.isManaged == jm else { return false }
        }
        if let ov = osVersion {
            guard d.deviceSource != .axmOnly, Self.osMajorVersionLabel(for: d) == ov else { return false }
        }
        if let fv = fileVault {
            guard d.deviceSource != .axmOnly, d.jamfDeviceType == "computer", Self.fileVaultLabel(for: d) == fv else { return false }
        }
        if let ck = checkin {
            guard d.deviceSource != .axmOnly, Self.checkinBucketLabel(for: d) == ck else { return false }
        }
        if let ew = expiringWindow {
            guard d.deviceSource != .jamfOnly, Self.expiringWindowLabel(for: d) == ew else { return false }
        }
        if let mc = mdmMigrationCapable {
            guard d.deviceSource != .jamfOnly, d.axmDeviceId != nil, Self.mdmMigrationCapableLabel(for: d) == mc else { return false }
        }
        if let ce = certExpiringWindow {
            guard d.deviceSource != .axmOnly, Self.certExpiringWindowLabel(for: d) == ce else { return false }
        }
        if let arch = architecture {
            guard d.deviceSource != .axmOnly, d.jamfDeviceType == "computer", Self.architectureLabel(for: d) == arch else { return false }
        }
        if let r = ram {
            guard d.deviceSource != .axmOnly, d.jamfDeviceType == "computer", Self.ramLabel(for: d) == r else { return false }
        }
        if let ob = osBehind {
            guard d.deviceSource != .axmOnly, Self.osBehindLabel(for: d, latestVersion: osBehindLatestVersion) == ob else { return false }
        }
        if let ms = axmMigrationStatus {
            guard d.deviceSource != .jamfOnly, d.axmDeviceId != nil, Self.axmMigrationStatusLabel(for: d) == ms else { return false }
        }
        if let mdw = migrationDeadlineWindow {
            guard d.deviceSource != .jamfOnly, d.axmDeviceId != nil, Self.migrationDeadlineWindowLabel(for: d) == mdw else { return false }
        }
        return true
    }

    /// Shared MDM assigned/unassigned/named-server classification — was
    /// duplicated verbatim in matchesDeviceFilters and matchesAxmDashboardFacets
    /// (ARCHITECTURE.md: every per-device classification must live in exactly
    /// one shared helper, precisely so a drill-down can never show a different
    /// set of devices than the tapped count implied). jamfOnly devices are never
    /// "assigned" — an AxM MDM-server assignment is an AxM-domain concept a
    /// jamfOnly device has no real claim to, even if a stale mdmServerLookup
    /// entry still names one (see the merge-time MDM patch in SyncEngine) —
    /// matching the population guard matchesAxmDashboardFacets already applies.
    private nonisolated static func matchesMdmFacet(_ d: Device, mdm: String?) -> Bool {
        guard let mdm else { return true }
        guard d.deviceSource != .jamfOnly else { return false }
        if mdm == AppStore.mdmUnassignedSentinel {
            return d.axmAssignmentStatus == "Unassigned"
        } else if mdm == AppStore.mdmAssignedSentinel {
            return d.axmAssignmentStatus != "Unassigned" && d.axmAssignmentStatus != nil
        } else {
            return d.assignedMdmServerName == mdm
        }
    }

    /// 4.2: single predicate for the Devices tab filters (dropdowns + search +
    /// Dashboard drill-down), shared by the debounced async path (`applyFilterNow`)
    /// and the synchronous mid-sync path (`applyFilterNowSync`) — those two had
    /// silently drifted (one searched 2 model fields, the other 3). Never
    /// reimplement this filter inline at a third call site.
    private nonisolated static func matchesDeviceFilters(_ d: Device,
        source: DeviceSource?, coverage: CoverageStatus?, kind: DeviceKind?, mdm: String?,
        wb: WBStatus?, searchText: String, noDrillDown: Bool,
        axmStatus: String?, productFamily: String?, purchaseSource: String?,
        addedToOrgYear: String?, jamfManaged: Bool?, osVersion: String?,
        fileVault: String?, checkin: String?, expiringWindow: String?,
        mdmMigrationCapable: String?, certExpiringWindow: String?,
        architecture: String?, ram: String?,
        osBehind: String?, osBehindLatestVersion: Int?,
        axmMigrationStatus: String?, migrationDeadlineWindow: String?
    ) -> Bool {
        if let src = source,   d.deviceSource  != src  { return false }
        if let cov = coverage, d.coverageStatus != cov  { return false }
        if let k   = kind,     d.deviceKind     != k    { return false }
        guard Self.matchesMdmFacet(d, mdm: mdm) else { return false }
        if let wb {
            if d.deviceSource == .axmOnly { return false }
            if d.wbStatus != wb { return false }
        }
        if !searchText.isEmpty {
            // 5.1: matched fields beyond serial/name/model — username, Jamf ID,
            // AppleCare agreement #, MDM server, order number, model identifier.
            // Collected into one array rather than a chain of individual
            // `?? "" .contains` checks so adding a future field is a one-line diff.
            let haystacks = [
                d.serialNumber, d.jamfName, d.jamfModel, d.axmModel, d.axmDeviceModel,
                d.jamfUsername, d.jamfId, d.axmAgreementNumber, d.assignedMdmServerName,
                d.axmOrderNumber, d.jamfModelIdentifier
            ]
            guard haystacks.contains(where: { $0?.lowercased().contains(searchText) == true }) else { return false }
        }
        if !noDrillDown, !Self.matchesDrillDownFilters(d,
            axmStatus: axmStatus, productFamily: productFamily, purchaseSource: purchaseSource,
            addedToOrgYear: addedToOrgYear, jamfManaged: jamfManaged, osVersion: osVersion,
            fileVault: fileVault, checkin: checkin, expiringWindow: expiringWindow,
            mdmMigrationCapable: mdmMigrationCapable, certExpiringWindow: certExpiringWindow,
            architecture: architecture, ram: ram,
            osBehind: osBehind, osBehindLatestVersion: osBehindLatestVersion,
            axmMigrationStatus: axmMigrationStatus, migrationDeadlineWindow: migrationDeadlineWindow) { return false }
        return true
    }

    private func applyFilterNowSync() {
        let snapshot   = devices
        let srcFilter  = deviceSourceFilter
        let covFilter  = coverageFilter
        let wbF        = wbFilter
        let typeFilter = deviceTypeFilter
        let mdmFilter  = mdmServerFilter
        let searchText = deviceSearchText.lowercased()
        let axmStatusF = axmStatusFilter
        let familyF    = productFamilyFilter
        let purchaseF  = purchaseSourceFilter
        let yearF      = addedToOrgYearFilter
        let managedF   = jamfManagedFilter
        let osVerF     = osVersionFilter
        let fvF        = fileVaultFilter
        let checkinF   = checkinFreshnessFilter
        let expiringF  = expiringWindowFilter
        let mdmCapF    = mdmMigrationCapableFilter
        let certExpF   = certExpiringWindowFilter
        let archF      = architectureFilter
        let ramF       = ramFilter
        let osBehindF  = osBehindFilter
        let osBehindLatestF = osBehindLatestVersionFilter
        let axmMigStatusF = axmMigrationStatusFilter
        let migDeadlineF  = migrationDeadlineWindowFilter
        let noDrillDown = axmStatusF == nil && familyF == nil && purchaseF == nil && yearF == nil
                       && managedF == nil && osVerF == nil && fvF == nil && checkinF == nil && expiringF == nil
                       && mdmCapF == nil && certExpF == nil && archF == nil && ramF == nil && osBehindF == nil
                       && axmMigStatusF == nil && migDeadlineF == nil

        let result: [Device]
        if srcFilter == nil && covFilter == nil && wbF == nil && typeFilter == nil && mdmFilter == nil && searchText.isEmpty && noDrillDown {
            result = snapshot
        } else {
            result = snapshot.filter { d in
                Self.matchesDeviceFilters(d, source: srcFilter, coverage: covFilter, kind: typeFilter,
                    mdm: mdmFilter, wb: wbF, searchText: searchText, noDrillDown: noDrillDown,
                    axmStatus: axmStatusF, productFamily: familyF, purchaseSource: purchaseF,
                    addedToOrgYear: yearF, jamfManaged: managedF, osVersion: osVerF,
                    fileVault: fvF, checkin: checkinF, expiringWindow: expiringF,
                    mdmMigrationCapable: mdmCapF, certExpiringWindow: certExpF,
                    architecture: archF, ram: ramF,
                    osBehind: osBehindF, osBehindLatestVersion: osBehindLatestF,
                    axmMigrationStatus: axmMigStatusF, migrationDeadlineWindow: migDeadlineF)
            }
        }
        filteredDevices  = result
        filterGeneration += 1
    }

    // MARK: - CoreData upsert (background context, chunked batch — O(n) at 60k scale)
    /// S7: returns whether every chunk actually persisted. A `false` return also
    /// latches `persistenceFailure` so a caller that ignores the result still can't
    /// report a clean run. All chunks are still attempted on partial failure —
    /// devices that DID save are kept (preserve partial progress).
    @discardableResult
    func upsertDevices(_ incoming: [Device]) async -> Bool {
        guard !incoming.isEmpty else { return true }
        let ctx = persistence.newBackgroundContext()
        let chunkSize = 1_000
        let chunks = stride(from: 0, to: incoming.count, by: chunkSize).map {
            Array(incoming[$0 ..< min($0 + chunkSize, incoming.count)])
        }
        var failedChunks = 0
        for chunk in chunks {
            let ok: Bool = await ctx.perform {
                CDDevice.batchUpsert(devices: chunk, in: ctx)
                return self.persistence.save(ctx)
            }
            if !ok { failedChunks += 1 }
        }
        if failedChunks > 0 { persistenceFailure = true }
        // Force viewContext to merge the saved changes immediately.
        // automaticallyMergesChangesFromParent fires asynchronously via notification;
        // refreshAllObjects() makes it synchronous so loadDevicesFromCoreDataSync()
        // (called right after upsertDevices by SyncEngine) reads fresh data.
        persistence.viewContext.refreshAllObjects()
        if failedChunks > 0 {
            log.error("CoreData: \(failedChunks) of \(chunks.count) chunk(s) FAILED to save (\(incoming.count) device(s) attempted).")
        } else {
            log.debug("CoreData: upserted \(incoming.count) device(s) in \(chunks.count) chunk(s).")
        }
        loadDevicesFromCoreData()  // throttled — only fires when suppressAutoReload=false
        return failedChunks == 0
    }

    /// S3: like `upsertDevices` but propagates a Core Data save failure instead of
    /// logging and swallowing it. The resume-cursor checkpoint is advanced by the
    /// caller only after this returns without throwing, so a failed batch commit can
    /// never leave the cursor ahead of the devices actually on disk.
    func upsertDevicesDurably(_ incoming: [Device]) async throws {
        guard !incoming.isEmpty else { return }
        let ctx = persistence.newBackgroundContext()
        let chunkSize = 1_000
        let chunks = stride(from: 0, to: incoming.count, by: chunkSize).map {
            Array(incoming[$0 ..< min($0 + chunkSize, incoming.count)])
        }
        for chunk in chunks {
            try await ctx.perform {
                CDDevice.batchUpsert(devices: chunk, in: ctx)
                try self.persistence.saveOrThrow(ctx)
            }
        }
        persistence.viewContext.refreshAllObjects()
        log.debug("CoreData: durably upserted \(incoming.count) device(s) in \(chunks.count) chunk(s).")
        loadDevicesFromCoreData()
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

    /// Same as fetchAllDevicesForMerge(), scoped to a specific set of serials.
    /// Used for the S3 per-batch commit during ABM pagination: that merge only
    /// ever touches the batch's own serials, so hydrating and re-merging every
    /// other already-existing device on every batch (a full-table fetch every
    /// ~10 pages) was pure waste — this fetches only the rows the batch's merge
    /// actually needs to carry Jamf fields forward for.
    func fetchDevicesForMerge(serials: Set<String>) async -> [Device] {
        guard !serials.isEmpty else { return [] }
        let ctx = persistence.newBackgroundContext()
        return await ctx.perform {
            let req = CDDevice.fetchRequest()
            req.predicate = NSPredicate(format: "serialNumber IN %@", serials)
            req.returnsObjectsAsFaults = false
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
        clearDeviceFilters()
        // Reset auth so Sync tab becomes disabled (user must re-test auth to re-enable)
        axmAuthStatus      = .idle
        jamfAuthStatus     = .idle
        log.info("Cache reset: CoreData wiped, timestamps cleared.")
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
        let axmStatusF = axmStatusFilter
        let familyF    = productFamilyFilter
        let purchaseF  = purchaseSourceFilter
        let yearF      = addedToOrgYearFilter
        let managedF   = jamfManagedFilter
        let osVerF     = osVersionFilter
        let fvF        = fileVaultFilter
        let checkinF   = checkinFreshnessFilter
        let expiringF  = expiringWindowFilter
        let mdmCapF    = mdmMigrationCapableFilter
        let certExpF   = certExpiringWindowFilter
        let archF      = architectureFilter
        let ramF       = ramFilter
        let osBehindF  = osBehindFilter
        let osBehindLatestF = osBehindLatestVersionFilter
        let axmMigStatusF = axmMigrationStatusFilter
        let migDeadlineF  = migrationDeadlineWindowFilter
        let noDrillDown = axmStatusF == nil && familyF == nil && purchaseF == nil && yearF == nil
                       && managedF == nil && osVerF == nil && fvF == nil && checkinF == nil && expiringF == nil
                       && mdmCapF == nil && certExpF == nil && archF == nil && ramF == nil && osBehindF == nil
                       && axmMigStatusF == nil && migDeadlineF == nil

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: [Device]
            if srcFilter == nil && covFilter == nil && wbF == nil && typeFilter == nil && mdmFilter == nil && searchText.isEmpty && noDrillDown {
                result = snapshot
            } else {
                result = snapshot.filter { d in
                    AppStore.matchesDeviceFilters(d, source: srcFilter, coverage: covFilter, kind: typeFilter,
                        mdm: mdmFilter, wb: wbF, searchText: searchText, noDrillDown: noDrillDown,
                        axmStatus: axmStatusF, productFamily: familyF, purchaseSource: purchaseF,
                        addedToOrgYear: yearF, jamfManaged: managedF, osVersion: osVerF,
                        fileVault: fvF, checkin: checkinF, expiringWindow: expiringF,
                        mdmMigrationCapable: mdmCapF, certExpiringWindow: certExpF,
                        architecture: archF, ram: ramF,
                        osBehind: osBehindF, osBehindLatestVersion: osBehindLatestF,
                        axmMigrationStatus: axmMigStatusF, migrationDeadlineWindow: migDeadlineF)
                }
            }
            // DeviceListPanel keys its List on filterGeneration, forcing a full remount
            // instead of an old-vs-new row diff — the diff itself (not its animation)
            // is what beachballs when the array swings from a small filtered set back
            // to a large unfiltered one (e.g. clearing a filter on a 20k+ environment).
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.filteredDevices  = result
                self.filterGeneration += 1
            }
        }
    }

    // MARK: - Stats (single O(n) pass — no redundant .filter calls)
    // MARK: - ISO date parsing for Dashboard check-in freshness
    // Static formatters — allocated once, not per-device, per-recompute pass.
    // nonisolated(unsafe): ISO8601DateFormatter isn't Sendable-audited by Apple yet,
    // but these are create-once-at-launch and only ever read (date parsing) from
    // multiple contexts afterward — never mutated post-init — so the manual opt-out
    // is safe. Needed so checkinBucketLabel/parseISO stay callable from the
    // nonisolated static classification helpers used inside applyFilterNow()'s
    // detached Task (see the standing AppStore invariant on that).
    private nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private nonisolated static func parseISO(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
    // axmCoverageEndDate is a plain "yyyy-MM-dd" string (not ISO8601 with a time
    // component), so it needs its own formatter — POSIX locale/UTC so parsing
    // never depends on the user's system calendar or region settings.
    private nonisolated static let ymdParser: DateFormatter = {
        let f = DateFormatter()
        f.locale   = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Shared per-device classification helpers
    // Used by BOTH recomputeStats() (to compute the numbers shown) and the filter
    // predicates in applyFilterNow/applyFilterNowSync (to drive Dashboard drill-down
    // taps) — factored out so a drill-down can never show a different set of devices
    // than the number that was tapped implies.
    nonisolated static func purchaseSourceLabel(for d: Device) -> String {
        switch d.axmPurchaseSource?.uppercased() {
        case "APPLE":          return "Apple"
        case "RESELLER":       return "Reseller"
        case "MANUALLY_ADDED": return "Manually Added"
        default:               return "Unknown"
        }
    }
    nonisolated static func productFamilyLabel(for d: Device) -> String {
        d.axmProductFamily?.isEmpty == false ? d.axmProductFamily! : "Unknown"
    }
    nonisolated static func addedToOrgYearLabel(for d: Device) -> String {
        if let date = d.axmAddedToOrgDate, date.count >= 4 { return String(date.prefix(4)) }
        return "Unknown"
    }
    nonisolated static func osMajorVersionLabel(for d: Device) -> String {
        if let os = d.jamfOsVersion, let major = os.split(separator: ".").first, !major.isEmpty { return String(major) }
        return "Unknown"
    }
    nonisolated static func fileVaultLabel(for d: Device) -> String {
        switch d.jamfFileVaultStatus {
        case "ALL_ENCRYPTED", "BOOT_ENCRYPTED": return "Encrypted"
        case "NOT_ENCRYPTED":                   return "Not Encrypted"
        default:                                return "Unknown"
        }
    }
    nonisolated static func checkinBucketLabel(for d: Device) -> String {
        guard let contact = d.jamfLastContact, let date = parseISO(contact) else { return "Never" }
        let days = -date.timeIntervalSinceNow / 86_400
        if days < 1       { return "Today" }
        if days < 7       { return "This Week" }
        if days > 30      { return "Stale (30+ days)" }
        return "This Month"
    }
    /// Non-overlapping "days until coverage ends" bucket for devices currently in
    /// warranty. Returns nil for anything that isn't a live, upcoming expiry —
    /// already out-of-warranty devices belong under "Out of Warranty", not here,
    /// and anything beyond 90 days isn't "soon" yet.
    nonisolated static func expiringWindowLabel(for d: Device) -> String? {
        guard d.coverageStatus == .active,
              let endStr = d.axmCoverageEndDate,
              let end = ymdParser.date(from: endStr) else { return nil }
        let daysOut = end.timeIntervalSinceNow / 86_400
        guard daysOut >= 0 else { return nil }  // end date already passed but status hasn't caught up
        if daysOut <= 30 { return "0–30" }
        if daysOut <= 60 { return "31–60" }
        if daysOut <= 90 { return "61–90" }
        return nil
    }
    nonisolated static func mdmMigrationCapableLabel(for d: Device) -> String {
        switch d.axmMdmMigrationCapable {
        case "True":  return "Capable"
        case "False": return "Not Capable"
        default:      return "Unknown"
        }
    }
    nonisolated static func axmMigrationStatusLabel(for d: Device) -> String {
        switch d.axmMdmMigrationStatus {
        case "REQUESTED": return "Requested"
        case "STARTED":   return "In Progress"
        case "SUCCESS":   return "Success"
        case "FAILED":    return "Failed"
        default:          return "Not Requested"
        }
    }
    /// Non-overlapping "days until migration deadline" bucket, mirroring
    /// expiringWindowLabel's shape exactly. Only meaningful for an in-progress
    /// migration (Requested/In Progress) — a completed or failed migration has
    /// no live deadline to be urgent about, even if the raw field is still set.
    nonisolated static func migrationDeadlineWindowLabel(for d: Device) -> String? {
        let status = Self.axmMigrationStatusLabel(for: d)
        guard status == "Requested" || status == "In Progress",
              let end = d.axmMdmMigrationDeadlineDate else { return nil }
        let daysOut = end.timeIntervalSinceNow / 86_400
        guard daysOut >= 0 else { return nil }
        if daysOut <= 30 { return "0–30" }
        if daysOut <= 60 { return "31–60" }
        if daysOut <= 90 { return "61–90" }
        return nil
    }
    /// Non-overlapping "days until MDM cert expires" bucket, mirroring
    /// expiringWindowLabel's shape exactly. jamfMdmCertExpirationDate already
    /// does the resilient raw-string parsing (see its declaration on Device).
    nonisolated static func certExpiringWindowLabel(for d: Device) -> String? {
        guard d.deviceSource != .axmOnly,
              let end = d.jamfMdmCertExpirationDate else { return nil }
        let daysOut = end.timeIntervalSinceNow / 86_400
        guard daysOut >= 0 else { return nil }
        if daysOut <= 30 { return "0–30" }
        if daysOut <= 60 { return "31–60" }
        if daysOut <= 90 { return "61–90" }
        return nil
    }
    nonisolated static func architectureLabel(for d: Device) -> String {
        guard let proc = d.jamfProcessorType, !proc.isEmpty else { return "Unknown" }
        return proc.localizedCaseInsensitiveContains("Apple") ? "Apple Silicon" : "Intel"
    }
    /// Bare number, matching osMajorVersionLabel's convention (no unit suffix) —
    /// BreakdownBarChart's .byVersionDescending sort does Int(key), which a " GB"
    /// suffix would break. The card title supplies the "GB" context instead.
    nonisolated static func ramLabel(for d: Device) -> String {
        guard let ram = d.jamfRamGB, !ram.isEmpty else { return "Unknown" }
        return ram
    }
    /// Fleet-relative "how many major OS versions behind the newest one seen
    /// in this population" — deliberately takes latestVersion as a parameter
    /// rather than looking it up itself: the caller (computeStats, for the
    /// number shown; the drill-down filter, for the devices a tap lands on)
    /// must both classify against the exact same "latest," or a tap could
    /// disagree with the card that was tapped. See computeStats's second pass
    /// for where latestVersion actually gets computed.
    /// Deliberately has no device-kind or deviceSource gate of its own — same
    /// style as osMajorVersionLabel, which doesn't either. computeStats calls
    /// this once per population (computer, then mobile) with that population's
    /// own latestVersion; the drill-down's accompanying `deviceType` filter
    /// narrows the population there. A shared, kind-agnostic helper means macOS
    /// and iOS both get "N behind" for free instead of two near-duplicate ones.
    nonisolated static func osBehindLabel(for d: Device, latestVersion: Int?) -> String {
        guard let latestVersion, let this = Int(osMajorVersionLabel(for: d)) else { return "Unknown" }
        let behind = latestVersion - this
        if behind <= 0 { return "Current" }
        if behind == 1 { return "1 Behind" }
        return "2+ Behind"
    }

    // Single O(n) pass over a device array, producing every dashboard breakdown.
    // Pulled out as a pure nonisolated function so it can run against the full
    // device list (recomputeStats) or a facet-filtered subset (the Jamf dashboard's
    // filter bar) without duplicating this loop.
    nonisolated static func computeStats(from devices: [Device]) -> DashboardStats {
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
                s.mdmMigrationCapableBreakdown[Self.mdmMigrationCapableLabel(for: d), default: 0] += 1
                s.axmMigrationStatusBreakdown[Self.axmMigrationStatusLabel(for: d), default: 0] += 1
                switch Self.migrationDeadlineWindowLabel(for: d) {
                case "0–30":  s.axmMigrationDeadline30 += 1
                case "31–60": s.axmMigrationDeadline60 += 1
                case "61–90": s.axmMigrationDeadline90 += 1
                default: break
                }
            }

            // Dashboard "Apple Manager" focus breakdowns — AxM-sourced fields only.
            // expiringWindowLabel is computed once per device and shared with the
            // Jamf-focus block below (for .both devices) — matches the file's single
            // O(n)-pass principle: no need to parse axmCoverageEndDate twice per device.
            let expiringLabel = Self.expiringWindowLabel(for: d)
            if d.deviceSource != .jamfOnly {
                s.axmProductFamilyBreakdown[Self.productFamilyLabel(for: d), default: 0] += 1
                s.axmPurchaseSourceBreakdown[Self.purchaseSourceLabel(for: d), default: 0] += 1
                s.axmOrderYearBreakdown[Self.addedToOrgYearLabel(for: d), default: 0] += 1

                switch expiringLabel {
                case "0–30":  s.axmExpiring30 += 1
                case "31–60": s.axmExpiring60 += 1
                case "61–90": s.axmExpiring90 += 1
                default: break
                }
            }

            // Dashboard "Jamf Pro" focus breakdowns — Jamf-sourced fields only
            if d.deviceSource != .axmOnly {
                if d.jamfDeviceType == "mobile" { s.jamfMobileCount += 1 } else { s.jamfComputerCount += 1 }

                // Bucketed separately by device type — mixing Mac and mobile OS numbers into
                // one list is meaningless, since e.g. macOS 26 and iOS 26 share a version number
                // under Apple's unified yearly versioning but are entirely different OSes.
                let osLabel = Self.osMajorVersionLabel(for: d)
                if d.jamfDeviceType == "mobile" {
                    s.jamfMobileOsVersionBreakdown[osLabel, default: 0] += 1
                } else {
                    s.jamfMacOsVersionBreakdown[osLabel, default: 0] += 1
                }

                // FileVault only applies to computers — mobile devices have no encryption state to report.
                if d.jamfDeviceType == "computer" {
                    switch Self.fileVaultLabel(for: d) {
                    case "Encrypted":     s.jamfFileVaultEncrypted    += 1
                    case "Not Encrypted": s.jamfFileVaultNotEncrypted += 1
                    default:              s.jamfFileVaultUnknown      += 1
                    }
                    // Hardware mix — architecture and RAM only apply to computers,
                    // same scoping as FileVault above.
                    s.jamfArchitectureBreakdown[Self.architectureLabel(for: d), default: 0] += 1
                    s.jamfRamBreakdown[Self.ramLabel(for: d), default: 0] += 1
                }

                switch Self.certExpiringWindowLabel(for: d) {
                case "0–30":  s.jamfCertExpiring30 += 1
                case "31–60": s.jamfCertExpiring60 += 1
                case "61–90": s.jamfCertExpiring90 += 1
                default: break
                }

                switch Self.checkinBucketLabel(for: d) {
                case "Today":            s.jamfCheckinToday     += 1
                case "This Week":        s.jamfCheckinThisWeek  += 1
                case "This Month":       s.jamfCheckinThisMonth += 1
                case "Stale (30+ days)": s.jamfCheckinStale     += 1
                default:                 s.jamfCheckinNever     += 1
                }

                // AxM coverage expiry and distribution, but only for devices Jamf also
                // has a record of — the Jamf dashboard's cards should never count an
                // AxM-only device.
                if d.deviceSource == .both {
                    switch expiringLabel {
                    case "0–30":  s.axmExpiring30InJamf += 1
                    case "31–60": s.axmExpiring60InJamf += 1
                    case "61–90": s.axmExpiring90InJamf += 1
                    default: break
                    }

                    switch d.coverageStatus {
                    case .active:                          s.jamfCoverageActive       += 1
                    case .inactive, .expired, .cancelled:   s.jamfCoverageInactive     += 1
                    case .noCoverage:                       s.jamfCoverageNoPlan       += 1
                    case .notFetched:                       s.jamfCoverageNeverFetched += 1
                    }
                }
            }
        }

        // OS version "N behind" — a second, small pass, since the fleet's latest
        // major version among each population isn't known until every device has
        // been seen once via the loop above. No hardcoded target version: whatever
        // the newest version actually present is becomes "Current," so this never
        // goes stale as new macOS/iOS versions ship. Computers and mobile devices
        // are entirely separate populations with their own "latest" (a shared
        // number would be meaningless — see the unified-versioning comment above).
        let latestMacOsVersion = s.jamfMacOsVersionBreakdown.keys.compactMap { Int($0) }.max()
        let latestMobileOsVersion = s.jamfMobileOsVersionBreakdown.keys.compactMap { Int($0) }.max()
        for d in devices {
            if d.jamfDeviceType == "computer" {
                switch Self.osBehindLabel(for: d, latestVersion: latestMacOsVersion) {
                case "Current":   s.jamfOsCurrentCount += 1
                case "1 Behind":  s.jamfOsOneBehindCount += 1
                case "2+ Behind": s.jamfOsTwoPlusBehindCount += 1
                default: break   // "Unknown" — unparseable version
                }
            } else if d.jamfDeviceType == "mobile" {
                switch Self.osBehindLabel(for: d, latestVersion: latestMobileOsVersion) {
                case "Current":   s.jamfMobileOsCurrentCount += 1
                case "1 Behind":  s.jamfMobileOsOneBehindCount += 1
                case "2+ Behind": s.jamfMobileOsTwoPlusBehindCount += 1
                default: break
                }
            }
        }

        return s
    }

    func recomputeStats() {
        var s = Self.computeStats(from: devices)

        s.lastAxmSync      = prefs.display(prefs.lastAxmSync)
        s.lastJamfSync     = prefs.display(prefs.lastJamfSync)
        s.lastCoverageSync = prefs.display(prefs.lastCoverageSync)

        stats = s
        // Also refresh filtered list after stats recalc (devices may have changed)
        applyFilterNow()
        scheduleDashboardFacetRecompute()
    }

    /// Fix: recomputeStats() is called from ~10 sites in SyncEngine's per-batch
    /// flush loops — on a 21,000+ device sync that's hundreds of calls, each of
    /// which used to unconditionally fan out into 3 more full O(n) filter+stats
    /// passes (one per dashboard mode) regardless of whether anyone is looking at
    /// a dashboard. Coalesce: a burst of calls within the same ~250ms window
    /// schedules at most one deferred recompute, always reading the latest
    /// `devices`/facet state when it actually runs, so dashboards mid-sync never
    /// fall behind by more than ~250ms and the final state after a sync always
    /// converges correctly. Facet-chip taps bypass this entirely — they call
    /// recompute*DashboardStats() directly for instant feedback.
    private var dashboardFacetRecomputeTask: Task<Void, Never>? = nil

    private func scheduleDashboardFacetRecompute() {
        guard dashboardFacetRecomputeTask == nil else { return }
        dashboardFacetRecomputeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.dashboardFacetRecomputeTask = nil
            self.recomputeJamfDashboardStats()
            self.recomputeAxmDashboardStats()
            self.recomputeCommonDashboardStats()
        }
    }

    /// A write-deferred binding to a facet property. SwiftUI's segmented `Picker`
    /// can push its selection back into the binding from inside `updateNSView`
    /// (a view-update pass) — a direct `@Published` write there trips the
    /// "Publishing changes from within view updates" runtime warning. Hopping the
    /// write to the next main-runloop turn keeps the mutation out of that pass.
    /// The `Menu`-based `FacetChipMenu` writes from a `Button` action (already an
    /// event, not an update) and doesn't need this.
    func facetBinding<T>(_ keyPath: ReferenceWritableKeyPath<AppStore, T>) -> Binding<T> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { newValue in
                DispatchQueue.main.async { self[keyPath: keyPath] = newValue }
            }
        )
    }

    // MARK: - Jamf dashboard facet filter bar
    // Independent of the Devices tab's own filters (jamfManagedFilter etc. above) —
    // this is a dashboard-only lens so flipping a facet here never changes what the
    // Devices tab shows, and vice versa. Every card on the Jamf dashboard reads from
    // jamfDashboardStats instead of the unfiltered `stats`.
    @Published var jamfDashboardManagedFacet:    Bool?       = nil { didSet { recomputeJamfDashboardStats() } }
    @Published var jamfDashboardDeviceTypeFacet: DeviceKind? = nil { didSet { recomputeJamfDashboardStats() } }
    @Published var jamfDashboardFileVaultFacet:  String?     = nil { didSet { recomputeJamfDashboardStats() } }
    @Published var jamfDashboardCheckinFacet:    String?     = nil { didSet { recomputeJamfDashboardStats() } }
    @Published private(set) var jamfDashboardStats = DashboardStats()
    private var jamfDashboardStatsGeneration = 0

    var jamfDashboardFacetCount: Int {
        [jamfDashboardManagedFacet != nil, jamfDashboardDeviceTypeFacet != nil,
         jamfDashboardFileVaultFacet != nil, jamfDashboardCheckinFacet != nil].filter { $0 }.count
    }

    func clearJamfDashboardFacets() {
        jamfDashboardManagedFacet    = nil
        jamfDashboardDeviceTypeFacet = nil
        jamfDashboardFileVaultFacet  = nil
        jamfDashboardCheckinFacet    = nil
    }

    private nonisolated static func matchesJamfDashboardFacets(_ d: Device,
        managed: Bool?, deviceType: DeviceKind?, fileVault: String?, checkin: String?
    ) -> Bool {
        guard d.deviceSource != .axmOnly else { return false }   // Jamf dashboard population
        if let m = managed,     d.isManaged   != m  { return false }
        if let dt = deviceType, d.deviceKind   != dt { return false }
        if let fv = fileVault,  Self.fileVaultLabel(for: d)   != fv { return false }
        if let ck = checkin,    Self.checkinBucketLabel(for: d) != ck { return false }
        return true
    }

    // Filters + recomputes off the main thread (mirrors applyFilterNow()'s detached
    // Task) — a 30k-device pass is cheap, but there's no reason to block the UI for it.
    // Generation counter discards a stale result if facets are toggled again before
    // an in-flight recompute finishes.
    func recomputeJamfDashboardStats() {
        jamfDashboardStatsGeneration += 1
        let myGeneration = jamfDashboardStatsGeneration
        let snapshot   = devices
        let managed    = jamfDashboardManagedFacet
        let deviceType = jamfDashboardDeviceTypeFacet
        let fileVault  = jamfDashboardFileVaultFacet
        let checkin    = jamfDashboardCheckinFacet
        Task.detached(priority: .userInitiated) {
            let filtered = snapshot.filter {
                AppStore.matchesJamfDashboardFacets($0, managed: managed, deviceType: deviceType,
                                                     fileVault: fileVault, checkin: checkin)
            }
            let result = AppStore.computeStats(from: filtered)
            await MainActor.run { [weak self] in
                guard let self, myGeneration == self.jamfDashboardStatsGeneration else { return }
                self.jamfDashboardStats = result
            }
        }
    }

    // MARK: - Apple (AxM) dashboard facet filter bar
    // Same dashboard-only-lens model as the Jamf bar above: flipping a facet here
    // never touches the Devices tab's own filters. Every card on the Apple focus
    // dashboard reads axmDashboardStats instead of the unfiltered `stats`.
    // Population is AxM-having devices (deviceSource != .jamfOnly), mirroring the
    // deviceSource scoping the AxM breakdowns use in computeStats.
    @Published var axmDashboardStatusFacet:         String? = nil { didSet { recomputeAxmDashboardStats() } }  // "ACTIVE" / "RELEASED"
    @Published var axmDashboardProductFamilyFacet:  String? = nil { didSet { recomputeAxmDashboardStats() } }  // productFamilyLabel
    @Published var axmDashboardPurchaseSourceFacet: String? = nil { didSet { recomputeAxmDashboardStats() } }  // "Apple" / "Reseller" / "Manually Added" / "Unknown"
    @Published var axmDashboardMdmFacet:            String? = nil { didSet { recomputeAxmDashboardStats() } }  // mdmAssignedSentinel / mdmUnassignedSentinel
    @Published private(set) var axmDashboardStats = DashboardStats()
    private var axmDashboardStatsGeneration = 0

    var axmDashboardFacetCount: Int {
        [axmDashboardStatusFacet != nil, axmDashboardProductFamilyFacet != nil,
         axmDashboardPurchaseSourceFacet != nil, axmDashboardMdmFacet != nil].filter { $0 }.count
    }

    func clearAxmDashboardFacets() {
        axmDashboardStatusFacet         = nil
        axmDashboardProductFamilyFacet  = nil
        axmDashboardPurchaseSourceFacet = nil
        axmDashboardMdmFacet            = nil
    }

    private nonisolated static func matchesAxmDashboardFacets(_ d: Device,
        status: String?, productFamily: String?, purchaseSource: String?, mdm: String?
    ) -> Bool {
        guard d.deviceSource != .jamfOnly else { return false }   // Apple dashboard population
        if let st = status,         (d.axmDeviceStatus?.uppercased() ?? "") != st          { return false }
        if let pf = productFamily,  Self.productFamilyLabel(for: d)         != pf           { return false }
        if let ps = purchaseSource, Self.purchaseSourceLabel(for: d)        != ps           { return false }
        guard Self.matchesMdmFacet(d, mdm: mdm) else { return false }
        return true
    }

    func recomputeAxmDashboardStats() {
        axmDashboardStatsGeneration += 1
        let myGeneration = axmDashboardStatsGeneration
        let snapshot = devices
        let status   = axmDashboardStatusFacet
        let family   = axmDashboardProductFamilyFacet
        let purchase = axmDashboardPurchaseSourceFacet
        let mdm      = axmDashboardMdmFacet
        Task.detached(priority: .userInitiated) {
            let filtered = snapshot.filter {
                AppStore.matchesAxmDashboardFacets($0, status: status, productFamily: family,
                                                    purchaseSource: purchase, mdm: mdm)
            }
            let result = AppStore.computeStats(from: filtered)
            await MainActor.run { [weak self] in
                guard let self, myGeneration == self.axmDashboardStatsGeneration else { return }
                self.axmDashboardStats = result
            }
        }
    }

    // MARK: - Default (Common) dashboard facet filter bar
    // Same dashboard-only-lens model. Population is the whole reconciled fleet —
    // no deviceSource pre-filter — so a Source facet is itself one of the lenses.
    @Published var commonDashboardSourceFacet:   DeviceSource?   = nil { didSet { recomputeCommonDashboardStats() } }
    @Published var commonDashboardCoverageFacet: CoverageStatus? = nil { didSet { recomputeCommonDashboardStats() } }
    @Published var commonDashboardWbFacet:       WBStatus?       = nil { didSet { recomputeCommonDashboardStats() } }
    @Published var commonDashboardManagedFacet:  Bool?           = nil { didSet { recomputeCommonDashboardStats() } }
    @Published private(set) var commonDashboardStats = DashboardStats()
    private var commonDashboardStatsGeneration = 0

    var commonDashboardFacetCount: Int {
        [commonDashboardSourceFacet != nil, commonDashboardCoverageFacet != nil,
         commonDashboardWbFacet != nil, commonDashboardManagedFacet != nil].filter { $0 }.count
    }

    func clearCommonDashboardFacets() {
        commonDashboardSourceFacet   = nil
        commonDashboardCoverageFacet = nil
        commonDashboardWbFacet       = nil
        commonDashboardManagedFacet  = nil
    }

    private nonisolated static func matchesCommonDashboardFacets(_ d: Device,
        source: DeviceSource?, coverage: CoverageStatus?, wb: WBStatus?, managed: Bool?
    ) -> Bool {
        if let src = source, d.deviceSource != src { return false }
        // Grouped by label so the "Out of Warranty" facet catches inactive/expired/
        // cancelled together — matching how the dashboard's own cards count them.
        if let cov = coverage, d.coverageStatus.label != cov.label { return false }
        if let w = wb {
            guard d.deviceSource != .axmOnly, d.wbStatus == w else { return false }
        }
        if let m = managed {
            guard d.deviceSource != .axmOnly, d.isManaged == m else { return false }
        }
        return true
    }

    func recomputeCommonDashboardStats() {
        commonDashboardStatsGeneration += 1
        let myGeneration = commonDashboardStatsGeneration
        let snapshot = devices
        let source   = commonDashboardSourceFacet
        let coverage = commonDashboardCoverageFacet
        let wb       = commonDashboardWbFacet
        let managed  = commonDashboardManagedFacet
        Task.detached(priority: .userInitiated) {
            let filtered = snapshot.filter {
                AppStore.matchesCommonDashboardFacets($0, source: source, coverage: coverage,
                                                       wb: wb, managed: managed)
            }
            let result = AppStore.computeStats(from: filtered)
            await MainActor.run { [weak self] in
                guard let self, myGeneration == self.commonDashboardStatsGeneration else { return }
                self.commonDashboardStats = result
            }
        }
    }

    // MARK: - Credentials
    func saveAxMCredentials() {
        if let envId = environmentId {
            KeychainService.saveAxMCredentialsForEnv(axmCredentials, id: envId)
        } else {
            KeychainService.saveAxMCredentials(axmCredentials)
        }
    }
    /// Keychain write only — no origin comparison, no revalidation trigger. Safe
    /// to call on every debounced keystroke while the user is still mid-edit;
    /// see saveJamfCredentials() for why that isn't true of the full path.
    func persistJamfCredentialsToKeychain() {
        if let envId = environmentId {
            KeychainService.saveJamfCredentialsForEnv(jamfCredentials, id: envId)
        } else {
            KeychainService.saveJamfCredentials(jamfCredentials)
        }
    }

    func saveJamfCredentials() {
        // S2: capture the mapping-trust baseline BEFORE persisting the new values.
        let newOrigin  = jamfCredentials.canonicalOrigin
        let prevOrigin = prefs.jamfValidatedOrigin

        persistJamfCredentialsToKeychain()

        // A blank previous origin means there was nothing to invalidate yet (brand-new
        // environment). Just record the baseline. Also covers the first save on the
        // legacy v1 store, where onJamfRebindingDetected is nil anyway.
        guard !prevOrigin.isEmpty else {
            prefs.jamfValidatedOrigin = newOrigin
            return
        }
        guard prevOrigin != newOrigin else { return }

        // The Jamf host and/or client changed. Every cached serial→Jamf-ID mapping was
        // built against the old host and must not be used for write-back until it is
        // re-confirmed against the new one (S2 — see ARCHITECTURE.md).
        prefs.jamfValidatedOrigin = newOrigin
        log.warn("Jamf connection changed — write-back paused for all devices until the serial→Jamf-ID mapping is re-confirmed against the new host. The next Run Sync will do a full Jamf re-fetch — Test Auth alone only verifies credentials, it doesn't re-fetch devices.")
        Task {
            await persistence.markJamfMappingsPendingRevalidation()
            await loadDevicesFromCoreDataSync()
        }
        onJamfRebindingDetected?()
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
        guard let envId = environmentId else {
            axmAuthStatus = .failure("No active environment — reopen the app and try again.")
            return
        }
        axmAuthStatus = .testing
        let svc = ABMService(credentials: axmCredentials, environmentId: envId, log: log)
        do {
            try await svc.verifyCredentials()
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
        .init(id: "axmWifiMacAddress",     label: "Wi-Fi MAC Address",       enabled: false),
        .init(id: "axmBluetoothMacAddress", label: "Bluetooth MAC Address",  enabled: false),
        .init(id: "axmEthernetMacAddress", label: "Ethernet MAC Address",    enabled: false),
        .init(id: "axmImei",               label: "IMEI",                    enabled: false),
        .init(id: "axmMeid",               label: "MEID",                    enabled: false),
        .init(id: "axmEid",                label: "EID",                     enabled: false),
        .init(id: "axmMdmMigrationCapable", label: "MDM Migration Capable",  enabled: false),
        .init(id: "axmMdmMigrationStatus", label: "MDM Migration Status",    enabled: false),
        .init(id: "axmMdmMigrationDeadline", label: "MDM Migration Deadline", enabled: false),
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
        case "axmWifiMacAddress":     return axmWifiMacAddress
        case "axmBluetoothMacAddress": return axmBluetoothMacAddress
        case "axmEthernetMacAddress": return axmEthernetMacAddress
        case "axmImei":               return axmImei
        case "axmMeid":               return axmMeid
        case "axmEid":                return axmEid
        case "axmMdmMigrationCapable": return axmMdmMigrationCapable
        case "axmMdmMigrationStatus": return axmMdmMigrationStatus
        case "axmMdmMigrationDeadline": return axmMdmMigrationDeadline
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
