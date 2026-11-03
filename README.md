# MacMixer

A free, open-source **per-app volume mixer for macOS**, like the Volume Mixer on Windows.
Click the menu bar icon to get a volume slider and a mute button for every app that's
making sound (Spotify, your browser, Discord, a game), plus a master volume for the output device.

- No virtual audio driver, no kernel extension, nothing to install system-wide.
- Apps left at 100% aren't touched at all. Their audio goes straight to your speakers as usual.
- Volumes are remembered per app, across launches.
- No network access, no telemetry, no audio is ever recorded or saved.
- Playing two different things in two browser tabs (Chrome, Safari, Firefox, Edge, Brave,
  Opera, Vivaldi, Arc)? When the browser happens to run them as separate OS processes,
  each gets its own slider instead of one shared "Chrome" slider for everything — see
  [Browser tabs](#browser-tabs) below for what that depends on, and the optional
  **Show browser tab titles** toggle that labels them with the real tab name.

Requires **macOS 14.2 (Sonoma) or later**.

## Install

1. Download `MacMixer-x.y.z.zip` from the [latest release](https://github.com/anteroa/MacMixer/releases/latest).
2. Unzip it and drag **MacMixer.app** into your **Applications** folder.
3. The app isn't notarized by Apple yet, so the first launch needs one extra step. Either:
   - Open it, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**, or
   - Run this once in Terminal:
     ```sh
     xattr -dr com.apple.quarantine /Applications/MacMixer.app
     ```
4. The first time you move an app's slider, macOS asks for **System Audio Recording**
   permission. Allow it. That permission is what lets MacMixer adjust other apps' audio.

> If you deny the permission, apps you've adjusted may go quiet. Drag their slider back to 100%,
> or allow MacMixer under **System Settings → Privacy & Security → Screen & System Audio Recording**
> and reopen it.

That's everything MacMixer needs to work. One more permission is available but **entirely
optional** — see below.

### Browser tabs

MacMixer separates browser tabs by OS process, not by tab — because that's the most
specific thing Core Audio actually exposes. Whether two tabs end up as two sliders or
one shared slider depends entirely on whether the browser happens to run them as
separate processes, which MacMixer has no control over and can't force:

- Often, each tab/site does get its own process, and its own slider.
- But browsers also centralize audio through one shared internal process in common
  cases (e.g. Chrome's "Audio Service" utility process) — when that happens, every tab
  routed through it shows up as **one slider that controls all of them together**,
  because by the time the audio reaches the OS, it's already been mixed into a single
  stream. No app — including this one, including a browser extension — can un-mix audio
  that's already been combined before it leaves the browser.

Turn on **Show browser tab titles** in the popover and MacMixer labels each slider with
the real tab title(s) instead of a generic "Google Chrome (2)", read live from the
browser's accessibility tree — the same mechanism VoiceOver uses, not a network request
and not a browser extension. When a slider is shared by more than one tab, every title
is shown, joined together, so you can tell it's shared rather than see one tab's name
silently stand in for several. Nothing is recorded, saved, or sent anywhere; it's only
ever read to label a slider.

This needs the **Accessibility** permission, which is a much bigger ask than the
audio-only access the rest of the app needs — it can technically read anything on
screen — so it's off by default, and macOS only asks you for it the moment you turn
the toggle on. Leave it off and MacMixer works exactly the same, just with generic
numbered labels for browser tabs instead of real titles.

## Build from source

All you need is the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't required.

```sh
git clone https://github.com/anteroa/MacMixer.git
cd MacMixer
make run        # build and launch
make install    # build and copy to /Applications
```

Local builds are signed ad-hoc, so macOS may ask for the audio permission again after each rebuild.

## How it works

macOS 14.2 added **Core Audio process taps**, an Apple API that can capture the audio of
specific processes. When you lower an app below 100% (or mute it), MacMixer:

1. creates a process tap on all of that app's processes (including helpers, like browser tabs)
   with *muted when tapped*, which silences the app's normal output,
2. wraps the tap in a private aggregate device clocked by your current output device,
3. copies the tapped audio to the output in a real-time callback, multiplied by your volume.

When the slider goes back to 100% and the app is unmuted, the tap is removed and the app
plays directly again. Switching outputs (for example, plugging in headphones) rebuilds the routes automatically.

```
Sources/MacMixer/
  MacMixerApp.swift        menu bar app entry point
  MixerView.swift          the SwiftUI popover
  MixerModel.swift         state, saved volumes, output device, master volume
  AudioAppDiscovery.swift  finds audio processes; groups helpers under their app,
                           except browser tabs/sites, which get their own row
  BrowserTabs.swift        optional: reads live tab titles via Accessibility
  AppTap.swift             process tap + aggregate device + real-time gain
  CoreAudioHelpers.swift   small wrappers over the Core Audio C API
```

## Releasing

Push a version tag and GitHub Actions builds a universal (Apple silicon + Intel) app and
attaches the zip to a new release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

## Roadmap

- [x] App icon
- [ ] Signed + notarized builds (no "Open Anyway" step)
- [ ] Homebrew cask (`brew install --cask macmixer`)
- [ ] Per-app output device routing
- [ ] Volume boost above 100%
- [ ] Keyboard shortcuts

## Contributing

Issues and pull requests are welcome. Please keep the audio callback in `AppTap.swift`
real-time safe: no allocation, locks, or Objective-C/Swift object calls inside it.

## License

[MIT](LICENSE)
