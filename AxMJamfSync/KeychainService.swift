// KeychainService.swift
// Keychain CRUD for all credentials and tokens — App Sandbox / entitlement compliant.
//
// Stored items (kSecClassGenericPassword, kSecAttrService = bundle ID):
//   axm.scope          — active scope string ("business" or "school")
//   abm.clientId / abm.keyId / abm.privKey  — ABM credentials
//   asm.clientId / asm.keyId / asm.privKey  — ASM credentials
//   abm.token / abm.tokenExpiry             — ABM bearer token cache
//   asm.token / asm.tokenExpiry             — ASM bearer token cache
//   jamf.clientId / jamf.clientSecret / jamf.baseURL
//   jamf.token / jamf.tokenExpiry           — Jamf OAuth2 token cache
//
// wipeCache() in AppStore resets axm.scope in BOTH UserDefaults and Keychain.

import Foundation
import Security

enum KeychainService {

    // Service name = bundle ID — makes items unique to this app in the Keychain.
    private static let service = Bundle.main.bundleIdentifier ?? "com.karthikmac.axmjamfsync"

    // MARK: - Key enum — one case per secret
    enum Key: String {
        case axmScope             = "axm.scope"           // which account type is active
        // Business (ABM) credentials
        case axmBizClientId       = "axm.business.clientId"
        case axmBizKeyId          = "axm.business.keyId"
        case axmBizPrivateKey     = "axm.business.privateKeyContent"
        // School (ASM) credentials
        case axmSchoolClientId    = "axm.school.clientId"
        case axmSchoolKeyId       = "axm.school.keyId"
        case axmSchoolPrivateKey  = "axm.school.privateKeyContent"
        // Legacy flat keys (kept for one-time migration on first launch)
        case _legacyAxmClientId   = "axm.clientId"
        case _legacyAxmKeyId      = "axm.keyId"
        case _legacyAxmPrivKey    = "axm.privateKeyContent"
        case jamfURL           = "jamf.url"
        case jamfClientId      = "jamf.clientId"
        case jamfClientSecret  = "jamf.clientSecret"
        case jamfPageSize      = "jamf.pageSize"
        // Cached Apple access tokens — stored with expiry so ABMService can reuse
        // across runs and avoid 429s from Apple's token endpoint rate limit.
        case axmBizToken       = "axm.business.accessToken"
        case axmBizTokenExpiry = "axm.business.accessTokenExpiry"   // Unix epoch Double as String
        case axmSchoolToken       = "axm.school.accessToken"
        case axmSchoolTokenExpiry = "axm.school.accessTokenExpiry"
        // S2: Cached Jamf access token — persisted so JamfService can reuse across launches.
        // Jamf tokens have a 30-minute TTL; caching avoids a round-trip on every app start.
        case jamfAccessToken       = "jamf.accessToken"
        case jamfAccessTokenExpiry = "jamf.accessTokenExpiry"
        case jamfTokenTTL          = "jamf.tokenTTL"
    }

