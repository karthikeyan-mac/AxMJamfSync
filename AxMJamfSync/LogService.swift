// LogService.swift
// @MainActor log sink — entries shown in Sync UI log window + written to disk.
//   shared singleton  → ~/Library/Containers/com.karthikmac.axmjamfsync/Data/Library/Logs/AxMJamfSync/sync.log            (app-wide diagnostics only)
//   per-environment   → ~/Library/Containers/com.karthikmac.axmjamfsync/Data/Library/Logs/AxMJamfSync/environments/{uuid}.log
//
// Levels: info/warn/error → append to UI entries list + write to file with [INFO ]/[WARN ]/[ERROR] prefix, then [GUI]/[CLI].
//         debug → file-only (never shown in UI). Consecutive duplicate debug lines within 2s
//         are collapsed to "(×N total) <message>" to prevent log spam from concurrent tasks.
//
// S9 — Rotation is environment-scoped: archives derive from the LIVE file's own stem
//   ({stem}.1.log … {stem}.5.log), so a per-env log rotates to {uuid}.1.log, never a
//   shared "sync.1.log". Every write AND rotation for one log run on that instance's
//   single serial `ioQueue`, and `fileHandle` is only ever touched from inside it — two
//   environments can never interleave file operations against the same path.
//
// Rotation: auto-rotates at maxFileBytes → {stem}.1.log … {stem}.5.log. Files are 0600.
// Retention: live log + up to maxArchivedLogs (5) archives per stem; rotation is the only
//   pruning (no time-based expiry, no auto-export). wipeEnvironmentLog removes all of an
//   environment's archives on deletion.
// Session header written by clearSession() at start of each sync run.

import Foundation
import os
import SwiftUI

// MARK: - LogEntry
struct LogEntry: Identifiable {
    enum Level: String {
        case info = "INFO", warn = "WARN", error = "ERROR", debug = "DEBUG"
        var icon: String {
            switch self { case .info: "✓"; case .warn: "⚠"; case .error: "✗"; case .debug: "·" }
        }
        var color: Color {
            switch self { case .info: .green; case .warn: .orange; case .error: .red; case .debug: .secondary }
        }
    }

    // P1/Q3: Shared static formatters — allocated once, never again.
    // DateFormatter init touches locale/calendar subsystem (~200µs each).
    // At 50k devices × 3 log lines per device = 150k calls — statics save ~30s.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    // ISO8601DateFormatter is not Sendable-audited — nonisolated(unsafe), read-only.
    nonisolated(unsafe) private static let isoFmt = ISO8601DateFormatter()
    // The GUI and a `--silent` run append to the same per-environment file, so each
    // file line says which process wrote it. Fixed for the life of the process.
    private static let source = CommandLine.arguments.contains("--silent") ? "CLI" : "GUI"

    let id         = UUID()
    let timestamp:  Date
    let level:     Level
    let message:   String
    // Q3: Stored at init time — computed property was re-allocating DateFormatter on every access.
    let timeString: String
    let fullLine:   String
    let fileLine:   String

    init(level: Level, message: String) {
        self.level     = level
        self.message   = message
        let ts         = Date()
        self.timestamp = ts
        timeString     = LogEntry.timeFmt.string(from: ts)
        let icon       = level.icon
        let raw        = level.rawValue.padded(to: 5)
        fullLine       = "\(timeString) \(icon) \(raw) \(message)"
        fileLine       = "[\(LogEntry.isoFmt.string(from: ts))] [\(raw)] [\(LogEntry.source)] \(message)"
    }
}

// MARK: - LogService
@MainActor
final class LogService: ObservableObject {
    static let shared = LogService()

    @Published private(set) var entries:   [LogEntry] = []
    @Published private(set) var warnCount: Int        = 0

