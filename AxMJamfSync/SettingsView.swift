// SettingsView.swift
// Content for the app's Settings scene (⌘,) — General and Schedule tabs.
// Uses Form(.grouped), the modern macOS Settings-window idiom, distinct from the
// GroupBox-card style used in the main window's tabs.

import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsTab()
        .tabItem { Label("General", systemImage: "gearshape") }
      ScheduleSettingsTab()
        .tabItem { Label("Schedule", systemImage: "clock.badge.checkmark") }
    }
    .frame(minWidth: 560, idealWidth: 560, minHeight: 420, idealHeight: 460)
    .scenePadding()
  }
}

// MARK: - General

private struct GeneralSettingsTab: View {
  @EnvironmentObject private var scheduler: SyncScheduler
  @EnvironmentObject private var runMode:   AppRunModeController

  var body: some View {
    Form {
      Section {
        Toggle(isOn: Binding(
          get: { scheduler.launchAtLoginEnabled },
          set: { scheduler.setLaunchAtLogin($0) }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Launch at Login")
            Text("Opens AxM Jamf Sync automatically when you log in, so scheduled syncs can run unattended.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section {
        Toggle(isOn: Binding(
          get: { runMode.dockIconVisible },
          set: { runMode.setDockIconVisible($0) }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Show in Dock")
            Text("Turn off to run AxM Jamf Sync as a menu bar–only app, with no Dock icon or Cmd-Tab entry. The menu bar icon stays available either way.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { scheduler.refreshLaunchAtLoginStatus() }
    .alert("Couldn't Update Login Item", isPresented: Binding(
      get: { scheduler.launchAtLoginError != nil },
      set: { if !$0 { scheduler.launchAtLoginError = nil } }
    )) {
      Button("OK") { scheduler.launchAtLoginError = nil }
    } message: {
      Text(scheduler.launchAtLoginError ?? "")
    }
  }
}

// MARK: - Schedule

private struct ScheduleSettingsTab: View {
  @EnvironmentObject private var scheduler: SyncScheduler
  @State private var showLaunchAtLoginPrompt = false

  var body: some View {
    Form {
      Section {
        Toggle("Automatically Sync", isOn: Binding(
          get: { scheduler.isEnabled },
          set: { newValue in
            scheduler.setEnabled(newValue)
            if newValue, !scheduler.launchAtLoginEnabled {
              showLaunchAtLoginPrompt = true
            }
          }
        ))
      } footer: {
        Text("Applies to every environment. Each scheduled run syncs all environments one at a time, the same as Sync All.")
      }

      if scheduler.isEnabled {
        Section {
          cronEditor
        }

        Section {
          LabeledContent("Next Sync") {
            Text(scheduler.nextFireDate.map(Self.df.string(from:)) ?? "—")
              .foregroundStyle(.secondary)
          }
          if let last = scheduler.lastFireDate {
            LabeledContent("Last Scheduled Run") {
              Text(Self.df.string(from: last))
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .alert("Enable Launch at Login?", isPresented: $showLaunchAtLoginPrompt) {
      Button("Enable") { scheduler.setLaunchAtLogin(true) }
      Button("Not Now", role: .cancel) { }
    } message: {
      Text("So scheduled syncs keep running even after you quit AxM Jamf Sync, it can open automatically when you log in. You can change this anytime in the General tab.")
    }
  }

  @ViewBuilder
  private var cronEditor: some View {
    FriendlyCronBuilderView()
      .padding(.vertical, 2)

    DisclosureGroup("Advanced (Raw Cron Expression)") {
      VStack(alignment: .leading, spacing: 6) {
        TextField("Cron Expression", text: Binding(
          get: { scheduler.cronText },
          set: { scheduler.setCronText($0) }
        ))
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .help("Standard 5-field cron syntax: minute hour day-of-month month day-of-week")

        if let error = scheduler.cronError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .padding(.top, 6)
    }
  }

  private static let df: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()
}
