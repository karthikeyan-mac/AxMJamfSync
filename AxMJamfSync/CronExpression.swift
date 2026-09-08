// CronExpression.swift
// Standard 5-field POSIX cron parsing (minute hour day-of-month month day-of-week)
// plus next-fire-date computation. No external dependency — small surface area,
// so a hand-rolled parser is simpler than pulling in a package.
//
// Field syntax supported per position: "*", "*/N", "A", "A-B", "A-B/N", "A,B,C"
// (and any comma-combination of the above). Day-of-week is 0-6, Sunday = 0,
// matching standard cron — 7 is also accepted as Sunday.

import Foundation

struct CronExpression: Equatable {
  var minute:     String
  var hour:       String
  var dayOfMonth: String
  var month:      String
  var dayOfWeek:  String

  static let dailyAt9AM = CronExpression(minute: "0", hour: "9", dayOfMonth: "*", month: "*", dayOfWeek: "*")

  var rawValue: String {
    [minute, hour, dayOfMonth, month, dayOfWeek].joined(separator: " ")
  }

  init(minute: String, hour: String, dayOfMonth: String, month: String, dayOfWeek: String) {
    self.minute = minute; self.hour = hour; self.dayOfMonth = dayOfMonth
    self.month = month; self.dayOfWeek = dayOfWeek
  }

  /// Parses a 5-field cron string. Returns nil if the field count or any field is malformed.
  init?(parsing text: String) {
    let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard fields.count == 5 else { return nil }
    let ranges: [ClosedRange<Int>] = [0...59, 0...23, 1...31, 1...12, 0...7]
    for (field, range) in zip(fields, ranges) {
      guard CronExpression.isValidField(field, range: range) else { return nil }
    }
    self.init(minute: fields[0], hour: fields[1], dayOfMonth: fields[2], month: fields[3], dayOfWeek: fields[4])
  }

  // MARK: - Field validation

  private static func isValidField(_ field: String, range: ClosedRange<Int>) -> Bool {
    for part in field.split(separator: ",") {
      guard isValidFieldPart(String(part), range: range) else { return false }
    }
    return true
  }

  private static func isValidFieldPart(_ part: String, range: ClosedRange<Int>) -> Bool {
    let stepSplit = part.split(separator: "/", maxSplits: 1)
    guard !stepSplit.isEmpty else { return false }
    let base = String(stepSplit[0])
    if stepSplit.count == 2 {
      guard let step = Int(stepSplit[1]), step > 0 else { return false }
    }
    if base == "*" { return true }
    if base.contains("-") {
      let bounds = base.split(separator: "-")
      guard bounds.count == 2,
            let lo = Int(bounds[0]), let hi = Int(bounds[1]),
            range.contains(lo), range.contains(hi), lo <= hi
      else { return false }
      return true
    }
    guard let value = Int(base), range.contains(value) else { return false }
    return true
  }

  // MARK: - Field expansion

  /// Expands a field into the concrete set of matching values within range.
  private func expand(_ field: String, range: ClosedRange<Int>) -> Set<Int> {
    var result = Set<Int>()
    for part in field.split(separator: ",") {
      let stepSplit = part.split(separator: "/", maxSplits: 1)
      let base = String(stepSplit[0])
      let step = stepSplit.count == 2 ? (Int(stepSplit[1]) ?? 1) : 1

      let baseValues: [Int]
      if base == "*" {
        baseValues = Array(range)
      } else if base.contains("-") {
        let bounds = base.split(separator: "-")
        guard bounds.count == 2, let lo = Int(bounds[0]), let hi = Int(bounds[1]) else { continue }
        baseValues = Array(lo...hi)
      } else if let value = Int(base) {
        baseValues = [value]
      } else {
        baseValues = []
      }

      let start = baseValues.first ?? range.lowerBound
      for v in baseValues where (v - start) % step == 0 {
        result.insert(v)
      }
    }
    // Cron treats 7 as Sunday in the day-of-week field — fold into 0.
    if range == 0...7, result.contains(7) {
      result.remove(7); result.insert(0)
    }
    return result
  }

  // MARK: - Next fire date

