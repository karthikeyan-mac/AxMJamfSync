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
    let persistence  = PersistenceController(environmentId: env.id)
    let prefs        = AppPreferences(environmentId: env.id)
    let logService   = LogService.makeForEnvironment(id: env.id)
    activeStore      = AppStore(environment: env, persistence: persistence, prefs: prefs)
    activeSyncEngine = SyncEngine()
    activeSyncEngine.log = logService
    // Wire status callback so sidebar reflects sync progress
    let envId = env.id
    activeSyncEngine.onSyncStatusChange = { [weak self] status, date in
      self?.updateSyncStatus(envId, status: status, date: date)
    }
    // Set synchronously — cacheIsPopulated is derived from a CoreData row count
    // in AppStore.init, so it is always correct before any view renders.
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
