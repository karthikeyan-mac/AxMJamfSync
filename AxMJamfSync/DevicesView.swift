// DevicesView.swift
// Devices tab — merged device table with filter dropdowns and search.
//
// Filter row: horizontally scrollable (ScrollView) to prevent squeeze at narrow widths.
// Filters: Type / Source / Coverage / Jamf Update — each a Menu dropdown.
// List: lazy-loaded, multi-selectable (Set<String> of serials). Selecting one
//   device shows its full detail; selecting several shows a summary panel with
//   Copy Serial Numbers / Export Selection.
// Search: debounced 200ms via AppStore.scheduleFilter() — matches serial, Jamf
//   name, model, username, Jamf ID, AppleCare agreement #, MDM server, order
//   number, model identifier (see AppStore.matchesDeviceFilters).
// Each row and the detail panel offer Copy Serial / Copy Jamf ID / Open in
//   Jamf Pro (computers.html / mobileDevices.html, disabled with no Jamf ID
//   or no Jamf URL configured).

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 5.4: Jamf Pro console deep link for a device's inventory record, or nil if
/// there's nothing to link to (no Jamf ID, or Jamf isn't configured). Shared by
/// the row context menu and the detail panel's button row.
private func jamfConsoleURL(for device: Device, jamfBaseURL: String) -> URL? {
    guard let jamfId = device.jamfId, !jamfId.isEmpty, !jamfBaseURL.isEmpty else { return nil }
    let base = jamfBaseURL.hasSuffix("/") ? String(jamfBaseURL.dropLast()) : jamfBaseURL
    let path = device.isMobile ? "mobileDevices.html" : "computers.html"
    return URL(string: "\(base)/\(path)?id=\(jamfId)&o=r")
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct DevicesView: View {
    @EnvironmentObject private var store: AppStore

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }
    // 5.3: selection is a Set of serials (the List's own identity key) rather
    // than a single Device — lets the user multi-select for bulk copy/export
    // while a single selection still drives the full detail panel unchanged.
    @State private var selectedSerials: Set<String> = []

    private var selectedDevices: [Device] {
        guard !selectedSerials.isEmpty else { return [] }
        return store.filteredDevices.filter { selectedSerials.contains($0.serialNumber) }
    }

    var body: some View {
        HSplitView {
            // MARK: Left: Filter + List
            VStack(spacing: 0) {
                DeviceFilterBar()
                Divider()
                DeviceListPanel(selectedSerials: $selectedSerials)
            }
            .frame(minWidth: 460, idealWidth: 560)

            // MARK: Right: Detail
            Group {
                if selectedDevices.count == 1, let device = selectedDevices.first {
                    DeviceDetailPanel(device: device)
                } else if selectedDevices.count > 1 {
                    MultiDeviceSelectionPanel(devices: selectedDevices)
                } else {
                    DeviceDetailPlaceholder()
                }
            }
            .frame(minWidth: 360, idealWidth: 420)
        }
        .background(.background)
        // Issue 7: clear selection when cache is wiped so stale detail doesn't persist
        .onChange(of: store.hasData) { _, hasData in
            if !hasData { selectedSerials.removeAll() }
        }
        // Drop any selected serial no longer in the filtered list (e.g. filter changed)
        .onChange(of: store.filteredDevices) { _, newList in
            guard !selectedSerials.isEmpty else { return }
            let stillPresent = Set(newList.map(\.serialNumber))
            selectedSerials.formIntersection(stillPresent)
        }
    }
}

// MARK: - Filter Bar
struct DeviceFilterBar: View {
    @EnvironmentObject private var store: AppStore

