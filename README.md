# MacMixer

A free, open-source **per-app volume mixer for macOS**, like the Volume Mixer on Windows.
Click the menu bar icon to get a volume slider and a mute button for every app that's
making sound (Spotify, your browser, Discord, a game), plus a master volume for the output device.

- No virtual audio driver, no kernel extension, nothing to install system-wide.
- Apps left at 100% aren't touched at all. Their audio goes straight to your speakers as usual.
- Volumes are remembered per app, across launches.
- No network access, no telemetry, no audio is ever recorded or saved.

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
  AudioAppDiscovery.swift  finds audio processes and groups helpers under their app
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
