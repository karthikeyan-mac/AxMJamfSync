// FriendlyCronBuilderView.swift
// A Mac-admin-friendly front end for CronExpression. Instead of editing five
// raw cron fields, the admin picks one repeat unit and fills in the values
// that unit actually needs:
//   Minute(s) → every N minutes
//   Hour(s)   → every N hours, at :MM past the hour
//   Day(s)    → one or more times a day (hour chips + a shared minute) — this
//               is also how real crontabs express "three times a day", e.g.
//               "0 8,14,20 * * *", so it covers what a separate "specific
//               times" feature would have without inventing new syntax.
//   Week(s)   → same as Day(s), restricted to chosen weekdays
//   Month(s)  → on a chosen day-of-month, at a specific time
// The raw cron expression is still generated and shown (read-only, in Settings'
// Advanced disclosure) so nothing is hidden — this view is just a nicer way to
// write it than five raw fields.

import SwiftUI

private enum RepeatUnit: String, CaseIterable, Identifiable {
  case minute = "Minute(s)"
  case hour   = "Hour(s)"
  case day    = "Day(s)"
  case week   = "Week(s)"
  case month  = "Month(s)"
  var id: String { rawValue }
}

struct FriendlyCronBuilderView: View {
  @EnvironmentObject private var scheduler: SyncScheduler

  @State private var unit:             RepeatUnit
  @State private var everyN:           Int
  @State private var minuteOfHour:     Int          // Hour(s) unit — shared minute for the interval
  @State private var selectedHours:    Set<Int>     // Day(s) / Week(s) — one or more times of day
  @State private var sharedMinute:     Int          // Day(s) / Week(s) — minute shared by all selected hours
  @State private var selectedWeekdays: Set<Int>
  @State private var dayOfMonth:       Int
  @State private var monthTimeOfDay:   Date
  /// False until loadFromScheduler finishes seeding state from the current
  /// expression — guards commit() so the seeding assignments don't immediately
  /// overwrite the very expression they were just loaded from.
  @State private var isReady = false

  private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