    // Active filter summary labels for each dropdown button
    private var typeLabel: String {
        store.deviceTypeFilter.map { $0.rawValue } ?? "All Types"
    }
    private var sourceLabel: String {
        store.deviceSourceFilter.map { $0.label } ?? "All Sources"
    }
    private var coverageLabel: String {
        switch store.coverageFilter {
        case .active:     return "In Warranty"
        case .inactive:   return "Out of Warranty"
        case .noCoverage: return "No Coverage"
        default:          return "All Coverage"
        }
    }
    private var jamfLabel: String {
        store.wbFilter.map { $0.label } ?? "All Updates"
    }
    private var hasActiveFilter: Bool {
        store.deviceTypeFilter != nil || store.deviceSourceFilter != nil ||
        store.coverageFilter   != nil || store.wbFilter            != nil ||
        store.mdmServerFilter  != nil || store.dashboardDrillDownDescription != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search + count ───────────────────────────────────────
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search serial, name, model, user, Jamf ID…", text: $store.deviceSearchText)
                        .textFieldStyle(.plain)
                    if !store.deviceSearchText.isEmpty {
                        Button { store.deviceSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("^[\(store.filteredDevices.count) device](inflect: true)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // ── Filter dropdowns — horizontally scrollable so they never squeeze ──
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                Text("Filters:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)

                // Dashboard drill-down chip — shown only for filters that don't have
                // their own dropdown below (OS version, FileVault, check-in freshness,
                // product family, purchase source, added-to-org year, AxM status,
                // Jamf managed/unmanaged). Distinct icon so it's clear this came from
                // tapping a Dashboard number, not from a manual filter pick here.
                if let drillDown = store.dashboardDrillDownDescription {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                        Text(drillDown)
                        Button {
                            store.clearDrillDownFilters()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Clear this Dashboard filter")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                }

                // Type
                Menu {
                    Button { store.deviceTypeFilter = nil } label: {
                        Label("All Types", systemImage: "tray.full")
                    }
                    Divider()
                    ForEach(DeviceKind.allCases, id: \.self) { kind in
                        Button {
                            store.deviceTypeFilter = store.deviceTypeFilter == kind ? nil : kind
                        } label: {
                            Label(kind.rawValue, systemImage: kind.icon)
                        }
                        .if(store.deviceTypeFilter == kind) { $0.labelStyle(.titleAndIcon) }
                    }
                } label: {
                    FilterDropdownLabel(
                        text: typeLabel,
                        isActive: store.deviceTypeFilter != nil,
                        icon: store.deviceTypeFilter.map { $0.icon } ?? "line.3.horizontal.decrease.circle"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Source
                Menu {
                    Button { store.deviceSourceFilter = nil } label: {
                        Label("All Sources", systemImage: "tray.full")
                    }
                    Divider()
                    ForEach(DeviceSource.allCases, id: \.self) { source in
                        Button { store.deviceSourceFilter = store.deviceSourceFilter == source ? nil : source } label: {
                            Label(source.label, systemImage: source.icon)
                        }
                    }
                } label: {
                    FilterDropdownLabel(
                        text: sourceLabel,
                        isActive: store.deviceSourceFilter != nil,
                        icon: store.deviceSourceFilter.map { $0.icon } ?? "line.3.horizontal.decrease.circle"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Coverage
                Menu {
                    Button { store.coverageFilter = nil } label: {
                        Label("All Coverage", systemImage: "shield")
                    }
                    Divider()
                    Button { store.coverageFilter = store.coverageFilter == .active    ? nil : .active    } label: { Label("In Warranty",     systemImage: "checkmark.shield.fill") }
                    Button { store.coverageFilter = store.coverageFilter == .inactive  ? nil : .inactive  } label: { Label("Out of Warranty", systemImage: "xmark.shield.fill") }
                    Button { store.coverageFilter = store.coverageFilter == .noCoverage ? nil : .noCoverage } label: { Label("No Coverage",    systemImage: "questionmark.circle.fill") }
                } label: {
                    FilterDropdownLabel(
                        text: coverageLabel,
                        isActive: store.coverageFilter != nil,
                        icon: store.coverageFilter.map { $0.icon } ?? "line.3.horizontal.decrease.circle"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Jamf Update
                Menu {
                    Button { store.wbFilter = nil } label: {
                        Label("All Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                    Button { store.wbFilter = store.wbFilter == .synced  ? nil : .synced  } label: { Label("Synced",  systemImage: "arrow.up.circle.fill") }
                    Button { store.wbFilter = store.wbFilter == .pending ? nil : .pending } label: { Label("Pending", systemImage: "clock.arrow.circlepath") }
                    Button { store.wbFilter = store.wbFilter == .failed  ? nil : .failed  } label: { Label("Failed",  systemImage: "xmark.circle.fill") }
                    Button { store.wbFilter = store.wbFilter == .skipped ? nil : .skipped } label: { Label("Skipped", systemImage: "minus.circle") }
                } label: {
                    FilterDropdownLabel(
                        text: jamfLabel,
                        isActive: store.wbFilter != nil,
                        icon: store.wbFilter != nil ? "arrow.up.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // MDM Server
                if !store.allMdmServerNames.isEmpty || store.devices.contains(where: { $0.axmAssignmentStatus != nil }) {
                    let isUnassignedFilter = store.mdmServerFilter == AppStore.mdmUnassignedSentinel
                    let activeLabel: String = {
                        if isUnassignedFilter { return "Unassigned" }
                        return store.mdmServerFilter ?? "All MDM Servers"
                    }()
                    Menu {
                        Button { store.mdmServerFilter = nil } label: {
                            Label("All MDM Servers", systemImage: "server.rack")
                        }
                        Divider()
                        Button {
                            store.mdmServerFilter = isUnassignedFilter ? nil : AppStore.mdmUnassignedSentinel
                        } label: {
                            Label("Unassigned", systemImage: "questionmark.circle")
                        }
                        if !store.allMdmServerNames.isEmpty {
                            Divider()
                            ForEach(store.allMdmServerNames, id: \.self) { name in
                                Button {
                                    store.mdmServerFilter = store.mdmServerFilter == name ? nil : name
                                } label: {
                                    Label(name, systemImage: "server.rack")
                                }
                            }
                        }
                    } label: {
                        FilterDropdownLabel(
                            text: activeLabel,
                            isActive: store.mdmServerFilter != nil,
                            icon: store.mdmServerFilter != nil ? "server.rack" : "line.3.horizontal.decrease.circle"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                // Clear all filters — deliberately not deviceSearchText, which has its
                // own clear button next to the search field and shouldn't be swept up
                // by this one (matches this button's existing behavior).
                if hasActiveFilter {
                    Button {
                        store.deviceTypeFilter   = nil
                        store.deviceSourceFilter = nil
                        store.coverageFilter     = nil
                        store.wbFilter           = nil
                        store.mdmServerFilter    = nil
                        store.clearDrillDownFilters()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all active filters")
                }

              }
              .padding(.horizontal, 12)
              .padding(.bottom, 10)
            }
        }
    }
}

// Small pill label for a filter dropdown button
private struct FilterDropdownLabel: View {
    let text: String
    let isActive: Bool
    let icon: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .background(
            isActive
                ? Color.accentColor.opacity(0.12)
                : Color(NSColor.controlBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.4) : Color(NSColor.separatorColor),
                    lineWidth: 1)
        )
    }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Device List Panel
struct DeviceListPanel: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedSerials: Set<String>

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }

    var body: some View {
        if store.filteredDevices.isEmpty {
            // H5: Two distinct empty states with actionable CTAs instead of a dead end.
            if store.devices.isEmpty {
                // No sync done yet — guide the user to run their first sync.
                VStack(spacing: 16) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No devices yet")
                        .font(.headline)
                    Text("Run a sync to fetch devices from \(scopeAbbrev) and Jamf.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Filters are active but nothing matches — let the user clear them.
                VStack(spacing: 16) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No devices match your filters")
                        .font(.headline)
                    Button("Clear Filters") {
                        store.clearDeviceFilters()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(store.filteredDevices, id: \.serialNumber, selection: $selectedSerials) { device in
                DeviceRow(device: device)
                    .equatable()
                    .tag(device.serialNumber)
                    .contextMenu {
                        Button("Copy Serial Number") { copyToPasteboard(device.serialNumber) }
                        if let jamfId = device.jamfId, !jamfId.isEmpty {
                            Button("Copy Jamf ID") { copyToPasteboard(jamfId) }
                        }
                        if let url = jamfConsoleURL(for: device, jamfBaseURL: store.jamfCredentials.url) {
                            Divider()
                            Button("Open in Jamf Pro") { NSWorkspace.shared.open(url) }
                        }
                    }
            }
            .listStyle(.inset)
            // Force a full remount on every completed filter/search change rather than
            // letting List diff old-vs-new row identities — that diff (not its animation)
            // is what beachballs when the array swings from a small filtered set back to
            // a large unfiltered one. Since List is lazy, remounting only actually builds
            // the rows currently in view, not the whole array.
            .id(store.filterGeneration)
        }
    }
}

// MARK: - Device Row (image 2 style: model icon + serial + model)
struct DeviceRow: View, Equatable {
    nonisolated static func == (lhs: DeviceRow, rhs: DeviceRow) -> Bool { lhs.device == rhs.device }
    @EnvironmentObject private var store: AppStore
    let device: Device

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }
    private var modelLabel: String {
        // Priority: Jamf model > Apple deviceModel (short) > productDescription > deviceClass
        if let m = device.jamfModel,       !m.isEmpty { return m }
        if let m = device.axmDeviceModel,  !m.isEmpty { return m }
        if let m = device.axmModel,        !m.isEmpty { return m }
        if let cls = device.axmDeviceClass, !cls.isEmpty {
            switch cls.uppercased() {
            case "MAC": return "Mac"; case "IPAD": return "iPad"
            case "IPHONE": return "iPhone"; case "IPOD": return "iPod touch"
            case "APPLETV": return "Apple TV"
            default: return cls.capitalized
            }
        }
        if let src = device.axmPurchaseSource, !src.isEmpty {
            return "Apple Device (\(src.capitalized))"
        }
        return "Apple Device"
    }

    // 5.2: MDM server/Unassigned moves to a subtitle line under the model —
    // it's identity information about the device, not a status worth a badge,
    // and four stacked capsules was pushing rows past 70pt tall.
    private var mdmSubtitle: String? {
        if let mdm = device.assignedMdmServerName, !mdm.isEmpty { return mdm }
        if device.axmAssignmentStatus == "Unassigned" { return "MDM: Unassigned" }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.modelIcon)
                .font(.title2)
                .foregroundStyle(device.deviceSource.color)
                .frame(width: 32)

            // Serial + model (+ MDM subtitle when present)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.serialNumber)
                    .font(.callout).fontWeight(.semibold).fontDesign(.monospaced)
                Text(modelLabel)
                    .font(.callout).foregroundStyle(.secondary)
                if let mdmSubtitle {
                    Label(mdmSubtitle, systemImage: "server.rack")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }

            Spacer()

            // Badges — coverage + source always; write-back failure only when true.
            VStack(alignment: .trailing, spacing: 4) {
                CoverageBadge(status: device.coverageStatus)
                SourceBadge(source: device.deviceSource, scopeAbbrev: scopeAbbrev)
                if let wb = device.wbStatus, wb == .failed {
                    StatusBadge(label: "WB Failed", color: .red)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct CoverageBadge: View {
    let status: CoverageStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon)
                .font(.caption2)
            Text(status.label)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12))
        .foregroundStyle(status.color)
        .clipShape(Capsule())
    }
}

struct SourceBadge: View {
    let source: DeviceSource
    let scopeAbbrev: String   // "ABM" or "ASM"

    private var label: String {
        switch source {
        case .both:     return "In Both"
        case .axmOnly:  return "\(scopeAbbrev) Only"
        case .jamfOnly: return "Jamf Only"
        }
    }
    private var icon: String {
        switch source {
        case .both:     return "arrow.triangle.2.circlepath"
        case .axmOnly:  return "applelogo"
        case .jamfOnly: return "server.rack"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(source.color.opacity(0.10))
        .foregroundStyle(source.color)
        .clipShape(Capsule())
    }
}

// MARK: - Device Detail Panel
// File-scope so CoveragePlanCard (defined outside DeviceDetailPanel) can reference it
struct CoveragePlan {
    let description:  String   // "Limited Warranty" | "AppleCare Protection Plan (123456)"
    let startDate:    String?
    let endDate:      String?
    let status:       String?
    let paymentType:  String?
    let isCanceled:   Bool
    let isRenewable:  Bool
    let isBest:       Bool     // true = the record that drives overall coverage status
}

struct DeviceDetailPanel: View {
    @EnvironmentObject private var store: AppStore
    let device: Device

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }

    // Parse org device scalar attributes from stored raw JSON
    private var orgAttrs: [String: String] {
        guard let data = device.axmRawJson,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attrs = json["attributes"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, val) in attrs {
            // Skip arrays — handled separately in orgDeviceRows() with join
            if val is [Any] { continue }
            if let s = val as? String        { result[key] = s }
            else if let i = val as? Int      { result[key] = String(i) }
            else if let d = val as? Double   { result[key] = String(d) }
            else if let b = val as? Bool     { result[key] = b ? "true" : "false" }
            // nil / NSNull — omit so the row is hidden entirely
        }
        return result
    }

    // Best model string: deviceModel from JSON > productDescription > axmDeviceClass-derived
    private var bestModelLabel: String {
        if let m = orgAttrs["deviceModel"], !m.isEmpty { return m }
        if let m = device.axmModel, !m.isEmpty         { return m }
        if let m = device.jamfModel, !m.isEmpty        { return m }
        if let cls = device.axmDeviceClass, !cls.isEmpty {
            switch cls.uppercased() {
            case "MAC": return "Mac"; case "IPAD": return "iPad"
            case "IPHONE": return "iPhone"; case "APPLETV": return "Apple TV"
            default: return cls.capitalized
            }
        }
        return "Apple Device"
    }

    // MDM assignment status from org JSON
    private var mdmStatus: String? { orgAttrs["status"] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ──────────────────────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: device.modelIcon)
                        .font(.system(size: 28))
                        .foregroundStyle(device.deviceSource.color)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.serialNumber)
                            .font(.title2).fontWeight(.bold).fontDesign(.monospaced)
                        Text(bestModelLabel)
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    Spacer()

                    // MDM + Coverage status — top right, matching screenshot
                    VStack(alignment: .trailing, spacing: 6) {
                        if let mdm = mdmStatus, !mdm.isEmpty {
                            HStack(spacing: 6) {
                                Text("MDM").font(.caption).foregroundStyle(.secondary)
                                Text(mdm).font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                            }
                        }
                        if let mdmServer = device.assignedMdmServerName, !mdmServer.isEmpty {
                            HStack(spacing: 6) {
                                Text("MDM SERVER").font(.caption).foregroundStyle(.secondary)
                                Text(mdmServer).font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(.purple)
                                    .lineLimit(1)
                            }
                        } else if device.axmAssignmentStatus == "Unassigned" {
                            HStack(spacing: 6) {
                                Text("MDM SERVER").font(.caption).foregroundStyle(.secondary)
                                Text("Unassigned").font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("COVERAGE").font(.caption).foregroundStyle(.secondary)
                            Text(device.coverageStatus.label)
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(device.coverageStatus.color)
                        }
                        if let wb = device.wbStatus {
                            HStack(spacing: 6) {
                                Text("JAMF").font(.caption).foregroundStyle(.secondary)
                                Text(wb.label).font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(wb.color)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // 5.4: quick actions — Copy Serial always available; Copy Jamf ID
                // and Open in Jamf Pro only when there's something to act on.
                HStack(spacing: 8) {
                    Button { copyToPasteboard(device.serialNumber) } label: {
                        Label("Copy Serial", systemImage: "doc.on.doc")
                    }
                    if let jamfId = device.jamfId, !jamfId.isEmpty {
                        Button { copyToPasteboard(jamfId) } label: {
                            Label("Copy Jamf ID", systemImage: "number")
                        }
                    }
                    if let url = jamfConsoleURL(for: device, jamfBaseURL: store.jamfCredentials.url) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("Open in Jamf Pro", systemImage: "arrow.up.forward.square")
                        }
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Divider()

                // Sections in a VStack with consistent spacing between cards
                VStack(alignment: .leading, spacing: 12) {

                    // ── Device Attributes (from Apple Org API JSON) ─────
                    if device.deviceSource != .jamfOnly && !orgAttrs.isEmpty {
                        AppleAttrSection(
                            title: "Device Attributes",
                            icon: device.modelIcon,
                            rows: orgDeviceRows(),
                            fetchLabel: "Device fetched",
                            fetchedAt: device.axmDeviceFetchedAt.flatMap { formatISO($0) }
                        )
                    }

                    // ── Coverage section ────────────────────────────────
                    if device.deviceSource != .jamfOnly {
                        let plans = coveragePlans
                        if !plans.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                // Header bar
                                HStack(spacing: 6) {
                                    Image(systemName: "shield.lefthalf.filled")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("AppleCare Coverage")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.separatorColor).opacity(0.15))

                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                                        CoveragePlanCard(plan: plan)
                                    }
                                    if let fetched = device.axmCoverageFetchedAt.flatMap({ formatISO($0) }) {
                                        HStack {
                                            Text("Coverage fetched")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(fetched)
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(12)
                            }
                            .background(.background.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                            )
                            .padding(.horizontal, 16)

                        } else if device.coverageStatus == .notFetched {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: "shield.lefthalf.filled")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("AppleCare Coverage")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.separatorColor).opacity(0.15))

                                HStack(spacing: 4) {
                                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                                    .help("This device exists in Apple Business/School Manager but has never been enrolled into Jamf Pro — it has no Jamf record yet")
                                    Text("Coverage will be fetched on the next sync run.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(12)
                            }
                            .background(.background.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                            )
                            .padding(.horizontal, 16)
                        }
                    }

                    // ── MDM Assignment section ──────────────────────────
                    if device.deviceSource != .jamfOnly, device.axmDeviceId != nil {
                        if let mdmName = device.assignedMdmServerName, !mdmName.isEmpty {
                            DetailSection(title: "MDM Assignment", icon: "server.rack") {
                                DetailGridRow(
                                    left:  ("MDM Server", mdmName),
                                    right: ("Type", device.mdmServerType.flatMap { MdmServerType(rawValue: $0)?.label } ?? device.mdmServerType)
                                )
                                if let serverId = device.assignedMdmServerId {
                                    DetailAttrRow(label: "Server ID", value: serverId)
                                }
                            }
                        } else {
                            DetailSection(title: "MDM Assignment", icon: "questionmark.circle") {
                                HStack(spacing: 6) {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Not assigned to any MDM server")
                                            .font(.callout)
                                        Text("This device is registered in Apple Business/School Manager but has not been assigned to a Device Management Service.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    // ── Jamf Pro section ────────────────────────────────
                    if device.deviceSource != .axmOnly {
                        DetailSection(title: "Jamf Pro", icon: "server.rack") {

                            // Identity
                            DetailGridRow(left:  ("Jamf ID",  device.jamfId),
                                          right: ("Name",     device.jamfName))
                            DetailGridRow(left:  ("Model",    device.jamfModel),
                                          right: ("MAC",      device.jamfMacAddress))

                            // Hardware — processorType/RAM only populated for computers (v4 hardware section)
                            DetailGridRow(left:  ("Processor", device.jamfProcessorType),
                                          right: ("RAM",       device.jamfRamGB.map { "\($0) GB" }))

                            // System
                            DetailGridRow(left:  ("OS Version",  device.jamfOsVersion),
                                          right: ("FileVault",   device.jamfFileVaultStatus))
                            DetailGridRow(left:  ("Username",    device.jamfUsername),
                                          right: ("Managed",     device.isManaged ? "Yes" : "No"))

                            // Activity timestamps — two per row to save vertical space
                            DetailGridRow(
                                left:  ("Report Date",  device.jamfReportDate.flatMap  { formatISO($0) }),
                                right: ("Last Contact", device.jamfLastContact.flatMap { formatISO($0) })
                            )
                            // Enrolled Date (initialEntryDate) is when the device was first ever
                            // added to Jamf; Last Enrolled is its most recent re-enrollment — the
                            // two can differ for a device that's been wiped and re-enrolled since.
                            DetailGridRow(
                                left:  ("Enrolled Date", device.jamfInitialEntryDate),
                                right: ("Last Enrolled", device.jamfLastEnrolled.flatMap { formatISO($0) })
                            )
                            if let v = device.jamfMdmCertExpiration.flatMap({ formatISO($0) }) {
                                DetailAttrRow(label: "MDM Cert Expires", value: v)
                            }

                            // Warranty
                            DetailGridRow(left:  ("Warranty Date", device.jamfWarrantyDate),
                                          right: ("AppleCare ID",  device.jamfAppleCareId))
                            if let vendor = device.jamfVendor, !vendor.isEmpty {
                                DetailAttrRow(label: "Vendor", value: vendor)
                            }
                        }
                    }

                    // ── Jamf Update section ─────────────────────────────
                    if device.deviceSource != .axmOnly {
                        DetailSection(title: "Jamf Update", icon: "arrow.up.to.line.circle.fill") {
                            DetailGridRow(left: ("Status",    device.wbStatus?.label ?? "Not run"),
                                          right: ("Pushed At", device.wbPushedAt.flatMap { formatISO($0) }))
                            if let note = device.wbNote, !note.isEmpty {
                                DetailAttrRow(label: "Note", value: note)
                            }
                        }
                    }

                    if device.deviceSource == .axmOnly, let note = device.wbNote, !note.isEmpty {
                        DetailSection(title: "Jamf", icon: "exclamationmark.triangle.fill") {
                            DetailAttrRow(label: "Note", value: note)
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
        }
        .background(.background.secondary)
    }

    // MARK: - Row builders
    private func orgDeviceRows() -> [(String, String)] {
        // Parse array fields from raw JSON (ethernetMacAddress, imei, meid)
        var arrayFields: [String: String] = [:]
        if let data = device.axmRawJson,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let attrs = json["attributes"] as? [String: Any] {
            for key in ["ethernetMacAddress", "imei", "meid"] {
                if let arr = attrs[key] as? [String], !arr.isEmpty {
                    arrayFields[key] = arr.joined(separator: ", ")
                }
            }
        }

        // All fields in display order, matching the Apple API attribute names exactly
        let orderedKeys: [(String, String?)] = [
            ("serialNumber",            orgAttrs["serialNumber"]),
            ("deviceModel",             orgAttrs["deviceModel"]),
            ("productFamily",           orgAttrs["productFamily"]),
            ("productType",             orgAttrs["productType"]),
            ("deviceCapacity",          orgAttrs["deviceCapacity"]),
            ("color",                   orgAttrs["color"]),
            ("status",                  orgAttrs["status"]),
            ("purchaseSourceType",      orgAttrs["purchaseSourceType"]),
            ("purchaseSourceId",        orgAttrs["purchaseSourceId"]),
            ("partNumber",              orgAttrs["partNumber"]),
            ("orderNumber",             orgAttrs["orderNumber"]),
            ("orderDateTime",           orgAttrs["orderDateTime"]),
            ("addedToOrgDateTime",      orgAttrs["addedToOrgDateTime"]),
            ("updatedDateTime",         orgAttrs["updatedDateTime"]),
            ("releasedFromOrgDateTime", orgAttrs["releasedFromOrgDateTime"]),
            ("wifiMacAddress",          orgAttrs["wifiMacAddress"]?.isEmpty == false ? orgAttrs["wifiMacAddress"] : nil),
            ("bluetoothMacAddress",     orgAttrs["bluetoothMacAddress"]?.isEmpty == false ? orgAttrs["bluetoothMacAddress"] : nil),
            ("ethernetMacAddress",      arrayFields["ethernetMacAddress"]),
            ("imei",                    arrayFields["imei"]),
            ("meid",                    arrayFields["meid"]),
            ("eid",                     orgAttrs["eid"]?.isEmpty == false ? orgAttrs["eid"] : nil),
            ("isMdmMigrationCapable",   orgAttrs["isMdmMigrationCapable"]),
            ("mdmMigrationStatus",      orgAttrs["mdmMigrationStatus"]),
            ("mdmMigrationDeadlineDateTime", orgAttrs["mdmMigrationDeadlineDateTime"]),
        ]
        return orderedKeys.compactMap { label, value in
            guard let v = value, !v.isEmpty else { return nil }
            return (label, v)
        }
    }

    // Parse all coverage plan records from raw JSON — one entry per plan
    private var coveragePlans: [CoveragePlan] {
        guard let data = device.axmCoverageRawJson,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else { return [] }

        // Find the id with the latest endDateTime to mark as "best"
        let bestId = dataArr
            .compactMap { record -> (String, String)? in
                guard let attrs = record["attributes"] as? [String: Any],
                      let end = attrs["endDateTime"] as? String,
                      let id = record["id"] as? String else { return nil }
                return (id, end)
            }
            .max(by: { $0.1 < $1.1 })?.0

        return dataArr.compactMap { record -> CoveragePlan? in
            guard let attrs = record["attributes"] as? [String: Any] else { return nil }
            let id          = record["id"] as? String ?? ""
            let desc        = attrs["description"] as? String ?? "Coverage Plan"
            let agreement   = attrs["agreementNumber"] as? String
            // Title: "AppleCare Protection Plan (325381091634)" or just "Limited Warranty"
            let title       = agreement != nil ? "\(desc) (\(agreement!))" : desc
            let start       = (attrs["startDateTime"] as? String).flatMap { formatShortDate($0) }
            let end         = (attrs["endDateTime"] as? String).flatMap { formatShortDate($0) }
            let status      = attrs["status"] as? String
            let payment     = attrs["paymentType"] as? String
            let canceled    = attrs["isCanceled"] as? Bool ?? false
            let renewable   = attrs["isRenewable"] as? Bool ?? false
            return CoveragePlan(
                description: title,
                startDate:   start,
                endDate:     end,
                status:      status,
                paymentType: payment,
                isCanceled:  canceled,
                isRenewable: renewable,
                isBest:      id == bestId
            )
        }
    }

    // Format ISO date to DD/MM/YYYY matching the screenshot style
    private func formatShortDate(_ iso: String) -> String? {
        if let date = _isoPlainParser.date(from: iso) {
            return _shortDateFmt.string(from: date)
        }
        // Try without time component (plain YYYY-MM-DD)
        if let d = _ymDateParser.date(from: String(iso.prefix(10))) {
            return _shortDateFmt.string(from: d)
        }
        return String(iso.prefix(10))
    }
}

// MARK: - Coverage Plan Card (matches screenshot style)
struct CoveragePlanCard: View {
    let plan: CoveragePlan

    // 4.10: a plan whose own status is ACTIVE (and not cancelled) still has time
    // left — its end date is a future "Expires", not a past "Expired on". A
    // device can hold several historical plans, so this is read per-card, not
    // from the device's overall coverageStatus.
    private var isActive: Bool {
        plan.status?.uppercased() == "ACTIVE" && !plan.isCanceled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Plan title — "Limited Warranty" or "AppleCare Protection Plan (325381091634)"
            HStack(spacing: 6) {
                Text(plan.description)
                    .font(.callout)
                    .foregroundStyle(.primary)
                if plan.isBest {
                    Text("Current")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }

            // Start / Expiry row — two columns matching screenshot
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Date")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(plan.startDate ?? "—")
                        .font(.callout).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isActive ? "Expires" : "Expired on")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(plan.endDate ?? "—")
                        .font(.callout).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Apple attribute section (two-column grid matching screenshot)
struct AppleAttrSection: View {
    let title:      String
    let icon:       String
    let rows:       [(String, String)]
    let fetchLabel: String
    let fetchedAt:  String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar — matches DetailSection style
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.separatorColor).opacity(0.15))

            // Two-column attribute grid
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(row.1)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)

            // Fetch timestamp footer
            if let fetched = fetchedAt {
                HStack {
                    Text(fetchLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(fetched)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Detail sub-components
struct DetailSection<Content: View>: View {
    let title:   String
    let icon:    String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.separatorColor).opacity(0.15))

            // Content
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

// Two-column row for compact Jamf/update sections
struct DetailGridRow: View {
    let left:  (String, String?)
    let right: (String, String?)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let v = left.1, !v.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(left.0).font(.caption).foregroundStyle(.secondary)
                    Text(v).font(.callout).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
            if let v = right.1, !v.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(right.0).font(.caption).foregroundStyle(.secondary)
                    Text(v).font(.callout).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }
}

// Single full-width attr row
struct DetailAttrRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Date formatting helpers
// P6: Static formatters — formatISO() was allocating 3 DateFormatter/ISO8601DateFormatter
// instances on every call. Called for every date field in the detail panel on every render.
// Statics are initialised once and shared across all calls.
// ISO8601DateFormatter is not Sendable-audited — nonisolated(unsafe), read-only.
nonisolated(unsafe) private let _isoFracParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
nonisolated(unsafe) private let _isoPlainParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Convert an ISO-8601 string (from CoreData/Apple APIs) to a readable local format.
/// Returns nil if the string is not parseable, so the caller hides the field cleanly.
private func formatISO(_ iso: String) -> String? {
    if let date = _isoFracParser.date(from: iso) {
        return _detailDateFmt.string(from: date)
    }
    // Try without fractional seconds
    if let date = _isoPlainParser.date(from: iso) {
        return _detailDateFmt.string(from: date)
    }
    // Already a plain date (YYYY-MM-DD from coverage end)
    if iso.count == 10 { return iso }
    return iso  // pass through as-is
}

private let _detailDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

// Additional statics used by formatShortDate inside DeviceDetailPanel
private let _shortDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .none
    return f
}()
private let _ymDateParser: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()

// MARK: - Multi-device selection panel (5.3)
// Shown in the detail pane when 2+ rows are selected — a bulk-action summary
// rather than trying to show N devices' worth of detail at once.
struct MultiDeviceSelectionPanel: View {
    @EnvironmentObject private var store: AppStore
    let devices: [Device]

    @State private var csvDocument:   CSVDocument? = nil
    @State private var showFilePicker = false
    @State private var didCopy        = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text("^[\(devices.count) device](inflect: true) selected")
                .font(.headline)
            Text("Choose an action for the selected devices.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Button {
                    let serials = devices.map(\.serialNumber).joined(separator: "\n")
                    copyToPasteboard(serials)
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy Serial Numbers",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .onChange(of: devices) { _, _ in didCopy = false }

                Button {
                    let data = store.buildCSVData(from: devices)
                    csvDocument = CSVDocument(csvData: data)
                    showFilePicker = true
                } label: {
                    Label("Export Selection…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
        .fileExporter(
            isPresented: $showFilePicker,
            document: csvDocument ?? CSVDocument(csvData: Data()),
            contentType: .commaSeparatedText,
            defaultFilename: "device_selection_\(devices.count)"
        ) { _ in
            csvDocument = nil
        }
    }
}

// MARK: - Placeholder
struct DeviceDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select a device")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Click any device in the list to view its full details.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }
}
