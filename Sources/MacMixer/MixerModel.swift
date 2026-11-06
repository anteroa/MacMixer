import AppKit
import Combine
import CoreAudio
import ServiceManagement

/// The app's state: which apps are making sound, their volumes, and the output device.
/// All methods are called on the main thread.
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var volumes: [String: Float] = [:]
    @Published private(set) var muted: Set<String> = []
    @Published private(set) var errors: [String: String] = [:] {
        didSet {
            for (id, message) in errors where oldValue[id] != message {
                Self.log("\(id): \(message)")
            }
        }
    }

    @Published private(set) var outputName: String = "No output device"
    @Published private(set) var masterVolume: Float = 1
    @Published private(set) var masterMuted = false
    @Published private(set) var masterAdjustable = false

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }

    /// Off by default: showing real tab titles needs the Accessibility
    /// permission (it can read anything on screen), which is a much bigger ask
    /// than the audio-only access MacMixer otherwise needs. Only request it,
    /// and only read tab titles, once someone explicitly opts in.
    @Published var showTabTitles: Bool {
        didSet {
            defaults.set(showTabTitles, forKey: showTabTitlesKey)
            if showTabTitles { BrowserTabs.requestAccessIfNeeded() }
            refresh()
        }
    }
    private let showTabTitlesKey = "showTabTitles"

    private var taps: [String: AppTap] = [:]
    /// Apps that have made sound since they launched. Like Windows, an app keeps its
    /// slider while it's open, even when paused.
    private var seenPlaying: Set<String> = []

    private var outputDevice: AudioDeviceID?
    private var outputUID: String?

    private var timer: Timer?
    private var listeners: [PropertyListener] = []
    private var outputChangeWorkItem: DispatchWorkItem?
    private var quitting = false

    private let defaults = UserDefaults.standard
    private let volumesKey = "appVolumes"
    private let mutedKey = "mutedApps"

    init() {
        showTabTitles = defaults.bool(forKey: showTabTitlesKey)
        if let saved = defaults.dictionary(forKey: volumesKey) as? [String: Double] {
            volumes = saved.mapValues { Float($0) }
        }
        muted = Set(defaults.stringArray(forKey: mutedKey) ?? [])

        updateOutputDevice()
        refresh()

        let system = AudioObjectID(kAudioObjectSystemObject)
        if let l = PropertyListener(objectID: system,
                                    address: CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                                    handler: { [weak self] in self?.scheduleOutputDeviceChanged() }) {
            listeners.append(l)
        }
        if let l = PropertyListener(objectID: system,
                                    address: CA.address(kAudioHardwarePropertyProcessObjectList),
                                    handler: { [weak self] in self?.refresh() }) {
            listeners.append(l)
        }

        // Cheap polling for "is this app playing right now" and master volume changes
        // made with the keyboard or Control Center.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.readMasterVolume()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
        taps.removeAll()
    }

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacMixer.log")

    private static func log(_ message: String) {
        guard let data = "\(Date()) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    // MARK: - Per-app volume

    func volume(for id: String) -> Float { volumes[id] ?? 1 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    func setVolume(_ value: Float, for id: String) {
        volumes[id] = max(0, min(1, value))
        updateTap(for: id, allowRemoval: false)
    }

    /// Called when the user lets go of a slider.
    func finishEditing(_ id: String) {
        if volume(for: id) > 0.98 { volumes[id] = 1 }
        if volume(for: id) >= 1 { volumes.removeValue(forKey: id) }
        save()
        updateTap(for: id, allowRemoval: true)
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        save()
        updateTap(for: id, allowRemoval: true)
    }

    /// Resets every app currently showing a permission/tap error back to its
    /// normal, untouched volume (100%, unmuted) — a recovery path for anyone
    /// who denied System Audio Recording and is now stuck with apps MacMixer
    /// can no longer control, without having to grant the permission just to
    /// get their sound back.
    func restoreNormalAudio() {
        for id in errors.keys {
            volumes.removeValue(forKey: id)
            muted.remove(id)
            updateTap(for: id, allowRemoval: true)
        }
        errors.removeAll()
        save()
    }

    /// Slider position → loudness. Squaring makes the slider feel even across its range
    /// (50% sounds about half as loud instead of barely quieter).
    private func gain(for id: String) -> Float32 {
        if muted.contains(id) { return 0 }
        let v = volume(for: id)
        return v * v
    }

    private func needsTap(_ id: String) -> Bool {
        muted.contains(id) || volume(for: id) < 0.999
    }

    /// Apps at 100% and unmuted are left completely alone (no tap, untouched audio).
    private func updateTap(for id: String, allowRemoval: Bool) {
        guard let app = apps.first(where: { $0.id == id }) else {
            taps.removeValue(forKey: id)
            return
        }
        guard needsTap(id) else {
            if allowRemoval { taps.removeValue(forKey: id) }
            else { taps[id]?.setGain(1) }
            return
        }
        guard let device = outputDevice, let uid = outputUID else { return }

        if let tap = taps[id], tap.processObjectIDs == app.processObjectIDs, tap.outputDeviceUID == uid {
            tap.setGain(gain(for: id))
            return
        }

        // (Re)build: new app, its set of processes changed, or the output device changed.
        taps.removeValue(forKey: id)
        if AudioCapturePermission.isDenied {
            errors[id] = "MacMixer needs the System Audio Recording permission. Allow it in Privacy & Security, then quit and reopen MacMixer."
            return
        }
        do {
            taps[id] = try AppTap(processObjectIDs: app.processObjectIDs,
                                  outputDevice: device,
                                  outputDeviceUID: uid,
                                  initialGain: gain(for: id))
            errors.removeValue(forKey: id)
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    /// Browser tabs/sites (see AudioAppDiscovery) are keyed by raw PID, not a
    /// stable bundle ID: the same key can belong to a totally different site
    /// next time that helper process is reused (e.g. Chrome's shared Audio
    /// Service), so unlike a real app, it's never safe to treat "has played
    /// before" as "same source, just paused" — or to remember a volume for it
    /// across process lifetimes.
    private func isEphemeral(_ id: String) -> Bool { id.hasPrefix("pid-") }

    private func save() {
        defaults.set(volumes.filter { !isEphemeral($0.key) }.mapValues { Double($0) }, forKey: volumesKey)
        defaults.set(Array(muted.filter { !isEphemeral($0) }), forKey: mutedKey)
    }

    // MARK: - Discovering apps

    func refresh() {
        let scanned = AudioAppDiscovery.scan(labelBrowserTabs: showTabTitles)
        for app in scanned where app.isPlaying && !isEphemeral(app.id) { seenPlaying.insert(app.id) }
        let aliveIDs = Set(scanned.map(\.id))
        seenPlaying.formIntersection(aliveIDs)

        // A dead ephemeral row's custom volume/mute would otherwise sit around
        // and get inherited by whatever unrelated source reuses that PID next.
        let deadEphemeral = Set(volumes.keys).union(muted).filter { isEphemeral($0) && !aliveIDs.contains($0) }
        if !deadEphemeral.isEmpty {
            for id in deadEphemeral {
                volumes.removeValue(forKey: id)
                muted.remove(id)
            }
            save()
        }

        let visible = scanned
            .filter { app in
                isEphemeral(app.id) ? (app.isPlaying || needsTap(app.id)) : (seenPlaying.contains(app.id) || needsTap(app.id))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if visible != apps { apps = visible }

        // Drop taps for apps that quit; keep taps in sync with process changes.
        for id in taps.keys where !aliveIDs.contains(id) {
            taps.removeValue(forKey: id)
            errors.removeValue(forKey: id)
        }
        for app in apps where needsTap(app.id) {
            if let tap = taps[app.id], tap.processObjectIDs == app.processObjectIDs, tap.outputDeviceUID == outputUID {
                continue
            }
            if errors[app.id] != nil && taps[app.id] == nil { continue } // don't retry every second
            updateTap(for: app.id, allowRemoval: true)
        }
        releaseBrokenTaps()
    }

    /// A tap mutes its app at the source even when the replay side is broken, which
    /// silences the app. Give up on taps whose device never started, and on taps that
    /// only deliver silence for an app the user wants to hear.
    private func releaseBrokenTaps() {
        let now = Date()
        for app in apps {
            guard let tap = taps[app.id] else { continue }
            // An idle app's tap may have nothing to drive it, so only judge apps that are playing.
            if !tap.hasRun && app.isPlaying && now.timeIntervalSince(tap.createdAt) >= 2 {
                taps.removeValue(forKey: app.id)
                errors[app.id] = "Couldn't route \(app.name)'s audio through MacMixer (its audio device never started), so it's playing at normal volume."
                continue
            }
            guard app.isPlaying, gain(for: app.id) > 0, !tap.hasSeenSignal else {
                tap.silentPlayingSince = nil
                continue
            }
            let since = tap.silentPlayingSince ?? now
            tap.silentPlayingSince = since
            if now.timeIntervalSince(since) >= 8 {
                taps.removeValue(forKey: app.id)
                errors[app.id] = "MacMixer was only receiving silence from \(app.name), so it's playing at normal volume."
            }
        }
    }

    // MARK: - Output device & master volume

    /// Coalesces bursts of "default output device changed" notifications into one
    /// rebuild. A Bluetooth headset switching profiles (e.g. opening the mic for a
    /// call) fires this property several times in quick succession as macOS
    /// renegotiates the route; tearing down and recreating every tap on each of
    /// those intermediate notifications — while another tap's Core Audio IO thread
    /// may still be mid-callback — is what crashed MacMixer. Waiting for the route
    /// to settle before rebuilding avoids that pile-up.
    private func scheduleOutputDeviceChanged() {
        outputChangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.outputDeviceChanged() }
        outputChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func outputDeviceChanged() {
        updateOutputDevice()
        // Every route points at the old device; rebuild them all.
        let ids = Array(taps.keys)
        taps.removeAll()
        errors.removeAll()
        for id in ids { updateTap(for: id, allowRemoval: true) }
        refresh()
    }

    private func updateOutputDevice() {
        outputDevice = CA.defaultOutputDevice
        if let device = outputDevice {
            outputUID = CA.deviceUID(device)
            outputName = CA.deviceName(device) ?? "Output"
        } else {
            outputUID = nil
            outputName = "No output device"
        }
        readMasterVolume()
    }

    private let outputScope = kAudioObjectPropertyScopeOutput

    /// Volume can live on the main element or on each channel, depending on the device.
    private func volumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if CA.isSettable(device, kAudioDevicePropertyVolumeScalar, scope: outputScope, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        let channels: [AudioObjectPropertyElement] = [1, 2]
        return channels.filter {
            CA.isSettable(device, kAudioDevicePropertyVolumeScalar, scope: outputScope, element: $0)
        }
    }

    func readMasterVolume() {
        guard let device = outputDevice else {
            masterAdjustable = false
            return
        }
        let elements = volumeElements(device)
        let adjustable = !elements.isEmpty
        if masterAdjustable != adjustable { masterAdjustable = adjustable }
        if adjustable {
            let values = elements.compactMap {
                CA.get(device, kAudioDevicePropertyVolumeScalar, scope: outputScope, element: $0, initial: Float32(0))
            }
            if !values.isEmpty {
                let v = values.reduce(0, +) / Float(values.count)
                if abs(v - masterVolume) > 0.005 { masterVolume = v }
            }
        }
        let m = (CA.get(device, kAudioDevicePropertyMute, scope: outputScope, initial: UInt32(0)) ?? 0) != 0
        if m != masterMuted { masterMuted = m }
    }

    func setMasterVolume(_ value: Float) {
        guard let device = outputDevice else { return }
        let v = Float32(max(0, min(1, value)))
        for element in volumeElements(device) {
            CA.set(device, kAudioDevicePropertyVolumeScalar, scope: outputScope, element: element, value: v)
        }
        masterVolume = v
    }

    func toggleMasterMute() {
        guard let device = outputDevice,
              CA.isSettable(device, kAudioDevicePropertyMute, scope: outputScope) else { return }
        let newValue: UInt32 = masterMuted ? 0 : 1
        if CA.set(device, kAudioDevicePropertyMute, scope: outputScope, value: newValue) {
            masterMuted = newValue != 0
        }
    }

    // MARK: - Quitting

    /// Taps mute their apps at the source, so destroying them instantly un-mutes every
    /// muted or turned-down app at its full volume. Duck the output device first,
    /// release the taps while it's silent, then fade the output back in.
    func prepareForQuit(then done: @escaping () -> Void) {
        guard !quitting else { return }
        quitting = true
        timer?.invalidate()
        timer = nil

        readMasterVolume()
        guard !taps.isEmpty, masterAdjustable, !masterMuted else {
            taps.removeAll()
            done()
            return
        }

        let original = masterVolume
        setMasterVolume(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            taps.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                fadeMasterVolume(to: original, over: 3, then: done)
            }
        }
    }

    private func fadeMasterVolume(to target: Float, over duration: TimeInterval, then done: @escaping () -> Void) {
        let steps = 40
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) { [self] in
                let t = Float(i) / Float(steps)
                setMasterVolume(target * t * t)
                if i == steps { done() }
            }
        }
    }

    // MARK: - Misc

    var menuBarSymbol: String {
        masterMuted ? "speaker.slash.fill" : "slider.horizontal.3"
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MacMixer: launch at login failed: \(error)")
        }
    }

    func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
