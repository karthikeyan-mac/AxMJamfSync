// DashboardChartViews.swift
// Shared Swift Charts components for the Dashboard's AxM and Jamf focus modes.
// The Common focus keeps its existing hand-drawn Canvas ring (CoverageRingView) —
// these are additive, for the two newer focus modes.

import SwiftUI
import Charts

// MARK: - Horizontal bar chart for a label → count breakdown
struct BreakdownBarChart: View {
  let breakdown: [String: Int]
  let color: Color
  var sortMode: BreakdownSortMode = .byCountDescending
  var maxBars: Int = 8
  var emptyText: String = "No data yet"
  // Drill-down to Devices tab, filtered to this row's exact label. Not offered for
  // "Other" — that bucket lumps together several real values with no single filter
  // that could represent it, unlike "Unknown" which is a real, matchable category.
  var onTapRow: ((String) -> Void)? = nil

  // "Unknown" always floats to the very end regardless of sort mode. It's a
  // diagnostic catch-all, not a real category — ranking it alongside real values
  // can otherwise put it first (plain string sort puts "Unknown" ahead of "9"
  // ahead of "26", since 'U' > any digit character) or bury it inside "Other".
  private var ranked: [(String, Int)] {
    let known = breakdown.filter { $0.key != "Unknown" }
    switch sortMode {
    case .byCountDescending:
      return known.sorted { $0.value > $1.value }
    case .byKeyDescending:
      return known.sorted { $0.key > $1.key }
    case .byVersionDescending:
      // Numeric-aware — for version-style keys like "26"/"9" where a plain
      // string sort would otherwise order "9" ahead of "26".
      return known.sorted { (Int($0.key) ?? -1) > (Int($1.key) ?? -1) }
    }
  }
  private var unknownCount: Int { breakdown["Unknown"] ?? 0 }

  // Built as a plain computed property, not inline in `body` — a SwiftUI ViewBuilder
  // interprets every `if` inside `body` as contributing to the view hierarchy, so
  // imperative statements like `rows.append(...)` (which produce `()`, not a View)
  // fail to compile there. Keeping this out of body sidesteps that entirely.
  private var rows: [(String, Int)] {
    let shown = Array(ranked.prefix(maxBars))
    let rest  = ranked.dropFirst(maxBars).reduce(0) { $0 + $1.1 }
    var result = shown
    if rest > 0         { result.append(("Other", rest)) }
    if unknownCount > 0 { result.append(("Unknown", unknownCount)) }
    return result
  }
  private var maxValue: Int { rows.map(\.1).max() ?? 1 }

  // Custom row layout instead of a Swift Charts BarMark — BarMark's trailing
  // annotation places the count right after wherever that row's bar happens to
  // end, so short bars get their number sitting near the left edge instead of
  // in a clean aligned column. This keeps the count in a fixed-width trailing
  // column regardless of bar length, and lets the label be styled bold.
  var body: some View {
    if ranked.isEmpty && unknownCount == 0 {
      Text(emptyText)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(rows, id: \.0) { label, count in
          let isCatchAll = label == "Other" || label == "Unknown"
          let row = HStack(spacing: 10) {
            Text(label)
              .font(.caption.bold())
              .foregroundStyle(isCatchAll ? .secondary : .primary)
              .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
              RoundedRectangle(cornerRadius: 3)
                .fill((isCatchAll ? Color.secondary : color).gradient)
                .frame(width: max(4, geo.size.width * CGFloat(count) / CGFloat(maxValue)))
            }
            .frame(height: 10)
            Text("\(count)")
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(width: 40, alignment: .trailing)
          }
          if label != "Other", let onTapRow {
            DashboardDrillDown(action: { onTapRow(label) }) { row }
          } else {
            row
          }
        }
      }
    }
  }
}

// MARK: - Vertical trend chart for a year → count breakdown, chronological order
struct YearTrendChart: View {
  let breakdown: [String: Int]
  let color: Color
  var unknownLabel: String = "Unknown"
  var onTapUnknown: (() -> Void)? = nil

  private var years: [(String, Int)] {
    breakdown.filter { $0.key != "Unknown" }.sorted { $0.key < $1.key }
  }
  private var unknownCount: Int { breakdown["Unknown"] ?? 0 }

