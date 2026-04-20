// SyncPanelView.swift
// Sync tab UI — run controls, progress block, last run summary, log window.
//
// Progress block (SyncProgressBlock):
//   - Step ETA ("~Xm Ys remaining") shown ABOVE the progress bar in orange.
//   - Total ETA ("~Xh Ym total") shown bottom-right below the bar.
//   - Step elapsed time shown bottom-right when no ETA is available.
//   - Elapsed wall-clock timer top-right (counts up since sync started).
//
// Log window (LogWindowView): throttled 8fps refresh, level filter, text search.

import SwiftUI

// MARK: - SyncView

struct SyncView: View {
    @ObservedObject  var engine: SyncEngine
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var prefs: AppPreferences
    // Use the engine's per-environment log — not the shared singleton.
    private var log: LogService { engine.log }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ───────────────────────────────────────────────
            HStack(alignment: .center) {
                Text("Monitor progress and live log output.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                GlobalSyncButton(engine: engine)
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)

            // ── Scrollable content ───────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Progress card — only shown while running (#6)
                    if engine.isRunning {
                        GroupBox {
                            SyncProgressBlock(engine: engine)
                        } label: {
                            Label("In Progress", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                        }
                        .padding(.horizontal, 24)
                    }

                    // Rich run summary — shown after sync completes
                    if engine.lastRunDate != nil {
                        RichRunSummaryCard(engine: engine)
                            .padding(.horizontal, 24)
                    }

                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: engine.lastRunDate != nil ? 420 : 180)

            Divider()

            // ── Log window — fixed below, always scrollable ──────────
            LogWindowView(log: log)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(.background)
    }
}

// MARK: - Rich Run Summary Card (matches image 3)

