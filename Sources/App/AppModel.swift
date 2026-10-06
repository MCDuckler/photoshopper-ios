import Foundation
import SwiftUI

/// App-wide state: connection, sync status, log. One instance.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var serverURL: String = Settings.serverURL
    @Published var token: String = Settings.token
    @Published var connected: Bool = false
    @Published var serverName: String = ""
    @Published var discovered: [DiscoveredServer] = []

    @Published var running: Bool = false
    @Published var progress: Double = 0
    @Published var status: String = "Not synced yet"
    @Published var counts = SyncCounts()
    @Published var lastSync: Date? = Settings.lastSync
    @Published var log: [LogLine] = LogStore.load()

    @Published var tab: AppTab = .library
    @Published var reviewRequest: ReviewRequest?

    /// Library → Review with the library's scope and filter.
    func startReview(scope: Scope, filter: RatingFilter) {
        reviewRequest = ReviewRequest(scope: scope, filter: filter)
        tab = .review
    }

    @Published var update: Release?
    @Published var checkingUpdate = false
    @Published var lastUpdateCheck: Date?
    @Published var dismissedBuild: String? = UserDefaults.standard.string(forKey: "dismissedBuild")

    /// Quiet check: on launch and when coming back, at most every 6 h unless forced.
    func checkForUpdate(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        checkingUpdate = true
        defer { checkingUpdate = false }
        let r = await Updates.latest()
        lastUpdateCheck = Date()
        if let r { update = r }
    }

    var updateAvailable: Bool { update?.isNewer(than: Updates.running) ?? false }
    var showUpdateBanner: Bool { updateAvailable && dismissedBuild != update?.build }

    func dismissUpdate() {
        dismissedBuild = update?.build
        UserDefaults.standard.set(dismissedBuild, forKey: "dismissedBuild")
    }

    private var discovery: Discovery?

    var api: API? {
        guard let url = URL(string: serverURL), !serverURL.isEmpty else { return nil }
        return API(base: url, token: token.isEmpty ? nil : token)
    }

    func startDiscovery() {
        discovery = Discovery { [weak self] found in
            Task { @MainActor in self?.discovered = found }
        }
        discovery?.start()
    }

    func stopDiscovery() { discovery?.stop(); discovery = nil }

    func connect(url: String, token: String? = nil) async -> Bool {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.hasPrefix("http") { u = "http://" + u }
        while u.hasSuffix("/") { u.removeLast() }
        serverURL = u
        if let token { self.token = token }
        guard let api else { return false }
        do {
            let h = try await api.health()
            connected = true
            serverName = h.service
            Settings.serverURL = u
            Settings.token = self.token
            append(.info, "Connected to \(u)")
            return true
        } catch {
            connected = false
            append(.error, "Could not reach \(u): \(error.localizedDescription)")
            return false
        }
    }

    /// `photoedit://pair?url=…&token=…` or a plain server URL, as the QR shows it.
    func connect(qr: String) async -> Bool {
        guard let comps = URLComponents(string: qr) else { return false }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let url = q["url"], !url.isEmpty { return await connect(url: url, token: q["token"]) }
        if let scheme = comps.scheme, scheme.hasPrefix("http"), let host = comps.host {
            let port = comps.port.map { ":\($0)" } ?? ""
            return await connect(url: "\(scheme)://\(host)\(port)", token: q["token"])
        }
        return false
    }

    func syncIfDue(reason: String) async {
        guard !running else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < 60, reason != "manual" { return }
        await sync(reason: reason)
    }

    func sync(reason: String, deadline: Date? = nil) async {
        guard !running, let api else { return }
        running = true
        progress = 0
        defer { running = false }
        let engine = SyncEngine(api: api, store: SyncStore.shared, writer: PhotosWriter())
        let result = await engine.run(deadline: deadline) { [weak self] p, text in
            Task { @MainActor in
                self?.progress = p
                self?.status = text
            }
        }
        counts = result.counts
        connected = result.reachedServer
        for line in result.log { append(line.level, line.text) }
        if result.reachedServer {
            lastSync = Date()
            Settings.lastSync = lastSync
        }
        status = result.summary
    }

    func append(_ level: LogLine.Level, _ text: String) {
        log.insert(LogLine(date: Date(), level: level, text: text), at: 0)
        if log.count > 400 { log.removeLast(log.count - 400) }
        LogStore.save(log)
    }
}

enum AppTab: Hashable { case library, review, sync, settings }

struct ReviewRequest: Equatable {
    let scope: Scope
    let filter: RatingFilter
    let n = UUID()
}

struct SyncCounts: Codable, Equatable {
    var selected = 0
    var inPhotos = 0
    var pending = 0
    var failed = 0
}

struct LogLine: Codable, Identifiable, Equatable {
    enum Level: String, Codable { case info, added, replaced, removed, error }
    var id = UUID()
    var date: Date
    var level: Level
    var text: String
}

enum LogStore {
    private static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("log.json") }
    static func load() -> [LogLine] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LogLine].self, from: d)) ?? []
    }
    static func save(_ lines: [LogLine]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(lines).write(to: url, options: .atomic)
    }
}

enum Settings {
    private static let d = UserDefaults.standard
    static var serverURL: String {
        get { d.string(forKey: "serverURL") ?? "" }
        set { d.set(newValue, forKey: "serverURL") }
    }
    static var token: String {
        get { d.string(forKey: "token") ?? "" }
        set { d.set(newValue, forKey: "token") }
    }
    static var lastSync: Date? {
        get { d.object(forKey: "lastSync") as? Date }
        set { d.set(newValue, forKey: "lastSync") }
    }
    static var backgroundSync: Bool {
        get { d.object(forKey: "backgroundSync") as? Bool ?? true }
        set { d.set(newValue, forKey: "backgroundSync") }
    }
    static var wifiOnly: Bool {
        get { d.object(forKey: "wifiOnly") as? Bool ?? true }
        set { d.set(newValue, forKey: "wifiOnly") }
    }
    static var albumName: String {
        get { d.string(forKey: "albumName") ?? "Photoshopper" }
        set { d.set(newValue, forKey: "albumName") }
    }
}
