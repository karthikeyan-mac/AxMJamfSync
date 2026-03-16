// JamfService.swift
// Jamf Pro API actor — all methods are actor-isolated; token state is safe under concurrency.
//
// Auth:  POST {jamfURL}/api/v1/oauth/token  (client_credentials, OAuth2)
//        TTL = 59s from server. Token passed explicitly to concurrent PATCH tasks
//        to avoid 8× redundant fetchToken() calls.
//
// Computers: GET /api/v3/computers-inventory  (paginated, serialNumber in hardware{})
// Mobile:    GET /api/v2/mobile-devices/detail (paginated, serialNumber in hardware{})
// PATCH computer: PATCH /api/v3/computers-inventory-detail/{id}  body: {purchasing:{…}}
// PATCH mobile:   PATCH /api/v2/mobile-devices/{id}              body: {ios:{purchasing:{…}}}

import Foundation

// MARK: - Jamf API response types

private struct JamfTokenResponse: Decodable {
    let access_token: String
    let expires_in:   Int
}

/// Top-level paginated response from /api/v3/computers-inventory
private struct JamfInventoryResponse: Decodable {
    let totalCount: Int
    let results:    [JamfInventoryRecord]
}

/// One computer record — sections mirror the ?section= query params
private struct JamfInventoryRecord: Decodable {
    let id:              String
    let udid:            String?   // top-level, NOT inside general{} — confirmed from API response
    let general:         JamfGeneral?
    let hardware:        JamfHardware?
    let operatingSystem: JamfOperatingSystem?
    let purchasing:      JamfPurchasing?
    let userAndLocation: JamfUserAndLocation?
    let diskEncryption:  JamfDiskEncryption?
}

private struct JamfOperatingSystem: Decodable {
    let name:                    String?   // "macOS"
    let version:                 String?   // "14.5"
    let build:                   String?   // "23F79"
    let supplementalBuildVersion: String?
    let rapidSecurityResponse:   String?
    let activeDirectoryStatus:   String?
    let fileVault2Status:        String?   // "ALL_ENCRYPTED" | "NOT_ENCRYPTED" | "UNKNOWN"
    let softwareUpdateDeviceId:  String?
}

private struct JamfGeneral: Decodable {
    let name:              String?
    let reportDate:        String?
    let lastContactTime:   String?
    let lastEnrolledDate:  String?
    let managementId:      String?
    let remoteManagement:  JamfRemoteManagement?
    let udid:              String?
    let platform:          String?       // "Mac"
    let supervised:        Bool?
    let mdmCapable:        JamfMdmCapable?
    let enrolledViaAutomatedDeviceEnrollment: Bool?
    let itunesStoreAccountActive:             Bool?
}

private struct JamfRemoteManagement: Decodable {
    let managed:               Bool?
    let managementUsername:    String?
}

private struct JamfMdmCapable: Decodable {
    let capable:        Bool?
    let capableUsers:   [String]?
}

private struct JamfHardware: Decodable {
    let serialNumber:            String?
    let model:                   String?
    let modelIdentifier:         String?
    let macAddress:              String?
    let altMacAddress:           String?
    let processorType:           String?
    let processorArchitecture:   String?
    let processorSpeedMhz:       Int?
    let numberOfCores:           Int?
    let totalRamMegabytes:       Int?
    let batteryCapacityPercent:  Int?
    let appleSiliconStatus:      String?
    let supportsIosAppInstalls:  Bool?
}

private struct JamfPurchasing: Decodable {
    let warrantyDate:    String?
    let vendor:          String?
    let appleCareId:     String?
    let purchased:       Bool?
    let leased:          Bool?
    let poNumber:        String?
    let poDate:          String?
    let purchasePrice:   String?
    let lifeExpectancy:  Int?
}

private struct JamfUserAndLocation: Decodable {
    let username:     String?
    let realname:     String?
    let email:        String?
    let position:     String?
    let phone:        String?
    let departmentId: String?
    let buildingId:   String?
    let room:         String?
}

