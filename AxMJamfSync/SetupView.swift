// SetupView.swift
// Setup tab — credential configuration for ABM/ASM and Jamf Pro.
//
// Scope picker: ABM / ASM toggle. Locked (disabled) when AxM-sourced data exists in CoreData
//   (axmDeviceId != nil). Switching loads the matching Keychain credentials.
// Jamf page size: slider 100…2000 step 100, default 1000. Saved to Keychain.
// Auth test buttons: validate credentials before sync. Status shown inline.
// Private key: loaded from .p8/.pem file via file picker. Content stored in Keychain, never path.

import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject private var store:  AppStore
    @EnvironmentObject private var prefs:  AppPreferences
    @ObservedObject    var engine: SyncEngine
    let navigateToSync: () -> Void

    var body: some View {
        // Capture isRunning as a plain Bool so child panels receive a value type,
        // not an @ObservedObject reference. This breaks the cross-observer
        // AttributeGraph cycle on macOS 14 that occurs when .disabled/.opacity
        // modifiers on a container depend on one ObservableObject (engine) while
        // the container's children observe a different ObservableObject (store).
        let isRunning = engine.isRunning
        VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Subtitle only — app name already shown in AppHeaderBar ──
                Text("Configure your Apple and Jamf credentials. All secrets are stored securely in the macOS Keychain.")
                    .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.top, 16)

                // ── Sync running banner ──────────────────────────────
                if isRunning {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Sync in progress — Setup is read-only.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("View Sync") { navigateToSync() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 24)
                }

                // ── Credential panels ────────────────────────────────
                // Pass isRunning as a plain Bool — avoids container-level
                // .disabled/@ObservedObject cross-observer cycle on macOS 14.
                HStack(alignment: .top, spacing: 16) {
                    AxMCredentialsPanel(isRunning: isRunning)
                    JamfCredentialsPanel(isRunning: isRunning)
                }
                .padding(.horizontal, 24)

                // ── Sync options + cache ─────────────────────────────
                CacheSettingsPanel(engine: engine, isRunning: isRunning)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }

        // ── Pinned Run Sync footer — always visible regardless of scroll/resize ──
        Divider()
        HStack {
            Spacer()
            GlobalSyncButton(engine: engine, navigateToSync: navigateToSync)
                .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
        } // VStack
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - AxM Credentials Panel

