// SyncScheduler.swift
// App-wide automatic sync scheduling.
//
// One schedule covers every environment — when due, all environments are pushed
// onto EnvironmentStore's existing serial sync queue (enqueueMultiSync), so a
// scheduled run behaves identically to tapping "Sync All": one environment at a
// time, no parallel Apple/Jamf API calls.
//
// Trigger model: in-process poll loop (a single Task sleeping 30s at a time,
// comparing wall-clock Date() against a persisted nextFireDate) paired with
// "Launch at Login" via SMAppService. This only fires while the app process is
// alive — if the app is force-quit, scheduled syncs resume on next launch rather
// than running while fully closed. That trade-off avoids a second XPC/helper
// target purely for scheduling.
//
// Settings are intentionally flat (unprefixed) UserDefaults keys — unlike
// AppPreferences, scheduling is global, not per-environment.

import Foundation
import Combine
import ServiceManagement
import os

// MARK: - UserDefaults keys

private enum SchedulePrefKey {
  static let enabled       = "schedule.enabled"
  static let cronExpr      = "schedule.cronExpr"
  static let nextFireEpoch = "schedule.nextFireEpoch"
  static let lastFireEpoch = "schedule.lastFireEpoch"
}

// MARK: - SyncScheduler

@MainActor
final class SyncScheduler: ObservableObject {

  private let ud = UserDefaults.standard

  // MARK: Settings (UserDefaults-backed, not @AppStorage — see AppPreferences.swift
  // for why @AppStorage inside an ObservableObject causes a re-render loop on macOS 14+).

  @Published private(set) var isEnabled: Bool = false {
    didSet { ud.set(isEnabled, forKey: SchedulePrefKey.enabled); reschedule() }
  }
  @Published private(set) var cronExpression: CronExpression = .dailyAt9AM {
    didSet { ud.set(cronExpression.rawValue, forKey: SchedulePrefKey.cronExpr); reschedule() }
  }
  /// Raw text the user is editing in the cron field — kept separate from
  /// `cronExpression` so an in-progress, momentarily-invalid string (e.g. "*/5 *")
  /// doesn't get rejected mid-keystroke. Committed to `cronExpression` on parse success.
  @Published var cronText: String = CronExpression.dailyAt9AM.rawValue
  @Published private(set) var cronError: String? = nil

  /// Next computed fire date — published so Settings UI can show "Next sync: …" live.
  @Published private(set) var nextFireDate: Date? = nil
  @Published private(set) var lastFireDate: Date? = nil

  // MARK: Launch at Login

  @Published private(set) var launchAtLoginEnabled: Bool = false
  @Published var launchAtLoginError: String? = nil

  // MARK: Wiring

  private weak var environmentStore: EnvironmentStore?
  private var pollTask: Task<Void, Never>?
  /// Watches EnvironmentStore's sync queue drain back to empty after a
  /// scheduled run enqueues it, so a single "Scheduled Sync Complete" summary
  /// notification can fire once the whole batch finishes — separate from the
  /// per-environment completion notifications SyncEngine already sends.
  private var queueCompletionCancellable: AnyCancellable?

  init() {
    isEnabled     = ud.bool(forKey: SchedulePrefKey.enabled)
    let savedCron = ud.string(forKey: SchedulePrefKey.cronExpr).flatMap(CronExpression.init(parsing:)) ?? .dailyAt9AM
    cronExpression = savedCron
    cronText       = savedCron.rawValue
    let savedNext = ud.double(forKey: SchedulePrefKey.nextFireEpoch)
    nextFireDate  = savedNext > 0 ? Date(timeIntervalSince1970: savedNext) : nil
    let savedLast = ud.double(forKey: SchedulePrefKey.lastFireEpoch)
    lastFireDate  = savedLast > 0 ? Date(timeIntervalSince1970: savedLast) : nil
    refreshLaunchAtLoginStatus()
  }

