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
}

enum EnvironmentSyncStatus: String, Codable {
  case never   // never synced
  case success // last sync succeeded
  case error   // last sync had errors
  case running // sync in progress

  var icon: String {
    switch self {
    case .never:   return "circle"
    case .success: return "checkmark.circle.fill"
    case .error:   return "exclamationmark.circle.fill"
    case .running: return "arrow.triangle.2.circlepath.circle.fill"
    }
  }

  var color: Color {
    switch self {
    case .never:   return .secondary
    case .success: return .green
    case .error:   return .orange
    case .running: return .accentColor
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

  /// True while the one-time v1→v2 CoreData migration is running.
  @Published private(set) var isMigrating: Bool = false
  @Published private(set) var migrationStatus: String = ""
  /// Set synchronously in buildServices — ContentView reads this before first render.
  @Published private(set) var initialTab: ContentView.Tab = .setup

  private let ud = UserDefaults.standard
  private let listKey   = "v2.environments"
  private let activeKey = "v2.activeEnvironmentId"

  var activeEnvironment: AppEnvironment? {
    guard let id = activeEnvironmentId else { return environments.first }
    return environments.first { $0.id == id }
  }

  init() {
    load()
    if environments.isEmpty {
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
    // in UserDefaults survives. Use all three sources in priority order:
    //   1. axm.scope Keychain key (most authoritative — written on every credential save)
    //   2. clientId prefix (SCHOOLAPI* / BUSINESSAPI* — written with credentials)
    //   3. dataCachedScope UserDefaults (survives Keychain wipe — written by SyncEngine)
    let savedScopeRaw = KeychainService.loadForEnv(key: "axm.scope", envId: env.id) ?? ""
    let clientIdRaw   = KeychainService.loadForEnv(key: "axm.clientId", envId: env.id) ?? ""
    let cachedPrefs   = AppPreferences(environmentId: env.id)
    let inferredScope: AxMScope? = {
      if let s = AxMScope(rawValue: savedScopeRaw) { return s }
      if clientIdRaw.uppercased().hasPrefix("SCHOOLAPI")   { return .school }
      if clientIdRaw.uppercased().hasPrefix("BUSINESSAPI") { return .business }
      // Fallback 3: scope of the data already in CoreData — written by SyncEngine at sync end
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

    let persistence  = PersistenceController(environmentId: env.id)
    let prefs        = AppPreferences(environmentId: env.id)
    let logService   = LogService.makeForEnvironment(id: env.id)
    activeStore      = AppStore(environment: env, persistence: persistence, prefs: prefs)
    activeSyncEngine = SyncEngine()
    activeSyncEngine.log = logService
    let envId = env.id
    activeSyncEngine.onSyncStatusChange = { [weak self] status, date in
      self?.updateSyncStatus(envId, status: status, date: date)
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

  /// Returns true if this environment can be deleted.
  /// The last remaining environment cannot be deleted — the app requires at least one.
  func canDelete(_ id: UUID) -> Bool { environments.count > 1 }

  /// Update the scope of an environment — persists the change so buildServices
  /// always loads the correct scope on the next switch or relaunch.
  func updateScope(_ id: UUID, scope: AxMScope) {
    guard let idx = environments.firstIndex(where: { $0.id == id }) else { return }
    environments[idx].scope = scope
    save()
  }

  func delete(_ id: UUID) {
    guard canDelete(id) else { return }
    wipeEnvironmentData(id: id)
    environments.removeAll { $0.id == id }
    save()
    if activeEnvironmentId == id {
      activeEnvironmentId = environments.first?.id
      if let env = activeEnvironment {
        buildServices(for: env)
      }
    }
  }

  func setActive(_ id: UUID) {
    guard environments.contains(where: { $0.id == id }) else { return }
    guard !activeSyncEngine.isRunning else {
      os_log(.default, "[EnvironmentStore] Switch blocked — sync is running.")
      return
    }
    activeSyncEngine.stop()   // defensive cleanup before replacing the engine
    activeEnvironmentId = id
    ud.set(id.uuidString, forKey: activeKey)
    if let env = activeEnvironment {
      buildServices(for: env)
    }
  }

  func updateSyncStatus(_ id: UUID, status: EnvironmentSyncStatus, date: Date? = nil) {
    guard let idx = environments.firstIndex(where: { $0.id == id }) else { return }
    environments[idx].lastSyncStatus = status
    if let d = date { environments[idx].lastSyncedAt = d }
    save()
  }

  // MARK: - Persistence

  private func save() {
    if let data = try? JSONEncoder().encode(environments) {
      ud.set(data, forKey: listKey)
    }
    if let id = activeEnvironmentId {
      ud.set(id.uuidString, forKey: activeKey)
    }
  }

  private func load() {
    if let data = ud.data(forKey: listKey),
       let list = try? JSONDecoder().decode([AppEnvironment].self, from: data) {
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
    migrationStatus = "Preparing migration…"

    Task {
      await runMigration()
    }
  }

  private func runMigration() async {
    let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let scopeRaw  = UserDefaults.standard.string(forKey: "activeScope") ?? ""
    let scope     = AxMScope(rawValue: scopeRaw) ?? .business

    migrationStatus = "Migrating credentials…"
    KeychainService.migrateToEnvironment(id: defaultId, scope: scope)

    migrationStatus = "Migrating device data…"
    // Run CoreData migration on a background thread — it can be slow for large stores
    await Task.detached(priority: .userInitiated) {
      _ = PersistenceController(environmentId: defaultId)
    }.value

    migrationStatus = "Migrating preferences…"
    AppPreferences.migrateToEnvironment(id: defaultId)

    var env = AppEnvironment(id: defaultId, name: "Default", scope: scope)
    env.lastSyncStatus = .never
    environments        = [env]
    activeEnvironmentId = defaultId
    save()
    os_log(.default, "[EnvironmentStore] Migration complete — Default environment (%{public}@)", defaultId.uuidString)

    // Build services for the default environment now that migration is complete
    buildServices(for: env)

    // Step 3: now that CoreData, UserDefaults, and services are all confirmed
    // working, delete the v1 flat Keychain keys. Done last so there is a full
    // rollback window if anything earlier failed.
    KeychainService.deleteV1KeychainKeys()

    migrationStatus = ""
    isMigrating     = false
  }

  // kept for internal use — non-migration path
  private func migrateFromV1() {
    startMigration()
  }

  // MARK: - Data wipe (on environment deletion)

  private func wipeEnvironmentData(id: UUID) {
    KeychainService.wipeEnvironment(id: id)
    AppPreferences.wipeEnvironment(id: id)
    PersistenceController.wipeEnvironment(id: id)
    LogService.wipeEnvironmentLog(id: id)
    os_log(.default, "[EnvironmentStore] Wiped all data for environment %{public}@", id.uuidString)
  }
}