    // S9: only ever read or mutated from inside `ioQueue` (init opens it via ioQueue.sync).
    private nonisolated(unsafe) var fileHandle: FileHandle?
    private nonisolated let logURL:      URL
    private nonisolated let logsDir:     URL
    // S9: filename stem the rotation archives derive from — "sync" for the shared
    // singleton, "{uuid}" for a per-environment log.
    private nonisolated let archiveStem: String
    // Serial queue for all file I/O AND rotation — keeps the main thread free during
    // large syncs and guarantees per-log serialization (one instance ⇒ one queue).
    private nonisolated let ioQueue = DispatchQueue(label: "com.karthikmac.axmjamfsync.logIO", qos: .utility)

    // Deduplication: suppress consecutive identical debug lines within 2s
    // (e.g. 8 concurrent PATCH tasks all logging "Token: reusing cached token")
    private var lastDebugLine: String = ""
    private var lastDebugTime: Date   = .distantPast
    private var lastDebugCount: Int   = 0

    // Rotation config. `maxArchivedLogs` is static so wipeEnvironmentLog uses the
    // same bound. Trigger/threshold logic is unchanged from before S9.
    nonisolated static let maxFileBytes:    Int = 10 * 1_024 * 1_024   // 10 MB
    nonisolated static let maxArchivedLogs: Int = 5

    /// Shared singleton — uses the default log path (sync.log).
    /// Reserved for genuinely app-wide diagnostics (app launch, environment list
    /// changes, Keychain/TLS infrastructure) — NOT a specific environment's sync run.
    private init() {
        logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AxMJamfSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logURL      = logsDir.appendingPathComponent("sync.log")
        archiveStem = logURL.deletingPathExtension().lastPathComponent
        ioQueue.sync { self.openHandleLocked(create: true) }
    }

    /// Internal init for per-environment log files.
    private init(logURL: URL, logsDir: URL) {
        self.logsDir     = logsDir
        self.logURL      = logURL
        self.archiveStem = logURL.deletingPathExtension().lastPathComponent
        ioQueue.sync { self.openHandleLocked(create: true) }
    }

    // MARK: - Logging methods
    func info(_ msg: String)  { append(.init(level: .info,  message: msg)) }
    func warn(_ msg: String)  { append(.init(level: .warn,  message: msg)); warnCount += 1 }
    func error(_ msg: String) { append(.init(level: .error, message: msg)) }

    /// Blocks until every line queued so far is on disk. For a process that exits
    /// straight after logging (a `--silent` run that refuses to start).
    func flush() { ioQueue.sync {} }

    /// debug() — file only. Never shown in the Sync UI log window.
    /// Consecutive identical messages within 2s are collapsed to avoid log spam
    /// from concurrent tasks (e.g. 8 PATCH workers all logging the same token line).
    func debug(_ msg: String) {
        let now = Date()
        if msg == lastDebugLine && now.timeIntervalSince(lastDebugTime) < 2.0 {
            lastDebugCount += 1
            return  // suppress duplicate
        }
        // Flush suppression summary before writing new line
        if lastDebugCount > 0 {
            let entry = LogEntry(level: .debug, message: "(×\(lastDebugCount + 1) total) \(lastDebugLine)")
            writeLine(entry.fileLine)
            lastDebugCount = 0
        }
        lastDebugLine = msg
        lastDebugTime = now
        let entry = LogEntry(level: .debug, message: msg)
        writeLine(entry.fileLine)
    }

    // P1: Shared static ISO formatter used for session header timestamp.
    private static let sessionIsoFmt = ISO8601DateFormatter()

