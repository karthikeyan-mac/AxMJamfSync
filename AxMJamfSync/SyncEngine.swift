// SyncEngine.swift
// Orchestrates the 4-phase auto-sync pipeline:
//   Phase 1  Fetch AxM org devices (paginated) — ABMService, ES256 JWT auth
//   Phase 2  Fetch Jamf computers + mobile devices (paginated) — JamfService, OAuth2
//   Phase 3  Merge both sets → classify BOTH / AXM_ONLY / JAMF_ONLY
//            Uses pre-populated CoreData snapshot to preserve cross-run state.
//            Jamf loop guard (axmDeviceId != nil) prevents jamfOnly→both misclassification.
//   Phase 4  Fetch AppleCare coverage (3-concurrent, per-task URLSession, 500ms inter-chunk)
//   Phase 5  Write warranty/coverage back to Jamf (8-concurrent, shared pre-fetched token)
//
// Stop-sync: saves partial data + last run summary before exiting.
// ETA: stepETA (above progress bar, per-step) + totalETA (bottom-right, overall run).

import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class SyncEngine: ObservableObject {

    @Published var phase:       SyncPhase = .idle
    @Published var currentStep: Int       = 0
    @Published var totalSteps:  Int       = 0
    @Published var stepLabel:   String    = ""
    @Published var isRunning:   Bool      = false
    @Published var lastError:   String?   = nil

    // Last-run summary counts (shown in SyncView after completion)
    @Published var lastRunAxm:      String = "—"
    @Published var lastRunJamf:     String = "—"
    @Published var lastRunCoverage: String = "—"
    @Published var lastRunWB:       String = "—"
    // Rich summary card fields
    @Published var lastRunDate:        Date?   = nil
    @Published var lastRunElapsed:     String  = ""
    @Published var lastRunAxmCount:    Int     = 0
    @Published var lastRunJamfCount:   Int     = 0
    @Published var lastRunCovActive:   Int     = 0
    @Published var lastRunCovInactive: Int     = 0
    @Published var lastRunCovNone:     Int     = 0
    @Published var lastRunCovFetched:  Int     = 0
    @Published var lastRunWBSynced:    Int     = 0
    @Published var lastRunWBFailed:    Int     = 0
    @Published var lastRunWBSyncedMac: Int     = 0   // Mac write-back successes
    @Published var lastRunWBFailedMac: Int     = 0   // Mac write-back failures
    @Published var lastRunWBSyncedMob: Int     = 0   // Mobile write-back successes
    @Published var lastRunWBFailedMob: Int     = 0   // Mobile write-back failures
    @Published var lastRunFromCache:   Int     = 0   // devices served from cache
    @Published var lastRunElapsedSecs: Int     = 0

    private let log = LogService.shared
    private var syncTask:  Task<Void, Never>?
    private var activeABM:  ABMService?  = nil
    private var activeJamf: JamfService? = nil
    @Published var tabBadge: String = ""   // shown next to Sync tab while running
    // ETA tracking — used by SyncProgressBlock for time-remaining display
    @Published var stepETA:   String = ""  // per-step ETA: "~2m 30s" shown ABOVE progress bar
    @Published var totalETA:  String = ""  // total run ETA: "~14h 22m total" shown bottom-right
    @Published var stepElapsed: String = ""  // elapsed time for current step e.g. "0:42"

    // Private ETA state
    private var coverageStartTime: Date?
    private var coverageStartIndex: Int = 0
    private var stepStartTime: Date?

    // MARK: - Init — restore last run summary from UserDefaults

    init() {
        let ud = UserDefaults.standard
        let epoch = ud.double(forKey: PrefKey.lrDateEpoch)
        guard epoch > 0 else { return }   // no previous run recorded
        let secs = ud.integer(forKey: PrefKey.lrElapsedSecs)
        lastRunDate        = Date(timeIntervalSince1970: epoch)
        lastRunElapsedSecs = secs
        lastRunElapsed     = secs >= 60 ? "\(secs/60)m \(secs%60)s" : "\(secs)s"
        lastRunAxmCount    = ud.integer(forKey: PrefKey.lrAxmCount)
        lastRunJamfCount   = ud.integer(forKey: PrefKey.lrJamfCount)
        lastRunFromCache   = ud.integer(forKey: PrefKey.lrFromCache)
        lastRunCovActive   = ud.integer(forKey: PrefKey.lrCovActive)
        lastRunCovInactive = ud.integer(forKey: PrefKey.lrCovInactive)
        lastRunCovNone     = ud.integer(forKey: PrefKey.lrCovNone)
        lastRunCovFetched  = ud.integer(forKey: PrefKey.lrCovFetched)
        lastRunWBSynced    = ud.integer(forKey: PrefKey.lrWBSynced)
        lastRunWBFailed    = ud.integer(forKey: PrefKey.lrWBFailed)
        // Reconstruct text summary lines
        lastRunAxm      = lastRunAxmCount  > 0 ? "\(lastRunAxmCount) fetched"  : "cached"
        lastRunJamf     = lastRunJamfCount > 0 ? "\(lastRunJamfCount) fetched" : "cached"
        lastRunCoverage = "\(lastRunCovFetched) fetched"
        lastRunWB       = lastRunWBFailed > 0
            ? "\(lastRunWBSynced) synced, \(lastRunWBFailed) failed"
            : "\(lastRunWBSynced) synced"
    }

    // Format elapsed seconds as "0:42" or "1:05:03"
    static func fmtElapsed(_ secs: TimeInterval) -> String {
        let t = Int(max(0, secs))
        let h = t / 3600; let m = (t % 3600) / 60; let s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var fraction: Double {
        guard totalSteps > 0 else { return 0 }
        return min(max(Double(currentStep) / Double(totalSteps), 0), 1)
    }

    // MARK: - Public API

    func run(store: AppStore) {
        guard !isRunning else { return }
        // Snapshot the one-shot flags BEFORE clearing them so _run can honour them
        let forceDevices  = store.prefs.alwaysRefreshDevices
        let forceCoverage = store.prefs.alwaysRefreshCoverage
        store.prefs.alwaysRefreshDevices  = false
        store.prefs.alwaysRefreshCoverage = false
        // Only request notification authorisation when status is undetermined —
        // re-requesting after grant/deny is a no-op but avoids an unnecessary system call.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
        tabBadge = "●"
        NSApp.dockTile.badgeLabel = "1/4"
        syncTask = Task { await _run(store: store, forceDevices: forceDevices, forceCoverage: forceCoverage) }
    }

    func stop() {
        guard isRunning else { return }   // prevent repeated calls from multiple workers
        syncTask?.cancel()
        syncTask  = nil
        stepLabel = "Stopping…"
        tabBadge  = ""
        NSApp.dockTile.badgeLabel = nil
        // Token cleanup happens in _run's finally block after CancellationError is caught
    }

    func resetCache(store: AppStore) async {
        await store.wipeCache()
        log.info("Cache reset — CoreData wiped, timestamps cleared.")
    }

    // MARK: - Main pipeline

    private func _run(store: AppStore, forceDevices: Bool = false, forceCoverage: Bool = false) async {
        isRunning   = true
        lastError   = nil
        phase       = .idle
        currentStep = 0
        totalSteps  = 1
        store.suppressAutoReload = true   // SyncEngine controls reload timing during sync
        log.clearSession()
        let runStart = Date()

        let prefs    = store.prefs
        let pageSize = max(store.jamfCredentials.pageSize, 10)

        // ── Settings dump — file log only, not shown in UI log window ────
        // Written at the top of every run so troubleshooting always has full context.
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .medium
        let axmCreds  = store.axmCredentials
        let jamfCreds = store.jamfCredentials
        log.debug("────────────────────────────────────────────────────────")
        log.debug("RUN STARTED  \(df.string(from: runStart))")
        log.debug("────────────────────────────────────────────────────────")
        log.debug("APP VERSION  \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        log.debug("── Scope & Credentials ─────────────────────────────────")
        log.debug("Scope          : \(axmCreds.scope == .school ? "ASM (Apple School Manager)" : "ABM (Apple Business Manager)")")
        log.debug("AxM Client ID  : \(axmCreds.clientId.isEmpty ? "(not set)" : "\(axmCreds.clientId.prefix(8))…")")
        log.debug("AxM Key ID     : \(axmCreds.keyId.isEmpty ? "(not set)" : "\(axmCreds.keyId.prefix(8))…")")
        log.debug("AxM Private Key: \(axmCreds.privateKeyContent.isEmpty ? "(not set)" : "set (\(axmCreds.privateKeyContent.count) chars)")")
        log.debug("Jamf URL       : \(jamfCreds.url.isEmpty ? "(not set)" : jamfCreds.url)")
        log.debug("Jamf Client ID : \(jamfCreds.clientId.isEmpty ? "(not set)" : "\(jamfCreds.clientId.prefix(8))…")")
        log.debug("Jamf Secret    : \(jamfCreds.clientSecret.isEmpty ? "(not set)" : "set (\(jamfCreds.clientSecret.count) chars)")")
        log.debug("── Cache Settings ──────────────────────────────────────")
        log.debug("Device Cache Days      : \(prefs.devicesCacheDays) day(s)  [\(prefs.alwaysRefreshDevices ? "ALWAYS REFRESH — cache days ignored" : "respect cache")]")
        log.debug("Coverage Cache Days    : \(prefs.coverageCacheDays) day(s)  [\(prefs.alwaysRefreshCoverage ? "ALWAYS REFRESH — cache days ignored" : "respect cache")]")
        log.debug("Coverage Limit         : \(prefs.coverageLimit == 0 ? "unlimited" : "\(prefs.coverageLimit) per run")")
        log.debug("Do Not Refetch Coverage: \(prefs.skipExistingCoverage ? "ON  (only fetch .notFetched)" : "OFF (re-fetch stale per cache days)")")
        log.debug("Jamf Page Size         : \(pageSize)")
        log.debug("── Last Run Timestamps ─────────────────────────────────")
        log.debug("Last AxM Sync     : \(prefs.lastAxmSync.map { df.string(from: $0) } ?? "never")")
        log.debug("Last Jamf Sync    : \(prefs.lastJamfSync.map { df.string(from: $0) } ?? "never")")
        log.debug("Last Coverage Sync: \(prefs.lastCoverageSync.map { df.string(from: $0) } ?? "never")")
        log.debug("AxM Cache Fresh   : \(prefs.axmIsFresh ? "YES (will skip Step 1)" : "NO  (will fetch)")")
        log.debug("Jamf Cache Fresh  : \(prefs.jamfIsFresh ? "YES (will skip Step 2)" : "NO  (will fetch)")")
        log.debug("Coverage Fresh    : \(prefs.coverageIsFresh ? "YES (no stale devices to re-fetch)" : "NO  (stale devices may be re-fetched)")")
        log.debug("── Device State ────────────────────────────────────────")
        log.debug("CoreData count    : \(store.devices.count) device(s)")
        let notFetched = store.devices.filter { $0.deviceSource != .jamfOnly && $0.axmDeviceId != nil && $0.coverageStatus == .notFetched }.count
        let covActive  = store.devices.filter { $0.coverageStatus == .active }.count
        let covNone    = store.devices.filter { $0.coverageStatus == .noCoverage }.count
        log.debug("Coverage: active=\(covActive)  noCoverage=\(covNone)  notFetched=\(notFetched)")
        log.debug("────────────────────────────────────────────────────────")
        // ── End settings dump ────────────────────────────────────────────

        // Per-run counters for the LastRunSummary card.
        var runAxmCount      = 0
        var runJamfCount     = 0
        var runCoverageCount = 0
        var runWBSynced      = 0
        var runWBFailed      = 0
        var runWBSyncedMac   = 0   // Mac (computer) write-back successes this run
        var runWBFailedMac   = 0   // Mac (computer) write-back failures this run
        var runWBSyncedMob   = 0   // Mobile write-back successes this run
        var runWBFailedMob   = 0   // Mobile write-back failures this run

        // Build real service actors from credentials stored in AppStore (loaded from Keychain).
        // Fresh actors each run — no stale token state carried over.
        let abmService  = ABMService(credentials: store.axmCredentials)
        let jamfService = JamfService(credentials: store.jamfCredentials)
        activeABM  = abmService
        activeJamf = jamfService

        // Declared outside do{} so the CancellationError handler can save whatever
        // was partially fetched before the user pressed Stop.
        var rawABM:    [RawABMDevice]         = []
        var rawJamf:   [RawJamfComputer]      = []
        var rawMobile: [RawJamfMobileDevice]  = []
        // Declared outside do{} so the CancellationError handler can flush whatever
        // partial coverage batch was in-flight when the user pressed Stop.
        var covBatch:  [Device]               = []

        do {
            // ── Step 1: AxM Devices ──────────────────────────────────────

            // Auto-test AxM auth using the already-built abmService actor — avoids creating
            // a second ABMService instance whose token request triggers Apple's rate limit
            // (429) right before the real fetch needs its own token.
            let axmCreds = store.axmCredentials
            let axmConfigured = !axmCreds.clientId.isEmpty
                && !axmCreds.keyId.isEmpty
                && !axmCreds.privateKeyContent.isEmpty
            if axmConfigured {
                let axmStatus = store.axmAuthStatus
                if case .success = axmStatus {
                    // already verified this session — skip to avoid a redundant token request
                } else {
                    log.info("Step 1/4 — Testing AxM authentication automatically…")
                    stepLabel = "Verifying AxM credentials…"
                    // Use the pipeline's own abmService so the token is cached and reused
                    // in Step 1 rather than wasted on a throw-away test instance.
                    do {
                        _ = try await abmService.validToken()
                        store.axmAuthStatus = .success("Token obtained successfully")
                        log.info("Step 1/4 — AxM authentication verified.")
                    } catch {
                        store.axmAuthStatus = .failure(error.localizedDescription)
                        log.error("Step 1/4 — AxM auth failed: \(error.localizedDescription). Skipping AxM fetch.")
                        // Do NOT attempt the fetch — the token is invalid and would produce
                        // the same error again. Fall through to Jamf with rawABM = [].
                    }
                }
            }

            // Guard: treat CoreData-empty as a forced refresh even if timestamps say "fresh".
            // Timestamps in UserDefaults can survive a CoreData wipe (sandbox reset, reinstall,
            // or a failed wipe that cleared the SQLite store but not UserDefaults).
            let coreDataEmpty = store.devices.isEmpty
            if coreDataEmpty && (prefs.lastAxmSync != nil || prefs.lastJamfSync != nil) {
                log.warn("Step 1/4 — Cache timestamps present but CoreData is empty — forcing full device fetch.")
                prefs.resetSyncTimestamps()   // realign timestamps with actual data state
            }

            if !forceDevices && prefs.axmIsFresh && !coreDataEmpty {
                log.info("Step 1/4 — AxM cache fresh (last synced \(prefs.display(prefs.lastAxmSync))), skipping.")
            } else {
                // If Force Refresh Devices is ON, discard any saved resume cursor —
                // a force refresh always starts from page 1 with fresh data.
                if forceDevices {
                    prefs.clearAxmResumeCursor()
                    log.info("Step 1/4 — Force Refresh: cleared saved resume cursor.")
                }
                phase     = .axmDevices; stepStartTime = Date(); stepElapsed = ""
                log.info("Step 1/4 — Fetching AxM org devices")

                if store.axmCredentials.clientId.isEmpty
                    || store.axmCredentials.keyId.isEmpty
                    || store.axmCredentials.privateKeyContent.isEmpty {
                    log.warn("Step 1/4 — AxM credentials not configured, skipping.")
                } else if case .failure = store.axmAuthStatus {
                    log.warn("Step 1/4 — AxM auth previously failed — skipping fetch, proceeding to Jamf.")
                } else {
                    // ── Option B: cursor resume ──────────────────────────────
                    // Check for a saved cursor from a previous interrupted fetch.
                    // Only resume if the cursor was saved for the current scope —
                    // never use an ABM cursor for an ASM fetch or vice versa.
                    let currentScopeRaw = store.axmCredentials.scope.rawValue
                    let savedCursor: String? = {
                        guard prefs.axmResumeScope == currentScopeRaw,
                              let c = prefs.axmResumeCursor, !c.isEmpty else { return nil }
                        return c
                    }()
                    if savedCursor != nil {
                        log.info("Step 1/4 — Resuming ABM fetch from saved cursor (\(prefs.axmResumedDeviceCount) devices already in cache).")
                        stepLabel = "Resuming AxM fetch from page \(prefs.axmResumedDeviceCount / 1000 + 1)…"
                    }

                    // DEBUG: set debugPageLimit > 0 to stop after N devices and test resume.
                    // Set to 0 (or remove entirely) before releasing to production.
                    let debugPageLimit = 0   // e.g. 1000 to test resume after 1 page

                    rawABM = await abmService.fetchOrgDevices(
                        pageSize:       pageSize,
                        resumeCursor:   savedCursor,
                        debugPageLimit: debugPageLimit,
                        batchFlushPages: 10,
                        onProgress: { [weak self] fetched, total in
                            guard let self else { return }
                            self.totalSteps  = max(total, fetched)
                            self.currentStep = fetched
                            self.stepLabel   = "Fetching org devices from Apple… \(fetched)/\(max(total, fetched))"
                            if let s = self.stepStartTime { self.stepElapsed = Self.fmtElapsed(-s.timeIntervalSinceNow) }
                        },
                        onBatchReady: { [weak self] batch, nextCursor in
                            guard let self else { return }
                            // Save cursor + device count to UserDefaults immediately.
                            // This runs on MainActor (onBatchReady is @MainActor).
                            if let cursor = nextCursor {
                                // More pages remaining — save cursor so next run can resume
                                prefs.axmResumeCursor       = cursor
                                prefs.axmResumedDeviceCount += batch.count
                                prefs.axmResumeScope        = currentScopeRaw
                                self.log.info("Cursor saved: \(batch.count) devices flushed, \(prefs.axmResumedDeviceCount) total, cursor=\(cursor.prefix(20))…")
                            } else {
                                // nil cursor = fetch complete — clear the saved resume state
                                prefs.clearAxmResumeCursor()
                                self.log.info("Fetch complete — resume cursor cleared.")
                            }
                        }
                    )
                    // fetchOrgDevices never throws — it returns partial on failure.
                    // rawABM will be empty only if credentials were bad or fetch never started.
                    runAxmCount = rawABM.count
                    if rawABM.isEmpty && savedCursor == nil {
                        log.warn("Step 1/4 — AxM fetch returned 0 devices. Check credentials and network.")
                    } else {
                        let pages = max(1, (rawABM.count + pageSize - 1) / pageSize)
                        log.info("AxM: fetched \(rawABM.count) devices across \(pages) page(s) this run.")
                    }
                }
            }

            // ── Step 2: Jamf Computers + Mobile Devices ──────────────────

            // Item 11: auto-test Jamf auth; warn but continue.
            let jamfAuthPassed: Bool
            let currentJamfStatus = store.jamfAuthStatus
            if case .success = currentJamfStatus {
                jamfAuthPassed = true
            } else if store.jamfCredentials.url.isEmpty
                || store.jamfCredentials.clientId.isEmpty
                || store.jamfCredentials.clientSecret.isEmpty {
                log.warn("Step 2/4 — Jamf credentials not configured. Skipping Jamf fetch.")
                jamfAuthPassed = false
            } else {
                log.info("Step 2/4 — Testing Jamf authentication automatically…")
                stepLabel = "Verifying Jamf credentials…"
                await store.testJamfAuth()
                let tested = store.jamfAuthStatus
                if case .success = tested {
                    log.info("Step 2/4 — Jamf authentication verified.")
                    jamfAuthPassed = true
                } else {
                    log.warn("Step 2/4 — Jamf authentication failed (\(tested.label)). Skipping Jamf fetch.")
                    jamfAuthPassed = false
                }
            }

            if !jamfAuthPassed {
                // warning already logged above — Jamf skipped
            } else if !forceDevices && prefs.jamfIsFresh && !coreDataEmpty {
                log.info("Step 2/4 — Jamf cache fresh (last synced \(prefs.display(prefs.lastJamfSync))), skipping.")
            } else {
                phase     = .jamf; stepStartTime = Date(); stepElapsed = ""
                log.info("Step 2/4 — Fetching Jamf computers")

                if store.jamfCredentials.url.isEmpty
                    || store.jamfCredentials.clientId.isEmpty
                    || store.jamfCredentials.clientSecret.isEmpty {
                    log.warn("Step 2/4 — Jamf credentials not configured, skipping.")
                } else {
                    // ── 2a: Computers (skipped when syncDeviceScope == .mobile) ───────
                    if prefs.syncDeviceScope != .mobile {
                    do {
                        rawJamf = try await jamfService.fetchComputers(
                            pageSize: pageSize,
                            onProgress: { [weak self] fetched, total in
                                guard let self else { return }
                                self.totalSteps  = max(total, fetched)
                                self.currentStep = fetched
                                self.stepLabel   = "Fetching Jamf computers… \(fetched)/\(max(total, fetched))"
                                if let s = self.stepStartTime { self.stepElapsed = Self.fmtElapsed(-s.timeIntervalSinceNow) }
                            }
                        )
                        let pages = max(1, (rawJamf.count + pageSize - 1) / pageSize)
                        log.info("Jamf: fetched \(rawJamf.count) computers across \(pages) page(s).")
                        runJamfCount += rawJamf.count
                    } catch {
                        log.error("Step 2/4 — Jamf computer fetch failed: \(error.localizedDescription). Continuing without computers.")
                        rawJamf = []
                    }
                    } else {
                        log.info("Step 2/4 — Jamf computers skipped (Sync Device Types = Mobile Only).")
                    }

                    // ── 2b: Mobile devices (skipped when syncDeviceScope == .mac) ─────
                    if prefs.syncDeviceScope != .mac {
                    do {
                        rawMobile = try await jamfService.fetchMobileDevices(
                            pageSize: pageSize,
                            onProgress: { [weak self] fetched, total in
                                guard let self else { return }
                                self.totalSteps  = max(total, fetched)
                                self.currentStep = fetched
                                self.stepLabel   = "Fetching Jamf mobile devices… \(fetched)/\(max(total, fetched))"
                                if let s = self.stepStartTime { self.stepElapsed = Self.fmtElapsed(-s.timeIntervalSinceNow) }
                            }
                        )
                        let mobilePages = max(1, (rawMobile.count + pageSize - 1) / pageSize)
                        log.info("Jamf: fetched \(rawMobile.count) mobile devices across \(mobilePages) page(s).")
                        runJamfCount += rawMobile.count
                    } catch {
                        log.warn("Step 2/4 — Jamf mobile fetch failed: \(error.localizedDescription). Continuing without mobile devices.")
                        rawMobile = []
                    }
                    } else {
                        log.info("Step 2/4 — Jamf mobile devices skipped (Sync Device Types = Mac Only).")
                    }
                }
            }

            // ── Step 2b: Merge & classify ────────────────────────────────
            if rawABM.isEmpty && rawJamf.isEmpty && rawMobile.isEmpty {
                log.info("Both caches fresh — skipping merge (using cached device records).")
                // Reload CoreData so Step 3/4 work against up-to-date coverage statuses
                await store.loadDevicesFromCoreDataSync()
            } else {
                stepLabel = "Merging AxM + Jamf datasets…"
                // Fetch existing devices directly from CoreData for the merge.
                // We do NOT use store.devices here — it may be stale due to the
                // suppressAutoReload gate or async merge timing. A direct fetch from
                // a fresh background context guarantees we see all previously saved
                // Jamf/AxM records (including jamfId) regardless of UI reload state.
                let existingSnap: [Device] = await store.fetchAllDevicesForMerge()
                log.info("Merge: loaded \(existingSnap.count) existing from CoreData — \(existingSnap.filter{$0.deviceSource == .jamfOnly}.count) jamfOnly, \(existingSnap.filter{$0.jamfId != nil}.count) with jamfId.")
                // Run merge off MainActor — it's CPU-bound dict work over 60k items
                let abmSnapshot    = rawABM
                let jamfSnapshot   = rawJamf
                let mobileSnapshot = rawMobile
                let mergeResult = await Task.detached(priority: .userInitiated) {
                    mergeDevicesOffActor(abm: abmSnapshot, jamf: jamfSnapshot, mobile: mobileSnapshot, existing: existingSnap)
                }.value
                let merged = mergeResult.devices
                if mergeResult.clearedExternally > 0 {
                    log.warn("\(mergeResult.clearedExternally) device(s) had purchasing data changed or cleared in Jamf (warrantyDate / vendor / poNumber / poDate) — re-queued for write-back.")
                    log.debug("[Detail] Purchasing data mismatch: \(mergeResult.clearedExternally) device(s) found with one or more fields changed in Jamf since last sync.")
                }

                let released  = merged.filter { $0.axmDeviceStatus == "RELEASED" }.count
                if released > 0 { log.warn("\(released) device(s) no longer in org — status RELEASED.") }

                let both     = merged.filter { $0.deviceSource == .both     }.count
                let axmOnly  = merged.filter { $0.deviceSource == .axmOnly  }.count
                let jamfOnly = merged.filter { $0.deviceSource == .jamfOnly }.count
                log.info("Merge: \(merged.count) total — \(both) both, \(axmOnly) AxM-only, \(jamfOnly) Jamf-only.")
                let existingBoth     = existingSnap.filter { $0.deviceSource == .both     }.count
                let existingAxmOnly  = existingSnap.filter { $0.deviceSource == .axmOnly  }.count
                let existingJamfOnly = existingSnap.filter { $0.deviceSource == .jamfOnly }.count
                log.debug("Merge inputs: \(abmSnapshot.count) AxM, \(jamfSnapshot.count) Jamf computers, \(mobileSnapshot.count) Jamf mobile | existing CoreData: \(existingSnap.count) total (\(existingBoth) both, \(existingAxmOnly) AxM-only, \(existingJamfOnly) Jamf-only)")


                stepLabel = "Saving \(merged.count) devices to CoreData…"
                await store.upsertDevices(merged.map { $0.toDevice() })
                // A2: Wait for CoreData reload to complete so Step 3 sees fresh device list
                await store.loadDevicesFromCoreDataSync()

                // Only stamp each timestamp when that source actually contributed fresh data.
                // If AxM cache was fresh (rawABM empty), do NOT update lastAxmSync — the old
                // timestamp is still correct and must not be reset to now (would make both
                // timestamps identical and mask the fact that AxM ran earlier than Jamf).
                // IMPORTANT: do NOT stamp lastAxmSync if a resume cursor is still saved —
                // a partial fetch is not complete. axmIsFresh must stay false so the next
                // run re-enters Phase 1 and continues from the cursor.
                let axmFetchComplete = !rawABM.isEmpty && prefs.axmResumeCursor == nil
                if axmFetchComplete { prefs.lastAxmSync  = Date() }
                if !rawJamf.isEmpty || !rawMobile.isEmpty { prefs.lastJamfSync = Date() }
                // Persist active scope so relaunch always restores the right ABM/ASM context
                prefs.activeScope = store.axmCredentials.scope.rawValue
                // Stamp dataCachedScope — authoritative lock source used by SetupView
                // to prevent switching scope while data exists in cache.
                prefs.dataCachedScope = store.axmCredentials.scope.rawValue
                log.info("Saved \(merged.count) devices to CoreData.")
            }

            // ── Step 3: AppleCare Coverage ───────────────────────────────
            //
            // Behaviour matrix:
            //   skipExistingCoverage = ON  → only ever fetch .notFetched devices (never re-fetch)
            //   skipExistingCoverage = OFF → re-fetch devices whose per-device axmCoverageFetchedAt
            //                               is older than coverageCacheDays, BUT only AFTER all
            //                               .notFetched devices are done (resume takes priority).
            //                               This means a stopped mid-run always continues where it
            //                               left off rather than restarting from the beginning.
            //
            // Skip Step 3 entirely when:
            //   - forceCoverage is false, AND
            //   - no .notFetched devices remain, AND
            //   - (Do Not Refetch ON  → nothing to re-fetch by definition)
            //     (Do Not Refetch OFF → all fetched devices are still within cache days)
            let coverageLimitActive = prefs.coverageLimit > 0
            let cacheDaysSecs       = Double(prefs.coverageCacheDays) * 86_400
            let now                 = Date()
            let isoParser           = ISO8601DateFormatter()

            let syncScope = prefs.syncDeviceScope
            let notFetchedDevices = store.devices.filter {
                // axmDeviceId == nil means AxM was skipped this run (cache fresh) and the device
                // was merged from Jamf only — it has no ABM/ASM device ID to query the coverage API.
                // Excluding nil-ID devices here prevents the "Coverage skipped — no AxM device ID" warn.
                guard $0.deviceSource != .jamfOnly && $0.axmDeviceId != nil && $0.coverageStatus == .notFetched else { return false }
                // Respect Sync Device Types setting — skip device types not selected
                switch syncScope {
                case .both:   return true
                case .mac:    return !$0.isMobile
                case .mobile: return $0.isMobile
                }
            }
            let notFetchedCount = notFetchedDevices.count

            // Devices that are fetched but whose per-device timestamp is older than cache days.
            // Only relevant when Do Not Refetch is OFF.
            // Short-circuit: if the global coverageIsFresh flag is true, no per-device check needed.
            let staleDevices: [Device] = (prefs.skipExistingCoverage || prefs.coverageIsFresh) ? [] : store.devices.filter {
                guard $0.deviceSource != .jamfOnly && $0.axmDeviceId != nil && $0.coverageStatus != .notFetched else { return false }
                // Respect Sync Device Types setting
                switch syncScope {
                case .mac:    if $0.isMobile  { return false }
                case .mobile: if !$0.isMobile { return false }
                case .both:   break
                }
                guard let fetchedStr = $0.axmCoverageFetchedAt,
                      let fetchedDate = isoParser.date(from: fetchedStr)
                        ?? ISO8601DateFormatter().date(from: fetchedStr) else { return true }
                return now.timeIntervalSince(fetchedDate) > cacheDaysSecs
            }

            let skipCoverage = !forceCoverage
                && notFetchedCount == 0
                && (prefs.skipExistingCoverage || staleDevices.isEmpty)

            // Hard gate: AxM credentials must be present to call Apple's coverage API.
            // If credentials were cleared after a previous run, skip Step 3 entirely.
            let axmCredsAvailable = !store.axmCredentials.clientId.isEmpty
                && !store.axmCredentials.keyId.isEmpty
                && !store.axmCredentials.privateKeyContent.isEmpty

            // Gate: if the org device fetch is incomplete (cursor still saved), skip coverage.
            // Running 3+ hours of coverage API calls on a partial device set is wasteful —
            // the remaining devices will need coverage anyway once the fetch completes.
            // Jamf write-back (Step 4) still runs for devices that already have cached coverage.
            let axmFetchIncomplete = prefs.axmResumeCursor != nil
            if syncScope != .both {
                log.info("Step 3/4 — Sync Device Types: \(syncScope.label) — coverage and write-back scoped accordingly.")
            }

            if axmFetchIncomplete {
                let fetchedSoFar = store.devices.filter { $0.deviceSource != .jamfOnly && $0.axmDeviceId != nil }.count
                log.warn("Step 3/4 — AppleCare coverage API skipped: Apple org devices fetch is incomplete — \(fetchedSoFar) devices fetched so far, remaining pages still pending. Re-sync to fetch the remaining devices from Apple. Coverage will run automatically once all pages are complete.")
            } else if !axmCredsAvailable {
                log.warn("Step 3/4 — AxM credentials not configured — skipping coverage fetch.")
            } else if case .failure = store.axmAuthStatus {
                log.warn("Step 3/4 — AxM auth failed — skipping coverage fetch.")
            } else if skipCoverage {
                log.info("Step 3/4 — Coverage cache fresh and all devices fetched — skipping.")
            } else {
                phase = .coverage; stepStartTime = Date(); stepElapsed = ""
                NSApp.dockTile.badgeLabel = "3/4"; NSApp.requestUserAttention(.informationalRequest)

                // forceCoverage = ON  → ALL eligible devices are re-fetched and re-patched,
                //                      ignoring cache timestamps entirely. This is a full
                //                      force-refresh: notFetched priority does NOT apply.
                // forceCoverage = OFF → resume semantics: finish .notFetched first, then
                //                      re-fetch stale devices (per coverageCacheDays).
                let allFetchableDevices: [Device] = store.devices.filter {
                    $0.deviceSource != .jamfOnly && $0.axmDeviceId != nil
                }
                let needsCoverage: [Device] = forceCoverage
                    ? allFetchableDevices                                          // force: re-fetch everything
                    : (notFetchedCount > 0 ? notFetchedDevices : staleDevices)    // normal: resume then stale

                let limit   = coverageLimitActive
                    ? min(prefs.coverageLimit, needsCoverage.count)
                    : needsCoverage.count
                let targets = Array(needsCoverage.prefix(limit))

                log.info("Step 3/4 — Fetching AppleCare coverage for \(targets.count) device(s)" +
                         (prefs.coverageLimit > 0 ? " (limit: \(prefs.coverageLimit))" : ""))

                if targets.isEmpty {
                    log.info("Coverage: all devices already have coverage data.")
                } else {
                    totalSteps  = targets.count
                    currentStep = 0
                    stepETA = ""; totalETA = ""
                    // ETA: record start time and index once so we can compute rate
                    coverageStartTime  = Date()
                    coverageStartIndex = 0

                    var covActive = 0, covInactive = 0, covNone = 0
                    var covProcessed = 0   // tracks how many were actually attempted (for abort summary)
                    var covAborted = false

                    // Q1: Extracted helper — the same 4-line record pattern was duplicated
                    // in 3 catch branches (normal, -1005 retry, auth retry, rate-limit retry).
                    // A single closure captures the mutable counters and batch by reference.
                    func recordCoverageResult(_ coverage: DeviceCoverage, for device: Device, label: String) {
                        switch coverage.status {
                        case .active:                       covActive   += 1
                        case .inactive,.expired,.cancelled: covInactive += 1
                        case .noCoverage:                   covNone     += 1
                        default: break
                        }
                        covProcessed += 1
                        covBatch.append(device.applyingCoverage(coverage, forceWBPending: forceCoverage))
                        log.info(label)
                    }

                    // ── 3-concurrent coverage fetch (matches v1.0) ───────────────
                    // 3 tasks run in parallel per chunk via TaskGroup.
                    // No inter-chunk pause — the 429 retry (15s) handles actual rate limiting.
                    // Each task receives the shared coverageSession so no per-task TLS handshake
                    // is needed. On URLError the retry uses a fresh session via the session:
                    // parameter — same isolation guarantee without the per-device TLS cost.
                    enum CovResult {
                        case success(Device, DeviceCoverage, Int)
                        case skipped(String, Int)
                        case authAbort
                        case rateLimited(Device, Int)
                    }

                    let covConcurrency = 3
                    let covChunks = stride(from: 0, to: targets.count, by: covConcurrency).map {
                        Array(targets[$0 ..< min($0 + covConcurrency, targets.count)])
                    }

                    chunkCovLoop: for (chunkIdx, chunk) in covChunks.enumerated() {
                        try Task.checkCancellation()

                        // Small inter-chunk pause — gives Apple's server a breath between bursts.
                        if chunkIdx > 0 {
                            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                        }

                        let chunkResults: [CovResult] = await withTaskGroup(of: CovResult.self) { group in
                            for (j, device) in chunk.enumerated() {
                                let globalIdx = chunkIdx * covConcurrency + j
                                group.addTask {
                                    guard let deviceId = device.axmDeviceId else {
                                        return .skipped(device.serialNumber, globalIdx)
                                    }
                                    // Each task gets its own dedicated URLSession so a connection
                                    // reset on one task does not affect the others. Apple's coverage
                                    // endpoint closes HTTP/2 streams under concurrent load; isolating
                                    // sessions means a reset only affects the one task that hit it.
                                    let taskSession = _makeABMCoverageSession()

                                    // Attempt 1
                                    do {
                                        let cov = try await abmService.fetchCoverage(
                                            deviceId: deviceId, serialNumber: device.serialNumber,
                                            session: taskSession)
                                        return .success(device, cov, globalIdx)
                                    } catch let urlErr as URLError {
                                        // Connection reset or stream error — wait and retry on a
                                        // fresh session (the original taskSession may be broken).
                                        let backoff: UInt64 = 2_000_000_000 // 2s
                                        await LogService.shared.warn("Coverage [\(globalIdx+1)/\(targets.count)] \(device.serialNumber): URLError \(urlErr.code.rawValue) — retrying with fresh session…")
                                        let retrySession = _makeABMCoverageSession()
                                        try? await Task.sleep(nanoseconds: backoff)
                                        do {
                                            let cov = try await abmService.fetchCoverage(
                                                deviceId: deviceId, serialNumber: device.serialNumber,
                                                session: retrySession)
                                            return .success(device, cov, globalIdx)
                                        } catch {
                                            await LogService.shared.warn("Coverage [\(globalIdx+1)/\(targets.count)] \(device.serialNumber): skipped after URLError retry — \(error.localizedDescription)")
                                            return .skipped(device.serialNumber, globalIdx)
                                        }
                                    } catch {
                                        let msg = error.localizedDescription.lowercased()
                                        if msg.contains("400") || msg.contains("401") || msg.contains("unauthori") || msg.contains("token") || msg.contains("invalid_client") {
                                            await abmService.clearToken()
                                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                                            do {
                                                let cov = try await abmService.fetchCoverage(
                                                    deviceId: deviceId, serialNumber: device.serialNumber)
                                                return .success(device, cov, globalIdx)
                                            } catch {
                                                return .authAbort
                                            }
                                        } else if msg.contains("429") || msg.contains("rate") {
                                            try? await Task.sleep(nanoseconds: 15_000_000_000)
                                            do {
                                                let cov = try await abmService.fetchCoverage(
                                                    deviceId: deviceId, serialNumber: device.serialNumber)
                                                return .success(device, cov, globalIdx)
                                            } catch {
                                                return .rateLimited(device, globalIdx)
                                            }
                                        } else {
                                            await LogService.shared.warn("Coverage [\(globalIdx+1)/\(targets.count)] \(device.serialNumber): skipped — \(error.localizedDescription)")
                                            return .skipped(device.serialNumber, globalIdx)
                                        }
                                    }
                                }
                            }
                            var results: [CovResult] = []
                            for await r in group { results.append(r) }
                            return results
                        }

                        // Process chunk results serially on MainActor
                        for result in chunkResults.sorted(by: {
                            if case .success(_, _, let a) = $0, case .success(_, _, let b) = $1 { return a < b }
                            return false
                        }) {
                            switch result {
                            case .success(let device, let coverage, let idx):
                                currentStep = idx + 1
                                let etaStr: String
                                if idx >= 3, let start = coverageStartTime {
                                    let elapsed   = -start.timeIntervalSinceNow
                                    let rate      = elapsed / Double(idx - coverageStartIndex)
                                    let remaining = rate * Double(targets.count - idx - 1)
                                    let remMins   = Int(remaining) / 60
                                    let remSecs   = Int(remaining) % 60
                                    etaStr = remMins > 0 ? "~\(remMins)m \(remSecs)s remaining" : "~\(remSecs)s remaining"
                                    let totalSecs = Int(remaining)
                                    let th = totalSecs / 3600; let tm = (totalSecs % 3600) / 60
                                    totalETA = th > 0 ? "~\(th)h \(tm)m total" : "~\(tm)m total"
                                } else { etaStr = ""; totalETA = "" }
                                stepETA   = etaStr
                                stepLabel = "Fetching Apple Coverage [\(idx+1)/\(targets.count)] \(device.serialNumber)" +
                                            (etaStr.isEmpty ? "" : " — \(etaStr)")
                                recordCoverageResult(coverage, for: device,
                                    label: "Coverage [\(idx+1)/\(targets.count)] \(device.serialNumber): \(coverage.status.label)")
                            case .skipped(let serial, let idx):
                                log.warn("Coverage [\(idx+1)/\(targets.count)] \(serial): skipped")
                                currentStep = idx + 1
                            case .rateLimited(let device, let idx):
                                log.warn("Coverage [\(idx+1)/\(targets.count)] \(device.serialNumber): rate-limit retry failed — skipping")
                                currentStep = idx + 1
                            case .authAbort:
                                log.error("Coverage: auth failed after retry — aborting coverage step.")
                                if !covBatch.isEmpty { await store.upsertDevices(covBatch); covBatch.removeAll() }
                                covAborted = true
                                break chunkCovLoop
                            }
                        }

                        // Flush batch every 50 results
                        if covBatch.count >= 50 {
                            await store.upsertDevices(covBatch)
                            covBatch.removeAll()
                            await store.loadDevicesFromCoreDataSync()
                        }
                    }
                    if !covBatch.isEmpty { await store.upsertDevices(covBatch); covBatch.removeAll() }
                    runCoverageCount = covProcessed
                    // B2: Only stamp lastCoverageSync when ALL devices are covered (no limit cap).
                    // If a limit is active and there are still unchecked devices, leave the timestamp
                    // unset so the next run re-enters Step 3 and continues the next batch.
                    // Reload from CoreData to get accurate post-coverage counts
                    await store.loadDevicesFromCoreDataSync()
                    let stillUnfetched = store.devices.filter {
                        $0.deviceSource != .jamfOnly && $0.coverageStatus == .notFetched
                    }.count
                    if stillUnfetched == 0 {
                        // All devices covered — stamp timestamp so next run can skip Step 3
                        prefs.lastCoverageSync = Date()
                        log.info("Coverage: all devices checked — timestamp updated.")
                    } else if prefs.coverageLimit == 0 {
                        // No limit set but some remain unchecked (e.g. no AxM device ID) — still stamp
                        prefs.lastCoverageSync = Date()
                        log.info("Coverage: \(stillUnfetched) device(s) remain unchecked (no AxM ID or skipped) — timestamp updated.")
                    } else {
                        // Limit active and devices remain — do NOT stamp; next run picks up next batch
                        log.info("Coverage: \(stillUnfetched) device(s) still not fetched — timestamp held so next run continues batch.")
                    }
                    if covProcessed > 0 || !covAborted {
                        log.info("Coverage: \(covProcessed) fetched — \(covActive) active, \(covInactive) expired/inactive, \(covNone) no plan.")
                    }
                    if covAborted {
                        log.warn("Coverage step aborted due to auth failure — check ASM/ABM credentials in Setup and re-authenticate.")
                        store.axmAuthStatus = .failure("Coverage auth error — re-authenticate in Setup.")
                    }
                    stepETA = ""; totalETA = ""
                }
            }

            // ── Pre-Step 4: Reset .failed → .pending ────────────────────
            // Failed devices must be retried on every sync run. The merge function
            // handles this when a fresh fetch ran (rawABM/rawJamf non-empty), but when
            // both caches are fresh the merge is skipped entirely — devices load straight
            // from CoreData with their .failed status intact. Reset them here so Phase 4
            // always picks them up regardless of whether the merge ran this session.
            let failedDevices = store.devices.filter {
                $0.wbStatus == .failed
                    && $0.deviceSource != .axmOnly
                    && $0.coverageStatus != .notFetched   // only retry if we have coverage data to write
                    && $0.jamfId != nil                   // only retry if we have a Jamf record to PATCH
            }
            if !failedDevices.isEmpty {
                log.info("Pre-Step 4: resetting \(failedDevices.count) .failed device(s) to .pending for retry.")
                let resetDevices = failedDevices.map { $0.withWBStatus(.pending, note: nil) }
                await store.upsertDevices(resetDevices)
                await store.loadDevicesFromCoreDataSync()
            }

            // ── Step 4: Jamf Write-back ──────────────────────────────────
            phase = .jamfUpdate; stepStartTime = Date(); stepElapsed = ""
                NSApp.dockTile.badgeLabel = "4/4"; NSApp.requestUserAttention(.informationalRequest)
            // Exclude AxM-only devices from Jamf Update — they have no jamfId.
            // When a full device sync later classifies them as .both, wbStatus resets to .pending.
            // Only write back devices that have real coverage data.
            // If a device is pending but has never had coverage fetched, writing back
            // only the vendor name (from AxM org API) is not useful.
            let allPending = store.devices.filter {
                guard $0.wbStatus == .pending && $0.deviceSource != .axmOnly else { return false }
                // Require at least one coverage field to have been populated.
                let hasCoverageData = $0.coverageStatus != .notFetched
                if !hasCoverageData {
                    return false  // skip: no coverage API data yet — don't write vendor-only
                }
                // Respect Sync Device Types setting — only write-back selected device types
                switch syncScope {
                case .both:   return true
                case .mac:    return !$0.isMobile
                case .mobile: return $0.isMobile
                }
            }
            // coverageLimit is an Apple API rate-limit only — it must NOT cap Step 4.
            // Any device that already has coverage data in CoreData but hasn't been
            // written to Jamf yet must be patched regardless of the coverage fetch limit.
            let wbTargets = allPending

            // ── Coverage → Jamf breakdown ────────────────────────────────────
            // Help the user understand why the write-back count differs from the
            // coverage fetch count (e.g. 100 coverage fetched but only 30 Jamf updates).
            let totalWithCoverage = store.devices.filter { $0.coverageStatus != .notFetched && $0.deviceSource != .jamfOnly }.count
            let skippedAxmOnly   = store.devices.filter { $0.wbStatus == .pending && $0.deviceSource == .axmOnly }.count
            let skippedNoCov     = store.devices.filter { $0.wbStatus == .pending && $0.coverageStatus == .notFetched && $0.deviceSource != .axmOnly }.count
            let alreadySynced    = store.devices.filter { $0.wbStatus == .synced }.count
            log.info("Step 4/4 — Jamf Update for \(wbTargets.count) device(s)")
            log.info("  Coverage in cache : \(totalWithCoverage) device(s) have AppleCare data")
            log.info("  Fetched this run  : \(runCoverageCount) device(s) coverage retrieved")
            log.info("  Pending write-back: \(wbTargets.count) device(s) queued for Jamf PATCH")
            log.info("  Already synced    : \(alreadySynced) device(s) previously written to Jamf")
            if skippedAxmOnly > 0 {
                log.info("  Skipped (AxM only): \(skippedAxmOnly) device(s) — no Jamf record to update")
            }
            if skippedNoCov > 0 {
                log.info("  Skipped (no cov)  : \(skippedNoCov) device(s) — coverage not yet fetched")
            }

            var wbSynced = 0, wbFailed = 0, wbSkipped = 0

            if wbTargets.isEmpty {
                log.info("Jamf Update: nothing pending.")
            } else {
                totalSteps  = wbTargets.count
                currentStep = 0

                // ── Concurrent Jamf PATCH ─────────────────────────────────────
                // Jamf Pro's PATCH /api/v3/computers-inventory-detail/{id} endpoints
                // are independent resources — safe to hit concurrently. We cap at
                // 8 in-flight requests so we don't overwhelm on-premise Jamf servers.
                // A single OAuth token is fetched once up-front and reused by all tasks.
                // An auth failure in any task cancels the whole group (fail-fast).
                // 5 concurrent PATCH tasks — reduced from 8 to avoid connection pool exhaustion.
                // With 8 tasks sharing Jamf Cloud's keep-alive connections, the load balancer
                // closes idle connections mid-flight causing -999 NSURLErrorCancelled errors.
                // 5 stays well within Jamf's recommended concurrency while avoiding this.
                let concurrency = 5

                // Thread-safe accumulators — written only on MainActor via batched upsert
                // but counted locally then merged after TaskGroup.
                // Result type carries the updated Device plus a success/fail flag.
                enum WBResult {
                    case synced(Device)
                    case failed(Device, String)
                    case skipped(Device, String)
                    case authAbort   // signals group to cancel
                }

                var wbBatch: [Device] = []

                // Split into chunks of `concurrency` and process chunk-by-chunk so we
                // can flush to CoreData and update live counters between chunks.
                let chunks = stride(from: 0, to: wbTargets.count, by: concurrency).map {
                    Array(wbTargets[$0 ..< min($0 + concurrency, wbTargets.count)])
                }

                let wbStartTime = Date()
                chunkLoop: for (chunkIdx, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    let chunkOffset = chunkIdx * concurrency
                    // Refresh token per chunk — validToken() uses in-memory cache with 60s
                    // buffer so this is a free date comparison on most chunks. Prevents
                    // 401 mid-write-back on Jamf instances with short token TTLs.
                    let sharedJamfToken = try await jamfService.validToken()

                    let results: [WBResult] = try await withThrowingTaskGroup(of: WBResult.self) { group in
                        for (j, device) in chunk.enumerated() {
                            group.addTask {
                                guard let jamfId = device.jamfId else {
                                    return .skipped(device, "No Jamf ID")
                                }
                                // Inner helper — attempt one PATCH, return the WBResult.
                                // Extracted so we can call it twice (initial + -999 retry).
                                // Build vendor string: "purchaseSourceType (purchaseSourceId)"
                                // If purchaseSourceId is nil/empty, use purchaseSourceType alone.
                                let vendorStr: String? = {
                                    guard let src = device.axmPurchaseSource, !src.isEmpty else { return nil }
                                    if let sid = device.axmPurchaseSourceId, !sid.isEmpty {
                                        return "\(src) (\(sid))"
                                    }
                                    return src
                                }()
                                func attempt() async throws {
                                    if device.isMobile {
                                        try await jamfService.writeWarrantyBackMobile(
                                            mobileDeviceId: jamfId,
                                            warrantyDate:   device.axmCoverageEndDate,
                                            appleCareId:    device.axmAgreementNumber,
                                            vendor:         vendorStr,
                                            poNumber:       device.axmOrderNumber,
                                            poDate:         device.axmOrderDate,
                                            token:          sharedJamfToken
                                        )
                                    } else {
                                        try await jamfService.writeWarrantyBack(
                                            jamfId:       jamfId,
                                            warrantyDate: device.axmCoverageEndDate,
                                            appleCareId:  device.axmAgreementNumber,
                                            vendor:       vendorStr,
                                            poNumber:     device.axmOrderNumber,
                                            poDate:       device.axmOrderDate,
                                            token:        sharedJamfToken
                                        )
                                    }
                                }
                                do {
                                    try await attempt()
                                    return .synced(device)
                                } catch let error as NSError where error.code == NSURLErrorCancelled {
                                    // -999 NSURLErrorCancelled: Jamf Cloud's load balancer closed
                                    // a shared keep-alive connection mid-flight. Not an auth failure —
                                    // safe to retry once after a short pause.
                                    await LogService.shared.debug("WB -999 cancelled for \(device.serialNumber) — retrying after 500ms")
                                    try await Task.sleep(nanoseconds: 500_000_000)
                                    do {
                                        try await attempt()
                                        return .synced(device)
                                    } catch {
                                        return .failed(device, "Cancelled (retry failed): \(error.localizedDescription)")
                                    }
                                } catch {
                                    let msg = error.localizedDescription.lowercased()
                                    if msg.contains("401") || msg.contains("unauthori") || msg.contains("token") {
                                        return .authAbort
                                    }
                                    return .failed(device, error.localizedDescription)
                                }
                            }
                            let _ = j  // suppress unused warning
                        }
                        var collected: [WBResult] = []
                        for try await result in group {
                            collected.append(result)
                            if case .authAbort = result { group.cancelAll() }
                        }
                        return collected
                    }

                    // Process chunk results
                    var authAborted = false
                    for (j, result) in results.enumerated() {
                        let globalIdx = chunkOffset + j + 1
                        switch result {
                        case .synced(let device):
                            wbSynced += 1
                            if device.isMobile { runWBSyncedMob += 1 } else { runWBSyncedMac += 1 }
                            currentStep = globalIdx
                            log.info("Jamf Update \(device.isMobile ? "Mobile" : "Mac") [\(globalIdx)/\(wbTargets.count)] \(device.serialNumber): OK")
                            wbBatch.append(device.withWBStatus(.synced, note: nil))
                        case .failed(let device, let msg):
                            wbFailed += 1
                            if device.isMobile { runWBFailedMob += 1 } else { runWBFailedMac += 1 }
                            currentStep = globalIdx
                            log.warn("Jamf Update \(device.isMobile ? "Mobile" : "Mac") FAILED \(device.serialNumber) — \(msg)")
                            wbBatch.append(device.withWBStatus(.failed, note: msg))
                        case .skipped(let device, let reason):
                            wbSkipped += 1
                            log.warn("Jamf Update skipped \(device.serialNumber) — \(reason)")
                            wbBatch.append(device.withWBStatus(.skipped, note: reason))
                        case .authAbort:
                            authAborted = true
                        }
                    }

                    // Auth abort: try a single token refresh then retry the whole chunk once
                    if authAborted {
                        log.warn("Jamf Update: auth error in chunk — invalidating token and retrying chunk once…")
                        await jamfService.invalidateToken()
                        _ = try? await jamfService.validToken()

                        // Retry only the devices that hit authAbort (those not yet in wbBatch for this chunk)
                        let retried = Set(wbBatch.suffix(chunk.count).map { $0.serialNumber })
                        let toRetry = chunk.filter { !retried.contains($0.serialNumber) }

                        if toRetry.isEmpty {
                            log.error("Jamf Update: auth error — aborting after chunk re-auth failed.")
                            if !wbBatch.isEmpty { await store.upsertDevices(wbBatch); wbBatch.removeAll() }
                            break chunkLoop
                        }

                        for device in toRetry {
                            guard let jamfId = device.jamfId else { continue }
                            let retryVendor: String? = {
                                guard let src = device.axmPurchaseSource, !src.isEmpty else { return nil }
                                if let sid = device.axmPurchaseSourceId, !sid.isEmpty { return "\(src) (\(sid))" }
                                return src
                            }()
                            do {
                                if device.isMobile {
                                    try await jamfService.writeWarrantyBackMobile(
                                        mobileDeviceId: jamfId,
                                        warrantyDate:   device.axmCoverageEndDate,
                                        appleCareId:    device.axmAgreementNumber,
                                        vendor:         retryVendor,
                                        poNumber:       device.axmOrderNumber,
                                        poDate:         device.axmOrderDate
                                    )
                                } else {
                                    try await jamfService.writeWarrantyBack(
                                        jamfId:       jamfId,
                                        warrantyDate: device.axmCoverageEndDate,
                                        appleCareId:  device.axmAgreementNumber,
                                        vendor:       retryVendor,
                                        poNumber:     device.axmOrderNumber,
                                        poDate:       device.axmOrderDate
                                    )
                                }
                                wbSynced += 1
                                if device.isMobile { runWBSyncedMob += 1 } else { runWBSyncedMac += 1 }
                                log.info("Jamf Update OK \(device.serialNumber) (re-auth retry succeeded)")
                                wbBatch.append(device.withWBStatus(.synced, note: nil))
                            } catch {
                                wbFailed += 1
                                if device.isMobile { runWBFailedMob += 1 } else { runWBFailedMac += 1 }
                                log.error("Jamf Update re-auth retry FAILED \(device.serialNumber) — aborting.")
                                wbBatch.append(device.withWBStatus(.failed, note: "Auth failed after retry"))
                                if !wbBatch.isEmpty { await store.upsertDevices(wbBatch); wbBatch.removeAll() }
                                break chunkLoop
                            }
                        }
                    }

                    // Flush batch every chunk for live UI updates
                    if !wbBatch.isEmpty {
                        await store.upsertDevices(wbBatch)
                        wbBatch.removeAll()
                        await store.loadDevicesFromCoreDataSync()
                    }
                    let wbDone = chunkOffset + chunk.count
                    if wbDone >= 2, wbDone < wbTargets.count {
                        let elapsed   = -wbStartTime.timeIntervalSinceNow
                        let rate      = elapsed / Double(wbDone)
                        let remaining = rate * Double(wbTargets.count - wbDone)
                        let rm = Int(remaining) / 60; let rs = Int(remaining) % 60
                        stepETA = rm > 0 ? "~\(rm)m \(rs)s remaining" : "~\(rs)s remaining"
                    } else if wbDone >= wbTargets.count {
                        stepETA = ""
                    }
                    stepLabel = "Jamf Update [\(min(chunkOffset + concurrency, wbTargets.count))/\(wbTargets.count)]"
                }

                if !wbBatch.isEmpty {
                    await store.upsertDevices(wbBatch)
                    await store.loadDevicesFromCoreDataSync()
                }
                runWBSynced = wbSynced
                runWBFailed = wbFailed
                // Mac/mobile breakdown logged for diagnostics
                let macDetail = runWBSyncedMac > 0 || runWBFailedMac > 0
                    ? "Mac: \(runWBSyncedMac) synced / \(runWBFailedMac) failed" : ""
                let mobDetail = runWBSyncedMob > 0 || runWBFailedMob > 0
                    ? "Mobile: \(runWBSyncedMob) synced / \(runWBFailedMob) failed" : ""
                let breakdown = [macDetail, mobDetail].filter { !$0.isEmpty }.joined(separator: "  |  ")
                log.info("Jamf Update: \(wbSynced) synced, \(wbFailed) failed, \(wbSkipped) skipped."
                         + (breakdown.isEmpty ? "" : "  [\(breakdown)]"))
            }

            // ── Done ─────────────────────────────────────────────────────
            lastRunAxm      = runAxmCount  > 0 ? "\(runAxmCount) fetched"  : "cached"
            lastRunJamf     = runJamfCount > 0 ? "\(runJamfCount) fetched" : "cached"
            lastRunCoverage = "\(runCoverageCount) fetched"
            // Build lastRunWB string with Mac/mobile breakdown
            let wbMacStr = (runWBSyncedMac + runWBFailedMac) > 0
                ? " (Mac: \(runWBSyncedMac) synced / \(runWBFailedMac) failed)" : ""
            let wbMobStr = (runWBSyncedMob + runWBFailedMob) > 0
                ? " (Mobile: \(runWBSyncedMob) synced / \(runWBFailedMob) failed)" : ""
            lastRunWB       = runWBFailed > 0
                ? "\(runWBSynced) synced, \(runWBFailed) failed\(wbMacStr)\(wbMobStr)"
                : "\(runWBSynced) synced\(wbMacStr)\(wbMobStr)"
            // Rich summary
            let elapsed = Int(Date().timeIntervalSince(runStart))
            lastRunDate        = Date()
            lastRunElapsedSecs = elapsed
            lastRunElapsed     = elapsed >= 60 ? "\(elapsed/60)m \(elapsed%60)s" : "\(elapsed)s"
            lastRunAxmCount    = runAxmCount
            lastRunJamfCount   = runJamfCount
            lastRunCovFetched  = runCoverageCount
            lastRunCovActive   = store.stats.coverageActive
            lastRunCovNone     = store.stats.coverageNoPlan
            lastRunCovInactive = store.stats.coverageInactive
            lastRunWBSynced    = runWBSynced
            lastRunWBFailed    = runWBFailed
            lastRunWBSyncedMac = runWBSyncedMac
            lastRunWBFailedMac = runWBFailedMac
            lastRunWBSyncedMob = runWBSyncedMob
            lastRunWBFailedMob = runWBFailedMob
            // Count devices served from cache (not re-fetched this run).
            // Fix #7: subtract actually-fetched counts rather than using max() which
            // over-reports when only one source was cached.
            lastRunFromCache = max(0, store.devices.count - runAxmCount - runJamfCount)

            // Persist summary to UserDefaults so it survives app relaunch.
            await MainActor.run {
                store.prefs.lrDateEpoch   = lastRunDate?.timeIntervalSince1970 ?? 0
                store.prefs.lrElapsedSecs = elapsed
                store.prefs.lrAxmCount    = lastRunAxmCount
                store.prefs.lrJamfCount   = lastRunJamfCount
                store.prefs.lrFromCache   = lastRunFromCache
                store.prefs.lrCovActive   = lastRunCovActive
                store.prefs.lrCovInactive = lastRunCovInactive
                store.prefs.lrCovNone     = lastRunCovNone
                store.prefs.lrCovFetched  = lastRunCovFetched
                store.prefs.lrWBSynced    = lastRunWBSynced
                store.prefs.lrWBFailed    = lastRunWBFailed
            }

            phase    = .done
            tabBadge = ""
            SyncNotificationService.sendCompletion(
                devices: store.devices.count,
                coverage: runCoverageCount,
                writeback: runWBSynced
            )
            NSApp.dockTile.badgeLabel = nil

            stepLabel = "Sync complete — \(store.devices.count) devices | " +
                        "coverage: \(store.devices.filter { $0.coverageStatus == .active }.count) active | " +
                        "Jamf Update: \(wbSynced) synced"
            currentStep = totalSteps
            log.info(stepLabel)
            store.recomputeStats()

            // ── Run Summary ──────────────────────────────────────────────────
            let endTime   = Date()
            let elapsedH  = elapsed / 3600
            let elapsedM  = (elapsed % 3600) / 60
            let elapsedS  = elapsed % 60
            let elapsedFmt = elapsedH > 0
                ? "\(elapsedH)h \(elapsedM)m \(elapsedS)s"
                : elapsedM > 0 ? "\(elapsedM)m \(elapsedS)s" : "\(elapsedS)s"
            let axmLine   = runAxmCount  > 0 ? "\(runAxmCount)" : "from cache"
            let jamfLine  = runJamfCount > 0 ? "\(runJamfCount)" : "from cache"
            let covActive = store.stats.coverageActive
            let covNone   = store.stats.coverageNoPlan
            let covInact  = store.stats.coverageInactive
            log.info("═══════════════════════════════════════════════")
            log.info("  SYNC SUMMARY")
            log.info("═══════════════════════════════════════════════")
            log.info("  Sync Device Types   : \(prefs.syncDeviceScope.label)")
            log.info("  Started             : \(df.string(from: runStart))")
            log.info("  Ended               : \(df.string(from: endTime))")
            log.info("  Total time          : \(elapsedFmt)")
            log.info("  ───────────────────────────────────────────")
            log.info("  AxM devices         : \(axmLine)")
            log.info("  Jamf devices        : \(jamfLine)")
            log.info("  Total in cache      : \(store.devices.count)")
            log.info("  ───────────────────────────────────────────")
            log.info("  Coverage fetched    : \(runCoverageCount)")
            log.info("  Coverage active     : \(covActive)")
            log.info("  Coverage inactive   : \(covInact)")
            log.info("  No coverage         : \(covNone)")
            log.info("  ───────────────────────────────────────────")
            log.info("  Jamf write-back     : \(runWBSynced) synced / \(runWBFailed) failed")
            if (runWBSyncedMac + runWBFailedMac) > 0 {
                log.info("    Mac               : \(runWBSyncedMac) synced / \(runWBFailedMac) failed")
            }
            if (runWBSyncedMob + runWBFailedMob) > 0 {
                log.info("    Mobile            : \(runWBSyncedMob) synced / \(runWBFailedMob) failed")
            }
            if prefs.axmResumeCursor != nil {
                log.warn("  AxM fetch incomplete: cursor saved — re-sync to fetch remaining devices")
            }
            log.info("═══════════════════════════════════════════════")

        } catch is CancellationError {
            phase     = .idle
            stepLabel = "Stopped."
            log.warn("Sync cancelled by user.")

            // ── Persist last run summary for stop-sync so UI reflects actual work done ──
            let stopElapsed = Int(Date().timeIntervalSince(runStart))
            lastRunDate        = Date()
            lastRunElapsedSecs = stopElapsed
            lastRunElapsed     = stopElapsed >= 60 ? "\(stopElapsed/60)m \(stopElapsed%60)s" : "\(stopElapsed)s"
            lastRunAxmCount    = runAxmCount
            lastRunJamfCount   = runJamfCount
            lastRunCovFetched  = runCoverageCount
            lastRunCovActive   = store.stats.coverageActive
            lastRunCovNone     = store.stats.coverageNoPlan
            lastRunCovInactive = store.stats.coverageInactive
            lastRunWBSynced    = runWBSynced
            lastRunWBFailed    = runWBFailed
            lastRunWBSyncedMac = runWBSyncedMac
            lastRunWBFailedMac = runWBFailedMac
            lastRunWBSyncedMob = runWBSyncedMob
            lastRunWBFailedMob = runWBFailedMob
            lastRunFromCache   = max(0, store.devices.count - runAxmCount - runJamfCount)
            lastRunAxm      = runAxmCount  > 0 ? "\(runAxmCount) fetched"  : "cached"
            lastRunJamf     = runJamfCount > 0 ? "\(runJamfCount) fetched" : "cached"
            lastRunCoverage = "\(runCoverageCount) fetched (stopped)"
            let wbMacStrStop = (runWBSyncedMac + runWBFailedMac) > 0
                ? " (Mac: \(runWBSyncedMac) synced / \(runWBFailedMac) failed)" : ""
            let wbMobStrStop = (runWBSyncedMob + runWBFailedMob) > 0
                ? " (Mobile: \(runWBSyncedMob) synced / \(runWBFailedMob) failed)" : ""
            lastRunWB       = lastRunWBFailed > 0
                ? "\(lastRunWBSynced) synced, \(lastRunWBFailed) failed\(wbMacStrStop)\(wbMobStrStop)"
                : "\(lastRunWBSynced) synced\(wbMacStrStop)\(wbMobStrStop)"
            await MainActor.run {
                store.prefs.lrDateEpoch   = lastRunDate?.timeIntervalSince1970 ?? 0
                store.prefs.lrElapsedSecs = stopElapsed
                store.prefs.lrAxmCount    = lastRunAxmCount
                store.prefs.lrJamfCount   = lastRunJamfCount
                store.prefs.lrFromCache   = lastRunFromCache
                store.prefs.lrCovActive   = lastRunCovActive
                store.prefs.lrCovInactive = lastRunCovInactive
                store.prefs.lrCovNone     = lastRunCovNone
                store.prefs.lrCovFetched  = lastRunCovFetched
                store.prefs.lrWBSynced    = lastRunWBSynced
                store.prefs.lrWBFailed    = lastRunWBFailed
            }

            // ── Flush partial coverage batch (Stop mid-Step 3) ─────────────
            // covBatch is declared outside do{} exactly so it survives unwinding.
            // Task.checkCancellation() fires at the TOP of the coverage for-loop,
            // meaning up to 49 already-fetched devices are sitting in covBatch
            // unwritten. Save them now before any other cleanup.
            if !covBatch.isEmpty {
                log.info("Flushing \(covBatch.count) partial coverage record(s) interrupted by Stop.")
                await store.upsertDevices(covBatch)
                covBatch.removeAll()
                await store.loadDevicesFromCoreDataSync()
            }

            // ── Save partial Step 1/2 fetch (Stop mid-device fetch) ────────
            // If Stop was pressed mid-Step 1 or 2, rawABM/rawJamf hold the pages
            // already downloaded. Merge and upsert them now so they aren't lost.
            if !rawABM.isEmpty || !rawJamf.isEmpty || !rawMobile.isEmpty {
                log.info("Saving \(rawABM.count) AxM + \(rawJamf.count) Jamf + \(rawMobile.count) mobile partial results before exit…")
                let existingSnap = await store.fetchAllDevicesForMerge()
                let partialResult = await Task.detached(priority: .userInitiated) {
                    mergeDevicesOffActor(abm: rawABM, jamf: rawJamf, mobile: rawMobile, existing: existingSnap)
                }.value
                let partial = partialResult.devices
                if partialResult.clearedExternally > 0 {
                    log.warn("\(partialResult.clearedExternally) device(s) had purchasing data changed or cleared in Jamf (warrantyDate / vendor / poNumber / poDate) — re-queued for write-back.")
                    log.debug("[Detail] Purchasing data mismatch: \(partialResult.clearedExternally) device(s) found with one or more fields changed in Jamf since last sync.")
                }
                await store.upsertDevices(partial.map { $0.toDevice() })
                await store.loadDevicesFromCoreDataSync()
                // Only stamp lastAxmSync if no resume cursor is pending — a partial
                // fetch must not mark the cache as fresh.
                if !rawABM.isEmpty && prefs.axmResumeCursor == nil { prefs.lastAxmSync  = Date() }
                if !rawJamf.isEmpty || !rawMobile.isEmpty { prefs.lastJamfSync = Date() }
                prefs.activeScope = store.axmCredentials.scope.rawValue
                prefs.dataCachedScope = store.axmCredentials.scope.rawValue
                log.info("Partial data saved (\(partial.count) devices). Next Run Sync will resume from Step 3.")
            }
        } catch let e as SyncError {
            phase = .error; lastError = e.localizedDescription
            stepLabel = "Error: \(e.localizedDescription)"
            log.error(e.localizedDescription)
            SyncNotificationService.sendError(message: e.localizedDescription)
        } catch {
            phase = .error; lastError = error.localizedDescription
            stepLabel = "Error: \(error.localizedDescription)"
            log.error(error.localizedDescription)
            SyncNotificationService.sendError(message: error.localizedDescription)
        }

        // End-of-run cleanup — runs regardless of success, error, or cancellation.
        // IMPORTANT: do NOT call clearToken() here. clearToken() wipes the Keychain entry,
        // which means the next run always hits Apple's token endpoint for a fresh token —
        // causing HTTP 429 rate-limit errors on back-to-back syncs.
        // The actors themselves are nilled out (invalidating their in-memory state) but the
        // Keychain token is left intact so the next ABMService init can load and reuse it.
        store.suppressAutoReload = false
        tabBadge = ""
        NSApp.dockTile.badgeLabel = nil
        await activeJamf?.invalidateToken()
        // nil the actors — releases their in-memory token cache but preserves Keychain entries
        activeABM  = nil
        activeJamf = nil
        isRunning = false
    }




}

// MARK: - Merge

// Free function — called from Task.detached so no actor context needed
private func mergeDevicesOffActor(
        abm:      [RawABMDevice],
        jamf:     [RawJamfComputer],
        mobile:   [RawJamfMobileDevice],
        existing: [Device]
    ) -> (devices: [SyncDevice], clearedExternally: Int) {

        let existingBySerial: [String: Device] = Dictionary(
            existing.map { ($0.serialNumber, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        var result: [String: SyncDevice] = [:]
        var clearedExternallyCount = 0
        let now = _iso8601.string(from: Date())

        // Always pre-populate result from existing CoreData records.
        //
        // This handles TWO scenarios:
        //   1. AxM cache fresh (abm empty): Jamf merge must find existing AxM records by serial
        //      or every AxM device gets rebuilt as jamfOnly, wiping model/coverage/deviceClass.
        //   2. Jamf cache fresh (jamf+mobile empty) but abm fresh: existing jamfOnly devices
        //      are not visited by either loop and silently disappear from the output.
        //      Example: user runs Jamf-first (Run 1), then adds AxM credentials and runs again
        //      (Run 2). On Run 2 Jamf cache is fresh so rawJamf=[], the abm loop creates axmOnly
        //      records, jamf loop does nothing. Without pre-population all Run-1 jamfOnly devices
        //      vanish, "In Both" shows 0 and Step 4 has no targets.
        //
        // Pre-populating is safe: both the abm loop and jamf loop overwrite their respective
        // fields on top of whatever is in result[], so no stale data leaks through.
        for d in existing {
                result[d.serialNumber] = SyncDevice(
                    serialNumber:         d.serialNumber,
                    deviceSource:         d.deviceSource,
                    axmDeviceId:          d.axmDeviceId,
                    axmDeviceStatus:      d.axmDeviceStatus,
                    axmDeviceFetchedAt:   d.axmDeviceFetchedAt,
                    axmPurchaseSource:    d.axmPurchaseSource,
                    axmModel:             d.axmModel,
                    axmDeviceModel:       d.axmDeviceModel,
                    axmDeviceClass:       d.axmDeviceClass,
                    axmProductFamily:     d.axmProductFamily,
                    axmCoverageStatus:    d.axmCoverageStatus,
                    axmCoverageEndDate:   d.axmCoverageEndDate,
                    axmCoverageFetchedAt: d.axmCoverageFetchedAt,
                    axmAgreementNumber:   d.axmAgreementNumber,
                    wbStatus:             d.wbStatus,
                    wbPushedAt:           d.wbPushedAt,
                    wbNote:               d.wbNote,
                    axmRawJson:           d.axmRawJson,
                    axmCoverageRawJson:   d.axmCoverageRawJson,
                    jamfId:               d.jamfId,
                    jamfName:             d.jamfName,
                    jamfManaged:          d.jamfManaged,
                    jamfModel:            d.jamfModel,
                    jamfModelIdentifier:  d.jamfModelIdentifier,
                    jamfMacAddress:       d.jamfMacAddress,
                    jamfReportDate:       d.jamfReportDate,
                    jamfLastContact:      d.jamfLastContact,
                    jamfLastEnrolled:     d.jamfLastEnrolled,
                    jamfWarrantyDate:     d.jamfWarrantyDate,
                    jamfVendor:           d.jamfVendor,
                    jamfAppleCareId:      d.jamfAppleCareId,
                    jamfOsVersion:        d.jamfOsVersion,
                    jamfFileVaultStatus:  d.jamfFileVaultStatus,
                    jamfUsername:         d.jamfUsername,
                    jamfDeviceType:       d.jamfDeviceType
                )
            }



        for d in abm {
            let ex = existingBySerial[d.serialNumber]
            // Derive Jamf endpoint type from productFamily ("Mac" → computer, else mobile).
            // Set here so AxM-only devices already have the correct routing before any Jamf merge.
            let axmDerivedDeviceType: String? = {
                guard let fam = d.productFamily ?? ex?.axmProductFamily else { return ex?.jamfDeviceType }
                return fam.caseInsensitiveCompare("Mac") == .orderedSame ? "computer" : "mobile"
            }()
            // If the existing record already has a Jamf ID (device was jamfOnly from a
            // Jamf-first run), mark it as .both immediately — the jamf loop won't visit
            // it again because rawJamf is empty (Jamf cache fresh).
            // Check BOTH existingBySerial (from CoreData load) AND the pre-populated
            // result entry — they should be identical, but we're defensive here since
            // this is the exact line that determines "In Both" vs "AxM Only".
            let prePopulatedJamfId = result[d.serialNumber]?.jamfId
            let resolvedJamfId     = ex?.jamfId ?? prePopulatedJamfId
            let abmDerivedSource: DeviceSource = (resolvedJamfId != nil) ? .both : .axmOnly

            result[d.serialNumber] = SyncDevice(
                serialNumber:         d.serialNumber,
                deviceSource:         abmDerivedSource,
                axmDeviceId:          d.deviceId,
                axmDeviceStatus:      d.deviceStatus,
                axmDeviceFetchedAt:   now,
                axmPurchaseSource:    d.purchaseSource   ?? ex?.axmPurchaseSource,
                axmPurchaseSourceId:  d.purchaseSourceId ?? ex?.axmPurchaseSourceId,
                axmOrderNumber:       d.orderNumber      ?? ex?.axmOrderNumber,
                axmOrderDate:         d.orderDate        ?? ex?.axmOrderDate,
                axmModel:             d.productDescription ?? ex?.axmModel,
                axmDeviceModel:       d.deviceModel ?? ex?.axmDeviceModel,
                axmDeviceClass:       d.deviceClass ?? ex?.axmDeviceClass,
                axmProductFamily:     d.productFamily ?? ex?.axmProductFamily,
                axmCoverageStatus:    ex?.axmCoverageStatus,
                axmCoverageEndDate:   ex?.axmCoverageEndDate,
                axmCoverageFetchedAt: ex?.axmCoverageFetchedAt,
                axmAgreementNumber:   ex?.axmAgreementNumber,
                // wbStatus rules for the ABM loop:
                //   axmOnly  → nil (no Jamf record to PATCH; avoids false "Pending" in dashboard)
                //   .both, genuinely new match (was jamfOnly before) → .pending (first-time write)
                //   .both, previously .synced → keep .synced (nothing new to write)
                //   .both, previously .failed → reset to .pending (retry on next sync — Fix #3)
                //   .both, previously .pending → keep .pending (hasn't been written yet)
                //   .both, previously nil (e.g. first ABM run after a Jamf-only cache) → .pending
                // This prevents Force Refresh Devices from re-queuing already-synced devices.
                wbStatus: {
                    guard abmDerivedSource == .both else { return nil }
                    let wasJamfOnly = ex?.deviceSource == .jamfOnly
                    let priorStatus = ex?.wbStatus
                    if wasJamfOnly || priorStatus == nil { return .pending }   // new match
                    if priorStatus == .synced             { return .synced  }   // already written — preserve
                    if priorStatus == .failed             { return .pending }   // retry failed devices
                    return priorStatus                                           // .pending/.skipped — keep
                }(),
                wbPushedAt:           ex?.wbPushedAt,
                wbNote:               ex?.wbNote,
                axmRawJson:           d.rawJson ?? ex?.axmRawJson,         // fresh JSON wins; fall back to cached
                axmCoverageRawJson:   ex?.axmCoverageRawJson,              // coverage JSON preserved from cache
                jamfId:               resolvedJamfId,   // use whichever source has the jamfId
                jamfName:             ex?.jamfName,
                jamfManaged:          ex?.jamfManaged,
                jamfModel:            ex?.jamfModel,
                jamfModelIdentifier:  ex?.jamfModelIdentifier,
                jamfMacAddress:       ex?.jamfMacAddress,
                jamfReportDate:       ex?.jamfReportDate,
                jamfLastContact:      ex?.jamfLastContact,
                jamfLastEnrolled:     ex?.jamfLastEnrolled,
                jamfWarrantyDate:     ex?.jamfWarrantyDate,
                jamfVendor:           ex?.jamfVendor,
                jamfAppleCareId:      ex?.jamfAppleCareId,
                jamfOsVersion:        ex?.jamfOsVersion,
                jamfFileVaultStatus:  ex?.jamfFileVaultStatus,
                jamfUsername:         ex?.jamfUsername,
                jamfDeviceType:       axmDerivedDeviceType
            )
        }

        for c in jamf {
            let managedStr = c.managed ? "True" : "False"
            // Only mark .both if result[] already has an ABM record for this serial
            // (axmDeviceId is set). Pre-populated jamfOnly records also live in result[]
            // but have no ABM data — they must fall through to the else branch and stay jamfOnly.
            if var sd = result[c.serialNumber], sd.axmDeviceId != nil {
                sd.deviceSource        = .both
                sd.jamfId              = c.jamfId
                sd.jamfName            = c.name
                sd.jamfManaged         = managedStr
                sd.jamfModel           = c.model
                sd.jamfModelIdentifier = c.modelIdentifier
                sd.jamfMacAddress      = c.macAddress
                sd.jamfReportDate      = c.reportDate
                sd.jamfLastContact     = c.lastContactTime
                sd.jamfLastEnrolled    = c.enrolledDate
                sd.jamfWarrantyDate    = c.warrantyDate
                sd.jamfVendor          = c.vendor
                sd.jamfAppleCareId     = c.appleCareId
                sd.jamfOsVersion       = c.osVersion
                sd.jamfFileVaultStatus = c.fileVault2Status
                sd.jamfUsername        = c.username
                // Device came from computers-inventory → definitively a computer.
                // axmProductFamily from ABM takes precedence for isMobile logic,
                // but jamfDeviceType records where in Jamf this device was found.
                sd.jamfDeviceType      = "computer"
                // Reset to .pending on new Jamf match (device gains a jamfId it can now be written to)
                // or if coverage data changed since last successful sync.
                // Fix #5: preserve .failed/.skipped status when no new data has arrived —
                // avoids endlessly re-queuing devices that genuinely can't be written (e.g. 404).
                let isNewJamfMatch = existingBySerial[c.serialNumber]?.deviceSource == .axmOnly
                    || existingBySerial[c.serialNumber] == nil
                let hasCoverageData = sd.axmCoverageStatus != nil
                let coverageChanged = sd.axmCoverageEndDate != existingBySerial[c.serialNumber]?.axmCoverageEndDate
                    || sd.axmAgreementNumber != existingBySerial[c.serialNumber]?.axmAgreementNumber
                // Detect external changes: last status was .synced but Jamf now reports
                // a blank or mismatched value for any field we write — re-queue to restore.
                // Covers: warrantyDate cleared, vendor changed, poNumber/poDate cleared.
                let wasWritten = existingBySerial[c.serialNumber]?.wbStatus == .synced
                let ex_c = existingBySerial[c.serialNumber]
                let expectedVendor: String? = {
                    guard let src = sd.axmPurchaseSource, !src.isEmpty else { return nil }
                    if let sid = sd.axmPurchaseSourceId, !sid.isEmpty { return "\(src) (\(sid))" }
                    return src
                }()
                let jamfDateCleared = wasWritten && hasCoverageData
                    && sd.axmCoverageEndDate != nil
                    && ((c.warrantyDate == nil || c.warrantyDate != sd.axmCoverageEndDate)
                     || (expectedVendor != nil && (c.vendor == nil || c.vendor != expectedVendor))
                     || (sd.axmOrderNumber != nil && (c.poNumber == nil || c.poNumber != sd.axmOrderNumber))
                     || (sd.axmOrderDate   != nil && (c.poDate   == nil || c.poDate   != sd.axmOrderDate)))
                if isNewJamfMatch {
                    // Always queue on first Jamf match regardless of prior status
                    sd.wbStatus = .pending
                } else if hasCoverageData && coverageChanged {
                    // Coverage data changed — re-queue so updated values get written
                    sd.wbStatus = .pending
                } else if !hasCoverageData && existingBySerial[c.serialNumber]?.wbStatus != .synced {
                    // Still no coverage — stay pending so Step 3 fills it, then next run writes.
                    // Exception: if already .synced (vendor-only write happened), don't regress.
                    sd.wbStatus = .pending
                } else if jamfDateCleared {
                    // Purchasing info was cleared in Jamf console — re-queue so we restore it
                    sd.wbStatus = .pending
                    clearedExternallyCount += 1
                } else if existingBySerial[c.serialNumber]?.wbStatus == .failed {
                    // Retry devices that failed in a previous run — Fix #3
                    sd.wbStatus = .pending
                }
                // else: keep existing .synced / .skipped — nothing new to write
                result[c.serialNumber] = sd
            } else {
                let ex = existingBySerial[c.serialNumber]
                result[c.serialNumber] = SyncDevice(
                    serialNumber:         c.serialNumber,
                    deviceSource:         .jamfOnly,
                    axmDeviceId:          nil,
                    axmDeviceStatus:      nil,
                    axmDeviceFetchedAt:   nil,
                    axmPurchaseSource:    nil,
                    axmPurchaseSourceId:  nil,
                    axmOrderNumber:       nil,
                    axmOrderDate:         nil,
                    axmModel:             nil,
                    axmDeviceModel:       nil,
                    axmDeviceClass:       nil,
                    axmProductFamily:     nil,             // Jamf-only — no ABM data
                    axmCoverageStatus:    ex?.axmCoverageStatus,
                    axmCoverageEndDate:   ex?.axmCoverageEndDate,
                    axmCoverageFetchedAt: ex?.axmCoverageFetchedAt,
                    axmAgreementNumber:   ex?.axmAgreementNumber,
                    wbStatus:             ex?.wbStatus,
                    wbPushedAt:           ex?.wbPushedAt,
                    wbNote:               ex?.wbNote,
                    axmRawJson:           nil,             // Jamf-only — no Apple org data
                    axmCoverageRawJson:   nil,             // Jamf-only — no coverage data
                    jamfId:               c.jamfId,
                    jamfName:             c.name,
                    jamfManaged:          managedStr,
                    jamfModel:            c.model,
                    jamfModelIdentifier:  c.modelIdentifier,
                    jamfMacAddress:       c.macAddress,
                    jamfReportDate:       c.reportDate,
                    jamfLastContact:      c.lastContactTime,
                    jamfLastEnrolled:     c.enrolledDate,
                    jamfWarrantyDate:     c.warrantyDate,
                    jamfVendor:           c.vendor,
                    jamfAppleCareId:      c.appleCareId,
                    jamfOsVersion:        c.osVersion,
                    jamfFileVaultStatus:  c.fileVault2Status,
                    jamfUsername:         c.username,
                    jamfDeviceType:       "computer"
                )
            }
        }

        // ── Mobile devices from Jamf ─────────────────────────────────────
        // Processed exactly like computers: merge into existing AxM records by serial
        // or create new jamfOnly records. Device type stored as "mobile" so PATCH
        // routing in Step 4 sends requests to /api/v2/mobile-devices/{id} instead.
        for m in mobile {
            let managedStr = m.managed ? "True" : "False"
            if var sd = result[m.serialNumber], sd.axmDeviceId != nil {
                // Device already in AxM — upgrade to .both
                sd.deviceSource        = .both
                sd.jamfId              = m.jamfId
                sd.jamfName            = m.name
                sd.jamfManaged         = managedStr
                sd.jamfModel           = m.model
                sd.jamfModelIdentifier = m.modelIdentifier
                sd.jamfMacAddress      = m.wifiMacAddress
                sd.jamfReportDate      = m.lastInventoryUpdate
                sd.jamfLastContact     = m.lastInventoryUpdate
                sd.jamfLastEnrolled    = m.lastEnrolledDate
                sd.jamfWarrantyDate    = m.warrantyDate
                sd.jamfVendor          = m.vendor
                sd.jamfAppleCareId     = m.appleCareId
                sd.jamfOsVersion       = m.osVersion
                sd.jamfFileVaultStatus = nil    // not applicable for mobile
                sd.jamfUsername        = m.username
                sd.jamfDeviceType      = "mobile"

                let isNewJamfMatch = existingBySerial[m.serialNumber]?.deviceSource == .axmOnly
                    || existingBySerial[m.serialNumber] == nil
                let hasCoverageData = sd.axmCoverageStatus != nil
                let coverageChanged = sd.axmCoverageEndDate != existingBySerial[m.serialNumber]?.axmCoverageEndDate
                    || sd.axmAgreementNumber != existingBySerial[m.serialNumber]?.axmAgreementNumber
                // Detect external changes: last status was .synced but Jamf now reports
                // a blank or mismatched value for any field we write — re-queue to restore.
                // Covers: warrantyDate cleared, vendor changed, poNumber/poDate cleared.
                let wasWritten = existingBySerial[m.serialNumber]?.wbStatus == .synced
                let ex_m = existingBySerial[m.serialNumber]
                let expectedVendorMob: String? = {
                    guard let src = sd.axmPurchaseSource, !src.isEmpty else { return nil }
                    if let sid = sd.axmPurchaseSourceId, !sid.isEmpty { return "\(src) (\(sid))" }
                    return src
                }()
                let jamfDateCleared = wasWritten && hasCoverageData
                    && sd.axmCoverageEndDate != nil
                    && ((m.warrantyDate == nil || m.warrantyDate != sd.axmCoverageEndDate)
                     || (expectedVendorMob != nil && (m.vendor == nil || m.vendor != expectedVendorMob))
                     || (sd.axmOrderNumber != nil && (m.poNumber == nil || m.poNumber != sd.axmOrderNumber))
                     || (sd.axmOrderDate   != nil && (m.poDate   == nil || m.poDate   != sd.axmOrderDate)))
                if isNewJamfMatch                          { sd.wbStatus = .pending }
                else if hasCoverageData && coverageChanged { sd.wbStatus = .pending }
                else if !hasCoverageData && existingBySerial[m.serialNumber]?.wbStatus != .synced {
                    sd.wbStatus = .pending   // no coverage yet — keep pending; don't clobber .synced
                } else if jamfDateCleared {
                    sd.wbStatus = .pending
                    clearedExternallyCount += 1
                } else if existingBySerial[m.serialNumber]?.wbStatus == .failed {
                    sd.wbStatus = .pending   // retry failed devices — Fix #3
                }
                // else: keep existing .synced / .skipped — nothing new to write
                result[m.serialNumber] = sd
            } else {
                let ex = existingBySerial[m.serialNumber]
                result[m.serialNumber] = SyncDevice(
                    serialNumber:         m.serialNumber,
                    deviceSource:         .jamfOnly,
                    axmDeviceId:          nil,
                    axmDeviceStatus:      nil,
                    axmDeviceFetchedAt:   nil,
                    axmPurchaseSource:    nil,
                    axmPurchaseSourceId:  nil,
                    axmOrderNumber:       nil,
                    axmOrderDate:         nil,
                    axmModel:             nil,
                    axmDeviceModel:       nil,
                    axmDeviceClass:       nil,
                    axmProductFamily:     nil,             // Jamf-only — no ABM data
                    axmCoverageStatus:    ex?.axmCoverageStatus,
                    axmCoverageEndDate:   ex?.axmCoverageEndDate,
                    axmCoverageFetchedAt: ex?.axmCoverageFetchedAt,
                    axmAgreementNumber:   ex?.axmAgreementNumber,
                    wbStatus:             ex?.wbStatus,
                    wbPushedAt:           ex?.wbPushedAt,
                    wbNote:               ex?.wbNote,
                    axmRawJson:           nil,
                    axmCoverageRawJson:   nil,
                    jamfId:               m.jamfId,
                    jamfName:             m.name,
                    jamfManaged:          managedStr,
                    jamfModel:            m.model,
                    jamfModelIdentifier:  m.modelIdentifier,
                    jamfMacAddress:       m.wifiMacAddress,
                    jamfReportDate:       m.lastInventoryUpdate,
                    jamfLastContact:      m.lastInventoryUpdate,
                    jamfLastEnrolled:     m.lastEnrolledDate,
                    jamfWarrantyDate:     m.warrantyDate,
                    jamfVendor:           m.vendor,
                    jamfAppleCareId:      m.appleCareId,
                    jamfOsVersion:        m.osVersion,
                    jamfFileVaultStatus:  nil,
                    jamfUsername:         m.username,
                    jamfDeviceType:       "mobile"
                )
            }
        }

        return (Array(result.values).sorted { $0.serialNumber < $1.serialNumber }, clearedExternallyCount)
    }

// MARK: - SyncError

enum SyncError: LocalizedError {
    case missingCredentials(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let m): return m
        case .networkError(let m):       return "Network error: \(m)"
        }
    }
}

// MARK: - SyncDevice (mutable intermediate — never escapes this file)

private struct SyncDevice {
    var serialNumber:         String
    var deviceSource:         DeviceSource
    var axmDeviceId:          String?
    var axmDeviceStatus:      String?
    var axmDeviceFetchedAt:   String?
    var axmPurchaseSource:    String?
    var axmPurchaseSourceId:  String?
    var axmOrderNumber:       String?
    var axmOrderDate:         String?
    var axmModel:             String?
    var axmDeviceModel:       String?
    var axmDeviceClass:       String?
    var axmProductFamily:     String?    // "Mac" | "iPad" | "iPhone" | "AppleTV"
    var axmCoverageStatus:    String?
    var axmCoverageEndDate:   String?
    var axmCoverageFetchedAt: String?
    var axmAgreementNumber:   String?
    var wbStatus:             WBStatus?
    var wbPushedAt:           String?   // Fix #1: carry push timestamp through merge
    var wbNote:               String?   // Fix #1: carry note through merge
    var axmRawJson:           Data?     // raw org device JSON from Apple API
    var axmCoverageRawJson:   Data?     // raw coverage JSON from Apple API
    var jamfId:               String?
    var jamfName:             String?
    var jamfManaged:          String?
    var jamfModel:            String?
    var jamfModelIdentifier:  String?
    var jamfMacAddress:       String?
    var jamfReportDate:       String?
    var jamfLastContact:      String?
    var jamfLastEnrolled:     String?
    var jamfWarrantyDate:     String?
    var jamfVendor:           String?
    var jamfAppleCareId:      String?
    var jamfOsVersion:        String?
    var jamfFileVaultStatus:  String?
    var jamfUsername:         String?
    var jamfDeviceType:       String?    // "computer" | "mobile"

    func toDevice() -> Device {
        Device(
            serialNumber:         serialNumber,
            deviceSource:         deviceSource,
            axmDeviceId:          axmDeviceId,
            axmDeviceStatus:      axmDeviceStatus,
            axmDeviceFetchedAt:   axmDeviceFetchedAt,
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
            axmCoverageFetchedAt: axmCoverageFetchedAt,
            axmAgreementNumber:   axmAgreementNumber,
            wbStatus:             wbStatus,
            wbPushedAt:           wbPushedAt,
            wbNote:               wbNote,
            jamfId:               jamfId,
            jamfName:             jamfName,
            jamfManaged:          jamfManaged,
            jamfModel:            jamfModel,
            jamfModelIdentifier:  jamfModelIdentifier,
            jamfMacAddress:       jamfMacAddress,
            jamfReportDate:       jamfReportDate,
            jamfLastContact:      jamfLastContact,
            jamfLastEnrolled:     jamfLastEnrolled,
            jamfWarrantyDate:     jamfWarrantyDate,
            jamfVendor:           jamfVendor,
            jamfAppleCareId:      jamfAppleCareId,
            jamfOsVersion:        jamfOsVersion,
            jamfFileVaultStatus:  jamfFileVaultStatus,
            jamfUsername:         jamfUsername,
            jamfDeviceType:       jamfDeviceType,
            axmRawJson:           axmRawJson,
            axmCoverageRawJson:   axmCoverageRawJson
        )
    }
}

// DeviceCoverage is defined in ABMService.swift

// MARK: - Shared formatters (avoid repeated allocations at 60k scale)
private let _iso8601 = ISO8601DateFormatter()

// MARK: - Device helpers

extension Device {
    // P8: Uses Device.copying() — only overrides the fields that change.
    // Previously copied all 35 fields manually; fragile when new fields are added.
    func applyingCoverage(_ coverage: DeviceCoverage, forceWBPending: Bool = false) -> Device {
        let newWBStatus: WBStatus? = {
            guard deviceSource != .axmOnly else { return wbStatus }
            // forceWBPending = true when Force Refresh Coverage is ON — always re-patch Jamf
            // even if coverage data hasn't changed since last fetch.
            if forceWBPending { return .pending }
            // .noCoverage IS valid data — the Apple API confirmed no AppleCare plan exists.
            // We still want to write this status to Jamf (clears any stale warranty date).
            // Previously this returned wbStatus unchanged for .noCoverage, meaning devices
            // with no plan kept wbStatus=nil and were silently skipped by Step 4.
            let endDateChanged   = coverage.endDate   != axmCoverageEndDate
            let agreementChanged = coverage.agreement != axmAgreementNumber
            let statusChanged    = coverage.status.rawValue != axmCoverageStatus
            if endDateChanged || agreementChanged || statusChanged { return .pending }
            return wbStatus == .synced ? .synced : .pending
        }()
        // Wrap each argument in Optional() so Swift promotes T? → T?? = .some(value).
        // The copying() sentinel pattern requires T?? where nil = "keep self's value"
        // and .some(x) = "override with x" (x itself may be nil for Optional fields).
        return copying(
            axmCoverageStatus:    Optional(coverage.status.rawValue),
            axmCoverageEndDate:   Optional(coverage.endDate),
            axmCoverageFetchedAt: Optional(_iso8601.string(from: Date())),
            axmAgreementNumber:   Optional(coverage.agreement),
            wbStatus:             Optional(newWBStatus),
            jamfWarrantyDate:     Optional(coverage.endDate ?? jamfWarrantyDate),
            jamfAppleCareId:      Optional(coverage.agreement ?? jamfAppleCareId),
            axmCoverageRawJson:   Optional(coverage.rawJson ?? axmCoverageRawJson)
        )
    }

    // P8: Uses Device.copying() — only overrides the 3 WB-related fields.
    func withWBStatus(_ status: WBStatus, note: String?) -> Device {
        copying(
            wbStatus:   Optional(status),
            wbPushedAt: Optional(status == .synced ? _iso8601.string(from: Date()) : wbPushedAt),
            wbNote:     Optional(note)
        )
    }
}
