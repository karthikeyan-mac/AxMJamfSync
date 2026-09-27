// DiagnosticsExporter.swift
// Phase 8 — Help ▸ Export Diagnostics…
//
// Builds a redacted diagnostics bundle — app/environment metadata, a per-
// environment settings dump, and every live + archived log file — into a temp
// directory, then zips it via the NSFileCoordinator(.forUploading) trick: no
// external `zip` process, no extra entitlement, works inside the sandbox.
//
// Never includes credentials or Jamf/Apple hosts: AppEnvironment itself
// carries neither (they live only in Keychain, never touched here), and the
// settings dump only ever states booleans/counts/timestamps — the same shape
// as the redacted dump SyncEngine already writes to the log at the top of
// every run (see ARCHITECTURE.md's log redaction rules for why raw HTTP
// bodies are never logged either).
//
// MainActor reads (environments, AppPreferences per environment) are
// snapshotted into plain Sendable values before hopping to a detached Task —
// same discipline as SyncEngine's merge snapshots — so the file I/O and
// zipping never touch @MainActor state directly.

import Foundation
import AppKit
import UniformTypeIdentifiers
import os

@MainActor
enum DiagnosticsExporter {

  /// Presents a save panel and, if the user picks a destination, builds and
  /// writes the diagnostics zip there. Best-effort support artifact, not a
  /// data-critical path — failures show an alert rather than throwing.
  static func exportWithSavePanel(envStore: EnvironmentStore, scheduler: SyncScheduler, runMode: AppRunModeController) {
    let panel = NSSavePanel()
    panel.title = "Export Diagnostics"
    panel.prompt = "Export"
    panel.nameFieldStringValue = defaultFilename()
    panel.allowedContentTypes = [.zip]
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    let environments = envStore.environments
    let settingsDumps = Dictionary(uniqueKeysWithValues: environments.map { ($0.id, settingsDumpText(for: $0)) })
    let scheduleSummary = scheduleSummaryText(scheduler)
    let runModeSummary  = runModeSummaryText(runMode)

    Task.detached(priority: .utility) {
      do {
        try buildAndWriteBundle(environments: environments, settingsDumps: settingsDumps,
                                 scheduleSummary: scheduleSummary, runModeSummary: runModeSummary,
                                 to: destination)
        await MainActor.run {
          NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
      } catch {
        os_log(.error, "[Diagnostics] Export failed: %{public}@", error.localizedDescription)
        await MainActor.run {
          let alert = NSAlert()
          alert.alertStyle = .warning
          alert.messageText = "Couldn't Export Diagnostics"
          alert.informativeText = error.localizedDescription
          alert.runModal()
        }
      }
    }
  }

  private static func defaultFilename() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd_HHmm"
    return "AxMJamfSync-Diagnostics-\(df.string(from: Date())).zip"
  }

  private static func scheduleSummaryText(_ scheduler: SyncScheduler) -> String {
    guard scheduler.isEnabled else { return "Automatically Sync : off" }
    var lines = ["Automatically Sync : on", "Cron Expression    : \(scheduler.cronExpression.rawValue)"]
    if let next = scheduler.nextFireDate { lines.append("Next Sync          : \(ISO8601DateFormatter().string(from: next))") }
    if let last = scheduler.lastFireDate { lines.append("Last Scheduled Run : \(ISO8601DateFormatter().string(from: last))") }
    lines.append("Launch at Login    : \(scheduler.launchAtLoginEnabled ? "on" : "off")")
    return lines.joined(separator: "\n")
  }

  private static func runModeSummaryText(_ runMode: AppRunModeController) -> String {
    "Show in Dock       : \(runMode.dockIconVisible ? "on" : "off")"
  }

