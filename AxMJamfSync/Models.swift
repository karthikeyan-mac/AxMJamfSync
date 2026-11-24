// Models.swift
// Shared value types and enums used across all layers.
//
// Device: plain Swift struct (Identifiable, Hashable) — safe to pass across actor boundaries.
//   Produced by CDDevice.toDevice() inside a CoreData perform{} block.
//   SyncDevice: mutable intermediate used during merge (off-actor, free function).
//
// AxMCredentials / JamfCredentials: credential bundles stored in Keychain.
//   pageSize default = 1000 (slider range 100…2000).
//
// DeviceSource: .axmOnly / .jamfOnly / .both — set by mergeDevicesOffActor().
//   Jamf loop guard: axmDeviceId != nil required before marking .both.

import Foundation
import SwiftUI

// MARK: - Device Source
enum DeviceSource: String, CaseIterable, Codable {
    case both     = "BOTH"
    case axmOnly  = "AXM_ONLY"
    case jamfOnly = "JAMF_ONLY"

    var label: String {
        switch self {
        case .both:     return "In Both"
        case .axmOnly:  return "AxM Only"
        case .jamfOnly: return "Jamf Only"
        }
    }
    var color: Color {
        switch self {
        case .both:     return .green
        case .axmOnly:  return .blue
        case .jamfOnly: return .orange
        }
    }
    var icon: String {
        switch self {
        case .both:     return "checkmark.circle.fill"
        case .axmOnly:  return "applelogo"
        case .jamfOnly: return "server.rack"
        }
    }
}

// MARK: - Coverage Status
enum CoverageStatus: String, CaseIterable, Codable {
    case active     = "ACTIVE"
    case inactive   = "INACTIVE"
    case expired    = "EXPIRED"
    case cancelled  = "CANCELLED"
    case noCoverage = "NO_COVERAGE"
    case notFetched = "NOT_FETCHED"

    var label: String {
        switch self {
        case .active:                        return "In Warranty"
        case .inactive, .expired, .cancelled: return "Out of Warranty"
        case .noCoverage:                    return "No Coverage Info"
        case .notFetched:                    return "Not Fetched"
        }
    }
    var color: Color {
        switch self {
        case .active:                        return .green
        case .inactive, .expired, .cancelled: return .red
        case .noCoverage:                    return .orange
        case .notFetched:                    return .secondary
        }
    }
    var icon: String {
        switch self {
        case .active:                        return "checkmark.shield.fill"
        case .inactive, .expired, .cancelled: return "xmark.shield.fill"
        case .noCoverage:                    return "questionmark.circle.fill"
        case .notFetched:                    return "clock.fill"
        }
    }
    static func from(_ raw: String?) -> CoverageStatus {
        guard let raw, !raw.isEmpty else { return .notFetched }
        return CoverageStatus(rawValue: raw.uppercased()) ?? .inactive
    }
}

// MARK: - Jamf Update Status
enum WBStatus: String, Codable {
    case pending = "PENDING"
    case synced  = "SYNCED"
    case failed  = "FAILED"
    case skipped = "SKIPPED"

    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .pending: return .orange
        case .synced:  return .green
        case .failed:  return .red
        case .skipped: return .secondary
        }
    }
}

// MARK: - Jamf mapping validation (S2)
/// Whether a device's cached serial→Jamf-ID mapping has been confirmed against the
/// currently configured Jamf host. Set to `.pendingRevalidation` the instant the Jamf
/// URL/clientId changes; flipped back to `.validated` per-device only when that serial
/// is freshly re-matched during a merge against the new host. A nil stored value (pre-S2
/// row) is treated as `.validated` — see `Device.jamfMappingValidated`.
enum JamfValidationStatus: String {
    case validated          = "validated"
    case pendingRevalidation = "pendingRevalidation"
}

/// Which device types to include in coverage fetch and Jamf write-back.
/// The Apple org devices fetch always runs in full regardless of this setting.
enum SyncDeviceScope: String, CaseIterable, Codable {
    case both   = "both"
    case mac    = "mac"
    case mobile = "mobile"

    var label: String {
        switch self {
        case .both:   return "Mac + Mobile"
        case .mac:    return "Mac Only"
        case .mobile: return "Mobile Only"
        }
    }
    var icon: String {
        switch self {
        case .both:   return "rectangle.stack.fill"
        case .mac:    return "laptopcomputer"
        case .mobile: return "iphone"
        }
    }
}

/// Filter kind for the Devices view — "Macs" vs "Mobile Devices".
/// Derived from ABM productFamily (most reliable) and Jamf deviceType.
enum DeviceKind: String, CaseIterable {
    case mac    = "Macs"
    case mobile = "Mobile Devices"

    var icon: String {
        switch self {
        case .mac:    return "desktopcomputer"
        case .mobile: return "iphone"
        }
    }
}

