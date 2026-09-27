// EnvironmentStore.swift
// Environment model and store for v2.0 multi-environment support.
//
// Each Environment is an isolated configuration:
//   - Its own ABM/ASM credentials in Keychain (keyed by env UUID)
//   - Its own Jamf Pro credentials in Keychain (keyed by env UUID)
//   - Its own CoreData SQLite store (named {uuid}.sqlite)
//   - Its own UserDefaults namespace (prefix env.{uuid}.)
//   - Its own log file ({uuid}.log)
//
// The list of environments (names, IDs, scope) is stored in UserDefaults.
// Credentials and data never leave their environment — deletion is atomic.

import Foundation
import SwiftUI
import Darwin
import notify
import os

// MARK: - Environment model

struct AppEnvironment: Identifiable, Codable, Equatable {
  let id:        UUID
  var name:      String
  var scope:     AxMScope
  var createdAt: Date
  var lastSyncedAt:     Date?
  var lastSyncStatus:   EnvironmentSyncStatus

  init(id: UUID = UUID(), name: String, scope: AxMScope) {
    self.id              = id
    self.name            = name
    self.scope           = scope
    self.createdAt       = Date()
    self.lastSyncedAt    = nil
    self.lastSyncStatus  = .never
  }

  // MARK: - JSON coding
  //
  // The encoder MUST keep JSONEncoder's default Date strategy (.deferredToDate —
  // a bare Double, timeIntervalSinceReferenceDate). v2.5 and earlier decode
  // v2.environments with a plain JSONDecoder(); an ISO8601 string makes the whole
  // list fail to decode there, and v2.5 then treats it as a first launch and runs
  // the v1 migration over real data. Shipped once in a v3.0 build and wiped a
  // user's environment list on downgrade — see ARCHITECTURE.md. The decoder still
  // accepts ISO8601 strings so any list that build wrote reads back fine, and
  // save() rewrites it in the old format on the next change.
  // Shared by every encode/decode of [AppEnvironment] — EnvironmentStore (list
  // persistence, headless status merge, external-run diffing) and DiagnosticsExporter.
  nonisolated(unsafe) private static let isoFmt: ISO8601DateFormatter = ISO8601DateFormatter()

  static var jsonEncoder: JSONEncoder {
    JSONEncoder()
  }

  static var jsonDecoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let str = try? container.decode(String.self) {
        guard let date = isoFmt.date(from: str) else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return date
      }
      // Old format: a bare Double is timeIntervalSinceReferenceDate — .deferredToDate's
      // encoding, what every pre-existing v2.environments entry was written with.
      if let seconds = try? container.decode(Double.self) {
        return Date(timeIntervalSinceReferenceDate: seconds)
      }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date format")
    }
    return d
  }
}

enum EnvironmentSyncStatus: String, Codable {
  case never     // never synced
  case success   // last sync succeeded cleanly
  case partial   // S7: last sync landed real data but was not a complete/fresh run
  case error     // last sync failed
  case cancelled // S7: last sync stopped by the user
  case running   // sync in progress

  // Fix: this used to redeclare its own icon/color mapping instead of routing
  // through SyncOutcome's — the two had already drifted (.error showed
  // xmark.circle.fill on the Sync tab via SyncOutcome.failed.symbol, but
  // exclamationmark.circle.fill here in the sidebar, for the identical failed
  // run). ARCHITECTURE.md's S7 section says the sidebar renders through "the
  // same helper" as the Sync tab banner precisely so that can't happen. .never
  // and .running have no SyncOutcome equivalent (a run in progress or one that
  // hasn't happened yet isn't a terminal outcome) and keep their own values;
  // every terminal case now delegates to SyncOutcome so they can't diverge again.
  var icon: String {
    switch self {
    case .never:     return "circle"
    case .running:   return "arrow.triangle.2.circlepath.circle.fill"
    case .success:   return SyncOutcome.success.symbol
    case .partial:   return SyncOutcome.partial.symbol
    case .error:     return SyncOutcome.failed.symbol
    case .cancelled: return SyncOutcome.cancelled.symbol
    }
  }

  var color: Color {
    switch self {
    case .never:     return .secondary
    case .running:   return .accentColor
    case .success:   return SyncOutcome.success.tint
    case .partial:   return SyncOutcome.partial.tint
    case .error:     return SyncOutcome.failed.tint
    case .cancelled: return SyncOutcome.cancelled.tint
    }
  }
}

// MARK: - Migration errors

/// S4: a typed failure from the v1→v2 migration. Every case means the migration
/// stopped before its commit point with the v1 credentials/store left intact.
/// `errorDescription` names the failing step without ever including a secret value.
enum MigrationError: LocalizedError, Sendable {
  case keychainCopyFailed(String)     // env-namespaced key that failed to write
  case keychainVerifyFailed(String)   // env-namespaced key that did not read back
  case storeCopyFailed(String)        // which file / stage failed
  case storeVerifyFailed(String)      // why the staged store failed verification

  var errorDescription: String? {
    switch self {
    case .keychainCopyFailed(let k):
      return "A saved credential (\(k)) could not be copied to the new format. Your existing credentials are unchanged."
    case .keychainVerifyFailed(let k):
      return "A copied credential (\(k)) did not read back correctly. Your existing credentials are unchanged."
    case .storeCopyFailed(let s):
      return "The device database could not be copied (\(s)). Your existing data is unchanged."
    case .storeVerifyFailed(let s):
      return "The copied device database failed verification (\(s)). Your existing data is unchanged."
    }
  }
}

