import Foundation
import Network

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
}

/// Finds Photoshopper servers advertising `_photoedit._tcp` (see server/app/mdns.py).
final class Discovery {
    private var browser: NWBrowser?
    private let onChange: ([DiscoveredServer]) -> Void
    private var found: [String: DiscoveredServer] = [:]
    private let queue = DispatchQueue(label: "p3k.discovery")

    init(onChange: @escaping ([DiscoveredServer]) -> Void) { self.onChange = onChange }

    func start() {
        let b = NWBrowser(for: .bonjour(type: "_photoedit._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                self.resolve(r.endpoint, name: name)
            }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }

    /// Resolve the service to host:port by opening (and immediately closing) a connection.
    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let params = NWParameters.tcp
        params.preferNoProxies = true
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let path = conn.currentPath, case let .hostPort(host, port) = path.remoteEndpoint {
                var h = "\(host)"
                if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                if h.contains(":") { h = "[\(h)]" }
                let s = DiscoveredServer(id: name, name: name, url: "http://\(h):\(port.rawValue)")
                self.found[name] = s
                self.onChange(Array(self.found.values).sorted { $0.name < $1.name })
                conn.cancel()
            } else if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: queue)
    }
}
