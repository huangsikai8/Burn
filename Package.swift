// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Burn",
    platforms: [.macOS(.v15)],
    targets: [
        // Declarations for the kernel interfaces the SDK doesn't publish: coalition
        // membership and totals, and the responsible-process lookup.
        .target(name: "CProc", path: "Sources/CProc"),
        .executableTarget(
            name: "Burn",
            dependencies: ["CProc"],
            path: "Sources/Burn",
            // Language mode 5: the sampler hands raw C structs across a background
            // queue and the IOKit/libproc APIs carry no Sendable annotations.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
