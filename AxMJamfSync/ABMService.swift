// ABMService.swift
// Apple Business/School Manager API actor.
//
// Auth:  POST https://appleid.apple.com/auth/oauth2/token  (ES256 JWT client assertion)
//        Token TTL = 3600s. Reused if >300s remaining. Cached in Keychain across relaunches.
//        HTTP 400 from coverage endpoint treated as auth failure (not HTTP 401).
//
// Devices:  GET {baseURL}/v1/orgDevices  (paginated, ABM/ASM)
// Coverage: GET {baseURL}/v1/orgDevices/{deviceId}/appleCareCoverage
//           3-concurrent tasks, each with isolated URLSession (_makeABMCoverageSession).
//           httpMaximumConnectionsPerHost=1 per session; 500ms inter-chunk gap.

import Foundation
import CryptoKit

// MARK: - Apple token endpoint constants (fixed — do NOT change to baseURL)

private let _TOKEN_ENDPOINT  = "https://account.apple.com/auth/oauth2/token"
private let _TOKEN_AUDIENCE  = "https://account.apple.com/auth/oauth2/v2/token"

// MARK: - ABM API response types

/// Token response
private struct ABMTokenResponse: Decodable {
    let access_token: String
    let token_type:   String
    let expires_in:   Int
}

/// One device record inside the `data` array
private struct ABMDeviceRecord: Codable {
    let id:         String                // AxM device UUID — used for coverage lookups
    let attributes: ABMDeviceAttributes
}

private struct ABMDeviceAttributes: Codable {
    // Core fields used in sync logic
    let serialNumber:             String?
    let purchaseSourceType:       String?
    let deviceStatus:             String?    // from top-level, not attributes
    let productDescription:       String?    // absent in real API — kept for compat
    let deviceClass:              String?    // absent in real API — kept for compat
    // All real attributes from /v1/orgDevices
    let status:                   String?    // e.g. "ASSIGNED"
    let color:                    String?    // e.g. "SPACE GRAY"
    let deviceModel:              String?    // e.g. "MacBook Pro 13\""
    let deviceCapacity:           String?    // e.g. "256GB"
    let productFamily:            String?    // e.g. "Mac"
    let productType:              String?    // e.g. "MacBookPro14,1"
    let partNumber:               String?    // e.g. "Z0UK"
    let orderNumber:              String?
    let orderDateTime:            String?
    let addedToOrgDateTime:       String?
    let updatedDateTime:          String?
    let releasedFromOrgDateTime:  String?
    let purchaseSourceId:         String?
    let wifiMacAddress:           String?
    let bluetoothMacAddress:      String?
    let ethernetMacAddress:       [String]?
    let imei:                     [String]?
    let meid:                     [String]?
    let eid:                      String?
    let isMdmMigrationCapable:    Bool?
    let mdmMigrationStatus:       String?    // "REQUESTED" | "STARTED" | "SUCCESS" | "FAILED"
    let mdmMigrationDeadlineDateTime: String?
}

/// Activation Lock response — GET /v1/orgDevices/{id}/activationLockStatus
private struct ABMActivationLockResponse: Decodable {
    let data: ABMActivationLockRecord?
}

private struct ABMActivationLockRecord: Decodable {
    let attributes: ABMActivationLockAttributes?
}

private struct ABMActivationLockAttributes: Decodable {
    let isLocked: Bool?
    let lockType: String?   // "MDM" | "USER" | "NONE"
}

/// Paginated list response
private struct ABMDeviceListResponse: Decodable {
    let data: [ABMDeviceRecord]
    let meta: ABMMeta?
}

private struct ABMMeta: Decodable {
    let paging: ABMPaging?
}

private struct ABMPaging: Decodable {
    let nextCursor: String?
}

/// Coverage response — data array of plan records
private struct ABMCoverageListResponse: Decodable {
    let data: [ABMCoverageRecord]?
}

private struct ABMCoverageRecord: Decodable {
    let id:         String?           // agreement number or device serial for Limited Warranty
    let attributes: ABMCoverageAttributes?
}

private struct ABMCoverageAttributes: Decodable {
    let status:                   String?   // "ACTIVE" | "INACTIVE" | "EXPIRED" | "CANCELLED"
    let description:              String?   // "Limited Warranty" | "AppleCare Protection Plan"
    let startDateTime:            String?
    let endDateTime:              String?
    let agreementNumber:          String?   // null for Limited Warranty
    let paymentType:              String?   // "NONE" | "PAID_UP_FRONT"
    let isCanceled:               Bool?
    let isRenewable:              Bool?
    let contractCancelDateTime:   String?
}

// MARK: - MDM Server response types

private struct ABMMdmServerListResponse: Decodable {
    let data: [ABMMdmServerRecord]
    let meta: ABMMeta?
}

private struct ABMMdmServerRecord: Decodable {
    let id:         String
    let attributes: ABMMdmServerAttributes
}

private struct ABMMdmServerAttributes: Decodable {
    let serverName: String?
    let serverType: String?   // "MDM" | "APPLE_CONFIGURATOR"
}

private struct ABMMdmDeviceLinkResponse: Decodable {
    let data: [ABMMdmDeviceLink]
    let meta: ABMMeta?
}

