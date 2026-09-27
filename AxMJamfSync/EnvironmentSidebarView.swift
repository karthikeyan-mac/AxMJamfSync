// EnvironmentSidebarView.swift
// Left sidebar for v2.0 multi-environment navigation.
// Lists environments with status indicators; allows add, rename, delete.
//
// 7.1: environments live in a native List(selection:) — keyboard ↑↓, VoiceOver,
// and the sidebar's vibrancy/selection styling all come from that for free,
// replacing the old manually-highlighted ScrollView+LazyVStack+onTapGesture rows.
// 7.4: rename is inline (double-click the name, or press Return on the selected
// row; Esc cancels) — the popover-based RenameEnvironmentView is gone.

import SwiftUI
import AppKit

// MARK: - Sidebar

struct EnvironmentSidebarView: View {
  @EnvironmentObject private var envStore: EnvironmentStore
  @EnvironmentObject private var syncEngine: SyncEngine
  @State private var showAddSheet      = false
  @State private var renamingId:       UUID?   = nil
  @State private var renameText:       String  = ""
  @FocusState private var renameFieldFocused: Bool
  @State private var deletingId:       UUID?   = nil
  @State private var showMultiSync     = false
  @State private var deleteError:      String? = nil

  /// 7.2: a scope tag on every row is redundant noise when every environment
  /// shares one scope (the common case) — only worth showing when they differ.
  private var scopesAreMixed: Bool {
    Set(envStore.environments.map(\.scope)).count > 1
  }

  /// Write-deferred so List's own internal selection write (during its update
  /// pass) never lands a direct @Published mutation mid-update — same
  /// AttributeGraph hazard as AppStore.facetBinding, see ARCHITECTURE.md.
  private var selectionBinding: Binding<UUID?> {
    Binding(
      get: { envStore.activeEnvironmentId },
      set: { newValue in
        guard let id = newValue else { return }
        DispatchQueue.main.async { envStore.setActive(id) }
      }
    )
  }

  /// Single gate for all three rename entry points (double-click, Return key,
  /// context menu) — renaming while a sync is running (in this process or a
  /// `--silent` one) would show the OLD name in that run's own log header for
  /// its whole duration (AppStore.environmentName is captured once, not
  /// re-read), while the sidebar switches to the new name immediately —
  /// confusing, and no reason to allow it mid-run rather than after.
  private func canRename(_ env: AppEnvironment) -> Bool {
    !envStore.isRunning(env.id) && !envStore.externallyLockedEnvironments.contains(env.id)
  }

  private func startRename(_ env: AppEnvironment) {
    guard canRename(env) else { return }
    renamingId = env.id
    renameText = env.name
    renameFieldFocused = true
  }