// MARK: - Dashboard Focus
/// Which system's data the Dashboard tab is scoped to.
/// .common = today's mixed reconciliation view (unchanged).
/// .axm/.jamf isolate the dashboard to one source system's own attributes,
/// so e.g. a device retired in real life but not yet released from AxM
/// simply won't appear in .jamf focus (it has no Jamf record).
enum DashboardFocus: String, CaseIterable, Identifiable, Codable {
    case common = "COMMON"
    case axm    = "AXM"
    case jamf   = "JAMF"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .common: return "Default"
        case .axm:    return "Apple"
        case .jamf:   return "Jamf Pro"
        }
    }
    var icon: String {
        switch self {
        case .common: return "square.grid.2x2"
        case .axm:    return "applelogo"
        case .jamf:   return "server.rack"
        }
    }
}

// MARK: - MDM Server Type
enum MdmServerType: String {
    case mdm              = "MDM"
    case appleConfigurator = "APPLE_CONFIGURATOR"

    var label: String {
        switch self {
        case .mdm:               return "MDM"
        case .appleConfigurator: return "Apple Configurator"
        }
    }
    var icon: String {
        switch self {
        case .mdm:               return "server.rack"
        case .appleConfigurator: return "apps.iphone"
        }
    }
}


struct Device: Identifiable, Hashable {
    var id: String { serialNumber }

    let serialNumber:           String
    let deviceSource:           DeviceSource
    let axmDeviceId:            String?
    let axmDeviceStatus:        String?
    let axmDeviceFetchedAt:     String?
    let axmPurchaseSource:      String?   // purchaseSourceType
    let axmPurchaseSourceId:    String?   // purchaseSourceId
    let axmOrderNumber:         String?   // orderNumber
    let axmOrderDate:           String?   // orderDateTime YYYY-MM-DD
    let axmAddedToOrgDate:      String?   // addedToOrgDateTime YYYY-MM-DD — reliably populated, unlike orderDate
    let axmModel:               String?   // productDescription from Apple API e.g. "MacBook Pro (16-inch, 2021)"
    let axmDeviceModel:         String?   // deviceModel short string e.g. "MacBook Pro 13\""
    let axmDeviceClass:         String?   // deviceClass from Apple API e.g. "MAC" | "IPAD"
    let axmProductFamily:       String?   // productFamily from ABM API e.g. "Mac" | "iPad" | "iPhone" | "AppleTV"
    let axmCoverageStatus:      String?
    let axmCoverageEndDate:     String?
    let axmCoverageFetchedAt:   String?
    let axmAgreementNumber:     String?
    let axmWifiMacAddress:      String?
    let axmBluetoothMacAddress: String?
    let axmEthernetMacAddress:  String?   // joined ", " — ABM returns an array
    let axmImei:                String?   // joined ", " — ABM returns an array
    let axmMeid:                String?   // joined ", " — ABM returns an array
    let axmEid:                 String?
    let axmMdmMigrationCapable: String?   // "True" | "False" — tri-state, nil = not yet populated by Apple
    let axmMdmMigrationStatus:  String?   // "REQUESTED" | "STARTED" | "SUCCESS" | "FAILED"
    let axmMdmMigrationDeadline: String?  // raw ISO 8601 — never parsed to Date at this layer
    let axmActivationLock:    String?   // "MDM" | "USER" | "NONE"; nil = not fetched
    let axmActivationLockFetchedAt: String?
    let wbStatus:               WBStatus?
    let wbPushedAt:             String?
    let wbNote:                 String?
    let jamfId:                 String?
    let jamfName:               String?
    let jamfManaged:            String?
    let jamfModel:              String?
    let jamfModelIdentifier:    String?
    let jamfMacAddress:         String?
    let jamfReportDate:         String?
    let jamfLastContact:        String?
    let jamfLastEnrolled:       String?
    let jamfMdmCertExpiration:  String?   // general.mdmCertificateExpiration (date-time)
    let jamfInitialEntryDate:   String?   // general.initialEntryDate — display as "Enrolled Date"; distinct from jamfLastEnrolled (most recent re-enrollment)
    let jamfProcessorType:      String?   // hardware.processorType
    let jamfRamGB:              String?   // hardware.totalRamMegabytes, pre-converted to whole GB
    let jamfWarrantyDate:       String?
    let jamfVendor:             String?
    let jamfAppleCareId:        String?
    let jamfOsVersion:          String?
    let jamfFileVaultStatus:    String?
    let jamfUsername:           String?
    let jamfDeviceType:         String?    // "computer" | "mobile" — nil for AxM-only
    let assignedMdmServerId:    String?    // MDM server UUID from /v1/mdmServers
    let assignedMdmServerName:  String?    // e.g. "ProdJamf|Pro"
    let mdmServerType:          String?    // "MDM" | "APPLE_CONFIGURATOR"
    let jamfValidationStatus:   String?    // S2: JamfValidationStatus raw — nil = legacy row, treated as validated
    let lastValidatedJamfOrigin: String?   // S2: canonical Jamf origin the jamfId mapping was last confirmed against
    let axmRawJson:             Data?
    let axmCoverageRawJson:     Data?

    var coverageStatus: CoverageStatus { CoverageStatus.from(axmCoverageStatus) }