// MARK: - EnvironmentStore

/// Manages the list of environments and the active AppStore + SyncEngine.
///
/// activeStore and activeSyncEngine are @Published so any view observing
/// EnvironmentStore will re-render when the active environment is switched.
/// The App scene passes these through as environmentObject so all child views
/// always see the services for the currently selected environment.
@MainActor
final class EnvironmentStore: ObservableObject {

  @Published private(set) var environments:        [AppEnvironment] = []
  @Published private(set) var activeEnvironmentId: UUID?

  /// The AppStore for the currently active environment.
  /// Initialised with an in-memory store as a safe placeholder —
  /// replaced immediately by buildServices() in init() or runMigration().
  @Published private(set) var activeStore:      AppStore   = AppStore(persistence: PersistenceController(inMemory: true))
  /// The SyncEngine for the currently active environment.
  @Published private(set) var activeSyncEngine: SyncEngine = SyncEngine()

  /// Registry of engines that are actively running, keyed by environment UUID.
  /// buildServices consults this before creating a new engine — if an engine is
  /// already running for the requested environment (because the user switched away
  /// and back), it is reused so the UI keeps observing live isRunning / progress.
  private var runningEngines: [UUID: SyncEngine] = [:]

  /// True while the one-time v1→v2 CoreData migration is running.
  @Published private(set) var isMigrating: Bool = false
  @Published private(set) var migrationStatus: String = ""
  /// Non-nil when the v1→v2 migration failed before its commit point. The v1
  /// credentials/store are still intact and the migration retries on next launch;
  /// this string is what the overlay shows the user.
  @Published private(set) var migrationError: String? = nil
  /// Set synchronously in buildServices — ContentView reads this before first render.
  @Published private(set) var initialTab: ContentView.Tab = .setup

  /// S7: terminal outcome of each environment's most recent run this session.
  /// Read by SyncScheduler to build an accurate scheduled-run completion summary.
  @Published private(set) var lastOutcomeByEnv: [UUID: SyncOutcome] = [:]

  /// S7: true once any per-environment Core Data store has reported a load failure.
  /// While set, the sync queue refuses to start — syncing against an unavailable
  /// store would fetch everything and persist nothing. Cleared only by relaunch.
  @Published private(set) var persistenceLoadFailed: Bool = false
  @Published private(set) var persistenceLoadFailureMessage: String? = nil

  /// A `--silent` run that failed before it even started (no environments
  /// configured, or `--env` matched none) — see HeadlessStartupFailure. Consumed
  /// once from UserDefaults in init() (GUI only), so it surfaces exactly once,
  /// on whichever launch happens to notice it, then is gone.
  @Published private(set) var headlessStartupFailure: (message: String, date: Date)?
  func dismissHeadlessStartupFailure() { headlessStartupFailure = nil }

  // MARK: - Sync Queue
  //
  // All syncs — whether triggered manually (Run Sync button) or via multi-sync —
  // go through a single serial queue. The runner switches the active environment
  // before each slot, so the existing Sync tab and log window show live progress
  // naturally. No background engines are ever created.
  //
  // Queue semantics:
  //   syncQueue[0]  = currently running (or about to run) environment
  //   syncQueue[1…] = pending slots in order
  //
  // Adding an ID that is already in the queue is a no-op — deduplication is
  // enforced by enqueue, so double-tapping Run Sync never starts parallel syncs.

  /// Ordered list of environment IDs waiting to sync. Non-empty iff a sync run
  /// is in progress or pending. Index 0 is always the currently-active slot.
  @Published private(set) var syncQueue: [UUID] = []
  private var syncQueueTask: Task<Void, Never>?

  var isSyncQueueRunning: Bool { !syncQueue.isEmpty }

  /// The engine that owns the currently-executing queue slot.
  /// May differ from activeSyncEngine when the user has switched environments
  /// while a sync is in progress.
  var currentSlotEngine: SyncEngine? {
    guard let id = syncQueue.first else { return nil }
    return runningEngines[id] ?? (activeSyncEngine.environmentId == id ? activeSyncEngine : nil)
  }

  var syncQueueProgress: String {
    guard syncQueue.count > 1 else { return "" }
    let name = environments.first(where: { $0.id == syncQueue.first })?.name ?? ""
    let suffix = name.isEmpty ? "" : " — \(name)"
    let done = max(0, (environments.count) - syncQueue.count)
    let total = done + syncQueue.count
    return "Syncing \(done + 1) of \(total)\(suffix)"
  }

  private let ud = UserDefaults.standard
  nonisolated private static let listKey = "v2.environments"
  private let listKey   = EnvironmentStore.listKey
  private let activeKey = "v2.activeEnvironmentId"

  /// Non-nil for a `--silent` run (HeadlessMode.swift). That process shares this
  /// UserDefaults domain with the GUI, so it must not write anything the GUI owns:
  /// the active-environment pointer and the environment list. It persists only
  /// terminal sync statuses, merged into the on-disk list (see updateSyncStatus).
  private let headless: HeadlessOptions?

  /// Environments whose run was declined because another process held their lock.
  private(set) var skippedForExternalSync: Set<UUID> = []

  /// Environments another process currently holds the sync lock for — GUI-display
  /// only (Sync/Setup gating, sidebar badge). Never consulted for the actual
  /// enforcement, which stays SyncEngine.run()'s own SyncLock.tryAcquire.
  @Published private(set) var externallyLockedEnvironments: Set<UUID> = []

