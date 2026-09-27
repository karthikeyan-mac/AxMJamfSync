// UpdateChecker.swift
// Notify-and-link update check against the GitHub Releases API. Never downloads or
// installs anything — it only reports that a newer release exists and opens its
// release page in the browser.
//
// Preferences live under flat UserDefaults keys, deliberately NOT in AppPreferences:
// that class is namespaced per environment ("env.{uuid}."), and an update preference
// is global to the app.

import AppKit
import os

struct AvailableUpdate: Equatable, Sendable {
  let version: String
  let url:     URL
  let notes:   String
}

// MARK: - GitHub source (nonisolated — safe to call from any context)

private enum GitHubReleases {
  static let repo   = "karthikeyan-mac/AxMJamfSync"
  static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

  struct Release: Decodable, Sendable {
    let tagName: String
    let htmlUrl: String
    let body:    String?
  }

  enum FetchError: LocalizedError {
    case badResponse, noReleases, rateLimited, http(Int), unparseableTag(String), untrustedURL

    var errorDescription: String? {
      switch self {
      case .badResponse:          return "GitHub returned an unexpected response."
      case .noReleases:           return "No releases were found on GitHub."
      case .rateLimited:          return "GitHub is limiting requests from this network. Try again later."
      case .http(let code):       return "GitHub returned HTTP \(code)."
      case .unparseableTag(let t): return "Couldn't read the latest release version (\(t))."
      case .untrustedURL:         return "The latest release has an unexpected link, so it was ignored."
      }
    }
  }

  static func fetchLatest(installedVersion: String) async throws -> Release {
    var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("AxMJamfSync/\(installedVersion)", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
    switch http.statusCode {
    case 200:      break
    case 404:      throw FetchError.noReleases
    case 403, 429: throw FetchError.rateLimited
    default:       throw FetchError.http(http.statusCode)
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Release.self, from: data)
  }

  /// Only links into this repo's github.com pages are ever opened.
  static func isTrusted(_ url: URL) -> Bool {
    url.scheme == "https"
      && url.host == "github.com"
      && url.path.hasPrefix("/\(repo)/")
  }

  /// "v2.10" → [2, 10]. Non-numeric suffixes on a component ("6-beta") are ignored.
  static func components(of version: String) -> [Int]? {
    var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
    var result: [Int] = []
    for part in text.split(separator: ".", omittingEmptySubsequences: false) {
      guard let n = Int(part.prefix { $0 >= "0" && $0 <= "9" }) else { return nil }
      result.append(n)
    }
    return result.isEmpty ? nil : result
  }

  static func isNewer(_ candidate: [Int], than installed: [Int]) -> Bool {
    let count = max(candidate.count, installed.count)
    for i in 0..<count {
      let a = i < candidate.count ? candidate[i] : 0
      let b = i < installed.count ? installed[i] : 0
      if a != b { return a > b }
    }
    return false
  }
}

// MARK: - UpdateChecker

@MainActor
final class UpdateChecker: ObservableObject {

  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(AvailableUpdate)
  }

  private enum Key {
    static let autoCheck       = "updateAutoCheck"
    static let lastCheckEpoch  = "updateLastCheckEpoch"
    static let skippedVersion  = "updateSkippedVersion"
    static let latestVersion   = "updateLatestVersion"
    static let latestURL       = "updateLatestURL"
    static let latestNotes     = "updateLatestNotes"
  }

  private static let checkInterval: TimeInterval = 86_400
  private static let launchDelay: Duration = .seconds(5)
  private static let log = Logger(subsystem: "com.karthikmac.axmjamfsync", category: "UpdateChecker")

  @Published private(set) var state: State = .idle
  @Published private(set) var lastError: String?

  private let ud = UserDefaults.standard

  init() {
    restoreCachedUpdate()
    Task { [weak self] in
      try? await Task.sleep(for: Self.launchDelay)
      await self?.checkAutomaticallyIfDue()
    }
  }

  // MARK: Preferences

  var autoCheckEnabled: Bool {
    get { ud.object(forKey: Key.autoCheck) != nil ? ud.bool(forKey: Key.autoCheck) : true }
    set { ud.set(newValue, forKey: Key.autoCheck); objectWillChange.send() }
  }

  var lastChecked: Date? {
    let epoch = ud.double(forKey: Key.lastCheckEpoch)
    return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
  }

  private var skippedVersion: String {
    get { ud.string(forKey: Key.skippedVersion) ?? "" }
    set { ud.set(newValue, forKey: Key.skippedVersion); objectWillChange.send() }
  }

  // MARK: Derived state

