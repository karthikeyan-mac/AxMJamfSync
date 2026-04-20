// EnvironmentSidebarView.swift
// Left sidebar for v2.0 multi-environment navigation.
// Lists environments with status indicators; allows add, rename, delete.

import SwiftUI

// MARK: - Sidebar

struct EnvironmentSidebarView: View {
  @EnvironmentObject private var envStore: EnvironmentStore
  @EnvironmentObject private var syncEngine: SyncEngine
  @State private var showAddSheet    = false
  @State private var renamingId:     UUID?   = nil
  @State private var renameText:     String  = ""
  @State private var deletingId:     UUID?   = nil

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Environments")
          .font(.subheadline)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        Spacer()
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
        .disabled(syncEngine.isRunning)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      // Environment list
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(envStore.environments) { env in
            EnvironmentRow(
              env:        env,
              isActive:   env.id == envStore.activeEnvironmentId,
              isRunning:  syncEngine.isRunning && env.id == envStore.activeEnvironmentId,
              canDelete:  envStore.canDelete(env.id),
              onSelect:   { envStore.setActive(env.id) },
              onRename: {
                renamingId = env.id
                renameText = env.name
              },
              onDelete:   {
                deletingId = env.id
              }
            )
          }
        }
        .padding(.vertical, 4)
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
    // Rename popover
    .popover(isPresented: Binding(
      get: { renamingId != nil },
      set: { if !$0 { renamingId = nil } }
    )) {
      RenameEnvironmentView(text: $renameText) {
        if let id = renamingId, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
          envStore.rename(id, to: renameText.trimmingCharacters(in: .whitespaces))
        }
        renamingId = nil
      }
    }
    // Delete confirmation sheet
    .sheet(isPresented: Binding(
      get: { deletingId != nil },
      set: { if !$0 { deletingId = nil } }
    )) {
      if let id = deletingId,
         let env = envStore.environments.first(where: { $0.id == id }) {
        DeleteEnvironmentSheet(env: env) {
          envStore.delete(id)
          deletingId = nil
        } onCancel: {
          deletingId = nil
        }
      }
    }
  }
}

// MARK: - Environment row

struct EnvironmentRow: View {
  let env:       AppEnvironment
  let isActive:  Bool
  let isRunning: Bool
  let canDelete: Bool
  let onSelect:  () -> Void
  let onRename:  () -> Void
  let onDelete:  () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 8) {
      // Status indicator
      if isRunning {
        ProgressView()
          .fixedSize()
          .scaleEffect(0.55)
          .frame(width: 12, height: 12)
      } else {
        Image(systemName: env.lastSyncStatus.icon)
          .font(.system(size: 11))
          .foregroundStyle(env.lastSyncStatus.color)
          .frame(width: 12, height: 12)
      }

      // Name + scope badge
      VStack(alignment: .leading, spacing: 1) {
        Text(env.name)
          .font(.callout)
          .fontWeight(isActive ? .semibold : .regular)
          .foregroundStyle(isActive ? .primary : .secondary)
          .lineLimit(1)
        Text(env.scope == .school ? "ASM" : "ABM")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Spacer()

      // Delete button — visible on hover or when active
      if (isHovering || isActive) && canDelete {
        Button {
          onDelete()
        } label: {
          Image(systemName: "trash")
            .font(.caption)
            .foregroundStyle(.red.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help("Delete this environment and all its data")
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .onHover { isHovering = $0 }
    .contextMenu {
      Button("Rename…") { onRename() }
      if canDelete {
        Divider()
        Button("Delete…", role: .destructive) { onDelete() }
      }
    }
    .padding(.horizontal, 4)
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

// MARK: - Rename popover

struct RenameEnvironmentView: View {
  @Binding var text: String
  let onCommit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Environment")
        .font(.headline)
      TextField("Environment name", text: $text)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
        .onSubmit { onCommit() }
      HStack {
        Spacer()
        Button("Rename") { onCommit() }
          .buttonStyle(.borderedProminent)
          .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(16)
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

// MARK: - Migration progress overlay

struct MigrationOverlayView: View {
  let status: String

  var body: some View {
    ZStack {
      Color.black.opacity(0.35)
        .ignoresSafeArea()

      VStack(spacing: 16) {
        ProgressView()
          .fixedSize()
          .scaleEffect(1.2)

        Text("Upgrading to v2.1")
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
      .padding(28)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    }
  }
}