private struct JamfDiskEncryption: Decodable {
    let bootPartitionEncryptionDetails: JamfBootEncryption?
    let individualRecoveryKeyValidityStatus: String?   // "VALID" | "INVALID" | "UNKNOWN"
    let institutionalRecoveryKeyPresent:     Bool?
    let diskEncryptionConfigurationName:     String?
}

private struct JamfBootEncryption: Decodable {
    let partitionName:          String?
    let partitionFileVault2State: String?  // "ENCRYPTED" | "DECRYPTED" | "UNKNOWN"
    let partitionFileVault2Percent: Int?
}


/// Top-level paginated response from /api/v2/mobile-devices/detail
private struct JamfMobileInventoryResponse: Decodable {
    let totalCount: Int
    let results:    [JamfMobileRecord]
}

private struct JamfMobileRecord: Decodable {
    let mobileDeviceId: String   // normalised from "id" or "mobileDeviceId"; String or Int in JSON
    let deviceType:     String?  // "iOS" | "tvOS"
    let hardware:       JamfMobileHardware?
    let general:        JamfMobileGeneral?
    let userAndLocation: JamfMobileUserAndLocation?
    let purchasing:     JamfMobilePurchasing?

    // The /api/v2/mobile-devices/detail endpoint returns the device ID as "id" (not "mobileDeviceId").
    // The classic mobile API uses "mobileDeviceId". We handle both so the decoder never silently
    // drops records due to a missing key — which was the root cause of rawMobile always being empty.
    // Jamf also sometimes returns the id as a JSON integer instead of a string.
    private enum CodingKeys: String, CodingKey {
        case id, mobileDeviceId, deviceType, hardware, general, userAndLocation, purchasing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try "id" first (v2 detail endpoint), fall back to "mobileDeviceId" (classic API)
        if let s = try? c.decode(String.self, forKey: .id) {
            mobileDeviceId = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            mobileDeviceId = String(n)
        } else if let s = try? c.decode(String.self, forKey: .mobileDeviceId) {
            mobileDeviceId = s
        } else {
            mobileDeviceId = String(try c.decode(Int.self, forKey: .mobileDeviceId))
        }
        deviceType      = try? c.decode(String.self,                      forKey: .deviceType)
        hardware        = try? c.decode(JamfMobileHardware.self,          forKey: .hardware)
        general         = try? c.decode(JamfMobileGeneral.self,           forKey: .general)
        userAndLocation = try? c.decode(JamfMobileUserAndLocation.self,   forKey: .userAndLocation)
        purchasing      = try? c.decode(JamfMobilePurchasing.self,        forKey: .purchasing)
    }
}

private struct JamfMobileHardware: Decodable {
    let serialNumber:        String?
    let model:               String?
    let modelIdentifier:     String?
    let wifiMacAddress:      String?
    let bluetoothMacAddress: String?
    // Note: osVersion/osBuild are in general section, not hardware, for mobile devices
}

private struct JamfMobileGeneral: Decodable {
    let udid:                    String?
    let displayName:             String?   // confirmed field name from real API response
    let managed:                 Bool?     // in general{} for mobile (not remoteManagement)
    let supervised:              Bool?
    let lastInventoryUpdateDate: String?
    let lastEnrolledDate:        String?
    let ipAddress:               String?
    let osVersion:               String?
    let osBuild:                 String?
    let managementId:            String?
}

private struct JamfMobileUserAndLocation: Decodable {
    let username:   String?
    let realName:   String?
    let emailAddress: String?
    let position:   String?
    let phoneNumber: String?
    let room:       String?
    let department: String?
    let building:   String?
}

private struct JamfMobilePurchasing: Decodable {
    let purchased:          Bool?
    let poNumber:           String?
    let vendor:             String?
    let appleCareId:        String?
    let purchasePrice:      String?
    let poDate:             String?
    let warrantyDate:       String?   // some Jamf versions use warrantyDate
    let warrantyExpiresDate: String?  // others use warrantyExpiresDate (full ISO8601)

