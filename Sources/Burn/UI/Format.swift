import Foundation

enum Format {
    /// Activity Monitor style: "1.23 GB", "512.4 MB", "84 KB".
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024, tb = gb * 1024
        switch value {
        case ..<kb: return String(format: "%.0f B", value)
        case ..<mb: return String(format: "%.0f KB", value / kb)
        case ..<(100 * mb): return String(format: "%.1f MB", value / mb)
        case ..<gb: return String(format: "%.0f MB", value / mb)
        case ..<tb: return String(format: "%.2f GB", value / gb)
        default: return String(format: "%.2f TB", value / tb)
        }
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        if bytesPerSecond < 1 { return "0 KB/s" }
        return bytes(bytesPerSecond) + "/s"
    }

    static func percent(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f%%", value)
    }

    static func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 0.01 { return "0 W" }
        if value < 1 { return String(format: "%.0f mW", value * 1000) }
        return String(format: "%.1f W", value)
    }

    /// CPU time the way Activity Monitor shows it: "1:02:03.45" or "12.34".
    static func cpuTime(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) % 3600 / 60
        let rest = seconds.truncatingRemainder(dividingBy: 60)
        if hours > 0 { return String(format: "%d:%02d:%05.2f", hours, minutes, rest) }
        if minutes > 0 { return String(format: "%d:%05.2f", minutes, rest) }
        return String(format: "%.2f", rest)
    }

    /// "45 s", "12 min", "3 h", "3 h 20 min", "2 days".
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86_400 {
            let h = seconds / 3600, m = seconds % 3600 / 60
            return m == 0 || h >= 10 ? "\(h) h" : "\(h) h \(m) min"
        }
        let days = seconds / 86_400
        return days == 1 ? "1 day" : "\(days) days"
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = now.timeIntervalSince(date)
        return interval < 60 ? "just now" : duration(interval) + " ago"
    }
}