private struct ABMMdmDeviceLink: Decodable {
    let id: String   // serial number
}

// MARK: - ABMService

/// File-scope factory — Swift does not allow `Self` in stored property initialisers.
func _makeABMCoverageSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest     = 45
    cfg.timeoutIntervalForResource    = 180
    cfg.waitsForConnectivity          = true
    // Single connection — Apple's coverage API is sensitive to concurrent streams.
    cfg.httpMaximumConnectionsPerHost = 1
    cfg.requestCachePolicy            = .reloadIgnoringLocalCacheData
    return URLSession(configuration: cfg, delegate: TLSDelegate(), delegateQueue: nil)
}

actor ABMService {

    // MARK: Configuration
    private let baseURL:           String   // e.g. "https://api-business.apple.com"
    private let clientId:          String
    private let keyId:             String
    private let privateKeyContent: String  // PEM content stored in Keychain — never read from file
    private let scope:             AxMScope // needed for Keychain token persistence
    private let environmentId:     UUID     // S1: token cache namespace — immutable, passed at init
    private let tokenIdentity:     String   // S1: SHA-256(origin + clientId) the cached token is bound to
    // S9: this environment's scoped log — every diagnostic here is about one env's run.
    private let log: LogService

    // MARK: Token cache (within this actor's lifetime)
    private var cachedToken:  String?
    private var tokenExpiry:  Date = .distantPast

    // MARK: URLSession
    // One session for token + org-device fetches (fast, parallel-safe)
    // `var` so it can be recreated after an HTTP/2 -1005 connection reset mid-fetch.
    private var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 600  // 10-min budget per request — large pages can take >2s
        cfg.waitsForConnectivity       = true
        cfg.requestCachePolicy         = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: TLSDelegate(), delegateQueue: nil)
    }()

    /// Recreate the org-device URL session after a -1005 HTTP/2 connection reset.
    /// Apple's API server closes the HTTP/2 connection after ~20 pages (~20k devices);
    /// a fresh session opens a new TCP connection for the retry.
    private func resetOrgDeviceSession() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity       = true
        cfg.requestCachePolicy         = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: TLSDelegate(), delegateQueue: nil)
    }

    // Dedicated session for AppleCare coverage requests.
    // httpMaximumConnectionsPerHost = 1 forces all requests through a single
    // persistent connection. On -1005 (connection reset / invalid HTTP/2 header),
    private var coverageSession: URLSession = _makeABMCoverageSession()


    // MARK: Init
    init(credentials: AxMCredentials, environmentId: UUID, log: LogService) {
        self.baseURL           = credentials.scope.baseURL
        self.clientId          = credentials.clientId
        self.keyId             = credentials.keyId
        self.privateKeyContent = credentials.privateKeyContent
        self.scope             = credentials.scope
        self.environmentId     = environmentId
        self.log               = log
        self.tokenIdentity     = KeychainService.tokenIdentity(origin: credentials.scope.baseURL,
                                                               clientId: credentials.clientId)

        let scopeLabel = credentials.scope == .school ? "ASM" : "ABM"

        // ── Credential diagnostics ────────────────────────────────────────────
        Task { @MainActor in
            let cidStatus = credentials.clientId.isEmpty  ? "missing" : "present"
            let kidStatus = credentials.keyId.isEmpty     ? "missing" : "present"
            log.debug("[\(scopeLabel)] Credentials — clientId: \(cidStatus) keyId: \(kidStatus) scope: \(credentials.scope.rawValue)")
            log.debug("[\(scopeLabel)] Base URL: \(credentials.scope.baseURL)")
            let hasKey = !credentials.privateKeyContent.isEmpty
            log.debug("[\(scopeLabel)] Private key: \(hasKey ? "present (\(credentials.privateKeyContent.count) chars)" : "⚠ MISSING — auth will fail")")
        }

        // ── Keychain token check ─────────────────────────────────────────────
        if let cached = KeychainService.loadAxMTokenForEnv(identity: tokenIdentity, scope: credentials.scope, envId: environmentId) {
            self.cachedToken = cached.token
            self.tokenExpiry = cached.expiry
            let remaining = Int(cached.expiry.timeIntervalSinceNow)
            let mins = remaining / 60
            Task { @MainActor in
                log.debug("[\(scopeLabel)] Keychain token: found — expires in \(mins)m (\(remaining)s), will \(remaining > 60 ? "reuse" : "refresh (< 60s remaining)").")
            }
        } else {
            Task { @MainActor in
                log.debug("[\(scopeLabel)] Keychain token: none — will fetch fresh token on first API call.")
            }
        }
    }

    // MARK: - Public: fetch all org devices (paginated)

    /// Mirrors device_sync.py → sync_axm_devices → _paginate_axm(…/v1/orgDevices)
    ///
    /// Option B — Cursor resume + partial dump:
    ///   - onBatchReady fires every `batchFlushPages` pages with accumulated devices + the
    ///     next-page cursor. It MUST durably commit that batch to CoreData and only then
    ///     advance the resume cursor; if the commit throws, the cursor is not advanced and
    ///     the error propagates out of this function so the next run replays from the last
    ///     committed batch (re-upserting a saved batch is idempotent).
    ///   - If all network retries fail, returns whatever was collected so far (partial
    ///     results) after flushing + committing the buffered batch first.
    ///   - debugPageLimit: DEBUG ONLY — set to a non-zero value to stop after N devices to test
    ///     cursor resume. Remove / set to 0 in production.
    func fetchOrgDevices(
        pageSize:        Int = 1000,
        resumeCursor:    String? = nil,
        debugPageLimit:  Int = 0,          // DEBUG: stop after this many devices (0 = no limit)
        batchFlushPages: Int = 10,         // commit to CoreData + advance cursor every N pages
        filters:         [URLQueryItem] = [],  // sent identically on every page — Apple rejects a cursor whose filters changed
        onProgress:      @Sendable @MainActor (Int, Int) -> Void,
        onBatchReady:    @Sendable @MainActor ([RawABMDevice], String?) async throws -> Void  // (batch, nextCursor)
    ) async throws -> [RawABMDevice] {     // partial on network failure; throws only if a batch fails to commit

        var results:  [RawABMDevice] = []
        // Start from a saved cursor if resuming, otherwise nil = start from page 1
        var cursor:   String? = resumeCursor
        let limit     = 1000
        let decoder   = JSONDecoder()
        let encoder   = JSONEncoder()
        let scopeLabel = scope == .school ? "ASM" : "ABM"
        var pageCount = 0   // pages fetched this run (for batch flush trigger)
        var batchAccumulator: [RawABMDevice] = []  // devices since last flush

        if let rc = resumeCursor {
            await log.info("[\(scopeLabel)] Resuming org device fetch from saved cursor (\(rc.prefix(20))…)")
        }
        await onProgress(0, 0)

        repeat {
            // Cancellation check — honour Stop Sync between pages
            guard !(Task.isCancelled) else {
                await log.info("[\(scopeLabel)] Fetch cancelled — committing \(batchAccumulator.count) buffered device(s).")
                if !batchAccumulator.isEmpty {
                    try await onBatchReady(batchAccumulator, cursor)
                }
                return results
            }

            // Fix B: per-page token refresh
            guard let token = try? await validToken() else {
                await log.error("[\(scopeLabel)] Token unavailable — stopping fetch with \(results.count) devices collected.")
                if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                return results
            }

            guard var components = URLComponents(string: baseURL + "/v1/orgDevices") else {
                await log.error("[\(scopeLabel)] Could not build /v1/orgDevices URL.")
                if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                return results
            }
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(limit)),
            ] + filters
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = queryItems

            guard let orgDevicesURL = components.url else {
                await log.error("[\(scopeLabel)] URLComponents produced nil URL.")
                if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                return results
            }
            var request = URLRequest(url: orgDevicesURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")

            let pageNum = (results.count / 1000) + 1

            // ── Fetch with -1005 escalating retry ────────────────────────────
            // Apple closes the HTTP/2 connection after ~20 pages. Two retries with
            // escalating backoff handle both the normal GOAWAY and rate-limit cases.
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlErr as URLError where urlErr.code == .networkConnectionLost
                                               || urlErr.code.rawValue == -1005 {
                // Attempt 1 — 5s
                await log.warn("[\(scopeLabel)] /v1/orgDevices page \(pageNum): -1005 connection reset — recreating session, waiting 5s, retry 1/2…")
                resetOrgDeviceSession()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                do {
                    (data, response) = try await session.data(for: request)
                } catch let retryErr as URLError where retryErr.code == .networkConnectionLost
                                                    || retryErr.code.rawValue == -1005 {
                    // Attempt 2 — 10s
                    await log.warn("[\(scopeLabel)] /v1/orgDevices page \(pageNum): retry 1 failed — waiting 10s, retry 2/2…")
                    resetOrgDeviceSession()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    do {
                        (data, response) = try await session.data(for: request)
                    } catch {
                        // All retries exhausted — flush what we have, save cursor, return partial
                        await log.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): all retries failed (\(error.localizedDescription)). Flushing \(results.count + batchAccumulator.count) devices and saving cursor for resume.")
                        if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                        return results
                    }
                } catch {
                    // Retry 1 threw a non -1005 error — flush and return partial
                    await log.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): retry 1 non-URL error (\(error.localizedDescription)). Flushing \(results.count + batchAccumulator.count) devices.")
                    if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                    return results
                }
            } catch {
                // Non -1005 error (e.g. 401, timeout) — flush and return partial
                await log.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): unexpected error (\(error.localizedDescription)). Flushing \(results.count + batchAccumulator.count) devices and saving cursor for resume.")
                if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                return results
            }

            // Validate HTTP status — if Apple returns 400/410 on a stale cursor,
            // the defensive fallback clears the cursor and the caller restarts from page 1.
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                await log.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): HTTP \(http.statusCode) — cursor may be stale. Flushing \(results.count + batchAccumulator.count) devices.")
                if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                return results
            }

            guard let decoded = try? decoder.decode(ABMDeviceListResponse.self, from: data) else {
                await log.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): JSON decode failed. Returning \(results.count) devices.")
                if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                return results
            }

            for record in decoded.data {
                let serial = (record.attributes.serialNumber ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty else { continue }
                let recordJson = try? encoder.encode(record)
                // orderDateTime from ABM is ISO8601 — extract YYYY-MM-DD prefix only
                let orderDateStr = record.attributes.orderDateTime.flatMap { s in
                    s.count >= 10 ? String(s.prefix(10)) : nil
                }
                // addedToOrgDateTime — unlike orderDateTime (often absent for reseller/manual/
                // older devices), this is populated for essentially every device, since it's
                // stamped when Apple adds the device to the org's ABM/ASM roster.
                let addedToOrgDateStr = record.attributes.addedToOrgDateTime.flatMap { s in
                    s.count >= 10 ? String(s.prefix(10)) : nil
                }
                let device = RawABMDevice(
                    deviceId:           record.id,
                    serialNumber:       serial,
                    deviceStatus:       record.attributes.deviceStatus ?? "ACTIVE",
                    purchaseSource:     record.attributes.purchaseSourceType,
                    purchaseSourceId:   record.attributes.purchaseSourceId,
                    orderNumber:        record.attributes.orderNumber,
                    orderDate:          orderDateStr,
                    addedToOrgDate:     addedToOrgDateStr,
                    productDescription: record.attributes.productDescription,
                    deviceModel:        record.attributes.deviceModel,
                    deviceClass:        record.attributes.deviceClass,
                    productFamily:      record.attributes.productFamily,
                    wifiMacAddress:      record.attributes.wifiMacAddress?.isEmpty == false ? record.attributes.wifiMacAddress : nil,
                    bluetoothMacAddress: record.attributes.bluetoothMacAddress?.isEmpty == false ? record.attributes.bluetoothMacAddress : nil,
                    ethernetMacAddress:  record.attributes.ethernetMacAddress?.isEmpty == false ? record.attributes.ethernetMacAddress!.joined(separator: ", ") : nil,
                    imei:                record.attributes.imei?.isEmpty == false ? record.attributes.imei!.joined(separator: ", ") : nil,
                    meid:                record.attributes.meid?.isEmpty == false ? record.attributes.meid!.joined(separator: ", ") : nil,
                    eid:                 record.attributes.eid?.isEmpty == false ? record.attributes.eid : nil,
                    isMdmMigrationCapable: record.attributes.isMdmMigrationCapable.map { $0 ? "True" : "False" },
                    mdmMigrationStatus:    record.attributes.mdmMigrationStatus,
                    mdmMigrationDeadline:  record.attributes.mdmMigrationDeadlineDateTime,
                    rawJson:            recordJson
                )
                results.append(device)
                batchAccumulator.append(device)
            }

            cursor = decoded.meta?.paging?.nextCursor
            pageCount += 1

            await onProgress(results.count, results.count)

            // ── Commit batch every N pages ───────────────────────────────────
            // onBatchReady writes these devices to CoreData and only then advances
            // the resume cursor to `cursor`. A throw here (commit failed) propagates
            // out of fetchOrgDevices without advancing the cursor.
            if pageCount % batchFlushPages == 0 {
                await log.info("[\(scopeLabel)] Batch commit: \(batchAccumulator.count) devices (total \(results.count)).")
                try await onBatchReady(batchAccumulator, cursor)
                batchAccumulator.removeAll()
            }

            // ── DEBUG page limit ─────────────────────────────────────────────
            // Set debugPageLimit > 0 to stop early and test cursor resume.
            // REMOVE or leave as 0 in production.
            if debugPageLimit > 0 && results.count >= debugPageLimit {
                await log.info("[\(scopeLabel)] DEBUG: debugPageLimit \(debugPageLimit) reached at \(results.count) devices — stopping to test cursor resume. cursor=\(cursor?.prefix(30) ?? "nil")")
                if !batchAccumulator.isEmpty { try await onBatchReady(batchAccumulator, cursor) }
                return results
            }

        } while cursor != nil

        // ── Full fetch complete ──────────────────────────────────────────────
        // Flush any remaining devices in the accumulator, then signal completion
        // with cursor=nil so SyncEngine clears the saved resume cursor.
        if !batchAccumulator.isEmpty {
            await log.info("[\(scopeLabel)] Final commit: \(batchAccumulator.count) device(s) (total \(results.count)).")
            try await onBatchReady(batchAccumulator, nil)  // nil cursor = fetch complete
        } else {
            // No leftover batch — still signal completion so cursor gets cleared
            try await onBatchReady([], nil)
        }

        return results
    }

    // MARK: - Public: fetch AppleCare coverage for one device

    /// Mirrors device_sync.py → sync_axm_coverage → _paginate_axm(…/v1/orgDevices/{deviceId}/appleCareCoverage)
    /// Uses the AxM device UUID (not serial number) — matches the Python exactly.
    func fetchCoverage(deviceId: String, serialNumber: String, session: URLSession? = nil) async throws -> DeviceCoverage {
        let token = try await validToken()

        let urlStr = baseURL + "/v1/orgDevices/\(deviceId)/appleCareCoverage"
        guard let url = URL(string: urlStr) else {
            throw ABMError.networkError("Invalid coverage URL for deviceId=\(deviceId)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await (session ?? coverageSession).data(for: request)

        // 404 = no AppleCare plan on file — not an error (Python handles this the same way)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return DeviceCoverage(status: .noCoverage, endDate: nil, agreement: nil, rawJson: nil)
        }
        try await validateHTTP(response, data: data, context: "ABM /v1/orgDevices/\(deviceId)/appleCareCoverage")

        let decoded = try JSONDecoder().decode(ABMCoverageListResponse.self, from: data)
        let records = decoded.data ?? []

        if records.isEmpty {
            return DeviceCoverage(status: .noCoverage, endDate: nil, agreement: nil, rawJson: nil)
        }

        // Overall status driven by the record with the latest endDateTime.
        // This means if AppleCare Protection Plan ends 2024-05-18 and Limited Warranty
        // ended 2022-05-18, the device shows INACTIVE based on 2024-05-18 — not 2022.
        let best = records
            .compactMap { $0.attributes }
            .max(by: { ($0.endDateTime ?? "") < ($1.endDateTime ?? "") })

        guard let attrs = best else {
            return DeviceCoverage(status: .noCoverage, endDate: nil, agreement: nil, rawJson: nil)
        }

        let status = CoverageStatus.from(attrs.status)
        let endDate = attrs.endDateTime.flatMap { s in
            s.count >= 10 ? String(s.prefix(10)) : nil
        }

        return DeviceCoverage(status: status, endDate: endDate, agreement: attrs.agreementNumber, rawJson: data)
    }

    // MARK: - Public: fetch Activation Lock status for one device

    /// Single attempt. Returns "MDM" | "USER" | "NONE", or "UNKNOWN" when Apple has no
    /// status for the device (404) or the payload carries no usable fields.
    func fetchActivationLock(deviceId: String, session: URLSession) async throws -> String {
        let token = try await validToken()
        guard let url = URL(string: baseURL + "/v1/orgDevices/\(deviceId)/activationLockStatus") else {
            throw ABMError.networkError("Invalid activation lock URL for deviceId=\(deviceId)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return "UNKNOWN" }
        try await validateHTTP(response, data: data, context: "ABM /v1/orgDevices/\(deviceId)/activationLockStatus")

        let attrs = try JSONDecoder().decode(ABMActivationLockResponse.self, from: data).data?.attributes
        guard let isLocked = attrs?.isLocked else { return "UNKNOWN" }
        guard isLocked else { return "NONE" }
        let type = attrs?.lockType?.uppercased()
        return (type == "MDM" || type == "USER") ? type! : "UNKNOWN"
    }

    // One long-lived session so requests multiplex over a single HTTP/2 connection
    // instead of opening ~1 TLS connection per device. Replaced (not cancelled) when a
    // request reports a lost connection, so in-flight siblings can finish.
    private var activationLockSession: URLSession = _makeABMCoverageSession()

    private func replaceActivationLockSession(ifStill used: URLSession) {
        guard used === activationLockSession else { return }
        activationLockSession.finishTasksAndInvalidate()
        activationLockSession = _makeABMCoverageSession()
    }

    /// Connection resets retry up to 3 times (2s, 5s back-off) on a fresh session;
    /// token errors refresh once; 429 backs off 15s once.
    func fetchActivationLockResilient(deviceId: String) async -> ActivationLockOutcome {
        let backoffs: [UInt64] = [2_000_000_000, 5_000_000_000]
        var attempt = 0
        var tokenRetried = false
        var rateRetried = false
        while true {
            let used = activationLockSession
            let began = Date()
            do {
                return .ok(try await fetchActivationLock(deviceId: deviceId, session: used))
            } catch let e as URLError {
                await log.debug("[ActLock] attempt \(attempt + 1) URLError \(e.code.rawValue) after \(Int(Date().timeIntervalSince(began) * 1000))ms")
                replaceActivationLockSession(ifStill: used)
                guard attempt < backoffs.count else {
                    return .skipped("URLError \(e.code.rawValue): \(e.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: backoffs[attempt])
                attempt += 1
            } catch {
                let msg = error.localizedDescription.lowercased()
                if msg.contains("400") || msg.contains("401") || msg.contains("unauthori") || msg.contains("token") || msg.contains("invalid_client") {
                    guard !tokenRetried else { return .authFailed }
                    tokenRetried = true
                    clearToken()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                } else if msg.contains("429") || msg.contains("rate") {
                    guard !rateRetried else { return .rateLimited }
                    rateRetried = true
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                } else {
                    return .skipped(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Public: fetch all MDM servers

    /// Fetches all MDM/Apple Configurator servers registered in the org.
    /// Returns an array of RawMdmServer (id, name, type). Never throws — returns
    /// empty on failure so the sync pipeline can continue without MDM data.
    func fetchMdmServers() async -> [RawMdmServer] {
        let scopeLabel = scope == .school ? "ASM" : "ABM"
        var results: [RawMdmServer] = []
        var cursor: String? = nil

        repeat {
            guard let token = try? await validToken() else {
                await log.error("[\(scopeLabel)] MDM servers: token unavailable.")
                return results
            }
            guard var components = URLComponents(string: baseURL + "/v1/mdmServers") else {
                return results
            }
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = queryItems
            guard let url = components.url else { return results }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json",  forHTTPHeaderField: "Accept")

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                await log.warn("[\(scopeLabel)] MDM servers: HTTP error — skipping.")
                return results
            }
            guard let decoded = try? JSONDecoder().decode(ABMMdmServerListResponse.self, from: data) else {
                await log.warn("[\(scopeLabel)] MDM servers: JSON decode failed.")
                return results
            }
            for record in decoded.data {
                results.append(RawMdmServer(
                    id:         record.id,
                    serverName: record.attributes.serverName ?? "",
                    serverType: record.attributes.serverType ?? "MDM"
                ))
            }
            cursor = decoded.meta?.paging?.nextCursor
        } while cursor != nil

        await log.info("[\(scopeLabel)] MDM servers: fetched \(results.count) server(s).")
        return results
    }

    /// Fetches all device serial numbers (orgDevice IDs) assigned to one MDM server.
    /// Returns a Set<String> of serial numbers for O(1) lookup during device merge.
    func fetchMdmServerDeviceIds(serverId: String) async -> Set<String> {
        let scopeLabel = scope == .school ? "ASM" : "ABM"
        var serials = Set<String>()
        var cursor: String? = nil

        repeat {
            guard let token = try? await validToken() else { return serials }
            guard var components = URLComponents(
                string: baseURL + "/v1/mdmServers/\(serverId)/relationships/devices"
            ) else { return serials }
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = queryItems
            guard let url = components.url else { return serials }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json",  forHTTPHeaderField: "Accept")

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                await log.warn("[\(scopeLabel)] MDM server \(serverId.prefix(8)): HTTP error fetching devices.")
                return serials
            }
            guard let decoded = try? JSONDecoder().decode(ABMMdmDeviceLinkResponse.self, from: data) else {
                return serials
            }
            for link in decoded.data {
                serials.insert(link.id.uppercased())
            }
            cursor = decoded.meta?.paging?.nextCursor
        } while cursor != nil

        return serials
    }



    /// Recreate the coverage URL session — call after a -1005 (connection reset) error
    /// so the retry uses a fresh TCP/HTTP2 connection rather than the broken one.
    func resetCoverageSession() {
        coverageSession = _makeABMCoverageSession()
    }

    /// Clear in-memory token and evict from Keychain — call after 401.
    func clearToken() {
        let scopeLabel = scope == .school ? "ASM" : "ABM"
        cachedToken = nil
        tokenExpiry = .distantPast
        KeychainService.clearAxMTokenForEnv(scope: scope, envId: environmentId)
        Task { @MainActor in
            log.debug("[\(scopeLabel)] Token: cleared from memory and Keychain (post-401 eviction).")
        }
    }

    /// S1: force a fresh token round-trip against the supplied credential identity.
    /// Never reads or writes the cache — used only by Setup's Test action so a stale
    /// cached token can't report success for credentials that are actually wrong.
    func verifyCredentials() async throws {
        _ = try await fetchToken()
    }

    func validToken() async throws -> String {
        let scopeLabel = scope == .school ? "ASM" : "ABM"
        // Reuse the cached token if it has more than 5 minutes remaining.
        // 60s was too aggressive — tokens expiring between back-to-back runs would
        // trigger a new fetch on every run, hitting Apple's per-client-id rate limit.
        if let t = cachedToken, Date() < tokenExpiry.addingTimeInterval(-300) {
            let remaining = Int(tokenExpiry.timeIntervalSinceNow)
            await log.debug("[\(scopeLabel)] Token: reusing cached token — \(remaining / 60)m \(remaining % 60)s remaining.")
            return t
        }
        let remaining = Int(tokenExpiry.timeIntervalSinceNow)
        if remaining > 0 {
            await log.debug("[\(scopeLabel)] Token: cached token has only \(remaining)s left — fetching fresh token.")
        } else {
            await log.debug("[\(scopeLabel)] Token: no valid cached token — fetching fresh token from Apple token endpoint…")
        }
        let (token, ttl) = try await fetchToken()
        cachedToken = token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(ttl))
        await log.debug("[\(scopeLabel)] Token: received — TTL \(ttl)s (\(ttl / 60)m). Saving to Keychain.")
        KeychainService.saveAxMTokenForEnv(token, expiry: tokenExpiry, identity: tokenIdentity, scope: scope, envId: environmentId)
        return token
    }

    private func fetchToken() async throws -> (token: String, ttl: Int) {
        let jwt = try buildJWT()

        // Token endpoint is always the fixed Apple account URL — NOT baseURL
        guard let tokenURL = URL(string: _TOKEN_ENDPOINT) else {
            throw ABMError.networkError("Invalid token endpoint URL: \(_TOKEN_ENDPOINT)")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "AxMJamfSync/\($0)" } ?? "AxMJamfSync/1.1", forHTTPHeaderField: "User-Agent")

        // Form body matches apple_oauth.py → _request_new_token() exactly
        func pct(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "+", with: "%2B")
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "=", with: "%3D") ?? s
        }
        let scope = baseURL.contains("school") ? "school.api" : "business.api"
        let body  = [
            "grant_type=client_credentials",
            "client_id=\(pct(clientId))",
            "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion=\(jwt)",
            "scope=\(pct(scope))",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            let scopeLabel = baseURL.contains("school") ? "ASM" : "ABM"
            if http.statusCode == 400 {
                // Do not log response body — Apple's 400 can echo back the client_assertion JWT
                // which contains the clientId. Log the status only.
                await log.error("[\(scopeLabel)] Token endpoint HTTP 400 — bad request. Check clientId/keyId/scope in Setup.")
                throw ABMError.authError("HTTP 400 — check clientId/keyId/scope")
            }
            if http.statusCode == 401 {
                // Do not log response body — may contain echoed client_assertion fragments.
                await log.error("[\(scopeLabel)] Token endpoint HTTP 401 — client assertion rejected. Check private key matches keyId in Setup.")
                throw ABMError.authError("HTTP 401 — client assertion rejected; check private key and keyId")
            }
            if http.statusCode == 429 {
                // Rate-limited on the token endpoint. This happens when the app is run
                // multiple times in quick succession — each cold start builds a new
                // ABMService and immediately requests a fresh token if the Keychain one
                // has expired or is missing. Apple does not document the exact rate limit
                // but empirically enforces it per-client-id.
                //
                // Strategy: honour Retry-After if the server sends one; otherwise back
                // off 30s and try once more. If the second attempt also 429s, throw so
                // the caller can surface a clear message rather than looping.
                let retryAfter: TimeInterval
                if let ra = http.value(forHTTPHeaderField: "Retry-After"),
                   let secs = Double(ra) {
                    retryAfter = secs
                } else {
                    retryAfter = 30   // conservative default
                }
                await log.warn("[\(scopeLabel)] Token endpoint HTTP 429 — rate limited. Waiting \(Int(retryAfter))s then retrying once…")
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                // Single retry after backoff
                let (retryData, retryResponse) = try await session.data(for: request)
                if let retryHTTP = retryResponse as? HTTPURLResponse, retryHTTP.statusCode == 429 {
                    await log.error("[\(scopeLabel)] Token endpoint still 429 after retry. Wait a few minutes and try again.")
                    throw ABMError.authError("HTTP 429 — token endpoint still rate-limited after \(Int(retryAfter))s backoff. Wait a few minutes and try again.")
                }
                try validateHTTP(retryResponse, context: "ABM token endpoint (retry)")
                let retryDecoded = try JSONDecoder().decode(ABMTokenResponse.self, from: retryData)
                await log.info("[\(scopeLabel)] Token endpoint retry succeeded after \(Int(retryAfter))s backoff.")
                return (retryDecoded.access_token, retryDecoded.expires_in)
            }
            if !(200..<300).contains(http.statusCode) {
                // Do not log response body — token endpoint errors may echo credential fragments.
                await log.error("[\(scopeLabel)] Token endpoint HTTP \(http.statusCode) — check credentials in Setup.")
            }
        }
        try validateHTTP(response, context: "ABM token endpoint")

        let decoded = try JSONDecoder().decode(ABMTokenResponse.self, from: data)
        return (decoded.access_token, decoded.expires_in)
    }

    // MARK: - JWT builder (ES256, CryptoKit)
    // Mirrors apple_oauth.py → _build_client_assertion() exactly:
    //   sub/iss = clientId, aud = _TOKEN_AUDIENCE, jti = UUID, exp = now + 86400

    private func buildJWT() throws -> String {
        let now    = Int(Date().timeIntervalSince1970)
        // S3: Apple recommends max 10-minute JWT lifetime (600s).
        // The previous 86400s (24h) meant a stolen JWT could mint fresh access tokens
        // for an entire day without needing the private key. 600s limits that window.
        let expiry = now + 600  // 10 minutes — Apple's recommended maximum

        let header  = ["alg": "ES256", "kid": keyId]
        let payload: [String: Any] = [
            "sub": clientId,
            "iss": clientId,
            "aud": _TOKEN_AUDIENCE,
            "iat": now,
            "exp": expiry,
            "jti": UUID().uuidString,
        ]

        let headerB64  = try base64URLEncode(JSONSerialization.data(withJSONObject: header))
        let payloadB64 = try base64URLEncode(JSONSerialization.data(withJSONObject: payload))
        let signingInput = "\(headerB64).\(payloadB64)"

        // Use PEM content stored in Keychain — file path is never accessed at runtime.
        guard !privateKeyContent.isEmpty else {
            throw ABMError.invalidPrivateKey("No private key configured. Choose a .p8/.pem file in Setup.")
        }
        let pemString = privateKeyContent
        let key = try loadECPrivateKey(from: pemString)

        let inputData = Data(signingInput.utf8)
        let signature = try key.signature(for: inputData)
        let rawSig    = try derToRaw(signature.derRepresentation)

        return "\(signingInput).\(base64URLRaw(rawSig))"
    }

    // MARK: - Crypto helpers

    private func loadECPrivateKey(from pem: String) throws -> P256.Signing.PrivateKey {
        let stripped = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: stripped) else {
            throw ABMError.invalidPrivateKey("Could not base64-decode PEM content — check the .p8/.pem file used in Setup.")
        }
        // Apple provides keys in SEC1 / PKCS#8 format — CryptoKit handles both
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return key }
        if let key = try? P256.Signing.PrivateKey(rawRepresentation: der) { return key }
        // Last attempt: try as x963 (some .p8 files from older Apple portals)
        return try P256.Signing.PrivateKey(x963Representation: der)
    }

    /// DER ECDSA signature → raw r‖s (64 bytes for P-256), required by JWT ES256
    private func derToRaw(_ der: Data) throws -> Data {
        var i = der.startIndex
        guard der[i] == 0x30 else { throw ABMError.invalidSignature }
        i = der.index(after: i)
        // Skip outer length (might be long-form)
        if der[i] & 0x80 != 0 {
            let lenBytes = Int(der[i] & 0x7F)
            i = der.index(i, offsetBy: lenBytes + 1)
        } else {
            i = der.index(after: i)
        }
        func readInt() throws -> Data {
            guard der[i] == 0x02 else { throw ABMError.invalidSignature }
            let li   = der.index(after: i)
            let len  = Int(der[li])
            let s    = der.index(li, offsetBy: 1)
            let e    = der.index(s, offsetBy: len)
            i        = e
            var bytes = Data(der[s..<e])
            while bytes.count > 32, bytes.first == 0x00 { bytes = bytes.dropFirst() }
            while bytes.count < 32 { bytes = Data([0x00]) + bytes }
            return bytes
        }
        return try readInt() + readInt()
    }

    private func base64URLEncode(_ data: Data) throws -> String { base64URLRaw(data) }
    private func base64URLRaw(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - HTTP validation

    func validateHTTP(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ABMError.networkError("\(context): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ABMError.httpError(context: context, statusCode: http.statusCode)
        }
    }

    /// Extended version that logs the HTTP status on error.
    /// Response body is intentionally not logged — API error responses may contain
    /// echoed credential fragments (client_assertion, clientId) from the token endpoint.
    func validateHTTP(_ response: URLResponse, data: Data, context: String) async throws {
        guard let http = response as? HTTPURLResponse else {
            await log.error("[\(context)] No HTTP response received.")
            throw ABMError.networkError("\(context): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            await log.error("[\(context)] HTTP \(http.statusCode).")
            throw ABMError.httpError(context: context, statusCode: http.statusCode)
        }
    }
}

// MARK: - Output types (Sendable — cross actor boundaries safely)

struct RawMdmServer: Sendable {
    let id:         String
    let serverName: String
    let serverType: String   // "MDM" | "APPLE_CONFIGURATOR"
}

struct RawABMDevice: Sendable {
    let deviceId:           String
    let serialNumber:       String
    let deviceStatus:       String
    let purchaseSource:     String?   // purchaseSourceType
    let purchaseSourceId:   String?   // purchaseSourceId
    let orderNumber:        String?   // orderNumber
    let orderDate:          String?   // orderDateTime → YYYY-MM-DD
    let addedToOrgDate:     String?   // addedToOrgDateTime → YYYY-MM-DD
    let productDescription: String?  // productDescription e.g. "MacBook Pro (16-inch, 2021)"
    let deviceModel:        String?  // deviceModel e.g. "MacBook Pro 13\""
    let deviceClass:        String?
    let productFamily:      String?  // e.g. "Mac" | "iPad" | "iPhone" | "AppleTV" — drives Jamf endpoint routing
    let wifiMacAddress:      String?
    let bluetoothMacAddress: String?
    let ethernetMacAddress:  String?  // joined ", " — ABM returns [String]
    let imei:                String?  // joined ", " — ABM returns [String]
    let meid:                String?  // joined ", " — ABM returns [String]
    let eid:                 String?
    let isMdmMigrationCapable: String?  // "True" | "False" — tri-state, nil = not yet populated by Apple
    let mdmMigrationStatus:    String?  // "REQUESTED" | "STARTED" | "SUCCESS" | "FAILED"
    let mdmMigrationDeadline:  String?  // raw ISO 8601 — never parsed to Date at this layer
    let rawJson:            Data?
}

struct DeviceCoverage: Sendable {
    let status:    CoverageStatus
    let endDate:   String?   // YYYY-MM-DD
    let agreement: String?
    let rawJson:   Data?     // full JSON response body from /v1/orgDevices/{id}/appleCareCoverage
}

enum ActivationLockOutcome: Sendable {
    case ok(String)
    case skipped(String)
    case authFailed
    case rateLimited
}

// MARK: - ABMError

enum ABMError: LocalizedError {
    case invalidPrivateKey(String)
    case invalidSignature
    case authError(String)
    case networkError(String)
    case httpError(context: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey(let m):     return "ABM: Invalid private key — \(m)"
        case .invalidSignature:             return "ABM: Could not parse ECDSA signature"
        case .authError(let m):             return "ABM: Auth failed — \(m)"
        case .networkError(let m):          return "ABM: Network error — \(m)"
        case .httpError(let ctx, let code): return "ABM: HTTP \(code) from \(ctx)"
        }
    }
}
