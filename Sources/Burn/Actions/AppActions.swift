import AppKit
import ApplicationServices

@MainActor
enum AppActions {
    // MARK: Unsaved work

    /// Titles of windows showing the unsaved-changes dot in their close button.
    /// nil when Burn hasn't been granted Accessibility and so can't look.
    ///
    /// The close button's AXEdited flag is what the dot is drawn from, so it's set
    /// for AppKit documents and for Electron apps alike; AXDocument alone isn't.
    static func unsavedWindows(pid: pid_t) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }

        var titles: [String] = []
        for window in windows {
            var buttonValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue) == .success,
                  let buttonValue, CFGetTypeID(buttonValue) == AXUIElementGetTypeID() else { continue }
            let button = buttonValue as! AXUIElement
            var edited: CFTypeRef?
            guard AXUIElementCopyAttributeValue(button, "AXEdited" as CFString, &edited) == .success,
                  (edited as? NSNumber)?.boolValue == true else { continue }
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            let text = (title as? String) ?? ""
            titles.append(text.isEmpty ? "Untitled" : text)
        }
        return titles
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Quitting

    /// A normal quit. Real apps get the same request as ⌘Q, so they still ask about
    /// unsaved documents. Anything else gets SIGTERM after a confirmation.
    static func quit(_ group: AppGroup) {
        if let pid = group.appPID, let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
            return
        }
        let count = group.processes.count
        var message = "\(group.name) isn’t a regular app, so Burn will ask its \(count == 1 ? "process" : "\(count) processes") to exit."
        if group.kind == .system {
            message += " macOS may restart system services automatically."
        }
        guard confirm(title: "Quit \(group.name)?", message: message, button: "Quit") else { return }
        send(group.processes, signal: SIGTERM)
    }

    static func forceQuit(_ group: AppGroup) {
        var message = "\(group.name) will stop immediately. Anything unsaved will be lost."
        if let pid = group.appPID {
            if let unsaved = unsavedWindows(pid: pid) {
                if !unsaved.isEmpty {
                    message += "\n\nUnsaved changes in: " + unsaved.prefix(6).joined(separator: ", ")
                }
            } else {
                message += "\n\nTo check for unsaved documents first, allow Burn under Privacy & Security › Accessibility."
            }
        }
        guard confirm(title: "Force quit \(group.name)?", message: message, button: "Force Quit", destructive: true) else { return }
        if let pid = group.appPID {
            NSRunningApplication(processIdentifier: pid)?.forceTerminate()
        }
        send(group.processes, signal: SIGKILL)
    }

    static func quitProcess(_ process: ProcessStat, in group: AppGroup, force: Bool) {
        var message: String
        if process.pid == group.appPID {
            message = "This is \(group.name) itself."
        } else if group.processes.count > 1 {
            message = "This is one of \(group.name)’s \(group.processes.count) processes. Stopping it may close a tab, a window or an extension."
        } else {
            message = "\(process.name) will be asked to exit."
        }
        if force { message += " Anything unsaved in it will be lost." }
        let title = "\(force ? "Force quit" : "Quit") \(process.name) (\(process.pid))?"
        guard confirm(title: title, message: message, button: force ? "Force Quit" : "Quit", destructive: force) else { return }
        send([process], signal: force ? SIGKILL : SIGTERM)
    }

    /// Normal quits for several apps at once. Returns the names of apps that have
    /// unsaved documents, which will each put up their own save prompt.
    @discardableResult
    static func quitAll(_ groups: [AppGroup]) -> [String] {
        var prompting: [String] = []
        for group in groups {
            guard let pid = group.appPID, let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if let unsaved = unsavedWindows(pid: pid), !unsaved.isEmpty { prompting.append(group.name) }
            app.terminate()
        }
        return prompting
    }

    /// Signals processes directly, falling back to an administrator prompt for any
    /// owned by root or another user — the same thing Activity Monitor asks for.
    private static func send(_ processes: [ProcessStat], signal: Int32) {
        var privileged: [pid_t] = []
        for process in processes {
            if process.isOwn, kill(process.pid, signal) == 0 { continue }
            if process.isOwn, errno == ESRCH { continue }
            privileged.append(process.pid)
        }
        guard !privileged.isEmpty else { return }
        let pids = privileged.map(String.init).joined(separator: " ")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"kill -\(signal) \(pids)\" with administrator privileges")?
            .executeAndReturnError(&error)
    }

    // MARK: Inspection

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Runs `sample` for three seconds and opens the report, like Activity Monitor's
    /// Sample Process. Other users' processes need root, which `sample` can't get.
    static func sample(pid: pid_t, name: String, isOwn: Bool) {
        guard isOwn else {
            inform(title: "Can’t sample \(name)",
                   message: "It belongs to another user or to macOS. Run `sudo sample \(pid) 3` in Terminal instead.")
            return
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burn/Samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let file = directory.appendingPathComponent("\(safeName)-\(pid)-\(stamp).txt")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "3", "-file", file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
            }
        }
    }

    static func openFiles(pid: pid_t, completion: @escaping @MainActor (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = ForeignProcessMemory.run("/usr/sbin/lsof", ["-n", "-P", "-p", String(pid)]) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(output.isEmpty ? "No open files could be listed. The process may belong to another user." : output)
                }
            }
        }
    }

    // MARK: Alerts

    static func confirm(title: String, message: String, button: String, destructive: Bool = false) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if destructive { alert.buttons[0].hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func inform(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
