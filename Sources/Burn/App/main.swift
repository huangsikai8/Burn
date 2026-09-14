import AppKit

let environment = ProcessInfo.processInfo.environment

if environment["BURN_DUMP"] != nil {
    MainActor.assumeIsolated {
        DumpMode.run(seconds: Double(environment["BURN_DUMP_SECONDS"] ?? "") ?? 3)
    }
    exit(0)
}

BurnApp.main()