    // Storage stays a raw String (jamfMdmCertExpirationRaw in CoreData — see
    // PersistenceController) so an unexpected format from Jamf never silently loses
    // the source value the way the original Date-typed attempt did. This offers Date
    // semantics on demand for anything that wants to sort or bucket by it, returning
    // nil gracefully on a parse failure rather than losing data at the storage layer.
    // Confirmed format from a live payload: "2018-10-31T18:04:13Z" (no fractional
    // seconds) — the plain parser below is tried first since that's the common case;
    // the fractional one is a fallback in case a future Jamf version adds millis.
    private nonisolated(unsafe) static let mdmCertExpirationParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private nonisolated(unsafe) static let mdmCertExpirationParserFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    var jamfMdmCertExpirationDate: Date? {
        guard let raw = jamfMdmCertExpiration else { return nil }
        return Self.mdmCertExpirationParser.date(from: raw)
            ?? Self.mdmCertExpirationParserFrac.date(from: raw)
    }

    // axmMdmMigrationDeadline stays raw String in storage for the same reason —
    // Apple's own API example shows fractional seconds ("2026-03-15T17:00:00.000Z"),
    // so that parser is tried first here (opposite priority from the Jamf cert
    // date above, whose confirmed live format has none). Reuses the same two
    // formatter instances since both are just plain ISO8601 parsers underneath.
    /// nil = Activation Lock never fetched for this device.
    var activationLockLabel: String? {
        switch axmActivationLock {
        case "MDM":     return "MDM Locked"
        case "USER":    return "User Locked"
        case "NONE":    return "Not Locked"
        case "UNKNOWN": return "Unknown"
        default:        return nil
        }
    }
    var activationLockColor: Color {
        switch axmActivationLock {
        case "MDM", "USER": return .orange
        case "NONE":        return .green
        default:            return .secondary
        }
    }
    var axmMdmMigrationDeadlineDate: Date? {
        guard let raw = axmMdmMigrationDeadline else { return nil }
        return Self.mdmCertExpirationParserFrac.date(from: raw)
            ?? Self.mdmCertExpirationParser.date(from: raw)
    }

    // P2: Explicit Hashable/Equatable — auto-synthesis hashes ALL 35 fields including
    // Data blobs (axmRawJson, axmCoverageRawJson). At 50k devices this creates massive
    // overhead in Dictionary/Set operations. serialNumber is the stable unique key.
    // Equality for SwiftUI diffing checks the fields that actually drive UI updates.
    static func == (lhs: Device, rhs: Device) -> Bool {
        lhs.serialNumber      == rhs.serialNumber      &&
        lhs.deviceSource      == rhs.deviceSource      &&
        lhs.axmCoverageStatus == rhs.axmCoverageStatus &&
        lhs.axmCoverageEndDate == rhs.axmCoverageEndDate &&
        lhs.wbStatus          == rhs.wbStatus          &&
        lhs.jamfManaged       == rhs.jamfManaged        &&
        lhs.jamfOsVersion     == rhs.jamfOsVersion      &&
        lhs.jamfFileVaultStatus == rhs.jamfFileVaultStatus &&
        lhs.jamfDeviceType      == rhs.jamfDeviceType   &&
        lhs.assignedMdmServerName == rhs.assignedMdmServerName
    }
    func hash(into hasher: inout Hasher) {
        // Hash only the stable unique key — O(1) instead of hashing 35 fields.
        hasher.combine(serialNumber)
    }

    /// SF Symbol name based on Jamf model string (mirrors Jamf/ABM device type icons)
    var modelIcon: String {
        // Check all available model strings — Jamf first, then Apple short/long descriptions
        let m = (jamfModel ?? jamfModelIdentifier ?? axmDeviceModel ?? axmModel ?? "").lowercased()
        if m.contains("macbook pro")  { return "laptopcomputer" }
        if m.contains("macbook air")  { return "laptopcomputer" }
        if m.contains("macbook")      { return "laptopcomputer" }
        if m.contains("mac pro")      { return "macpro.gen3" }
        if m.contains("mac mini")     { return "macmini" }
        if m.contains("mac studio")   { return "macstudio" }
        if m.contains("imac")         { return "desktopcomputer" }
        if m.contains("ipad")         { return "ipad" }
        if m.contains("iphone")       { return "iphone" }
        if m.contains("ipod")         { return "ipodtouch" }
        if m.contains("apple tv")     { return "appletv" }
        // Fall back to deviceClass
        let cls = (axmDeviceClass ?? "").uppercased()
        if cls == "MAC"      { return "laptopcomputer" }
        if cls == "IPAD"     { return "ipad" }
        if cls == "IPHONE"   { return "iphone" }
        if cls == "APPLETV"  { return "appletv" }
        return "desktopcomputer"
    }
    var isManaged: Bool { jamfManaged?.lowercased() == "true" }

    /// S2: true unless the serial→Jamf-ID mapping is explicitly pending revalidation
    /// against the currently configured Jamf host. A nil stored status (pre-S2 row)
    /// counts as validated — the pre-fix behaviour assumed the cache was trustworthy.
    /// Jamf write-back skips any device where this is false.
    var jamfMappingValidated: Bool {
        jamfValidationStatus != JamfValidationStatus.pendingRevalidation.rawValue
    }

