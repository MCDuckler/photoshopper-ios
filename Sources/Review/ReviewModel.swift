import SwiftUI
import Combine

enum SwipeDir { case right, left, up }

/// The review deck: one photo at a time over the same scope + filter the library
/// uses. Ratings go through the outbox, so swiping never waits on the network.
@MainActor
final class ReviewModel: ObservableObject {
    @Published var scope: Scope = .all
    @Published var filter: RatingFilter = .unrated
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var idx = 0
    @Published private(set) var complete = false      // every page is in
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var reviewed = 0
    @Published private(set) var streak = 0

    struct Step { let idx: Int; let prev: Int; let changed: Bool; let dir: SwipeDir }
    private(set) var history: [Step] = []
    private var gen = 0
    private var bag: Set<AnyCancellable> = []

    init() {
        Outbox.shared.changes.sink { [weak self] c in self?.apply(c) }.store(in: &bag)
    }

    var current: PhotoItem? { items.indices.contains(idx) ? items[idx] : nil }
    func item(_ i: Int) -> PhotoItem? { items.indices.contains(i) ? items[i] : nil }
    var finished: Bool { complete && idx >= items.count && !items.isEmpty }
    var canUndo: Bool { !history.isEmpty }

    var query: String { [scope.query, filter.query].filter { !$0.isEmpty }.joined(separator: "&") }

    func reload(_ api: API?) async {
        guard let api else { error = "Not connected"; return }
        gen += 1
        let my = gen
        items = []; idx = 0; history = []; reviewed = 0; streak = 0; complete = false; error = nil
        loading = true
        defer { if my == gen { loading = false } }
        var seen = Set<String>()
        var cursor: String?
        repeat {
            do {
                let page = try await api.photos(query: query, cursor: cursor)
                guard my == gen else { return }
                let fresh = page.items.filter { seen.insert($0.id).inserted }
                items.append(contentsOf: fresh)
                cursor = page.next_cursor
            } catch {
                if my == gen { self.error = error.localizedDescription }
                return
            }
        } while cursor != nil
        complete = true
    }

    /// Rate (or leave as is, for skip) and move on.
    func commit(_ rating: Int?, dir: SwipeDir) {
        guard let p = current else { return }
        let changed = rating != nil && rating != p.rating
        history.append(Step(idx: idx, prev: p.rating, changed: changed, dir: dir))
        if let rating, changed { Outbox.shared.rate([p.id], rating) }
        reviewed += 1
        streak = (rating ?? 0) > 0 ? streak + 1 : 0
        idx += 1
    }

    /// Steps back one card and restores its rating. Returns the step for the animation.
    func undo() -> Step? {
        guard let s = history.popLast() else { return nil }
        idx = s.idx
        reviewed = max(0, reviewed - 1)
        streak = 0
        if s.changed, let p = item(s.idx) { Outbox.shared.rate([p.id], s.prev) }
        return s
    }

    func restart() { idx = 0; reviewed = 0; streak = 0; history = [] }

    private func apply(_ c: LocalChange) {
        switch c {
        case .rating(let ids, let r):
            let set = Set(ids)
            for i in items.indices where set.contains(items[i].id) { items[i].rating = r }
        case .edited(let id, let has, let at):
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].has_edit = has; items[i].edited_at = has ? at : nil }
        case .album:
            break
        }
    }
}
