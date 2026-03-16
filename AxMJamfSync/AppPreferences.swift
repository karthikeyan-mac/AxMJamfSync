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
}

// MARK: - AppPreferences
// @MainActor because it's read and written from SwiftUI views.
// Uses plain UserDefaults-backed computed properties instead of @AppStorage to avoid
// the macOS 14 infinite re-render loop caused by @AppStorage inside ObservableObject.
@MainActor
final class AppPreferences: ObservableObject {

    private let ud = UserDefaults.standard

    // MARK: - Helpers
    private func int(_ key: String, default d: Int) -> Int {
        ud.object(forKey: key) != nil ? ud.integer(forKey: key) : d
    }
    private func bool(_ key: String, default d: Bool) -> Bool {
        ud.object(forKey: key) != nil ? ud.bool(forKey: key) : d
    }
    private func double(_ key: String) -> Double { ud.double(forKey: key) }
    private func string(_ key: String, default d: String) -> String {
        ud.string(forKey: key) ?? d
    }

    // MARK: - Cache behaviour (user-configurable)
    var devicesCacheDays: Int {
        get { int(PrefKey.devicesCacheDays, default: 1) }
        set { ud.set(newValue, forKey: PrefKey.devicesCacheDays); objectWillChange.send() }
    }
    var coverageCacheDays: Int {
        get { int(PrefKey.coverageCacheDays, default: 7) }
        set { ud.set(newValue, forKey: PrefKey.coverageCacheDays); objectWillChange.send() }
    }
    var coverageLimit: Int {
        get { int(PrefKey.coverageLimit, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.coverageLimit); objectWillChange.send() }
    }
    var alwaysRefreshDevices: Bool {
        get { bool(PrefKey.alwaysRefreshDevices, default: false) }
        set { ud.set(newValue, forKey: PrefKey.alwaysRefreshDevices); objectWillChange.send() }
    }
    var alwaysRefreshCoverage: Bool {
        get { bool(PrefKey.alwaysRefreshCoverage, default: false) }
        set { ud.set(newValue, forKey: PrefKey.alwaysRefreshCoverage); objectWillChange.send() }
    }
    /// Never re-fetch coverage for devices that already have a coverage record.
    var skipExistingCoverage: Bool {
        get { bool(PrefKey.skipExistingCoverage, default: true) }
        set { ud.set(newValue, forKey: PrefKey.skipExistingCoverage); objectWillChange.send() }
    }

    // MARK: - Last-sync timestamps (stored as Unix epoch Double)
    private var lastAxmEpoch: Double {
        get { double(PrefKey.lastAxmSyncEpoch) }
        set { ud.set(newValue, forKey: PrefKey.lastAxmSyncEpoch) }
    }
    private var lastJamfEpoch: Double {
        get { double(PrefKey.lastJamfSyncEpoch) }
        set { ud.set(newValue, forKey: PrefKey.lastJamfSyncEpoch) }
    }
    private var lastCoverageEpoch: Double {
        get { double(PrefKey.lastCoverageSyncEpoch) }
        set { ud.set(newValue, forKey: PrefKey.lastCoverageSyncEpoch) }
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
        set { ud.set(newValue, forKey: PrefKey.exportColumnJSON) }
    }

    // MARK: - Last run summary — persisted across launches
    var lrDateEpoch: Double {
        get { double(PrefKey.lrDateEpoch) }
        set { ud.set(newValue, forKey: PrefKey.lrDateEpoch); objectWillChange.send() }
    }
    var lrElapsedSecs: Int {
        get { int(PrefKey.lrElapsedSecs, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrElapsedSecs); objectWillChange.send() }
    }
    var lrAxmCount: Int {
        get { int(PrefKey.lrAxmCount, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrAxmCount); objectWillChange.send() }
    }
    var lrJamfCount: Int {
        get { int(PrefKey.lrJamfCount, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrJamfCount); objectWillChange.send() }
    }
    var lrFromCache: Int {
        get { int(PrefKey.lrFromCache, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrFromCache); objectWillChange.send() }
    }
    var lrCovActive: Int {
        get { int(PrefKey.lrCovActive, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrCovActive); objectWillChange.send() }
    }
    var lrCovInactive: Int {
        get { int(PrefKey.lrCovInactive, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrCovInactive); objectWillChange.send() }
    }
    var lrCovNone: Int {
        get { int(PrefKey.lrCovNone, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrCovNone); objectWillChange.send() }
    }
    var lrCovFetched: Int {
        get { int(PrefKey.lrCovFetched, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrCovFetched); objectWillChange.send() }
    }
    var lrWBSynced: Int {
        get { int(PrefKey.lrWBSynced, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrWBSynced); objectWillChange.send() }
    }
    var lrWBFailed: Int {
        get { int(PrefKey.lrWBFailed, default: 0) }
        set { ud.set(newValue, forKey: PrefKey.lrWBFailed); objectWillChange.send() }
    }

    // MARK: - Scope persistence (survives relaunch)
    // Stores "business" or "school". Saved on every sync + credential save.
    var activeScope: String {
        get { string(PrefKey.activeScope, default: AxMScope.business.rawValue) }
        set { ud.set(newValue, forKey: PrefKey.activeScope); objectWillChange.send() }
    }

    // The scope whose data is actually stored in the CoreData cache.
    // Written ONLY by the sync engine after devices are saved — never by UI scope switching.
    // This is the authoritative source for the scope-lock check in SetupView.
    var dataCachedScope: String {
        get { string(PrefKey.dataCachedScope, default: "") }
        set { ud.set(newValue, forKey: PrefKey.dataCachedScope); objectWillChange.send() }
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

    // MARK: - Cache staleness helpers (used by SyncEngine)
    var axmIsFresh: Bool {
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

    // MARK: - Full cache reset
    func resetSyncTimestamps() {
        lastAxmEpoch      = 0
        lastJamfEpoch     = 0
        lastCoverageEpoch = 0
        objectWillChange.send()
        LogService.shared.info("Preferences: sync timestamps cleared — next sync re-fetches all.")
    }
}
