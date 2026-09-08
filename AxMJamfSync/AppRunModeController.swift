// AppRunModeController.swift
// Lets the user choose, at runtime, whether AxM Jamf Sync shows a Dock icon
// (normal app) or runs as a menu-bar-only accessory (no Dock presence, no
// Cmd-Tab entry). The MenuBarExtra scene itself is always present in either
// mode — this only toggles NSApplication's activation policy.
//
// Flat UserDefaults key — app-wide, like SyncScheduler's settings.

import AppKit
import Combine

private enum RunModePrefKey {
  static let dockIconVisible = "runMode.dockIconVisible"
}

@MainActor
final class AppRunModeController: ObservableObject {

  private let ud = UserDefaults.standard

  @Published private(set) var dockIconVisible: Bool {
    didSet {
      ud.set(dockIconVisible, forKey: RunModePrefKey.dockIconVisible)
      apply()
    }
  }

  init() {
    self.dockIconVisible = ud.object(forKey: RunModePrefKey.dockIconVisible) != nil
      ? ud.bool(forKey: RunModePrefKey.dockIconVisible) : true
  }

  /// Call once at launch, after init, to put NSApp in the persisted state.
  func applyInitialPolicy() {
    apply()
  }

  func setDockIconVisible(_ visible: Bool) {
    dockIconVisible = visible
  }

  private func apply() {
    if dockIconVisible {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
