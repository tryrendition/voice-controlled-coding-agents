import AVFoundation
import AudioToolbox
import Foundation

// Does macOS voice processing remove our own voice from our own microphone,
// on a unit we pin to a device ourselves?
//
// The question behind it: the manager cannot be interrupted while it speaks,
// because the only defence against hearing itself is a gate that feeds the
// transcriber silence. Real echo cancellation would remove the gate and let a
// person cut in mid-sentence. The reason we have not used it is one day's
// scar: on 12 Aug AVAudioEngine's inputNode built a CADefaultDeviceAggregate
// over the default devices and dragged the AirPods into SCO. A raw
// kAudioUnitSubType_VoiceProcessingIO unit is not AVAudioEngine; TN2091's
// sequence applies to it too, so it can be pinned. This measures both halves:
// which device it ends up on, and how much of the played sound survives into
// the captured signal.
//
//   swiftc -O tools/aec-probe/main.swift -o /tmp/aec-probe && /tmp/aec-probe

let inRate = 48000.0
var played = [Float](repeating: 0, count: Int(inRate * 3))     // 3 s of tone out
for i in played.indices { played[i] = 0.35 * sinf(2 * .pi * 440 * Float(i) / Float(inRate)) }

final class Probe {
    var rate = inRate
    var captureChannels = 1
    var renderChannels = 1
    var unit: AudioUnit?
    var playhead = 0
    var playing = false
    var sumSquares = [Double](repeating: 0, count: 2)   // 0 = quiet, 1 = while playing
    var samples = [Int](repeating: 0, count: 2)
    var buffer: AudioBufferList?

    func device(_ selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr else { throw NSError(domain: "probe", code: Int(status)) }
        return id
    }

    func name(_ id: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        return name as String
    }

    /// Every device with input streams, and every device with output streams.
    static func devices() -> [(id: AudioDeviceID, name: String, ins: Int, outs: Int)] {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        let probe = Probe()
        return ids.map { id in
            (id, probe.name(id), Probe.channels(id, kAudioObjectPropertyScopeInput), Probe.channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, data) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func start(pinTo input: AudioDeviceID?) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: "probe", code: -1, userInfo: [NSLocalizedDescriptionKey: "no VPIO component"])
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "instance")
        self.unit = unit
        var on: UInt32 = 1
        try check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, UInt32(MemoryLayout<UInt32>.size)), "enable input")
        try check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, UInt32(MemoryLayout<UInt32>.size)), "enable output")
        // TN2091's move, on a voice-processing unit: name the device rather
        // than letting it find the default. VPIO uses one device for both
        // busses, so this pins the speaker too.
        if var pinned = input {
            try check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &pinned, UInt32(MemoryLayout<AudioDeviceID>.size)), "pin device")
        }

        // Take the unit's own formats rather than imposing ours: voice
        // processing refused a 16 kHz mono client format outright (-10875).
        try check(AudioUnitInitialize(unit!), "initialize")
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &hardware, &size), "read capture format")
        rate = hardware.mSampleRate
        captureChannels = Int(hardware.mChannelsPerFrame)
        var outFormat = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFormat, &size), "read render format")
        renderChannels = Int(outFormat.mChannelsPerFrame)
        played = (0..<Int(outFormat.mSampleRate * 3)).map { 0.35 * sinf(2 * .pi * 440 * Float($0) / Float(outFormat.mSampleRate)) }

        var input = AURenderCallbackStruct(inputProc: { ref, flags, stamp, bus, frames, _ in
            let probe = Unmanaged<Probe>.fromOpaque(ref).takeUnretainedValue()
            return probe.captured(flags, stamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &input, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")

        var render = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, data in
            let probe = Unmanaged<Probe>.fromOpaque(ref).takeUnretainedValue()
            return probe.render(frames, data)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")

        try check(AudioOutputUnitStart(unit!), "start")
    }

    func render(_ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let data else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(data)
        let start = playhead
        for buffer in list {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            var head = start
            for i in 0..<Int(frames) * channels {
                if playing, head < played.count {
                    out[i] = played[head]
                    if (i + 1) % channels == 0 { head += 1 }
                } else {
                    out[i] = 0
                }
            }
            playhead = head
        }
        return noErr
    }

    func captured(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                  _ stamp: UnsafePointer<AudioTimeStamp>,
                  _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let bytes = Int(frames) * 4 * captureChannels
        var list = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(captureChannels), mDataByteSize: UInt32(bytes),
                                  mData: malloc(bytes)))
        defer { free(list.mBuffers.mData) }
        let status = AudioUnitRender(unit, flags, stamp, bus, frames, &list)
        guard status == noErr, let samplesIn = list.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return status }
        let slot = playing ? 1 : 0
        for i in 0..<Int(frames) * captureChannels {
            let v = Double(samplesIn[i]); sumSquares[slot] += v * v
        }
        samples[slot] += Int(frames) * captureChannels
        return noErr
    }

    func rms(_ slot: Int) -> Double {
        samples[slot] == 0 ? 0 : (sumSquares[slot] / Double(samples[slot])).squareRoot()
    }

    func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw NSError(domain: "probe", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(status)"])
        }
    }

    func currentDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return id
    }
}

print("devices with audio streams:")
for d in Probe.devices() where d.ins > 0 || d.outs > 0 {
    print("  \(d.id)\t in \(d.ins)\t out \(d.outs)\t \(d.name)")
}

func attempt(_ label: String, _ pin: AudioDeviceID?) {
    let probe = Probe()
    do {
        try probe.start(pinTo: pin)
        let landed = probe.currentDevice()
        print("\n\(label): initialized on \(landed) \(probe.name(landed)), \(Int(probe.rate)) Hz, capture \(probe.captureChannels) ch")
        Thread.sleep(forTimeInterval: 1.5)
        probe.playing = true
        Thread.sleep(forTimeInterval: 3.0)
        probe.playing = false
        Thread.sleep(forTimeInterval: 0.2)
        if let unit = probe.unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        let quiet = probe.rms(0), during = probe.rms(1)
        let ratio = quiet > 0 ? during / quiet : 0
        print(String(format: "  room rms %.5f, rms while our own tone plays %.5f, ratio %.2f", quiet, during, ratio))
        print("  \(ratio < 3 ? "the echo is cancelled" : "the echo survives: a gate would still be needed")")
    } catch {
        print("\n\(label): \(error.localizedDescription)")
        if let unit = probe.unit { AudioComponentInstanceDispose(unit) }
    }
}

let system = Probe()
do {
    let defaultInput = try system.device(kAudioHardwarePropertyDefaultInputDevice)
    let defaultOutput = try system.device(kAudioHardwarePropertyDefaultOutputDevice)
    print("\ndefault input:  \(defaultInput) \(system.name(defaultInput))")
    print("default output: \(defaultOutput) \(system.name(defaultOutput))")
    attempt("VPIO, unpinned (its own choice)", nil)
    attempt("VPIO, pinned to the default input", defaultInput)
    for d in Probe.devices() where d.ins > 0 && d.outs > 0 {
        attempt("VPIO, pinned to \(d.name) (in and out on one device)", d.id)
    }
} catch {
    print("probe failed: \(error.localizedDescription)")
    exit(1)
}