  private func commitRename() {
    defer { renamingId = nil }
    guard let id = renamingId else { return }
    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    envStore.rename(id, to: trimmed)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Environments")
          .font(.subheadline)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        Spacer()
        // Multi-sync — only shown when 2+ environments exist
        if envStore.environments.count > 1 {
          Button {
            showMultiSync = true
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .semibold))
              Text("Sync All")
                .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(envStore.isSyncQueueRunning ? Color(.tertiaryLabelColor) : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(envStore.isSyncQueueRunning
                      ? Color(.quaternaryLabelColor)
                      : Color.accentColor.opacity(0.12))
            )
          }
          .buttonStyle(.plain)
          .help("Queue a sync across multiple environments")
          .disabled(envStore.isSyncQueueRunning)
          .popover(isPresented: $showMultiSync, arrowEdge: .trailing) {
            MultiSyncPopover()
          }
        }
        Button {
          showAddSheet = true
        } label: {
          Image(systemName: "plus")
            .font(.callout)
            .fontWeight(.medium)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Add a new environment")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      // Environment list
      List(envStore.environments, id: \.id, selection: selectionBinding) { env in
        EnvironmentRow(
          env:         env,
          isActive:    env.id == envStore.activeEnvironmentId,
          isRunning:   syncEngine.isRunning && env.id == envStore.activeEnvironmentId,
          isLockedExternally: envStore.externallyLockedEnvironments.contains(env.id),
          isQueued:    envStore.syncQueue.dropFirst().contains(env.id),
          blockReason: envStore.deletionBlockReason(env.id),
          showScopeTag: scopesAreMixed,
          isRenaming:  renamingId == env.id,
          renameText:  $renameText,
          renameFieldFocused: $renameFieldFocused,
          onStartRename:  { startRename(env) },
          onCommitRename: { commitRename() },
          onCancelRename: { renamingId = nil },
          onDelete: { deletingId = env.id }
        )
        .tag(env.id)
      }
      .listStyle(.sidebar)
      // 7.4: Return-to-rename — only while nothing is already being renamed and
      // a row is actually selected. Esc-to-cancel lives on the row's TextField
      // itself (.onExitCommand), since only it has keyboard focus by then.
      .onKeyPress(.return) {
        guard renamingId == nil, let id = envStore.activeEnvironmentId,
              let env = envStore.environments.first(where: { $0.id == id }) else { return .ignored }
        startRename(env)
        return .handled
      }

      Divider()

      // Footer — active environment info
      if let active = envStore.activeEnvironment {
        Label(active.scope.label, systemImage: active.scope == .school ? "graduationcap" : "briefcase")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
      }
    }
    // Add sheet
    .sheet(isPresented: $showAddSheet) {
      AddEnvironmentSheet()
    }
    // Delete confirmation sheet
    .sheet(isPresented: Binding(
      get: { deletingId != nil },
      set: { if !$0 { deletingId = nil } }
    )) {
      if let id = deletingId,
         let env = envStore.environments.first(where: { $0.id == id }) {
        DeleteEnvironmentSheet(env: env) {
          let target = id
          deletingId = nil
          Task {
            do { try await envStore.delete(target) }
            catch { deleteError = error.localizedDescription }
          }
        } onCancel: {
          deletingId = nil
        }
      }
    }
    .alert("Couldn’t delete environment",
           isPresented: Binding(get: { deleteError != nil },
                                set: { if !$0 { deleteError = nil } })) {
      Button("OK", role: .cancel) { deleteError = nil }
    } message: {
      Text(deleteError ?? "")
    }
  }
}

// MARK: - Environment row

struct EnvironmentRow: View {
  let env:         AppEnvironment
  let isActive:    Bool
  let isRunning:   Bool
  /// Another process (a `--silent` run) currently holds this environment's sync
  /// lock — see EnvironmentStore.refreshExternalLocks(). Distinct from `isRunning`,
  /// which only reflects a sync running in this GUI process.
  let isLockedExternally: Bool
  let isQueued:    Bool
  /// nil when the environment can be deleted; otherwise why it can't.
  let blockReason: EnvironmentStore.DeletionBlockReason?
  /// 7.2: only draw the trailing ABM/ASM tag when the sidebar actually holds a
  /// mix of scopes — redundant on every row when it's all one scope.
  let showScopeTag: Bool
  // 7.4: inline rename — state lives in the parent (one shared renamingId), this
  // row just reflects whether it's the one currently being edited.
  let isRenaming:  Bool
  @Binding var renameText: String
  var renameFieldFocused: FocusState<Bool>.Binding
  let onStartRename:  () -> Void
  let onCommitRename: () -> Void
  let onCancelRename: () -> Void
  let onDelete:    () -> Void

  @State private var isHovering = false

  /// Same rule as EnvironmentSidebarView.canRename(_:) — kept in sync manually
  /// since this row doesn't have the environment's live running/lock state any
  /// other way than the isRunning/isLockedExternally it's already handed.
  private var canRename: Bool { !isRunning && !isLockedExternally }

  /// Deletable now.
  private var canDelete: Bool { blockReason == nil }
  /// Offer the control (disabled, with a reason) for a transient block; hide it
  /// entirely only for the permanent "last environment" case.
  private var showDeleteControl: Bool {
    blockReason == nil || blockReason == .running || blockReason == .queued || blockReason == .lockedExternally
  }

