import AudioToolbox
import CoreAudio
import Foundation

/// Gain shared between the main thread (writer) and the real-time audio thread (reader).
/// Plain aligned Float32 loads/stores are atomic on Apple silicon and Intel.
struct GainState {
    var target: Float32
    var current: Float32
    var sawSignal: Bool = false
    var didRun: Bool = false
}

enum AudioCapturePermission {
    /// True only when macOS has explicitly denied System Audio Recording. Without it,
    /// a process tap still mutes the app but its aggregate device never runs, so
    /// tapping would just silence the app. Uses the TCC SPI (as Apple's AudioCap
    /// sample does); if that's unavailable, MixerModel's dead-tap check is the fallback.
    static var isDenied: Bool {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return false }
        let preflight = unsafeBitCast(symbol, to: Preflight.self)
        return preflight("kTCCServiceAudioCapture" as CFString, nil) == 1
    }
}

enum TapError: LocalizedError {
    case createTap(OSStatus)
    case createAggregate(OSStatus)
    case createIOProc(OSStatus)
    case start(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createTap(let s): return "Couldn't tap this app's audio (error \(s))."
        case .createAggregate(let s): return "Couldn't create the audio route (error \(s))."
        case .createIOProc(let s): return "Couldn't start audio processing (error \(s))."
        case .start(let s): return "Couldn't start audio playback (error \(s))."
        }
    }
}

/// Captures every audio process belonging to one app, silences its normal output,
/// and re-plays the audio on the output device with our own gain applied.
///
///   app processes ──► process tap (muted when tapped) ──► private aggregate device
///                                                          │ IOProc: out = in × gain
///                                                          ▼
///                                                    real output device
final class AppTap {
    let processObjectIDs: Set<AudioObjectID>
    let outputDeviceUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let gain: UnsafeMutablePointer<GainState>

    let createdAt = Date()

    /// Main thread only; see MixerModel.releaseBrokenTaps.
    var silentPlayingSince: Date?

    var hasSeenSignal: Bool { gain.pointee.sawSignal }
    var hasRun: Bool { gain.pointee.didRun }

    init(processObjectIDs: Set<AudioObjectID>,
         outputDevice: AudioDeviceID,
         outputDeviceUID: String,
         initialGain: Float32) throws {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        gain = .allocate(capacity: 1)
        gain.initialize(to: GainState(target: initialGain, current: initialGain))

        do {
            try start(outputDevice: outputDevice)
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
        gain.deinitialize(count: 1)
        gain.deallocate()
    }

    /// Linear amplitude, 0...1. Applied smoothly over the next audio buffer.
    func setGain(_ value: Float32) {
        gain.pointee.target = value
    }

    // MARK: - Setup / teardown

    private func start(outputDevice: AudioDeviceID) throws {
        // 1. The tap: a stereo mix of all of this app's processes, muted at the source.
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        // Owned by this process, so a crash can't leave an app muted with nobody replaying it.
        description.isPrivate = true
        description.name = "MacMixer"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTap)
        guard err == noErr else { throw TapError.createTap(err) }
        tapID = newTap

        // 2. A private aggregate device that has the real output device as its clock
        //    and the tap as an extra input.
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacMixer Route",
            kAudioAggregateDeviceUIDKey: "MacMixer-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(config as CFDictionary, &newAggregate)
        guard err == noErr else { throw TapError.createAggregate(err) }
        aggregateID = newAggregate

        // 3. The real-time callback. Runs on Core Audio's IO thread: no locks,
        //    no allocation, no Swift objects — just pointer math.
        let gainPtr = gain
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            GainRenderer.render(input: inInput, output: outOutput, gain: gainPtr)
        }
        guard err == noErr, let procID else { throw TapError.createIOProc(err) }
        ioProcID = procID

        // If the output device also has inputs (e.g. a headset mic), don't open them —
        // we only want the tap. Otherwise Bluetooth headsets drop to call quality.
        disableDeviceInputStreams(outputDevice: outputDevice, procID: procID)

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw TapError.start(err) }
    }

    private func disableDeviceInputStreams(outputDevice: AudioDeviceID, procID: AudioDeviceIOProcID) {
        let deviceInputs = CA.streamCount(outputDevice, scope: kAudioObjectPropertyScopeInput)
        guard deviceInputs > 0 else { return }
        let totalInputs = CA.streamCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard totalInputs > deviceInputs else { return }

        // AudioHardwareIOProcStreamUsage is variable-length:
        //   void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[mNumberStreams];
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let byteCount = headerSize + totalInputs * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { raw.deallocate() }

        // AudioDeviceIOProcID is a C function pointer; store its address.
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self),
                       as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(totalInputs),
                       toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for i in 0..<totalInputs {
            // Sub-device streams come first, taps last.
            let on: UInt32 = i < deviceInputs ? 0 : 1
            raw.storeBytes(of: on, toByteOffset: headerSize + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        _ = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(byteCount), raw)
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

/// Real-time safe copy-with-gain from the tap's input buffer to the device's output buffers.
enum GainRenderer {
    static func render(input: UnsafePointer<AudioBufferList>,
                       output: UnsafeMutablePointer<AudioBufferList>,
                       gain: UnsafeMutablePointer<GainState>) {
        gain.pointee.didRun = true
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

        // Start from silence.
        for buffer in outBuffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // The tap's stream is the last active input buffer.
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var tapBuffer: AudioBuffer?
        for buffer in inBuffers.reversed() where buffer.mData != nil && buffer.mNumberChannels > 0 {
            tapBuffer = buffer
            break
        }
        guard let tap = tapBuffer, let inData = tap.mData else { return }

        let inChannels = Int(tap.mNumberChannels)
        let inFrames = Int(tap.mDataByteSize) / (MemoryLayout<Float32>.size * inChannels)
        guard inFrames > 0 else { return }
        let src = inData.assumingMemoryBound(to: Float32.self)

        if !gain.pointee.sawSignal {
            for i in 0..<(inFrames * inChannels) where src[i] != 0 {
                gain.pointee.sawSignal = true
                break
            }
        }

        let start = gain.pointee.current
        let target = gain.pointee.target
        if start == 0 && target == 0 {
            return // muted: leave silence
        }

        // Write the stereo signal into the first two output channels, wherever they live
        // (one interleaved buffer, or two mono buffers).
        var channelBase = 0
        for buffer in outBuffers {
            guard channelBase < 2 else { break }
            let outChannels = Int(buffer.mNumberChannels)
            guard outChannels > 0, let outData = buffer.mData else {
                channelBase += outChannels
                continue
            }
            let dst = outData.assumingMemoryBound(to: Float32.self)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
            let frames = min(inFrames, outFrames)
            guard frames > 0 else {
                channelBase += outChannels
                continue
            }
            let step = (target - start) / Float32(frames)

            for c in 0..<outChannels {
                let globalChannel = channelBase + c
                if globalChannel >= 2 { break }
                let srcChannel = globalChannel % inChannels
                var g = start
                for f in 0..<frames {
                    dst[f * outChannels + c] = src[f * inChannels + srcChannel] * g
                    g += step
                }
            }
            channelBase += outChannels
        }

        gain.pointee.current = target
    }
}
