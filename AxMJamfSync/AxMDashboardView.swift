// AxMDashboardView.swift
// Dashboard "Apple Manager" focus — scoped entirely to AxM-sourced attributes.
// Selected via the Dashboard focus menu in DashboardView.swift.

import SwiftUI

struct AxMDashboardContent: View {
  @EnvironmentObject private var store: AppStore
  var navigateToDevices: () -> Void = {}

  private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }
  private var scopeFull: String { store.axmCredentials.scope.label }
  private var s: DashboardStats { store.stats }              // unfiltered — sync status only
  private var fs: DashboardStats { store.axmDashboardStats }  // facet-filtered — every breakdown card

  // Every tap lands on exactly the population the tapped number was counted from
  // (the facet-filtered set), so any facet not overridden by the tapped dimension
  // carries forward into the drill-down — see ARCHITECTURE.md "Dashboard facet
  // filters must compose into drill-downs".
  private func drillDown(axmStatus: String? = nil, productFamily: String? = nil,
                          purchaseSource: String? = nil, addedToOrgYear: String? = nil,
                          mdmServer: String? = nil, expiringWindow: String? = nil,
                          mdmMigrationCapable: String? = nil, activationLock: String? = nil, coverage: CoverageStatus? = nil,
                          axmMigrationStatus: String? = nil, migrationDeadlineWindow: String? = nil) {
    store.drillDown(coverage: coverage,
                     mdmServer: mdmServer ?? store.axmDashboardMdmFacet,
                     axmStatus: axmStatus ?? store.axmDashboardStatusFacet,
                     productFamily: productFamily ?? store.axmDashboardProductFamilyFacet,
                     purchaseSource: purchaseSource ?? store.axmDashboardPurchaseSourceFacet,
                     addedToOrgYear: addedToOrgYear,
                     expiringWindow: expiringWindow,
                     mdmMigrationCapable: mdmMigrationCapable,
                     activationLock: activationLock ?? store.axmDashboardActivationLockFacet,
                     axmMigrationStatus: axmMigrationStatus, migrationDeadlineWindow: migrationDeadlineWindow)
    navigateToDevices()
  }

  // Colour by meaning, not rank — "Not Locked" must not inherit the warning colour.
  private func activationLockSegments(_ breakdown: [String: Int]) -> [DonutSegment] {
    DonutChartView.segments(from: breakdown, palette: [.secondary]).map { seg in
      let color: Color
      switch seg.label {
      case "MDM Locked", "User Locked": color = .orange
      case "Not Locked":                color = .green
      default:                          color = .secondary
      }
      return DonutSegment(label: seg.label, value: seg.value, color: color)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {

      // MARK: Facet filter bar — dashboard-only lens, independent of the Devices
      // tab's own filters. Every card below reads from `fs` (axmDashboardStats).
      AxMDashboardFacetBar()
        .padding(.horizontal, 24)

      // MARK: Totals row
      HStack(spacing: 12) {
        StatCard(title: "Total Devices", value: "\(fs.axmTotal)", icon: "applelogo", color: .primary,
                 tooltip: InfoContent(
                   icon: "applelogo", title: "Total in \(scopeFull)",
                   summary: "All devices currently registered under your \(scopeAbbrev) account.",
                   bullets: ["Includes Active and Released devices.", "This total ignores whether a device is also present in Jamf."]))
        DashboardDrillDown(action: { drillDown(axmStatus: "ACTIVE") }) {
          StatCard(title: "Active", value: "\(fs.axmActive)", icon: "checkmark.circle.fill", color: .green,
                   tooltip: InfoContent(
                     icon: "checkmark.circle", title: "Active in \(scopeAbbrev)",
                     summary: "Devices currently enrolled and active in your \(scopeAbbrev) account.",
                     bullets: ["Apple recognizes these as part of your organization.", "Warranty and AppleCare data can be fetched for all active devices."]))
        }
        DashboardDrillDown(action: { drillDown(axmStatus: "RELEASED") }) {
          StatCard(title: "Released", value: "\(fs.axmReleased)", icon: "clock.arrow.circlepath", color: .secondary,
                   tooltip: InfoContent(
                     icon: "clock.arrow.circlepath", title: "Released Devices",
                     summary: "Devices that were removed or unenrolled from \(scopeAbbrev).",
                     bullets: ["Their records are kept for history — see the Devices tab.",
                               "A device retired in real life but not yet released here still counts toward these totals."]))
        }
      }
      .padding(.horizontal, 24)

      // MARK: Expiring Soon — same non-overlapping 0–30/31–60/61–90-day buckets as
      // the Common dashboard's card, scoped to this focus mode.
      CardSection(title: "Expiring Soon", icon: "clock.badge.exclamationmark") {
        HStack(spacing: 12) {
          DashboardDrillDown(action: { drillDown(expiringWindow: "0–30") }) {
            CoverageStatCard(title: "Next 30 Days", value: fs.axmExpiring30, total: fs.axmTotal,
                             icon: "exclamationmark.shield.fill", color: .red)
          }
          DashboardDrillDown(action: { drillDown(expiringWindow: "31–60") }) {
            CoverageStatCard(title: "31–60 Days", value: fs.axmExpiring60, total: fs.axmTotal,
                             icon: "clock.badge.exclamationmark.fill", color: .orange)
          }
          DashboardDrillDown(action: { drillDown(expiringWindow: "61–90") }) {
            CoverageStatCard(title: "61–90 Days", value: fs.axmExpiring90, total: fs.axmTotal,
                             icon: "clock.fill", color: .yellow,
                             tooltip: InfoContent(
                               icon: "clock.fill", title: "Coverage Expiring in 61–90 Days",
                               summary: "AppleCare or warranty coverage on these devices ends within the next 61 to 90 days.",
                               bullets: ["Only devices currently In Warranty are counted here.",
                                         "A device already Out of Warranty shows up there instead, not in this card."]))
          }
        }
      }
      .padding(.horizontal, 24)

      // MARK: Product family + Purchase source
      HStack(alignment: .top, spacing: 16) {
        CardSection(title: "Product Family", icon: "laptopcomputer") {
          HStack(spacing: 20) {
            DonutChartView(
              segments: DonutChartView.segments(from: fs.axmProductFamilyBreakdown, palette: [.blue, .purple, .orange, .green, .secondary]),
              centerTitle: "\(fs.axmTotal)", centerSubtitle: "devices")
              .frame(width: 130, height: 130)
            VStack(alignment: .leading, spacing: 8) {
              ForEach(DonutChartView.segments(from: fs.axmProductFamilyBreakdown, palette: [.blue, .purple, .orange, .green, .secondary])) { seg in
                DashboardDrillDown(action: { drillDown(productFamily: seg.label) }) {
                  CoverageLegendRow(label: seg.label, value: seg.value, color: seg.color)
                }
              }
            }
          }
        }
        CardSection(title: "Purchase Source", icon: "cart") {
          BreakdownBarChart(breakdown: fs.axmPurchaseSourceBreakdown, color: .purple,
                             onTapRow: { label in drillDown(purchaseSource: label) })
        }
      }
      .padding(.horizontal, 24)

      // MARK: MDM Assignment + Migration Capability — same row.
      if fs.mdmAssigned > 0 || fs.mdmUnassigned > 0 {
        HStack(alignment: .top, spacing: 16) {
          CardSection(title: "MDM Assignment", icon: "server.rack") {
            HStack(alignment: .top, spacing: 16) {
              HStack(spacing: 12) {
                DashboardDrillDown(action: { drillDown(mdmServer: AppStore.mdmAssignedSentinel) }) {
                  CoverageStatCard(
                    title: "Assigned", value: fs.mdmAssigned, total: fs.axmTotal,
                    icon: "checkmark.circle.fill", color: .purple,
                    tooltip: InfoContent(
                      icon: "checkmark.circle.fill", title: "MDM Assigned",
                      summary: "AxM devices assigned to a Device Management Service (MDM server).",
                      bullets: ["These devices are enrolled in an MDM server in \(scopeAbbrev).",
                                "Breakdown by server is shown on the right."]))
                }
                DashboardDrillDown(action: { drillDown(mdmServer: AppStore.mdmUnassignedSentinel) }) {
                  CoverageStatCard(
                    title: "Unassigned", value: fs.mdmUnassigned, total: fs.axmTotal,
                    icon: "questionmark.circle.fill", color: .secondary,
                    tooltip: InfoContent(
                      icon: "questionmark.circle.fill", title: "MDM Unassigned",
                      summary: "AxM devices not assigned to any Device Management Service.",
                      bullets: ["These devices are registered in \(scopeAbbrev) but have not been assigned to an MDM server.",
                                "Use the Devices tab to find and review these devices."]))
                }
              }
              if !fs.mdmServerBreakdown.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                  Text("MDM Servers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                  BreakdownList(breakdown: fs.mdmServerBreakdown, color: .purple, maxRows: 10,
                                onTapRow: { name in drillDown(mdmServer: name) })
                }
                .frame(maxWidth: .infinity)
              }
            }
          }
          if !fs.activationLockBreakdown.isEmpty {
            CardSection(title: "Activation Lock", icon: "lock.laptopcomputer") {
              HStack(spacing: 20) {
                DonutChartView(
                  segments: activationLockSegments(fs.activationLockBreakdown),
                  centerTitle: "\(fs.activationLockBreakdown.values.reduce(0, +))", centerSubtitle: "devices")
                  .frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 8) {
                  ForEach(activationLockSegments(fs.activationLockBreakdown)) { seg in
                    DashboardDrillDown(action: { drillDown(activationLock: seg.label) }) {
                      CoverageLegendRow(label: seg.label, value: seg.value, color: seg.color)
                    }
                  }
                }
              }
            }
          }
          if !fs.mdmMigrationCapableBreakdown.isEmpty {
            CardSection(title: "MDM Migration Capability", icon: "arrow.triangle.2.circlepath") {
              HStack(spacing: 20) {
                DonutChartView(
                  segments: DonutChartView.segments(from: fs.mdmMigrationCapableBreakdown, palette: [.green, .orange, .secondary]),
                  centerTitle: "\(fs.mdmMigrationCapableBreakdown.values.reduce(0, +))", centerSubtitle: "devices")
                  .frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 8) {
                  ForEach(DonutChartView.segments(from: fs.mdmMigrationCapableBreakdown, palette: [.green, .orange, .secondary])) { seg in
                    DashboardDrillDown(action: { drillDown(mdmMigrationCapable: seg.label) }) {
                      CoverageLegendRow(label: seg.label, value: seg.value, color: seg.color)
                    }
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, 24)
      }

      // MARK: MDM Migration Status & Deadline — full width, always shown when
      // there's any AxM data. "Not Requested" is a real, meaningful state (no
      // migration has been asked for yet), not a placeholder to hide.
      //
      // Stat cards, not a donut: this data is typically extremely skewed (almost
      // everything "Not Requested" until migrations actually start), and a donut
      // renders a small-but-real count (e.g. 4 of 1325) as a sliver of roughly a
      // degree — effectively invisible next to angularInset/cornerRadius, even
      // though the legend text is technically still correct. A stat card gives
      // every status equal visual weight regardless of proportion, matching how
      // MDM Assignment right above already handles its own Assigned/Unassigned
      // split without a donut.
      if !fs.axmMigrationStatusBreakdown.isEmpty {
        CardSection(title: "MDM Migration Status", icon: "arrow.triangle.2.circlepath.circle") {
          VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
              DashboardDrillDown(action: { drillDown(axmMigrationStatus: "Not Requested") }) {
                CoverageStatCard(title: "Not Requested", value: fs.axmMigrationStatusBreakdown["Not Requested"] ?? 0, total: fs.axmTotal,
                                 icon: "minus.circle", color: .secondary)
              }
              DashboardDrillDown(action: { drillDown(axmMigrationStatus: "Requested") }) {
                CoverageStatCard(title: "Requested", value: fs.axmMigrationStatusBreakdown["Requested"] ?? 0, total: fs.axmTotal,
                                 icon: "arrow.triangle.2.circlepath", color: .blue)
              }
              DashboardDrillDown(action: { drillDown(axmMigrationStatus: "In Progress") }) {
                CoverageStatCard(title: "In Progress", value: fs.axmMigrationStatusBreakdown["In Progress"] ?? 0, total: fs.axmTotal,
                                 icon: "clock.fill", color: .orange)
              }
              DashboardDrillDown(action: { drillDown(axmMigrationStatus: "Success") }) {
                CoverageStatCard(title: "Success", value: fs.axmMigrationStatusBreakdown["Success"] ?? 0, total: fs.axmTotal,
                                 icon: "checkmark.circle.fill", color: .green)
              }
              DashboardDrillDown(action: { drillDown(axmMigrationStatus: "Failed") }) {
                CoverageStatCard(title: "Failed", value: fs.axmMigrationStatusBreakdown["Failed"] ?? 0, total: fs.axmTotal,
                                 icon: "xmark.circle.fill", color: .red)
              }
            }
            if fs.axmMigrationDeadline30 + fs.axmMigrationDeadline60 + fs.axmMigrationDeadline90 > 0 {
              Divider()
              Text("Deadline Approaching")
                .font(.caption)
                .foregroundStyle(.secondary)
              HStack(spacing: 12) {
                DashboardDrillDown(action: { drillDown(migrationDeadlineWindow: "0–30") }) {
                  CoverageStatCard(title: "Next 30 Days", value: fs.axmMigrationDeadline30, total: fs.axmTotal,
                                   icon: "exclamationmark.triangle.fill", color: .red)
                }
                DashboardDrillDown(action: { drillDown(migrationDeadlineWindow: "31–60") }) {
                  CoverageStatCard(title: "31–60 Days", value: fs.axmMigrationDeadline60, total: fs.axmTotal,
                                   icon: "clock.badge.exclamationmark.fill", color: .orange)
                }
                DashboardDrillDown(action: { drillDown(migrationDeadlineWindow: "61–90") }) {
                  CoverageStatCard(title: "61–90 Days", value: fs.axmMigrationDeadline90, total: fs.axmTotal,
                                   icon: "clock.fill", color: .yellow,
                                   tooltip: InfoContent(
                                     icon: "clock.fill", title: "Migration Deadline in 61–90 Days",
                                     summary: "These devices have an in-progress MDM migration whose deadline is 61 to 90 days out.",
                                     bullets: ["Apple caps migration deadlines at 90 days out, so this captures the full window.",
                                               "Only Requested/In Progress migrations are counted — a completed or failed migration has no live deadline."]))
                }
              }
            }
          }
        }
        .padding(.horizontal, 24)
      }

      // MARK: Added-to-org history — sourced from addedToOrgDate, not orderDate.
      // Apple's orderDateTime is frequently absent (reseller purchases, manually
      // added devices, older records), while addedToOrgDate is populated for
      // essentially every device, since it's stamped when Apple adds the device
      // to the org's roster.
      CardSection(title: "Added to Org History", icon: "calendar") {
        YearTrendChart(breakdown: fs.axmOrderYearBreakdown, color: .orange, unknownLabel: "Unknown date added",
                        onTapUnknown: { drillDown(addedToOrgYear: "Unknown") })
      }
      .padding(.horizontal, 24)

      // MARK: Coverage distribution ring — same coverage fields the Default
      // dashboard shows, since they're already scoped to AxM-having devices.
      CardSection(title: "Coverage Distribution", icon: "chart.pie.fill") {
        HStack(spacing: 64) {
          CoverageRingView(active: fs.coverageActive, inactive: fs.coverageInactive,
                            noPlan: fs.coverageNoPlan, neverFetched: fs.coverageNeverFetched)
            .frame(width: 220, height: 220)
          VStack(alignment: .leading, spacing: 16) {
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
          Spacer()
        }
        .padding(.vertical, 8)
      }
      .padding(.horizontal, 24)

      // MARK: Sync status — moved to the very end, below Coverage Distribution.
      CardSection(title: scopeFull, icon: "applelogo") {
        SyncTimestampRow(label: "Last sync", timestamp: s.lastAxmSync)
        if s.runAxmFetched > 0 {
          DashStatRow(label: "Fetched this run", value: s.runAxmFetched, color: .blue)
        }
      }
      .padding(.horizontal, 24)
    }
  }
}