  var body: some View {
    if years.isEmpty && unknownCount == 0 {
      Text("No data yet")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        if !years.isEmpty {
          Chart(years, id: \.0) { year, count in
            BarMark(
              x: .value("Year", year),
              y: .value("Devices", count)
            )
            .foregroundStyle(color.gradient)
          }
          .frame(height: 160)
          // Explicit axis labels on BOTH axes, no customisation beyond the default
          // position. Charts' own automatic label-placement — on the numeric Y
          // axis as much as the string X axis, and this is the one that was
          // actually still firing after an X-only override — can pick a
          // non-standard UnitPoint anchor near a plot edge to dodge clipping,
          // which its renderer doesn't support and logs a warning for (harmless —
          // it still renders correctly). Taking over rendering here, even with
          // nothing actually customised, is what stops Charts computing that
          // anchor itself.
          .chartXAxis {
            AxisMarks { _ in
              AxisValueLabel()
            }
          }
          .chartYAxis {
            AxisMarks { _ in
              AxisValueLabel()
            }
          }
        }
        if unknownCount > 0 {
          if let onTapUnknown {
            DashboardDrillDown(action: onTapUnknown) {
              DashStatRow(label: unknownLabel, value: unknownCount, color: .secondary)
            }
          } else {
            DashStatRow(label: unknownLabel, value: unknownCount, color: .secondary)
          }
        }
      }
    }
  }
}

// MARK: - Donut chart for a small set of proportional segments (Swift Charts SectorMark)
struct DonutSegment: Identifiable {
  var id: String { label }
  let label: String
  let value: Int
  let color: Color
}

struct DonutChartView: View {
  let segments: [DonutSegment]
  let centerTitle: String
  let centerSubtitle: String

  private var nonZero: [DonutSegment] { segments.filter { $0.value > 0 } }

  var body: some View {
    ZStack {
      if nonZero.isEmpty {
        Circle()
          .stroke(Color.secondary.opacity(0.15), lineWidth: 18)
      } else {
        Chart(nonZero) { seg in
          SectorMark(
            angle: .value("Count", seg.value),
            innerRadius: .ratio(0.62),
            angularInset: 1.5
          )
          .foregroundStyle(seg.color)
          .cornerRadius(3)
        }
        .chartLegend(.hidden)
      }

      VStack(spacing: 2) {
        Text(centerTitle)
          .font(.system(.title2, design: .rounded, weight: .bold))
        Text(centerSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

// Builds colored segments from a plain label → count breakdown, cycling through
// the given palette in descending-count order. Used where categories are dynamic
// (product family, purchase source) rather than fixed, known values.
extension DonutChartView {
  static func segments(from breakdown: [String: Int], palette: [Color]) -> [DonutSegment] {
    breakdown.sorted { $0.value > $1.value }.enumerated().map { index, entry in
      DonutSegment(label: entry.key, value: entry.value, color: palette[index % palette.count])
    }
  }
}

// MARK: - Dashboard facet bar shared controls
// Used by all three focus modes' facet filter bars (Default / Apple / Jamf).

// A Menu with a fully custom trigger — pill-shaped, icon-led, tinted with the
// accent color whenever a non-default value is selected — instead of the default
// macOS `.menu` picker style's plain "Label: Value" text. Used for facets with
// more values than a segmented control comfortably fits (FileVault, Check-in,
// Coverage, Write-back, Product Family, Purchase Source).
struct FacetChipMenu<Value: Hashable>: View {
  let icon: String
  let title: String
  let options: [(label: String, value: Value?)]
  @Binding var selection: Value?

  private var isActive: Bool { selection != nil }
  private var currentLabel: String {
    options.first { $0.value == selection }?.label ?? title
  }

  var body: some View {
    Menu {
      ForEach(options.indices, id: \.self) { i in
        Button {
          selection = options[i].value
        } label: {
          if selection == options[i].value {
            Label(options[i].label, systemImage: "checkmark")
          } else {
            Text(options[i].label)
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
        Text(isActive ? currentLabel : title)
        Image(systemName: "chevron.down")
          .font(.caption2)
      }
      .font(.caption)
      .padding(.horizontal, 12)
      .frame(height: 26)
      .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
      .foregroundStyle(isActive ? Color.accentColor : Color.primary)
      .overlay(
        Capsule().strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.3))
      )
      .clipShape(Capsule())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

// The dismissible pill shown in a facet bar's active-filter row — same style used
// for Dashboard drill-down filter chips in DevicesView.swift.
struct FacetActiveChip: View {
  let label: String
  var onClear: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(label)
      Button(action: onClear) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .help("Clear this filter")
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.accentColor.opacity(0.12))
    .foregroundStyle(Color.accentColor)
    .clipShape(Capsule())
  }
}