    /// MDM assignment status — only meaningful for devices in AxM (axmDeviceId != nil).
    /// Derived from MDM server lookup populated during sync:
    ///   "Assigned"   — device appears in an MDM server's device list
    ///   "Unassigned" — device is in AxM but not assigned to any MDM server
    ///   nil          — Jamf-only device (no AxM record, Apple has no MDM assignment info)
    var axmAssignmentStatus: String? {
        guard deviceSource != .jamfOnly, axmDeviceId != nil else { return nil }
        return assignedMdmServerId != nil ? "Assigned" : "Unassigned"
    }
    /// True when this device is an iPad/iPhone/AppleTV (uses /api/v2/mobile-devices in Jamf).
    /// Derived from ABM productFamily when available (most reliable), then Jamf deviceType.
    var isMobile: Bool {
        if let family = axmProductFamily {
            return family.caseInsensitiveCompare("Mac") != .orderedSame
        }
        return jamfDeviceType == "mobile"
    }

    /// Coarse device category for the Devices view filter chips.
    var deviceKind: DeviceKind { isMobile ? .mobile : .mac }

    // P8: Convenience copy helper — returns a new Device identical to self except
    // for the fields explicitly passed. Call sites in SyncEngine use named arguments
    // for only the fields they want to change; everything else keeps its current value.
    //
    // Swift doesn't allow instance members as default parameter values, so each
    // overridable field uses Optional as a sentinel: nil means "keep self's value",
    // a non-nil value (including .some(nil) for Optional fields) overrides it.
    // Wrap Optional fields in another Optional: pass String?? to override a String?.
    func copying(
        deviceSource:         DeviceSource?       = nil,
        axmCoverageStatus:    String??            = nil,
        axmCoverageEndDate:   String??            = nil,
        axmCoverageFetchedAt: String??            = nil,
        axmAgreementNumber:   String??            = nil,
        axmActivationLock:    String??            = nil,
        axmActivationLockFetchedAt: String??      = nil,
        wbStatus:             WBStatus??          = nil,
        wbPushedAt:           String??            = nil,
        wbNote:               String??            = nil,
        jamfWarrantyDate:     String??            = nil,
        jamfAppleCareId:      String??            = nil,
        axmCoverageRawJson:   Data??              = nil,
        jamfDeviceType:       String??            = nil,
        assignedMdmServerId:  String??            = nil,
        assignedMdmServerName: String??           = nil,
        mdmServerType:        String??            = nil
    ) -> Device {
        Device(
            serialNumber:         serialNumber,
            deviceSource:         deviceSource         ?? self.deviceSource,
            axmDeviceId:          axmDeviceId,
            axmDeviceStatus:      axmDeviceStatus,
            axmDeviceFetchedAt:   axmDeviceFetchedAt,
            axmPurchaseSource:    axmPurchaseSource,
            axmPurchaseSourceId:  axmPurchaseSourceId,
            axmOrderNumber:       axmOrderNumber,
            axmOrderDate:         axmOrderDate,
            axmAddedToOrgDate:    axmAddedToOrgDate,
            axmModel:             axmModel,
            axmDeviceModel:       axmDeviceModel,
            axmDeviceClass:       axmDeviceClass,
            axmProductFamily:     axmProductFamily      ?? self.axmProductFamily,
            axmCoverageStatus:    axmCoverageStatus    ?? self.axmCoverageStatus,
            axmCoverageEndDate:   axmCoverageEndDate   ?? self.axmCoverageEndDate,
            axmCoverageFetchedAt: axmCoverageFetchedAt ?? self.axmCoverageFetchedAt,
            axmAgreementNumber:   axmAgreementNumber   ?? self.axmAgreementNumber,
            axmWifiMacAddress:    axmWifiMacAddress,
            axmBluetoothMacAddress: axmBluetoothMacAddress,
            axmEthernetMacAddress: axmEthernetMacAddress,
            axmImei:              axmImei,
            axmMeid:              axmMeid,
            axmEid:               axmEid,
            axmMdmMigrationCapable: axmMdmMigrationCapable,
            axmMdmMigrationStatus: axmMdmMigrationStatus,
            axmMdmMigrationDeadline: axmMdmMigrationDeadline,
            axmActivationLock:    axmActivationLock    ?? self.axmActivationLock,
            axmActivationLockFetchedAt: axmActivationLockFetchedAt ?? self.axmActivationLockFetchedAt,
            wbStatus:             wbStatus             ?? self.wbStatus,
            wbPushedAt:           wbPushedAt           ?? self.wbPushedAt,
            wbNote:               wbNote               ?? self.wbNote,
            jamfId:               jamfId,
            jamfName:             jamfName,
            jamfManaged:          jamfManaged,
            jamfModel:            jamfModel,
            jamfModelIdentifier:  jamfModelIdentifier,
            jamfMacAddress:       jamfMacAddress,
            jamfReportDate:       jamfReportDate,
            jamfLastContact:      jamfLastContact,
            jamfLastEnrolled:     jamfLastEnrolled,
            jamfMdmCertExpiration: jamfMdmCertExpiration,
            jamfInitialEntryDate: jamfInitialEntryDate,
            jamfProcessorType:    jamfProcessorType,
            jamfRamGB:            jamfRamGB,
            jamfWarrantyDate:     jamfWarrantyDate     ?? self.jamfWarrantyDate,
            jamfVendor:           jamfVendor,
            jamfAppleCareId:      jamfAppleCareId      ?? self.jamfAppleCareId,
            jamfOsVersion:        jamfOsVersion,
            jamfFileVaultStatus:  jamfFileVaultStatus,
            jamfUsername:         jamfUsername,
            jamfDeviceType:       jamfDeviceType       ?? self.jamfDeviceType,
            assignedMdmServerId:  assignedMdmServerId  ?? self.assignedMdmServerId,
            assignedMdmServerName: assignedMdmServerName ?? self.assignedMdmServerName,
            mdmServerType:        mdmServerType        ?? self.mdmServerType,
            jamfValidationStatus:   jamfValidationStatus,
            lastValidatedJamfOrigin: lastValidatedJamfOrigin,
            axmRawJson:           axmRawJson,
            axmCoverageRawJson:   axmCoverageRawJson   ?? self.axmCoverageRawJson
        )
    }
}

