import AppKit
import Combine
import UserNotifications

/// Posts notifications for the findings worth interrupting for: a runaway process,
/// memory turning critical, and a steady leak. Each fires once per episode.
@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private let monitor: Monitor
    private let preferences: Preferences
    private var cancellable: AnyCancellable?
    private var notifiedRunaways: [String: Date] = [:]
    private var notifiedLeaks: [String: Date] = [:]
    private var lastPressure: PressureLevel = .normal
    private var lastPressureNotice = Date.distantPast

    private static let runawayCategory = "RUNAWAY"
    private static let quitAction = "QUIT"
    private static let forceQuitAction = "FORCE_QUIT"
    private static let ignoreAction = "IGNORE"

    init(engine: InsightEngine, monitor: Monitor, preferences: Preferences) {
        self.monitor = monitor
        self.preferences = preferences
        super.init()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let quit = UNNotificationAction(identifier: Self.quitAction, title: "Quit")
        let force = UNNotificationAction(identifier: Self.forceQuitAction, title: "Force Quit…", options: [.destructive, .foreground])
        let ignore = UNNotificationAction(identifier: Self.ignoreAction, title: "Ignore This App")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.runawayCategory, actions: [quit, force, ignore], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        cancellable = engine.$insights.sink { [weak self] insights in
            self?.handle(insights)
        }
    }

    private func handle(_ insights: Insights) {
        let now = Date()

        if preferences.notifyRunaway {
            for runaway in insights.runaways {
                if let last = notifiedRunaways[runaway.id], now.timeIntervalSince(last) < 1800 { continue }
                notifiedRunaways[runaway.id] = now
                let process = runaway.processName == runaway.group.name ? "" : " (\(runaway.processName))"
                post(id: "runaway.\(runaway.id)",
                     title: "\(runaway.group.name) is stuck at \(Format.percent(runaway.cpu, digits: 0)) CPU",
                     body: "It has stayed above \(Format.percent(preferences.runawayCPU, digits: 0)) for \(Format.duration(runaway.minutes * 60))\(process). This drains the battery and heats the Mac.",
                     category: Self.runawayCategory,
                     info: ["key": runaway.group.historyKey, "pid": Int(runaway.pid ?? 0)])
            }
        }
        let active = Set(insights.runaways.map(\.id))
        notifiedRunaways = notifiedRunaways.filter { active.contains($0.key) || now.timeIntervalSince($0.value) < 1800 }

        let level = insights.pressure.level
        if preferences.notifyPressure, level == .critical, lastPressure != .critical, now.timeIntervalSince(lastPressureNotice) > 1800 {
            lastPressureNotice = now
            post(id: "pressure", title: insights.pressure.headline, body: insights.pressure.body, category: nil, info: [:])
        }
        lastPressure = level

        if preferences.notifyLeaks {
            for leak in insights.leaks {
                if let last = notifiedLeaks[leak.key], now.timeIntervalSince(last) < 6 * 3600 { continue }
                notifiedLeaks[leak.key] = now
                post(id: "leak.\(leak.key)",
                     title: "\(leak.name)’s memory keeps growing",
                     body: "Up \(Format.bytes(leak.bytesPerHour)) an hour for \(Format.duration(leak.hours * 3600)), now \(Format.bytes(leak.toBytes)). Quitting and reopening it will get the memory back.",
                     category: Self.runawayCategory,
                     info: ["key": leak.key, "pid": 0])
            }
        }
    }

    private func post(id: String, title: String, body: String, category: String?, info: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = info
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let key = response.notification.request.content.userInfo["key"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.perform(action, key: key) }
        }
        completionHandler()
    }

    private func perform(_ action: String, key: String?) {
        guard let key else { return }
        let group = monitor.snapshot.groups.first { $0.historyKey == key }
        switch action {
        case Self.quitAction:
            if let group { AppActions.quit(group) }
        case Self.forceQuitAction:
            if let group { AppActions.forceQuit(group) }
        case Self.ignoreAction:
            if !preferences.isIgnored(key) { preferences.toggleIgnored(key) }
        default:
            NSApp.activate()
        }
    }
}
