import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: Monitor
    @EnvironmentObject private var engine: InsightEngine
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.openWindow) private var openWindow

    @SceneStorage("tab") private var tab: ViewTab = .memory
    @SceneStorage("filter") private var filter: ViewFilter = .apps
    @State private var search = ""
    @State private var selection: Row.ID?
    @State private var sortOrder: [RowComparator] = [RowComparator(metric: .memory)]
    @State private var showSidebar = true

    var body: some View {
        let rows = RowBuilder.rows(snapshot: monitor.snapshot, filter: filter, search: search,
                                   extras: engine.insights.extras, sort: sortOrder)
        let selected = find(selection, in: rows)

        VStack(spacing: 0) {
            AppTableView(rows: rows, tab: tab, selection: $selection, sortOrder: $sortOrder, actions: actions)
            Divider()
            SystemFooter(tab: tab, system: monitor.snapshot.system, history: monitor.systemHistory)
                .background(.bar)
        }
        .overlay {
            if monitor.snapshot.groups.isEmpty {
                ProgressView("Taking the first sample…")
            }
        }
        .inspector(isPresented: $showSidebar) {
            Group {
                if let selected, let group = selected.group {
                    DetailPanel(group: group, process: selected.process, close: { selection = nil },
                                selectProcess: { process in selection = "p\(process.pid).\(process.identity.key.startMicros)" },
                                selectGroup: select)
                } else {
                    InsightsPanel(select: select)
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 350, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(ViewTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $filter) {
                    ForEach(ViewFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 190)
                .help("Which apps and processes to list")
            }
            ToolbarItem {
                Button {
                    showSidebar.toggle()
                } label: {
                    Label("Insights", systemImage: engine.insights.alertCount > 0 ? "sparkles.rectangle.stack.fill" : "sidebar.right")
                }
                .help("Show or hide insights")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps, processes, PIDs")
        .navigationTitle("Burn")
        .navigationSubtitle(subtitle)
        .onChange(of: tab, initial: true) { _, newTab in
            sortOrder = [RowComparator(metric: newTab.primary)]
        }
        .onAppear {
            monitor.setVisible(true)
            model.openMainWindow = { openWindow(id: "main") }
        }
        .onDisappear { monitor.setVisible(false) }
    }

    private var subtitle: String {
        let snapshot = monitor.snapshot
        let apps = snapshot.groups.filter { $0.kind == .app }.count
        return "\(apps) apps · \(snapshot.system.processCount) processes"
    }

    private var actions: RowActions {
        RowActions(
            quit: { row in
                if row.level == .process, let process = row.process, let group = row.group {
                    AppActions.quitProcess(process, in: group, force: false)
                } else if let group = row.group {
                    AppActions.quit(group)
                }
            },
            forceQuit: { row in
                if row.level == .process, let process = row.process, let group = row.group {
                    AppActions.quitProcess(process, in: group, force: true)
                } else if let group = row.group {
                    AppActions.forceQuit(group)
                }
            },
            reveal: { row in
                if let path = row.group?.bundlePath ?? row.process?.identity.path, !path.isEmpty { AppActions.reveal(path) }
            },
            inspect: { row in
                selection = row.id
                showSidebar = true
            },
            sample: { row in
                if let process = row.process {
                    AppActions.sample(pid: process.pid, name: process.name, isOwn: process.isOwn)
                } else if let group = row.group {
                    AppActions.sample(pid: group.leaderPID, name: group.name, isOwn: group.isOwn)
                }
            },
            ignore: { row in
                if let key = row.group?.historyKey { preferences.toggleIgnored(key) }
            }
        )
    }

    private func select(_ group: AppGroup) {
        selection = "g\(group.id)"
        showSidebar = true
    }

    private func find(_ id: Row.ID?, in rows: [Row]) -> Row? {
        guard let id else { return nil }
        for row in rows {
            if row.id == id { return row }
            if let match = find(id, in: row.children ?? []) { return match }
        }
        return nil
    }
}

extension ViewTab: Codable {}
extension ViewFilter: Codable {}
