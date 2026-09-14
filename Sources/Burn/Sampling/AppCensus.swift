import AppKit
import CoreGraphics

struct RunningAppInfo {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let bundlePath: String?
    let policy: NSApplication.ActivationPolicy
    let isHidden: Bool
    let isActive: Bool
    let launchDate: Date?
}

/// What the workspace knows about apps, captured on the main thread for the sampler.
struct Census {
    var apps: [pid_t: RunningAppInfo] = [:]
    var lastActive: [String: Date] = [:]
    var hiddenSince: [String: Date] = [:]
    var trackingSince = Date()
}

private struct StaticAppInfo {
    let name: String
    let bundleID: String?
    let bundlePath: String?
    let launchDate: Date?
}

struct WindowCount {
    var total = 0
    var onscreen = 0
}

/// Remembers when each app was last frontmost and when it was hidden.
///
/// Both are persisted so a relaunch of Burn — every rebuild is one — doesn't reset
/// every app to "unknown". Keys are bundle ids, which survive the app relaunching;
/// a hidden-since entry also records the app's launch date so it's discarded once
/// the app itself has been relaunched.
@MainActor
final class ActivityTracker {
    private(set) var lastActive: [String: Date] = [:]
    private var hidden: [String: (since: Date, launch: Date?)] = [:]
    let trackingSince: Date
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var staticInfo: [pid_t: StaticAppInfo] = [:]

    private static let activeKey = "activity.lastActive"
    private static let hiddenKey = "activity.hiddenSince"
    private static let trackingKey = "activity.trackingSince"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.trackingKey) as? Date {
            trackingSince = stored
        } else {
            trackingSince = Date()
            defaults.set(trackingSince, forKey: Self.trackingKey)
        }
        if let stored = defaults.dictionary(forKey: Self.activeKey) as? [String: Date] {
            lastActive = stored
        }
        if let stored = defaults.dictionary(forKey: Self.hiddenKey) as? [String: [String: Date]] {
            for (key, value) in stored {
                if let since = value["since"] { hidden[key] = (since, value["launch"]) }
            }
        }
        reconcile()
        observe()
    }

    static func key(for app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? app.executableURL?.path ?? "pid:\(app.processIdentifier)"
    }

    func census() -> Census {
        var census = Census(lastActive: lastActive, trackingSince: trackingSince)
        var live = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            live.insert(pid)
            // Name, bundle and launch date never change for a pid, and localizedName
            // goes through LaunchServices, so they're read once. Only state is re-read.
            let fixed = staticInfo[pid] ?? {
                let info = StaticAppInfo(
                    name: app.localizedName ?? app.executableURL?.lastPathComponent ?? "Unknown",
                    bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path, launchDate: app.launchDate)
                staticInfo[pid] = info
                return info
            }()
            census.apps[pid] = RunningAppInfo(
                pid: pid, name: fixed.name, bundleID: fixed.bundleID, bundlePath: fixed.bundlePath,
                policy: app.activationPolicy, isHidden: app.isHidden, isActive: app.isActive, launchDate: fixed.launchDate)
        }
        if staticInfo.count > live.count { staticInfo = staticInfo.filter { live.contains($0.key) } }
        census.lastActive = lastActive
        census.hiddenSince = hidden.mapValues(\.since)
        return census
    }

    /// Brings the stored state in line with what is running right now.
    private func reconcile() {
        let now = Date()
        var stillHidden: [String: (since: Date, launch: Date?)] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let key = Self.key(for: app)
            if app.isActive { lastActive[key] = now }
            guard app.isHidden else { continue }
            if let known = hidden[key], known.launch == app.launchDate {
                stillHidden[key] = known
            } else {
                // Hidden before we were watching: the best lower bound is now.
                stillHidden[key] = (now, app.launchDate)
            }
        }
        hidden = stillHidden
        save()
    }

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        func app(_ note: Notification) -> NSRunningApplication? {
            note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = app(note) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                // The app losing focus was in use right up to now.
                for other in NSWorkspace.shared.runningApplications where other.isActive == false {
                    let key = Self.key(for: other)
                    if let last = self.lastActive[key], now.timeIntervalSince(last) < 1 { self.lastActive[key] = now }
                }
                self.lastActive[Self.key(for: running)] = now
                self.save()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = app(note) else { return }
            MainActor.assumeIsolated {
                self?.lastActive[Self.key(for: running)] = Date()
                self?.save()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = app(note) else { return }
            MainActor.assumeIsolated {
                self?.hidden[Self.key(for: running)] = (Date(), running.launchDate)
                self?.save()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = app(note) else { return }
            MainActor.assumeIsolated {
                self?.hidden[Self.key(for: running)] = nil
                self?.save()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = app(note) else { return }
            MainActor.assumeIsolated {
                self?.hidden[Self.key(for: running)] = nil
                self?.save()
            }
        })
    }

    private func save() {
        defaults.set(lastActive, forKey: Self.activeKey)
        var stored: [String: [String: Date]] = [:]
        for (key, value) in hidden {
            var entry = ["since": value.since]
            if let launch = value.launch { entry["launch"] = launch }
            stored[key] = entry
        }
        defaults.set(stored, forKey: Self.hiddenKey)
    }
}

enum WindowCensus {
    /// Real windows per owning pid. Hidden (⌘H) and minimised windows count toward
    /// `total` but not `onscreen`. Tiny and fully transparent windows are skipped —
    /// many apps keep invisible utility windows that aren't anything a person sees.
    static func countsByPID() -> [pid_t: WindowCount] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: WindowCount] = [:]
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            if let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict),
               bounds.width < 60 || bounds.height < 60 { continue }
            result[pid, default: WindowCount()].total += 1
            if (window[kCGWindowIsOnscreen as String] as? Bool) == true {
                result[pid, default: WindowCount()].onscreen += 1
            }
        }
        return result
    }
}
