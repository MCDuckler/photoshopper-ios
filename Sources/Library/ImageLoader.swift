import UIKit
import SwiftUI

/// Memory cache of decoded images over a large on-disk URLCache.
final class ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: c)
    }

    func cached(_ r: URLRequest) -> UIImage? {
        guard let k = r.url?.absoluteString else { return nil }
        return memory.object(forKey: k as NSString)
    }

    func image(_ r: URLRequest) async -> UIImage? {
        guard let k = r.url?.absoluteString else { return nil }
        if let i = memory.object(forKey: k as NSString) { return i }
        guard let (d, resp) = try? await session.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300,
              let img = UIImage(data: d) else { return nil }
        let ready = await img.byPreparingForDisplay() ?? img
        memory.setObject(ready, forKey: k as NSString, cost: d.count * 4)
        return ready
    }

    func prefetch(_ r: URLRequest) { Task.detached(priority: .utility) { _ = await self.image(r) } }
}

struct RemoteImage: View {
    let request: URLRequest?
    var fill = true
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let img {
                Image(uiImage: img).resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: request?.url) {
            guard let request else { return }
            if let c = ImageLoader.shared.cached(request) { img = c; return }
            img = nil
            let loaded = await ImageLoader.shared.image(request)
            withAnimation(.easeOut(duration: 0.15)) { img = loaded }
        }
    }
}
