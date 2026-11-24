// SyncPanelView.swift
// Sync tab UI — run controls, progress block, last run summary, log window.
// Summary and log sit in a VSplitView so the log pane can be resized —
// worthwhile on a long run when the log is the thing worth expanding.
//
// Progress block (SyncProgressBlock):
//   - Step ETA ("~Xm Ys remaining") shown ABOVE the progress bar in orange.
//   - Total ETA ("~Xh Ym total") shown bottom-right below the bar.
//   - Step elapsed time shown bottom-right when no ETA is available.
//   - Elapsed wall-clock timer top-right (counts up since sync started).
//
// Log window (LogWindowView): throttled 8fps refresh, level filter (All /
// Info / Warn+ / Error — Warn+ is warn-or-error), text search. Auto-scroll
// only follows new lines while the user is at the bottom (tracked via an
// invisible sentinel row's onAppear/onDisappear); scrolled up shows a "Jump
// to Latest" pill instead of yanking the view back down. Clear resets only
// the in-memory entries shown here — the on-disk file/rotation is untouched.

import Combine
import SwiftUI

// MARK: - SyncView

struct SyncView: View {
    @ObservedObject  var engine: SyncEngine
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var prefs: AppPreferences

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

            // 3.3: VSplitView instead of a fixed-height ScrollView above a fixed-
            // remainder log — lets the log pane be resized when it's the thing
            // worth expanding (a long run) without losing the summary above.
            VSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        if engine.isRunning {
                            GroupBox {
                                SyncProgressBlock(engine: engine)
                            } label: {
                                Label("In Progress", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.headline)
                            }
                            .padding(.horizontal, 24)
                        }

                        if engine.lastRunDate != nil && !engine.isRunning {
                            SyncOutcomeBanner(engine: engine)
                                .padding(.horizontal, 24)
                        }

                        if engine.lastRunDate != nil {
                            RichRunSummaryCard(engine: engine)
                                .padding(.horizontal, 24)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 120, idealHeight: engine.lastRunDate != nil ? 340 : 160)

                LogWindowView(log: engine.log)
                    .frame(minHeight: 160)
                    .padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .background(.background)
    }
}

// MARK: - Sync outcome banner (S7)
// Shows which of the four outcomes the last run actually produced. A clean success
// stays deliberately quiet — a single green line, no extra chrome or confirmation —
// so the healthy path looks exactly as unremarkable as it did before this change.
struct SyncOutcomeBanner: View {
    @ObservedObject var engine: SyncEngine

    private var detail: String {
        switch engine.lastOutcome {
        case .success:
            return "\(engine.lastRunWBSynced) write-back(s) synced"
        case .partial:
            var bits: [String] = []
            if engine.lastRunWBFailed > 0 { bits.append("\(engine.lastRunWBFailed) write-back(s) failed") }
            if bits.isEmpty { bits.append("some data was not fully synced this run") }
            return bits.joined(separator: " · ") + " — known-good data was kept; re-run to finish"
        case .failed:
            return engine.lastError ?? "The run did not complete. Existing data is unchanged."
        case .cancelled:
            return "Stopped by you. Devices fetched before stopping were saved."
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: engine.lastOutcome.symbol)
                .foregroundStyle(engine.lastOutcome.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.lastOutcome.label)
                    .font(.subheadline).fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(engine.lastOutcome == .success
                      ? Color.secondary.opacity(0.08)
                      : engine.lastOutcome.tint.opacity(0.12))
        )
    }
}

// MARK: - Rich Run Summary Card