  /// MainActor read of one environment's AppPreferences — cheap (UserDefaults
  /// only, no I/O) — reduced to a plain redacted String before the detached
  /// Task ever sees it. No credentials, no Jamf/Apple host — AppPreferences
  /// doesn't store either.
  private static func settingsDumpText(for env: AppEnvironment) -> String {
    let prefs = AppPreferences(environmentId: env.id)
    let iso = ISO8601DateFormatter()
    return """
    Environment        : \(env.name)
    Scope              : \(env.scope == .school ? "ASM (Apple School Manager)" : "ABM (Apple Business)")
    Last Sync Status   : \(env.lastSyncStatus.rawValue)
    Last Synced At     : \(env.lastSyncedAt.map { iso.string(from: $0) } ?? "never")
    Device Cache Days  : \(prefs.devicesCacheDays)
    Coverage Cache Days: \(prefs.coverageCacheDays)
    Coverage Limit     : \(prefs.coverageLimit == 0 ? "unlimited" : "\(prefs.coverageLimit)/run")
    Do Not Refetch     : \(prefs.skipExistingCoverage ? "on" : "off")
    Sync Device Types  : \(prefs.syncDeviceScope.label)
    Last AxM Sync      : \(prefs.lastAxmSync.map { iso.string(from: $0) } ?? "never")
    Last Jamf Sync     : \(prefs.lastJamfSync.map { iso.string(from: $0) } ?? "never")
    Last Coverage Sync : \(prefs.lastCoverageSync.map { iso.string(from: $0) } ?? "never")
    Last Run Outcome   : \(prefs.lrOutcome)
    """
  }

  // MARK: - Bundle assembly (off-actor — file I/O + zipping only, no @MainActor state)

  private nonisolated static let logsRootDir: URL = {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/AxMJamfSync")
  }()
  private nonisolated static var envLogsDir: URL { logsRootDir.appendingPathComponent("environments") }

  /// Live log + every archive that actually exists for `stem` in `dir` — see
  /// ARCHITECTURE.md "Per-environment logs: UUID-stemmed rotation" for the
  /// {stem}.{i}.log naming this mirrors.
  private nonisolated static func logURLs(stem: String, in dir: URL) -> [URL] {
    var urls = [dir.appendingPathComponent("\(stem).log")]
    for i in 1...LogService.maxArchivedLogs {
      urls.append(dir.appendingPathComponent("\(stem).\(i).log"))
    }
    return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Matches the alphanumeric tokens a serial number could appear as, so
  /// `maskedText` only has to check each candidate against `serialLabels`
  /// (O(1) dictionary lookup) rather than compiling one regex per serial.
  private nonisolated static let serialTokenPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9]{6,}")