    // Normalised accessor — whichever field is populated, extract YYYY-MM-DD
    var resolvedWarrantyDate: String? {
        let raw = warrantyDate ?? warrantyExpiresDate
        guard let r = raw, !r.isEmpty else { return nil }
        return r.count >= 10 ? String(r.prefix(10)) : r
    }
}

// MARK: - JamfService

actor JamfService {

    private let baseURL:      String  // trailing slash already stripped
    private let clientId:     String
    private let clientSecret: String

    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity       = true
        cfg.requestCachePolicy         = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: TLSDelegate(), delegateQueue: nil)
    }()

    init(credentials: JamfCredentials) {
        self.baseURL      = credentials.url.hasSuffix("/")
            ? String(credentials.url.dropLast())
            : credentials.url
        self.clientId     = credentials.clientId
        self.clientSecret = credentials.clientSecret
    }

    // MARK: - Public: fetch all computers

    /// Mirrors device_sync.py → _JamfClient.fetch_all_computers()
    func fetchComputers(
        pageSize: Int = 200,
        onProgress: @MainActor (Int, Int) -> Void
    ) async throws -> [RawJamfComputer] {

        let clampedPageSize = min(max(pageSize, 10), 2000)
        var results: [RawJamfComputer] = []
        var page    = 0
        var total   = Int.max

        await onProgress(0, 0)

        // Fetch the token once before the page loop — all pages use the same token.
        // Previously validToken() was called on every page iteration, causing N log lines
        // ("fetching fresh token") and N token-endpoint hits on cold start.
        let token = try await validToken()

        while results.count < total {
            try Task.checkCancellation()

            // section must be sent as repeated query items — same as Python's list param
            // URLComponents doesn't deduplicate, so build URL manually.
            let urlStr = baseURL + "/api/v3/computers-inventory"
            guard var components = URLComponents(string: urlStr) else {
                throw JamfError.networkError("Invalid Jamf URL: \(urlStr)")
            }
            components.queryItems = [
                URLQueryItem(name: "section",    value: "GENERAL"),
                URLQueryItem(name: "section",    value: "HARDWARE"),
                URLQueryItem(name: "section",    value: "OPERATING_SYSTEM"),
                URLQueryItem(name: "section",    value: "PURCHASING"),
                URLQueryItem(name: "section",    value: "USER_AND_LOCATION"),
                URLQueryItem(name: "section",    value: "DISK_ENCRYPTION"),
                URLQueryItem(name: "page",       value: String(page)),
                URLQueryItem(name: "page-size",  value: String(clampedPageSize)),
                URLQueryItem(name: "sort",       value: "general.name:asc"),
            ]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            try await validateHTTP(response, data: data, context: "Jamf /api/v3/computers-inventory page \(page)")

            let decoded = try JSONDecoder().decode(JamfInventoryResponse.self, from: data)

            if page == 0 {
                total = decoded.totalCount
                await onProgress(0, total)
                await LogService.shared.debug("[Jamf] Page 0 — totalCount=\(decoded.totalCount)")
            }

            let batch = decoded.results
            if batch.isEmpty { break }

            // Build id→rawRecord dict once per page for O(1) per-record JSON lookup
            var rawRecordById: [String: [String: Any]] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let records = json["results"] as? [[String: Any]] {
                for rec in records {
                    if let id = rec["id"] as? String { rawRecordById[id] = rec }
                }
            }

            for record in batch {
                let hw     = record.hardware
                let serial = ((hw?.serialNumber ?? "")).uppercased().trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty else { continue }

                let g  = record.general
                let p  = record.purchasing
                let ul = record.userAndLocation
                let de = record.diskEncryption
                let os = record.operatingSystem
                let managed = g?.remoteManagement?.managed ?? false

                // P10: Use compact JSON (no .prettyPrinted) for the stored blob.
                // Pretty-printing adds ~3× size overhead per record with no benefit in storage.
                let recordRawJson: Data? = rawRecordById[record.id].flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                }

                results.append(RawJamfComputer(
                    jamfId:              record.id,
                    serialNumber:        serial,
                    udid:                record.udid ?? g?.udid,  // udid is top-level; g?.udid always nil
                    name:                g?.name,
                    managed:             managed,
                    managementUsername:  g?.remoteManagement?.managementUsername,
                    platform:            g?.platform,
                    supervised:          g?.supervised,
                    mdmCapable:          g?.mdmCapable?.capable,
                    enrolledViaADE:      g?.enrolledViaAutomatedDeviceEnrollment,
                    model:               hw?.model,
                    modelIdentifier:     hw?.modelIdentifier,
                    macAddress:          hw?.macAddress,
                    altMacAddress:       hw?.altMacAddress,
                    processorType:       hw?.processorType,
                    processorArch:       hw?.processorArchitecture,
                    processorSpeedMhz:   hw?.processorSpeedMhz,
                    numberOfCores:       hw?.numberOfCores,
                    totalRamMegabytes:   hw?.totalRamMegabytes,
                    batteryCapacityPercent: hw?.batteryCapacityPercent,
                    appleSiliconStatus:  hw?.appleSiliconStatus,
                    reportDate:          g?.reportDate,
                    lastContactTime:     g?.lastContactTime,
                    enrolledDate:        g?.lastEnrolledDate,
                    managementId:        g?.managementId,
                    warrantyDate:        p?.warrantyDate,
                    vendor:              p?.vendor,
                    appleCareId:         p?.appleCareId,
                    purchased:           p?.purchased,
                    leased:              p?.leased,
                    poNumber:            p?.poNumber,
                    poDate:              p?.poDate,
                    purchasePrice:       p?.purchasePrice,
                    lifeExpectancy:      p?.lifeExpectancy,
                    username:            ul?.username,
                    realname:            ul?.realname,
                    email:               ul?.email,
                    position:            ul?.position,
                    phone:               ul?.phone,
                    room:                ul?.room,
                    departmentId:        ul?.departmentId,
                    buildingId:          ul?.buildingId,
                    osName:              os?.name,
                    osVersion:           os?.version,
                    osBuild:             os?.build,
                    osSupplementalBuild: os?.supplementalBuildVersion,
                    osRapidResponse:     os?.rapidSecurityResponse,
                    fileVault2Status:    os?.fileVault2Status,
                    activeDirectoryStatus: os?.activeDirectoryStatus,
                    fileVaultStatus:     de?.bootPartitionEncryptionDetails?.partitionFileVault2State,
                    fileVaultPercent:    de?.bootPartitionEncryptionDetails?.partitionFileVault2Percent,
                    recoveryKeyStatus:   de?.individualRecoveryKeyValidityStatus,
                    encryptionConfig:    de?.diskEncryptionConfigurationName,
                    rawJson:             recordRawJson
                ))
            }

            page += 1
            await onProgress(results.count, total)
        }

        return results
    }

    // MARK: - Public: write back AppleCare data to Jamf purchasing fields

    /// Mirrors device_sync.py → _patch_with_backoff() + sync_jamf_writeback()
    /// PATCH /api/v3/computers-inventory-detail/{jamfId}
    /// Body: { "purchasing": { "appleCareId": "…", "warrantyDate": "YYYY-MM-DD", "vendor": "…" } }
    func writeWarrantyBack(
        jamfId:         String,
        warrantyDate:   String?,    // YYYY-MM-DD from axm_coverage_end_date
        appleCareId:    String?,    // from axm_agreement_number
        vendor:         String?,    // from axm_purchase_source
        token:          String? = nil  // pre-fetched token — avoids N concurrent validToken() calls
    ) async throws {

        // Build the purchasing dict — only include non-empty fields (matches Python pre-flight check)
        var purchasing: [String: String] = [:]
        if let v = appleCareId,  !v.isEmpty { purchasing["appleCareId"]  = v }
        if let v = warrantyDate, !v.isEmpty { purchasing["warrantyDate"] = v }
        if let v = vendor,       !v.isEmpty { purchasing["vendor"]       = v }

        guard !purchasing.isEmpty else {
            throw JamfError.noDataToWrite("All coverage fields empty for jamfId=\(jamfId)")
        }

        let resolvedToken = try await { if let t = token { return t }; return try await validToken() }()
        guard let safeId = jamfId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseURL + "/api/v3/computers-inventory-detail/\(safeId)") else {
            throw JamfError.networkError("Invalid Jamf ID: \(jamfId)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(resolvedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody   = try JSONSerialization.data(withJSONObject: ["purchasing": purchasing])

        let (_, response) = try await session.data(for: request)
        try validateHTTP(response, context: "Jamf PATCH /api/v3/computers-inventory-detail/\(jamfId)")
    }


    // MARK: - Public: fetch all mobile devices
    /// GET /api/v2/mobile-devices/detail?section=GENERAL&section=HARDWARE&section=USER_AND_LOCATION&section=PURCHASING
    func fetchMobileDevices(
        pageSize: Int = 200,
        onProgress: @MainActor (Int, Int) -> Void
    ) async throws -> [RawJamfMobileDevice] {

        let clampedPageSize = min(max(pageSize, 10), 2000)
        var results: [RawJamfMobileDevice] = []
        var page    = 0
        var total   = Int.max

        await onProgress(0, 0)

        // Token fetched once before the page loop — reused across all pages.
        let mobileToken = try await validToken()

        while results.count < total {
            try Task.checkCancellation()

            let urlStr = baseURL + "/api/v2/mobile-devices/detail"
            guard var components = URLComponents(string: urlStr) else {
                throw JamfError.networkError("Invalid Jamf URL: \(urlStr)")
            }
            components.queryItems = [
                URLQueryItem(name: "section",   value: "GENERAL"),
                URLQueryItem(name: "section",   value: "HARDWARE"),
                URLQueryItem(name: "section",   value: "USER_AND_LOCATION"),
                URLQueryItem(name: "section",   value: "PURCHASING"),
                URLQueryItem(name: "page",      value: String(page)),
                URLQueryItem(name: "page-size", value: String(clampedPageSize)),
                URLQueryItem(name: "sort",      value: "displayName:asc"),
            ]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(mobileToken)", forHTTPHeaderField: "Authorization")
            request.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            try await validateHTTP(response, data: data, context: "Jamf /api/v2/mobile-devices/detail page \(page)")

            let decoded = try JSONDecoder().decode(JamfMobileInventoryResponse.self, from: data)

            if page == 0 {
                total = decoded.totalCount
                await onProgress(0, total)
                await LogService.shared.debug("[Jamf] Mobile page 0 — totalCount=\(decoded.totalCount), decoded \(decoded.results.count) records")
            }

            let batch = decoded.results
            if batch.isEmpty {
                await LogService.shared.debug("[Jamf] Mobile page \(page) — empty batch (totalCount=\(total), collected=\(results.count)). Stopping.")
                break
            }

            // Build id→rawRecord dict for O(1) raw JSON lookup.
            // v2 mobile-devices/detail uses "id"; classic API uses "mobileDeviceId". Support both.
            var rawRecordById: [String: [String: Any]] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let records = json["results"] as? [[String: Any]] {
                for rec in records {
                    let idStr: String?
                    if      let s = rec["id"] as? String             { idStr = s }
                    else if let n = rec["id"] as? Int                { idStr = String(n) }
                    else if let s = rec["mobileDeviceId"] as? String { idStr = s }
                    else if let n = rec["mobileDeviceId"] as? Int    { idStr = String(n) }
                    else                                              { idStr = nil }
                    if let id = idStr { rawRecordById[id] = rec }
                }
            }

            for record in batch {
                let hw  = record.hardware
                let g   = record.general
                let ul  = record.userAndLocation
                let p   = record.purchasing
                // serialNumber is in hardware{} — confirmed from real API response
                let serial = (hw?.serialNumber ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty else {
                    await LogService.shared.debug("[Jamf] Mobile: skipping record — empty serial (mobileDeviceId=\(record.mobileDeviceId))")
                    continue
                }

                // OS version lives in general.osVersion per the mobile inventory API
                // (unlike computers where it's in operatingSystem section)
                let osVer = g?.osVersion

                // resolvedWarrantyDate handles both warrantyDate and warrantyExpiresDate
                // field names (Jamf version differences) and normalises to YYYY-MM-DD.
                let warrantyDate: String? = p?.resolvedWarrantyDate

                let recordRawJson: Data? = rawRecordById[record.mobileDeviceId].flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                }

                results.append(RawJamfMobileDevice(
                    jamfId:           record.mobileDeviceId,
                    serialNumber:     serial,
                    udid:             g?.udid,
                    name:             g?.displayName,
                    deviceType:       record.deviceType ?? "iOS",
                    managed:          g?.managed ?? false,
                    supervised:       g?.supervised,
                    model:            hw?.model,
                    modelIdentifier:  hw?.modelIdentifier,
                    wifiMacAddress:   hw?.wifiMacAddress,
                    osVersion:        osVer,
                    osBuild:          g?.osBuild,
                    lastInventoryUpdate: g?.lastInventoryUpdateDate,
                    lastEnrolledDate: g?.lastEnrolledDate,
                    ipAddress:        g?.ipAddress,
                    warrantyDate:     warrantyDate,
                    vendor:           p?.vendor,
                    appleCareId:      p?.appleCareId,
                    purchased:        p?.purchased,
                    poNumber:         p?.poNumber,
                    poDate:           p?.poDate,
                    purchasePrice:    p?.purchasePrice,
                    username:         ul?.username,
                    realname:         ul?.realName,
                    email:            ul?.emailAddress,
                    position:         ul?.position,
                    phone:            ul?.phoneNumber,
                    room:             ul?.room,
                    department:       ul?.department,
                    building:         ul?.building,
                    rawJson:          recordRawJson
                ))
            }

            page += 1
            await onProgress(results.count, total)
        }

        return results
    }

    // MARK: - Public: write back AppleCare data to mobile device purchasing fields
    /// PATCH /api/v2/mobile-devices/{mobileDeviceId}
    /// Body: { "ios": { "purchasing": { "appleCareId": "…", "vendor": "…", "warrantyExpiresDate": "…" } } }
    func writeWarrantyBackMobile(
        mobileDeviceId: String,
        warrantyDate:   String?,    // YYYY-MM-DD — converted to ISO8601 for mobile API
        appleCareId:    String?,
        vendor:         String?,
        token:          String? = nil  // pre-fetched token
    ) async throws {

        var purchasing: [String: String] = [:]
        if let v = appleCareId,  !v.isEmpty { purchasing["appleCareId"]         = v }
        if let v = vendor,       !v.isEmpty { purchasing["vendor"]              = v }
        // Mobile PATCH requires ISO8601 full date-time — append T00:00:00Z if plain date
        if let v = warrantyDate, !v.isEmpty {
            let iso = v.count == 10 ? v + "T00:00:00.000Z" : v
            purchasing["warrantyExpiresDate"] = iso
        }

        guard !purchasing.isEmpty else {
            throw JamfError.noDataToWrite("All coverage fields empty for mobileDeviceId=\(mobileDeviceId)")
        }

        let resolvedToken = try await { if let t = token { return t }; return try await validToken() }()
        guard let safeId = mobileDeviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseURL + "/api/v2/mobile-devices/\(safeId)") else {
            throw JamfError.networkError("Invalid mobile device ID: \(mobileDeviceId)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(resolvedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ios": ["purchasing": purchasing]])

        let (_, response) = try await session.data(for: request)
        try validateHTTP(response, context: "Jamf PATCH /api/v2/mobile-devices/\(mobileDeviceId)")
    }

    // MARK: - Token management

    func validToken() async throws -> String {
        // S2: Check in-memory cache first (fastest path)
        if let t = cachedToken, Date() < tokenExpiry.addingTimeInterval(-60) {
            let remaining = Int(tokenExpiry.timeIntervalSinceNow)
            await LogService.shared.debug("[Jamf] Token: reusing cached token — \(remaining / 60)m \(remaining % 60)s remaining.")
            return t
        }
        // S2: Check Keychain cache — survives app restarts within the 30-min TTL.
        // Without this, every cold launch fetched a new token even if the previous was valid.
        if let cached = KeychainService.loadJamfToken() {
            cachedToken = cached.token
            tokenExpiry = cached.expiry
            let remaining = Int(cached.expiry.timeIntervalSinceNow)
            await LogService.shared.debug("[Jamf] Token: restored from Keychain — \(remaining / 60)m \(remaining % 60)s remaining.")
            return cached.token
        }
        await LogService.shared.debug("[Jamf] Token: fetching fresh token from \(baseURL)/api/v1/oauth/token…")
        let (token, ttl) = try await fetchToken()
        cachedToken = token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(ttl))
        // S2: Persist the new token so the next app launch can reuse it.
        KeychainService.saveJamfToken(token, expiry: tokenExpiry)
        await LogService.shared.debug("[Jamf] Token: received — TTL \(ttl)s (\(ttl / 60)m). Saved to Keychain.")
        return token
    }

    /// Call on app exit or sync stop — clears memory cache and revokes the token server-side.
    /// Jamf endpoint: POST /api/v1/auth/invalidate-token  (no body, Bearer header)
    func invalidateToken() async {
        guard let token = cachedToken else { return }
        cachedToken = nil
        tokenExpiry = .distantPast
        // S2: Evict from Keychain so the next launch fetches fresh.
        KeychainService.clearJamfToken()
        // Best-effort server-side revoke — ignore errors (safe URL construction)
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if var components = URLComponents(string: base),
           let revokeURL = { components.path = "/api/v1/auth/invalidate-token"; return components.url }() {
            var req = URLRequest(url: revokeURL)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            _ = try? await session.data(for: req)
        }
    }

    /// Clear in-memory token without a server call (for ABM — Apple has no revoke endpoint).
    func clearToken() {
        cachedToken = nil
        tokenExpiry = .distantPast
        // S2: Evict from Keychain (mirrors invalidateToken without the server call).
        KeychainService.clearJamfToken()
    }

    private func fetchToken() async throws -> (token: String, ttl: Int) {
        // S1: Use URLComponents to safely build the token URL.
        // String concatenation breaks when baseURL has a trailing slash or query chars.
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: base) else {
            throw JamfError.invalidURL(baseURL)
        }
        components.path = "/api/v1/oauth/token"
        guard let tokenURL = components.url else {
            throw JamfError.invalidURL(baseURL)
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Percent-encode credentials — secrets may contain &, =, + characters
        func pct(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "+", with: "%2B")
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "=", with: "%3D") ?? s
        }
        request.httpBody = "grant_type=client_credentials&client_id=\(pct(clientId))&client_secret=\(pct(clientSecret))".data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            await LogService.shared.error("[Jamf] Token endpoint HTTP 401 — check clientId/clientSecret. Response: \(body)")
            throw JamfError.authError("Jamf token rejected (401) — check clientId/clientSecret")
        }
        try await validateHTTP(response, data: data, context: "Jamf /api/v1/oauth/token")

        let decoded = try JSONDecoder().decode(JamfTokenResponse.self, from: data)
        return (decoded.access_token, decoded.expires_in)
    }

    // MARK: - HTTP validation

    private func validateHTTP(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw JamfError.networkError("\(context): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JamfError.httpError(context: context, statusCode: http.statusCode)
        }
    }

    private func validateHTTP(_ response: URLResponse, data: Data, context: String) async throws {
        guard let http = response as? HTTPURLResponse else {
            await LogService.shared.error("[Jamf] \(context): no HTTP response.")
            throw JamfError.networkError("\(context): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(500) ?? "<no body>"
            await LogService.shared.error("[Jamf] \(context) HTTP \(http.statusCode) — \(body)")
            throw JamfError.httpError(context: context, statusCode: http.statusCode)
        }
    }
}

