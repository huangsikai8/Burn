import AppKit

/// App icons are expensive to fetch and never change while an app runs.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for group: AppGroup) -> NSImage {
        let key = group.bundlePath ?? group.historyKey
        if let cached = icons[key] { return cached }
        let image: NSImage
        if let pid = group.appPID, let running = NSRunningApplication(processIdentifier: pid), let icon = running.icon {
            image = icon
        } else if let path = group.bundlePath {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if group.kind == .system {
            image = symbol("gearshape.2.fill")
        } else {
            image = symbol("terminal.fill")
        }
        image.size = NSSize(width: 32, height: 32)
        icons[key] = image
        return image
    }

    static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }
}
