import ApplicationServices
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SuggestionSettings().tabItem { Label("Suggestions", systemImage: "lightbulb") }
            AlertSettings().tabItem { Label("Alerts", systemImage: "bell") }
            HistorySettings().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var preferences: Preferences
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibility = AXIsProcessTrusted()

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Show in menu bar", isOn: $showMenuBarItem)
            Picker("Menu bar shows", selection: $preferences.menuBarLabel) {
                ForEach(MenuBarLabel.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(!showMenuBarItem)
            Picker("Refresh while open", selection: $preferences.fastInterval) {
                Text("Every second").tag(1.0)
                Text("Every 2 seconds").tag(2.0)
                Text("Every 5 seconds").tag(5.0)
            }
            LabeledContent("Unsaved-work check") {
                if accessibility {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow Accessibility…") {
                        AppActions.requestAccessibility()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { accessibility = AXIsProcessTrusted() }
                    }
                }
            }
            Text("Burn samples every 10 seconds in the background so alerts and history keep working when the window is closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct SuggestionSettings: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        Form {
            Section("Suggest closing an app when") {
                LabeledContent("Unused or hidden for") {
                    Slider(value: $preferences.idleHours, in: 0.5...12, step: 0.5) {
                        EmptyView()
                    }
                    Text(Format.duration(preferences.idleHours * 3600)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                LabeledContent("And using at least") {
                    Slider(value: $preferences.suggestMinimumMB, in: 100...2000, step: 50) { EmptyView() }
                    Text(Format.bytes(preferences.suggestMinimumMB * 1_048_576)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                Text("Apps playing audio, holding a call, keeping the Mac awake or running tools such as a terminal build are never suggested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never suggest or alert about") {
                if preferences.ignoredApps.isEmpty {
                    Text("No apps. Right-click an app in the table to add it.").foregroundStyle(.secondary)
                }
                ForEach(preferences.ignoredApps, id: \.self) { key in
                    HStack {
                        Text(name(for: key))
                        Spacer()
                        Button("Remove") { preferences.toggleIgnored(key) }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func name(for key: String) -> String {
        monitor.snapshot.groups.first { $0.historyKey == key }?.name ?? key
    }
}

private struct AlertSettings: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Section("Runaway process") {
                Toggle("Notify", isOn: $preferences.notifyRunaway)
                LabeledContent("Above") {
                    Slider(value: $preferences.runawayCPU, in: 50...100, step: 5) { EmptyView() }
                    Text(Format.percent(preferences.runawayCPU, digits: 0)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                LabeledContent("For") {
                    Slider(value: $preferences.runawayMinutes, in: 1...15, step: 1) { EmptyView() }
                    Text("\(Int(preferences.runawayMinutes)) min").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
            }
            Section("Busy while hidden") {
                LabeledContent("Average CPU above") {
                    Slider(value: $preferences.hiddenBusyCPU, in: 1...20, step: 1) { EmptyView() }
                    Text(Format.percent(preferences.hiddenBusyCPU, digits: 0)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                LabeledContent("Over") {
                    Slider(value: $preferences.hiddenBusyMinutes, in: 2...30, step: 1) { EmptyView() }
                    Text("\(Int(preferences.hiddenBusyMinutes)) min").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
            }
            Section("Memory") {
                Toggle("Notify when memory pressure turns critical", isOn: $preferences.notifyPressure)
                Toggle("Notify about apps whose memory keeps growing", isOn: $preferences.notifyLeaks)
                LabeledContent("Growth of at least") {
                    Slider(value: $preferences.leakMBPerHour, in: 100...1000, step: 50) { EmptyView() }
                    Text("\(Int(preferences.leakMBPerHour)) MB/h").monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var size: UInt64 = 0

    var body: some View {
        Form {
            LabeledContent("Stored") { Text(Format.bytes(size)) }
            Text("Per-minute history is kept for 48 hours and 15-minute averages for 30 days, together with the battery ledger.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear History…", role: .destructive) {
                if AppActions.confirm(title: "Clear all history?", message: "Charts, battery use and leak detection start again from now.",
                                      button: "Clear", destructive: true) {
                    model.history.clear()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { size = model.history.sizeOnDisk }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { size = model.history.sizeOnDisk }
    }
}