// MARK: - Output types (Sendable)

struct RawJamfComputer: Sendable {
    // Identity
    let jamfId:              String
    let serialNumber:        String
    let udid:                String?
    let name:                String?
    // General
    let managed:             Bool
    let managementUsername:  String?
    let platform:            String?
    let supervised:          Bool?
    let mdmCapable:          Bool?
    let enrolledViaADE:      Bool?
    // Hardware
    let model:               String?
    let modelIdentifier:     String?
    let macAddress:          String?
    let altMacAddress:       String?
    let processorType:       String?
    let processorArch:       String?
    let processorSpeedMhz:   Int?
    let numberOfCores:       Int?
    let totalRamMegabytes:   Int?
    let batteryCapacityPercent: Int?
    let appleSiliconStatus:  String?
    // General dates
    let reportDate:          String?
    let lastContactTime:     String?
    let enrolledDate:        String?
    let managementId:        String?
    // Purchasing
    let warrantyDate:        String?
    let vendor:              String?
    let appleCareId:         String?
    let purchased:           Bool?
    let leased:              Bool?
    let poNumber:            String?
    let poDate:              String?
    let purchasePrice:       String?
    let lifeExpectancy:      Int?
    // User and Location
    let username:            String?
    let realname:            String?
    let email:               String?
    let position:            String?
    let phone:               String?
    let room:                String?
    let departmentId:        String?
    let buildingId:          String?
    // Operating System
    let osName:              String?
    let osVersion:           String?
    let osBuild:             String?
    let osSupplementalBuild: String?
    let osRapidResponse:     String?
    let fileVault2Status:    String?
    let activeDirectoryStatus: String?
    // Disk Encryption
    let fileVaultStatus:     String?
    let fileVaultPercent:    Int?
    let recoveryKeyStatus:   String?
    let encryptionConfig:    String?
    // Raw JSON blob for full detail display
    let rawJson:             Data?
}