  var installedVersion: String {
    #if DEBUG
    if let fake = ProcessInfo.processInfo.environment["AXM_FAKE_INSTALLED_VERSION"] { return fake }
    #endif
    return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  /// The available update, unless the user chose to skip that version — drives the menu bar row.
  var pendingUpdate: AvailableUpdate? {
    guard case .available(let update) = state, update.version != skippedVersion else { return nil }
    return update
  }

  var statusText: String {
    switch state {
    case .checking:
      return "Checking…"
    case .available(let update):
      return "Version \(update.version) is available."
    case .idle, .upToDate:
      if let lastError { return lastError }
      guard let lastChecked else { return "Not checked yet." }
      return "Last checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))."
    }
  }

  // MARK: Checking

  func checkAutomaticallyIfDue() async {
    guard autoCheckEnabled else { return }
    if let lastChecked, -lastChecked.timeIntervalSinceNow < Self.checkInterval { return }
    await check(userInitiated: false)
  }

  /// Automatic checks are silent on every outcome; only user-initiated ones show an alert.
  func check(userInitiated: Bool) async {
    guard state != .checking else { return }
    let previous = state
    state = .checking
    lastError = nil

    do {
      let release = try await GitHubReleases.fetchLatest(installedVersion: installedVersion)
      guard let latest = GitHubReleases.components(of: release.tagName) else {
        throw GitHubReleases.FetchError.unparseableTag(release.tagName)
      }
      guard let url = URL(string: release.htmlUrl), GitHubReleases.isTrusted(url) else {
        throw GitHubReleases.FetchError.untrustedURL
      }
      ud.set(Date().timeIntervalSince1970, forKey: Key.lastCheckEpoch)

      let installed = GitHubReleases.components(of: installedVersion) ?? [0]
      if GitHubReleases.isNewer(latest, than: installed) {
        let update = AvailableUpdate(version: latest.map(String.init).joined(separator: "."),
                                     url: url, notes: release.body ?? "")
        cache(update)
        state = .available(update)
        if userInitiated { presentAvailableAlert(update) }
      } else {
        clearCache()
        state = .upToDate
        if userInitiated { presentUpToDateAlert() }
      }
    } catch {
      Self.log.info("Update check failed: \(error.localizedDescription, privacy: .public)")
      state = previous
      if userInitiated {
        lastError = error.localizedDescription
        presentFailureAlert(error.localizedDescription)
      }
    }
  }

  // MARK: Cache (so a found update survives relaunch inside the 24 h throttle window)

  private func cache(_ update: AvailableUpdate) {
    ud.set(update.version,      forKey: Key.latestVersion)
    ud.set(update.url.absoluteString, forKey: Key.latestURL)
    ud.set(update.notes,        forKey: Key.latestNotes)
  }

  private func clearCache() {
    ud.removeObject(forKey: Key.latestVersion)
    ud.removeObject(forKey: Key.latestURL)
    ud.removeObject(forKey: Key.latestNotes)
  }

  /// Re-validates on restore: the installed version may have been upgraded since the cache was written.
  private func restoreCachedUpdate() {
    guard let version = ud.string(forKey: Key.latestVersion),
          let urlString = ud.string(forKey: Key.latestURL),
          let url = URL(string: urlString), GitHubReleases.isTrusted(url),
          let candidate = GitHubReleases.components(of: version),
          let installed = GitHubReleases.components(of: installedVersion),
          GitHubReleases.isNewer(candidate, than: installed)
    else { clearCache(); return }
    state = .available(AvailableUpdate(version: version, url: url,
                                       notes: ud.string(forKey: Key.latestNotes) ?? ""))
  }

  // MARK: Alerts

  private func presentAvailableAlert(_ update: AvailableUpdate) {
    let alert = NSAlert()
    alert.messageText = "AxM Jamf Sync \(update.version) is available"
    let notes = Self.excerpt(of: update.notes)
    alert.informativeText = "You have version \(installedVersion)."
      + (notes.isEmpty ? "" : "\n\n\(notes)")
    alert.addButton(withTitle: "View Release")
    alert.addButton(withTitle: "Skip This Version")
    alert.addButton(withTitle: "Later")
    NSApp.activate(ignoringOtherApps: true)
    switch alert.runModal() {
    case .alertFirstButtonReturn:  NSWorkspace.shared.open(update.url)
    case .alertSecondButtonReturn: skippedVersion = update.version
    default:                       break
    }
  }

  private func presentUpToDateAlert() {
    let alert = NSAlert()
    alert.messageText = "You're up to date"
    alert.informativeText = "AxM Jamf Sync \(installedVersion) is the latest version."
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private func presentFailureAlert(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Couldn't check for updates"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private static func excerpt(of notes: String, limit: Int = 600) -> String {
    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
  }
}
