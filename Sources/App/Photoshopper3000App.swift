import SwiftUI
import BackgroundTasks

@main
struct Photoshopper3000App: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    init() {
        BackgroundSync.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.red)
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .active:
                Task { await model.syncIfDue(reason: "open") }
            case .background:
                BackgroundSync.schedule()
            default:
                break
            }
        }
    }
}
