// ContentView.swift
// Root TabView — Dashboard / Devices / Sync / Setup / Export.
// Tab badges: Sync tab shows live progress badge while sync is running.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab: Tab = .setup

    /// Sync tab is enabled once at least one auth test has succeeded OR there is cached data
    /// Sync tab is accessible only when there is cached data OR when the user
    /// has successfully tested at least one auth endpoint this session.
    /// After wipeCache(), both auth statuses are reset to .idle, so this returns false
    /// until the user re-tests credentials — enforcing Setup-first on reset.
    private var syncEnabled: Bool {
        // hasData: previous sync exists → allow re-sync
        if store.hasData { return true }
        // Auth tested this session (not persisted across launches) → allow first sync
        switch store.axmAuthStatus {
        case .success: return true
        default: break
        }
        switch store.jamfAuthStatus {
        case .success: return true
        default: break
        }
        return false
    }

    enum Tab: String, CaseIterable {
        case setup     = "Setup"
        case sync      = "Sync"
        case dashboard = "Dashboard"
        case devices   = "Devices"
        case export    = "Export"

        var icon: String {
            switch self {
            case .setup:     return "gearshape.2.fill"
            case .sync:      return "arrow.triangle.2.circlepath.circle.fill"
            case .dashboard: return "chart.bar.xaxis"
            case .devices:   return "desktopcomputer"
            case .export:    return "square.and.arrow.up"
            }
        }
    }

    // Shared SyncEngine — created at app level and passed in so tokens can be
    // invalidated on app quit.
    @ObservedObject var appEngine: SyncEngine

    // Which tabs are unlocked
    private func isTabAllowed(_ tab: Tab) -> Bool {
        switch tab {
        case .setup:     return true
        case .sync:      return syncEnabled
        case .dashboard, .devices, .export: return store.hasData
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeaderBar()

            // Custom tab bar replaces native TabView entirely.
            // SwiftUI's TabView is backed by NSTabView (AppKit). On macOS 15/26,
            // the AppKit sendAction that fires on every tab click re-evaluates ALL
            // .tabItem closures and triggers simultaneous layout of all tab content
            // views, which AttributeGraph cannot resolve when views observe different
            // ObservableObjects (engine vs store). The custom bar is pure SwiftUI —
            // no NSTabView, no .tabItem, no AppKit sendAction involved.
            AppTabBar(
                tabs: Tab.allCases,
                selected: $selectedTab,
                isAllowed: isTabAllowed,
                isRunning: appEngine.isRunning
            )

            Divider()

            // Content area — only the selected tab is in the view tree.
            // ZStack-with-opacity is intentionally avoided; pure if/else means
            // unselected views are fully deallocated, preventing background
            // @ObservedObject updates from triggering off-screen renders.
            Group {
                switch selectedTab {
                case .setup:
                    SetupView(engine: appEngine,
                              navigateToSync: { selectedTab = .sync })
                case .sync:
                    if isTabAllowed(.sync) {
                        SyncView(engine: appEngine)
                    } else {
                        LockedTabPlaceholder(
                            reason: store.hasData
                                ? "Complete your credential setup in Setup to run a sync."
                                : "Configure your Apple and Jamf credentials in Setup, then test authentication to unlock this tab."
                        )
                    }
                case .dashboard:
                    if store.hasData { DashboardView() }
                    else { LockedTabPlaceholder(reason: "Run your first sync to see device statistics and coverage summaries here.") }
                case .devices:
                    if store.hasData { DevicesView() }
                    else { LockedTabPlaceholder(reason: "Run your first sync to browse, filter, and search all your devices here.") }
                case .export:
                    if store.hasData { ExportView() }
                    else { LockedTabPlaceholder(reason: "Run your first sync to export your device and coverage data as a CSV file.") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectedTab = store.hasData ? .dashboard : .setup
        }
        .onChange(of: store.hasData) { _, newHasData in
            if newHasData {
                if selectedTab == .setup { selectedTab = .dashboard }
            } else {
                selectedTab = .setup
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            appEngine.stop()
        }
    }
}

// MARK: - Reusable label with info popover
// MARK: - Structured info content model
/// Passed to InfoButton / InfoLabel to produce a formatted popover card
/// instead of a plain paragraph.
struct InfoContent {
    let icon:    String          // SF Symbol name
    let title:   String          // Bold heading line
    let summary: String          // One-sentence plain-language description
    var bullets: [String] = []   // Optional "key things to know" bullet points
}

struct InfoLabel: View {
    let text: String
    let info: InfoContent

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.callout).foregroundStyle(.primary)
            InfoButton(info: info)
        }
    }
}