  var body: some View {
    HStack(spacing: 8) {
      // Status indicator
      if isRunning {
        ProgressView()
          .fixedSize()
          .scaleEffect(0.55)
          .frame(width: 12, height: 12)
      } else if isLockedExternally {
        Image(systemName: "terminal.fill")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .frame(width: 12, height: 12)
      } else if isQueued {
        Image(systemName: "clock")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .frame(width: 12, height: 12)
      } else {
        Image(systemName: env.lastSyncStatus.icon)
          .font(.system(size: 11))
          .foregroundStyle(env.lastSyncStatus.color)
          .frame(width: 12, height: 12)
      }

      // Name (or inline rename field) + last-synced subtitle
      VStack(alignment: .leading, spacing: 1) {
        if isRenaming {
          TextField("Environment name", text: $renameText)
            .textFieldStyle(.plain)
            .font(.callout)
            .focused(renameFieldFocused)
            .onSubmit { onCommitRename() }
            .onExitCommand { onCancelRename() }
        } else {
          Text(env.name)
            .font(.callout)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? .primary : .secondary)
            .lineLimit(1)
            // Double-click is a no-op while locked — onStartRename() routes through
            // the parent's startRename(_:), which re-checks canRename itself. No
            // visual affordance either way for a double-click, unlike the context
            // menu item below, so there's nothing to disable here.
            .onTapGesture(count: 2) { onStartRename() }
        }
        // 7.2: sync recency — an MSP scanning many tenants wants "when did
        // this last run", not a scope label duplicating the sidebar footer.
        HStack(spacing: 3) {
          if isLockedExternally {
            Image(systemName: "terminal.fill")
              .font(.system(size: 8))
              .foregroundStyle(.secondary)
            Text("Syncing (command-line)")
          } else {
            Image(systemName: env.lastSyncStatus.icon)
              .font(.system(size: 8))
              .foregroundStyle(env.lastSyncStatus.color)
            if let date = env.lastSyncedAt {
              Text("Synced ") + Text(date, style: .relative)
            } else {
              Text("Never synced")
            }
          }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }

      Spacer()

      if showScopeTag {
        Text(env.scope == .school ? "ASM" : "ABM")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Color.secondary.opacity(0.12))
          .clipShape(Capsule())
      }

      // 7.3: hover-only now — the typed-name delete sheet already guards
      // against a misclick, so a permanently-visible trash icon next to the
      // active environment was just unnerving with no added safety.
      if isHovering && showDeleteControl {
        Button {
          onDelete()
        } label: {
          Image(systemName: "trash")
            .font(.caption)
            .foregroundStyle(.red.opacity(canDelete ? 0.7 : 0.25))
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
        .help(blockReason?.userMessage ?? "Delete this environment and all its data")
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    // The environment ID is what a log filename, --env, and Full Disk Access
    // debugging all key off — a system tooltip alone isn't selectable text, so
    // it's also on the context menu below for an actual copy.
    .help("Environment ID: \(env.id.uuidString)")
    .contextMenu {
      Button("Rename…") { onStartRename() }
        .disabled(!canRename)
      if !canRename {
        Text(isLockedExternally ? "A command-line sync is running for this environment"
                                 : "Sync in progress")
      }
      Button("Copy Environment ID") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env.id.uuidString, forType: .string)
      }
      Divider()
      Button("Delete…", role: .destructive) { onDelete() }
        .disabled(!canDelete)
      if let blockReason { Text(blockReason.userMessage) }
    }
    .animation(.easeInOut(duration: 0.15), value: isHovering)
  }
}

// MARK: - Add environment sheet

struct AddEnvironmentSheet: View {
  @EnvironmentObject private var envStore: EnvironmentStore
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("New Environment")
        .font(.headline)

      Text("Enter a name for this environment. The account type (ABM or ASM) will be set automatically when you configure credentials in Setup.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      TextField("Environment name (e.g. Acme Corp)", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit { if isValid { commit() } }

      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Add Environment") { commit() }
          .buttonStyle(.borderedProminent)
          .disabled(!isValid)
      }
    }
    .padding(24)
    .frame(width: 340)
  }

  private func commit() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    // Scope defaults to .business — updated automatically when credentials are saved
    let env = envStore.add(name: trimmed, scope: .business)
    envStore.setActive(env.id)
    dismiss()
  }
}

// MARK: - Delete environment confirmation sheet

struct DeleteEnvironmentSheet: View {
  let env:      AppEnvironment
  let onDelete: () -> Void
  let onCancel: () -> Void

  @State private var confirmName = ""

  private var nameMatches: Bool {
    confirmName.trimmingCharacters(in: .whitespaces).lowercased() == env.name.lowercased()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "trash.circle.fill")
          .symbolRenderingMode(.multicolor)
          .font(.title)
        Text("Delete Environment")
          .font(.headline)
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("You are about to permanently delete **\(env.name)**.")
          .fixedSize(horizontal: false, vertical: true)

