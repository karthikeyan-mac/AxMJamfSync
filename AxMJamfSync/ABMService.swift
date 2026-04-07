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
    init(credentials: AxMCredentials) {
        self.baseURL           = credentials.scope.baseURL
        self.clientId          = credentials.clientId
        self.keyId             = credentials.keyId
        self.privateKeyContent = credentials.privateKeyContent
        self.scope             = credentials.scope

        let scopeLabel = credentials.scope == .school ? "ASM" : "ABM"

        // ── Credential diagnostics ────────────────────────────────────────────
        Task { @MainActor in
            let log = LogService.shared
            let cidStatus = credentials.clientId.isEmpty  ? "missing" : "present"
            let kidStatus = credentials.keyId.isEmpty     ? "missing" : "present"
            log.debug("[\(scopeLabel)] Credentials — clientId: \(cidStatus) keyId: \(kidStatus) scope: \(credentials.scope.rawValue)")
            log.debug("[\(scopeLabel)] Base URL: \(credentials.scope.baseURL)")
            let hasKey = !credentials.privateKeyContent.isEmpty
            log.debug("[\(scopeLabel)] Private key: \(hasKey ? "present (\(credentials.privateKeyContent.count) chars)" : "⚠ MISSING — auth will fail")")
        }

        // ── Keychain token check ─────────────────────────────────────────────
        if let cached = KeychainService.loadAxMToken(for: credentials.scope) {
            self.cachedToken = cached.token
            self.tokenExpiry = cached.expiry
            let remaining = Int(cached.expiry.timeIntervalSinceNow)
            let mins = remaining / 60
            Task { @MainActor in
                LogService.shared.debug("[\(scopeLabel)] Keychain token: found — expires in \(mins)m (\(remaining)s), will \(remaining > 60 ? "reuse" : "refresh (< 60s remaining)").")
            }
        } else {
            Task { @MainActor in
                LogService.shared.debug("[\(scopeLabel)] Keychain token: none — will fetch fresh token on first API call.")
            }
        }
    }

    // MARK: - Public: fetch all org devices (paginated)

    /// Mirrors device_sync.py → sync_axm_devices → _paginate_axm(…/v1/orgDevices)
    ///
    /// Option B — Cursor resume + partial dump:
    ///   - onBatchReady fires every `batchFlushPages` pages with accumulated devices + current
    ///     cursor. SyncEngine saves them to CoreData immediately and persists the cursor to
    ///     UserDefaults. On next run SyncEngine passes a resumeCursor to start from that point.
    ///   - If all retries fail, returns whatever was collected so far (partial results) rather
    ///     than throwing — cursor was already saved by the last onBatchReady call so resume works.
    ///   - debugPageLimit: DEBUG ONLY — set to a non-zero value to stop after N devices to test
    ///     cursor resume. Remove / set to 0 in production.
    func fetchOrgDevices(
        pageSize:        Int = 1000,
        resumeCursor:    String? = nil,
        debugPageLimit:  Int = 0,          // DEBUG: stop after this many devices (0 = no limit)
        batchFlushPages: Int = 10,         // flush to CoreData + save cursor every N pages
        onProgress:      @MainActor (Int, Int) -> Void,
        onBatchReady:    @MainActor ([RawABMDevice], String?) -> Void  // (batch, nextCursor)
    ) async -> [RawABMDevice] {            // returns partial on failure — never throws

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
            await LogService.shared.info("[\(scopeLabel)] Resuming org device fetch from saved cursor (\(rc.prefix(20))…)")
        }
        await onProgress(0, 0)

        repeat {
            // Cancellation check — honour Stop Sync between pages
            guard !(Task.isCancelled) else {
                await LogService.shared.info("[\(scopeLabel)] Fetch cancelled — flushing \(batchAccumulator.count) buffered device(s).")
                if !batchAccumulator.isEmpty {
                    await onBatchReady(batchAccumulator, cursor)
                }
                return results
            }

            // Fix B: per-page token refresh
            guard let token = try? await validToken() else {
                await LogService.shared.error("[\(scopeLabel)] Token unavailable — stopping fetch with \(results.count) devices collected.")
                if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
                return results
            }

            guard var components = URLComponents(string: baseURL + "/v1/orgDevices") else {
                await LogService.shared.error("[\(scopeLabel)] Could not build /v1/orgDevices URL.")
                if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
                return results
            }
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(limit)),
            ]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = queryItems

            guard let orgDevicesURL = components.url else {
                await LogService.shared.error("[\(scopeLabel)] URLComponents produced nil URL.")
                if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
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
                await LogService.shared.warn("[\(scopeLabel)] /v1/orgDevices page \(pageNum): -1005 connection reset — recreating session, waiting 5s, retry 1/2…")
                resetOrgDeviceSession()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                do {
                    (data, response) = try await session.data(for: request)
                } catch let retryErr as URLError where retryErr.code == .networkConnectionLost
                                                    || retryErr.code.rawValue == -1005 {
                    // Attempt 2 — 10s
                    await LogService.shared.warn("[\(scopeLabel)] /v1/orgDevices page \(pageNum): retry 1 failed — waiting 10s, retry 2/2…")
                    resetOrgDeviceSession()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    do {
                        (data, response) = try await session.data(for: request)
                    } catch {
                        // All retries exhausted — flush what we have, save cursor, return partial
                        await LogService.shared.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): all retries failed (\(error.localizedDescription)). Flushing \(results.count + batchAccumulator.count) devices and saving cursor for resume.")
                        if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
                        return results
                    }
                } catch {
                    // Retry 1 threw a non -1005 error — flush and return partial
                    await LogService.shared.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): retry 1 non-URL error (\(error.localizedDescription)). Flushing \(results.count + batchAccumulator.count) devices.")
                    if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
                    return results
                }
            } catch {
                // Non -1005 error (e.g. 401, timeout) — flush and return partial
                await LogService.shared.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): unexpected error (\(error.localizedDescription)). Flushing \(results.count + batchAccumulator.count) devices and saving cursor for resume.")
                if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
                return results
            }

            // Validate HTTP status — if Apple returns 400/410 on a stale cursor,
            // the defensive fallback clears the cursor and the caller restarts from page 1.
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                await LogService.shared.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): HTTP \(http.statusCode) — cursor may be stale. Flushing \(results.count + batchAccumulator.count) devices.")
                if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
                return results
            }

            guard let decoded = try? decoder.decode(ABMDeviceListResponse.self, from: data) else {
                await LogService.shared.error("[\(scopeLabel)] /v1/orgDevices page \(pageNum): JSON decode failed. Returning \(results.count) devices.")
                if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
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
                let device = RawABMDevice(
                    deviceId:           record.id,
                    serialNumber:       serial,
                    deviceStatus:       record.attributes.deviceStatus ?? "ACTIVE",
                    purchaseSource:     record.attributes.purchaseSourceType,
                    purchaseSourceId:   record.attributes.purchaseSourceId,
                    orderNumber:        record.attributes.orderNumber,
                    orderDate:          orderDateStr,
                    productDescription: record.attributes.productDescription,
                    deviceModel:        record.attributes.deviceModel,
                    deviceClass:        record.attributes.deviceClass,
                    productFamily:      record.attributes.productFamily,
                    rawJson:            recordJson
                )
                results.append(device)
                batchAccumulator.append(device)
            }

            cursor = decoded.meta?.paging?.nextCursor
            pageCount += 1

            await onProgress(results.count, results.count)

            // ── Flush batch every N pages ────────────────────────────────────
            // Saves devices to CoreData + persists cursor to UserDefaults so any
            // failure after this point can resume from the next cursor.
            if pageCount % batchFlushPages == 0 {
                await LogService.shared.info("[\(scopeLabel)] Batch flush: \(batchAccumulator.count) devices (total \(results.count)) — cursor saved for resume.")
                await onBatchReady(batchAccumulator, cursor)
                batchAccumulator.removeAll()
            }

            // ── DEBUG page limit ─────────────────────────────────────────────
            // Set debugPageLimit > 0 to stop early and test cursor resume.
            // REMOVE or leave as 0 in production.
            if debugPageLimit > 0 && results.count >= debugPageLimit {
                await LogService.shared.info("[\(scopeLabel)] DEBUG: debugPageLimit \(debugPageLimit) reached at \(results.count) devices — stopping to test cursor resume. cursor=\(cursor?.prefix(30) ?? "nil")")
                if !batchAccumulator.isEmpty { await onBatchReady(batchAccumulator, cursor) }
                return results
            }

        } while cursor != nil

        // ── Full fetch complete ──────────────────────────────────────────────
        // Flush any remaining devices in the accumulator, then signal completion
        // with cursor=nil so SyncEngine clears the saved resume cursor.
        if !batchAccumulator.isEmpty {
            await LogService.shared.info("[\(scopeLabel)] Final flush: \(batchAccumulator.count) device(s) (total \(results.count)).")
            await onBatchReady(batchAccumulator, nil)  // nil cursor = fetch complete
        } else {
            // No leftover batch — still signal completion so cursor gets cleared
            await onBatchReady([], nil)
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

    // MARK: - Token management

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
        KeychainService.clearAxMToken(for: scope)
        Task { @MainActor in
            LogService.shared.debug("[\(scopeLabel)] Token: cleared from memory and Keychain (post-401 eviction).")
        }
    }

    func validToken() async throws -> String {
        let scopeLabel = scope == .school ? "ASM" : "ABM"
        // Reuse the cached token if it has more than 5 minutes remaining.
        // 60s was too aggressive — tokens expiring between back-to-back runs would
        // trigger a new fetch on every run, hitting Apple's per-client-id rate limit.
        if let t = cachedToken, Date() < tokenExpiry.addingTimeInterval(-300) {
            let remaining = Int(tokenExpiry.timeIntervalSinceNow)
            await LogService.shared.debug("[\(scopeLabel)] Token: reusing cached token — \(remaining / 60)m \(remaining % 60)s remaining.")
            return t
        }
        let remaining = Int(tokenExpiry.timeIntervalSinceNow)
        if remaining > 0 {
            await LogService.shared.debug("[\(scopeLabel)] Token: cached token has only \(remaining)s left — fetching fresh token.")
        } else {
            await LogService.shared.debug("[\(scopeLabel)] Token: no valid cached token — fetching fresh token from Apple token endpoint…")
        }
        let (token, ttl) = try await fetchToken()
        cachedToken = token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(ttl))
        await LogService.shared.debug("[\(scopeLabel)] Token: received — TTL \(ttl)s (\(ttl / 60)m). Saving to Keychain.")
        KeychainService.saveAxMToken(token, expiry: tokenExpiry, for: scope)
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
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                await LogService.shared.error("[\(scopeLabel)] Token endpoint HTTP 400 — bad request. Check clientId/keyId/scope. Response: \(body)")
                throw ABMError.authError("HTTP 400 — check clientId/keyId/scope")
            }
            if http.statusCode == 401 {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                await LogService.shared.error("[\(scopeLabel)] Token endpoint HTTP 401 — client assertion rejected. Check private key matches keyId. Response: \(body)")
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
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                let retryAfter: TimeInterval
                if let ra = http.value(forHTTPHeaderField: "Retry-After"),
                   let secs = Double(ra) {
                    retryAfter = secs
                } else {
                    retryAfter = 30   // conservative default
                }
                await LogService.shared.warn("[\(scopeLabel)] Token endpoint HTTP 429. Response: \(body)")
                await LogService.shared.warn("[\(scopeLabel)] Rate-limited — waiting \(Int(retryAfter))s then retrying once…")
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                // Single retry after backoff
                let (retryData, retryResponse) = try await session.data(for: request)
                if let retryHTTP = retryResponse as? HTTPURLResponse, retryHTTP.statusCode == 429 {
                    let retryBody = String(data: retryData, encoding: .utf8) ?? "<no body>"
                    await LogService.shared.error("[\(scopeLabel)] Token endpoint still 429 after retry. Response: \(retryBody)")
                    throw ABMError.authError("HTTP 429 — token endpoint still rate-limited after \(Int(retryAfter))s backoff. Wait a few minutes and try again.")
                }
                try validateHTTP(retryResponse, context: "ABM token endpoint (retry)")
                let retryDecoded = try JSONDecoder().decode(ABMTokenResponse.self, from: retryData)
                await LogService.shared.info("[\(scopeLabel)] Token endpoint retry succeeded after \(Int(retryAfter))s backoff.")
                return (retryDecoded.access_token, retryDecoded.expires_in)
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                await LogService.shared.error("[\(scopeLabel)] Token endpoint HTTP \(http.statusCode). Response: \(body)")
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

    /// Extended version that also logs the response body on error — use at call sites
    /// where `data` is already in scope.
    func validateHTTP(_ response: URLResponse, data: Data, context: String) async throws {
        guard let http = response as? HTTPURLResponse else {
            await LogService.shared.error("[\(context)] No HTTP response received.")
            throw ABMError.networkError("\(context): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(500) ?? "<no body>"
            await LogService.shared.error("[\(context)] HTTP \(http.statusCode) — \(body)")
            throw ABMError.httpError(context: context, statusCode: http.statusCode)
        }
    }
}

// MARK: - Output types (Sendable — cross actor boundaries safely)

struct RawABMDevice: Sendable {
    let deviceId:           String
    let serialNumber:       String
    let deviceStatus:       String
    let purchaseSource:     String?   // purchaseSourceType
    let purchaseSourceId:   String?   // purchaseSourceId
    let orderNumber:        String?   // orderNumber
    let orderDate:          String?   // orderDateTime → YYYY-MM-DD
    let productDescription: String?  // productDescription e.g. "MacBook Pro (16-inch, 2021)"
    let deviceModel:        String?  // deviceModel e.g. "MacBook Pro 13\""
    let deviceClass:        String?
    let productFamily:      String?  // e.g. "Mac" | "iPad" | "iPhone" | "AppleTV" — drives Jamf endpoint routing
    let rawJson:            Data?
}

struct DeviceCoverage: Sendable {
    let status:    CoverageStatus
    let endDate:   String?   // YYYY-MM-DD
    let agreement: String?
    let rawJson:   Data?     // full JSON response body from /v1/orgDevices/{id}/appleCareCoverage
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
