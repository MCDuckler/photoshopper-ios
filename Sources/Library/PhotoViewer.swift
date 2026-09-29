import SwiftUI

/// One photo on the wall: swipe to browse, rate, toggle "on the phone".
struct PhotoViewer: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var lib: LibraryModel
    @State var index: Int
    let flash: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drag: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var busy = false

    private var item: PhotoItem? { lib.items.indices.contains(index) ? lib.items[index] : nil }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if let item {
                VStack(spacing: 0) {
                    header(item)
                    Spacer(minLength: 8)
                    RemoteImage(request: app.api?.preview(item), fill: false)
                        .background(Color.white)
                        .padding(10)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
                        .aspectRatio(item.aspect, contentMode: .fit)
                        .scaleEffect(zoom)
                        .offset(x: drag.width, y: max(0, drag.height))
                        .padding(.horizontal, 16)
                        .gesture(swipe)
                        .simultaneousGesture(MagnificationGesture().onChanged { zoom = max(1, min(4, $0)) }.onEnded { _ in withAnimation { zoom = 1 } })
                        .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2.5 } }
                    Spacer(minLength: 8)
                    footer(item)
                }
                .onAppear { prefetch() }
                .onChange(of: index) { _, _ in prefetch() }
            }
        }
    }

    private func header(_ p: PhotoItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text((p.filename ?? "").uppercased()).font(.custom("Helvetica Neue", size: 12).weight(.bold)).tracking(1.2)
                Text([p.captureDate?.formatted(date: .abbreviated, time: .shortened), p.camera, "\(index + 1) / \(lib.items.count)"].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.custom("Helvetica Neue", size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Close") { dismiss() }.font(.custom("Helvetica Neue", size: 13).weight(.medium))
        }
        .padding(.horizontal, 20).padding(.top, 12)
    }

    private func footer(_ p: PhotoItem) -> some View {
        let onPhone = lib.phoneIDs.contains(p.id)
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { rate(p, p.rating == -1 ? 0 : -1) } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.rating == -1 ? Theme.red : .secondary)
                }
                ForEach(1...5, id: \.self) { n in
                    Button { rate(p, p.rating == n ? 0 : n) } label: {
                        Image(systemName: p.rating >= n ? "star.fill" : "star").font(.system(size: 19)).foregroundStyle(p.rating >= n ? Theme.red : .secondary)
                    }
                }
            }
            Button { Task { await togglePhone(p, onPhone) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: onPhone ? "checkmark" : "iphone.and.arrow.forward")
                    Text(onPhone ? "ON THE PHONE — TAP TO REMOVE" : "SYNC TO PHONE")
                        .font(.custom("Helvetica Neue", size: 12).weight(.bold)).tracking(1.2)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .foregroundStyle(onPhone ? Theme.red : .white)
                .background(onPhone ? Color.clear : Theme.red)
                .overlay(Rectangle().stroke(Theme.red, lineWidth: 1))
            }
            .disabled(busy)
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in if zoom == 1 { drag = v.translation } }
            .onEnded { v in
                defer { withAnimation(.spring(response: 0.25)) { drag = .zero } }
                guard zoom == 1 else { return }
                if v.translation.height > 140 && abs(v.translation.width) < 80 { dismiss(); return }
                if v.translation.width < -70, index < lib.items.count - 1 { index += 1 }
                else if v.translation.width > 70, index > 0 { index -= 1 }
            }
    }

    private func prefetch() {
        guard let api = app.api else { return }
        for j in [index + 1, index - 1, index + 2] where lib.items.indices.contains(j) {
            ImageLoader.shared.prefetch(api.preview(lib.items[j]))
        }
    }

    private func rate(_ p: PhotoItem, _ r: Int) {
        var copy = p
        copy.rating = r
        lib.update(copy)
        UISelectionFeedbackGenerator().selectionChanged()
        Task { do { try await app.api?.rate(p.id, r) } catch { flash("Rating failed: \(error.localizedDescription)") } }
    }

    private func togglePhone(_ p: PhotoItem, _ onPhone: Bool) async {
        busy = true
        defer { busy = false }
        let ok = onPhone ? await lib.removeFromPhone([p.id], api: app.api) : await lib.addToPhone([p.id], variant: "full", api: app.api)
        if ok {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task { await app.sync(reason: "manual") }
        }
    }
}
