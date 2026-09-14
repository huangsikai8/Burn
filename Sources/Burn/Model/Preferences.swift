import Foundation

enum MenuBarLabel: String, CaseIterable, Identifiable {
    case power = "Power draw"
    case cpu = "CPU"
    case memory = "Memory pressure"
    case iconOnly = "Icon only"

    var id: String { rawValue }
}

/// User-tunable thresholds for suggestions and alerts, stored in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    // Suggestions
    @Published var idleHours: Double { didSet { save("idleHours", idleHours) } }
    @Published var suggestMinimumMB: Double { didSet { save("suggestMinimumMB", suggestMinimumMB) } }
    @Published var ignoredApps: [String] { didSet { save("ignoredApps", ignoredApps) } }

    // Detectors
    @Published var runawayCPU: Double { didSet { save("runawayCPU", runawayCPU) } }
    @Published var runawayMinutes: Double { didSet { save("runawayMinutes", runawayMinutes) } }
    @Published var hiddenBusyCPU: Double { didSet { save("hiddenBusyCPU", hiddenBusyCPU) } }
    @Published var hiddenBusyMinutes: Double { didSet { save("hiddenBusyMinutes", hiddenBusyMinutes) } }
    @Published var leakMBPerHour: Double { didSet { save("leakMBPerHour", leakMBPerHour) } }

    // Notifications
    @Published var notifyRunaway: Bool { didSet { save("notifyRunaway", notifyRunaway) } }
    @Published var notifyPressure: Bool { didSet { save("notifyPressure", notifyPressure) } }
    @Published var notifyLeaks: Bool { didSet { save("notifyLeaks", notifyLeaks) } }

    // Menu bar and sampling
    @Published var menuBarLabel: MenuBarLabel { didSet { save("menuBarLabel", menuBarLabel.rawValue) } }
    @Published var fastInterval: Double { didSet { save("fastInterval", fastInterval) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        idleHours = double("idleHours", 2)
        suggestMinimumMB = double("suggestMinimumMB", 300)
        ignoredApps = defaults.stringArray(forKey: "ignoredApps") ?? []
        runawayCPU = double("runawayCPU", 90)
        runawayMinutes = double("runawayMinutes", 3)
        hiddenBusyCPU = double("hiddenBusyCPU", 3)
        hiddenBusyMinutes = double("hiddenBusyMinutes", 5)
        leakMBPerHour = double("leakMBPerHour", 250)
        notifyRunaway = bool("notifyRunaway", true)
        notifyPressure = bool("notifyPressure", true)
        notifyLeaks = bool("notifyLeaks", true)
        menuBarLabel = MenuBarLabel(rawValue: defaults.string(forKey: "menuBarLabel") ?? "") ?? .power
        fastInterval = double("fastInterval", 2)
    }

    func isIgnored(_ key: String) -> Bool { ignoredApps.contains(key) }

    func toggleIgnored(_ key: String) {
        if let index = ignoredApps.firstIndex(of: key) { ignoredApps.remove(at: index) } else { ignoredApps.append(key) }
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }
}
