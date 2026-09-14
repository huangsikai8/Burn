import Foundation

/// Measured signals that point at what is driving a system service.
enum CauseHint {
    /// Apps with windows on screen that are drawing (CPU or GPU).
    case onScreenApps
    /// Apps holding an audio assertion.
    case audioApps
    /// Apps starting processes quickly — every new binary is checked and registered.
    case processSpawners
    /// Monitoring tools that ask for every process's statistics.
    case statsTools
    /// Memory-heavy apps, when the service's work is paging.
    case memoryHogs
    /// Apps writing a lot to disk.
    case diskWriters
    /// Thermal state, when macOS is cooling the chip.
    case thermal
    /// Pages moving to and from swap.
    case swapActivity
}

struct ServiceInfo {
    /// Short label for the table, e.g. "Draws the screen".
    let title: String
    let what: String
    let whyBusy: String
    let reduce: [String]
    var hints: [CauseHint] = []
}

/// Plain-English notes on the macOS services that most often show up near the top
/// of the CPU list. Only services whose role is well established are described;
/// anything else is shown with its path and no guesswork.
enum ServiceKnowledge {
    static func info(for executable: String) -> ServiceInfo? {
        if let exact = table[executable] { return exact }
        for (prefix, info) in prefixes where executable.hasPrefix(prefix) { return info }
        return nil
    }

    private static let spotlight = ServiceInfo(
        title: "Spotlight indexing",
        what: "Spotlight reads new and changed files so they can be found by search.",
        whyBusy: "It works hardest after lots of files change: a macOS update, a new drive, a big download, or developer folders full of build output.",
        reduce: [
            "It usually settles on its own once the changes are indexed.",
            "Exclude folders that change constantly (build output, node_modules, virtual machines) in System Settings › Spotlight › Search Privacy."
        ],
        hints: [.diskWriters])

    private static let iCloud = ServiceInfo(
        title: "iCloud sync",
        what: "Keeps iCloud Drive, Desktop & Documents and other iCloud data in sync.",
        whyBusy: "Large or many changed files are uploading or downloading, or a sync got stuck retrying.",
        reduce: [
            "Check iCloud Drive in Finder’s sidebar for files still uploading.",
            "Keep frequently changing folders (builds, caches) out of iCloud Drive."
        ],
        hints: [.diskWriters])

    private static let securityChecks = ServiceInfo(
        title: "Checking code signatures",
        what: "Verifies apps and command-line tools before they run, and scans for known malware.",
        whyBusy: "Every newly launched program is checked, so it spikes when an app or build system starts many processes, or after installing apps.",
        reduce: [
            "Find the app starting processes rapidly (shown below) and pause or quit what it is running.",
            "Repeated short-lived tools — build scripts, language servers, agents — are the usual cause."
        ],
        hints: [.processSpawners])

    private static let photos = ServiceInfo(
        title: "Photos analysis",
        what: "Analyses the Photos library for people, objects and text so it can be searched.",
        whyBusy: "It runs after many photos are added or after a macOS update, mostly while the Mac is idle and on power.",
        reduce: [
            "It pauses when you use the Mac and finishes on its own.",
            "Leaving the Mac plugged in and idle lets it complete sooner."
        ])

