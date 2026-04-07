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
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          showAddSheet = true
        } label: {
          Image(systemName: "plus.circle.fill")
            .font(.title3)
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Add a new environment")
        .disabled(syncEngine.isRunning)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

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
        HStack(spacing: 6) {
          Image(systemName: active.scope == .school ? "graduationcap.fill" : "briefcase.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(active.scope.label)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
          .scaleEffect(0.6)
          .frame(width: 14, height: 14)
      } else {
        Image(systemName: env.lastSyncStatus.icon)
          .font(.caption)
          .foregroundStyle(env.lastSyncStatus.color)
          .frame(width: 14, height: 14)
      }

      // Name + scope badge
      VStack(alignment: .leading, spacing: 2) {
        Text(env.name)
          .font(.callout)
          .fontWeight(isActive ? .semibold : .regular)
          .foregroundStyle(isActive ? .primary : .secondary)
          .lineLimit(1)
        Text(env.scope == .school ? "ASM" : "ABM")
          .font(.caption2)
          .foregroundStyle(.secondary)
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
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
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

  @State private var name  = ""
  @State private var scope: AxMScope = .business

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("New Environment")
        .font(.headline)

      TextField("Environment name (e.g. Acme Corp)", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit { if isValid { commit() } }

      VStack(alignment: .leading, spacing: 6) {
        Text("Account Type")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        HStack(spacing: 0) {
          ForEach(AxMScope.allCases, id: \.self) { s in
            Button { scope = s } label: {
              HStack(spacing: 4) {
                Image(systemName: s == .school ? "graduationcap.fill" : "briefcase.fill")
                  .font(.caption)
                Text(s == .school ? "ASM" : "ABM")
                  .font(.callout).fontWeight(.medium)
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 6)
              .background(scope == s ? Color.accentColor : Color(NSColor.controlBackgroundColor))
              .foregroundStyle(scope == s ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
      }

      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Add") { commit() }
          .buttonStyle(.borderedProminent)
          .disabled(!isValid)
      }
    }
    .padding(24)
    .frame(width: 320)
  }

  private func commit() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    let env = envStore.add(name: trimmed, scope: scope)
    envStore.setActive(env.id)
    dismiss()
  }
}

// MARK: - Rename popover

struct RenameEnvironmentView: View {
  @Binding var text: String
  let onCommit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      TextField("Environment name", text: $text)
        .textFieldStyle(.roundedBorder)
        .frame(width: 180)
        .onSubmit { onCommit() }
      Button("Rename") { onCommit() }
        .buttonStyle(.borderedProminent)
        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .padding(12)
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
      // Header
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title2)
          .foregroundStyle(.red)
        Text("Delete Environment")
          .font(.headline)
      }

      // Warning body
      VStack(alignment: .leading, spacing: 10) {
        Text("You are about to permanently delete **\(env.name)**.")
          .fixedSize(horizontal: false, vertical: true)

        Text("This will irreversibly delete:")
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 4) {
          Label("All \(env.scope == .school ? "ASM" : "ABM") device data and coverage cache", systemImage: "internaldrive")
          Label("All Jamf sync history", systemImage: "arrow.triangle.2.circlepath")
          Label("Credentials stored in Keychain", systemImage: "key.fill")
          Label("All sync preferences and timestamps", systemImage: "gearshape")
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.leading, 4)

        Text("This action cannot be undone.")
          .fontWeight(.semibold)
          .foregroundStyle(.red)
      }

      Divider()

      // Confirmation input
      VStack(alignment: .leading, spacing: 6) {
        Text("Type **\(env.name)** to confirm:")
          .font(.callout)
          .foregroundStyle(.secondary)
        TextField("Environment name", text: $confirmName)
          .textFieldStyle(.roundedBorder)
      }

      // Buttons
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
    .frame(width: 420)
  }
}

// MARK: - Migration progress overlay

struct MigrationOverlayView: View {
  let status: String

  var body: some View {
    ZStack {
      Color.black.opacity(0.45)
        .ignoresSafeArea()

      VStack(spacing: 20) {
        ProgressView()
          .scaleEffect(1.4)
          .padding(.bottom, 4)

        Text("Upgrading to v2.0")
          .font(.headline)

        Text(status.isEmpty ? "Migrating data…" : status)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 280)

        Text("This happens once and only takes a moment.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
      .padding(32)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      .shadow(radius: 20)
    }
  }
}
