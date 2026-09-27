// DashboardView.swift
// Dashboard tab — live summary tiles and ring chart.
//
// Tiles: Total / AxM-Only / Jamf-Only / In Both / In Warranty / Out of Warranty / No Coverage.
// Ring chart: proportional arcs for coverage status. Animates on data change.
// Stats computed by AppStore.recomputeStats() (single O(n) pass).

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store:  AppStore
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var prefs:  AppPreferences
    var navigateToDevices: () -> Void = {}

    private var scopeFull: String { store.axmCredentials.scope.label }

    // A system counts as "in play" if it's configured, or if there's already cached
    // data from a previous sync — so the option doesn't vanish mid-session just
    // because someone is mid-edit clearing credentials in Setup.
    private var hasAxmConfigured: Bool {
        (!store.axmCredentials.clientId.isEmpty && !store.axmCredentials.keyId.isEmpty) || store.stats.axmTotal > 0
    }
    private var hasJamfConfigured: Bool {
        (!store.jamfCredentials.url.isEmpty && !store.jamfCredentials.clientId.isEmpty) || store.stats.jamfTotal > 0
    }

    // Only offer "Default" (the mixed reconciliation view) when both systems are
    // actually in play — with just one system configured there's nothing for the
    // mixed view to reconcile, so it would just be a redundant extra click in front
    // of the one dashboard that has any data. With only one system configured, that
    // system's own focus mode is the only mode offered — and effectiveFocus below
    // resolves straight to it, with no picker shown at all.
    private var availableFocusModes: [DashboardFocus] {
        switch (hasAxmConfigured, hasJamfConfigured) {
        case (true, true):   return [.common, .axm, .jamf]
        case (true, false):  return [.axm]
        case (false, true):  return [.jamf]
        case (false, false): return [.common]  // nothing configured yet — only the default view makes sense
        }
    }

    // Falls back to the first available mode if the persisted choice's system is no
    // longer in play — e.g. Jamf credentials were cleared after Jamf focus had been
    // selected, or the other system just got disconnected leaving only one mode.
    private var effectiveFocus: DashboardFocus {
        availableFocusModes.contains(prefs.dashboardFocus) ? prefs.dashboardFocus : (availableFocusModes.first ?? .common)
    }

    private var headerSubtitle: String {
        switch effectiveFocus {
        case .common: return "Live overview of synced devices, AppleCare coverage, and Jamf Update status."
        case .axm:    return "What \(scopeFull) knows about your fleet."
        case .jamf:   return "What Jamf Pro knows about your fleet."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Header + Focus picker + Sync button
                HStack(alignment: .center) {
                    Text(headerSubtitle)
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if availableFocusModes.count > 1 {
                        focusMenu
                    }
                    GlobalSyncButton(engine: engine)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                switch effectiveFocus {
                case .common: CommonDashboardContent(navigateToDevices: navigateToDevices)
                case .axm:    AxMDashboardContent(navigateToDevices: navigateToDevices)
                case .jamf:   JamfDashboardContent(navigateToDevices: navigateToDevices)
                }

                Spacer(minLength: 24)
            }
        }
        .background(.background)
    }

    // MARK: - Focus picker
    // Only ever shown when there's an actual choice to make (availableFocusModes.count > 1).
    private var focusMenu: some View {
        Menu {
            ForEach(availableFocusModes) { focus in
                Button {
                    prefs.dashboardFocus = focus
                } label: {
                    Label(focus.label, systemImage: focus.icon)
                }
            }
        } label: {
            Label(effectiveFocus.label, systemImage: effectiveFocus.icon)
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which system's data the Dashboard focuses on")
    }
}