// MARK: - Apple dashboard facet filter bar
// Same dashboard-only lens as JamfDashboardFacetBar — setting these never touches
// the Devices tab's own filters. Status/MDM as segmented controls; Product Family
// and Purchase Source as icon-chip menus (Product Family's values are dynamic).
private struct AxMDashboardFacetBar: View {
  @EnvironmentObject private var store: AppStore

  private var matchCount: Int { store.axmDashboardStats.axmTotal }

  // Sourced from the unfiltered stats so the option list stays stable regardless
  // of which facets are currently active.
  private var productFamilyOptions: [(label: String, value: String?)] {
    [("All", nil)] + store.stats.axmProductFamilyBreakdown
      .sorted { $0.value > $1.value }
      .map { (label: $0.key, value: Optional($0.key)) }
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Spacer()
        Picker("", selection: store.facetBinding(\.axmDashboardStatusFacet)) {
          Text("All").tag(String?.none)
          Text("Active").tag(String?.some("ACTIVE"))
          Text("Released").tag(String?.some("RELEASED"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)

        Picker("", selection: store.facetBinding(\.axmDashboardMdmFacet)) {
          Text("All MDM").tag(String?.none)
          Text("Assigned").tag(String?.some(AppStore.mdmAssignedSentinel))
          Text("Unassigned").tag(String?.some(AppStore.mdmUnassignedSentinel))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)

        FacetChipMenu(icon: "laptopcomputer", title: "Product Family",
                      options: productFamilyOptions,
                      selection: store.facetBinding(\.axmDashboardProductFamilyFacet))

        FacetChipMenu(icon: "lock.laptopcomputer", title: "Activation Lock",
                      options: [("All", nil), ("MDM Locked", "MDM Locked"), ("User Locked", "User Locked"),
                                ("Not Locked", "Not Locked"), ("Unknown", "Unknown"), ("Not Fetched", "Not Fetched")],
                      selection: store.facetBinding(\.axmDashboardActivationLockFacet))

        FacetChipMenu(icon: "cart", title: "Purchase Source",
                      options: [("All", nil), ("Apple", "Apple"), ("Reseller", "Reseller"),
                                ("Manually Added", "Manually Added"), ("Unknown", "Unknown")],
                      selection: store.facetBinding(\.axmDashboardPurchaseSourceFacet))

        Spacer()
      }

      if store.axmDashboardFacetCount > 0 {
        HStack(spacing: 8) {
          Spacer()
          if let st = store.axmDashboardStatusFacet {
            FacetActiveChip(label: st.capitalized) { store.axmDashboardStatusFacet = nil }
          }
          if let mdm = store.axmDashboardMdmFacet {
            FacetActiveChip(label: mdm == AppStore.mdmAssignedSentinel ? "MDM Assigned" : "MDM Unassigned") {
              store.axmDashboardMdmFacet = nil
            }
          }
          if let pf = store.axmDashboardProductFamilyFacet {
            FacetActiveChip(label: pf) { store.axmDashboardProductFamilyFacet = nil }
          }
          if let ps = store.axmDashboardPurchaseSourceFacet {
            FacetActiveChip(label: ps) { store.axmDashboardPurchaseSourceFacet = nil }
          }
          if let al = store.axmDashboardActivationLockFacet {
            FacetActiveChip(label: "Activation Lock: \(al)") { store.axmDashboardActivationLockFacet = nil }
          }
          Text("^[\(matchCount) device](inflect: true) match")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Clear All") { store.clearAxmDashboardFacets() }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
          Spacer()
        }
      }
    }
  }
}
