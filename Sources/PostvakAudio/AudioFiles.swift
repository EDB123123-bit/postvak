import Foundation
import AVFoundation
import PostvakCore

public enum AudioFiles {
    /// Compresses a recording to AAC next to the original and removes the original on success.
    public static func compress(_ url: URL) throws -> URL {
        let dest = url.deletingPathExtension().appendingPathExtension("m4a")
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0 else { return url }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: min(format.sampleRate, 48_000),
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVEncoderBitRateKey: 64_000,
        ]
        try? FileManager.default.removeItem(at: dest)
        do {
            let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return url }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
        try FileManager.default.removeItem(at: url)
        return dest
    }

    /// Length in seconds, by the rate the file says it has.
    public static func duration(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// How much later the call track started than the microphone: the microphone starts first and the call capture follows
    /// once its tap is set up, and both stop together, so the difference in length is the head start. Zero when unclear.
    public static func callOffset(mic: URL, system: URL) -> Double {
        guard let m = duration(mic), let s = duration(system) else { return 0 }
        return MeetingStore.callOffset(micSeconds: m, callSeconds: s)
    }

    public static func sampleRate(_ url: URL) -> Double? { (try? AVAudioFile(forReading: url))?.fileFormat.sampleRate }

    /// The same samples saved under another sample rate, next to the original. Nothing is resampled: this corrects a file
    /// whose label was wrong, so it plays at the right speed and pitch again.
    public static func relabel(_ url: URL, as rate: Double) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let src = input.processingFormat
        guard let target = AVAudioFormat(commonFormat: src.commonFormat, sampleRate: rate, channels: src.channelCount, interleaved: src.isInterleaved) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent("relabel-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: src.channelCount, AVEncoderBitRateKey: 64_000]
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: src.commonFormat, interleaved: src.isInterleaved)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 65_536),
              let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536) else { throw CocoaError(.fileWriteUnknown) }
        let inList = UnsafeMutableAudioBufferListPointer(inBuf.mutableAudioBufferList)
        let outList = UnsafeMutableAudioBufferListPointer(outBuf.mutableAudioBufferList)
        while input.framePosition < input.length {
            try input.read(into: inBuf)
            if inBuf.frameLength == 0 { break }
            outBuf.frameLength = inBuf.frameLength
            for i in 0..<min(inList.count, outList.count) {
                guard let s = inList[i].mData, let d = outList[i].mData else { continue }
                memcpy(d, s, Int(inList[i].mDataByteSize))
            }
            try output.write(from: outBuf)
        }
        return dest
    }

    /// True when a track holds no audible signal. All zeros also means the capture permission was denied.
    public static func isSilent(_ url: URL, threshold: Float = 0.0008) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000) else { return true }
        var peakRMS: Float = 0
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for c in 0..<Int(buffer.format.channelCount) { for i in 0..<n { sum += data[c][i] * data[c][i] } }
            peakRMS = max(peakRMS, (sum / Float(n * Int(buffer.format.channelCount))).squareRoot())
            if peakRMS > threshold { return false }
        }
        return true
    }
}