// MARK: - Common Dashboard content (today's mixed reconciliation view — unchanged)
struct CommonDashboardContent: View {
    @EnvironmentObject private var store: AppStore
    var navigateToDevices: () -> Void = {}

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }
    private var scopeFull:   String { store.axmCredentials.scope.label }

    var s:  DashboardStats { store.stats }              // unfiltered — sync status / run counters only
    var fs: DashboardStats { store.commonDashboardStats } // facet-filtered — every breakdown card

    // Clears every filter, applies the drill-down passed in, then jumps to Devices —
    // the one place every tap target in this view funnels through. Any facet not
    // overridden by the tapped dimension carries forward, so the Devices list always
    // matches the number that was tapped — see ARCHITECTURE.md "Dashboard facet
    // filters must compose into drill-downs".
    private func drillDown(source: DeviceSource? = nil, coverage: CoverageStatus? = nil,
                            wb: WBStatus? = nil, mdmServer: String? = nil,
                            axmStatus: String? = nil, jamfManaged: Bool? = nil,
                            expiringWindow: String? = nil) {
        store.drillDown(source: source ?? store.commonDashboardSourceFacet,
                         coverage: coverage ?? store.commonDashboardCoverageFacet,
                         wb: wb ?? store.commonDashboardWbFacet,
                         mdmServer: mdmServer,
                         axmStatus: axmStatus,
                         jamfManaged: jamfManaged ?? store.commonDashboardManagedFacet,
                         expiringWindow: expiringWindow)
        navigateToDevices()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

                // MARK: Facet filter bar — dashboard-only lens, independent of the
                // Devices tab's own filters. Every card below reads from `fs`.
                CommonDashboardFacetBar()
                    .padding(.horizontal, 24)

                // MARK: Overall totals row
                HStack(spacing: 12) {
                    DashboardDrillDown(action: { drillDown() }) {
                        StatCard(title: "Total Devices",  value: "\(fs.total)",   icon: "desktopcomputer",         color: .primary,
                               tooltip: InfoContent(
                                   icon: "desktopcomputer", title: "Total Devices",
                                   summary: "All unique devices found across both Apple and Jamf, combined.",
                                   bullets: ["A device is counted once even if it appears in both systems.",
                                             "This is the sum of In Both + \(scopeAbbrev) Only + Jamf Only."]))
                    }
                    DashboardDrillDown(action: { drillDown(source: .both) }) {
                        StatCard(title: "In Both",         value: "\(fs.both)",    icon: "checkmark.circle.fill",   color: .green,
                               tooltip: InfoContent(
                                   icon: "checkmark.circle.fill", title: "In Both",
                                   summary: "Devices enrolled in Apple Business/School Manager AND present in Jamf Pro.",
                                   bullets: ["These are fully managed devices — Apple has them registered and Jamf tracks them.",
                                             "Only devices In Both can have warranty dates written back to Jamf."]))
                    }
                    DashboardDrillDown(action: { drillDown(source: .axmOnly) }) {
                        StatCard(title: store.axmCredentials.scope == .school ? "ASM Only" : "ABM Only",        value: "\(fs.axmOnly)", icon: "applelogo",               color: .blue,
                               tooltip: InfoContent(
                                   icon: "applelogo", title: store.axmCredentials.scope == .school ? "ASM Only" : "ABM Only",
                                   summary: "Devices registered in Apple Business/School Manager but not yet enrolled in Jamf Pro.",
                                   bullets: ["These may be new devices awaiting Jamf enrollment, or devices removed from Jamf but still in Apple's system.",
                                             "Warranty coverage can still be fetched for these devices, but dates cannot be written to Jamf until they enrol."]))
                    }
                    DashboardDrillDown(action: { drillDown(source: .jamfOnly) }) {
                        StatCard(title: "Jamf Only",       value: "\(fs.jamfOnly)",icon: "server.rack",             color: .orange,
                               tooltip: InfoContent(
                                   icon: "server.rack", title: "Jamf Only",
                                   summary: "Devices that exist in Jamf Pro but are not registered in Apple Business/School Manager.",
                                   bullets: ["Common for devices enrolled manually in Jamf, or Apple-removed devices still tracked in Jamf.",
                                             "No Apple warranty data can be fetched for these devices via this app."]))
                    }
                }
                .padding(.horizontal, 24)

                // MARK: Three section grid
                HStack(alignment: .top, spacing: 16) {

                    // --- AxM section ---
                    CardSection(title: scopeFull, icon: "applelogo") {
                        DashStatRow(label: "Total Devices",  value: fs.axmTotal,    color: .primary,
                            tooltip: InfoContent(icon: "applelogo", title: "Total in Apple Manager",
                                summary: "All devices currently registered under your Apple Business or School Manager account.",
                                bullets: ["Includes Active and Released devices.", "Fetched directly from Apple's device API during each sync."]))
                        DashboardDrillDown(action: { drillDown(axmStatus: "ACTIVE") }) {
                            DashStatRow(label: "Active",          value: fs.axmActive,   color: .green,
                                tooltip: InfoContent(icon: "checkmark.circle", title: "Active in Apple Manager",
                                    summary: "Devices currently enrolled and active in your Apple Business or School Manager account.",
                                    bullets: ["These are devices Apple recognises as part of your organisation.", "Warranty and AppleCare data can be fetched for all active devices."]))
                        }
                        DashboardDrillDown(action: { drillDown(axmStatus: "RELEASED") }) {
                            DashStatRow(label: "Released",        value: fs.axmReleased, color: .secondary,
                                        tooltip: InfoContent(
                                            icon:    "clock.arrow.circlepath",
                                            title:   "Released Devices",
                                            summary: "Devices that were removed or unenrolled from \(scopeAbbrev).",
                                            bullets: [
                                                "Their records are kept for history — you can still see them in the Devices tab.",
                                                "They are no longer actively managed through \(scopeAbbrev)."
                                            ]
                                        ))
                        }
                        Divider()
                        SyncTimestampRow(label: "Last sync", timestamp: s.lastAxmSync)
                        if s.runAxmFetched > 0 {
                            DashStatRow(label: "Fetched this run", value: s.runAxmFetched, color: .blue)
                        }
                    }

                    // --- Jamf section ---
                    CardSection(title: "Jamf Pro", icon: "server.rack") {
                        DashStatRow(label: "Total Devices (Jamf)", value: fs.jamfTotal,     color: .primary,
                            tooltip: InfoContent(icon: "server.rack", title: "Total in Jamf Pro",
                                summary: "All computer records currently in your Jamf Pro inventory.",
                                bullets: ["Fetched from Jamf during each sync.", "Includes both managed and unmanaged computers."]))
                        DashboardDrillDown(action: { drillDown(jamfManaged: true) }) {
                            DashStatRow(label: "Managed",          value: fs.jamfManaged,   color: .green,
                                tooltip: InfoContent(icon: "checkmark.shield", title: "Managed by Jamf",
                                    summary: "Computers actively managed by Jamf Pro — Jamf can push policies, apps, and settings to these devices.",
                                    bullets: ["These are the devices this app can write warranty dates back to.", "Unmanaged devices cannot receive Jamf configuration profiles or policies."]))
                        }
                        DashboardDrillDown(action: { drillDown(jamfManaged: false) }) {
                            DashStatRow(label: "Unmanaged",        value: fs.jamfUnmanaged, color: .orange,
                                tooltip: InfoContent(icon: "exclamationmark.shield", title: "Unmanaged in Jamf",
                                    summary: "Computers present in Jamf but not currently under active management.",
                                    bullets: ["These devices may have had their MDM profile removed, or were enrolled manually without full MDM.",
                                             "Warranty dates can still be written back to Jamf inventory records for these devices."]))
                        }
                        Divider()
                        SyncTimestampRow(label: "Last sync", timestamp: s.lastJamfSync)
                        if s.runJamfFetched > 0 {
                            DashStatRow(label: "Fetched this run", value: s.runJamfFetched, color: .blue)
                        }
                    }

                    // --- Write-back section ---
                    CardSection(title: "Jamf Update", icon: "arrow.up.to.line.circle.fill") {
                        DashboardDrillDown(action: { drillDown(wb: .synced) }) {
                            DashStatRow(label: "Synced to Jamf", value: fs.wbSynced,  color: .green,
                                tooltip: InfoContent(icon: "checkmark.circle.fill", title: "Synced to Jamf",
                                    summary: "Devices whose warranty date has been successfully written to Jamf Pro.",
                                    bullets: ["The warranty end date and AppleCare ID in Jamf now match what Apple's API returned.", "These devices will not be updated again unless the warranty data changes."]))
                        }
                        DashboardDrillDown(action: { drillDown(wb: .pending) }) {
                            DashStatRow(label: "Pending",         value: fs.wbPending, color: .orange,
                                tooltip: InfoContent(icon: "clock.fill", title: "Pending Jamf Update",
                                    summary: "Devices with new warranty data from Apple that has not yet been written to Jamf Pro.",
                                    bullets: ["These will be updated on the next sync run.", "A high pending count after a sync usually means the Jamf Update step was skipped or aborted."]))
                        }
                        DashboardDrillDown(action: { drillDown(wb: .failed) }) {
                            DashStatRow(label: "Failed",          value: fs.wbFailed,  color: .red,
                                        tooltip: InfoContent(
                                            icon:    "exclamationmark.triangle.fill",
                                            title:   "Write-back Failed",
                                            summary: "The warranty date could not be saved into Jamf Pro for these devices.",
                                            bullets: [
                                                "Open the Devices tab and search for the affected serial number.",
                                                "Check the Note column for the specific error reason.",
                                                "Common causes: Jamf permission issue, device not found, or API timeout."
                                            ]
                                        ))
                        }
                        DashboardDrillDown(action: { drillDown(wb: .skipped) }) {
                            DashStatRow(label: "Skipped",         value: fs.wbSkipped, color: .secondary,
                                        tooltip: InfoContent(
                                            icon:    "minus.circle.fill",
                                            title:   "Skipped Devices",
                                            summary: "These devices were skipped during the Jamf warranty update step.",
                                            bullets: [
                                                "Either the device has no warranty date to write back.",
                                                "Or the serial number could not be matched to a record in Jamf Pro."
                                            ]
                                        ))
                        }
                        if s.runWbSynced > 0 || s.runWbFailed > 0 {
                            Divider()
                            if s.runWbSynced > 0 {
                                DashStatRow(label: "Pushed this run", value: s.runWbSynced, color: .green)
                            }
                            if s.runWbFailed > 0 {
                                DashStatRow(label: "Failed this run", value: s.runWbFailed, color: .red)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)

                // MARK: MDM Assignment — full-width, only shown when data exists
                if fs.mdmAssigned > 0 || fs.mdmUnassigned > 0 {
                    CardSection(title: "MDM Assignment", icon: "server.rack") {
                        HStack(alignment: .top, spacing: 16) {
                            // Left: assigned / unassigned stat cards
                            HStack(spacing: 12) {
                                DashboardDrillDown(action: { drillDown(mdmServer: AppStore.mdmAssignedSentinel) }) {
                                    CoverageStatCard(
                                        title: "Assigned",
                                        value: fs.mdmAssigned,
                                        total: fs.axmTotal,
                                        icon:  "checkmark.circle.fill",
                                        color: .purple,
                                        tooltip: InfoContent(
                                            icon:    "checkmark.circle.fill",
                                            title:   "MDM Assigned",
                                            summary: "AxM devices assigned to a Device Management Service (MDM server).",
                                            bullets: [
                                                "These devices are enrolled in an MDM server in \(scopeAbbrev).",
                                                "Breakdown by server is shown on the right."
                                            ]
                                        )
                                    )
                                }
                                DashboardDrillDown(action: { drillDown(mdmServer: AppStore.mdmUnassignedSentinel) }) {
                                    CoverageStatCard(
                                        title: "Unassigned",
                                        value: fs.mdmUnassigned,
                                        total: fs.axmTotal,
                                        icon:  "questionmark.circle.fill",
                                        color: .secondary,
                                        tooltip: InfoContent(
                                            icon:    "questionmark.circle.fill",
                                            title:   "MDM Unassigned",
                                            summary: "AxM devices not assigned to any Device Management Service.",
                                            bullets: [
                                                "These devices are registered in \(scopeAbbrev) but have not been assigned to an MDM server.",
                                                "Use the Devices tab to find and review these devices."
                                            ]
                                        )
                                    )
                                }
                            }

                            // Right: per-server breakdown
                            if !fs.mdmServerBreakdown.isEmpty {
                                Divider()
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("MDM Servers")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.bottom, 2)
                                    let sorted = fs.mdmServerBreakdown.sorted { $0.value > $1.value }
                                    ForEach(sorted, id: \.key) { name, count in
                                        DashboardDrillDown(action: { drillDown(mdmServer: name) }) {
                                            DashStatRow(label: name, value: count, color: .purple)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // MARK: Expiring Soon — active coverage only, bucketed by days until
                // axmCoverageEndDate. Non-overlapping windows so the three counts can
                // be read individually without double-counting a device across cards.
                CardSection(title: "Expiring Soon", icon: "clock.badge.exclamationmark") {
                    HStack(spacing: 12) {
                        DashboardDrillDown(action: { drillDown(expiringWindow: "0–30") }) {
                            CoverageStatCard(
                                title:    "Next 30 Days",
                                value:    fs.axmExpiring30,
                                total:    fs.axmTotal,
                                icon:     "exclamationmark.shield.fill",
                                color:    .red
                            )
                        }
                        DashboardDrillDown(action: { drillDown(expiringWindow: "31–60") }) {
                            CoverageStatCard(
                                title:    "31–60 Days",
                                value:    fs.axmExpiring60,
                                total:    fs.axmTotal,
                                icon:     "clock.badge.exclamationmark.fill",
                                color:    .orange
                            )
                        }
                        DashboardDrillDown(action: { drillDown(expiringWindow: "61–90") }) {
                            CoverageStatCard(
                                title:    "61–90 Days",
                                value:    fs.axmExpiring90,
                                total:    fs.axmTotal,
                                icon:     "clock.fill",
                                color:    .yellow,
                                tooltip:  InfoContent(
                                icon:    "clock.fill",
                                title:   "Coverage Expiring in 61–90 Days",
                                summary: "AppleCare or warranty coverage on these devices ends within the next 61 to 90 days.",
                                bullets: [
                                    "Only devices currently In Warranty are counted here.",
                                    "A device already Out of Warranty shows up there instead, not in this card."
                                ]
                            )
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)

                // MARK: Coverage ring chart — full width, generous height
                CardSection(title: "Coverage Distribution", icon: "chart.pie.fill") {
                    HStack(spacing: 64) {
                        CoverageRingView(active: fs.coverageActive, inactive: fs.coverageInactive,
                                          noPlan: fs.coverageNoPlan, neverFetched: fs.coverageNeverFetched)
                            .frame(width: 300, height: 300)

                        VStack(alignment: .leading, spacing: 24) {
                            DashboardDrillDown(action: { drillDown(coverage: .active) }) {
                                CoverageLegendRow(label: "In Warranty",      value: fs.coverageActive,       color: .green,     total: fs.axmTotal)
                            }
                            DashboardDrillDown(action: { drillDown(coverage: .inactive) }) {
                                CoverageLegendRow(label: "Out of Warranty",  value: fs.coverageInactive,     color: .red,       total: fs.axmTotal)
                            }
                            DashboardDrillDown(action: { drillDown(coverage: .noCoverage) }) {
                                CoverageLegendRow(label: "No Coverage Info", value: fs.coverageNoPlan,       color: .orange,    total: fs.axmTotal)
                            }
                            DashboardDrillDown(action: { drillDown(coverage: .notFetched) }) {
                                CoverageLegendRow(label: "Never Fetched",    value: fs.coverageNeverFetched, color: .secondary, total: fs.axmTotal)
                            }
                        }
                        .frame(minWidth: 260)

                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .frame(minHeight: 340)
                    Divider()
                    HStack {
                        SyncTimestampRow(label: "Last coverage sync", timestamp: s.lastCoverageSync)
                        Spacer()
                        if s.runCovFetched > 0 {
                            Text("\(s.runCovFetched) fetched this run")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 24)
        }
    }
}

// MARK: - Default dashboard facet filter bar
// Same dashboard-only lens as JamfDashboardFacetBar — setting these never touches
// the Devices tab's own filters. Source/Managed as segmented controls; Coverage and
// Write-back as icon-chip menus (more values than a segmented control comfortably fits).
private struct CommonDashboardFacetBar: View {
    @EnvironmentObject private var store: AppStore

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }
    private var matchCount:  Int    { store.commonDashboardStats.total }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Spacer()
                Picker("", selection: store.facetBinding(\.commonDashboardSourceFacet)) {
                    Text("All").tag(DeviceSource?.none)
                    Text("In Both").tag(DeviceSource?.some(.both))
                    Text("\(scopeAbbrev) Only").tag(DeviceSource?.some(.axmOnly))
                    Text("Jamf Only").tag(DeviceSource?.some(.jamfOnly))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)

                Picker("", selection: store.facetBinding(\.commonDashboardManagedFacet)) {
                    Text("All").tag(Bool?.none)
                    Text("Managed").tag(Bool?.some(true))
                    Text("Unmanaged").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                FacetChipMenu(icon: "shield.lefthalf.filled", title: "Coverage",
                              options: [("All", nil), ("In Warranty", CoverageStatus.active),
                                        ("Out of Warranty", .inactive), ("No Coverage Info", .noCoverage),
                                        ("Never Fetched", .notFetched)],
                              selection: store.facetBinding(\.commonDashboardCoverageFacet))

                FacetChipMenu(icon: "arrow.up.to.line.circle.fill", title: "Jamf Update",
                              options: [("All", nil), ("Synced", WBStatus.synced), ("Pending", .pending),
                                        ("Failed", .failed), ("Skipped", .skipped)],
                              selection: store.facetBinding(\.commonDashboardWbFacet))

                Spacer()
            }

            if store.commonDashboardFacetCount > 0 {
                HStack(spacing: 8) {
                    Spacer()
                    if let src = store.commonDashboardSourceFacet {
                        FacetActiveChip(label: src == .axmOnly ? "\(scopeAbbrev) Only" : src.label) {
                            store.commonDashboardSourceFacet = nil
                        }
                    }
                    if let m = store.commonDashboardManagedFacet {
                        FacetActiveChip(label: m ? "Managed" : "Unmanaged") { store.commonDashboardManagedFacet = nil }
                    }
                    if let cov = store.commonDashboardCoverageFacet {
                        FacetActiveChip(label: cov.label) { store.commonDashboardCoverageFacet = nil }
                    }
                    if let wb = store.commonDashboardWbFacet {
                        FacetActiveChip(label: wb.label) { store.commonDashboardWbFacet = nil }
                    }
                    Text("^[\(matchCount) device](inflect: true) match")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear All") { store.clearCommonDashboardFacets() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Shared Run/Stop Sync Button (used on Dashboard and any other tab)
/// Shared Run/Stop button — used on Setup, Sync, and Dashboard tabs.
/// Pass navigateToSync to auto-switch to the Sync tab on start (Setup only).
struct GlobalSyncButton: View {
    @ObservedObject        var engine:  SyncEngine
    @EnvironmentObject private var store:    AppStore
    @EnvironmentObject private var envStore: EnvironmentStore
    var navigateToSync: (() -> Void)? = nil
    @State private var showStopConfirm = false
    @State private var isHovering      = false

    private var canRun: Bool {
        let axm  = !store.axmCredentials.clientId.isEmpty && !store.axmCredentials.keyId.isEmpty
        let jamf = !store.jamfCredentials.url.isEmpty && !store.jamfCredentials.clientId.isEmpty
        return axm || jamf
    }

    private var isQueued: Bool {
        guard let envId = store.environmentId else { return false }
        return envStore.syncQueue.dropFirst().contains(envId)
    }

    /// A `--silent` process (not this GUI) currently holds this environment's sync
    /// lock. Distinct from engine.isRunning, which is this process's own state.
    private var isLockedExternally: Bool {
        guard let envId = store.environmentId else { return false }
        return envStore.externallyLockedEnvironments.contains(envId)
    }

    // MARK: State-derived appearance

    private var buttonLabel: String {
        if engine.isRunning      { return "Stop Sync" }
        if isLockedExternally    { return "Syncing (CLI)" }
        if isQueued               { return "In Queue"  }
        return "Run Sync"
    }

    private var buttonIcon: String {
        if engine.isRunning      { return "stop.circle.fill"                        }
        if isLockedExternally    { return "terminal.fill"                           }
        if isQueued               { return "clock.badge.checkmark"                  }
        return "arrow.triangle.2.circlepath.circle.fill"
    }

    private var buttonTint: Color {
        if engine.isRunning      { return .red                       }
        if isLockedExternally    { return Color(.secondaryLabelColor) }
        if isQueued               { return Color(.secondaryLabelColor) }
        if !canRun                { return Color(.tertiaryLabelColor) }
        return .accentColor
    }

    private var isDisabled: Bool {
        isLockedExternally || isQueued || envStore.persistenceLoadFailed || (!canRun && !engine.isRunning)
    }

    private var helpText: String {
        if engine.isRunning      { return "Stop the sync in progress — devices fetched so far will be saved" }
        if isLockedExternally    { return "A command-line sync (--silent) is already running for this environment" }
        if isQueued               { return "This environment is waiting in the sync queue"                    }
        if canRun                 { return "Sync devices from Apple and Jamf, check warranty coverage, and update Jamf" }
        return "Enter your Apple and Jamf credentials in Setup before running a sync"
    }

    var body: some View {
        Button {
            if engine.isRunning {
                showStopConfirm = true
            } else if !isQueued && !isLockedExternally {
                if let envId = store.environmentId {
                    envStore.enqueue(envId)
                } else {
                    engine.run(store: store)
                }
                navigateToSync?()
            }
        } label: {
            HStack(spacing: 6) {
                if engine.isRunning && !showStopConfirm {
                    ProgressView()
                        .fixedSize()
                        .scaleEffect(0.75)
                        .tint(.white)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: buttonIcon)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(buttonLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isDisabled ? Color(.tertiaryLabelColor) : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDisabled
                          ? Color(.quaternaryLabelColor)
                          : isHovering
                            ? buttonTint.opacity(0.85)
                            : buttonTint)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: engine.isRunning)
        .animation(.easeInOut(duration: 0.15), value: isQueued)
        .animation(.easeInOut(duration: 0.1),  value: isHovering)
        .help(helpText)
        .confirmationDialog(
            "Stop Sync?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop & Save Progress", role: .destructive) { engine.stop() }
            Button("Keep Running", role: .cancel) { }
        } message: {
            Text("All devices fetched so far will be saved to cache. The next Run Sync will resume from where this left off.")
        }
    }
}

// MARK: - Dashboard row
struct DashStatRow: View {
    let label:   String
    let value:   Int
    let color:   Color
    var tooltip: InfoContent? = nil

    var body: some View {
        HStack {
            if let tooltip {
                InfoLabel(text: label, info: tooltip)
            } else {
                Text(label)
                    .font(.callout)
            }
            Spacer()
            Text("\(value)")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

// MARK: - Breakdown list (label → count, sorted and capped)
// Shared by the AxM and Jamf focus modes for things like product family,
// purchase source, order year, and OS version distributions.
enum BreakdownSortMode {
    case byCountDescending
    case byKeyDescending
    case byVersionDescending  // numeric-aware key sort — for version-style breakdowns
}

struct BreakdownList: View {
    let breakdown: [String: Int]
    let color:     Color
    var sortMode:  BreakdownSortMode = .byCountDescending
    var maxRows:   Int = 6
    var emptyText: String = "No data yet"
    var onTapRow:  ((String) -> Void)? = nil

    private var sorted: [(String, Int)] {
        switch sortMode {
        case .byCountDescending:   return breakdown.sorted { $0.value > $1.value }
        case .byKeyDescending:     return breakdown.sorted { $0.key   > $1.key   }
        case .byVersionDescending: return breakdown.sorted { (Int($0.key) ?? -1) > (Int($1.key) ?? -1) }
        }
    }

    var body: some View {
        if sorted.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let shown = Array(sorted.prefix(maxRows))
            let rest  = sorted.dropFirst(maxRows).reduce(0) { $0 + $1.1 }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown, id: \.0) { label, count in
                    if let onTapRow {
                        DashboardDrillDown(action: { onTapRow(label) }) {
                            DashStatRow(label: label, value: count, color: color)
                        }
                    } else {
                        DashStatRow(label: label, value: count, color: color)
                    }
                }
                if rest > 0 {
                    DashStatRow(label: "Other", value: rest, color: .secondary)
                }
            }
        }
    }
}

// MARK: - Tappable wrapper for Dashboard drill-down elements
// Wraps any Dashboard component (StatCard, DashStatRow, CoverageLegendRow, a
// BreakdownBarChart row...) in an optional tap target that jumps to the Devices tab
// pre-filtered to exactly what was tapped — a PivotTable-style "drill to detail".
// Hover feedback matches GlobalSyncButton's existing convention: a subtle background
// tint, no cursor override (Button already conveys clickability on macOS).
struct DashboardDrillDown<Content: View>: View {
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        if let action {
            Button(action: action) {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.1), value: isHovering)
        } else {
            content
        }
    }
}

// MARK: - Sync timestamp
struct SyncTimestampRow: View {
    let label:     String
    let timestamp: String

    var body: some View {
        HStack {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(timestamp.isEmpty ? "Never" : timestamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Coverage stat card with progress bar
struct CoverageStatCard: View {
    @EnvironmentObject private var store: AppStore
    let title:   String
    let value:   Int
    let total:   Int
    let icon:    String
    let color:   Color
    var tooltip: InfoContent? = nil

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(value) / Double(total), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .symbolRenderingMode(.hierarchical)
                Spacer()
                if let tooltip {
                    InfoButton(info: tooltip)
                }
            }
            Text("\(value)")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(title)
                .font(.callout)
            ProgressView(value: fraction)
                .tint(color)
            Text(total > 0 ? "\(Int(fraction * 100))% of \(scopeAbbrev) devices" : "—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Ring chart (pure SwiftUI)
// Takes explicit counts rather than a whole DashboardStats so it can be reused
// for the Apple- and Jamf-focus dashboards' own coverage breakdowns, not just
// the Default dashboard's all-AxM-devices one.
struct CoverageRingView: View {
    let active:       Int
    let inactive:     Int
    let noPlan:       Int
    let neverFetched: Int

    private var total: Int { active + inactive + noPlan + neverFetched }

    private var segments: [(Double, Color)] {
        let denom = Double(max(total, 1))
        return [
            (Double(active)       / denom, .green),
            (Double(inactive)     / denom, .red),
            (Double(noPlan)       / denom, .orange),
            (Double(neverFetched) / denom, .secondary),
        ]
    }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let center   = CGPoint(x: size.width / 2, y: size.height / 2)
                let lineW: CGFloat = 18
                // Inset by half lineWidth so rounded caps don't clip the canvas edge.
                let radius   = min(size.width, size.height) / 2 - lineW / 2 - 4
                var startAngle = Angle.degrees(-90)

                for (fraction, color) in segments where fraction > 0 {
                    let sweep = Angle.degrees(fraction * 360)
                    var path  = Path()
                    path.addArc(center: center, radius: radius,
                                startAngle: startAngle,
                                endAngle: startAngle + sweep,
                                clockwise: false)
                    ctx.stroke(path,
                               with: .color(color),
                               style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    startAngle += sweep + .degrees(1.5)
                }
            }
            // Centre label as a SwiftUI overlay — avoids GraphicsContext.ResolvedText
            VStack(spacing: 2) {
                Text("\(total)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Legend row
struct CoverageLegendRow: View {
    let label: String
    let value: Int
    let color: Color
    var total: Int? = nil   // when set, shows "N%" of total next to the count

    private var percentageText: String? {
        guard let total, total > 0 else { return nil }
        let pct = Int((Double(value) / Double(total) * 100).rounded())
        return "\(pct)%"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.callout)
            Spacer()
            Text("\(value)")
                .font(.callout)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(color)
            if let percentageText {
                Text("(\(percentageText))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
