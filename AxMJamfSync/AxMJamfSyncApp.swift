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

  @StateObject private var envStore = EnvironmentStore()
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

  var body: some Scene {
    WindowGroup {
      ContentView(appEngine: envStore.activeSyncEngine, initialTab: envStore.initialTab)
        .environmentObject(envStore.activeStore)
        .environmentObject(envStore.activeSyncEngine)
        .environmentObject(envStore.activeStore.prefs)
        .environmentObject(envStore)
        .environment(\.managedObjectContext, envStore.activeStore.persistence.viewContext)
        .frame(minWidth: 1100, minHeight: 700)
        // Re-key on environment switch — forces ContentView to re-init with new initialTab
        .id(envStore.activeEnvironmentId)
        .onAppear {
          appDelegate.envStore = envStore
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
  }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
  var envStore: EnvironmentStore?

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