struct InfoButton: View {
    let info: InfoContent
    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .top) {
            InfoPopoverCard(info: info)
        }
    }
}

struct InfoPopoverCard: View {
    let info: InfoContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row: icon + title
            HStack(spacing: 8) {
                Image(systemName: info.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(info.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Divider()

            // Summary sentence
            Text(info.summary)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Optional bullet points
            if !info.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(info.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .padding(.top, 1)
                            Text(bullet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(minWidth: 260, maxWidth: 320)
    }
}

// MARK: - Section card container
struct CardSection<Content: View>: View {
    let title: String
    let icon:  String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) { content }.padding(.top, 4)
        } label: {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(.primary)
        }
    }
}

// MARK: - Stat card
struct StatCard: View {
    let title:    String
    let value:    String
    let icon:     String
    let color:    Color
    var subtitle: String = ""
    var tooltip:  InfoContent? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.title3).foregroundStyle(color)
                Spacer()
                if let tooltip {
                    InfoButton(info: tooltip)
                }
            }
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(title).font(.callout).foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.25), lineWidth: 1))
    }
}


// MARK: - Custom Tab Bar (truly blocks locked tabs — .disabled on TabView items doesn't work on macOS)

// MARK: - Locked tab placeholder
struct LockedTabPlaceholder: View {
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Tab Not Available Yet")
                .font(.headline)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text("Go to the **Setup** tab to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct AppTabBar: View {
    let tabs:      [ContentView.Tab]
    @Binding var selected: ContentView.Tab
    let isAllowed: (ContentView.Tab) -> Bool
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                let allowed = isAllowed(tab)
                let isSelected = selected == tab

                Button {
                    guard allowed else { return }   // ← hard block: ignore the click
                    selected = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        Text(tab == .sync && isRunning ? "Sync ●" : tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(
                        isSelected  ? Color.accentColor :
                        !allowed    ? Color.secondary.opacity(0.35) :
                                      Color.secondary
                    )
                    .background(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    // Show a "lock" cursor / no-entry tooltip when locked
                    .help(allowed ? "" : "This tab is not available yet — run your first sync before you can use it. Go to the Dashboard tab and press Run Sync to download your devices.")
                }
                .buttonStyle(.plain)
                .disabled(!allowed)   // accessibility / keyboard only — click still blocked above
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - App header bar (shown at top of every tab)
struct AppHeaderBar: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAbout = false

    private var appTitle: String {
        switch store.axmCredentials.scope {
        case .business: return "ABM Jamf Sync"
        case .school:   return "ASM Jamf Sync"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9))

            Text(appTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.primary)

            Button {
                showAbout = true
            } label: {
                Image(systemName: "info.circle.fill").font(.body).foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .help("About this app — tap to see the version number, build date, and where to get help")
            .popover(isPresented: $showAbout, arrowEdge: .bottom) {
                AboutPopover()
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct AboutPopover: View {
    @EnvironmentObject private var store: AppStore

    private var scopeFull: String { store.axmCredentials.scope == .school ? "Apple School Manager (ASM)" : "Apple Business Manager (ABM)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AxM Jamf Sync")
                        .font(.headline)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Syncs \(scopeFull) device inventory with Jamf Pro — including AppleCare coverage data and warranty write-back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 4) {
                Text("Developed by").font(.caption).foregroundStyle(.secondary)
                Link("Karthikeyan Marappan",
                     destination: URL(string: "https://www.linkedin.com/in/bewithkarthi/")!)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Badge
struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}
