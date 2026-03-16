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

// MARK: - Device (pure value type — loaded from CoreData, never written directly)
struct Device: Identifiable, Hashable {
    var id: String { serialNumber }

    let serialNumber:           String
    let deviceSource:           DeviceSource
    let axmDeviceId:            String?
    let axmDeviceStatus:        String?
    let axmDeviceFetchedAt:     String?
    let axmPurchaseSource:      String?
    let axmModel:               String?   // productDescription from Apple API e.g. "MacBook Pro (16-inch, 2021)"
    let axmDeviceModel:         String?   // deviceModel short string e.g. "MacBook Pro 13\""
    let axmDeviceClass:         String?   // deviceClass from Apple API e.g. "MAC" | "IPAD"
    let axmProductFamily:       String?   // productFamily from ABM API e.g. "Mac" | "iPad" | "iPhone" | "AppleTV"
    let axmCoverageStatus:      String?
    let axmCoverageEndDate:     String?
    let axmCoverageFetchedAt:   String?
    let axmAgreementNumber:     String?
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
    let jamfWarrantyDate:       String?
    let jamfVendor:             String?
    let jamfAppleCareId:        String?
    let jamfOsVersion:          String?
    let jamfFileVaultStatus:    String?
    let jamfUsername:           String?
    let jamfDeviceType:         String?    // "computer" | "mobile" — nil for AxM-only
    let axmRawJson:             Data?
    let axmCoverageRawJson:     Data?