  /// Finds the next Date strictly after `now` that satisfies this expression.
  /// Searches minute-by-minute up to two years out — generous enough for any
  /// realistic schedule (e.g. "Feb 29 only") without risking an infinite loop.
  func nextFireDate(after now: Date, calendar: Calendar = .current) -> Date? {
    let minutes  = expand(minute,     range: 0...59)
    let hours    = expand(hour,       range: 0...23)
    let domSet   = expand(dayOfMonth, range: 1...31)
    let months   = expand(month,      range: 1...12)
    let dowSet   = expand(dayOfWeek,  range: 0...7)
    guard !minutes.isEmpty, !hours.isEmpty, !domSet.isEmpty, !months.isEmpty, !dowSet.isEmpty else { return nil }

    // Cron semantics: if BOTH day-of-month and day-of-week are restricted (not "*"),
    // a date matches if it satisfies EITHER field. If only one is restricted, that
    // field alone governs.
    let domIsWildcard = dayOfMonth.trimmingCharacters(in: .whitespaces) == "*"
    let dowIsWildcard = dayOfWeek.trimmingCharacters(in: .whitespaces) == "*"

    var candidate = calendar.date(byAdding: .minute, value: 1, to: now) ?? now
    candidate = calendar.date(bySetting: .second, value: 0, of: candidate) ?? candidate

    let maxIterations = 60 * 24 * 366 * 2 // two years of minutes
    var i = 0
    while i < maxIterations {
      defer { i += 1 }
      let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
      guard let min = c.minute, let hr = c.hour, let day = c.day, let mo = c.month, let weekday = c.weekday else { return nil }
      let dow = weekday - 1 // Calendar.weekday is 1-based (Sunday = 1) — cron is 0-based

      guard months.contains(mo) else {
        candidate = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: DateComponents(
          year: c.year, month: mo, day: 1, hour: 0, minute: 0
        )) ?? candidate) ?? candidate
        continue
      }

      let dayMatches = domIsWildcard != dowIsWildcard
        ? (domIsWildcard ? dowSet.contains(dow) : domSet.contains(day))
        : (domSet.contains(day) || dowSet.contains(dow))

      guard dayMatches else {
        candidate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) ?? candidate
        continue
      }
      guard hours.contains(hr) else {
        if let nextHourToday = hours.sorted().first(where: { $0 > hr }) {
          candidate = calendar.date(bySettingHour: nextHourToday, minute: 0, second: 0, of: candidate) ?? candidate
        } else {
          let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) ?? candidate
          candidate = calendar.date(bySettingHour: hours.sorted().first ?? 0, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
        continue
      }
      guard minutes.contains(min) else {
        candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate
        continue
      }
      return candidate
    }
    return nil
  }

  // MARK: - Human-readable summary (best-effort, for the Settings UI)

  /// A plain-English approximation shown beneath the cron field — not exhaustive,
  /// falls back to echoing the raw expression for anything non-trivial.
  var humanSummary: String {
    let isWildMinute = minute == "*"
    let isWildHour   = hour == "*"
    let isWildDom    = dayOfMonth == "*"
    let isWildMonth  = month == "*"
    let isWildDow    = dayOfWeek == "*"

    if isWildMinute, isWildHour, isWildDom, isWildMonth, isWildDow {
      return "Every minute"
    }
    if minute.hasPrefix("*/"), isWildHour, isWildDom, isWildMonth, isWildDow, let step = Int(minute.dropFirst(2)) {
      return "Every \(step) minute\(step == 1 ? "" : "s")"
    }
    if let m = Int(minute), hour.hasPrefix("*/"), isWildDom, isWildMonth, isWildDow, let step = Int(hour.dropFirst(2)) {
      return "Every \(step) hour\(step == 1 ? "" : "s"), at minute \(m)"
    }
    if let m = Int(minute), isWildDom, isWildMonth, let hours = Self.intList(hour), !hours.isEmpty {
      let times = hours.sorted().map { Self.timeString(hour: $0, minute: m) }.joined(separator: ", ")
      if isWildDow {
        return "Every day at \(times)"
      }
      if let days = Self.intList(dayOfWeek), !days.isEmpty {
        let names = days.sorted().map(Self.weekdayName).joined(separator: ", ")
        return "\(names) at \(times)"
      }
    }
    if let m = Int(minute), let h = Int(hour), let dom = Int(dayOfMonth), isWildMonth, isWildDow {
      return "Day \(dom) of the month at \(Self.timeString(hour: h, minute: m))"
    }
    return rawValue
  }

  private static func intList(_ field: String) -> [Int]? {
    let values = field.split(separator: ",").compactMap { Int($0) }
    return values.isEmpty ? nil : values
  }

  private static func timeString(hour: Int, minute: Int) -> String {
    var c = DateComponents(); c.hour = hour; c.minute = minute
    let date = Calendar.current.date(from: c) ?? Date()
    let f = DateFormatter(); f.timeStyle = .short
    return f.string(from: date)
  }

  private static func weekdayName(_ dow: Int) -> String {
    let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    return names.indices.contains(dow) ? names[dow] : "?"
  }
}