  private var externalRunToken: Int32 = 0
  private var externalRunStartToken: Int32 = 0

  /// True when a v2 environment list exists — lets a headless run refuse to start
  /// instead of triggering the first-launch v1 migration from init().
  nonisolated static var hasPersistedEnvironments: Bool {
    guard let data = UserDefaults.standard.data(forKey: listKey),
          let list = try? AppEnvironment.jsonDecoder.decode([AppEnvironment].self, from: data) else { return false }
    return !list.isEmpty
  }

  var activeEnvironment: AppEnvironment? {
    guard let id = activeEnvironmentId else { return environments.first }
    return environments.first { $0.id == id }
  }

  init(headless: HeadlessOptions? = nil) {
    self.headless = headless
    if headless == nil {
      observeExternalRuns()
      headlessStartupFailure = HeadlessStartupFailure.consume()
    }
    NotificationCenter.default.addObserver(
      forName: .persistenceLoadFailed, object: nil, queue: .main) { [weak self] note in
        let msg = note.object as? String
        Task { @MainActor in
          self?.persistenceLoadFailed = true
          self?.persistenceLoadFailureMessage = msg
        }
      }
    load()
    if environments.isEmpty {
      // "No usable list" is not "first launch": an undecodable list or existing
      // environment stores mean real data, and the v1 migration would overwrite
      // both the list and the …0001 store. Refuse instead — see ARCHITECTURE.md.
      if let reason = Self.v1MigrationRefusal(listPresent: ud.object(forKey: listKey) != nil) {
        os_log(.error, "[EnvironmentStore] v1 migration refused — %{public}@", reason)
        migrationError = reason
        return
      }
      // First v2.0 launch — migration runs async; buildServices called at end of runMigration()
      migrateFromV1()
      return
    }
    // Ensure activeEnvironmentId points to a real environment
    if activeEnvironmentId == nil || !environments.contains(where: { $0.id == activeEnvironmentId }) {
      activeEnvironmentId = environments.first?.id
    }
    // Build services for the initial active environment
    if let env = activeEnvironment {
      buildServices(for: env)
    }
  }

  // MARK: - Service construction

