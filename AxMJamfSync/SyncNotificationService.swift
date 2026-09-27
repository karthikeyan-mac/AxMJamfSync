// SyncNotificationService.swift
// User Notification Centre integration.
// Sends completion and error notifications after each sync run.
// App icon badge cleared at run end.

import Foundation
import UserNotifications
import AppKit
import os

@MainActor
enum SyncNotificationService {

    /// Set by the `--silent` headless run — no notification may be posted from it.
    static var isSuppressed = false

    // MARK: - Schedule triggered
    // Fired once per scheduled run, before the queue starts — distinct from the
    // per-environment completion/error notifications below, which still fire once
    // per environment as the queue works through them.
    static func sendScheduleTriggered(environmentNames: [String]) {
        let content = UNMutableNotificationContent()
        content.title = "Scheduled Sync Starting"
        content.body  = environmentNames.count == 1
            ? "Syncing \(environmentNames[0])…"
            : "Syncing \(environmentNames.count) environments: \(environmentNames.joined(separator: ", "))"
        content.sound = .default
        sendNotification(content, id: "schedule-triggered")
    }

    // MARK: - Schedule completed
    // Fired once when every environment in a scheduled run has finished — a
    // summary on top of the per-environment completion/error notifications
    // below, which still fire individually as the queue works through them.
    static func sendScheduleCompleted(summary: ScheduledRunSummary) {
        let content = UNMutableNotificationContent()
        content.title = summary.allClean ? "Scheduled Sync Complete"
                                         : "Scheduled Sync — Completed with Issues"
        content.body  = summary.notificationText
        content.sound = .default
        sendNotification(content, id: "schedule-completed")
    }

    // MARK: - Completion (success)
    static func sendCompletion(devices: Int, coverage: Int, writeback: Int) {
        guard !isSuppressed else { return }   // before any NSApp touch — see sendError's note
        NSApp.requestUserAttention(.informationalRequest)   // bounce dock icon once

        let content = UNMutableNotificationContent()
        content.title = "AxM Sync Complete ✓"
        content.body  = "\(devices) devices · \(coverage) coverage fetched · \(writeback) write-backs synced"
        content.sound = .default
        sendNotification(content, id: "sync-complete")
    }

    // MARK: - Partial (S7)
    // A run that landed real data but did not fully complete — distinct from both a
    // clean success and an outright failure.
    static func sendPartial(detail: String) {
        guard !isSuppressed else { return }
        NSApp.requestUserAttention(.informationalRequest)
        let content = UNMutableNotificationContent()
        content.title = "AxM Sync — Completed with Issues"
        content.body  = detail
        content.sound = .default
        sendNotification(content, id: "sync-partial")
    }

    // MARK: - Failure
    // 4.5: informational, not critical — a sync failure never risks data loss
    // (existing cache is untouched), so an insistent bounce-until-focused
    // request overstates the severity. The notification itself still uses
    // .defaultCritical sound so it's not silent.
    // `isSuppressed` is checked here too, not just inside sendNotification() below — a
    // `--silent` run must never touch `NSApp` at all. Referencing the `NSApp` global
    // lazily instantiates NSApplication.shared on first touch even if nothing ever calls
    // NSApplication.shared directly, and HeadlessRunner deliberately never does (S-headless-2:
    // a headless process that's a real NSApplication is addressable by an Apple Event sent to
    // the bundle ID, e.g. a Quit or reopen meant for the GUI — the OS can't tell them apart
    // and may kill the headless one silently. Cost a real interrupted overnight sync to find.)
    static func sendError(message: String) {
        guard !isSuppressed else { return }
        NSApp.requestUserAttention(.informationalRequest)

        let content = UNMutableNotificationContent()
        content.title = "AxM Sync Failed ✗"
        content.body  = message
        content.sound = .defaultCritical
        sendNotification(content, id: "sync-error")
    }

    // MARK: - Private
    private static func sendNotification(_ content: UNMutableNotificationContent, id: String) {
        guard !isSuppressed else { return }
        // Attach the app icon so Notification Centre shows it alongside the alert.
        // On macOS the system uses the app bundle icon automatically for sandboxed apps,
        // but writing it explicitly as an attachment guarantees it appears.
        if content.attachments.isEmpty,
           let iconURL = writeIconAttachment() {
            content.attachments = (try? [UNNotificationAttachment(identifier: "icon", url: iconURL, options: nil)]) ?? []
        }
        let req = UNNotificationRequest(
            identifier: "\(id)-\(Int(Date().timeIntervalSince1970))",
            content:    content,
            trigger:    nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err { os_log(.error, "[Notification] error: %{public}@", err.localizedDescription) }
        }
    }

    /// Write the app icon as a PNG to the app's caches directory for use as a notification attachment.
    /// Returns nil if the icon cannot be written (non-fatal — notification still sends without icon).
    /// macOS notification centre on sandboxed apps picks up the bundle icon automatically,
    /// so this attachment is belt-and-suspenders insurance for edge cases.
    private static func writeIconAttachment() -> URL? {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.karthikmac.axmjamfsync") ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let iconURL = caches.appendingPathComponent("notif-icon.png")
        // Re-use cached PNG if it already exists
        if FileManager.default.fileExists(atPath: iconURL.path) { return iconURL }
        guard let icon = NSApp.applicationIconImage,
              let tiff = icon.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: iconURL)
        return iconURL
    }
}
