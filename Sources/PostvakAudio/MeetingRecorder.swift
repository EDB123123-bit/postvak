import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

public enum RecorderError: Error, LocalizedError {
    case osStatus(String, OSStatus)
    case micDenied
    case alreadyRecording
    case notRecording
    public var errorDescription: String? {
        switch self {
        case .osStatus(let w, let s): "\(w) failed with code \(s)."
        case .micDenied: "Postvak has no microphone permission. Turn it on in System Settings, Privacy & Security, Microphone."
        case .alreadyRecording: "A recording is already running."
        case .notRecording: "No recording is running."
        }
    }
}

/// Records all system audio into a file through a Core Audio process tap. Needs no virtual driver or screen permission.
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "postvak.systemaudio", qos: .userInitiated)

    func start(writingTo url: URL) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "Postvak"
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw RecorderError.osStatus("Creating the system audio tap", status) }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Postvak Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { cleanup(); throw RecorderError.osStatus("Creating the capture device", status) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { cleanup(); throw RecorderError.osStatus("Reading the tap format", status) }
        // The callback delivers audio at the capture device's own rate, which can differ from what the tap reports:
        // MacBook speakers run at 44.1 kHz while the tap says 48 kHz. Writing those samples as 48 kHz made every call
        // track play 9% fast and drift away from the microphone.
        if let rate = Self.nominalRate(aggregateID), rate > 0 { asbd.mSampleRate = rate }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup(); throw RecorderError.osStatus("Reading the tap format", status)
        }
        let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        file = output

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let file = self.file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            try? file.write(from: buffer)
        }
        guard status == noErr else { cleanup(); throw RecorderError.osStatus("Starting the audio callback", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { cleanup(); throw RecorderError.osStatus("Starting capture", status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID { AudioDeviceStop(aggregateID, procID) }
        // Runs after the last callback, then closes the file.
        queue.sync { file = nil }
        cleanup()
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr else { throw RecorderError.osStatus("Finding the output device", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
        guard status == noErr, let uid else { throw RecorderError.osStatus("Reading the output device id", status) }
        return uid.takeRetainedValue() as String
    }
}

/// Records the microphone. Converts to a fixed format, so swapping to AirPods mid-call keeps one valid file.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    func start(writingTo url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: target.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try installAndStart()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            try? self?.installAndStart()
        }
    }

    private func installAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        lock.lock(); converter = AVAudioConverter(from: format, to: target); lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.write(buffer) }
        engine.prepare()
        try engine.start()
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let converter, let file else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { try? file.write(from: out) }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); file = nil; converter = nil; lock.unlock()
    }
}

/// Two independent tracks: mic is "me", system audio is everyone else. That split gives speaker separation on calls for free.
public final class MeetingRecorder: @unchecked Sendable {
    public struct Output: Sendable { public let mic: URL; public let system: URL? }

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var output: Output?

    public init() {}

    public static func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start(folder: URL, captureSystem: Bool = true) async throws {
        guard mic == nil else { throw RecorderError.alreadyRecording }
        guard await Self.requestMicPermission() else { throw RecorderError.micDenied }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.caf")
        let sysURL = folder.appendingPathComponent("system.caf")
        let m = MicCapture()
        try m.start(writingTo: micURL)
        mic = m
        var systemOutput: URL?
        if captureSystem {
            let s = SystemAudioCapture()
            do {
                try s.start(writingTo: sysURL)
                system = s
                systemOutput = sysURL
            } catch {
                // Keeps the in-person path working. The pipeline reports the missing track.
                system = nil
            }
        }
        output = Output(mic: micURL, system: systemOutput)
    }

    public func stop() throws -> Output {
        guard let out = output else { throw RecorderError.notRecording }
        system?.stop()
        mic?.stop()
        system = nil
        mic = nil
        output = nil
        return out
    }
}

/// Reports call apps using the microphone. Browsers count too, which covers Google Meet.
public enum MeetingAppDetector {
    public static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime", "com.cisco.webexmeetingsapp": "Webex", "Cisco-Systems.Spark": "Webex",
        "com.google.Chrome": "a browser call", "com.apple.Safari": "a browser call", "company.thebrowser.Browser": "a browser call",
        "com.microsoft.edgemac": "a browser call", "org.mozilla.firefox": "a browser call", "com.brave.Browser": "a browser call",
    ]

    public static func activeCallApp() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &runAddr, 0, nil, &runSize, &running) == noErr, running != 0 else { continue }
            var bundle: Unmanaged<CFString>?
            var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let s = withUnsafeMutablePointer(to: &bundle) { AudioObjectGetPropertyData(id, &bAddr, 0, nil, &bSize, $0) }
            guard s == noErr, let bid = bundle?.takeRetainedValue() as String? else { continue }
            if let hit = callApps.first(where: { bid == $0.key || bid.hasPrefix($0.key + ".") }) { return hit.value }
        }
        return nil
    }
}