    var coverageStatus: CoverageStatus { CoverageStatus.from(axmCoverageStatus) }

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
        lhs.jamfDeviceType      == rhs.jamfDeviceType
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
        deviceSource:         DeviceSource?       = nil,   // nil → keep self.deviceSource
        axmCoverageStatus:    String??            = nil,
        axmCoverageEndDate:   String??            = nil,
        axmCoverageFetchedAt: String??            = nil,
        axmAgreementNumber:   String??            = nil,
        wbStatus:             WBStatus??          = nil,
        wbPushedAt:           String??            = nil,
        wbNote:               String??            = nil,
        jamfWarrantyDate:     String??            = nil,
        jamfAppleCareId:      String??            = nil,
        axmCoverageRawJson:   Data??              = nil,
        jamfDeviceType:       String??            = nil
    ) -> Device {
        Device(
            serialNumber:         serialNumber,
            deviceSource:         deviceSource         ?? self.deviceSource,
            axmDeviceId:          axmDeviceId,
            axmDeviceStatus:      axmDeviceStatus,
            axmDeviceFetchedAt:   axmDeviceFetchedAt,
            axmPurchaseSource:    axmPurchaseSource,
            axmModel:             axmModel,
            axmDeviceModel:       axmDeviceModel,
            axmDeviceClass:       axmDeviceClass,
            axmProductFamily:     axmProductFamily      ?? self.axmProductFamily,
            axmCoverageStatus:    axmCoverageStatus    ?? self.axmCoverageStatus,
            axmCoverageEndDate:   axmCoverageEndDate   ?? self.axmCoverageEndDate,
            axmCoverageFetchedAt: axmCoverageFetchedAt ?? self.axmCoverageFetchedAt,
            axmAgreementNumber:   axmAgreementNumber   ?? self.axmAgreementNumber,
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
            jamfWarrantyDate:     jamfWarrantyDate     ?? self.jamfWarrantyDate,
            jamfVendor:           jamfVendor,
            jamfAppleCareId:      jamfAppleCareId      ?? self.jamfAppleCareId,
            jamfOsVersion:        jamfOsVersion,
            jamfFileVaultStatus:  jamfFileVaultStatus,
            jamfUsername:         jamfUsername,
            jamfDeviceType:       jamfDeviceType       ?? self.jamfDeviceType,
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
}

// MARK: - AxM Scope
enum AxMScope: String, CaseIterable {
    case business = "business.api"
    case school   = "school.api"

    var label: String {
        switch self {
        case .business: return "Apple Business Manager (ABM)"
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
               axmDeviceFetchedAt: "2026-03-03T19:59:36Z", axmPurchaseSource: "APPLE",
               axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: "Mac",
               axmCoverageStatus: "ACTIVE", axmCoverageEndDate: "2027-03-01",
               axmCoverageFetchedAt: "2026-03-03T20:07:36Z", axmAgreementNumber: "APP-123456",
               wbStatus: .synced, wbPushedAt: "2026-03-03T20:10:00Z", wbNote: nil,
               jamfId: "142", jamfName: "MacBook-Pro-KM", jamfManaged: "True",
               jamfModel: "MacBook Pro 15\"", jamfModelIdentifier: "MacBookPro8,2",
               jamfMacAddress: "a4:5e:60:ab:cd:ef", jamfReportDate: "2026-03-01T00:00:00Z",
               jamfLastContact: "2026-03-03T00:00:00Z", jamfLastEnrolled: "2024-06-15T00:00:00Z",
               jamfWarrantyDate: "2027-03-01", jamfVendor: "Apple", jamfAppleCareId: "APP-123456", jamfOsVersion: "14.5", jamfFileVaultStatus: "ALL_ENCRYPTED", jamfUsername: "karthik.m", jamfDeviceType: "computer", axmRawJson: nil, axmCoverageRawJson: nil),
        Device(serialNumber: "FVFXG2Q6Q6LR", deviceSource: .axmOnly,
               axmDeviceId: "FVFXG2Q6Q6LR", axmDeviceStatus: "ACTIVE",
               axmDeviceFetchedAt: "2026-03-03T19:59:36Z", axmPurchaseSource: "APPLE",
               axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: nil,
               axmCoverageStatus: "NO_COVERAGE", axmCoverageEndDate: nil,
               axmCoverageFetchedAt: "2026-03-03T20:07:36Z", axmAgreementNumber: nil,
               wbStatus: nil, wbPushedAt: nil, wbNote: nil,
               jamfId: nil, jamfName: nil, jamfManaged: nil, jamfModel: nil,
               jamfModelIdentifier: nil, jamfMacAddress: nil, jamfReportDate: nil,
               jamfLastContact: nil, jamfLastEnrolled: nil, jamfWarrantyDate: nil,
               jamfVendor: nil, jamfAppleCareId: nil, jamfOsVersion: nil, jamfFileVaultStatus: nil, jamfUsername: nil, jamfDeviceType: nil, axmRawJson: nil, axmCoverageRawJson: nil),
        Device(serialNumber: "C02GH1Z6DTY3", deviceSource: .both,
               axmDeviceId: "C02GH1Z6DTY3", axmDeviceStatus: "ACTIVE",
               axmDeviceFetchedAt: "2026-03-03T19:59:36Z", axmPurchaseSource: "RESELLER",
               axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: "Mac",
               axmCoverageStatus: "EXPIRED", axmCoverageEndDate: "2025-01-15",
               axmCoverageFetchedAt: "2026-03-03T20:07:36Z", axmAgreementNumber: "APP-789012",
               wbStatus: .failed, wbPushedAt: nil, wbNote: "HTTP 404: computer not found",
               jamfId: "201", jamfName: "MacBook-Air-Finance", jamfManaged: "True",
               jamfModel: "MacBook Air", jamfModelIdentifier: "MacBookAir10,1",
               jamfMacAddress: "f4:d4:88:11:22:33", jamfReportDate: "2026-02-28T00:00:00Z",
               jamfLastContact: "2026-02-28T00:00:00Z", jamfLastEnrolled: "2023-01-10T00:00:00Z",
               jamfWarrantyDate: nil, jamfVendor: nil, jamfAppleCareId: nil, jamfOsVersion: nil, jamfFileVaultStatus: nil, jamfUsername: nil, jamfDeviceType: nil, axmRawJson: nil, axmCoverageRawJson: nil),
        Device(serialNumber: "VMQ52LH6PF", deviceSource: .jamfOnly,
               axmDeviceId: nil, axmDeviceStatus: nil, axmDeviceFetchedAt: nil,
               axmPurchaseSource: nil, axmModel: nil, axmDeviceModel: nil, axmDeviceClass: nil, axmProductFamily: nil,
               axmCoverageStatus: nil, axmCoverageEndDate: nil,
               axmCoverageFetchedAt: nil, axmAgreementNumber: nil,
               wbStatus: nil, wbPushedAt: nil, wbNote: nil,
               jamfId: "305", jamfName: "Mac-IT-Desk", jamfManaged: "False",
               jamfModel: "Mac mini", jamfModelIdentifier: "Macmini9,1",
               jamfMacAddress: "3c:22:fb:44:55:66", jamfReportDate: "2026-01-15T00:00:00Z",
               jamfLastContact: "2026-01-15T00:00:00Z", jamfLastEnrolled: "2022-08-20T00:00:00Z",
               jamfWarrantyDate: "2024-09-01", jamfVendor: "Apple", jamfAppleCareId: nil, jamfOsVersion: "13.6", jamfFileVaultStatus: "ALL_ENCRYPTED", jamfUsername: nil, jamfDeviceType: nil, axmRawJson: nil, axmCoverageRawJson: nil),
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