  private func buildServices(for env: AppEnvironment) {
    // ── Scope self-heal ─────────────────────────────────────────────────────
    // AppEnvironment.scope (stored in UserDefaults) may disagree with the
    // scope that was actually used when credentials were saved — this happens
    // when an env was created as ABM but credentials were entered as ASM before
    // the fix that persists scope changes back to AppEnvironment.
    //
    // Strategy: the saved "axm.scope" Keychain key for this env is the ground
    // truth because it is written every time credentials are saved or the scope
    // button is tapped. If it disagrees with env.scope, correct the in-memory
    // env and persist the correction to UserDefaults before building services.
    var env = env
    // ── Three-source scope resolution ────────────────────────────────────────
    // When Keychain is cleared, axm.scope and clientId are gone but dataCachedScope
    // in UserDefaults survives. Use sources in priority order:
    //   1. Scoped clientId keys (axm.school.clientId / axm.business.clientId) — this is
    //      the actual current storage format (see KeychainService.saveAxMCredentialsForEnv),
    //      and directly observable ground truth: if real credentials exist under exactly
    //      one scope, that's the scope in use, full stop.
    //      PRIORITY FIX: this now runs BEFORE checking the axm.scope key. axm.scope is
    //      just a label pointing at which credentials to use — it can itself become
    //      wrong (that's exactly the bug this block used to have, and once "corrected"
    //      incorrectly, axm.scope gets persisted with the bad value, so trusting it
    //      first turns one bad inference into a permanent one). Real credential presence
    //      can't lie the same way, so it must outrank the label.
    //   2. axm.scope Keychain key — trusted only when scoped-key evidence is ambiguous
    //      (both or neither populated).
    //   3. Legacy unscoped clientId prefix (SCHOOLAPI* / BUSINESSAPI*) — pre-migration format
    //   4. dataCachedScope UserDefaults (survives Keychain wipe — written by SyncEngine)
    let savedScopeRaw          = KeychainService.loadForEnv(key: "axm.scope", envId: env.id) ?? ""
    let scopedSchoolClientId   = KeychainService.loadForEnv(key: "axm.school.clientId",   envId: env.id) ?? ""
    let scopedBusinessClientId = KeychainService.loadForEnv(key: "axm.business.clientId", envId: env.id) ?? ""
    let legacyClientIdRaw      = KeychainService.loadForEnv(key: "axm.clientId", envId: env.id) ?? ""
    let cachedPrefs   = AppPreferences(environmentId: env.id)
    let inferredScope: AxMScope? = {
      if !scopedSchoolClientId.isEmpty   && scopedBusinessClientId.isEmpty { return .school }
      if !scopedBusinessClientId.isEmpty && scopedSchoolClientId.isEmpty   { return .business }
      if let s = AxMScope(rawValue: savedScopeRaw) { return s }
      if legacyClientIdRaw.uppercased().hasPrefix("SCHOOLAPI")   { return .school }
      if legacyClientIdRaw.uppercased().hasPrefix("BUSINESSAPI") { return .business }
      // Fallback 4: scope of the data already in CoreData — written by SyncEngine at sync end
      if let s = AxMScope(rawValue: cachedPrefs.dataCachedScope) { return s }
      return nil
    }()
    if let correctedScope = inferredScope, correctedScope != env.scope {
      os_log(.default, "[EnvironmentStore] Scope mismatch for env %{public}@ — AppEnvironment=%{public}@ corrected to=%{public}@.", env.id.uuidString, env.scope.rawValue, correctedScope.rawValue)
      env.scope = correctedScope
      if let idx = environments.firstIndex(where: { $0.id == env.id }) {
        environments[idx].scope = correctedScope
        save()
      }
      let correctedRaw = correctedScope.rawValue
      if cachedPrefs.dataCachedScope != correctedRaw { cachedPrefs.dataCachedScope = correctedRaw }
      if cachedPrefs.activeScope     != correctedRaw { cachedPrefs.activeScope     = correctedRaw }
      // Persist the authoritative Keychain key too, so future launches resolve via
      // fallback 1 directly instead of re-inferring from scoped clientId keys every time.
      if savedScopeRaw != correctedRaw {
        _ = KeychainService.saveForEnv(correctedRaw, key: "axm.scope", envId: env.id)
      }
    }

    // ── Keychain key migration ───────────────────────────────────────────────
    // Migrate credentials from old scopeless keys (axm.clientId) to scoped keys
    // (axm.business.clientId / axm.school.clientId) if scoped keys are empty.
    // This runs once per environment and is a no-op thereafter.
    let s = env.scope == .school ? "school" : "business"
    let hasScoped = KeychainService.loadForEnv(key: "axm.\(s).clientId", envId: env.id)?.isEmpty == false
    if !hasScoped {
      if let clientId = KeychainService.loadForEnv(key: "axm.clientId", envId: env.id), !clientId.isEmpty {
        os_log(.default, "[EnvironmentStore] Migrating scopeless Keychain keys to axm.%{public}@.* for env %{public}@", s, env.id.uuidString)
        let keyId   = KeychainService.loadForEnv(key: "axm.keyId",             envId: env.id) ?? ""
        let privKey = KeychainService.loadForEnv(key: "axm.privateKeyContent", envId: env.id) ?? ""
        _ = KeychainService.saveForEnv(clientId, key: "axm.\(s).clientId",          envId: env.id)
        _ = KeychainService.saveForEnv(keyId,    key: "axm.\(s).keyId",             envId: env.id)
        if !privKey.isEmpty {
          _ = KeychainService.saveForEnv(privKey, key: "axm.\(s).privateKeyContent", envId: env.id)
        }
      }
    }

    // Reuse the already-loaded store for this environment when one is still
    // alive (e.g. a running sync's captured `store:` keeps its
    // PersistenceController retained even after the user switches away and
    // back). Building a second PersistenceController here would silently
    // overwrite the registry entry (PersistenceController.init registers
    // unconditionally) and orphan the instance the running sync is still
    // writing through — the UI would then show a second, inert store while
    // writes land somewhere it never reads from.
    let persistence  = PersistenceController.loadedStore(for: env.id) ?? PersistenceController(environmentId: env.id)
    let prefs        = AppPreferences(environmentId: env.id)
    let logService   = LogService.makeForEnvironment(id: env.id)
    activeStore      = AppStore(environment: env, persistence: persistence, prefs: prefs)

    // S2: when a Jamf URL/clientId change invalidates the cached serial→Jamf-ID
    // mapping, flag the next sync for a full Jamf re-fetch — forceFullJamfRefetch
    // is a one-shot consumed by SyncEngine.run(). Deliberately does NOT enqueue a
    // sync itself: saving new Jamf credentials in Setup used to silently kick off
    // a background sync the moment you clicked Save, with no explicit action from
    // the user — surprising, and indistinguishable in the UI from an unrelated
    // auto-trigger. The re-fetch now happens on whatever the user does next —
    // Test Auth, Run Sync, or a schedule/CLI run — not on its own.
    activeStore.onJamfRebindingDetected = { [weak store = activeStore] in
      guard let store else { return }
      store.prefs.forceFullJamfRefetch = true
    }

    // If an engine is already running for this environment — whether it is the
    // current activeSyncEngine or a previously-active engine the user switched
    // away from — reuse it. This preserves the live isRunning / progress state
    // that SwiftUI components observe, regardless of how many environment switches
    // happened while the sync was in progress.
    if let running = runningEngines[env.id] {
      activeSyncEngine     = running
      activeSyncEngine.log = logService
    } else {
      let engine = SyncEngine()
      engine.log           = logService
      engine.environmentId = env.id
      // writeBackEnabled defaults to true (SyncEngine's own default) — a --silent
      // run used to have its own read-only-unless---write mode here; removed so
      // --silent always matches what Run Sync does in the app.
      let skippedId = env.id
      engine.onSkippedExternalLock = { [weak self] in self?.skippedForExternalSync.insert(skippedId) }
      // Restore this environment's own Last Run Summary now that both
      // environmentId and its namespaced `prefs` exist — see SyncEngine's
      // restoreLastRun(from:) doc comment for why this can't happen in init().
      engine.restoreLastRun(from: prefs)
      let envId = env.id
      engine.onSyncStatusChange = { [weak self, weak engine] status, date in
        guard let self, let engine else { return }
        if status == .running {
          self.runningEngines[envId] = engine
        } else {
          self.runningEngines.removeValue(forKey: envId)
          // S7: record the terminal outcome so a scheduled run's summary reflects
          // what actually happened, not merely that the queue drained.
          switch status {
          case .success:   self.lastOutcomeByEnv[envId] = .success
          case .partial:   self.lastOutcomeByEnv[envId] = .partial
          case .cancelled: self.lastOutcomeByEnv[envId] = .cancelled
          case .error:     self.lastOutcomeByEnv[envId] = .failed
          case .never, .running: break
          }
        }
        self.updateSyncStatus(envId, status: status, date: date)
      }
      activeSyncEngine = engine
    }
    initialTab = activeStore.cacheIsPopulated ? .dashboard : .setup
  }