    func clearSession() {
        entries        = []
        warnCount      = 0
        lastDebugLine  = ""
        lastDebugTime  = .distantPast
        lastDebugCount = 0
        // Rotate before the new session header. Runs on ioQueue so it can't interleave
        // with in-flight writes; `.sync` keeps it ordered ahead of the header lines below.
        ioQueue.sync { self.rotateLocked() }
        let iso = LogService.sessionIsoFmt.string(from: Date())
        writeLine("")
        writeLine("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        writeLine("  AxMJamfSync — New Sync Session")
        writeLine("  Started : \(iso)")
        writeLine("  macOS   : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        writeLine("  App     : \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        writeLine("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    /// 3.4: UI-only clear — resets what LogWindowView shows without touching the
    /// on-disk file or rotation. Distinct from clearSession(), which is tied to a
    /// new sync run actually starting (rotates the file, writes a session
    /// header) — a manual "Clear Log" click in the UI must never do that.
    func clearDisplayedEntries() {
        entries   = []
        warnCount = 0
    }

    var allText: String { entries.map(\.fullLine).joined(separator: "\n") }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allText, forType: .string)
    }

    func openLogFile() { NSWorkspace.shared.open(logURL) }
    var logFileURL: URL { logURL }

    // MARK: - Rotation
    //   {stem}.4.log → {stem}.5.log, …, {stem}.1.log → {stem}.2.log, live → {stem}.1.log
    // stem is "sync" for the shared log, "{uuid}" for a per-environment log.

    private nonisolated func archiveURL(_ i: Int) -> URL {
        logsDir.appendingPathComponent("\(archiveStem).\(i).log")
    }

    /// Runs on `ioQueue`. Trigger threshold (`size >= maxFileBytes`) is unchanged.
    private nonisolated func rotateLocked() {
        let fm   = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int) ?? 0
        guard size >= Self.maxFileBytes else { return }

        try? fileHandle?.close(); fileHandle = nil

        for i in stride(from: Self.maxArchivedLogs - 1, through: 1, by: -1) {
            let src = archiveURL(i), dst = archiveURL(i + 1)
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dst) }
        }

        let first = archiveURL(1)
        if fm.fileExists(atPath: first.path) { try? fm.removeItem(at: first) }
        try? fm.moveItem(at: logURL, to: first)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path)

        openHandleLocked(create: true)
        os_log(.default, "[LogService] Rotated %{public}@ (was %d KB).",
               logURL.lastPathComponent, size / 1_024)
    }

    // MARK: - Private helpers (all run on ioQueue)

    /// S5: Restrict log files to owner read/write only (0600) — they hold device
    /// serials, MACs, agreement IDs.
    private nonisolated func openHandleLocked(create: Bool) {
        let fm = FileManager.default
        if create && !fm.fileExists(atPath: logURL.path) {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        if fm.fileExists(atPath: logURL.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        try? fileHandle?.close()
        // O_APPEND, not open-then-seekToEnd: a headless run appends to the same
        // per-environment file while the GUI holds a handle, and a plain handle would
        // resume at its stale offset and overwrite the other process's lines.
        let fd = open(logURL.path, O_WRONLY | O_APPEND, 0o600)
        fileHandle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    private nonisolated func writeLocked(_ data: Data) {
        if fileHandle == nil || !FileManager.default.fileExists(atPath: logURL.path) {
            openHandleLocked(create: true)
        }
        do { try fileHandle?.write(contentsOf: data) }
        catch {
            openHandleLocked(create: true)
            try? fileHandle?.write(contentsOf: data)
        }
    }

    private func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > 2_000 { entries.removeFirst(entries.count - 2_000) }
        writeLine(entry.fileLine)
    }

    private nonisolated func writeLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        ioQueue.async { [weak self] in self?.writeLocked(data) }
    }

  // MARK: - v2.0 Per-environment LogService

  /// Cache of per-environment LogService instances keyed by environment UUID.
  /// Ensures that buildServices() and buildBackgroundServices() always return
  /// the same instance for a given environment — so the Sync UI log window,
  /// the active engine, and any background multi-sync engine all share one
  /// @Published entries array and updates are visible everywhere.
  private static var envCache: [UUID: LogService] = [:]
  private static var didPurgeLegacyArchives = false

  private static var environmentsLogDir: URL {
    FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/AxMJamfSync/environments", isDirectory: true)
  }

  static func makeForEnvironment(id: UUID) -> LogService {
    if let cached = envCache[id] { return cached }
    let logsDir = environmentsLogDir
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    purgeLegacySharedArchives()
    let logURL  = logsDir.appendingPathComponent("\(id.uuidString).log")
    let service = LogService(logURL: logURL, logsDir: logsDir)
    envCache[id] = service
    return service
  }

  /// S9: pre-fix rotation wrote every environment's archives into a shared
  /// `environments/sync.N.log`. Those files can hold a since-deleted environment's
  /// history and are never claimed by the UUID-stemmed scheme, so remove them once.
  private static func purgeLegacySharedArchives() {
    guard !didPurgeLegacyArchives else { return }
    didPurgeLegacyArchives = true
    let fm  = FileManager.default
    let dir = environmentsLogDir
    let names = ["sync.log"] + (1...maxArchivedLogs).map { "sync.\($0).log" }
    for name in names {
      let u = dir.appendingPathComponent(name)
      guard fm.fileExists(atPath: u.path) else { continue }
      try? fm.removeItem(at: u)
      os_log(.default, "[LogService] Removed legacy shared archive %{public}@ from environments dir.", name)
    }
  }

  /// The cached LogService for an environment, if one was ever opened this session.
  static func envInstance(for id: UUID) -> LogService? { envCache[id] }

  /// Removes the cached instance for an environment — called when the environment
  /// is deleted so the cache does not retain a LogService for a wiped env.
  static func evictEnvironment(id: UUID) {
    envCache.removeValue(forKey: id)
  }

  /// S5: drain queued writes and close the open file handle so the log file can be
  /// deleted. Call BEFORE wipeEnvironmentLog / file removal.
  func closeForDeletion() {
    ioQueue.sync {
      try? self.fileHandle?.close()
      self.fileHandle = nil
    }
  }

  /// Removes an environment's live log and every rotated archive ({uuid}.1.log …
  /// {uuid}.maxArchivedLogs.log — the exact scheme rotateLocked writes).
  static func wipeEnvironmentLog(id: UUID) {
    let fm     = FileManager.default
    let logsDir = environmentsLogDir
    try? fm.removeItem(at: logsDir.appendingPathComponent("\(id.uuidString).log"))
    for i in 1...maxArchivedLogs {
      try? fm.removeItem(at: logsDir.appendingPathComponent("\(id.uuidString).\(i).log"))
    }
  }
}

