import AppKit
import CoreAudio
import Darwin

/// One row in the mixer: an app plus all of its helper processes that make sound
/// (e.g. Chrome's renderer helpers, Safari's WebContent processes).
struct AudioApp: Identifiable, Equatable {
    /// Stable key used for saved volumes: the owning app's bundle ID when known.
    let id: String
    var name: String
    var icon: NSImage?
    var processObjectIDs: Set<AudioObjectID>
    var isPlaying: Bool

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name &&
            lhs.processObjectIDs == rhs.processObjectIDs && lhs.isPlaying == rhs.isPlaying
    }
}

enum AudioAppDiscovery {
    /// Browsers run every site in its own helper process. For these, each helper
    /// that's actually making sound gets its own row instead of being collapsed
    /// into one "Chrome" entry — so playing music in one tab and a video in
    /// another gives you two independent sliders. Core Audio only reports a PID
    /// and bundle ID for each process, not the page it's showing, so rows from
    /// the same browser are only numbered ("Google Chrome (2)"), not named after
    /// the site. Single-purpose multi-process apps (Spotify, Discord, Slack) are
    /// deliberately not in this set: their helpers are all still "one app" to the
    /// user, so they stay grouped under one row like before.
    private static let multiSourceBrowserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", // Arc
    ]

    /// Processes with no regular owning app (system daemons) whose raw name
    /// isn't something to show someone.
    private static let friendlyNames: [String: String] = [
        "systemsoundserverd": "System Sounds",
    ]

    private static let fallbackIcon = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)

    /// Every process Core Audio knows about, grouped by the app that owns it
    /// (except browser tabs/sites — see `multiSourceBrowserBundleIDs`).
    static func scan(labelBrowserTabs: Bool) -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = CA.objectIDs(AudioObjectID(kAudioObjectSystemObject),
                                     kAudioHardwarePropertyProcessObjectList)
        var groups: [String: AudioApp] = [:]
        var browserOwnerPIDs: [String: pid_t] = [:]

        for objectID in processes {
            guard let pid = CA.get(objectID, kAudioProcessPropertyPID, initial: pid_t(-1)),
                  pid > 0, pid != ownPID else { continue }
            let running = (CA.get(objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            let processBundleID = CA.string(objectID, kAudioProcessPropertyBundleID)

            let owner = owningApp(for: pid, processBundleID: processBundleID)
            if owner?.processIdentifier == ownPID { continue }

            let isBrowserHelper = owner?.processIdentifier != pid
                && multiSourceBrowserBundleIDs.contains(owner?.bundleIdentifier ?? "")

            let key = isBrowserHelper ? "pid-\(pid)" : (owner?.bundleIdentifier ?? processBundleID ?? "pid-\(pid)")
            let name = resolveName(owner: owner, processBundleID: processBundleID, pid: pid)
            let icon = owner?.icon ?? fallbackIcon
            if isBrowserHelper, let ownerPID = owner?.processIdentifier { browserOwnerPIDs[key] = ownerPID }

            if var existing = groups[key] {
                existing.processObjectIDs.insert(objectID)
                existing.isPlaying = existing.isPlaying || running
                groups[key] = existing
            } else {
                groups[key] = AudioApp(id: key, name: name, icon: icon,
                                       processObjectIDs: [objectID], isPlaying: running)
            }
        }
        let disambiguated = disambiguate(Array(groups.values))
        guard labelBrowserTabs else { return disambiguated }
        return labelFromOpenTabs(disambiguated, ownerPIDs: browserOwnerPIDs)
    }

    /// Best-effort: replace a playing browser row's generic "Chrome (2)" name
    /// with the actual tab title, read live from the browser's Accessibility
    /// tree (see BrowserTabs). Core Audio and the Accessibility tree each
    /// enumerate processes/tabs in their own order with no shared identifier
    /// between the two, so when several tabs are audible at once this can
    /// pair the wrong title with the wrong row — it only ever affects the text
    /// shown, never which process that row's slider actually controls.
    private static func labelFromOpenTabs(_ apps: [AudioApp], ownerPIDs: [String: pid_t]) -> [AudioApp] {
        let playing = apps.filter { $0.isPlaying && ownerPIDs[$0.id] != nil }
        guard !playing.isEmpty else { return apps }
        BrowserTabs.requestAccessIfNeeded()

        var byOwnerPID: [pid_t: [AudioApp]] = [:]
        for app in playing {
            guard let ownerPID = ownerPIDs[app.id] else { continue }
            byOwnerPID[ownerPID, default: []].append(app)
        }

        var titleByID: [String: String] = [:]
        for (ownerPID, rows) in byOwnerPID {
            let titles = BrowserTabs.audiblePlayingTitles(ownerPID: ownerPID)
            guard !titles.isEmpty else { continue }
            let rows = rows.sorted { pidFromKey($0.id) < pidFromKey($1.id) }
            for (row, title) in zip(rows, titles) { titleByID[row.id] = title }
        }
        guard !titleByID.isEmpty else { return apps }

        return apps.map { app in
            guard let title = titleByID[app.id] else { return app }
            var app = app
            app.name = title
            return app
        }
    }

    /// When a browser contributes more than one row, number them so they're
    /// distinguishable — stably, by PID, so a row doesn't relabel itself between
    /// one-second refreshes.
    private static func disambiguate(_ apps: [AudioApp]) -> [AudioApp] {
        var byName: [String: [AudioApp]] = [:]
        for app in apps { byName[app.name, default: []].append(app) }

        var result: [AudioApp] = []
        for (name, group) in byName {
            guard group.count > 1 else {
                result.append(contentsOf: group)
                continue
            }
            let sorted = group.sorted { pidFromKey($0.id) < pidFromKey($1.id) }
            for (index, var app) in sorted.enumerated() {
                app.name = "\(name) (\(index + 1))"
                result.append(app)
            }
        }
        return result
    }

    private static func resolveName(owner: NSRunningApplication?, processBundleID: String?, pid: pid_t) -> String {
        if let processBundleID, let friendly = friendlyNames[processBundleID] { return friendly }
        if let name = owner?.localizedName { return name }
        if let last = processBundleID?.split(separator: ".").last { return String(last) }
        if let name = processName(pid) { return name }
        return "Process \(pid)"
    }

    private static func pidFromKey(_ key: String) -> Int {
        guard key.hasPrefix("pid-"), let value = Int(key.dropFirst(4)) else { return .max }
        return value
    }

    // MARK: - Finding the app a helper process belongs to

    private static func owningApp(for pid: pid_t, processBundleID: String?) -> NSRunningApplication? {
        // 1. macOS tracks a "responsible" process for helpers and XPC services.
        if let responsiblePID = responsiblePID(for: pid),
           let app = NSRunningApplication(processIdentifier: responsiblePID),
           app.activationPolicy == .regular {
            return app
        }
        // 2. Walk up the parent chain (Chrome/Electron helpers are children of the app).
        var current = pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current) else { break }
            current = parent
        }
        // 3. Bundle ID prefix match, e.g. "com.google.Chrome.helper" → "com.google.Chrome".
        if let processBundleID {
            let candidates = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular &&
                    ($0.bundleIdentifier.map { processBundleID.hasPrefix($0) } ?? false)
            }
            if let best = candidates.max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }) {
                return best
            }
        }
        // 4. Whatever the process itself is.
        return NSRunningApplication(processIdentifier: pid)
    }

    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t

    private static let responsibilityFn: ResponsibilityFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFn.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = responsibilityFn else { return nil }
        let result = fn(pid)
        return result > 0 && result != pid ? result : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