  // MARK: - CRUD

  func add(name: String, scope: AxMScope) -> AppEnvironment {
    // Append a numeric suffix if the name is already taken
    var finalName = name
    var counter   = 1
    while environments.contains(where: { $0.name == finalName }) {
      counter  += 1
      finalName = "\(name) (\(counter))"
    }
    let env = AppEnvironment(name: finalName, scope: scope)
    environments.append(env)
    save()
    return env
  }

  func rename(_ id: UUID, to name: String) {
    guard let idx = environments.firstIndex(where: { $0.id == id }) else { return }
    var finalName = name
    var counter   = 1
    while environments.contains(where: { $0.name == finalName && $0.id != id }) {
      counter  += 1
      finalName = "\(name) (\(counter))"
    }
    environments[idx].name = finalName
    save()
  }

  // MARK: - Deletion eligibility (S5)

  /// Why an environment can't be deleted right now, or nil if it can.
  enum DeletionBlockReason: Equatable {
    case lastEnvironment
    case running
    case queued
    case lockedExternally

    var userMessage: String {
      switch self {
      case .lastEnvironment:  return "The app needs at least one environment."
      case .running:          return "Can't delete — sync in progress."
      case .queued:           return "Can't delete — queued for scheduled sync."
      case .lockedExternally: return "Can't delete — a command-line sync is running for this environment."
      }
    }
  }

  enum EnvironmentDeletionError: LocalizedError {
    case blocked(DeletionBlockReason)
    case teardownFailed(String)

    var errorDescription: String? {
      switch self {
      case .blocked(let r):        return r.userMessage
      case .teardownFailed(let m): return "The environment could not be fully removed (\(m)). Nothing was deleted from the environment list — try again."
      }
    }
  }

  /// True while `id` has a live, running sync — checked against the same
  /// `runningEngines` map and active engine the queue runner resolves slots from.
  func isRunning(_ id: UUID) -> Bool {
    if let e = runningEngines[id], e.isRunning { return true }
    if activeSyncEngine.environmentId == id, activeSyncEngine.isRunning { return true }
    return false
  }

  /// True while `id` sits anywhere in the sync queue — index 0 (the active slot)
  /// included. `syncQueue` is the same array `startQueueRunner` dequeues from
  /// (S6), so this can't disagree with what the runner would execute.
  func isQueued(_ id: UUID) -> Bool { syncQueue.contains(id) }

  func deletionBlockReason(_ id: UUID) -> DeletionBlockReason? {
    if environments.count <= 1               { return .lastEnvironment }
    if isRunning(id)                          { return .running }
    if isQueued(id)                           { return .queued }
    if externallyLockedEnvironments.contains(id) { return .lockedExternally }
    return nil
  }

  /// Returns true if this environment can be deleted right now.
  func canDelete(_ id: UUID) -> Bool { deletionBlockReason(id) == nil }

  /// Update the scope of an environment — persists the change so buildServices
  /// always loads the correct scope on the next switch or relaunch.
  func updateScope(_ id: UUID, scope: AxMScope) {
    guard let idx = environments.firstIndex(where: { $0.id == id }) else { return }
    environments[idx].scope = scope
    save()
  }

  /// S5: quiesce every context that could still be writing to this environment,
  /// detach its Core Data coordinator and close its log file, THEN remove the
  /// on-disk data, and only after all of that succeeds drop the registry entry.
  /// Order matters — detach before delete, never delete before detach, or the
  /// coordinator keeps writing to an unlinked inode and the writes vanish.
  func delete(_ id: UUID) async throws {
    // Re-check at the point of deletion — state may have changed since the UI
    // last evaluated canDelete (a scheduled run could have enqueued it).
    if let reason = deletionBlockReason(id) {
      throw EnvironmentDeletionError.blocked(reason)
    }
    // deletionBlockReason's externallyLockedEnvironments is a cache, refreshed on
    // activation/notification — not guaranteed current to the instant. A fresh,
    // uncached lock check right before the destructive file removal below is
    // cheap and closes that gap for the one check that actually matters.
    if SyncLock.isHeldElsewhere(id) {
      throw EnvironmentDeletionError.blocked(.lockedExternally)
    }
    guard environments.contains(where: { $0.id == id }) else { return }

    let wasActive = (activeEnvironmentId == id)

    // 1. Quiesce any in-flight work. deletionBlockReason already rejected a
    //    *running* sync, but a run that finished microseconds ago may still be
    //    unwinding — await it cleanly (bounded) rather than racing teardown.
    if let engine = runningEngines[id] { await engine.cancelAndWait() }
    if wasActive, activeSyncEngine.environmentId == id { await activeSyncEngine.cancelAndWait() }

    // 2. Capture the live store/log for this env, then switch the active pointers
    //    away FIRST so no view or engine keeps using the store we're about to
    //    detach.
    let storeToDetach = wasActive ? activeStore.persistence
                                  : PersistenceController.loadedStore(for: id)
    let logToClose    = LogService.envInstance(for: id)

    if wasActive {
      activeEnvironmentId = environments.first(where: { $0.id != id })?.id
      if let id = activeEnvironmentId { ud.set(id.uuidString, forKey: activeKey) }
      if let env = activeEnvironment { buildServices(for: env) }
    }

    // 3. Drain pending persistence, close the log handle, detach the coordinator —
    //    all BEFORE any file removal.
    if let storeToDetach {
      await storeToDetach.viewContext.perform { }   // let queued saves land
    }
    logToClose?.closeForDeletion()
    storeToDetach?.detach()

    // 4. Remove Keychain items, preferences, log files and the SQLite store.
    //    A failure to remove the store files is fatal to the operation — we must
    //    not leave a registry entry pointing at half-deleted data.
    do {
      try wipeEnvironmentData(id: id)
    } catch {
      throw EnvironmentDeletionError.teardownFailed(error.localizedDescription)
    }

    // 5. Only now drop the registry metadata.
    runningEngines.removeValue(forKey: id)
    lastOutcomeByEnv.removeValue(forKey: id)
    environments.removeAll { $0.id == id }
    save()
  }