  /// Called once at app launch. Recomputes a fresh nextFireDate if the persisted
  /// one is missing or already in the past (e.g. the app was closed for days) —
  /// scheduled syncs never "catch up" on missed runs, only look forward.
  func start(environmentStore: EnvironmentStore) {
    self.environmentStore = environmentStore
    if isEnabled, nextFireDate == nil || nextFireDate! < Date() {
      nextFireDate = computeNextFireDate()
      persistNextFire()
    }
    startPolling()
  }

  // MARK: - Public setters (UI-facing)

  func setEnabled(_ enabled: Bool) { isEnabled = enabled }

  /// Called as the user types in the free-text cron field. Parses on every
  /// keystroke; valid expressions commit immediately, invalid ones just set
  /// `cronError` and leave the last-valid `cronExpression` (and therefore the
  /// schedule) untouched until the text becomes valid again.
  func setCronText(_ text: String) {
    cronText = text
    guard let parsed = CronExpression(parsing: text) else {
      cronError = "Not a valid 5-field cron expression."
      return
    }
    cronError = nil
    cronExpression = parsed
  }

  /// Called by the friendly schedule builder, which computes a whole
  /// CronExpression from plain-language controls (every N minutes/hours, or a
  /// specific time daily/weekly/monthly) rather than editing one field at a time.
  func setCronExpression(_ expression: CronExpression) {
    cronExpression = expression
    cronText       = expression.rawValue
    cronError      = nil
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginError = nil
    } catch {
      // Roll the published toggle back to actual system state on failure.
      launchAtLoginError = error.localizedDescription
    }
    refreshLaunchAtLoginStatus()
  }

  /// System Settings → General → Login Items can change this outside the app —
  /// call when Settings appears so the toggle reflects reality.
  func refreshLaunchAtLoginStatus() {
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
  }

  // MARK: - Scheduling core

  private func reschedule() {
    nextFireDate = isEnabled ? computeNextFireDate() : nil
    persistNextFire()
    startPolling()
  }

  private func startPolling() {
    pollTask?.cancel()
    pollTask = nil
    guard isEnabled else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.checkDue()
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }

  private func checkDue() async {
    guard isEnabled, let next = nextFireDate, Date() >= next else { return }
    fireScheduledSync()
    lastFireDate = Date()
    ud.set(lastFireDate!.timeIntervalSince1970, forKey: SchedulePrefKey.lastFireEpoch)
    nextFireDate = computeNextFireDate()
    persistNextFire()
  }

  private func fireScheduledSync() {
    guard let environmentStore else { return }
    let ids = environmentStore.environments.map(\.id)
    guard !ids.isEmpty else {
      os_log(.default, "[SyncScheduler] Scheduled sync skipped — no environments configured.")
      return
    }
    os_log(.default, "[SyncScheduler] Scheduled sync firing for %{public}d environment(s).", ids.count)
    let names = environmentStore.environments.map(\.name)
    SyncNotificationService.sendScheduleTriggered(environmentNames: names)
    environmentStore.enqueueMultiSync(ids: ids)
    observeQueueCompletion(environmentStore, environmentCount: ids.count)
  }

  private func observeQueueCompletion(_ environmentStore: EnvironmentStore, environmentCount: Int) {
    queueCompletionCancellable?.cancel()
    queueCompletionCancellable = environmentStore.$syncQueue
      .dropFirst() // skip the just-enqueued snapshot; wait for a later, empty one
      .filter(\.isEmpty)
      .first()
      .sink { [weak self] _ in
        Task { @MainActor in
          SyncNotificationService.sendScheduleCompleted(environmentCount: environmentCount)
          self?.queueCompletionCancellable = nil
        }
      }
  }

  private func computeNextFireDate(from now: Date = Date()) -> Date? {
    cronExpression.nextFireDate(after: now)
  }

  private func persistNextFire() {
    ud.set(nextFireDate?.timeIntervalSince1970 ?? 0, forKey: SchedulePrefKey.nextFireEpoch)
  }
}
