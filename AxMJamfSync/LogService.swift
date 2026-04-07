// LogService.swift
// @MainActor log sink — entries shown in Sync UI log window + written to ~/Library/Logs/AxMJamfSync/sync.log
//
// Levels: info/warn/error → append to UI entries list + write to file with [INFO ]/[WARN ]/[ERROR] prefix.
//         debug → file-only (never shown in UI). Consecutive duplicate debug lines within 2s
//         are collapsed to "(×N total) <message>" to prevent log spam from concurrent tasks.
//
// Rotation: auto-rotates at 10MB → sync.1.log … sync.5.log. File permissions: 0600.
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
    private static let isoFmt = ISO8601DateFormatter()

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
        fileLine       = "[\(LogEntry.isoFmt.string(from: ts))] [\(raw)] \(message)"
    }
}

// MARK: - LogService
@MainActor
final class LogService: ObservableObject {
    static let shared = LogService()

    @Published private(set) var entries:   [LogEntry] = []
    @Published private(set) var warnCount: Int        = 0

    private var fileHandle: FileHandle?
    private let logURL:     URL
    private let logsDir:    URL
    // Serial queue for all file I/O — keeps main thread free during large syncs.
    // @MainActor methods queue writes here rather than calling fileHandle.write() directly.
    private let ioQueue = DispatchQueue(label: "com.karthikmac.axmjamfsync.logIO", qos: .utility)

    // Deduplication: suppress consecutive identical debug lines within 2s
    // (e.g. 8 concurrent PATCH tasks all logging "Token: reusing cached token")
    private var lastDebugLine: String = ""
    private var lastDebugTime: Date   = .distantPast
    private var lastDebugCount: Int   = 0

    // Rotation config
    private let maxFileBytes:    Int = 10 * 1_024 * 1_024   // 10 MB
    private let maxArchivedLogs: Int = 5

    /// Shared singleton — uses the default log path (sync.log).
    /// Used for the Default (v1-migrated) environment.
    private init() {
        logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AxMJamfSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logURL = logsDir.appendingPathComponent("sync.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        // S5: Restrict log file to owner-read/write only (0600).
        // Logs contain device serials, MACs, agreement IDs — not world-readable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        openFileHandle()
    }

    /// Internal init for per-environment log files.
    private init(logURL: URL, logsDir: URL) {
        self.logsDir = logsDir
        self.logURL  = logURL
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        openFileHandle()
    }

    // MARK: - Logging methods
    func info(_ msg: String)  { append(.init(level: .info,  message: msg)) }
    func warn(_ msg: String)  { append(.init(level: .warn,  message: msg)); warnCount += 1 }
    func error(_ msg: String) { append(.init(level: .error, message: msg)) }

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
        // Rotate before writing the new session header if the file is large
        rotateIfNeeded()
        let iso = LogService.sessionIsoFmt.string(from: Date())
        writeLine("")
        writeLine("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        writeLine("  AxMJamfSync — New Sync Session")
        writeLine("  Started : \(iso)")
        writeLine("  macOS   : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        writeLine("  App     : \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        writeLine("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    var allText: String { entries.map(\.fullLine).joined(separator: "\n") }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allText, forType: .string)
    }

    func openLogFile() { NSWorkspace.shared.open(logURL) }
    var logFileURL: URL { logURL }

    // MARK: - Rotation
    // Renames:  sync.4.log → sync.5.log, …, sync.1.log → sync.2.log, sync.log → sync.1.log
    // Deletes sync.5.log first if it already exists.
    private func rotateIfNeeded() {
        let fm   = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        guard size >= maxFileBytes else { return }

        // Close current handle before renaming
        try? fileHandle?.close(); fileHandle = nil

        // Shift existing archives: sync.4 → sync.5, sync.3 → sync.4, …
        for i in stride(from: maxArchivedLogs - 1, through: 1, by: -1) {
            let src  = logsDir.appendingPathComponent("sync.\(i).log")
            let dest = logsDir.appendingPathComponent("sync.\(i + 1).log")
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            if fm.fileExists(atPath: src.path)  { try? fm.moveItem(at: src, to: dest) }
        }

        // Rotate current log → sync.1.log
        let archive = logsDir.appendingPathComponent("sync.1.log")
        if fm.fileExists(atPath: archive.path) { try? fm.removeItem(at: archive) }
        try? fm.moveItem(at: logURL, to: archive)

        // Create fresh sync.log
        fm.createFile(atPath: logURL.path, contents: nil)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        openFileHandle()

        os_log(.default, "[LogService] Rotated sync.log (was %d KB).", size / 1_024)
    }

    // MARK: - Private helpers
    private func openFileHandle() {
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
    }

    private func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > 2_000 { entries.removeFirst(entries.count - 2_000) }
        writeLine(entry.fileLine)
    }

    private func writeLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let fh      = fileHandle
        let logURL  = self.logURL
        let logsDir = self.logsDir
        ioQueue.async { [weak self] in
            // Recreate file and handle if deleted externally (e.g. in Finder)
            if fh == nil || !FileManager.default.fileExists(atPath: logURL.path) {
                try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
                if let newHandle = try? FileHandle(forWritingTo: logURL) {
                    newHandle.seekToEndOfFile()
                    newHandle.write(data)
                    DispatchQueue.main.async { self?.fileHandle = newHandle }
                    return
                }
            }
            fh?.write(data)
        }
    }

  // MARK: - v2.0 Per-environment LogService

  static func makeForEnvironment(id: UUID) -> LogService {
    let logsDir = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/AxMJamfSync/environments", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logURL = logsDir.appendingPathComponent("\(id.uuidString).log")
    return LogService(logURL: logURL, logsDir: logsDir)
  }

  static func wipeEnvironmentLog(id: UUID) {
    let logsDir = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/AxMJamfSync/environments", isDirectory: true)
    let logURL = logsDir.appendingPathComponent("\(id.uuidString).log")
    try? FileManager.default.removeItem(at: logURL)
    for i in 1...5 {
      let archive = logsDir.appendingPathComponent("\(id.uuidString).\(i).log")
      try? FileManager.default.removeItem(at: archive)
    }
  }
}

// MARK: - String helper
private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