  func setActive(_ id: UUID) {
    guard environments.contains(where: { $0.id == id }) else { return }
    // Switching the active view is always allowed — the running engine keeps its
    // own Task and service references and continues uninterrupted. buildServices
    // only replaces the @Published pointers; it does not touch the running engine.
    // Do NOT call activeSyncEngine.stop() here — that would cancel a live sync.
    activeEnvironmentId = id
    if headless == nil { ud.set(id.uuidString, forKey: activeKey) }
    if let env = activeEnvironment {
      buildServices(for: env)
    }
  }

  // MARK: - Sync Queue

  /// Adds the given environment to the sync queue if it isn't already present.
  /// If the runner is idle this starts it immediately.
  /// Called by both Run Sync (single env) and the multi-sync popover.
  func enqueue(_ id: UUID) {
    guard !persistenceLoadFailed else {
      os_log(.error, "[EnvironmentStore] enqueue refused — device database unavailable; relaunch required.")
      return
    }
    guard environments.contains(where: { $0.id == id }) else { return }
    guard !syncQueue.contains(id) else { return }
    syncQueue.append(id)
    if syncQueueTask == nil { startQueueRunner() }
  }

  /// Appends all IDs in order, deduplicating. Starts the runner if idle.
  func enqueueMultiSync(ids: [UUID]) {
    guard !persistenceLoadFailed else {
      os_log(.error, "[EnvironmentStore] multi-sync refused — device database unavailable; relaunch required.")
      return
    }
    for id in ids {
      guard environments.contains(where: { $0.id == id }) else { continue }
      guard !syncQueue.contains(id) else { continue }
      syncQueue.append(id)
    }
    if syncQueueTask == nil && !syncQueue.isEmpty { startQueueRunner() }
  }

  /// Cancels the current slot (stops the active engine, saving progress)
  /// and clears the rest of the queue.
  func cancelQueue() {
    syncQueueTask?.cancel()
    syncQueueTask = nil
    // Stop whichever engine owns the current slot — may differ from activeSyncEngine
    // when the user has switched to a different environment while the queue runs.
    if let currentEnvId = syncQueue.first, let engine = runningEngines[currentEnvId] {
      engine.stop()
    } else if activeSyncEngine.isRunning {
      activeSyncEngine.stop()
    }
    runningEngines.removeAll()
    syncQueue.removeAll()
  }

  /// Stops the current slot only — progress is saved, queue advances to next env.
  func stopCurrentSlot() {
    // Look up the engine that owns the current queue slot. It may not be
    // activeSyncEngine if the user switched environments while the slot was running.
    if let currentEnvId = syncQueue.first, let engine = runningEngines[currentEnvId] {
      engine.stop()
    } else {
      activeSyncEngine.stop()
    }
  }