struct RichRunSummaryCard: View {
    @ObservedObject var engine: SyncEngine

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    // 3.2: Apple devices · Jamf devices · Coverage checked · Jamf updated ·
    // Jamf failed · Duration — replaces the old tile set, which had an "Active"
    // tile that silently swapped between three unrelated counters and a
    // "Released" tile that read *live* store.stats rather than this run.
    private var appleSubtitle: String {
        if engine.lastRunAxmCount > 0 { return "fetched" }
        if engine.lastRunFromCache > 0 { return "^[\(engine.lastRunFromCache) from cache](inflect: true)" }
        return "cache fresh"
    }
    private var jamfSubtitle: String {
        engine.lastRunJamfCount > 0 ? "fetched" : "cache fresh"
    }
    private var coverageSubtitle: String {
        guard engine.lastRunCovFetched > 0 else { return "no devices checked" }
        return "\(engine.lastRunCovActive) active · \(engine.lastRunCovInactive) inactive"
    }
    private func macMobileSubtitle(mac: Int, mobile: Int) -> String {
        guard mac + mobile > 0 else { return "" }
        return "\(mac) Mac · \(mobile) Mobile"
    }

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

                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, spacing: 10) {
                    RunStatTile(
                        icon: "applelogo",
                        value: "\(engine.lastRunAxmCount)",
                        label: "Apple Devices",
                        color: .blue,
                        subtitle: appleSubtitle
                    )
                    RunStatTile(
                        icon: "server.rack",
                        value: "\(engine.lastRunJamfCount)",
                        label: "Jamf Devices",
                        color: .indigo,
                        subtitle: jamfSubtitle
                    )
                    RunStatTile(
                        icon: "shield.lefthalf.filled",
                        value: "\(engine.lastRunCovFetched)",
                        label: "Coverage Checked",
                        color: .green,
                        subtitle: coverageSubtitle
                    )
                    RunStatTile(
                        icon: "checkmark.circle",
                        value: "\(engine.lastRunWBSynced)",
                        label: "Jamf Updated",
                        color: .purple,
                        subtitle: macMobileSubtitle(mac: engine.lastRunWBSyncedMac, mobile: engine.lastRunWBSyncedMob)
                    )
                    RunStatTile(
                        icon: "xmark.circle",
                        value: "\(engine.lastRunWBFailed)",
                        label: "Jamf Failed",
                        color: engine.lastRunWBFailed > 0 ? .red : .secondary,
                        subtitle: macMobileSubtitle(mac: engine.lastRunWBFailedMac, mobile: engine.lastRunWBFailedMob)
                    )
                    RunStatTile(
                        icon: "clock",
                        value: engine.lastRunElapsed.isEmpty ? "—" : engine.lastRunElapsed,
                        label: "Duration",
                        color: .secondary
                    )
                }

                // Footer
                if engine.lastRunWBFailed > 0 || engine.lastRunMdmServers > 0 {
                    Divider()
                }
                if engine.lastRunWBFailed > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        Text("^[\(engine.lastRunWBFailed) Jamf Update failure](inflect: true)")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                    }
                }
                if engine.lastRunMdmServers > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("^[\(engine.lastRunMdmServers) MDM server](inflect: true) · \(engine.lastRunMdmAssigned) assigned")
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
    var subtitle: String = ""

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
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
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
                // 3.3: the overall-run ETA the file header already documents but
                // never actually rendered — a long coverage run is exactly where
                // "how much longer, total" matters most.
                if !engine.totalETA.isEmpty {
                    HStack {
                        Spacer()
                        Text(engine.totalETA)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        // Elapsed-time ticker: a MainActor-isolated task, restarted whenever the run
        // state flips and auto-cancelled on disappear — no escaping Timer to manage.
        .task(id: engine.isRunning) {
            guard engine.isRunning else { return }
            elapsedSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                elapsedSeconds += 1
            }
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

// 4.hotfix2: a plain-SwiftUI stand-in for Picker(.segmented). The real
// NSSegmentedControl-bridged picker's sizeThatFits is expensive enough that
// even throttling LogWindowView's refresh to 8fps wasn't enough — it shares
// the toolbar HStack with the "N lines"/"N warnings" counters, whose text
// changes on every refresh force the whole row to re-measure, which in turn
// re-triggers the segmented control's layout every single time. This control
// looks the same but is built entirely from Text/Button/Capsule, so
// re-measuring it costs nothing.
private struct LogLevelFilterBar: View {
    @Binding var selection: LogEntry.Level?
    private static let options: [(label: String, value: LogEntry.Level?)] = [
        ("All", nil), ("Info", .info), ("Warn+", .some(.warn)), ("Error", .some(.error))
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.options, id: \.label) { option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.caption2)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
        .clipShape(Capsule())
        .frame(width: 200)
        .help("Warn+ shows warnings and errors together")
    }
}

struct LogWindowView: View {
    // 4.hotfix: NOT @ObservedObject. LogService.entries/warnCount are @Published,
    // and a large concurrent sync (e.g. Force Refresh Coverage over 1,000+
    // devices) can append a log line many times per second — @ObservedObject
    // invalidates this view's ENTIRE body on every single one of those, with no
    // way to read only the properties actually used. That includes the toolbar's
    // segmented level-filter Picker, whose AppKit-bridged sizeThatFits is
    // expensive enough that reflowing it at that rate pins the main thread and
    // makes the whole app unresponsive (confirmed via a hang sample — the stack
    // was 100% inside this view's body, dominated by SystemSegmentedControl
    // layout). Fix: read log.entries/log.warnCount into local @State mirrors,
    // refreshed via a throttled subscription to log.objectWillChange (see
    // .onReceive below) instead of a live @Published binding — this is the
    // "throttled 8fps" the file header above has always claimed but never
    // actually implemented.
    let log: LogService
    @State private var displayedEntries:   [LogEntry] = []
    @State private var displayedWarnCount: Int        = 0
    @State private var filterLevel: LogEntry.Level? = nil
    @State private var searchText:  String          = ""
    // 3.4: tracks whether the bottom-anchor row is currently visible in the
    // scroll viewport — true means the user is at (or near) the bottom, which is
    // when new lines should auto-follow. Toggled by the anchor's onAppear/
    // onDisappear since SwiftUI has no direct scroll-offset API before macOS 15
    // (this app's floor is macOS 14).
    // Tail tracking must not be @State: the sentinel's appear/disappear flips as the
    // list grows, and each @State write re-evaluated the whole body (hang samples:
    // LogWindowView.isAtBottom.setter on every one). The flag lives in a plain box;
    // only the debounced Jump button visibility is @State.
    @State private var tail = LogTailState()
    @State private var showJump = false
    @State private var showClearConfirm = false

    private static let bottomAnchorId = "log-bottom-anchor"

    // Rendering all 2,000 buffered rows on every refresh pins the main thread in a
    // Debug build during a verbose sync (hang sample: LogWindowView.body / isAtBottom
    // setter). Only the newest rows are drawn; the full buffer still backs counts + search.
    private static let maxRenderedRows = 400

    // filterLevel == .warn means "Warn+" — warn and error together — since a
    // segmented control has no room for a genuine multi-select and "everything
    // at or above Warn" is what admins actually want when triaging a run.
    var visibleEntries: [LogEntry] {
        var result = displayedEntries
        if let level = filterLevel {
            result = level == .warn
                ? result.filter { $0.level == .warn || $0.level == .error }
                : result.filter { $0.level == level }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.message.lowercased().contains(q) }
        }
        return Array(result.suffix(Self.maxRenderedRows))
    }

    private func scheduleJumpRefresh() {
        tail.pending?.cancel()
        tail.pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let want = !tail.isAtBottom
            if showJump != want { showJump = want }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──────────────────────────────────────────────
            HStack(spacing: 8) {
                Label("Log", systemImage: "terminal")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if displayedWarnCount > 0 {
                    Text("\(displayedWarnCount) warnings")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15)).foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if !displayedEntries.isEmpty {
                    Text("\(displayedEntries.count) lines")
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

                LogLevelFilterBar(selection: $filterLevel)

                Button { log.copyAll() } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }.buttonStyle(.bordered).help("Copy the full sync log to the clipboard")

                Button { log.openLogFile() } label: {
                    Image(systemName: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).help("Open the raw log file in Console or TextEdit")

                Button { showClearConfirm = true } label: {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.bordered).help("Clear the log shown here — the saved log file on disk is not affected")
                .confirmationDialog("Clear Log?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) {
                        log.clearDisplayedEntries()
                        displayedEntries = []
                        displayedWarnCount = 0
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This clears the log shown here. The saved log file on disk is not affected.")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.bar)

            if !searchText.isEmpty {
                Divider()
                HStack {
                    Text("\(visibleEntries.count) of \(displayedEntries.count) lines match: " + searchText)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.background.secondary)
            }

            Divider()

            // ── Scrollable log ───────────────────────────────────────
            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleEntries) { entry in
                                LogLineView(entry: entry).id(entry.id)
                            }
                            // 3.4: invisible sentinel — its visibility in the
                            // viewport is how we know the user is following the
                            // tail rather than having scrolled up to read
                            // something. New lines only auto-scroll while this
                            // is visible.
                            Color.clear.frame(height: 1)
                                .id(Self.bottomAnchorId)
                                .onAppear { tail.isAtBottom = true; scheduleJumpRefresh() }
                                .onDisappear { tail.isAtBottom = false; scheduleJumpRefresh() }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .onChange(of: displayedEntries.count) { _, _ in
                        guard searchText.isEmpty, tail.isAtBottom, let last = visibleEntries.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    .onChange(of: filterLevel) { _, _ in
                        guard tail.isAtBottom, let last = visibleEntries.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }

                    if showJump && searchText.isEmpty {
                        Button {
                            withAnimation { proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom) }
                        } label: {
                            Label("Jump to Latest", systemImage: "arrow.down.circle.fill")
                                .font(.caption).fontWeight(.medium)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(8)
                    }
                }
            }
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        .onAppear {
            displayedEntries = log.entries
            displayedWarnCount = log.warnCount
        }
        .onReceive(
            log.objectWillChange
                .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            displayedEntries = log.entries
            displayedWarnCount = log.warnCount
        }
    }
}

final class LogTailState {
    var isAtBottom = true
    var pending: Task<Void, Never>?
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