        Text("This will irreversibly remove:")
          .font(.callout)
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 6) {
          Label("\(env.scope == .school ? "ASM" : "ABM") device data and coverage cache", systemImage: "internaldrive")
          Label("All Jamf sync history", systemImage: "arrow.triangle.2.circlepath")
          Label("Keychain credentials", systemImage: "key.fill")
          Label("Sync preferences and timestamps", systemImage: "gearshape")
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.leading, 2)

        Text("This action cannot be undone.")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundStyle(.red)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("Type **\(env.name)** to confirm:")
          .font(.callout)
          .foregroundStyle(.secondary)
        TextField("Environment name", text: $confirmName)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.escape)
        Spacer()
        Button("Delete Permanently", role: .destructive) { onDelete() }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!nameMatches)
      }
    }
    .padding(24)
    .frame(width: 400)
  }
}

// MARK: - Multi-sync popover

struct MultiSyncPopover: View {
  @EnvironmentObject private var envStore:   EnvironmentStore
  @EnvironmentObject private var syncEngine: SyncEngine
  @Environment(\.dismiss) private var dismiss

  @State private var selected: Set<UUID> = []

  private var allSelected: Bool { selected.count == envStore.environments.count }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {

      // ── Header ───────────────────────────────────────────────────────────
      HStack {
        Label("Run Multiple Syncs", systemImage: "arrow.triangle.2.circlepath.circle.fill")
          .symbolRenderingMode(.hierarchical)
          .font(.headline)
        Spacer()
        Button(allSelected ? "Deselect All" : "Select All") {
          if allSelected { selected.removeAll() }
          else           { selected = Set(envStore.environments.map(\.id)) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(Color.accentColor)
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 10)

      Text("Choose environments to add to the sync queue. They will run one at a time in order.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)

      Divider()

      // ── Environment checklist ─────────────────────────────────────────────
      ScrollView {
        VStack(spacing: 0) {
          ForEach(envStore.environments) { env in
            let isChecked = selected.contains(env.id)
            HStack(spacing: 10) {
              Toggle("", isOn: Binding(
                get: { isChecked },
                set: { on in
                  if on { selected.insert(env.id) }
                  else  { selected.remove(env.id) }
                }
              ))
              .toggleStyle(.checkbox)
              .labelsHidden()

              Image(systemName: env.lastSyncStatus.icon)
                .font(.system(size: 10))
                .foregroundStyle(env.lastSyncStatus.color)
                .frame(width: 12)

              VStack(alignment: .leading, spacing: 1) {
                Text(env.name)
                  .font(.callout)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                Text(env.scope == .school ? "ASM" : "ABM")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }

              Spacer()

              if let date = env.lastSyncedAt {
                Text(date, style: .relative)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
              if isChecked { selected.remove(env.id) }
              else         { selected.insert(env.id) }
            }

            if env.id != envStore.environments.last?.id {
              Divider().padding(.leading, 16)
            }
          }
        }
      }
      .frame(maxHeight: 240)

      Divider()

      // ── Footer ────────────────────────────────────────────────────────────
      HStack {
        if selected.isEmpty {
          Text("Select at least one environment")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          Text("^[\(selected.count) environment](inflect: true) selected")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.escape)
        Button("Add to Queue") {
          let orderedIds = envStore.environments.map(\.id).filter { selected.contains($0) }
          dismiss()
          envStore.enqueueMultiSync(ids: orderedIds)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selected.isEmpty)
        .keyboardShortcut(.return)
      }
      .padding(16)
    }
    .frame(width: 340)
    .onAppear {
      selected = Set(envStore.environments.map(\.id))
    }
  }
}

// MARK: - Migration progress overlay

struct MigrationOverlayView: View {
  let status: String
  var error: String? = nil

  var body: some View {
    ZStack {
      Color.black.opacity(0.35)
        .ignoresSafeArea()

      VStack(spacing: 16) {
        if let error {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 30))
            .foregroundStyle(.orange)

          Text("Upgrade couldn’t be completed")
            .font(.headline)

          Text(error)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)

          Text("Nothing was deleted. Quit and reopen AxM Jamf Sync to try again.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)

          Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut(.defaultAction)
        } else {
          ProgressView()
            .fixedSize()
            .scaleEffect(1.2)

          Text("Upgrading to v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2")")
            .font(.headline)

          Text(status.isEmpty ? "Migrating data…" : status)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 260)

          Text("This happens once and only takes a moment.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(28)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    }
  }
}