  /// Replaces every token in `text` that is a known device serial with its
  /// placeholder. Everything else — including tokens that merely look like a
  /// serial — passes through untouched.
  private nonisolated static func maskedText(_ text: String, labels: [String: String]) -> String {
    guard !labels.isEmpty else { return text }
    let ns = text as NSString
    let matches = serialTokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return text }
    var result = ""
    var cursor = 0
    for match in matches {
      guard let label = labels[ns.substring(with: match.range)] else { continue }
      result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      result += label
      cursor = match.range.location + match.range.length
    }
    result += ns.substring(from: cursor)
    return result
  }

  /// Reads `src` as text, masks known serials, and writes the result to `dst`.
  /// Skips the file entirely rather than falling back to a raw copy if it
  /// can't be decoded as UTF-8 — a diagnostics bundle leaving the Mac must
  /// never risk shipping an unmasked serial.
  private nonisolated static func copyMaskedLog(from src: URL, to dst: URL, labels: [String: String]) {
    guard let text = try? String(contentsOf: src, encoding: .utf8) else { return }
    try? maskedText(text, labels: labels).write(to: dst, atomically: true, encoding: .utf8)
  }

  private nonisolated static func buildAndWriteBundle(
    environments: [AppEnvironment], settingsDumps: [UUID: String],
    scheduleSummary: String, runModeSummary: String, to destination: URL
  ) throws {
    let fm = FileManager.default
    let stagingDir = fm.temporaryDirectory.appendingPathComponent("AxMJamfSync-Diagnostics-\(UUID().uuidString)")
    try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stagingDir) }

    // Log files carry every synced device's serial number in plain text (see
    // ARCHITECTURE.md's log redaction rules). Build one serial→placeholder map
    // across every environment being exported, so a shared log file never
    // reveals an org's device inventory — and so the same serial reads as the
    // same placeholder everywhere in the bundle, including the shared sync.log.
    var allSerials = Set<String>()
    for env in environments {
      let persistence = PersistenceController.loadedStore(for: env.id) ?? PersistenceController(environmentId: env.id)
      allSerials.formUnion(persistence.allSerialNumbers())
    }
    let serialLabels = Dictionary(uniqueKeysWithValues:
      allSerials.sorted().enumerated().map { ($1, "<device \($0 + 1)>") })

    let appText = """
    AxM Jamf Sync — Diagnostics
    Generated       : \(ISO8601DateFormatter().string(from: Date()))
    App Version     : \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
    macOS           : \(ProcessInfo.processInfo.operatingSystemVersionString)
    \(runModeSummary)
    \(scheduleSummary)
    Environment Count: \(environments.count)
    """
    try appText.write(to: stagingDir.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)

    // environments.json — AppEnvironment carries no credentials or hosts, safe as-is.
    if let data = try? AppEnvironment.jsonEncoder.encode(environments) {
      try data.write(to: stagingDir.appendingPathComponent("environments.json"))
    }

    let envDir = stagingDir.appendingPathComponent("environments")
    try fm.createDirectory(at: envDir, withIntermediateDirectories: true)
    for env in environments {
      let envFolder = envDir.appendingPathComponent(env.id.uuidString)
      try fm.createDirectory(at: envFolder, withIntermediateDirectories: true)
      let dump = settingsDumps[env.id] ?? "Environment : \(env.name)\n(no settings snapshot available)"
      try dump.write(to: envFolder.appendingPathComponent("settings.txt"), atomically: true, encoding: .utf8)

      for logURL in logURLs(stem: env.id.uuidString, in: envLogsDir) {
        copyMaskedLog(from: logURL, to: envFolder.appendingPathComponent(logURL.lastPathComponent), labels: serialLabels)
      }
    }

    // Shared app-level log (diagnostics outside any one environment's run).
    for logURL in logURLs(stem: "sync", in: logsRootDir) {
      copyMaskedLog(from: logURL, to: stagingDir.appendingPathComponent(logURL.lastPathComponent), labels: serialLabels)
    }

    // Zip the staging directory. NSFileCoordinator's .forUploading option is
    // the documented sandbox-safe way to get a zip of a folder's contents
    // without shelling out to /usr/bin/zip (not guaranteed reachable/
    // entitled from inside the App Sandbox) or a third-party archiving library.
    //
    // Fix: the coordinator's zip lives at a temporary location whose lifetime
    // is tied to the coordinated read — it is only guaranteed to exist while
    // still inside this closure. The previous code captured the URL and moved
    // it AFTER `coordinate(...)` had already returned, which could race with
    // the temp file being cleaned up ("X couldn't be moved to Y because
    // either the former doesn't exist..."). Copy to `destination` from inside
    // the closure instead — copyItem is also the safer choice than moveItem
    // here regardless, since the source is coordinator-owned temp storage and
    // the destination is a user-granted sandbox extension (Desktop, etc.),
    // not a plain rename target.
    var coordError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(readingItemAt: stagingDir, options: .forUploading, error: &coordError) { zipURL in
      do {
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: zipURL, to: destination)
      } catch {
        copyError = error
      }
    }
    if let coordError { throw coordError }
    if let copyError { throw copyError }
    guard fm.fileExists(atPath: destination.path) else {
      throw NSError(domain: "AxMJamfSync.Diagnostics", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: "Could not create the diagnostics archive."])
    }
  }
}