// MARK: - Dashboard Stats (derived, not stored)
struct DashboardStats {
    var total: Int = 0; var both: Int = 0; var axmOnly: Int = 0; var jamfOnly: Int = 0
    var axmTotal: Int = 0; var axmActive: Int = 0; var axmReleased: Int = 0
    var lastAxmSync: String = "Never"
    var jamfTotal: Int = 0; var jamfManaged: Int = 0; var jamfUnmanaged: Int = 0
    var lastJamfSync: String = "Never"
    var coverageActive: Int = 0; var coverageInactive: Int = 0
    var coverageNoPlan: Int = 0; var coverageNeverFetched: Int = 0
    var lastCoverageSync: String = "Never"
    // "Expiring Soon" — active coverage only, bucketed by days until axmCoverageEndDate.
    // Non-overlapping windows (not cumulative) so the three counts can be summed safely.
    var axmExpiring30: Int = 0   // ends within 30 days
    var axmExpiring60: Int = 0   // ends 31–60 days out
    var axmExpiring90: Int = 0   // ends 61–90 days out

    // MARK: - AxM coverage expiry, scoped to devices also in Jamf (Dashboard "Jamf Pro" focus)
    // Same axmCoverageEndDate bucketing as above, but restricted to deviceSource == .both,
    // so the Jamf dashboard's card only counts devices Jamf actually has a record of.
    // Shown only when AxM is configured — there is no substitute data source when it isn't
    // (jamfWarrantyDate is a write-back artifact of AxM, not an independent Jamf signal,
    // so it's deliberately not used here).
    var axmExpiring30InJamf: Int = 0
    var axmExpiring60InJamf: Int = 0
    var axmExpiring90InJamf: Int = 0
    // Coverage distribution (In Warranty / Out of Warranty / No Coverage Info / Never
    // Fetched), same semantics as the coverageActive/Inactive/NoPlan/NeverFetched
    // fields above, but restricted to deviceSource == .both — the population the
    // Jamf dashboard's own "Coverage Distribution" card should show, since an
    // AxM-only device isn't part of the Jamf fleet this dashboard describes.
    var jamfCoverageActive:       Int = 0
    var jamfCoverageInactive:     Int = 0
    var jamfCoverageNoPlan:       Int = 0
    var jamfCoverageNeverFetched: Int = 0
    var wbSynced: Int = 0; var wbPending: Int = 0; var wbFailed: Int = 0; var wbSkipped: Int = 0
    var runAxmFetched: Int = 0; var runJamfFetched: Int = 0
    var runCovFetched: Int = 0; var runWbSynced: Int = 0; var runWbFailed: Int = 0
    // P11: Pre-computed export preset counts — calculated in the single O(n) pass
    // inside recomputeStats() so ExportView doesn't run 7 separate filter passes
    // on every AppStore @Published change during sync.
    var exportActiveCount:   Int = 0   // axmDeviceStatus == "ACTIVE"
    var exportReleasedCount: Int = 0   // axmDeviceStatus == "RELEASED"
    var exportNoCovCount:    Int = 0   // coverageStatus == .noCoverage
    var exportCovFoundCount: Int = 0   // active/inactive/expired/cancelled
    var exportCovActiveCount: Int = 0  // coverageStatus == .active
    var exportCovInactiveCount: Int = 0 // inactive/expired/cancelled
    // MDM assignment stats — only for AxM devices (jamfOnly excluded)
    var mdmAssigned:         Int = 0
    var mdmUnassigned:       Int = 0
    var mdmServerBreakdown:  [String: Int] = [:]  // serverName → device count
    var mdmMigrationCapableBreakdown: [String: Int] = [:]  // "Capable" / "Not Capable" / "Unknown" → count
    var activationLockBreakdown: [String: Int] = [:]       // Device.activationLockLabel → count; devices never fetched are omitted
    var axmMigrationStatusBreakdown: [String: Int] = [:]   // "Requested" / "In Progress" / "Success" / "Failed" → count
    var axmMigrationDeadline30: Int = 0                    // in-progress migration deadline within 30 days
    var axmMigrationDeadline60: Int = 0                    // 31–60 days out
    var axmMigrationDeadline90: Int = 0                    // 61–90 days out

