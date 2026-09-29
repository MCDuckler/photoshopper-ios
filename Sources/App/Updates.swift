import Foundation
import UIKit

/// What GitHub has, and whether it is newer than what is running.
///
/// Same idea as WetOwl's update row: iOS cannot install anything itself, and the app
/// is signed on the phone by SideStore, which is a different app. So this notices a
/// newer build, says so, and hands the ipa link to SideStore (AltStore, then Safari as
/// fallbacks). The repo is public, so GitHub Pages is reachable from anywhere — no
/// server of our own is involved, unlike the LAN-only Photoshopper server.
struct Release: Decodable, Equatable {
    let version: String
    let build: String
    let bytes: Int
    let built: String?
    let url: String
    let notes: String?

    /// Build stamps are UTC `YYYYMMDDHHMM`: in order by construction.
    func isNewer(than mine: String) -> Bool {
        guard let theirs = Int(build) else { return false }
        guard let ours = Int(mine) else { return true }   // an unstamped build predates all of this
        return theirs > ours
    }
    var size: String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    var builtDate: Date? { built.flatMap { ISO8601DateFormatter().date(from: $0) } }
}

enum Updates {
    static let pages = "https://mcduckler.github.io/photoshopper-ios"
    static let sourceURL = "\(pages)/apps.json"
    static let manifestURL = "\(pages)/latest.json"

    static var running: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    static var runningVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    static func latest() async -> Release? {
        // Cache-busting: Pages sends max-age=600, and "check now" should mean now.
        guard let u = URL(string: manifestURL + "?t=\(Int(Date().timeIntervalSince1970))") else { return nil }
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Release.self, from: d)
    }

    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

    /// Hand the ipa to whichever sideloader is installed; there is no way to ask which,
    /// and a scheme nothing handles simply does not open.
    @MainActor
    static func install(_ release: Release) async -> Bool {
        let targets = ["sidestore://install?url=\(enc(release.url))", "altstore://install?url=\(enc(release.url))", release.url]
        for t in targets {
            guard let u = URL(string: t) else { continue }
            if await UIApplication.shared.open(u) { return true }
        }
        return false
    }

    /// Adding the source once turns every later build into a normal SideStore update.
    @MainActor
    static func addSource() async -> Bool {
        for t in ["sidestore://source?url=\(enc(sourceURL))", "altstore://source?url=\(enc(sourceURL))", pages] {
            guard let u = URL(string: t) else { continue }
            if await UIApplication.shared.open(u) { return true }
        }
        return false
    }
}
