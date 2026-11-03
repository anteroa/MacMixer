import ApplicationServices
import AppKit

/// Reads which tab is actually making sound in a supported browser, via the
/// Accessibility API — the same tree VoiceOver uses. Chromium-based browsers
/// annotate a tab's accessible title with "- Audio playing" the moment it
/// starts producing sound, which is the only place that fact exists outside
/// the browser itself (it isn't in any Core Audio property, and AppleScript's
/// tab object has no such attribute either). This is read-only, local, and
/// needs the user to grant Accessibility access once; until they do, callers
/// just get nothing back and fall back to generic names.
enum BrowserTabs {
    private static var hasPrompted = false

    /// Call once, the first time a label might actually be useful, so we only
    /// ever show the system's permission prompt a single time per launch.
    static func requestAccessIfNeeded() {
        guard !hasPrompted else { return }
        hasPrompted = true
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private static var isTrusted: Bool { AXIsProcessTrustedWithOptions(nil) }

    /// Clean titles (Chromium's own "- Pinned" / "- Memory usage" decorations
    /// stripped) of every tab in `ownerPID`'s windows that's currently audible,
    /// in on-screen order.
    static func audiblePlayingTitles(ownerPID: pid_t) -> [String] {
        guard isTrusted else { return [] }
        let app = AXUIElementCreateApplication(ownerPID)
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var titles: [String] = []
        for window in windows { collect(window, depth: 0, into: &titles) }
        return titles
    }

    private static func collect(_ element: AXUIElement, depth: Int, into titles: inout [String]) {
        guard depth < 16 else { return }
        if let role = attr(element, kAXRoleAttribute) as? String, role == "AXRadioButton",
           let title = attr(element, kAXTitleAttribute) as? String, title.contains("Audio playing") {
            titles.append(clean(title))
        }
        for child in (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            collect(child, depth: depth + 1, into: &titles)
        }
    }

    /// Strips Chromium's own accessible-name decorations, e.g.
    /// "Some Video - YouTube - Audio playing - Memory usage - 480 MB"
    /// → "Some Video - YouTube".
    private static func clean(_ raw: String) -> String {
        var s = raw
        for marker in [" - Audio playing", " - Muted", " - Pinned"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        for marker in [" - Memory usage", " - High memory usage"] {
            if let range = s.range(of: marker) { s = String(s[..<range.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
