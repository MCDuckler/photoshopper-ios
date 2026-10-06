import SwiftUI
import Combine

enum Scope: Hashable {
    case all, phone
    case album(Int, String)
    case folder(String)

    var query: String {
        switch self {
        case .all: return ""
        case .phone: return "phone=true"
        case .album(let id, _): return "album_id=\(id)"
        case .folder(let p): return "folder=" + (p.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? p)
        }
    }
    var title: String {
        switch self {
        case .all: return "All photos"
        case .phone: return "On the phone"
        case .album(_, let n): return n
        case .folder(let p): return p.isEmpty ? "Pictures" : (p.split(separator: "/").last.map(String.init) ?? p)
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case newest = "capture_desc", oldest = "capture_asc", name = "filename"
    var id: String { rawValue }
    var label: String { self == .newest ? "Newest first" : self == .oldest ? "Oldest first" : "File name" }
}

enum RatingFilter: String, CaseIterable, Identifiable {
    case any = "Any", unrated = "Unrated", one = "★1+", two = "★2+", three = "★3+", four = "★4+", five = "★5", rejected = "Rejected"
    var id: String { rawValue }
    var query: String {
        switch self {
        case .any: return ""
        case .unrated: return "unrated=true"
        case .one: return "min_rating=1"
        case .two: return "min_rating=2"
        case .three: return "min_rating=3"
        case .four: return "min_rating=4"
        case .five: return "min_rating=5"
        case .rejected: return "only_rejected=true"
        }
    }
}

struct JCell: Identifiable { let item: PhotoItem; let w: CGFloat; var id: String { item.id } }
struct JRow: Identifiable { let id: String; let cells: [JCell]; let height: CGFloat }
struct JSection: Identifiable { let key: String; let rows: [JRow]; let count: Int; var id: String { key } }

@MainActor
final class LibraryModel: ObservableObject {
    @Published var scope: Scope = .all
    @Published var filter: RatingFilter = .any
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var loading = false
    @Published var folders: [Folder] = []
    @Published var phoneIDs: Set<String> = []
    @Published var selecting = false
    @Published var selected: Set<String> = []
    @Published var error: String?
    @Published var rowHeight: CGFloat = 120

    private var gen = 0
    private var layoutKey = ""
    private var layoutCache: [JSection] = []
    private var bag: Set<AnyCancellable> = []

    init() {
        Outbox.shared.changes.sink { [weak self] c in self?.apply(c) }.store(in: &bag)
    }

    private func apply(_ c: LocalChange) {
        switch c {
        case .rating(let ids, let r):
            let set = Set(ids)
            for i in items.indices where set.contains(items[i].id) { items[i].rating = r }
            layoutKey = ""
        case .edited(let id, let has, let at):
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].has_edit = has; items[i].edited_at = has ? at : nil }
            layoutKey = ""
        case .album(let albumID, let ids, let added):
            if !added, case .album(let open, _) = scope, open == albumID {
                let set = Set(ids)
                items.removeAll { set.contains($0.id) }
                layoutKey = ""
            }
        }
    }

    @Published var sort: SortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .newest {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "librarySort") }
    }

    var query: String { [scope.query, filter.query, "sort=" + sort.rawValue].filter { !$0.isEmpty }.joined(separator: "&") }

    func reload(_ api: API?) async {
        guard let api else { return }
        gen += 1
        let my = gen
        loading = true
        error = nil
        var all: [PhotoItem] = []
        var cursor: String? = nil
        defer { if my == gen { loading = false } }
        repeat {
            do {
                let page = try await api.photos(query: query, cursor: cursor)
                guard my == gen else { return }
                all.append(contentsOf: page.items)
                cursor = page.next_cursor
                items = all      // show the first page right away
            } catch {
                if my == gen { self.error = error.localizedDescription }
                return
            }
        } while cursor != nil
    }

    func loadMeta(_ api: API?) async {
        guard let api else { return }
        async let f = try? api.folders()
        async let p = try? api.phoneIDs()
        await AlbumStore.shared.load(api)
        if let v = await f { folders = v }
        if let v = await p { phoneIDs = v }
    }

    func update(_ item: PhotoItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item; layoutKey = "" }
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        if !selecting && !selected.isEmpty { selecting = true }
    }

    func endSelection() { selecting = false; selected.removeAll() }

    func addToPhone(_ ids: [String], variant: String, api: API?) async -> Bool {
        guard let api, !ids.isEmpty else { return false }
        do {
            try await api.addToPhone(ids, variant: variant)
            phoneIDs.formUnion(ids)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func removeFromPhone(_ ids: [String], api: API?) async -> Bool {
        guard let api, !ids.isEmpty else { return false }
        do {
            try await api.removeFromPhone(ids)
            phoneIDs.subtract(ids)
            if scope == .phone { items.removeAll { ids.contains($0.id) }; layoutKey = "" }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    // MARK: justified layout (same idea as the web app's shared/layout.js)

    func sections(width: CGFloat, gap: CGFloat) -> [JSection] {
        let key = "\(Int(width))|\(Int(rowHeight))|\(items.count)|\(items.first?.id ?? "")|\(items.last?.id ?? "")"
        if key == layoutKey { return layoutCache }
        var out: [JSection] = []
        var group: [PhotoItem] = []
        var current: String? = nil
        for it in items {
            if let c = current, it.monthKey != c {
                out.append(JSection(key: c, rows: Self.pack(group, width: width, targetH: rowHeight, gap: gap), count: group.count))
                group = []
            }
            current = it.monthKey
            group.append(it)
        }
        if let c = current, !group.isEmpty {
            out.append(JSection(key: c, rows: Self.pack(group, width: width, targetH: rowHeight, gap: gap), count: group.count))
        }
        layoutKey = key
        layoutCache = out
        return out
    }

    static func pack(_ items: [PhotoItem], width: CGFloat, targetH: CGFloat, gap: CGFloat) -> [JRow] {
        var rows: [JRow] = []
        var cur: [PhotoItem] = []
        var ar: CGFloat = 0
        func flush(last: Bool) {
            guard !cur.isEmpty else { return }
            let n = CGFloat(cur.count)
            var h = (width - (n - 1) * gap) / ar
            if last { h = min(h, targetH * 1.3) }
            let cells = cur.map { JCell(item: $0, w: floor($0.aspect * h)) }
            rows.append(JRow(id: cur[0].id, cells: cells, height: floor(h)))
            cur = []
            ar = 0
        }
        for it in items {
            cur.append(it)
            ar += it.aspect
            if ar * targetH + CGFloat(cur.count - 1) * gap >= width { flush(last: false) }
        }
        flush(last: true)
        return rows
    }

    static func monthTitle(_ key: String) -> String {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[1]), (1...12).contains(m) else { return "Undated" }
        return "\(DateFormatter().monthSymbols[m - 1]) \(parts[0])".uppercased()
    }
}
