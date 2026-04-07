// AppPreferences.swift
// UserDefaults keys (PrefKey) and AppPreferences ObservableObject.
// All keys are plain strings without bundle-ID prefix (required in sandboxed apps).
// Last run summary keys (lrDateEpoch, lrElapsedSecs, lrAxmCount, …) persist across relaunches.
//
// FIX: @AppStorage inside a @MainActor ObservableObject causes an infinite re-render loop
// on macOS 14 (each @AppStorage internally posts objectWillChange on every view pass).
// All properties are now plain computed vars backed by UserDefaults.standard directly.
// objectWillChange.send() is called manually in each setter so SwiftUI updates correctly.

import SwiftUI
import Combine

// MARK: - Namespaced UserDefaults keys
// Short keys — no bundle ID prefix needed. In a sandboxed app UserDefaults.standard
// is already scoped to the app container automatically.
enum PrefKey {
    static let devicesCacheDays       = "devicesCacheDays"
    static let coverageCacheDays      = "coverageCacheDays"
    static let coverageLimit          = "coverageLimit"
    static let alwaysRefreshDevices   = "alwaysRefreshDevices"
    static let alwaysRefreshCoverage  = "alwaysRefreshCoverage"
    static let skipExistingCoverage   = "skipExistingCoverage"
    static let lastAxmSyncEpoch       = "lastAxmSyncEpoch"
    static let lastJamfSyncEpoch      = "lastJamfSyncEpoch"
    static let lastCoverageSyncEpoch  = "lastCoverageSyncEpoch"
    static let exportColumnJSON       = "exportColumnJSON"
    // Last run summary — persisted so Sync UI shows previous run on next launch
    static let lrDateEpoch            = "lrDateEpoch"
    static let lrElapsedSecs          = "lrElapsedSecs"
    static let lrAxmCount             = "lrAxmCount"
    static let lrJamfCount            = "lrJamfCount"
    static let lrFromCache            = "lrFromCache"
    static let lrCovActive            = "lrCovActive"
    static let lrCovInactive          = "lrCovInactive"
    static let lrCovNone              = "lrCovNone"
    static let lrCovFetched           = "lrCovFetched"
    static let lrWBSynced             = "lrWBSynced"
    static let lrWBFailed             = "lrWBFailed"
    static let activeScope            = "activeScope"
    static let dataCachedScope        = "dataCachedScope"
    static let syncDeviceScope        = "syncDeviceScope"
    // Cursor resume — saves the last successful cursor + fetched count so a
    // failed mid-fetch can resume from exactly where it stopped on next run.
    static let axmResumeCursor        = "axmResumeCursor"
    static let axmResumedDeviceCount  = "axmResumedDeviceCount"
    static let axmResumeScope         = "axmResumeScope"
}

// MARK: - AppPreferences
// @MainActor because it's read and written from SwiftUI views.
// Uses plain UserDefaults-backed computed properties instead of @AppStorage to avoid
// the macOS 14 infinite re-render loop caused by @AppStorage inside ObservableObject.
//
// v2.0: Each environment gets its own namespace prefix (env.{uuid}.).
// The default init uses flat keys (no prefix) for the Default environment (v1 migration).
@MainActor
final class AppPreferences: ObservableObject {

    private let ud     = UserDefaults.standard
    // Namespace prefix — empty string for Default environment (v1 flat keys),
    // "env.{uuid}." for all other environments.
    private let prefix: String

    /// v1-compatible init — uses flat keys, no prefix. Used for Default environment.
    init() { self.prefix = "" }

    /// Per-environment init — all keys namespaced as "env.{uuid}.{key}".
    init(environmentId: UUID) {
        self.prefix = "env.\(environmentId.uuidString)."
    }

    // MARK: - Helpers
    private func k(_ key: String) -> String { prefix + key }
    private func int(_ key: String, default d: Int) -> Int {
        ud.object(forKey: k(key)) != nil ? ud.integer(forKey: k(key)) : d
    }
    private func bool(_ key: String, default d: Bool) -> Bool {
        ud.object(forKey: k(key)) != nil ? ud.bool(forKey: k(key)) : d
    }
    private func double(_ key: String) -> Double { ud.double(forKey: k(key)) }
    private func string(_ key: String, default d: String) -> String {
        ud.string(forKey: k(key)) ?? d
    }

