import AppKit
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            masterRow
            Divider()
            appList
            if !model.errors.isEmpty { errorBanner }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("MacMixer").font(.headline)
            Spacer()
            Label(model.outputName, systemImage: "hifispeaker")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var masterRow: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleMasterMute) {
                Image(systemName: model.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .help(model.masterMuted ? "Unmute output" : "Mute output")

            Slider(value: Binding(
                get: { Double(model.masterVolume) },
                set: { model.setMasterVolume(Float($0)) }
            ), in: 0...1)
            .disabled(!model.masterAdjustable)

            Text(model.masterAdjustable ? percent(model.masterVolume) : "—")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
        .opacity(model.masterMuted ? 0.5 : 1)
    }

    @ViewBuilder
    private var appList: some View {
        if model.apps.isEmpty {
            Text("No apps are playing sound right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.apps) { app in
                        AppRow(app: app)
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Some apps couldn't be controlled.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("MacMixer needs the System Audio Recording permission. Allow it in Privacy & Security, then quit and reopen MacMixer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Privacy & Security", action: model.openPrivacySettings)
                Button("Restore Normal Audio", action: model.restoreNormalAudio)
                    .help("Resets the affected apps to 100% volume, unmuted — gets your sound back without granting the permission.")
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $model.showTabTitles) {
                Text("Show browser tab titles")
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("Needs the Accessibility permission (it can read what's on screen), "
                + "so MacMixer only asks for it once you turn this on.")

            HStack {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
                    .keyboardShortcut("q")
            }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var model: MixerModel
    let app: AudioApp

    var body: some View {
        let muted = model.isMuted(app.id)
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name).font(.caption).lineLimit(1)
                    if app.isPlaying && !muted {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Slider(value: Binding(
                    get: { Double(model.volume(for: app.id)) },
                    set: { model.setVolume(Float($0), for: app.id) }
                ), in: 0...1, onEditingChanged: { editing in
                    if !editing { model.finishEditing(app.id) }
                })
                .controlSize(.small)
            }

            Button { model.toggleMute(app.id) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")

            Text(percent(model.volume(for: app.id)))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
        .opacity(muted ? 0.5 : (app.isPlaying ? 1 : 0.7))
        .help(model.errors[app.id] ?? "")
    }
}

private func percent(_ value: Float) -> String {
    "\(Int((value * 100).rounded()))%"
}