// MARK: - S9: HTTP response body sanitisation
// One place that formats an error-response body for the log. Used by JamfService's
// 401 and non-2xx branches (ABMService deliberately logs status only).
extension LogService {

  nonisolated private static let bodyRedactors: [(NSRegularExpression, String)] = {
    let specs: [(String, String)] = [
      // JWT (header.payload.signature): Apple client_assertion, OAuth access tokens
      ("eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]*", "‹redacted-jwt›"),
      // Authorization: Bearer <token>
      ("(?i)(bearer)\\s+[A-Za-z0-9._~+/=-]{8,}", "$1 ‹redacted›"),
      // "key": "value" / key=value for credential-shaped keys
      ("(?i)(\"?(?:access_token|refresh_token|id_token|client_secret|client_assertion|assertion|password|passwd|secret|api[_-]?key|authorization)\"?\\s*[:=]\\s*)\"?[^\"\\s,&}]{4,}\"?", "$1‹redacted›"),
      // user:pass@host embedded in a URL
      ("://[^/\\s:@]+:[^/\\s@]+@", "://‹redacted›@"),
    ]
    return specs.compactMap { pat, tmpl in
      (try? NSRegularExpression(pattern: pat)).map { ($0, tmpl) }
    }
  }()

  /// Redact first, THEN clamp: truncating first can slice a token mid-string so the
  /// pattern no longer matches the surviving head.
  nonisolated static func sanitizedResponseBody(_ text: String, maxChars: Int = 500) -> String {
    var s = text
    for (re, tmpl) in bodyRedactors {
      s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tmpl)
    }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count > maxChars else { return s.isEmpty ? "<no body>" : s }
    let cut = s.index(s.startIndex, offsetBy: maxChars)
    return String(s[..<cut]) + " …(+\(s.count - maxChars) chars)"
  }

  nonisolated static func sanitizedResponseBody(_ data: Data, maxChars: Int = 500) -> String {
    let capped = data.count > 65_536 ? data.prefix(65_536) : data
    return sanitizedResponseBody(String(decoding: capped, as: UTF8.self), maxChars: maxChars)
  }
}

// MARK: - String helper
private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