struct AxMCredentialsPanel: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var prefs: AppPreferences
    let isRunning: Bool
    @State private var saveToKeychain = true

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }
    private var scopeFull:   String { store.axmCredentials.scope == .school ? "Apple School Manager (ASM)" : "Apple Business Manager (ABM)" }

    // Locked when credentials are configured OR cache exists.
    // Derived purely from @Published AppStore properties — no Keychain reads in body.
    private var scopeLocked: Bool {
        !store.axmCredentials.clientId.isEmpty || store.cacheIsPopulated
    }

    var body: some View {
        CardSection(title: scopeFull, icon: "applelogo") {
            // ── Account type: horizontal segmented row (#5) ──────────
            VStack(alignment: .leading, spacing: 8) {
                InfoLabel(
                    text: "Account Type",
                    info: InfoContent(
                        icon:    "building.2.fill",
                        title:   "Account Type",
                        summary: "Choose the Apple platform your organisation uses to manage devices.",
                        bullets: [
                            "Business Manager (ABM) — for companies, enterprises, and government organisations.",
                            "School Manager (ASM) — for schools and educational institutions.",
                            "This controls which Apple servers the app connects to when fetching device and warranty data."
                        ]
                    ))

                // Lock rule: account type is locked if EITHER credentials exist in
                // Keychain OR data is cached. Both must be empty to allow switching.
                // scopeLocked is a @State refreshed on appear and credential changes.
                HStack(spacing: 10) {
                    ForEach(AxMScope.allCases, id: \.self) { scope in
                        Button {
                            guard !scopeLocked else { return }
                            let saved = store.environmentId.map {
                                KeychainService.loadAxMCredentialsForEnv(id: $0, scope: scope)
                            } ?? KeychainService.loadAxMCredentials(for: scope)
                            store.axmCredentials = saved
                            store.axmAuthStatus  = .idle
                            prefs.activeScope = scope.rawValue
                            KeychainService.save(scope.rawValue, for: .axmScope)
                            saveToKeychain = !saved.clientId.isEmpty
                                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: scope == .school
                                    ? "graduationcap.fill"
                                    : "briefcase.fill")
                                    .font(.callout)
                                Text(scope.label)
                                    .font(.callout).fontWeight(.medium)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(
                                store.axmCredentials.scope == scope
                                    ? Color.accentColor
                                    : Color(NSColor.controlBackgroundColor)
                            )
                            .foregroundStyle(
                                store.axmCredentials.scope == scope
                                    ? Color.white
                                    : Color.primary
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        store.axmCredentials.scope == scope
                                            ? Color.accentColor
                                            : Color(NSColor.separatorColor),
                                        lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(scopeLocked && store.axmCredentials.scope != scope)
                        .opacity(scopeLocked && store.axmCredentials.scope != scope ? 0.35 : 1.0)
                        .help(scopeLocked && store.axmCredentials.scope != scope
                            ? "Account type is locked. Clear your credentials and delete the cache to switch account type."
                            : "")
                    }
                }
                if scopeLocked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.caption2)
                        Text("Account type is locked. Clear credentials and delete cache to switch.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }

            Divider()

            InlineCredentialField(
                label: "Client ID",
                info: InfoContent(
                    icon:    "person.badge.key.fill",
                    title:   "Apple API Client ID",
                    summary: "Your API username from Apple Business or School Manager.",
                    bullets: [
                        "Find it in \(scopeAbbrev) → Settings → API → select your API key.",
                        "Starts with BUSINESSAPI… (ABM) or SCHOOLAPI… (ASM).",
                        "Copy and paste it exactly — do not retype it manually."
                    ]
                ),
                text: $store.axmCredentials.clientId,
                isSecure: false,
                placeholder: store.axmCredentials.scope == .school
                    ? "SCHOOLAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
                    : "BUSINESSAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")

            InlineCredentialField(
                label: "Key ID",
                info: InfoContent(
                    icon:    "number.square.fill",
                    title:   "Key ID",
                    summary: "A short code that identifies which signing key this app should use when talking to Apple.",
                    bullets: [
                        "Find it in \(scopeAbbrev) → Settings → API next to your API key.",
                        "Looks like AUTHKEY_XXXXXXXXXX.",
                        "Copy it exactly — it is case-sensitive."
                    ]
                ),
                text: $store.axmCredentials.keyId,
                isSecure: true,
                placeholder: "AUTHKEY_XXXXXXXXXX")

            HStack(spacing: 8) {
                InfoLabel(
                    text: "Private Key (.p8/.pem)",
                    info: InfoContent(
                        icon:    "key.fill",
                        title:   "Private Key File",
                        summary: "The secret key file Apple gave you when you created your API key in \(scopeAbbrev).",
                        bullets: [
                            "The file name ends in .p8 or .pem.",
                            "You only need to pick the file once — the app reads it and stores the contents securely in the macOS Keychain.",
                            "The file itself is never copied or saved by the app."
                        ]
                    ))
                    .frame(width: 140, alignment: .leading)
                // Status pill — shows where the key was loaded from
                if !store.axmCredentials.privateKeyContent.isEmpty {
                    if store.axmCredentials.privateKeyPath.isEmpty {
                        // Content came from Keychain (path not set = loaded on app launch from Keychain)
                        Label("Loaded from Keychain", systemImage: "lock.shield.fill")
                            .font(.caption).foregroundStyle(.green)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    } else {
                        // Content just loaded from a file the user just picked this session
                        Label("Loaded from file", systemImage: "arrow.down.doc.fill")
                            .font(.caption).foregroundStyle(.blue)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                } else {
                    Text("No key loaded")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { pickFile() }
            }

            Divider()

            HStack(spacing: 8) {
                Toggle("Save to Keychain", isOn: $saveToKeychain)
                    .toggleStyle(.checkbox).font(.callout)
                    .onChange(of: saveToKeychain) { _, on in
                        if on { store.saveAxMCredentials() }
                    }
                if saveToKeychain {
                    Button { clearCreds() } label: { Text("Clear").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                        .help("Remove all Apple Business/School Manager credentials saved on this Mac and blank out all the fields above. You will need to re-enter them before you can run a sync.")
                }
                Spacer()
                Button {
                    if saveToKeychain { store.saveAxMCredentials() }
                    Task { await store.testAxMAuth() }
                } label: {
                    Label("Test Auth", systemImage: "network.badge.shield.half.filled")
                }
                .buttonStyle(.bordered)
                .disabled(store.axmAuthStatus == .testing)
                .help("Check that your Apple credentials work by sending a test login to Apple's servers. A green tick means the app can authenticate successfully and is ready to fetch devices.")
                if store.axmAuthStatus != .idle { AuthStatusBadge(status: store.axmAuthStatus) }
            }
        }
        .onAppear {
            // Check Keychain directly — store.axmCredentials may be populated in-memory
            // without ever having been saved, which would wrongly enable the toggle.
            let inKeychain = store.environmentId.map {
                KeychainService.loadAxMCredentialsForEnv(id: $0, scope: store.axmCredentials.scope)
            } ?? KeychainService.loadAxMCredentials(for: store.axmCredentials.scope)
            saveToKeychain = !inKeychain.clientId.isEmpty
        }
        .disabled(isRunning)
        .opacity(isRunning ? 0.5 : 1)
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false; p.canChooseDirectories = false
        p.title = "Select Private Key (.pem / .p8)"; p.prompt = "Select"
        // Accept .p8 (Apple API key) and .pem (PEM certificate) files.
        // UTType.data is the fallback — added so the picker still works if
        // the system doesn't recognise the extension as a specific type.
        let p8Type  = UTType(filenameExtension: "p8")  ?? .data
        let pemType = UTType(filenameExtension: "pem") ?? .data
        p.allowedContentTypes = [p8Type, pemType, .data]
        if p.runModal() == .OK, let url = p.url {
            store.axmCredentials.privateKeyPath = url.path
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                store.axmCredentials.privateKeyContent = content
            }
            if saveToKeychain { store.saveAxMCredentials() }  // only save if user opted in
        }
    }

    private func clearCreds() {
        let scope = store.axmCredentials.scope
        store.axmCredentials = AxMCredentials()
        store.axmCredentials.scope = scope
        // Delete env-namespaced keys (v2.0 path)
        if let envId = store.environmentId {
            KeychainService.deleteForEnv(key: "axm.clientId",          envId: envId)
            KeychainService.deleteForEnv(key: "axm.keyId",             envId: envId)
            KeychainService.deleteForEnv(key: "axm.privateKeyContent", envId: envId)
            KeychainService.deleteForEnv(key: "axm.scope",             envId: envId)
        }
        // Also delete v1 flat keys (no-op if already migrated, safety net otherwise)
        KeychainService.delete(for: .axmBizClientId);    KeychainService.delete(for: .axmBizKeyId)
        KeychainService.delete(for: .axmBizPrivateKey)
        KeychainService.delete(for: .axmSchoolClientId); KeychainService.delete(for: .axmSchoolKeyId)
        KeychainService.delete(for: .axmSchoolPrivateKey); KeychainService.delete(for: .axmScope)
        store.axmAuthStatus = .idle
        saveToKeychain = false
    }
}

// MARK: - Jamf Credentials Panel

struct JamfCredentialsPanel: View {
    @EnvironmentObject private var store: AppStore
    let isRunning: Bool
    @State private var showSecret     = false
    @State private var saveToKeychain = true
    @State private var pageSize: Double = 1000   // local mirror of store.jamfCredentials.pageSize

    var body: some View {
        CardSection(title: "Jamf Pro", icon: "server.rack") {
            InlineCredentialField(
                label: "Jamf URL",
                info: InfoContent(
                    icon:    "network",
                    title:   "Jamf Pro Server URL",
                    summary: "The web address of your Jamf Pro server.",
                    bullets: [
                        "Jamf Cloud example: https://yourorg.jamfcloud.com",
                        "On-premise example: https://jamf.yourschool.edu",
                        "Do not include a trailing slash at the end.",
                        "The app uses this address for all Jamf communication."
                    ]
                ),
                text: $store.jamfCredentials.url,
                isSecure: false,
                placeholder: "https://yourinstance.jamfcloud.com")

            InlineCredentialField(
                label: "Client ID",
                info: InfoContent(
                    icon:    "person.badge.key.fill",
                    title:   "Jamf API Client ID",
                    summary: "The username for the API client that gives this app access to Jamf Pro.",
                    bullets: [
                        "Create or find it in Jamf Pro → Settings → System → API Roles and Clients.",
                        "The client needs Read Computers, Read Mobile Devices, Update Computers, and Update Mobile Devices permissions.",
                        "Without the update permissions, warranty dates cannot be written back to Jamf."
                    ]
                ),
                text: $store.jamfCredentials.clientId,
                isSecure: false,
                placeholder: "a1b2c3d4-e5f6-…")

            HStack(spacing: 8) {
                InfoLabel(
                    text: "Client Secret",
                    info: InfoContent(
                        icon:    "lock.fill",
                        title:   "Client Secret",
                        summary: "The password that pairs with your Jamf API Client ID to prove the app is authorised to access Jamf Pro.",
                        bullets: [
                            "You get this value from Jamf Pro when you create or rotate an API client.",
                            "Stored securely in the macOS Keychain — never written to a plain text file.",
                            "If Jamf rejects the connection, try rotating the secret in Jamf Pro and re-entering it here."
                        ]
                    ))
                    .frame(width: 140, alignment: .leading)
                if showSecret {
                    TextField("Client Secret", text: $store.jamfCredentials.clientSecret)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Client Secret", text: $store.jamfCredentials.clientSecret)
                        .textFieldStyle(.roundedBorder)
                }
                Button { showSecret.toggle() } label: {
                    Image(systemName: showSecret ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                InfoLabel(
                    text: "Page Size",
                    info: InfoContent(
                        icon:    "doc.text.magnifyingglass",
                        title:   "Jamf Page Size",
                        summary: "Controls how many computer records are downloaded from Jamf Pro in each network request.",
                        bullets: [
                            "Smaller values (50–100) are safer for slow or heavily loaded Jamf servers.",
                            "Larger values are faster but can cause timeouts on older Jamf instances.",
                            "1000 is the default. Options: 500 / 1000 / 1500 / 2000. Lower if you see request timeouts."
                        ]
                    ))
                HStack {
                    Slider(value: $pageSize, in: 500...2000, step: 500)
                        .onChange(of: pageSize) { _, val in
                            store.jamfCredentials.pageSize = Int(val)
                        }
                    Text("\(Int(pageSize))")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }

            HStack { Spacer(); APIPrivilegesButton(); Spacer() }

            Divider()

            HStack(spacing: 8) {
                Toggle("Save to Keychain", isOn: $saveToKeychain)
                    .toggleStyle(.checkbox).font(.callout)
                    .onChange(of: saveToKeychain) { _, on in
                        if on { store.saveJamfCredentials() }
                    }
                if saveToKeychain {
                    Button { clearCreds() } label: { Text("Clear").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                        .help("Remove all Jamf Pro credentials saved on this Mac and blank out all the fields above. You will need to re-enter them before the app can connect to Jamf.")
                }
                Spacer()
                Button {
                    if saveToKeychain { store.saveJamfCredentials() }
                    Task { await store.testJamfAuth() }
                } label: {
                    Label("Test Auth", systemImage: "network.badge.shield.half.filled")
                }
                .buttonStyle(.bordered)
                .disabled(store.jamfAuthStatus == .testing)
                .help("Check that your Jamf credentials work by attempting a test login to your Jamf server. A green tick means the app can connect and authenticate — you are ready to sync.")
                if store.jamfAuthStatus != .idle { AuthStatusBadge(status: store.jamfAuthStatus) }
            }
        }
        .onAppear {
            // Check Keychain directly — store.jamfCredentials may be populated in-memory
            // without ever having been saved, which would wrongly enable the toggle.
            let inKeychain = store.environmentId.map {
                KeychainService.loadJamfCredentialsForEnv(id: $0)
            } ?? KeychainService.loadJamfCredentials()
            saveToKeychain = !inKeychain.clientId.isEmpty
            // Sync local pageSize mirror from store (avoids Binding get/set cycle on macOS 26)
            pageSize = Double(store.jamfCredentials.pageSize)
        }
        .disabled(isRunning)
        .opacity(isRunning ? 0.5 : 1)
    }

    private func clearCreds() {
        store.jamfCredentials = JamfCredentials()
        // Delete env-namespaced keys (v2.0 path)
        if let envId = store.environmentId {
            KeychainService.deleteForEnv(key: "jamf.url",          envId: envId)
            KeychainService.deleteForEnv(key: "jamf.clientId",     envId: envId)
            KeychainService.deleteForEnv(key: "jamf.clientSecret", envId: envId)
            KeychainService.deleteForEnv(key: "jamf.pageSize",     envId: envId)
        }
        // Also delete v1 flat keys
        KeychainService.delete(for: .jamfURL); KeychainService.delete(for: .jamfClientId)
        KeychainService.delete(for: .jamfClientSecret); KeychainService.delete(for: .jamfPageSize)
        store.jamfAuthStatus = .idle
        saveToKeychain = false
    }
}

// MARK: - Auth status badge

struct AuthStatusBadge: View {
    let status: AuthTestStatus
    var body: some View {
        HStack(spacing: 4) {
            if status == .testing {
                ProgressView().scaleEffect(0.7)
            } else if let icon = status.icon {
                Image(systemName: icon).foregroundStyle(status.color).font(.callout)
            }
            Text(status.label).font(.callout).foregroundStyle(status.color).lineLimit(1)
        }
    }
}


// MARK: - API Privileges Button + Popover

struct APIPrivilegesButton: View {
    @State private var showPrivileges = false

    var body: some View {
        Button {
            showPrivileges = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.callout)
                Text("API Privileges Required")
                    .font(.callout)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(Color.cyan)
            .background(Color.cyan.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPrivileges, arrowEdge: .bottom) {
            APIPrivilegesPopover()
        }
    }
}

struct APIPrivilegesPopover: View {
    private let privileges: [(name: String, detail: String)] = [
        ("Read Computers",          "View Mac computer inventory records"),
        ("Read Mobile Devices",     "View iPhone, iPad and Apple TV inventory records"),
        ("Update Computers",        "Write warranty dates back to Mac computer records"),
        ("Update Mobile Devices",   "Write warranty dates back to mobile device records"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("Required API Permissions")
                    .font(.headline)
            }
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("API Role Privileges")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                ForEach(privileges, id: \.name) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.callout)
                                .fontWeight(.semibold)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            Divider().padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("How to create an API Client")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .padding(.bottom, 2)

                ForEach(Array([
                    "Open Jamf Pro → Settings",
                    "Go to API Roles and Clients",
                    "Create a Role with the privileges above",
                    "Create a Client and assign the Role",
                    "Copy the Client ID and generate a Secret",
                ].enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .font(.callout)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
// MARK: - Cache & Sync Options Panel (simplified — #3)

struct CacheSettingsPanel: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var prefs: AppPreferences
    let engine: SyncEngine   // kept for resetCache call only — not observed
    let isRunning: Bool
    @State private var showDeleteConfirm  = false
    @State private var coverageLimitText  = ""
    // Local mirrors for coupled toggles — avoids cross-writing Binding(get:set:) cycle on macOS 26.
    // Each setter in the old Binding wrote to the property the OTHER binding read,
    // creating a bidirectional read-write cycle in AttributeGraph.
    @State private var alwaysRefreshCoverage = false
    @State private var skipExistingCoverage  = false
    @State private var alwaysRefreshDevices  = false
    @State private var syncDeviceScope: SyncDeviceScope = .both

    private var scopeAbbrev: String { store.axmCredentials.scope == .school ? "ASM" : "ABM" }

    /// Real on-disk path — read from the active environment's persistence controller.
    private var cacheURL: URL {
        store.persistence.storeURL
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AxMJamfSync/AxMJamfSync.sqlite")
    }
    private var cacheLocationPath: String { cacheURL.path }

    var body: some View {
        CardSection(title: "Sync Options", icon: "slider.horizontal.3") {
            // ── Sync Device Types — first row so it's clearly global (not Jamf-specific)
            HStack(spacing: 0) {
                InfoLabel(
                    text: "Sync Device Types",
                    info: InfoContent(
                        icon:    "rectangle.stack.fill",
                        title:   "Sync Device Types",
                        summary: "Choose which device types to include in the AppleCare coverage fetch and Jamf write-back.",
                        bullets: [
                            "Mac + Mobile: all devices synced (default).",
                            "Mac Only: AppleCare and Jamf sync run for Mac devices only. iPhone, iPad and Apple TV are skipped.",
                            "Mobile Only: AppleCare and Jamf sync run for iPhone, iPad and Apple TV only. Macs are skipped.",
                            "Apple org devices are always fetched in full — this setting only affects coverage and write-back.",
                            "Existing data for unselected device types is retained in cache but won't be refreshed until you include them again."
                        ]
                ))
                Spacer()
                Picker("", selection: $syncDeviceScope) {
                    ForEach(SyncDeviceScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .onChange(of: syncDeviceScope) { _, val in
                    prefs.syncDeviceScope = val
                }
                .disabled(isRunning)
                Spacer()
            }

            Divider()

            HStack(alignment: .top, spacing: 32) {

                // ── Left: cache durations + force-refresh ─────────────
                VStack(alignment: .leading, spacing: 14) {
                    StepperPref(
                        label: "Device Cache (days)",
                        info: InfoContent(
                            icon:    "clock.arrow.2.circlepath",
                            title:   "Device Cache Duration",
                            summary: "How many days the downloaded device list stays valid before the next sync re-fetches it from Apple and Jamf.",
                            bullets: [
                                "Set to 0 to always re-download the full device list on every sync.",
                                "Higher values speed up syncs by skipping the device download step when the data is still fresh.",
                                "This setting has no effect when Force Refresh Devices is turned on."
                            ]
                        ),
                        value: $prefs.devicesCacheDays, range: 0...30)
                    .opacity(alwaysRefreshDevices ? 0.4 : 1.0)
                    .disabled(alwaysRefreshDevices)
                    StepperPref(
                        label: "Coverage Cache (days)",
                        info: InfoContent(
                            icon:    "shield.lefthalf.filled.badge.checkmark",
                            title:   "Coverage Cache Duration",
                            summary: "How many days the warranty coverage results stay valid before being re-fetched from Apple.",
                            bullets: [
                                "Set to 0 to always re-check coverage on every sync.",
                                "Has no effect when 'Do Not Refetch Cached Warranty' or 'Force Refresh Coverage' is enabled — those settings take priority."
                            ]
                        ),
                        value: $prefs.coverageCacheDays, range: 0...90)
                    .opacity((skipExistingCoverage || alwaysRefreshCoverage) ? 0.4 : 1.0)
                    .disabled(skipExistingCoverage || alwaysRefreshCoverage)

                    Divider()

                    TogglePrefOneShot(
                        label: "Force Refresh Devices",
                        info: InfoContent(
                            icon:    "arrow.clockwise.circle",
                            title:   "Force Refresh Devices",
                            summary: "Forces the next sync to re-download all device records from Apple and Jamf, even if the local cache is recent.",
                            bullets: [
                                "Useful if you suspect the device list is out of date.",
                                "Automatically resets to OFF after the sync completes.",
                                "Does not affect warranty coverage fetching or the Jamf write-back step."
                            ]
                        ),
                        isOn: $alwaysRefreshDevices)
                        .onChange(of: alwaysRefreshDevices) { _, val in
                            prefs.alwaysRefreshDevices = val
                        }

                    TogglePref(
                        label: "Force Refresh Coverage",
                        info: InfoContent(
                            icon:    "arrow.clockwise.circle.fill",
                            title:   "Force Refresh Coverage",
                            summary: "Forces the next sync to re-check warranty coverage for every device, ignoring any previously saved results.",
                            bullets: [
                                "Every device will be sent to Apple's warranty API again from scratch.",
                                "Automatically turns itself back off after the sync finishes.",
                                "Temporarily overrides the 'Do Not Refetch Cached Warranty' setting for that one run."
                            ]
                        ),
                        isOn: $alwaysRefreshCoverage)
                        .onChange(of: alwaysRefreshCoverage) { _, val in
                            prefs.alwaysRefreshCoverage = val
                            if val {
                                prefs.skipExistingCoverage = false
                                skipExistingCoverage = false
                            }
                        }

                }

                Divider()

                // ── Right: coverage options + limit + cache ────────────
                VStack(alignment: .leading, spacing: 14) {
                    // Coverage fetch limit
                    HStack {
                        InfoLabel(
                            text: "Coverage Fetch Limit",
                            info: InfoContent(
                                icon:    "gauge.with.dots.needle.67percent",
                                title:   "Coverage Fetch Limit",
                                summary: "Limits how many devices are checked for warranty coverage in a single sync run.",
                                bullets: [
                                    "Set to 0 to check all devices every time (no limit).",
                                    "Enter a number (e.g. 500) to cap each run — the next sync automatically picks up where the last one stopped.",
                                    "Useful for large fleets or if Apple's API is returning rate-limit errors."
                                ]
                            ))
                        Spacer()
                        HStack(spacing: 6) {
                            TextField("0", text: $coverageLimitText)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                                .onChange(of: coverageLimitText) { _, newVal in
                                    let digits  = newVal.filter(\.isNumber)
                                    let clamped = min(Int(digits) ?? 0, 100_000)
                                    prefs.coverageLimit = clamped
                                    if digits != newVal { coverageLimitText = digits }
                                }
                            Text(prefs.coverageLimit == 0 ? "= all" : "devices/run")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                        }
                    }

                    // Do Not Refetch Cached Warranty — linked to Force Refresh Coverage
                    TogglePref(
                        label: "Do Not Refetch Cached Warranty",
                        info: InfoContent(
                            icon:    "shield.checkered",
                            title:   "Do Not Refetch Cached Warranty",
                            summary: "Only check warranty coverage for devices that have never been checked before — skip any device that already has a result.",
                            bullets: [
                                "Recommended ON for most environments — saves time and reduces Apple API calls.",
                                "Devices already showing Active, Expired, or No Info are left unchanged.",
                                "Turn OFF if you want every device re-checked completely from scratch on every run."
                            ]
                        ),
                        isOn: $skipExistingCoverage)
                        .onChange(of: skipExistingCoverage) { _, val in
                            prefs.skipExistingCoverage = val
                            if val {
                                prefs.alwaysRefreshCoverage = false
                                alwaysRefreshCoverage = false
                            }
                        }
                    .disabled(alwaysRefreshCoverage)
                    .opacity(alwaysRefreshCoverage ? 0.4 : 1.0)

                    Divider()

                    // Cache location + delete
                    VStack(alignment: .leading, spacing: 4) {
                        InfoLabel(
                            text: "Cache Location",
                            info: InfoContent(
                                icon:    "internaldrive.fill",
                                title:   "Cache Location",
                                summary: "The folder on this Mac where the app stores all your device data.",
                                bullets: [
                                    "Contains device records from Apple and Jamf, warranty results, and sync history.",
                                    "Click the folder icon to open this location in Finder.",
                                    "You can copy this folder to back up your data before resetting."
                                ]
                            ))
                        HStack(spacing: 6) {
                            Text(cacheLocationPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Button {
                                let folder = cacheURL.deletingLastPathComponent()
                                // Select the file itself in Finder if it exists, else open the folder
                                if FileManager.default.fileExists(atPath: cacheURL.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([cacheURL])
                                } else {
                                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(folder)
                                }
                            } label: {
                                Image(systemName: "folder.fill").font(.caption).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).help("Open this folder in Finder — useful if you want to back up your device data or check what files the app has stored")
                        }
                    }

                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete Cache", systemImage: "trash.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Wipe all locally cached device records and clear the sync history. Use this if your device list looks wrong, out of date, or you want to start fresh. The next time you run a sync, everything will be re-downloaded from Apple and Jamf from scratch.")
                    .confirmationDialog("Delete Cache?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("Delete Cache", role: .destructive) {
                            Task { await engine.resetCache(store: store) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("All cached device records will be deleted and all sync timestamps cleared. The next Run Sync will re-fetch everything from \(scopeAbbrev) and Jamf Pro.")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            coverageLimitText     = prefs.coverageLimit == 0 ? "0" : String(prefs.coverageLimit)
            // Sync local mirrors from prefs (avoids Binding get/set cycle on macOS 26)
            alwaysRefreshCoverage = prefs.alwaysRefreshCoverage
            skipExistingCoverage  = prefs.skipExistingCoverage
            alwaysRefreshDevices  = prefs.alwaysRefreshDevices
            syncDeviceScope       = prefs.syncDeviceScope
        }
        .disabled(isRunning)
        .opacity(isRunning ? 0.5 : 1)
    }
}

// MARK: - Shared pref components

struct StepperPref: View {
    let label: String; let info: InfoContent
    @Binding var value: Int; let range: ClosedRange<Int>
    var body: some View {
        HStack {
            InfoLabel(text: label, info: info)
            Spacer()
            Stepper(value: $value, in: range) {
                Text("\(value)").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

struct TogglePref: View {
    let label: String; let info: InfoContent
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            InfoLabel(text: label, info: info)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// One-shot toggle — shows an orange "next run" badge when ON
struct TogglePrefOneShot: View {
    let label: String; let info: InfoContent
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 8) {
            InfoLabel(text: label, info: info)
            if isOn {
                Text("next run")
                    .font(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18)).foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct CredentialField: View {
    let label: String; let info: InfoContent
    @Binding var text: String
    let isSecure: Bool; var placeholder: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            InfoLabel(text: label, info: info)
            if isSecure {
                SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct InlineCredentialField: View {
    let label: String; let info: InfoContent
    @Binding var text: String
    let isSecure: Bool; var placeholder: String = ""
    var body: some View {
        HStack(spacing: 8) {
            InfoLabel(text: label, info: info)
                .frame(width: 140, alignment: .leading)
            if isSecure {
                SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            }
        }
    }
}

private struct SyncTimestamp: View {
    let label: String; let date: Date?
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(date.map { Self.df.string(from: $0) } ?? "Never")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(date == nil ? .secondary : .primary)
        }
    }
}
