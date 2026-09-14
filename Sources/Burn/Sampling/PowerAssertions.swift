import Foundation
import IOKit.pwr_mgt

struct SleepAssertion: Hashable {
    let type: String
    let name: String
}

enum PowerAssertions {
    /// Assertion types that actually keep the Mac or its display awake.
    private static let preventing: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion"
    ]

    /// Sleep-preventing assertions keyed by the pid they are *for*. coreaudiod and
    /// similar daemons take assertions on behalf of an app; those are charged to the app.
    static func current() -> [pid_t: [SleepAssertion]] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as NSDictionary? else { return [:] }

        var result: [pid_t: [SleepAssertion]] = [:]
        for (key, value) in dict {
            guard let owner = (key as? NSNumber)?.int32Value,
                  let list = value as? [[String: Any]] else { continue }
            for entry in list {
                guard let type = entry["AssertType"] as? String, preventing.contains(type) else { continue }
                let name = entry["AssertName"] as? String ?? type
                // powerd's own "prevent sleep while display is on" is not caused by any app.
                if name.hasPrefix("Powerd - ") { continue }
                let target = (entry["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? owner
                result[target, default: []].append(SleepAssertion(type: type, name: name))
            }
        }
        return result
    }
}
