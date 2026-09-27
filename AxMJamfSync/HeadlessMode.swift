// HeadlessMode.swift
// `--silent` command-line mode: the same signed, sandboxed binary runs the sync
// pipeline with no UI, against the same Keychain / Core Data / UserDefaults the GUI
// uses, then exits with a code. Intended for launchd / cron / scripts.
//
//   "/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync" --silent [--env <name|uuid>]…
//
// Always writes back to Jamf, same as Run Sync in the app — there was a --write
// flag gating this (a read-only-unless-asked default that had no GUI equivalent
// to match), removed so --silent behaves identically to a manual sync either way.

import Foundation
import Darwin
import notify
import os

// MARK: - Entry point

@main
@MainActor
enum AppLauncher {
  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    switch HeadlessOptions.parse(args) {
    case .gui:
      if args.isEmpty && launchedFromTerminal {
        print(HeadlessOptions.usage)
        exit(HeadlessExit.success)
      }
      AxMJamfSyncApp.main()
    case .help:
      print(HeadlessOptions.usage)
      exit(HeadlessExit.success)
    case .headless(let options):
      HeadlessRunner.run(options)
    case .usageError(let message):
      FileHandle.standardError.write(Data("AxM Jamf Sync: \(message)\n\n\(HeadlessOptions.usage)\n".utf8))
      exit(HeadlessExit.usage)
    }
  }

  /// Finder, `open`, launchd and Xcode never attach a terminal, so a bare launch from
  /// a shell prompt is someone who typed the path and wants help, not a window.
  /// Xcode is excluded explicitly: its console can present as a tty. `--gui` opts back in.
  private static var launchedFromTerminal: Bool {
    guard ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] == nil else { return false }
    return isatty(STDIN_FILENO) != 0 || isatty(STDOUT_FILENO) != 0
  }
}

// MARK: - Options

struct HeadlessOptions: Sendable {
  /// Environment names or UUIDs from `--env`. Empty means every environment.
  var environments: [String] = []

  enum Parsed {
    case gui
    case help
    case headless(HeadlessOptions)
    case usageError(String)
  }

  static var usage: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    return """
    AxM Jamf Sync \(version) — syncs AppleCare/warranty coverage from Apple Business/School
    Manager into Jamf Pro.

    USAGE
      AxM Jamf Sync                      Open the app (double-click, or `open -a`).
      AxM Jamf Sync --gui                Open the app when launched from a terminal.
      AxM Jamf Sync --silent [options]   Sync with no UI, then exit. For launchd / cron.
      AxM Jamf Sync --help               Show this help.

    OPTIONS (only with --silent)
      --env <name>    Sync only this environment, by name or UUID. Repeat to pick
                      several. Default: every environment.

    A --silent run writes warranty/purchase data back to Jamf Pro, same as Run
    Sync in the app — it's a full sync, not a preview.

    EXAMPLES
      Sync every environment:
        "/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync" --silent
      Sync two environments:
        "/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync" --silent --env Production --env Staging

    HOW IT WORKS
      Uses the same environments, credentials, cache and settings as the app — set them
      up in the app first. Nothing is prompted for and no window or notification is
      shown. A run never adds, removes or renames environments or changes which one is
      active. Environments are queued and synced in turn.
      If the app (or another --silent run) is already syncing an environment, that
      environment is skipped rather than run twice; skipping is not a failure.
      SIGTERM (launchd stop) and Ctrl-C cancel the run like Stop in the app: partial
      progress is saved first, then the exit code is 3. An open app reloads what a
      run wrote when it finishes.

    LOGS
      Each run appends to the same log files the app uses, with lines tagged [CLI]
      (the app's are tagged [GUI]):
        ~/Library/Containers/com.karthikmac.axmjamfsync/Data/Library/Logs/AxMJamfSync/
          environments/<environment UUID>.log    one per environment
          sync.log                               app-wide, including refused starts
      Problems that stop a run before it starts are also printed to stderr.

    EXIT CODES
      0   success, or every environment skipped
      1   partial: some data landed but the run was not complete
      2   failed
      3   cancelled
      64  bad usage (unknown or misplaced argument)
      78  no environment configured, or --env matched none
    """
  }

  /// A launch without `--silent` is a normal GUI launch — macOS itself passes
  /// single-dash flags such as -NSDocumentRevisionsDebugMode, so those must not
  /// turn a GUI launch into an error. Double-dash arguments are ours: see below.
  static func parse(_ args: [String]) -> Parsed {
    if args.contains("--help") || args.contains("-h") { return .help }
    guard args.contains("--silent") else {
      // macOS only ever injects single-dash flags (-NSDocumentRevisionsDebugMode…),
      // so a double-dash argument here is the user's, and silently opening the GUI
      // would swallow it.
      if args.contains("--env") {
        return .usageError("--env only applies to a --silent run")
      }
      if let flag = args.first(where: { $0.hasPrefix("--") && $0 != "--gui" }) {
        return .usageError("unknown argument \(flag)")
      }
      return .gui
    }
    var options = HeadlessOptions()
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--silent":
        break
      case "--env":
        i += 1
        guard i < args.count, !args[i].hasPrefix("--") else { return .usageError("--env needs a value") }
        options.environments.append(args[i])
      default:
        return .usageError("unknown argument \(args[i])")
      }
      i += 1
    }
    return .headless(options)
  }
}