    // MARK: - Save
    @discardableResult
    static func save(_ value: String, for key: Key) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass                       as String: kSecClassGenericPassword,
            kSecAttrService                 as String: service,
            kSecAttrAccount                 as String: key.rawValue,
            kSecAttrSynchronizable          as String: false,  // never sync to iCloud Keychain
            // TN3137: explicitly target the data protection keychain (not file-based).
            // On macOS, SecItem defaults to the file-based keychain without this flag.
            // The data protection keychain is more secure, consistent with iOS, and
            // recommended by Apple for all new macOS apps.
            kSecUseDataProtectionKeychain   as String: true,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData      as String] = data
            // S4: kSecAttrAccessibleWhenUnlockedThisDeviceOnly — same as WhenUnlocked
            // but explicitly non-portable: items are NOT synced to iCloud Keychain and
            // cannot be transferred to another device. Enterprise credentials (Apple API
            // private keys, Jamf secrets) should never leave this machine.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    // MARK: - Load
    static func load(for key: Key) -> String? {
        // Primary: data protection keychain (modern, recommended by Apple TN3137)
        let dpQuery: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrService               as String: service,
            kSecAttrAccount               as String: key.rawValue,
            kSecAttrSynchronizable        as String: false,
            kSecReturnData                as String: true,
            kSecMatchLimit                as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(dpQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        // Migration: item not in data protection keychain — check legacy file-based keychain.
        // This runs once after upgrading from a build that lacked kSecUseDataProtectionKeychain.
        // If found, migrate it to the data protection keychain and delete the legacy copy.
        let legacyQuery: [String: Any] = [
            kSecClass              as String: kSecClassGenericPassword,
            kSecAttrService        as String: service,
            kSecAttrAccount        as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecReturnData         as String: true,
            kSecMatchLimit         as String: kSecMatchLimitOne,
        ]
        var legacyResult: AnyObject?
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
              let legacyData = legacyResult as? Data,
              let legacyValue = String(data: legacyData, encoding: .utf8) else { return nil }

        // Migrate: write to data protection keychain, then delete legacy copy
        if save(legacyValue, for: key) {
            let deleteQuery: [String: Any] = [
                kSecClass              as String: kSecClassGenericPassword,
                kSecAttrService        as String: service,
                kSecAttrAccount        as String: key.rawValue,
                kSecAttrSynchronizable as String: false,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
        return legacyValue
    }

    // MARK: - Delete
    @discardableResult
    static func delete(for key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrService               as String: service,
            kSecAttrAccount               as String: key.rawValue,
            kSecAttrSynchronizable        as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - Convenience loaders
    /// Returns credential keys for a given scope
    private static func clientIdKey(for scope: AxMScope) -> Key {
        scope == .school ? .axmSchoolClientId : .axmBizClientId
    }
    private static func keyIdKey(for scope: AxMScope) -> Key {
        scope == .school ? .axmSchoolKeyId : .axmBizKeyId
    }
    private static func privKeyKey(for scope: AxMScope) -> Key {
        scope == .school ? .axmSchoolPrivateKey : .axmBizPrivateKey
    }

    static func loadAxMCredentials() -> AxMCredentials {
        var c = AxMCredentials()
        c.scope = AxMScope(rawValue: load(for: .axmScope) ?? "") ?? .business
        c.clientId          = load(for: clientIdKey(for: c.scope)) ?? ""
        c.keyId             = load(for: keyIdKey(for: c.scope))    ?? ""
        c.privateKeyContent = load(for: privKeyKey(for: c.scope))  ?? ""
        c.privateKeyPath    = ""  // path is never persisted
        // One-time migration from legacy flat keys (pre-scope-split)
        if c.clientId.isEmpty, let legacy = load(for: ._legacyAxmClientId), !legacy.isEmpty {
            c.clientId = legacy
            save(legacy, for: clientIdKey(for: c.scope))
            delete(for: ._legacyAxmClientId)
        }
        if c.keyId.isEmpty, let legacy = load(for: ._legacyAxmKeyId), !legacy.isEmpty {
            c.keyId = legacy
            save(legacy, for: keyIdKey(for: c.scope))
            delete(for: ._legacyAxmKeyId)
        }
        if c.privateKeyContent.isEmpty, let legacy = load(for: ._legacyAxmPrivKey), !legacy.isEmpty {
            c.privateKeyContent = legacy
            save(legacy, for: privKeyKey(for: c.scope))
            delete(for: ._legacyAxmPrivKey)
        }

        // ── Keychain credential diagnostics (logged at sync start) ───────────
        let scopeLabel  = c.scope == .school ? "ASM" : "ABM"
        let hasClientId = !c.clientId.isEmpty
        let hasKeyId    = !c.keyId.isEmpty
        let hasPrivKey  = !c.privateKeyContent.isEmpty
        let allPresent  = hasClientId && hasKeyId && hasPrivKey
        Task { @MainActor in
            let log = LogService.shared
            log.debug("[Keychain] \(scopeLabel) credentials — " +
                "clientId: \(hasClientId ? "✓" : "⚠ MISSING") | " +
                "keyId: \(hasKeyId ? "✓" : "⚠ MISSING") | " +
                "privateKey: \(hasPrivKey ? "\(c.privateKeyContent.count) chars" : "⚠ MISSING")")
            if !allPresent {
                log.warn("[Keychain] \(scopeLabel) credentials incomplete — sync will fail. Configure in Setup.")
            }

            // Token cache status
            if let cached = loadAxMToken(for: c.scope) {
                let mins = Int(cached.expiry.timeIntervalSinceNow) / 60
                let secs = Int(cached.expiry.timeIntervalSinceNow) % 60
                log.debug("[Keychain] \(scopeLabel) access token: cached — valid for \(mins)m \(secs)s.")
            } else {
                log.debug("[Keychain] \(scopeLabel) access token: not cached (will be fetched from Apple on first API call).")
            }

            // Jamf credential status
            let j = loadJamfCredentials()
            let hasJamfURL    = !j.url.isEmpty
            let hasJamfClient = !j.clientId.isEmpty
            let hasJamfSecret = !j.clientSecret.isEmpty
            log.debug("[Keychain] Jamf credentials — " +
                "url: \(hasJamfURL ? "✓" : "⚠ MISSING") | " +
                "clientId: \(hasJamfClient ? "✓" : "⚠ MISSING") | " +
                "clientSecret: \(hasJamfSecret ? "✓" : "⚠ MISSING")")
            if !hasJamfURL || !hasJamfClient || !hasJamfSecret {
                log.warn("[Keychain] Jamf credentials incomplete — Jamf steps will be skipped.")
            }
        }

        return c
    }

    /// Load credentials for a specific scope (used when switching account type)
    static func loadAxMCredentials(for scope: AxMScope) -> AxMCredentials {
        var c = AxMCredentials()
        c.scope             = scope
        c.clientId          = load(for: clientIdKey(for: scope))  ?? ""
        c.keyId             = load(for: keyIdKey(for: scope))     ?? ""
        c.privateKeyContent = load(for: privKeyKey(for: scope))   ?? ""
        c.privateKeyPath    = ""
        return c
    }

    static func saveAxMCredentials(_ c: AxMCredentials) {
        save(c.scope.rawValue,    for: .axmScope)
        save(c.clientId,          for: clientIdKey(for: c.scope))
        save(c.keyId,             for: keyIdKey(for: c.scope))
        if !c.privateKeyContent.isEmpty {
            save(c.privateKeyContent, for: privKeyKey(for: c.scope))
        }
    }

    static func loadJamfCredentials() -> JamfCredentials {
        var c = JamfCredentials()
        c.url          = load(for: .jamfURL)          ?? ""
        c.clientId     = load(for: .jamfClientId)     ?? ""
        c.clientSecret = load(for: .jamfClientSecret) ?? ""
        // Load saved pageSize; snap to nearest 500-step value (500/1000/1500/2000).
        // Older saves may have stored 200 — clamp those to 1000 (default).
        let rawSize = Int(load(for: .jamfPageSize) ?? "1000") ?? 1000
        let validSizes = [500, 1000, 1500, 2000]
        c.pageSize = validSizes.min(by: { abs($0 - rawSize) < abs($1 - rawSize) }) ?? 1000
        return c
    }

    static func saveJamfCredentials(_ c: JamfCredentials) {
        save(c.url,              for: .jamfURL)
        save(c.clientId,         for: .jamfClientId)
        save(c.clientSecret,     for: .jamfClientSecret)
        save(String(c.pageSize), for: .jamfPageSize)
    }

    // MARK: - Apple access token persistence
    // Tokens are cached in Keychain so ABMService can reuse them across app launches
    // and avoid hitting Apple's token endpoint rate limit (429) on back-to-back syncs.

    private static func tokenKey(for scope: AxMScope) -> Key {
        scope == .school ? .axmSchoolToken : .axmBizToken
    }
    private static func tokenExpiryKey(for scope: AxMScope) -> Key {
        scope == .school ? .axmSchoolTokenExpiry : .axmBizTokenExpiry
    }

    /// Save an Apple access token and its expiry date to Keychain.
    static func saveAxMToken(_ token: String, expiry: Date, for scope: AxMScope) {
        save(token,                                        for: tokenKey(for: scope))
        save(String(expiry.timeIntervalSince1970),        for: tokenExpiryKey(for: scope))
    }

    /// Load a cached Apple access token if it is still valid (>60s remaining).
    /// Returns nil when no token is stored or it has expired / is about to expire.
    static func loadAxMToken(for scope: AxMScope) -> (token: String, expiry: Date)? {
        guard let token  = load(for: tokenKey(for: scope)), !token.isEmpty,
              let expStr = load(for: tokenExpiryKey(for: scope)),
              let epoch  = Double(expStr) else { return nil }
        let expiry = Date(timeIntervalSince1970: epoch)
        // Treat token as unusable if less than 5 minutes remain — matches the
        // 300s guard in ABMService.validToken() so a token near expiry isn't
        // loaded from Keychain only to be immediately discarded and re-fetched.
        guard expiry.timeIntervalSinceNow > 300 else { return nil }
        return (token, expiry)
    }

    /// Evict the cached token for a scope (call after 401 or explicit cache reset).
    static func clearAxMToken(for scope: AxMScope) {
        delete(for: tokenKey(for: scope))
        delete(for: tokenExpiryKey(for: scope))
    }

    /// Clear the AxM token for a specific environment.
    static func clearAxMTokenForEnv(id: UUID) {
        deleteForEnv(key: "axm.accessToken",       envId: id)
        deleteForEnv(key: "axm.accessTokenExpiry", envId: id)
    }

    /// Clear the Jamf token for a specific environment.
    static func clearJamfTokenForEnv(id: UUID) {
        deleteForEnv(key: "jamf.accessToken",       envId: id)
        deleteForEnv(key: "jamf.accessTokenExpiry", envId: id)
        deleteForEnv(key: "jamf.tokenTTL",          envId: id)
    }

    // MARK: - Jamf access token persistence (S2)
    // JamfService previously cached tokens only in memory, losing them on every app restart.
    // These methods mirror the AxM token pattern so Jamf tokens survive across launches.
    // Jamf TTL is 30 minutes; we evict if <60s remain (same guard as AxM).

    /// Save a Jamf OAuth access token and its expiry to Keychain.
    static func saveJamfToken(_ token: String, expiry: Date, ttl: Int) {
        save(token,                                    for: .jamfAccessToken)
        save(String(expiry.timeIntervalSince1970),    for: .jamfAccessTokenExpiry)
        save(String(ttl),                             for: .jamfTokenTTL)
    }

    /// Load a cached Jamf token. Returns nil if not found or expired.
    /// TTL is included so validToken() can compute an adaptive buffer.
    static func loadJamfToken() -> (token: String, expiry: Date, ttl: Int)? {
        guard let token  = load(for: .jamfAccessToken), !token.isEmpty,
              let expStr = load(for: .jamfAccessTokenExpiry),
              let epoch  = Double(expStr) else { return nil }
        let expiry = Date(timeIntervalSince1970: epoch)
        guard expiry.timeIntervalSinceNow > 0 else { return nil }
        let ttl = Int(load(for: .jamfTokenTTL).flatMap { Int($0) } ?? 1800)
        return (token, expiry, ttl)
    }

    /// Evict the cached Jamf token (call after 401 or explicit logout).
    static func clearJamfToken() {
        delete(for: .jamfAccessToken)
        delete(for: .jamfAccessTokenExpiry)
        delete(for: .jamfTokenTTL)
    }

    // MARK: - v2.0 Environment-namespaced Keychain access

    /// Save a value using an environment-namespaced account key.
    /// Format: "env.{uuid}.{key}" stored as the kSecAttrAccount.
    @discardableResult
    static func saveForEnv(_ value: String, key: String, envId: UUID) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let account = "env.\(envId.uuidString).\(key)"
        let query: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrService               as String: service,
            kSecAttrAccount               as String: account,
            kSecAttrSynchronizable        as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData      as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func loadForEnv(key: String, envId: UUID) -> String? {
        let account = "env.\(envId.uuidString).\(key)"
        let query: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrService               as String: service,
            kSecAttrAccount               as String: account,
            kSecAttrSynchronizable        as String: false,
            kSecReturnData                as String: true,
            kSecMatchLimit                as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deleteForEnv(key: String, envId: UUID) -> Bool {
        let account = "env.\(envId.uuidString).\(key)"
        let query: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrService               as String: service,
            kSecAttrAccount               as String: account,
            kSecAttrSynchronizable        as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Load credentials for a specific environment.
    /// Key format: axm.{scope}.clientId — scoped so ABM and ASM credentials
    /// coexist independently within the same environment UUID.
    /// Falls back to the legacy scopeless key (axm.clientId) for existing data.
    static func loadAxMCredentialsForEnv(id: UUID, scope: AxMScope) -> AxMCredentials {
        var c = AxMCredentials()
        c.scope = scope
        let s = scope == .school ? "school" : "business"
        // Prefer scope-namespaced key; fall back to legacy scopeless key for migration compat
        c.clientId = loadForEnv(key: "axm.\(s).clientId", envId: id)
            ?? loadForEnv(key: "axm.clientId", envId: id) ?? ""
        c.keyId = loadForEnv(key: "axm.\(s).keyId", envId: id)
            ?? loadForEnv(key: "axm.keyId", envId: id) ?? ""
        c.privateKeyContent = loadForEnv(key: "axm.\(s).privateKeyContent", envId: id)
            ?? loadForEnv(key: "axm.privateKeyContent", envId: id) ?? ""
        c.privateKeyPath = ""
        return c
    }

    static func saveAxMCredentialsForEnv(_ c: AxMCredentials, id: UUID) {
        let s = c.scope == .school ? "school" : "business"
        saveForEnv(c.scope.rawValue, key: "axm.scope",                 envId: id)
        saveForEnv(c.clientId,       key: "axm.\(s).clientId",         envId: id)
        saveForEnv(c.keyId,          key: "axm.\(s).keyId",            envId: id)
        if !c.privateKeyContent.isEmpty {
            saveForEnv(c.privateKeyContent, key: "axm.\(s).privateKeyContent", envId: id)
        }
    }

    /// Delete AxM credentials for a specific scope within an environment.
    static func deleteAxMCredentialsForEnv(id: UUID, scope: AxMScope) {
        let s = scope == .school ? "school" : "business"
        deleteForEnv(key: "axm.\(s).clientId",         envId: id)
        deleteForEnv(key: "axm.\(s).keyId",            envId: id)
        deleteForEnv(key: "axm.\(s).privateKeyContent", envId: id)
        // Also delete legacy scopeless keys in case they were written by an older build
        deleteForEnv(key: "axm.clientId",          envId: id)
        deleteForEnv(key: "axm.keyId",             envId: id)
        deleteForEnv(key: "axm.privateKeyContent", envId: id)
        deleteForEnv(key: "axm.scope",             envId: id)
    }

    static func loadJamfCredentialsForEnv(id: UUID) -> JamfCredentials {
        var c = JamfCredentials()
        c.url          = loadForEnv(key: "jamf.url",          envId: id) ?? ""
        c.clientId     = loadForEnv(key: "jamf.clientId",     envId: id) ?? ""
        c.clientSecret = loadForEnv(key: "jamf.clientSecret", envId: id) ?? ""
        let raw        = loadForEnv(key: "jamf.pageSize",      envId: id)
        c.pageSize     = Int(raw ?? "1000") ?? 1000
        return c
    }

    static func saveJamfCredentialsForEnv(_ c: JamfCredentials, id: UUID) {
        saveForEnv(c.url,          key: "jamf.url",          envId: id)
        saveForEnv(c.clientId,     key: "jamf.clientId",     envId: id)
        saveForEnv(c.clientSecret, key: "jamf.clientSecret", envId: id)
        saveForEnv(String(c.pageSize), key: "jamf.pageSize", envId: id)
    }

    // MARK: - v2.0 Migration: copy v1 flat keys into env namespace

    /// Step 1 of migration: copy v1 flat Keychain credentials to env-namespaced keys.
    /// v1 flat keys are NOT deleted here — call deleteV1KeychainKeys() only after
    /// the entire migration (CoreData + UserDefaults) completes successfully.
    static func migrateToEnvironment(id: UUID, scope: AxMScope) {
        let s = scope == .school ? "school" : "business"
        if let v = load(for: scope == .school ? .axmSchoolClientId  : .axmBizClientId),  !v.isEmpty { saveForEnv(v, key: "axm.\(s).clientId",          envId: id) }
        if let v = load(for: scope == .school ? .axmSchoolKeyId     : .axmBizKeyId),     !v.isEmpty { saveForEnv(v, key: "axm.\(s).keyId",             envId: id) }
        if let v = load(for: scope == .school ? .axmSchoolPrivateKey : .axmBizPrivateKey),!v.isEmpty { saveForEnv(v, key: "axm.\(s).privateKeyContent", envId: id) }
        if let v = load(for: .jamfURL),          !v.isEmpty { saveForEnv(v, key: "jamf.url",          envId: id) }
        if let v = load(for: .jamfClientId),     !v.isEmpty { saveForEnv(v, key: "jamf.clientId",     envId: id) }
        if let v = load(for: .jamfClientSecret), !v.isEmpty { saveForEnv(v, key: "jamf.clientSecret", envId: id) }
        if let v = load(for: .jamfPageSize),     !v.isEmpty { saveForEnv(v, key: "jamf.pageSize",     envId: id) }
        saveForEnv(scope.rawValue, key: "axm.scope", envId: id)
    }

    /// Step 2 of migration: delete v1 flat keys after full migration completes.
    /// Separated from migrateToEnvironment() so there is a rollback window.
    static func deleteV1KeychainKeys() {
        delete(for: .axmBizClientId);    delete(for: .axmBizKeyId);    delete(for: .axmBizPrivateKey)
        delete(for: .axmSchoolClientId); delete(for: .axmSchoolKeyId); delete(for: .axmSchoolPrivateKey)
        delete(for: .jamfURL);           delete(for: .jamfClientId);   delete(for: .jamfClientSecret)
        delete(for: .jamfPageSize);      delete(for: .axmScope)
        delete(for: .axmBizToken);       delete(for: .axmBizTokenExpiry)
        delete(for: .axmSchoolToken);    delete(for: .axmSchoolTokenExpiry)
        delete(for: .jamfAccessToken);   delete(for: .jamfAccessTokenExpiry); delete(for: .jamfTokenTTL)
    }

    // MARK: - v2.0 Wipe all Keychain items for an environment

    static func wipeEnvironment(id: UUID) {
        let prefix = "env.\(id.uuidString)."
        // Query all generic password items for this service
        let query: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrService               as String: service,
            kSecReturnAttributes          as String: true,
            kSecMatchLimit                as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            let del: [String: Any] = [
                kSecClass                     as String: kSecClassGenericPassword,
                kSecAttrService               as String: service,
                kSecAttrAccount               as String: account,
                kSecUseDataProtectionKeychain as String: true,
            ]
            SecItemDelete(del as CFDictionary)
        }
    }

}