struct RawJamfMobileDevice: Sendable {
    // Identity
    let jamfId:           String
    let serialNumber:     String
    let udid:             String?
    let name:             String?
    let deviceType:       String    // "iOS" | "tvOS"
    // General
    let managed:          Bool
    let supervised:       Bool?
    let model:            String?
    let modelIdentifier:  String?
    let wifiMacAddress:   String?
    let osVersion:        String?
    let osBuild:          String?
    let lastInventoryUpdate: String?
    let lastEnrolledDate: String?
    let ipAddress:        String?
    // Purchasing
    let warrantyDate:     String?
    let vendor:           String?
    let appleCareId:      String?
    let purchased:        Bool?
    let poNumber:         String?
    let poDate:           String?
    let purchasePrice:    String?
    // User and Location
    let username:         String?
    let realname:         String?
    let email:            String?
    let position:         String?
    let phone:            String?
    let room:             String?
    let department:       String?
    let building:         String?
    // Raw JSON blob
    let rawJson:          Data?
}

// MARK: - JamfError

enum JamfError: LocalizedError {
    case authError(String)
    case networkError(String)
    case httpError(context: String, statusCode: Int)
    case noDataToWrite(String)
    case invalidURL(String)    // S1: malformed base URL

    var errorDescription: String? {
        switch self {
        case .authError(let m):             return "Jamf: Auth failed — \(m)"
        case .networkError(let m):          return "Jamf: Network error — \(m)"
        case .httpError(let ctx, let code): return "Jamf: HTTP \(code) from \(ctx)"
        case .noDataToWrite(let m):         return "Jamf: No data — \(m)"
        case .invalidURL(let u):            return "Jamf: Invalid URL — \(u)"
        }
    }
}