struct RichRunSummaryCard: View {
    @ObservedObject var engine: SyncEngine
    @EnvironmentObject private var store: AppStore

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                // Timestamp top-right
                HStack {
                    Label("Last Run Summary", systemImage: "chart.bar.fill")
                        .font(.subheadline).fontWeight(.semibold)
                    Spacer()
                    if let date = engine.lastRunDate {
                        Text(Self.dateFmt.string(from: date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // 3×2 tile grid — exactly matching the screenshot
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, spacing: 10) {
                    RunStatTile(
                        icon: "checkmark.circle",
                        value: "\(engine.lastRunAxmCount > 0 ? engine.lastRunAxmCount : (engine.lastRunFromCache > 0 ? engine.lastRunFromCache : engine.lastRunJamfCount))",
                        label: "Active",
                        color: .blue
                    )
                    RunStatTile(
                        icon: "shield.lefthalf.filled",
                        value: "\(engine.lastRunCovActive)",
                        label: "Coverage Active",
                        color: .green
                    )
                    RunStatTile(
                        icon: "minus.circle",
                        value: "\(store.stats.axmReleased)",
                        label: "Released",
                        color: .orange
                    )
                    RunStatTile(
                        icon: "tray.2.fill",
                        value: "\(engine.lastRunFromCache)",
                        label: "From Cache",
                        color: .purple
                    )
                    RunStatTile(
                        icon: "shield.slash",
                        value: "\(engine.lastRunCovNone)",
                        label: "No Coverage Info",
                        color: .pink
                    )
                    RunStatTile(
                        icon: "xmark.circle",
                        value: "\(engine.lastRunWBFailed)",
                        label: "Failed",
                        color: .secondary
                    )
                }

                // Footer
                Divider()
                HStack {
                    if !engine.lastRunElapsed.isEmpty {
                        Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                        Text("Completed in \(engine.lastRunElapsed)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.lastRunWBFailed > 0 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        Text("\(engine.lastRunWBFailed) Jamf Update failure\(engine.lastRunWBFailed == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if engine.lastRunMdmServers > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(engine.lastRunMdmServers) MDM server\(engine.lastRunMdmServers == 1 ? "" : "s") · \(engine.lastRunMdmAssigned) assigned")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct RunStatTile: View {
    let icon:  String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(color)
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16).padding(.horizontal, 8)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Progress block

struct SyncProgressBlock: View {
    @ObservedObject var engine: SyncEngine
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                phaseIconView
                Text(engine.stepLabel.isEmpty ? "Waiting for sync to start…" : engine.stepLabel)
                    .font(.callout)
                    .foregroundStyle(engine.phase == .error ? Color.red : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if elapsedSeconds > 0 {
                    Text(formattedElapsed)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: engine.fraction)
                .tint(engine.phase == .error ? .red :
                      engine.phase == .done  ? .green : Color.accentColor)
            if engine.totalSteps > 0 {
                HStack {
                    Text("\(engine.currentStep) / \(engine.totalSteps)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    // Bottom-right: step ETA (remaining) > step elapsed > percent
                    if !engine.stepETA.isEmpty {
                        Text(engine.stepETA)
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !engine.stepElapsed.isEmpty {
                        Text("Step: \(engine.stepElapsed)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("\(Int(engine.fraction * 100))%")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .onChange(of: engine.isRunning) { _, running in
            if running {
                elapsedSeconds = 0
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    elapsedSeconds += 1
                }
            } else {
                timer?.invalidate(); timer = nil
            }
        }
        .onDisappear {
            // Safety: if the view is removed while a sync is running (tab switch),
            // invalidate the timer so it does not fire against a deallocated @State.
            timer?.invalidate(); timer = nil
        }
    }

    @ViewBuilder private var phaseIconView: some View {
        if engine.isRunning {
            ProgressView()
                .fixedSize()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: engine.phase == .done  ? "checkmark.circle.fill" :
                              engine.phase == .error ? "xmark.circle.fill" : "clock")
                .font(.callout)
                .foregroundStyle(engine.phase == .done  ? Color.green :
                                 engine.phase == .error ? Color.red : Color.secondary)
        }
    }

    private var formattedElapsed: String {
        let m = elapsedSeconds / 60; let s = elapsedSeconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

// MARK: - Log Window (throttled 8fps, with search)

struct LogWindowView: View {
    @ObservedObject var log: LogService
    @State private var filterLevel: LogEntry.Level? = nil
    @State private var searchText:  String          = ""

    var visibleEntries: [LogEntry] {
        var result = log.entries
        if let level = filterLevel { result = result.filter { $0.level == level } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.message.lowercased().contains(q) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──────────────────────────────────────────────
            HStack(spacing: 8) {
                Label("Log", systemImage: "terminal")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if log.warnCount > 0 {
                    Text("\(log.warnCount) warnings")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15)).foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if !log.entries.isEmpty {
                    Text("\(log.entries.count) lines")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Search
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                    TextField("Search log…", text: $searchText)
                        .textFieldStyle(.plain).font(.caption).frame(width: 130)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Picker("", selection: $filterLevel) {
                    Text("All").tag(Optional<LogEntry.Level>.none)
                    Text("Info").tag(Optional<LogEntry.Level>.some(.info))
                    Text("Warn").tag(Optional<LogEntry.Level>.some(.warn))
                    Text("Error").tag(Optional<LogEntry.Level>.some(.error))
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                .controlSize(.small)

                Button { log.copyAll() } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }.buttonStyle(.bordered).help("Copy the full sync log to the clipboard")

                Button { log.openLogFile() } label: {
                    Image(systemName: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).help("Open the raw log file in Console or TextEdit")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.bar)

            if !searchText.isEmpty {
                Divider()
                HStack {
                    Text("\(visibleEntries.count) of \(log.entries.count) lines match: " + searchText)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.background.secondary)
            }

            Divider()

            // ── Scrollable log ───────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            LogLineView(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .onChange(of: log.entries.count) { _, _ in
                    guard searchText.isEmpty, let last = visibleEntries.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
    }
}

// MARK: - Log line
struct LogLineView: View {
    let entry: LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timeString)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(entry.level.icon)
                .font(.system(size: 10)).foregroundStyle(entry.level.color)
                .frame(width: 12)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level == .warn ? Color.orange :
                                 entry.level == .error ? Color.red :
                                 Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1.5).padding(.horizontal, 6)
        .background(entry.level == .warn  ? Color.orange.opacity(0.05) :
                    entry.level == .error ? Color.red.opacity(0.05)    : Color.clear)
    }
}
