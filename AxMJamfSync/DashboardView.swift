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

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }
    private var scopeFull:   String { store.axmCredentials.scope == .school ? "Apple School Manager (ASM)" : "Apple Business Manager (ABM)" }

    var s: DashboardStats { store.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Header + Sync button
                HStack(alignment: .center) {
                    Text("Live overview of synced devices, AppleCare coverage, and Jamf Update status.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    GlobalSyncButton(engine: engine)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                // MARK: Overall totals row
                HStack(spacing: 12) {
                    StatCard(title: "Total Devices",  value: "\(s.total)",   icon: "desktopcomputer",         color: .primary,
                           tooltip: InfoContent(
                               icon: "desktopcomputer", title: "Total Devices",
                               summary: "All unique devices found across both Apple and Jamf, combined.",
                               bullets: ["A device is counted once even if it appears in both systems.",
                                         "This is the sum of In Both + \(scopeAbbrev) Only + Jamf Only."]))
                    StatCard(title: "In Both",         value: "\(s.both)",    icon: "checkmark.circle.fill",   color: .green,
                           tooltip: InfoContent(
                               icon: "checkmark.circle.fill", title: "In Both",
                               summary: "Devices enrolled in Apple Business/School Manager AND present in Jamf Pro.",
                               bullets: ["These are fully managed devices — Apple has them registered and Jamf tracks them.",
                                         "Only devices In Both can have warranty dates written back to Jamf."]))
                    StatCard(title: store.axmCredentials.scope == .school ? "ASM Only" : "ABM Only",        value: "\(s.axmOnly)", icon: "applelogo",               color: .blue,
                           tooltip: InfoContent(
                               icon: "applelogo", title: store.axmCredentials.scope == .school ? "ASM Only" : "ABM Only",
                               summary: "Devices registered in Apple Business/School Manager but not yet enrolled in Jamf Pro.",
                               bullets: ["These may be new devices awaiting Jamf enrollment, or devices removed from Jamf but still in Apple's system.",
                                         "Warranty coverage can still be fetched for these devices, but dates cannot be written to Jamf until they enrol."]))
                    StatCard(title: "Jamf Only",       value: "\(s.jamfOnly)",icon: "server.rack",             color: .orange,
                           tooltip: InfoContent(
                               icon: "server.rack", title: "Jamf Only",
                               summary: "Devices that exist in Jamf Pro but are not registered in Apple Business/School Manager.",
                               bullets: ["Common for devices enrolled manually in Jamf, or Apple-removed devices still tracked in Jamf.",
                                         "No Apple warranty data can be fetched for these devices via this app."]))
                }
                .padding(.horizontal, 24)

                // MARK: Three section grid
                HStack(alignment: .top, spacing: 16) {

                    // --- AxM section ---
                    CardSection(title: scopeFull, icon: "applelogo") {
                        DashStatRow(label: "Total Devices",  value: s.axmTotal,    color: .primary,
                            tooltip: InfoContent(icon: "applelogo", title: "Total in Apple Manager",
                                summary: "All devices currently registered under your Apple Business or School Manager account.",
                                bullets: ["Includes Active and Released devices.", "Fetched directly from Apple's device API during each sync."]))
                        DashStatRow(label: "Active",          value: s.axmActive,   color: .green,
                            tooltip: InfoContent(icon: "checkmark.circle", title: "Active in Apple Manager",
                                summary: "Devices currently enrolled and active in your Apple Business or School Manager account.",
                                bullets: ["These are devices Apple recognises as part of your organisation.", "Warranty and AppleCare data can be fetched for all active devices."]))
                        DashStatRow(label: "Released",        value: s.axmReleased, color: .secondary,
                                    tooltip: InfoContent(
                                        icon:    "clock.arrow.circlepath",
                                        title:   "Released Devices",
                                        summary: "Devices that were removed or unenrolled from \(scopeAbbrev).",
                                        bullets: [
                                            "Their records are kept for history — you can still see them in the Devices tab.",
                                            "They are no longer actively managed through \(scopeAbbrev)."
                                        ]
                                    ))
                        Divider()
                        SyncTimestampRow(label: "Last sync", timestamp: s.lastAxmSync)
                        if s.runAxmFetched > 0 {
                            DashStatRow(label: "Fetched this run", value: s.runAxmFetched, color: .blue)
                        }
                    }

                    // --- Jamf section ---
                    CardSection(title: "Jamf Pro", icon: "server.rack") {
                        DashStatRow(label: "Total Devices (Jamf)", value: s.jamfTotal,     color: .primary,
                            tooltip: InfoContent(icon: "server.rack", title: "Total in Jamf Pro",
                                summary: "All computer records currently in your Jamf Pro inventory.",
                                bullets: ["Fetched from Jamf during each sync.", "Includes both managed and unmanaged computers."]))
                        DashStatRow(label: "Managed",          value: s.jamfManaged,   color: .green,
                            tooltip: InfoContent(icon: "checkmark.shield", title: "Managed by Jamf",
                                summary: "Computers actively managed by Jamf Pro — Jamf can push policies, apps, and settings to these devices.",
                                bullets: ["These are the devices this app can write warranty dates back to.", "Unmanaged devices cannot receive Jamf configuration profiles or policies."]))
                        DashStatRow(label: "Unmanaged",        value: s.jamfUnmanaged, color: .orange,
                            tooltip: InfoContent(icon: "exclamationmark.shield", title: "Unmanaged in Jamf",
                                summary: "Computers present in Jamf but not currently under active management.",
                                bullets: ["These devices may have had their MDM profile removed, or were enrolled manually without full MDM.",
                                         "Warranty dates can still be written back to Jamf inventory records for these devices."]))
                        Divider()
                        SyncTimestampRow(label: "Last sync", timestamp: s.lastJamfSync)
                        if s.runJamfFetched > 0 {
                            DashStatRow(label: "Fetched this run", value: s.runJamfFetched, color: .blue)
                        }
                    }

                    // --- Write-back section ---
                    CardSection(title: "Jamf Update", icon: "arrow.up.to.line.circle.fill") {
                        DashStatRow(label: "Synced to Jamf", value: s.wbSynced,  color: .green,
                            tooltip: InfoContent(icon: "checkmark.circle.fill", title: "Synced to Jamf",
                                summary: "Devices whose warranty date has been successfully written to Jamf Pro.",
                                bullets: ["The warranty end date and AppleCare ID in Jamf now match what Apple's API returned.", "These devices will not be updated again unless the warranty data changes."]))
                        DashStatRow(label: "Pending",         value: s.wbPending, color: .orange,
                            tooltip: InfoContent(icon: "clock.fill", title: "Pending Jamf Update",
                                summary: "Devices with new warranty data from Apple that has not yet been written to Jamf Pro.",
                                bullets: ["These will be updated on the next sync run.", "A high pending count after a sync usually means the Jamf Update step was skipped or aborted."]))
                        DashStatRow(label: "Failed",          value: s.wbFailed,  color: .red,
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
                        DashStatRow(label: "Skipped",         value: s.wbSkipped, color: .secondary,
                                    tooltip: InfoContent(
                                        icon:    "minus.circle.fill",
                                        title:   "Skipped Devices",
                                        summary: "These devices were skipped during the Jamf warranty update step.",
                                        bullets: [
                                            "Either the device has no warranty date to write back.",
                                            "Or the serial number could not be matched to a record in Jamf Pro."
                                        ]
                                    ))
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
                if s.mdmAssigned > 0 || s.mdmUnassigned > 0 {
                    CardSection(title: "MDM Assignment", icon: "server.rack") {
                        HStack(alignment: .top, spacing: 16) {
                            // Left: assigned / unassigned stat cards
                            HStack(spacing: 12) {
                                CoverageStatCard(
                                    title: "Assigned",
                                    value: s.mdmAssigned,
                                    total: s.axmTotal,
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
                                CoverageStatCard(
                                    title: "Unassigned",
                                    value: s.mdmUnassigned,
                                    total: s.axmTotal,
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

                            // Right: per-server breakdown
                            if !s.mdmServerBreakdown.isEmpty {
                                Divider()
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("MDM Servers")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.bottom, 2)
                                    let sorted = s.mdmServerBreakdown.sorted { $0.value > $1.value }
                                    ForEach(sorted, id: \.key) { name, count in
                                        DashStatRow(label: name, value: count, color: .purple)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // MARK: Coverage breakdown — full-width
                CardSection(title: "Apple Warranty Status", icon: "shield.lefthalf.filled") {
                    HStack(spacing: 12) {
                        CoverageStatCard(
                            title:    "In Warranty",
                            value:    s.coverageActive,
                            total:    s.axmTotal,
                            icon:     "checkmark.shield.fill",
                            color:    .green
                        )
                        CoverageStatCard(
                            title:    "Out of Warranty",
                            value:    s.coverageInactive,
                            total:    s.axmTotal,
                            icon:     "xmark.shield.fill",
                            color:    .red
                        )
                        CoverageStatCard(
                            title:    "No Coverage Info",
                            value:    s.coverageNoPlan,
                            total:    s.axmTotal,
                            icon:     "questionmark.circle.fill",
                            color:    .orange,
                            tooltip:  InfoContent(
                            icon:    "questionmark.circle.fill",
                            title:   "No Coverage Info",
                            summary: "Apple has no warranty or AppleCare record on file for these devices.",
                            bullets: [
                                "Common for older devices past their original warranty period.",
                                "Can happen for devices bought through a third-party reseller not linked to your \(scopeAbbrev) account.",
                                "Devices not registered under your Apple Business/School Manager account may also show this."
                            ]
                        )
                        )
                        CoverageStatCard(
                            title:    "Never Fetched",
                            value:    s.coverageNeverFetched,
                            total:    s.axmTotal,
                            icon:     "clock.arrow.circlepath",
                            color:    .secondary,
                            tooltip:  InfoContent(
                            icon:    "clock.badge.questionmark",
                            title:   "Never Fetched",
                            summary: "Warranty coverage has not been checked for these devices yet.",
                            bullets: [
                                "Run a sync to retrieve their warranty status from Apple.",
                                "This count goes down each time a sync completes.",
                                "New devices added to \(scopeAbbrev) will appear here until their first coverage check."
                            ]
                        )
                        )
                    }
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

                // MARK: Coverage ring chart — full width, generous height
                CardSection(title: "Coverage Distribution", icon: "chart.pie.fill") {
                    HStack(spacing: 64) {
                        CoverageRingView(stats: s)
                            .frame(width: 300, height: 300)

                        VStack(alignment: .leading, spacing: 24) {
                            CoverageLegendRow(label: "In Warranty",      value: s.coverageActive,       color: .green)
                            CoverageLegendRow(label: "Out of Warranty",  value: s.coverageInactive,     color: .red)
                            CoverageLegendRow(label: "No Coverage Info", value: s.coverageNoPlan,       color: .orange)
                            CoverageLegendRow(label: "Never Fetched",    value: s.coverageNeverFetched, color: .secondary)
                        }
                        .frame(minWidth: 260)

                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .frame(minHeight: 340)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 24)
            }
        }
        .background(.background)
    }
}

// MARK: - Shared Run/Stop Sync Button (used on Dashboard and any other tab)
/// Shared Run/Stop button — used on Setup, Sync, and Dashboard tabs.
/// Pass navigateToSync to auto-switch to the Sync tab on start (Setup only).
struct GlobalSyncButton: View {
    @ObservedObject        var engine: SyncEngine
    @EnvironmentObject private var store: AppStore
    var navigateToSync: (() -> Void)? = nil
    @State private var showStopConfirm = false

    var canRun: Bool {
        let axm  = !store.axmCredentials.clientId.isEmpty && !store.axmCredentials.keyId.isEmpty
        let jamf = !store.jamfCredentials.url.isEmpty && !store.jamfCredentials.clientId.isEmpty
        return axm || jamf
    }

    var body: some View {
        Button {
            if engine.isRunning {
                showStopConfirm = true
            } else {
                engine.run(store: store)
                navigateToSync?()
            }
        } label: {
            HStack(spacing: 6) {
                if engine.isRunning {
                    ProgressView().fixedSize().scaleEffect(0.75)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                }
                Text(engine.isRunning ? "Stop Sync" : "Run Sync").fontWeight(.semibold)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(engine.isRunning ? .red : Color.accentColor)
        .disabled(!canRun && !engine.isRunning)
        .help(engine.isRunning ? "Click to stop the sync that is currently in progress — any devices already fetched will be saved" :
              canRun ? "Fetch all devices from Apple and Jamf, check warranty coverage, and update Jamf with the latest warranty dates" : "Go to the Setup tab and enter your Apple and Jamf credentials before running a sync")
        .confirmationDialog(
            "Stop Sync?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop & Save Progress", role: .destructive) { engine.stop() }
            Button("Keep Running", role: .cancel) { }
        } message: {
            Text("All devices fetched so far will be saved to cache immediately. The next Run Sync will skip already-fetched steps and resume from where this stopped.")
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
struct CoverageRingView: View {
    let stats: DashboardStats

    private var segments: [(Double, Color)] {
        let total = Double(max(stats.axmTotal, 1))
        return [
            (Double(stats.coverageActive)       / total, .green),
            (Double(stats.coverageInactive)     / total, .red),
            (Double(stats.coverageNoPlan)       / total, .orange),
            (Double(stats.coverageNeverFetched) / total, .secondary),
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
                Text("\(stats.axmTotal)")
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
        }
    }
}