    // MARK: - Cache behaviour (user-configurable)
    var devicesCacheDays: Int {
        get { int(PrefKey.devicesCacheDays, default: 1) }
        set { ud.set(newValue, forKey: k(PrefKey.devicesCacheDays)); objectWillChange.send() }
    }
    var coverageCacheDays: Int {
        get { int(PrefKey.coverageCacheDays, default: 7) }
        set { ud.set(newValue, forKey: k(PrefKey.coverageCacheDays)); objectWillChange.send() }
    }
    var coverageLimit: Int {
        get { int(PrefKey.coverageLimit, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.coverageLimit)); objectWillChange.send() }
    }
    var alwaysRefreshDevices: Bool {
        get { bool(PrefKey.alwaysRefreshDevices, default: false) }
        set { ud.set(newValue, forKey: k(PrefKey.alwaysRefreshDevices)); objectWillChange.send() }
    }
    var alwaysRefreshCoverage: Bool {
        get { bool(PrefKey.alwaysRefreshCoverage, default: false) }
        set { ud.set(newValue, forKey: k(PrefKey.alwaysRefreshCoverage)); objectWillChange.send() }
    }
    /// Never re-fetch coverage for devices that already have a coverage record.
    var skipExistingCoverage: Bool {
        get { bool(PrefKey.skipExistingCoverage, default: true) }
        set { ud.set(newValue, forKey: k(PrefKey.skipExistingCoverage)); objectWillChange.send() }
    }

    // MARK: - Last-sync timestamps (stored as Unix epoch Double)
    private var lastAxmEpoch: Double {
        get { double(PrefKey.lastAxmSyncEpoch) }
        set { ud.set(newValue, forKey: k(PrefKey.lastAxmSyncEpoch)) }
    }
    private var lastJamfEpoch: Double {
        get { double(PrefKey.lastJamfSyncEpoch) }
        set { ud.set(newValue, forKey: k(PrefKey.lastJamfSyncEpoch)) }
    }
    private var lastCoverageEpoch: Double {
        get { double(PrefKey.lastCoverageSyncEpoch) }
        set { ud.set(newValue, forKey: k(PrefKey.lastCoverageSyncEpoch)) }
    }

    var lastAxmSync: Date? {
        get { lastAxmEpoch      > 0 ? Date(timeIntervalSince1970: lastAxmEpoch)      : nil }
        set { lastAxmEpoch      = newValue?.timeIntervalSince1970 ?? 0; objectWillChange.send() }
    }
    var lastJamfSync: Date? {
        get { lastJamfEpoch     > 0 ? Date(timeIntervalSince1970: lastJamfEpoch)     : nil }
        set { lastJamfEpoch     = newValue?.timeIntervalSince1970 ?? 0; objectWillChange.send() }
    }
    var lastCoverageSync: Date? {
        get { lastCoverageEpoch > 0 ? Date(timeIntervalSince1970: lastCoverageEpoch) : nil }
        set { lastCoverageEpoch = newValue?.timeIntervalSince1970 ?? 0; objectWillChange.send() }
    }

    // MARK: - Formatted display strings
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    func display(_ date: Date?) -> String {
        guard let d = date else { return "Never" }
        return Self.df.string(from: d)
    }

    // MARK: - Export column state (JSON-encoded [columnId: enabled])
    private var exportColumnJSON: String {
        get { string(PrefKey.exportColumnJSON, default: "") }
        set { ud.set(newValue, forKey: k(PrefKey.exportColumnJSON)) }
    }

    // MARK: - Last run summary — persisted across launches
    var lrDateEpoch: Double {
        get { double(PrefKey.lrDateEpoch) }
        set { ud.set(newValue, forKey: k(PrefKey.lrDateEpoch)); objectWillChange.send() }
    }
    var lrElapsedSecs: Int {
        get { int(PrefKey.lrElapsedSecs, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrElapsedSecs)); objectWillChange.send() }
    }
    var lrAxmCount: Int {
        get { int(PrefKey.lrAxmCount, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrAxmCount)); objectWillChange.send() }
    }
    var lrJamfCount: Int {
        get { int(PrefKey.lrJamfCount, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrJamfCount)); objectWillChange.send() }
    }
    var lrFromCache: Int {
        get { int(PrefKey.lrFromCache, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrFromCache)); objectWillChange.send() }
    }
    var lrCovActive: Int {
        get { int(PrefKey.lrCovActive, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrCovActive)); objectWillChange.send() }
    }
    var lrCovInactive: Int {
        get { int(PrefKey.lrCovInactive, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrCovInactive)); objectWillChange.send() }
    }
    var lrCovNone: Int {
        get { int(PrefKey.lrCovNone, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrCovNone)); objectWillChange.send() }
    }
    var lrCovFetched: Int {
        get { int(PrefKey.lrCovFetched, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrCovFetched)); objectWillChange.send() }
    }
    var lrWBSynced: Int {
        get { int(PrefKey.lrWBSynced, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrWBSynced)); objectWillChange.send() }
    }
    var lrWBFailed: Int {
        get { int(PrefKey.lrWBFailed, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.lrWBFailed)); objectWillChange.send() }
    }

    // MARK: - Scope persistence (survives relaunch)
    // Stores "business" or "school". Saved on every sync + credential save.
    var activeScope: String {
        get { string(PrefKey.activeScope, default: "") }
        set { ud.set(newValue, forKey: k(PrefKey.activeScope)); objectWillChange.send() }
    }

    // The scope whose data is actually stored in the CoreData cache.
    // Written ONLY by the sync engine after devices are saved — never by UI scope switching.
    // This is the authoritative source for the scope-lock check in SetupView.
    var dataCachedScope: String {
        get { string(PrefKey.dataCachedScope, default: "") }
        set { ud.set(newValue, forKey: k(PrefKey.dataCachedScope)); objectWillChange.send() }
    }

    var lastRunDate: Date? { lrDateEpoch > 0 ? Date(timeIntervalSince1970: lrDateEpoch) : nil }

    func saveExportColumns(_ columns: [ExportColumn]) {
        let dict = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0.enabled) })
        if let json = try? JSONEncoder().encode(dict),
           let str  = String(data: json, encoding: .utf8) {
            exportColumnJSON = str
        }
    }

    func loadExportColumnEnabled() -> [String: Bool] {
        guard !exportColumnJSON.isEmpty,
              let data = exportColumnJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return dict
    }

    // MARK: - Cursor resume state
    // Cleared when fetch completes fully. Scoped — an ABM cursor is never used for ASM.
    var axmResumeCursor: String? {
        get { let v = ud.string(forKey: k(PrefKey.axmResumeCursor)); return v?.isEmpty == false ? v : nil }
        set { ud.set(newValue ?? "", forKey: k(PrefKey.axmResumeCursor)) }
    }
    var axmResumedDeviceCount: Int {
        get { int(PrefKey.axmResumedDeviceCount, default: 0) }
        set { ud.set(newValue, forKey: k(PrefKey.axmResumedDeviceCount)) }
    }
    var axmResumeScope: String {
        get { string(PrefKey.axmResumeScope, default: "") }
        set { ud.set(newValue, forKey: k(PrefKey.axmResumeScope)) }
    }
    func clearAxmResumeCursor() {
        ud.removeObject(forKey: k(PrefKey.axmResumeCursor))
        ud.removeObject(forKey: k(PrefKey.axmResumedDeviceCount))
        ud.removeObject(forKey: k(PrefKey.axmResumeScope))
    }

    // MARK: - Device scope (which device types to sync)
    /// Controls which device types are included in coverage fetch and Jamf sync.
    /// .both = all devices (default), .mac = Mac only, .mobile = iPhone/iPad/AppleTV only.
    var syncDeviceScope: SyncDeviceScope {
        get {
            SyncDeviceScope(rawValue: ud.string(forKey: k(PrefKey.syncDeviceScope)) ?? "") ?? .both
        }
        set { ud.set(newValue.rawValue, forKey: k(PrefKey.syncDeviceScope)); objectWillChange.send() }
    }

    // MARK: - Cache staleness helpers (used by SyncEngine)
    var axmIsFresh: Bool {
        // A pending resume cursor means the previous fetch was incomplete —
        // never treat a partial fetch as fresh; Phase 1 must resume it.
        if axmResumeCursor != nil { return false }
        guard !alwaysRefreshDevices, let last = lastAxmSync else { return false }
        return -last.timeIntervalSinceNow < Double(devicesCacheDays) * 86_400
    }
    var jamfIsFresh: Bool {
        guard !alwaysRefreshDevices, let last = lastJamfSync else { return false }
        return -last.timeIntervalSinceNow < Double(devicesCacheDays) * 86_400
    }
    var devicesAreFresh: Bool { axmIsFresh && jamfIsFresh }
    var coverageIsFresh: Bool {
        guard !alwaysRefreshCoverage, let last = lastCoverageSync else { return false }
        return -last.timeIntervalSinceNow < Double(coverageCacheDays) * 86_400
    }


    // MARK: - v2.0 Environment migration helpers (static)

    /// Copy all v1 flat UserDefaults keys into the env namespace.
    /// Safe to call multiple times — skips keys that are already set in the env namespace.
    static func migrateToEnvironment(id: UUID) {
        let ud     = UserDefaults.standard
        let prefix = "env.\(id.uuidString)."

        // Settings — always migrated (safe regardless of data state)
        let settingsKeys: [String] = [
            PrefKey.devicesCacheDays,
            PrefKey.coverageCacheDays,
            PrefKey.coverageLimit,
            PrefKey.alwaysRefreshDevices,
            PrefKey.alwaysRefreshCoverage,
            PrefKey.skipExistingCoverage,
            PrefKey.exportColumnJSON,
            PrefKey.activeScope,
            PrefKey.dataCachedScope,
            PrefKey.syncDeviceScope,
        ]
        for key in settingsKeys {
            let envKey = prefix + key
            guard ud.object(forKey: envKey) == nil else { continue }
            if let val = ud.object(forKey: key) { ud.set(val, forKey: envKey) }
        }

        // Timestamps and last-run summary — only migrate if the CoreData store
        // exists on disk. If the store was not yet migrated, copying timestamps
        // causes SyncEngine to believe data exists when CoreData is empty,
        // triggering the "Cache timestamps present but CoreData is empty" warning.
        let storeURL = PersistenceController.environmentsDirectory
            .appendingPathComponent("\(id.uuidString).sqlite")
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        let timestampKeys: [String] = [
            PrefKey.lastAxmSyncEpoch,
            PrefKey.lastJamfSyncEpoch,
            PrefKey.lastCoverageSyncEpoch,
            PrefKey.lrDateEpoch,
            PrefKey.lrElapsedSecs,
            PrefKey.lrAxmCount,
            PrefKey.lrJamfCount,
            PrefKey.lrFromCache,
            PrefKey.lrCovActive,
            PrefKey.lrCovInactive,
            PrefKey.lrCovNone,
            PrefKey.lrCovFetched,
            PrefKey.lrWBSynced,
            PrefKey.lrWBFailed,
            PrefKey.axmResumeCursor,
            PrefKey.axmResumedDeviceCount,
            PrefKey.axmResumeScope,
        ]
        for key in timestampKeys {
            let envKey = prefix + key
            guard ud.object(forKey: envKey) == nil else { continue }
            if let val = ud.object(forKey: key) { ud.set(val, forKey: envKey) }
        }
    }

    /// Delete all UserDefaults keys for an environment (called on environment deletion).
    static func wipeEnvironment(id: UUID) {
        let ud     = UserDefaults.standard
        let prefix = "env.\(id.uuidString)."
        let allKeys = ud.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(prefix) {
            ud.removeObject(forKey: key)
        }
    }

    // MARK: - Full cache reset
    func resetSyncTimestamps() {
        lastAxmEpoch      = 0
        lastJamfEpoch     = 0
        lastCoverageEpoch = 0
        clearAxmResumeCursor()
        objectWillChange.send()
        LogService.shared.info("Preferences: sync timestamps cleared — next sync re-fetches all.")
    }
}