  init() {
    // Real initial values are set from the scheduler's current expression in onAppear —
    // these are just placeholders so the @State properties have something to hold.
    _unit             = State(initialValue: .day)
    _everyN           = State(initialValue: 1)
    _minuteOfHour     = State(initialValue: 0)
    _selectedHours    = State(initialValue: [9])
    _sharedMinute     = State(initialValue: 0)
    _selectedWeekdays = State(initialValue: [1]) // Monday
    _dayOfMonth       = State(initialValue: 1)
    _monthTimeOfDay   = State(initialValue: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Repeat Every", selection: $unit) {
        ForEach(RepeatUnit.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .onChange(of: unit) { _, _ in commit() }

      switch unit {
      case .minute:
        Stepper("Every \(everyN) minute\(everyN == 1 ? "" : "s")", value: $everyN, in: 1...59)
          .onChange(of: everyN) { _, _ in commit() }

      case .hour:
        Stepper("Every \(everyN) hour\(everyN == 1 ? "" : "s")", value: $everyN, in: 1...23)
          .onChange(of: everyN) { _, _ in commit() }
        Stepper("At minute \(minuteOfHour)", value: $minuteOfHour, in: 0...59)
          .onChange(of: minuteOfHour) { _, _ in commit() }
          .help("Only the minute value is used — the hour is governed by \u{201C}Every \(everyN) hour(s)\u{201D} above.")

      case .day:
        hourChipGrid
        Stepper("At minute \(sharedMinute)", value: $sharedMinute, in: 0...59)
          .onChange(of: sharedMinute) { _, _ in commit() }

      case .week:
        weekdayPicker
        hourChipGrid
        Stepper("At minute \(sharedMinute)", value: $sharedMinute, in: 0...59)
          .onChange(of: sharedMinute) { _, _ in commit() }

      case .month:
        Stepper("On day \(dayOfMonth) of the month", value: $dayOfMonth, in: 1...31)
          .onChange(of: dayOfMonth) { _, _ in commit() }
        DatePicker("At", selection: $monthTimeOfDay, displayedComponents: .hourAndMinute)
          .onChange(of: monthTimeOfDay) { _, _ in commit() }
      }

      summaryLabel
    }
    .onAppear { loadFromScheduler() }
  }

  /// Live readout of the schedule currently in effect — reflects the friendly
  /// controls above, and also picks up hand-typed edits from the Advanced raw
  /// cron field, since both write through to the same `scheduler.cronExpression`.
  /// Styled green to match the header bar's Next Sync badge — the shared color
  /// signals "this schedule is active" wherever it's shown.
  private var summaryLabel: some View {
    Label(scheduler.cronExpression.humanSummary, systemImage: "calendar.badge.clock")
      .font(.callout)
      .fontWeight(.medium)
      .foregroundStyle(.green)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.green.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .padding(.top, 4)
  }

  private var hourChipGrid: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(selectedHours.count > 1 ? "At these times" : "At this time")
        .font(.caption)
        .foregroundStyle(.secondary)
      let columns = [GridItem(.adaptive(minimum: 40), spacing: 6)]
      LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
        ForEach(0..<24, id: \.self) { h in
          let isOn = selectedHours.contains(h)
          Button {
            if isOn, selectedHours.count > 1 { selectedHours.remove(h) }
            else if !isOn { selectedHours.insert(h) }
            commit()
          } label: {
            Text(String(format: "%02d", h))
              .font(.caption)
              .frame(minWidth: 32)
              .padding(.vertical, 3)
          }
          .buttonStyle(.bordered)
          .tint(isOn ? .accentColor : .secondary)
        }
      }
    }
  }

  private var weekdayPicker: some View {
    HStack(spacing: 6) {
      ForEach(0..<7, id: \.self) { dow in
        let isOn = selectedWeekdays.contains(dow)
        Button(Self.weekdayNames[dow]) {
          if isOn, selectedWeekdays.count > 1 { selectedWeekdays.remove(dow) }
          else if !isOn { selectedWeekdays.insert(dow) }
          commit()
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .secondary)
        .font(.caption)
      }
    }
  }

  // MARK: - Build a CronExpression from the current controls

  private func commit() {
    guard isReady else { return }

    let expr: CronExpression
    switch unit {
    case .minute:
      expr = CronExpression(minute: "*/\(everyN)", hour: "*", dayOfMonth: "*", month: "*", dayOfWeek: "*")
    case .hour:
      expr = CronExpression(minute: "\(minuteOfHour)", hour: "*/\(everyN)", dayOfMonth: "*", month: "*", dayOfWeek: "*")
    case .day:
      let hours = selectedHours.sorted().map(String.init).joined(separator: ",")
      expr = CronExpression(minute: "\(sharedMinute)", hour: hours, dayOfMonth: "*", month: "*", dayOfWeek: "*")
    case .week:
      let hours = selectedHours.sorted().map(String.init).joined(separator: ",")
      let days  = selectedWeekdays.sorted().map(String.init).joined(separator: ",")
      expr = CronExpression(minute: "\(sharedMinute)", hour: hours, dayOfMonth: "*", month: "*", dayOfWeek: days)
    case .month:
      let cal = Calendar.current
      let hm  = cal.dateComponents([.hour, .minute], from: monthTimeOfDay)
      expr = CronExpression(minute: "\(hm.minute ?? 0)", hour: "\(hm.hour ?? 9)", dayOfMonth: "\(dayOfMonth)", month: "*", dayOfWeek: "*")
    }
    scheduler.setCronExpression(expr)
  }

  // MARK: - Best-effort reverse mapping when the view first appears

  /// Recognises the canonical shapes this builder itself produces. A hand-written
  /// expression from the Advanced field that doesn't match one of these shapes
  /// just falls back to a sensible default here — the raw expression underneath
  /// is unaffected either way, this only seeds the friendly controls.
  private func loadFromScheduler() {
    let e = scheduler.cronExpression
    let cal = Calendar.current

    func time(hour: Int, minute: Int) -> Date {
      cal.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    defer { isReady = true }

    if e.hour == "*", e.dayOfMonth == "*", e.month == "*", e.dayOfWeek == "*",
       e.minute.hasPrefix("*/"), let n = Int(e.minute.dropFirst(2)) {
      unit = .minute; everyN = n; return
    }
    if e.dayOfMonth == "*", e.month == "*", e.dayOfWeek == "*",
       e.hour.hasPrefix("*/"), let n = Int(e.hour.dropFirst(2)), let m = Int(e.minute) {
      unit = .hour; everyN = n; minuteOfHour = m; return
    }
    if e.dayOfMonth == "*", e.month == "*", e.dayOfWeek == "*",
       let m = Int(e.minute) {
      let hours = Set(e.hour.split(separator: ",").compactMap { Int($0) })
      if !hours.isEmpty {
        unit = .day; selectedHours = hours; sharedMinute = m; return
      }
    }
    if e.dayOfMonth == "*", e.month == "*", e.dayOfWeek != "*",
       let m = Int(e.minute) {
      let hours = Set(e.hour.split(separator: ",").compactMap { Int($0) })
      let days  = Set(e.dayOfWeek.split(separator: ",").compactMap { Int($0) })
      if !hours.isEmpty, !days.isEmpty {
        unit = .week; selectedHours = hours; selectedWeekdays = days; sharedMinute = m; return
      }
    }
    if e.month == "*", e.dayOfWeek == "*",
       let dom = Int(e.dayOfMonth), let h = Int(e.hour), let m = Int(e.minute) {
      unit = .month; dayOfMonth = dom; monthTimeOfDay = time(hour: h, minute: m); return
    }
    // Unrecognised custom expression — default to "every day at 9:00 AM" in the
    // friendly controls; Advanced still shows the real expression untouched.
    unit = .day
    selectedHours = [9]
    sharedMinute  = 0
  }
}
