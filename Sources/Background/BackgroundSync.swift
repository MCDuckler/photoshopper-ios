import Foundation
import BackgroundTasks
import Network

/// Two BG tasks: a short refresh (list + a few photos) every few hours, and a
/// long processing task that iOS runs on power + network.
enum BackgroundSync {
    static let refreshID = "dance.duckduck.p3k.refresh"
    static let syncID = "dance.duckduck.p3k.sync"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task, budget: 25)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: syncID, using: nil) { task in
            handle(task, budget: 20 * 60)
        }
    }

    static func schedule() {
        guard Settings.backgroundSync else {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            return
        }
        let r = BGAppRefreshTaskRequest(identifier: refreshID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(r)
        let p = BGProcessingTaskRequest(identifier: syncID)
        p.requiresNetworkConnectivity = true
        p.requiresExternalPower = true
        p.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(p)
    }

    private static func handle(_ task: BGTask, budget: TimeInterval) {
        schedule()
        let work = Task { @MainActor in
            let wifi = await onWiFi()
            if Settings.wifiOnly && !wifi { task.setTaskCompleted(success: true); return }
            await AppModel.shared.sync(reason: "background", deadline: Date(timeIntervalSinceNow: budget - 5))
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    static func onWiFi() async -> Bool {
        await withCheckedContinuation { cont in
            let m = NWPathMonitor()
            var resumed = false
            m.pathUpdateHandler = { path in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
                m.cancel()
            }
            m.start(queue: DispatchQueue(label: "p3k.path"))
        }
    }
}