enum HeadlessExit {
  static let success: Int32   = 0
  static let partial: Int32   = 1
  static let failed: Int32    = 2
  static let cancelled: Int32 = 3
  static let usage: Int32     = 64
  static let config: Int32    = 78
}

// MARK: - Cross-process notification

enum HeadlessNotification {
  /// Posted right before a `--silent` run enqueues its environments — lets an open
  /// GUI show "syncing (command-line)" immediately rather than only discovering it
  /// reactively (the GUI also peeks every lock on launch/activation for the case
  /// where it opens *after* a run is already in progress; see EnvironmentStore).
  static let runStarted  = "com.karthikmac.axmjamfsync.headless.runStarted"
  /// Darwin notification posted when a headless run finishes an environment, so a
  /// running GUI can reload what the run wrote. Never carries data — the GUI
  /// re-reads Core Data / UserDefaults itself.
  static let runFinished = "com.karthikmac.axmjamfsync.headless.runFinished"
}

// MARK: - Per-environment cross-process sync lock

/// `flock` on a per-environment file inside the container. The kernel drops the
/// lock when the holding process dies, so a crashed or killed run can never leave
/// an environment permanently locked.
struct SyncLock: Sendable {
  private let fd: Int32

  private static var directory: URL {
    PersistenceController.environmentsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("locks", isDirectory: true)
  }

  /// nil means another process holds this environment's lock. If the lock file
  /// itself can't be opened the run proceeds unlocked (fd -1, release is a no-op)
  /// rather than making every sync fail on a filesystem problem.
  static func tryAcquire(_ envId: UUID) -> SyncLock? {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("\(envId.uuidString).lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else {
      os_log(.error, "[SyncLock] could not open lock file for %{public}@ — proceeding without a cross-process lock.", envId.uuidString)
      return SyncLock(fd: -1)
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return nil
    }
    return SyncLock(fd: fd)
  }

  func release() {
    guard fd >= 0 else { return }
    flock(fd, LOCK_UN)
    close(fd)
  }

  static func remove(_ envId: UUID) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(envId.uuidString).lock"))
  }

  /// Best-effort, non-blocking peek: is another process (or another open file
  /// description in this one) currently holding this environment's lock? For UI
  /// display only — never itself acquires the real lock, and a lock taken a moment
  /// after this returns isn't caught. tryAcquire() above is the actual enforcement.
  ///
  /// flock() locks belong to the *open file description*, not the path or the
  /// process, so a second open() on the same path always starts unlocked — trying
  /// to lock it non-blockingly and immediately releasing on success is the correct
  /// way to test another holder without disturbing it (fcntl's F_GETLK does NOT
  /// see a flock()-held lock; it's a separate, non-interoperating lock namespace).
  static func isHeldElsewhere(_ envId: UUID) -> Bool {
    let path = directory.appendingPathComponent("\(envId.uuidString).lock").path
    let fd = open(path, O_RDWR)   // no O_CREAT — nothing to peek if it was never made
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
    flock(fd, LOCK_UN)
    return false
  }
}

// MARK: - Runner

@MainActor
enum HeadlessRunner {

  // Retained for the life of the process — a DispatchSource that is released stops firing.
  private static var signalSources: [DispatchSourceSignal] = []
  private static var wasCancelled = false

  /// Deliberately never touches NSApplication/NSApp — see SyncNotificationService's
  /// sendError() doc comment. dispatchMain() blocks forever pumping the main dispatch
  /// queue, which is what MainActor's executor runs on: everything this Task needs
  /// (async/await, @MainActor hops) works exactly as it did under NSApplication.run(),
  /// just without ever registering as an addressable app instance.
  static func run(_ options: HeadlessOptions) -> Never {
    SyncNotificationService.isSuppressed = true

    Task { @MainActor in
      let code = await execute(options)
      notify_post(HeadlessNotification.runFinished)
      exit(code)
    }
    dispatchMain()
  }