    // MARK: - AxM-focus breakdowns (Dashboard "Apple" mode)
    var axmProductFamilyBreakdown:  [String: Int] = [:]  // "Mac" / "iPad" / "iPhone" / "AppleTV" → count
    var axmPurchaseSourceBreakdown: [String: Int] = [:]  // "Apple" / "Reseller" / "Manually Added" / "Unknown" → count
    var axmOrderYearBreakdown:      [String: Int] = [:]  // "2024" / "Unknown" → count, keyed by year added to org (addedToOrgDate) — orderDate is too often absent from Apple's API to be usable here

    // MARK: - Jamf-focus breakdowns (Dashboard "Jamf Pro" mode)
    // All scoped to devices that actually have a Jamf record (deviceSource != .axmOnly).
    var jamfComputerCount:        Int = 0
    var jamfMobileCount:          Int = 0
    var jamfMacOsVersionBreakdown:    [String: Int] = [:]  // macOS major version e.g. "15" → count (computers only)
    var jamfMobileOsVersionBreakdown: [String: Int] = [:]  // iOS/iPadOS/tvOS major version → count (mobile only)
    var jamfFileVaultEncrypted:   Int = 0               // computers only
    var jamfFileVaultNotEncrypted: Int = 0
    var jamfFileVaultUnknown:     Int = 0
    var jamfCheckinToday:         Int = 0
    var jamfCheckinThisWeek:      Int = 0
    var jamfCheckinThisMonth:     Int = 0                // 7–30 days since last contact
    var jamfCheckinStale:         Int = 0                // last contact > 30 days ago
    var jamfCheckinNever:         Int = 0                // no last-contact date on record
    var jamfCertExpiring30:       Int = 0               // MDM cert expiring within 30 days
    var jamfCertExpiring60:       Int = 0               // 31–60 days out
    var jamfCertExpiring90:       Int = 0               // 61–90 days out
    var jamfArchitectureBreakdown: [String: Int] = [:]  // "Apple Silicon" / "Intel" / "Unknown" → count (computers only)
    var jamfRamBreakdown:         [String: Int] = [:]   // e.g. "16 GB" → count (computers only)
    var jamfOsCurrentCount:       Int = 0                // computers on the newest major macOS version seen in this population
    var jamfOsOneBehindCount:     Int = 0
    var jamfOsTwoPlusBehindCount: Int = 0
    var jamfMobileOsCurrentCount:       Int = 0          // mobile devices on the newest major iOS/iPadOS/tvOS/visionOS version seen in this population
    var jamfMobileOsOneBehindCount:     Int = 0
    var jamfMobileOsTwoPlusBehindCount: Int = 0
}

// MARK: - AxM Scope
enum AxMScope: String, CaseIterable, Codable {
    case business = "business.api"
    case school   = "school.api"

    var label: String {
        switch self {
        case .business: return "Apple Business (ABM)"
        case .school:   return "Apple School Manager (ASM)"
        }
    }
    var baseURL: String {
        switch self {
        case .business: return "https://api-business.apple.com"
        case .school:   return "https://api-school.apple.com"
        }
    }
}

// MARK: - Sync Phase
enum SyncPhase: String {
    case idle       = "IDLE"
    case axmDevices = "AXM_DEVICES"
    case jamf       = "JAMF"
    case coverage   = "COVERAGE"
    case jamfUpdate = "WRITEBACK"
    case done       = "DONE"
    case error      = "ERROR"

    var displayLabel: String {
        switch self {
        case .idle:       return "Ready"
        case .axmDevices: return "Fetching AxM Devices…"
        case .jamf:       return "Fetching Jamf Computers…"
        case .coverage:   return "Fetching AppleCare Coverage…"
        case .jamfUpdate: return "Jamf Update in progress…"
        case .done:       return "Sync Complete"
        case .error:      return "Error"
        }
    }
}

// MARK: - Credential models (in-memory only — persisted to Keychain, never UserDefaults)
struct AxMCredentials {
    var clientId:          String   = ""
    var keyId:             String   = ""
    var scope:             AxMScope = .business
    var privateKeyPath:    String   = ""   // path only — for display/re-read
    var privateKeyContent: String   = ""   // PEM file content cached in Keychain
}

struct JamfCredentials {
    var url:          String = ""
    var clientId:     String = ""
    var clientSecret: String = ""
    var pageSize:     Int    = 1000
}

extension JamfCredentials {
    /// S2: canonical identity the serial→Jamf-ID mapping is bound to — the normalised,
    /// lowercased base URL plus the client ID. A change in either means the cached
    /// mapping was built against a different Jamf configuration and must be
    /// re-confirmed against the new host before any write-back. Matches the
    /// normalisation `JamfService.init` applies to `baseURL`.
    var canonicalOrigin: String {
        let normalized = url.hasSuffix("/") ? String(url.dropLast()) : url
        return normalized.lowercased() + "\n" + clientId
    }
}

