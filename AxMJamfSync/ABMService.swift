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
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity       = true
        cfg.requestCachePolicy         = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: TLSDelegate(), delegateQueue: nil)
    }()

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
            log.debug("[\(scopeLabel)] Credentials loaded — clientId: \(credentials.clientId.prefix(8))… keyId: \(credentials.keyId.prefix(8))… scope: \(credentials.scope.rawValue)")
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
    func fetchOrgDevices(
        pageSize: Int = 1000,
        onProgress: @MainActor (Int, Int) -> Void
    ) async throws -> [RawABMDevice] {

        let token     = try await validToken()
        var results:  [RawABMDevice] = []
        var cursor:   String? = nil
        // Apple's org device API supports up to 1000 per page (documented limit).
        // We always use 1000 — the pageSize parameter is Jamf-only.
        let limit     = 1000

        // P5: Hoist encoder/decoder outside the loop — JSONEncoder/Decoder initialisation
        // is moderately expensive. Previously allocated per-page (decoder) and per-record
        // (encoder). At 50k devices = 50k encoder + 50 decoder allocs eliminated.
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        await onProgress(0, 0)

        repeat {
            try Task.checkCancellation()

            guard var components = URLComponents(string: baseURL + "/v1/orgDevices") else {
                throw ABMError.networkError("Could not build /v1/orgDevices URL from baseURL: \(baseURL)")
            }
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(limit)),
            ]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            components.queryItems = queryItems

            guard let orgDevicesURL = components.url else {
                throw ABMError.networkError("URLComponents produced nil URL for /v1/orgDevices")
            }
            var request = URLRequest(url: orgDevicesURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            try await validateHTTP(response, data: data, context: "ABM /v1/orgDevices page \((results.count / 1000) + 1)")

            let decoded = try decoder.decode(ABMDeviceListResponse.self, from: data)

            for record in decoded.data {
                let serial = (record.attributes.serialNumber ?? "").uppercased().trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty else { continue }
                // Encode this single record back to JSON for storage.
                // This is cheap — we already have `data` in memory; re-encoding one record
                // avoids storing the entire page blob (which may contain 1000 devices).
                let recordJson = try? encoder.encode(record)
                results.append(RawABMDevice(
                    deviceId:           record.id,
                    serialNumber:       serial,
                    deviceStatus:       record.attributes.deviceStatus ?? "ACTIVE",
                    purchaseSource:     record.attributes.purchaseSourceType,
                    productDescription: record.attributes.productDescription,
                    deviceModel:        record.attributes.deviceModel,
                    deviceClass:        record.attributes.deviceClass,
                    productFamily:      record.attributes.productFamily,
                    rawJson:            recordJson
                ))
            }

            // Cursor lives at: body.meta.paging.nextCursor
            cursor = decoded.meta?.paging?.nextCursor

            let knownTotal = max(results.count, 0)
            await onProgress(results.count, knownTotal)

        } while cursor != nil

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
        request.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")

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
        request.setValue("AxMJamfSync/1.0", forHTTPHeaderField: "User-Agent")

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
    let purchaseSource:     String?
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