  private static func execute(_ options: HeadlessOptions) async -> Int32 {
    guard EnvironmentStore.hasPersistedEnvironments else {
      fail("no environments configured — open AxM Jamf Sync and set one up first.")
      return HeadlessExit.config
    }

    let envStore = EnvironmentStore(headless: options)

    var targets: [AppEnvironment] = []
    if options.environments.isEmpty {
      targets = envStore.environments
    } else {
      for query in options.environments {
        let match = envStore.environments.first { $0.id.uuidString.caseInsensitiveCompare(query) == .orderedSame }
          ?? envStore.environments.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        guard let match else {
          fail("no environment named or identified “\(query)”.")
          return HeadlessExit.config
        }
        if !targets.contains(where: { $0.id == match.id }) { targets.append(match) }
      }
    }
    guard !targets.isEmpty else {
      fail("no environments configured.")
      return HeadlessExit.config
    }
    let ids = targets.map(\.id)

    // launchd stops a job with SIGTERM. Route it (and Ctrl-C) through the same
    // cancel path as the GUI's Stop so partial progress is flushed before exit.
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler {
        Task { @MainActor in
          wasCancelled = true
          envStore.cancelQueue()
        }
      }
      source.resume()
      signalSources.append(source)
    }

    LogService.shared.info("Headless run started — \(ids.count) environment(s). Per-environment results are in each environment's own log.")
    notify_post(HeadlessNotification.runStarted)
    envStore.enqueueMultiSync(ids: ids)

    // cancelQueue() empties the queue immediately while the engine is still
    // unwinding its partial-data flush, so the queue alone is not "finished".
    while envStore.isSyncQueueRunning || envStore.activeSyncEngine.isRunning || ids.contains(where: { envStore.isRunning($0) }) {
      try? await Task.sleep(for: .milliseconds(250))
    }

    if wasCancelled { return finish(HeadlessExit.cancelled, "cancelled by signal") }

    var worst = HeadlessExit.success
    var succeeded = 0, partial = 0, failed = 0, skipped = 0
    for id in ids {
      if envStore.skippedForExternalSync.contains(id) { skipped += 1; continue }
      switch envStore.lastOutcomeByEnv[id] {
      case .success:   succeeded += 1
      case .partial:   partial += 1; worst = max(worst, HeadlessExit.partial)
      case .cancelled: return finish(HeadlessExit.cancelled, "an environment was cancelled")
      // No terminal outcome and not skipped: the run was refused before starting
      // (e.g. the device database failed to load) — same rule the scheduler uses.
      case .failed, .none: failed += 1; worst = HeadlessExit.failed
      }
    }
    return finish(worst, "\(succeeded) succeeded, \(partial) partial, \(failed) failed, \(skipped) skipped")
  }

  /// The one place a headless run reports its result to sync.log. Flushes because
  /// the caller exits the process straight afterwards.
  private static func finish(_ code: Int32, _ detail: String) -> Int32 {
    if code == HeadlessExit.success { HeadlessStartupFailure.clear() }
    let word = ["success", "partial", "failed", "cancelled"][Int(min(code, 3))]
    HeadlessRunStatus.record(result: word, exitCode: code, detail: detail)
    let line = "Headless run finished — \(word) (exit \(code)): \(detail)."
    if code == HeadlessExit.success { LogService.shared.info(line) } else { LogService.shared.warn(line) }
    LogService.shared.flush()
    return code
  }

  /// Also lands in sync.log (a launchd/cron job's stderr is easy to never see) and
  /// a UserDefaults marker the GUI shows once on next launch (HeadlessStartupFailure
  /// below) — a scheduled agent that never even gets an environment to sync against
  /// fails silently otherwise: no crash, no notification, just a repeating log line
  /// nobody's looking at. A run that never starts has no per-environment status to
  /// surface through the sidebar the way an ordinary sync failure already does.
  private static func fail(_ message: String) {
    FileHandle.standardError.write(Data("AxM Jamf Sync: \(message)\n".utf8))
    LogService.shared.error("Headless run not started: \(message)")
    LogService.shared.flush()
    HeadlessStartupFailure.record(message)
    HeadlessRunStatus.record(result: "config", exitCode: HeadlessExit.config, detail: message)
  }
}

// MARK: - Durable --silent status, for `defaults read` / debugging — see the
// "Inspecting --silent's status" section on the wiki's Command-Line Mode page.
//
// Distinct from HeadlessStartupFailure above: that one is consumed (read once,
// cleared) to drive a one-time GUI alert. This one is never cleared — it's a
// running record of "has --silent ever run, and how did it last go", meant to be
// read directly from the plist, not surfaced in the app.
//
// What this can't tell you: whether a LaunchAgent is actually registered with
// launchd right now. A sandboxed app can't read ~/Library/LaunchAgents or query
// another job's launchd registration — there's no entitlement for either. These
// fields are the closest honest substitute: real evidence that --silent has
// actually executed, from something (a LaunchAgent, `launchctl kickstart`, or a
// person running it by hand) — not proof that an agent is currently loaded.
enum HeadlessRunStatus {
  private static let firstSeenKey = "headless.firstSeenEpoch"
  private static let lastRunEpochKey  = "headless.lastRunEpoch"
  private static let lastRunResultKey = "headless.lastRunResult"
  private static let lastRunExitCodeKey = "headless.lastRunExitCode"
  private static let lastRunDetailKey   = "headless.lastRunDetail"

