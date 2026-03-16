// AxMJamfSyncApp.swift
// @main entry point.
// © 2026 Karthikeyan Marappan. All rights reserved. Initialises AppStore, SyncEngine, LogService.
// Menu bar: Help menu, About panel, Quit (clears Jamf token on exit).

import SwiftUI
import CoreData
import AppKit

@main
struct AxMJamfSyncApp: App {

    @StateObject private var store = AppStore()
    @StateObject private var syncEngine = SyncEngine()

    // AppDelegate handles applicationWillTerminate — the only reliable hook for
    // clearing the Apple token when the app quits or is force-killed via Dock.
    // SwiftUI's .onDisappear / scenePhase do not fire on force-quit.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Sandbox-safe log paths (avoids @MainActor LogService.shared in Commands)
    private var logFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AxMJamfSync/sync.log")
    }
    private var logDirURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AxMJamfSync")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appEngine: syncEngine)
                .environmentObject(store)
                .environmentObject(syncEngine)
                .environmentObject(store.prefs)
                .environment(\.managedObjectContext,
                             PersistenceController.shared.viewContext)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    // Give the delegate a reference to store so it can read the active scope
                    appDelegate.store = store
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .onChange(of: syncEngine.isRunning) { _, _ in }
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
                Button("Show Sync Log in Finder") {
                    NSWorkspace.shared.open(logDirURL)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Open Sync Log in Console") {
                    NSWorkspace.shared.open(logFileURL)
                }
            }
        }
    }
}

// MARK: - App Delegate
/// Handles applicationWillTerminate to clear the Apple access token from Keychain.
/// This is the correct hook — SwiftUI lifecycle events don't fire on force-quit.
/// Note: SIGKILL (Activity Monitor "Force Quit") cannot be caught by any hook.
/// applicationWillTerminate covers: Cmd+Q, Dock quit, and normal termination.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Injected by the App scene's .onAppear so we can read the current scope.
    var store: AppStore?

    func applicationWillTerminate(_ notification: Notification) {
        // Clear the Apple AxM token from Keychain on clean quit.
        // The token has a 1-hour TTL from Apple — leaving it in Keychain is fine for
        // back-to-back runs (we want reuse), but clearing on quit prevents a stale token
        // from being loaded on next launch if the system clock drifts or the token was
        // already invalidated server-side by an admin rotating the credentials.
        // Jamf token is separately invalidated via the /invalidate-token API call
        // in SyncEngine's end-of-run cleanup.
        let scope = store.map { $0.axmCredentials.scope } ?? .business
        KeychainService.clearAxMToken(for: scope)
        // Also clear the other scope defensively (no-op if no token stored)
        let otherScope: AxMScope = scope == .school ? .business : .school
        KeychainService.clearAxMToken(for: otherScope)
        print("[AppDelegate] Apple AxM token cleared from Keychain on app quit.")
    }
}
