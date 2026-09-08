// AxMJamfSyncApp.swift
// @main entry point — v2.0 multi-environment.
// © 2026 Karthikeyan Marappan. All rights reserved.
//
// EnvironmentStore owns the active AppStore and SyncEngine as @Published properties.
// When the user switches environments, EnvironmentStore rebuilds those services and
// publishes the new instances. The WindowGroup body re-evaluates, and .environmentObject
// propagates the new instances to all child views automatically.
//
// No @StateObject swapping needed — the scene simply reads from envStore.activeStore
// and envStore.activeSyncEngine on every render.

import os
import SwiftUI
import CoreData
import AppKit

@main
struct AxMJamfSyncApp: App {

  @StateObject private var envStore  = EnvironmentStore()
  @StateObject private var scheduler = SyncScheduler()
  @StateObject private var runMode   = AppRunModeController()
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  private var logDirURL: URL {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/AxMJamfSync/environments")
  }
  private var logFileURL: URL {
    guard let envId = envStore.activeEnvironmentId else {
      return logDirURL.deletingLastPathComponent().appendingPathComponent("sync.log")
    }
    return logDirURL.appendingPathComponent("\(envId.uuidString).log")
  }

  /// MenuBarExtra doesn't reliably honor SwiftUI's .resizable()/.frame() sizing
  /// on a large source image — it can render at (or near) native size instead of
  /// shrinking. Pre-rendering a small, fixed-size NSImage once avoids that.
  private static let menuBarIcon: NSImage = {
    guard let source = NSImage(named: "AppLogo") else {
      return NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        ?? NSImage()
    }
    let size = NSSize(width: 18, height: 18)
    let resized = NSImage(size: size)
    resized.lockFocus()
    source.draw(in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1.0)
    resized.unlockFocus()
    return resized
  }()

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView(appEngine: envStore.activeSyncEngine, initialTab: envStore.initialTab)
        .environmentObject(envStore.activeStore)
        .environmentObject(envStore.activeSyncEngine)
        .environmentObject(envStore.activeStore.prefs)
        .environmentObject(envStore)
        .environmentObject(scheduler)
        .environment(\.managedObjectContext, envStore.activeStore.persistence.viewContext)
        .frame(minWidth: 1100, minHeight: 700)
        // Re-key on environment switch — forces ContentView to re-init with new initialTab
        .id(envStore.activeEnvironmentId)
        .onAppear {
          appDelegate.envStore  = envStore
          appDelegate.scheduler = scheduler
          scheduler.start(environmentStore: envStore)
          runMode.applyInitialPolicy()
        }
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: true))
    .onChange(of: envStore.activeSyncEngine.isRunning) { _, _ in }
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appInfo) {
        Button("About AxMJamfSync") {
          let credits = NSMutableAttributedString(
            string: "Developed by ",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
          )
          credits.append(NSAttributedString(
            string: "Karthikeyan Marappan",
            attributes: [
              .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
              .link: URL(string: "https://www.linkedin.com/in/bewithkarthi/")!
            ]
          ))
          NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "AxMJamfSync",
            .credits:         credits
          ])
        }
      }
      SidebarCommands()
      CommandGroup(replacing: .help) {
        Button("AxM Jamf Sync Help") {
          NSWorkspace.shared.open(URL(string: "https://github.com/karthikeyan-mac/AxMJamfSync")!)
        }
        .keyboardShortcut("?", modifiers: .command)
        Divider()
        Button("Show Sync Log in Finder") { NSWorkspace.shared.open(logDirURL) }
          .keyboardShortcut("l", modifiers: [.command, .shift])
        Button("Open Sync Log in Console") { NSWorkspace.shared.open(logFileURL) }
      }
    }

    MenuBarExtra {
      MenuBarContentView()
        .environmentObject(envStore)
        .environmentObject(scheduler)
    } label: {
      Image(nsImage: Self.menuBarIcon)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView()
        .environmentObject(scheduler)
        .environmentObject(runMode)
    }
    .windowResizability(.contentMinSize)
  }
}

// MARK: - Menu bar content

private struct MenuBarContentView: View {
  @EnvironmentObject private var envStore:  EnvironmentStore
  @EnvironmentObject private var scheduler: SyncScheduler
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    } label: {
      Label("Open AxM Jamf Sync", systemImage: "macwindow")
    }

    Button {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
      envStore.enqueueMultiSync(ids: envStore.environments.map(\.id))
    } label: {
      Label("Sync All Now", systemImage: "arrow.triangle.2.circlepath")
    }
    .disabled(envStore.isSyncQueueRunning || envStore.environments.isEmpty)

    if scheduler.isEnabled {
      Divider()
      if let next = scheduler.nextFireDate {
        Text("Next Sync: \(next.formatted(date: .abbreviated, time: .shortened))")
      }
      if let last = scheduler.lastFireDate {
        Text("Last Sync: \(last.formatted(date: .abbreviated, time: .shortened))")
      }
    }

    Divider()

    SettingsLink {
      Label("Settings…", systemImage: "gearshape")
    }
    .keyboardShortcut(",", modifiers: .command)

    Divider()

    Button("Quit AxM Jamf Sync") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
  var envStore:  EnvironmentStore?
  var scheduler: SyncScheduler?

  /// Warns before quitting (not closing the window) while a schedule is active —
  /// Cmd-Q and the Quit menu item both route through this, window close does not.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let scheduler, scheduler.isEnabled else { return .terminateNow }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Quit AxM Jamf Sync?"
    alert.informativeText = scheduler.launchAtLoginEnabled
      ? "A sync schedule is active. Quitting pauses it until the app reopens — it will resume automatically at login."
      : "A sync schedule is active. Quitting pauses it until you reopen the app. Enable Launch at Login in Settings to keep it running automatically."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Clear AxM and Jamf tokens for the active environment
    if let envId = envStore?.activeEnvironmentId {
      KeychainService.clearAxMTokenForEnv(id: envId)
      KeychainService.clearJamfTokenForEnv(id: envId)
    }
    // Also clear v1 flat token keys (no-op if already migrated)
    let scope = envStore?.activeStore.axmCredentials.scope ?? .business
    KeychainService.clearAxMToken(for: scope)
    KeychainService.clearAxMToken(for: scope == .school ? .business : .school)
    KeychainService.clearJamfToken()
    os_log(.default, "[AppDelegate] Tokens cleared from Keychain on app quit.")
  }
}