  /// `result` is one of success/partial/failed/cancelled (a real run reaching
  /// finish()) or "config" (fail() — never got as far as attempting a sync).
  static func record(result: String, exitCode: Int32, detail: String) {
    let ud = UserDefaults.standard
    let now = Date()
    // Stored as a real Date, not a raw epoch Double — see AppEnvironment's
    // jsonEncoder/jsonDecoder doc comment for the fuller reasoning; the same
    // applies here, just without the old-data-migration complication since
    // these are flat keys, not something JSONEncoder is choosing the format for.
    // Write-once (preserves the true first-run moment) — but a value already on
    // disk from before this key stored a real Date (a raw Double, the old
    // .timeIntervalSince1970 format) would then never migrate: this is the ONLY
    // place that ever touches firstSeenKey, and once it's non-nil, "set only if
    // nil" never fires again. Unlike v2.environments (rewritten on every save())
    // or lastRunEpoch (overwritten unconditionally on every run), there's no other
    // event that would ever correct it. So: migrate the type in place if needed,
    // keeping the original moment — don't just leave stale data stuck forever.
    switch ud.object(forKey: firstSeenKey) {
    case .none:
      ud.set(now, forKey: firstSeenKey)
    case .some(let existing) where !(existing is Date):
      if let legacy = existing as? Double {
        ud.set(Date(timeIntervalSince1970: legacy), forKey: firstSeenKey)
      }
    default:
      break   // already a real Date — leave the true first-seen moment alone
    }
    ud.set(now,                  forKey: lastRunEpochKey)
    ud.set(result,               forKey: lastRunResultKey)
    ud.set(Int(exitCode),        forKey: lastRunExitCodeKey)
    ud.set(detail,               forKey: lastRunDetailKey)
    ud.synchronize()   // same exit()-right-after reasoning as HeadlessStartupFailure
  }
}

// MARK: - Startup-failure marker surfaced to the GUI

/// A `--silent` run that never got as far as attempting a sync (no environments
/// configured, or `--env` matched none) leaves nothing for the ordinary
/// per-environment sidebar status to show — this is the one place that failure
/// becomes visible without reading sync.log. Recorded here, read and cleared once
/// by EnvironmentStore.init() on the next GUI launch. Flat UserDefaults keys,
/// same domain as everything else this app shares between GUI and --silent.
enum HeadlessStartupFailure {
  private static let messageKey = "headless.startupFailureMessage"
  private static let epochKey   = "headless.startupFailureEpoch"

  static func record(_ message: String) {
    let ud = UserDefaults.standard
    ud.set(message, forKey: messageKey)
    ud.set(Date(), forKey: epochKey)   // real Date, not a raw epoch Double — see AppEnvironment
    // UserDefaults.set() doesn't guarantee an immediate disk write — normally fine,
    // but fail() calls this right before exit(), which tears the process down before
    // the usual async flush to cfprefsd would happen. synchronize() is deprecated
    // (rarely needed) but still functional, and is exactly the "about to hard-exit,
    // must land now" case it remains useful for. Confirmed via a real --silent run:
    // without this, the marker silently never reached disk at all.
    ud.synchronize()
  }

  /// Called by a successful run too (HeadlessRunner.finish) — a working sync means
  /// whatever caused an earlier startup failure is no longer live, so an old notice
  /// shouldn't linger for the GUI to surface on some future launch.
  static func clear() {
    let ud = UserDefaults.standard
    ud.removeObject(forKey: messageKey)
    ud.removeObject(forKey: epochKey)
    ud.synchronize()   // same exit()-right-after reasoning as record() above
  }

  /// Reads and clears in one step — this is a one-time notice, not persistent
  /// state; a GUI relaunch must never show the same failure twice.
  static func consume() -> (message: String, date: Date)? {
    let ud = UserDefaults.standard
    guard let message = ud.string(forKey: messageKey) else { return nil }
    // Pre-fix data (a raw Double under this key) reads back as nil here — falls
    // through to `?? Date()`, same "harmless one-time reset" as SyncScheduler's.
    let date = ud.object(forKey: epochKey) as? Date ?? Date()
    clear()
    return (message, date)
  }
}
