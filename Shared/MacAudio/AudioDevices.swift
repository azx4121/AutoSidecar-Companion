#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

/// The devices published by WiredDisplayAudio.driver (D-017, D-032): two
/// loopback channels, each split into a visible one-way device for apps and a
/// hidden one for the host, so apps cannot pick them the wrong way round.
public enum WiredAudioDevice: String, CaseIterable, Sendable {
    /// Output only, visible: apps play here.
    case speaker = "dev.wireddisplay.audio.speaker"
    /// Input only, hidden: the host records what apps played into `speaker`.
    case speakerTap = "dev.wireddisplay.audio.speaker.tap"
    /// Input only, visible: apps record the iPad microphone here.
    case microphone = "dev.wireddisplay.audio.microphone"
    /// Output only, hidden: the host plays iPad microphone audio here.
    case microphoneFeed = "dev.wireddisplay.audio.microphone.feed"
}

public struct AudioDeviceInfo: Sendable, Equatable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var inputChannels: Int
    public var outputChannels: Int
    /// kAudioDeviceTransportType… (Bluetooth, USB, BuiltIn, Virtual, …).
    public var transport: UInt32 = 0
}

public enum AudioDevices {
    public struct SpeakerLoopback: Sendable {
        public let captureDevice: AudioDeviceID
        public let outputDevice: AudioDeviceID
        public let usesSharedBlackHole: Bool
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notInstalled(String)
        case missingSpeakerLoopback
        case coreAudio(String, OSStatus)

        public var description: String {
            switch self {
            case .notInstalled(let uid):
                return "audio device \(uid) not found: install WiredDisplayAudio.driver (scripts/build-audio-driver.sh)"
            case .missingSpeakerLoopback:
                return "neither BlackHole 2ch nor the WiredDisplay speaker loopback is available"
            case .coreAudio(let what, let status): return "CoreAudio \(what) failed: \(status)"
            }
        }
    }

    public static func all() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { id in
            AudioDeviceInfo(id: id, name: string(id, kAudioObjectPropertyName) ?? "?",
                            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "?",
                            inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
                            outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput),
                            transport: uint(id, kAudioDevicePropertyTransportType))
        }
    }

    /// By UID, which also finds hidden devices (they are not in `all()`).
    public static func find(_ device: WiredAudioDevice) throws -> AudioDeviceID {
        guard let id = find(uid: device.rawValue) else { throw Error.notInstalled(device.rawValue) }
        return id
    }

    public static func speakerLoopback(preferBlackHole: Bool) throws -> SpeakerLoopback {
        if preferBlackHole, let blackHole = find(uid: "BlackHole2ch_UID") {
            return SpeakerLoopback(captureDevice: blackHole, outputDevice: blackHole, usesSharedBlackHole: true)
        }
        do {
            return try SpeakerLoopback(captureDevice: find(.speakerTap), outputDevice: find(.speaker),
                                       usesSharedBlackHole: false)
        } catch {
            if preferBlackHole { throw Error.missingSpeakerLoopback }
            throw error
        }
    }

    private static func find(uid value: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid = value as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Verify the installed BlackHole's current input format without changing its
    /// shared sample rate or assuming this Mac exclusively owns the device.
    public static func hasStereoFloatInput(_ device: AudioDeviceID, sampleRate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format) == noErr else { return false }
        return format.mSampleRate == sampleRate && format.mFormatID == kAudioFormatLinearPCM &&
            format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 &&
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
            format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
    }

    /// Points an AVAudioEngine's input or output node at a specific device.
    /// Must be called before the engine starts.
    public static func bind(_ node: AVAudioIONode, to device: AudioDeviceID) throws {
        guard let unit = node.audioUnit else { throw Error.coreAudio("node has no audio unit", -1) }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw Error.coreAudio("set current device", status) }
    }

    /// Requests a smaller IO buffer for this process's use of `device`
    /// (lower latency). The HAL clamps to the device's allowed range.
    @discardableResult
    public static func setBufferFrameSize(_ device: AudioDeviceID, frames: UInt32) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var requested = frames
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &requested)
        return bufferFrameSize(device)
    }

    public static func bufferFrameSize(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var actual: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &actual)
        return actual
    }

    /// The system default output (`input: false`) or input device.
    public static func defaultDevice(input: Bool) -> AudioDeviceID {
        uint(AudioObjectID(kAudioObjectSystemObject),
             input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }

    @discardableResult
    public static func setDefaultDevice(_ device: AudioDeviceID, input: Bool) -> Bool {
        setSystemDevice(device, selector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static var defaultSystemOutput: AudioDeviceID {
        uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    @discardableResult
    public static func setDefaultSystemOutput(_ device: AudioDeviceID) -> Bool {
        setSystemDevice(device, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    private static func setSystemDevice(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    /// The built-in output's current data source is the headphone jack.
    public static func isHeadphoneJack(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864_706E // 'hdpn'
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
#endif