// MARK: - Export Column
struct ExportColumn: Identifiable, Hashable {
    let id:      String
    let label:   String
    var enabled: Bool
}

// MARK: - Sample data for Previews and first-launch
extension Device {
    static let sampleDevices: [Device] = [
        Device(serialNumber: "C02FN4P0DF91", deviceSource: .both,
               axmDeviceId: "C02FN4P0DF91", axmDeviceStatus: "ACTIVE",
               axmDeviceFetchedAt: "2026-03-03T19:59:36Z", axmPurchaseSource: "APPLE", axmPurchaseSourceId: nil, axmOrderNumber: nil, axmOrderDate: nil, axmAddedToOrgDate: nil,
               axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: "Mac",
               axmCoverageStatus: "ACTIVE", axmCoverageEndDate: "2027-03-01",
               axmCoverageFetchedAt: "2026-03-03T20:07:36Z", axmAgreementNumber: "APP-123456",
               axmWifiMacAddress: "a4:5e:60:ab:cd:ef", axmBluetoothMacAddress: "a4:5e:60:ab:cd:f0", axmEthernetMacAddress: nil, axmImei: nil, axmMeid: nil, axmEid: nil, axmMdmMigrationCapable: nil, axmMdmMigrationStatus: nil, axmMdmMigrationDeadline: nil, axmActivationLock: nil, axmActivationLockFetchedAt: nil,
               wbStatus: .synced, wbPushedAt: "2026-03-03T20:10:00Z", wbNote: nil,
               jamfId: "142", jamfName: "MacBook-Pro-KM", jamfManaged: "True",
               jamfModel: "MacBook Pro 15\"", jamfModelIdentifier: "MacBookPro8,2",
               jamfMacAddress: "a4:5e:60:ab:cd:ef", jamfReportDate: "2026-03-01T00:00:00Z",
               jamfLastContact: "2026-03-03T00:00:00Z", jamfLastEnrolled: "2024-06-15T00:00:00Z",
               jamfMdmCertExpiration: "2027-01-01T00:00:00Z", jamfInitialEntryDate: "2021-05-10", jamfProcessorType: "Apple M1", jamfRamGB: "16",
               jamfWarrantyDate: "2027-03-01", jamfVendor: "Apple", jamfAppleCareId: "APP-123456", jamfOsVersion: "14.5", jamfFileVaultStatus: "ALL_ENCRYPTED", jamfUsername: "karthik.m", jamfDeviceType: "computer", assignedMdmServerId: "B996D182CC0C4298ADF7992033EA8FE6", assignedMdmServerName: "ProdJamf|Pro", mdmServerType: "MDM", jamfValidationStatus: "validated", lastValidatedJamfOrigin: nil, axmRawJson: nil, axmCoverageRawJson: nil),
        Device(serialNumber: "FVFXG2Q6Q6LR", deviceSource: .axmOnly,
               axmDeviceId: "FVFXG2Q6Q6LR", axmDeviceStatus: "ACTIVE",
               axmDeviceFetchedAt: "2026-03-03T19:59:36Z", axmPurchaseSource: "APPLE", axmPurchaseSourceId: nil, axmOrderNumber: nil, axmOrderDate: nil, axmAddedToOrgDate: nil,
               axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: nil,
               axmCoverageStatus: "NO_COVERAGE", axmCoverageEndDate: nil,
               axmCoverageFetchedAt: "2026-03-03T20:07:36Z", axmAgreementNumber: nil,
               axmWifiMacAddress: nil, axmBluetoothMacAddress: nil, axmEthernetMacAddress: nil, axmImei: nil, axmMeid: nil, axmEid: nil, axmMdmMigrationCapable: nil, axmMdmMigrationStatus: nil, axmMdmMigrationDeadline: nil, axmActivationLock: nil, axmActivationLockFetchedAt: nil,
               wbStatus: nil, wbPushedAt: nil, wbNote: nil,
               jamfId: nil, jamfName: nil, jamfManaged: nil, jamfModel: nil,
               jamfModelIdentifier: nil, jamfMacAddress: nil, jamfReportDate: nil,
               jamfLastContact: nil, jamfLastEnrolled: nil,
               jamfMdmCertExpiration: nil, jamfInitialEntryDate: nil, jamfProcessorType: nil, jamfRamGB: nil,
               jamfWarrantyDate: nil,
               jamfVendor: nil, jamfAppleCareId: nil, jamfOsVersion: nil, jamfFileVaultStatus: nil, jamfUsername: nil, jamfDeviceType: nil, assignedMdmServerId: nil, assignedMdmServerName: nil, mdmServerType: nil, jamfValidationStatus: "validated", lastValidatedJamfOrigin: nil, axmRawJson: nil, axmCoverageRawJson: nil),
        Device(serialNumber: "C02GH1Z6DTY3", deviceSource: .both,
               axmDeviceId: "C02GH1Z6DTY3", axmDeviceStatus: "ACTIVE",
               axmDeviceFetchedAt: "2026-03-03T19:59:36Z", axmPurchaseSource: "RESELLER", axmPurchaseSourceId: "RSL-001", axmOrderNumber: "PO-20190101", axmOrderDate: "2019-01-01", axmAddedToOrgDate: "2019-01-05",
               axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: "Mac",
               axmCoverageStatus: "EXPIRED", axmCoverageEndDate: "2025-01-15",
               axmCoverageFetchedAt: "2026-03-03T20:07:36Z", axmAgreementNumber: "APP-789012",
               axmWifiMacAddress: nil, axmBluetoothMacAddress: nil, axmEthernetMacAddress: nil, axmImei: nil, axmMeid: nil, axmEid: nil, axmMdmMigrationCapable: "True", axmMdmMigrationStatus: "STARTED", axmMdmMigrationDeadline: "2026-05-01T17:00:00.000Z", axmActivationLock: nil, axmActivationLockFetchedAt: nil,
               wbStatus: .failed, wbPushedAt: nil, wbNote: "HTTP 404: computer not found",
               jamfId: "201", jamfName: "MacBook-Air-Finance", jamfManaged: "True",
               jamfModel: "MacBook Air", jamfModelIdentifier: "MacBookAir10,1",
               jamfMacAddress: "f4:d4:88:11:22:33", jamfReportDate: "2026-02-28T00:00:00Z",
               jamfLastContact: "2026-02-28T00:00:00Z", jamfLastEnrolled: "2023-01-10T00:00:00Z",
               jamfMdmCertExpiration: nil, jamfInitialEntryDate: "2019-01-08", jamfProcessorType: "Apple M2", jamfRamGB: "8",
               jamfWarrantyDate: nil, jamfVendor: nil, jamfAppleCareId: nil, jamfOsVersion: nil, jamfFileVaultStatus: nil, jamfUsername: nil, jamfDeviceType: nil, assignedMdmServerId: nil, assignedMdmServerName: nil, mdmServerType: nil, jamfValidationStatus: "validated", lastValidatedJamfOrigin: nil, axmRawJson: nil, axmCoverageRawJson: nil),
        Device(serialNumber: "VMQ52LH6PF", deviceSource: .jamfOnly,
               axmDeviceId: nil, axmDeviceStatus: nil, axmDeviceFetchedAt: nil,
               axmPurchaseSource: nil, axmPurchaseSourceId: nil, axmOrderNumber: nil, axmOrderDate: nil, axmAddedToOrgDate: nil, axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: nil,
               axmCoverageStatus: nil, axmCoverageEndDate: nil,
               axmCoverageFetchedAt: nil, axmAgreementNumber: nil,
               axmWifiMacAddress: nil, axmBluetoothMacAddress: nil, axmEthernetMacAddress: nil, axmImei: nil, axmMeid: nil, axmEid: nil, axmMdmMigrationCapable: nil, axmMdmMigrationStatus: nil, axmMdmMigrationDeadline: nil, axmActivationLock: nil, axmActivationLockFetchedAt: nil,
               wbStatus: nil, wbPushedAt: nil, wbNote: nil,
               jamfId: "305", jamfName: "Mac-IT-Desk", jamfManaged: "False",
               jamfModel: "Mac mini", jamfModelIdentifier: "Macmini9,1",
               jamfMacAddress: "3c:22:fb:44:55:66", jamfReportDate: "2026-01-15T00:00:00Z",
               jamfLastContact: "2026-01-15T00:00:00Z", jamfLastEnrolled: "2022-08-20T00:00:00Z",
               jamfMdmCertExpiration: "2026-08-20T00:00:00Z", jamfInitialEntryDate: "2022-08-15", jamfProcessorType: "Intel Core i5", jamfRamGB: "16",
               jamfWarrantyDate: "2024-09-01", jamfVendor: "Apple", jamfAppleCareId: nil, jamfOsVersion: "13.6", jamfFileVaultStatus: "ALL_ENCRYPTED", jamfUsername: nil, jamfDeviceType: nil, assignedMdmServerId: nil, assignedMdmServerName: nil, mdmServerType: nil, jamfValidationStatus: "validated", lastValidatedJamfOrigin: nil, axmRawJson: nil, axmCoverageRawJson: nil),
    ]
}

extension DashboardStats {
    static let sample: DashboardStats = {
        var s = DashboardStats()
        s.total = 247; s.both = 198; s.axmOnly = 31; s.jamfOnly = 18
        s.axmTotal = 229; s.axmActive = 212; s.axmReleased = 17; s.lastAxmSync = "3 Mar 2026, 19:59"
        s.jamfTotal = 216; s.jamfManaged = 198; s.jamfUnmanaged = 18; s.lastJamfSync = "3 Mar 2026, 20:01"
        s.coverageActive = 143; s.coverageInactive = 44; s.coverageNoPlan = 25
        s.coverageNeverFetched = 17; s.lastCoverageSync = "3 Mar 2026, 20:07"
        s.wbSynced = 143; s.wbPending = 44; s.wbFailed = 8; s.wbSkipped = 3
        return s
    }()
}