  private func startQueueRunner() {
    guard syncQueueTask == nil else { return }   // never start a second runner
    syncQueueTask = Task { @MainActor in
      defer { syncQueueTask = nil }
      while !syncQueue.isEmpty && !Task.isCancelled {
        let envId = syncQueue[0]

        guard environments.contains(where: { $0.id == envId }) else {
          syncQueue.removeFirst()   // environment deleted while it sat in the queue
          continue
        }

        // S6: resolve and capture this slot's engine + store BEFORE any suspension
        // point. setActive → buildServices runs synchronously, so activeSyncEngine /
        // activeStore are already this environment's the instant setActive returns.
        // Capturing after an await would let a UI setActive() during the gap
        // redirect this slot to whatever environment the user just clicked, while
        // the queue still believed it was running `envId`.
        if activeEnvironmentId != envId { setActive(envId) }
        let engine = runningEngines[envId] ?? activeSyncEngine
        let store  = activeStore

        guard engine.environmentId == envId, store.environmentId == envId else {
          os_log(.error,
                 "[EnvironmentStore] Queue slot identity mismatch for %{public}@ (engine=%{public}@ store=%{public}@) — aborting slot.",
                 envId.uuidString,
                 engine.environmentId?.uuidString ?? "nil",
                 store.environmentId?.uuidString ?? "nil")
          if syncQueue.first == envId { syncQueue.removeFirst() }
          continue
        }

        if engine.isRunning {
          // A manual Run Sync was already triggered on this environment — wait for it.
          while engine.isRunning && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
          }
        } else {
          // Brief settle so isRunning / UI injection catch up. A setActive() by the
          // user during this window is harmless now — engine and store are bound.
          try? await Task.sleep(for: .milliseconds(300))
          guard !Task.isCancelled,
                syncQueue.first == envId,
                environments.contains(where: { $0.id == envId }) else {
            if syncQueue.first == envId { syncQueue.removeFirst() }
            continue   // unqueued or deleted during the settle — do not substitute
          }
          engine.run(store: store)
          // Short initial sleep so isRunning = true has time to propagate.
          try? await Task.sleep(for: .milliseconds(100))
          while engine.isRunning && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
          }
          if Task.isCancelled { engine.stop() }
        }

        // Always dequeue the finished slot before looping.
        if syncQueue.first == envId { syncQueue.removeFirst() }
      }
    }
  }

  func updateSyncStatus(_ id: UUID, status: EnvironmentSyncStatus, date: Date? = nil) {
    guard let idx = environments.firstIndex(where: { $0.id == id }) else { return }
    environments[idx].lastSyncStatus = status
    if let d = date { environments[idx].lastSyncedAt = d }
    if headless != nil {
      persistHeadlessStatus(id, status: status, date: date)
    } else {
      save()
    }
  }

  /// Read-modify-write of one environment's status on the on-disk list, so a
  /// headless run can never clobber an environment the GUI added or renamed. Only
  /// terminal statuses are written: a killed run must not leave the GUI showing
  /// "running" forever, and the cross-process lock is what signals "in progress".
  private func persistHeadlessStatus(_ id: UUID, status: EnvironmentSyncStatus, date: Date?) {
    guard status != .running,
          let data = ud.data(forKey: listKey),
          var list = try? AppEnvironment.jsonDecoder.decode([AppEnvironment].self, from: data),
          let idx = list.firstIndex(where: { $0.id == id }) else { return }
    list[idx].lastSyncStatus = status
    if let date { list[idx].lastSyncedAt = date }
    if let out = try? AppEnvironment.jsonEncoder.encode(list) { ud.set(out, forKey: listKey) }
  }

  // MARK: - External (headless) runs

  /// The GUI learns about a finished `--silent` run two ways: a Darwin notification
  /// posted by that process, and app activation as a fallback in case the
  /// notification is dropped. Both funnel into refreshFromExternalRun().
  private func observeExternalRuns() {
    notify_register_dispatch(HeadlessNotification.runFinished, &externalRunToken, .main) { [weak self] _ in
      Task { @MainActor in self?.refreshFromExternalRun() }
    }
    // Same fallback shape as runFinished above, but for the START of a headless
    // run — lets a locked-environment badge appear immediately rather than only
    // once that run finishes. refreshExternalLocks() also runs unconditionally
    // below at every activation, which is what catches a run already in progress
    // *before* the GUI was even open to receive this notification.
    notify_register_dispatch(HeadlessNotification.runStarted, &externalRunStartToken, .main) { [weak self] _ in
      Task { @MainActor in self?.refreshExternalLocks() }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          self?.refreshFromExternalRun()
          self?.refreshExternalLocks()
        }
      }
    refreshExternalLocks()
  }

  /// Best-effort peek of every environment's lock (see SyncLock.isHeldElsewhere) —
  /// GUI display only. Skips whatever this process is itself running so a live
  /// in-process sync is never mistaken for an externally-locked one.
  func refreshExternalLocks() {
    guard headless == nil else { return }
    var locked: Set<UUID> = []
    for env in environments where !isRunning(env.id) {
      if SyncLock.isHeldElsewhere(env.id) { locked.insert(env.id) }
    }
    if locked != externallyLockedEnvironments { externallyLockedEnvironments = locked }
  }

  /// Compares the on-disk environment list with memory. For an environment whose
  /// last-run status or time changed underneath us (and isn't running here), adopts
  /// the on-disk values; if that includes the active environment, reloads its
  /// last-run summary and devices. A no-op when nothing changed, so the fallback on
  /// every app activation stays cheap.
  private func refreshFromExternalRun() {
    guard headless == nil,
          let data = ud.data(forKey: listKey),
          let onDisk = try? AppEnvironment.jsonDecoder.decode([AppEnvironment].self, from: data) else { return }
    var changed: Set<UUID> = []
    for disk in onDisk {
      guard let idx = environments.firstIndex(where: { $0.id == disk.id }), !isRunning(disk.id) else { continue }
      if environments[idx].lastSyncedAt != disk.lastSyncedAt || environments[idx].lastSyncStatus != disk.lastSyncStatus {
        environments[idx].lastSyncedAt   = disk.lastSyncedAt
        environments[idx].lastSyncStatus = disk.lastSyncStatus
        changed.insert(disk.id)
      }
    }
    guard let active = activeEnvironmentId, changed.contains(active) else { return }
    activeSyncEngine.restoreLastRun(from: activeStore.prefs)
    activeStore.prefs.objectWillChange.send()
    Task { await activeStore.loadDevicesFromCoreDataSync() }
  }

  // MARK: - Persistence

  private func save() {
    guard headless == nil else { return }
    if let data = try? AppEnvironment.jsonEncoder.encode(environments) {
      ud.set(data, forKey: listKey)
    }
    if let id = activeEnvironmentId {
      ud.set(id.uuidString, forKey: activeKey)
    }
  }

  private func load() {
    if let data = ud.data(forKey: listKey),
       let list = try? AppEnvironment.jsonDecoder.decode([AppEnvironment].self, from: data) {
      environments = list
    }
    if let str = ud.string(forKey: activeKey),
       let id  = UUID(uuidString: str) {
      activeEnvironmentId = id
    }
  }

  // MARK: - v1 → v2 Migration

  /// On first v2.0 launch, if no environments exist, migrate the current single-environment
  /// setup into a named "Default" environment. All existing data (Keychain, CoreData,
  /// UserDefaults) is moved into the new environment's namespace.
  /// Called from init() when no environments exist yet.
  /// Sets isMigrating = true, runs the full migration on a detached Task,
  /// then builds services and clears the flag — all on MainActor.
  private func startMigration() {
    isMigrating     = true
    migrationError  = nil
    migrationStatus = "Preparing migration…"

    Task {
      await runMigration()
    }
  }

  private func runMigration() async {
    let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let scopeRaw  = UserDefaults.standard.string(forKey: "activeScope") ?? ""
    let scope     = AxMScope(rawValue: scopeRaw) ?? .business

    // ── Step 1: credentials — copy each one AND read it back to confirm it
    // round-trips. v1 flat keys are not touched.
    migrationStatus = "Migrating credentials…"
    if case .failure(let err) = KeychainService.migrateToEnvironment(id: defaultId, scope: scope) {
      failMigration(err)
      return
    }

    // ── Step 2: device store — stage the copy, verify it loads with the same
    // device count as v1, then move it atomically into place. On any failure
    // nothing is moved and the v1 store is left byte-for-byte intact.
    migrationStatus = "Migrating device data…"
    let destURL = PersistenceController.environmentStoreURL(defaultId)
    do {
      try FileManager.default.createDirectory(
        at: PersistenceController.environmentsDirectory, withIntermediateDirectories: true)
      let count = try await Task.detached(priority: .userInitiated) {
        try PersistenceController.stageAndVerifyV1Copy(to: destURL)
      }.value
      os_log(.default, "[EnvironmentStore] v1 store migrated and verified — %d device(s).", count)
    } catch {
      failMigration(error)
      return
    }

    // ── Step 3: preferences (UserDefaults — synchronous, per-key, low risk).
    migrationStatus = "Migrating preferences…"
    AppPreferences.migrateToEnvironment(id: defaultId)

    // ── Commit: both verifications passed. Persisting the environment list is
    // what stops the migration re-running on the next launch, so it must come
    // only after everything above has succeeded.
    var env = AppEnvironment(id: defaultId, name: "Default", scope: scope)
    env.lastSyncStatus = .never
    environments        = [env]
    activeEnvironmentId = defaultId
    save()
    os_log(.default, "[EnvironmentStore] Migration complete — Default environment (%{public}@)", defaultId.uuidString)

    buildServices(for: env)

    // ── Legacy cleanup — only now, after a fully verified and committed
    // migration. If anything above failed we returned early and these flat keys
    // are still the app's only copy of the credentials.
    KeychainService.deleteV1KeychainKeys()

    migrationStatus = ""
    migrationError  = nil
    isMigrating     = false
  }

  /// Migration hit an unrecoverable error before the commit point. v1 credentials
  /// and the v1 store are still fully intact; `environments` is left empty so the
  /// migration retries on the next launch, and the overlay shows `message`.
  private func failMigration(_ error: Error) {
    let message = (error as? LocalizedError)?.errorDescription ?? "Migration could not be completed."
    os_log(.error,
           "[EnvironmentStore] Migration FAILED — %{public}@ — v1 data left intact; will retry on next launch.",
           message)
    migrationError  = message
    migrationStatus = ""
    isMigrating     = false
  }

  /// Non-nil when the v1→v2 migration must not run because v2 data already exists.
  private static func v1MigrationRefusal(listPresent: Bool) -> String? {
    if listPresent {
      return "The saved environment list couldn’t be read — it may have been written by a newer version of AxM Jamf Sync. Your environments were left untouched."
    }
    let stores = (try? FileManager.default.contentsOfDirectory(atPath: PersistenceController.environmentsDirectory.path)) ?? []
    if stores.contains(where: { $0.hasSuffix(".sqlite") && !$0.hasSuffix(".staging.sqlite") }) {
      return "Environment data already exists but the environment list is missing. Your environments were left untouched."
    }
    return nil
  }

  // kept for internal use — non-migration path
  private func migrateFromV1() {
    startMigration()
  }

  // MARK: - Data wipe (on environment deletion)

  /// S5: caller (`delete`) must have already detached the Core Data coordinator and
  /// closed the log handle. Throws if the SQLite store files can't be removed — a
  /// present store file is what makes a future launch treat the env as still-valid,
  /// so a half-deleted store must not be reported as a clean wipe. Keychain /
  /// preferences / log removal are best-effort (logged, not fatal).
  private func wipeEnvironmentData(id: UUID) throws {
    KeychainService.wipeEnvironment(id: id)
    AppPreferences.wipeEnvironment(id: id)
    try PersistenceController.wipeEnvironment(id: id)   // fatal on failure
    LogService.wipeEnvironmentLog(id: id)
    LogService.evictEnvironment(id: id)
    SyncLock.remove(id)
    os_log(.default, "[EnvironmentStore] Wiped all data for environment %{public}@", id.uuidString)
  }
}
