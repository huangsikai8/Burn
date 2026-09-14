import Combine
import SwiftUI

/// Owns every long-lived service and wires them together.
@MainActor
final class AppModel: ObservableObject {
    let preferences: Preferences
    let monitor: Monitor
    let history: HistoryStore
    let engine: InsightEngine
    private(set) var alerts: AlertCenter?
    /// Set by a view that has the openWindow action, so the Dock icon can reopen the window.
    var openMainWindow: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    static var stateDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["BURN_STATE_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burn", isDirectory: true)
    }

    init() {
        preferences = Preferences()
        monitor = Monitor()
        history = HistoryStore(directory: Self.stateDirectory)
        engine = InsightEngine(monitor: monitor, preferences: preferences, history: history)
        alerts = AlertCenter(engine: engine, monitor: monitor, preferences: preferences)

        monitor.subscribe { [history] snapshot in history.record(snapshot) }
        preferences.$fastInterval
            .sink { [monitor] interval in monitor.visibleInterval = interval }
            .store(in: &cancellables)
        monitor.start()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { _ = model }
        // build.sh stops the running copy with SIGTERM before replacing it. Flush the
        // minute of history in progress so a rebuild doesn't leave a gap.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.model.history.flush() }
            exit(0)
        }
        source.resume()
        terminationSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.history.flush() }
    }

    /// Closing the window keeps Burn watching from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { model.openMainWindow?() } }
        return true
    }
}

struct BurnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    var body: some Scene {
        Window("Burn", id: "main") {
            MainWindow()
                .environmentObjects(delegate.model)
        }
        .defaultSize(width: 1320, height: 820)

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarView()
                .environmentObjects(delegate.model)
        } label: {
            MenuBarLabelView()
                .environmentObjects(delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObjects(delegate.model)
        }
    }
}

extension View {
    @MainActor
    func environmentObjects(_ model: AppModel) -> some View {
        environmentObject(model)
            .environmentObject(model.monitor)
            .environmentObject(model.engine)
            .environmentObject(model.preferences)
    }
}
