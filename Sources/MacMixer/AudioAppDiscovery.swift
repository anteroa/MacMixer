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
    /// Every process Core Audio knows about, grouped by the app that owns it.
    static func scan() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = CA.objectIDs(AudioObjectID(kAudioObjectSystemObject),
                                     kAudioHardwarePropertyProcessObjectList)
        var groups: [String: AudioApp] = [:]

        for objectID in processes {
            guard let pid = CA.get(objectID, kAudioProcessPropertyPID, initial: pid_t(-1)),
                  pid > 0, pid != ownPID else { continue }
            let running = (CA.get(objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            let processBundleID = CA.string(objectID, kAudioProcessPropertyBundleID)

            let owner = owningApp(for: pid, processBundleID: processBundleID)
            if owner?.processIdentifier == ownPID { continue }

            let key = owner?.bundleIdentifier ?? processBundleID ?? "pid-\(pid)"
            let name = owner?.localizedName
                ?? processBundleID?.split(separator: ".").last.map(String.init)
                ?? processName(pid)
                ?? "Process \(pid)"

            if var existing = groups[key] {
                existing.processObjectIDs.insert(objectID)
                existing.isPlaying = existing.isPlaying || running
                groups[key] = existing
            } else {
                groups[key] = AudioApp(id: key, name: name, icon: owner?.icon,
                                       processObjectIDs: [objectID], isPlaying: running)
            }
        }
        return Array(groups.values)
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