    private static let table: [String: ServiceInfo] = [
        "WindowServer": ServiceInfo(
            title: "Draws the screen",
            what: "Composites every window, menu, animation and video frame you see, on every display.",
            whyBusy: "More visible windows, animated or video content, transparency effects and extra or high-resolution displays all add to its work. Apps that redraw constantly keep it busy even when nothing seems to change.",
            reduce: [
                "Close or minimise windows playing video or animated pages.",
                "Quit apps that redraw constantly (shown below).",
                "Turn on Reduce transparency and Reduce motion in System Settings › Accessibility › Display.",
                "Disconnect displays you aren’t using."
            ],
            hints: [.onScreenApps]),
        "kernel_task": ServiceInfo(
            title: "macOS kernel",
            what: "The core of macOS: memory paging, disk and network I/O, drivers and temperature management.",
            whyBusy: "When the Mac is hot, the kernel deliberately takes CPU time so the chip cools. Heavy swapping and disk activity also show up here.",
            reduce: [
                "If the Mac is warm, quit heavy apps and keep the vents clear; the load drops as it cools.",
                "With a lot of swap, quitting memory-heavy apps reduces paging work.",
                "Unplug accessories you suspect are misbehaving."
            ],
            hints: [.thermal, .swapActivity, .memoryHogs]),
        "launchd": ServiceInfo(
            title: "Starts apps and services",
            what: "The first process; it launches and supervises every app, agent and daemon.",
            whyBusy: "Something is launching or relaunching processes rapidly.",
            reduce: ["Find the app starting processes quickly (shown below)."],
            hints: [.processSpawners]),
        "launchservicesd": ServiceInfo(
            title: "App registry",
            what: "Tracks installed apps and which app opens which file type.",
            whyBusy: "Apps launching, apps being installed or updated, or a program asking about apps over and over.",
            reduce: ["Find the app starting processes or querying apps constantly (shown below)."],
            hints: [.processSpawners]),
        "runningboardd": ServiceInfo(
            title: "Manages app lifecycles",
            what: "Decides which apps and extensions may run and how much memory they get.",
            whyBusy: "Many processes starting and stopping, or memory pressure forcing decisions about what to suspend.",
            reduce: ["Quit apps starting processes quickly, or memory-heavy apps under pressure."],
            hints: [.processSpawners, .memoryHogs]),
        "sysmond": ServiceInfo(
            title: "System statistics",
            what: "Collects per-process statistics for Activity Monitor and similar tools.",
            whyBusy: "A monitoring tool is open and refreshing often.",
            reduce: ["Close Activity Monitor or other monitors you aren’t looking at."],
            hints: [.statsTools]),
        "coreaudiod": ServiceInfo(
            title: "Audio",
            what: "Mixes and routes all sound input and output.",
            whyBusy: "Apps playing or recording audio, calls, virtual audio devices, or Bluetooth audio.",
            reduce: [
                "Stop playback or calls in the apps below if you aren’t using them.",
                "Remove virtual audio devices you no longer need."
            ],
            hints: [.audioApps]),
        "logd": ServiceInfo(
            title: "System log",
            what: "Records log messages from every app and service.",
            whyBusy: "Some program is writing log messages at a very high rate.",
            reduce: ["Run `log stream` in Terminal to see which process is flooding the log, then quit or update it."]),
        "WindowManager": ServiceInfo(
            title: "Window management",
            what: "Handles Stage Manager, desktop widgets and window tiling.",
            whyBusy: "Many windows moving, resizing or being arranged, or widgets updating.",
            reduce: ["Turn off Stage Manager or desktop widgets if you don’t use them."],
            hints: [.onScreenApps]),
        "Dock": ServiceInfo(
            title: "Dock and Mission Control",
            what: "Runs the Dock, Mission Control, Launchpad and Spaces.",
            whyBusy: "Animations, many windows in Mission Control, or badges updating often.",
            reduce: ["Turn off Dock magnification and animate opening apps in System Settings › Desktop & Dock."]),
        "bluetoothd": ServiceInfo(
            title: "Bluetooth",
            what: "Manages Bluetooth devices.",
            whyBusy: "Bluetooth audio, many connected devices, or a device repeatedly reconnecting.",
            reduce: ["Disconnect devices you aren’t using."],
            hints: [.audioApps]),
        "locationd": ServiceInfo(
            title: "Location Services",
            what: "Works out the Mac’s location for apps that ask.",
            whyBusy: "An app is requesting location continuously.",
            reduce: ["Review System Settings › Privacy & Security › Location Services and turn off apps that don’t need it."]),
        "nsurlsessiond": ServiceInfo(
            title: "Background downloads",
            what: "Performs downloads and uploads on behalf of apps and macOS.",
            whyBusy: "App Store, iCloud or another app is transferring data in the background.",
            reduce: ["Let transfers finish, or pause them in the app that started them."]),
        "fseventsd": ServiceInfo(
            title: "File change tracking",
            what: "Tells apps which files and folders changed.",
            whyBusy: "Many files changing at once: builds, syncing, unpacking archives.",
            reduce: ["It settles when the file activity stops; the busiest writers are shown below."],
            hints: [.diskWriters]),
        "cfprefsd": ServiceInfo(
            title: "App settings",
            what: "Reads and writes preferences for apps.",
            whyBusy: "An app is saving its settings over and over.",
            reduce: ["Quitting the misbehaving app stops it."]),
        "distnoted": ServiceInfo(
            title: "Inter-app notifications",
            what: "Delivers notifications that apps broadcast to each other.",
            whyBusy: "An app is broadcasting notifications continuously.",
            reduce: ["Quitting the misbehaving app stops it."]),
        "opendirectoryd": ServiceInfo(
            title: "User and group lookups",
            what: "Answers questions about user accounts, groups and directory services.",
            whyBusy: "Programs looking up users repeatedly, common with command-line tools starting rapidly.",
            reduce: ["Find the app starting processes quickly (shown below)."],
            hints: [.processSpawners]),
        "backupd": ServiceInfo(
            title: "Time Machine",
            what: "Backs up the Mac with Time Machine.",
            whyBusy: "A backup is running, often a large one after many files changed.",
            reduce: ["Let it finish, or exclude large, constantly changing folders in Time Machine options."],
            hints: [.diskWriters]),
        "softwareupdated": ServiceInfo(
            title: "Software Update",
            what: "Checks for, downloads and prepares macOS updates.",
            whyBusy: "An update is downloading or being prepared.",
            reduce: ["Let it finish; it stops once the update is ready to install."]),
        "installd": ServiceInfo(
            title: "Installing software",
            what: "Installs apps and packages.",
            whyBusy: "An app or update is being installed.",
            reduce: ["Let the installation finish."]),
        "MTLCompilerService": ServiceInfo(
            title: "Compiling graphics shaders",
            what: "Prepares GPU programs for apps and games.",
            whyBusy: "An app launched for the first time since an update, or a game is loading.",
            reduce: ["It finishes once shaders are cached; relaunches are faster."],
            hints: [.onScreenApps]),
        "loginwindow": ServiceInfo(
            title: "Login session",
            what: "Manages your login session, screen lock and the Force Quit window.",
            whyBusy: "Brief spikes are normal around locking, unlocking and app launches.",
            reduce: ["Sustained load usually follows another app misbehaving; check apps starting processes."],
            hints: [.processSpawners]),
        "duetexpertd": ServiceInfo(
            title: "Siri Suggestions",
            what: "Learns how you use the Mac to predict apps, contacts and shortcuts for Siri Suggestions and Spotlight.",
            whyBusy: "It periodically processes recent activity; bursts are usually short.",
            reduce: [
                "Sustained load usually passes on its own.",
                "Turning off suggestions in System Settings › Siri & Spotlight reduces its work."
            ]),
        "trustd": securityChecks,
        "syspolicyd": securityChecks,
        "amfid": securityChecks,
        "XprotectService": securityChecks,
        "XProtect": securityChecks,
        "mds": spotlight,
        "mds_stores": spotlight,
        "corespotlightd": spotlight,
        "cloudd": iCloud,
        "bird": iCloud,
        "fileproviderd": iCloud,
        "photoanalysisd": photos,
        "mediaanalysisd": photos,
        "photolibraryd": photos
    ]

    private static let prefixes: [(String, ServiceInfo)] = [
        ("mdworker", spotlight),
        ("spotlightknowledge", spotlight),
        ("com.apple.CloudDocs", iCloud)
    ]
}
