import AVFoundation
import Foundation
import PostvakCore
import WhisperKit
import SpeakerKit

public struct TrackResult: Sendable {
    public var segments: [TrackSegment]
    public var language: String?
    public init(segments: [TrackSegment], language: String?) { self.segments = segments; self.language = language }
}

public protocol TranscriptionEngine: Sendable {
    var name: String { get }
    /// Identifies the language from a sample of audio.
    func detectLanguage(audio: URL) async throws -> String?
    /// `diarize` splits multiple voices on one track. Without it, every segment gets `speaker`.
    func transcribe(audio: URL, language: String?, speaker: String, diarize: Bool) async throws -> TrackResult
    func finished() async
}

/// Local transcription on the Neural Engine. Audio never leaves the Mac.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated var name: String { "whisperkit:\(model)" }
    public static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    let model: String
    let downloadBase: URL
    private var whisper: WhisperKit?
    private var speakerKit: SpeakerKit?
    private let onProgress: (@Sendable (String) -> Void)?

    public init(model: String = WhisperKitEngine.defaultModel, downloadBase: URL, onProgress: (@Sendable (String) -> Void)? = nil) {
        self.model = model
        self.downloadBase = downloadBase
        self.onProgress = onProgress
    }

    /// Downloads the model on first use, around 650 MB for the default.
    public func prepare() async throws {
        if whisper != nil { return }
        onProgress?("Loading the transcription model")
        let config = WhisperKitConfig(model: model, downloadBase: downloadBase, verbose: false, logLevel: .error, prewarm: false, load: true, download: true)
        whisper = try await WhisperKit(config)
    }

    /// Whisper judges a language from one 30-second window, by default the first. A call often opens with silence, a
    /// greeting in English or a "Thank you" Whisper invents from noise, and a Dutch meeting judged English comes out as a
    /// rough English translation. So windows spread over the whole track vote, each weighed by how sure Whisper is.
    public func detectLanguage(audio: URL) async throws -> String? {
        LanguageVote.winner(try await languageSamples(audio: audio))
    }

    public func languageSamples(audio: URL, count: Int = LanguageVote.samples) async throws -> [LanguageVote.Sample] {
        try await prepare()
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        var out: [LanguageVote.Sample] = []
        for start in LanguageVote.starts(duration: duration, count: count) {
            let buffer = try AudioProcessor.loadAudio(fromPath: audio.path, startTime: start, endTime: min(duration, start + LanguageVote.window))
            let samples = AudioProcessor.convertBufferToArray(buffer: buffer)
            // Near silence says nothing about the language, and invites the invented "Thank you".
            guard LanguageVote.speechShare(samples) >= LanguageVote.minSpeechShare else { continue }
            let r = try await whisper!.detectLangauge(audioArray: samples)
            out.append(.init(start: start, language: r.language, confidence: exp(r.langProbs[r.language] ?? -10)))
        }
        // All windows quiet: fall back to Whisper's own pick from the opening.
        if out.isEmpty { out.append(.init(start: 0, language: try await whisper!.detectLanguage(audioPath: audio.path).language, confidence: 1)) }
        return out
    }

    public func transcribe(audio: URL, language: String?, speaker: String, diarize: Bool) async throws -> TrackResult {
        try await prepare()
        var options = DecodingOptions(task: .transcribe, language: language, skipSpecialTokens: true, wordTimestamps: diarize)
        options.detectLanguage = language == nil
        options.usePrefillPrompt = language != nil
        options.chunkingStrategy = .vad
        let results = try await whisper!.transcribe(audioPath: audio.path, decodeOptions: options)
        let lang = results.first?.language

        var segments: [TrackSegment] = []
        if diarize, let labelled = try? await diarized(audio: audio, results: results), !labelled.isEmpty {
            segments = labelled
        } else {
            for r in results {
                for s in r.segments where !TranscriptMerger.isNoise(Self.clean(s.text)) {
                    segments.append(TrackSegment(start: Double(s.start), end: Double(s.end), speaker: speaker, text: Self.clean(s.text)))
                }
            }
        }
        // One voice found means no separate labels are needed.
        if diarize, Set(segments.map(\.speaker)).count == 1 {
            segments = segments.map { var s = $0; s.speaker = speaker; return s }
        }
        return TrackResult(segments: segments, language: lang)
    }

    private func diarized(audio: URL, results: [TranscriptionResult]) async throws -> [TrackSegment] {
        onProgress?("Separating speakers")
        if speakerKit == nil {
            let config = PyannoteConfig(downloadBase: downloadBase.path, verbose: false, logLevel: .error)
            speakerKit = try await SpeakerKit(config)
        }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
        let diarization = try await speakerKit!.diarize(audioArray: samples)
        let groups = diarization.addSpeakerInfo(to: results)
        var out: [TrackSegment] = []
        for group in groups {
            for seg in group {
                let text = Self.clean(seg.text)
                if TranscriptMerger.isNoise(text) { continue }
                let label = seg.speaker.speakerId.map { "Speaker \($0 + 1)" } ?? "Unknown"
                out.append(TrackSegment(start: Double(seg.startTime), end: Double(seg.endTime), speaker: label, text: text))
            }
        }
        return out
    }

    /// Frees the model's memory. Nothing holds it between meetings.
    public func finished() async {
        await whisper?.unloadModels()
        whisper = nil
        speakerKit = nil
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct DeepgramError: Error, LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? { "\(message) (HTTP \(status))" }
}

/// Optional cloud path. Used per meeting, because it sends audio to Deepgram.
public final class DeepgramEngine: TranscriptionEngine {
    public var name: String { "deepgram:nova-3" }
    let apiKey: String
    let session: URLSession
    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func detectLanguage(audio: URL) async throws -> String? { nil }
    public func finished() async {}

    struct Response: Decodable {
        struct Results: Decodable {
            struct Channel: Decodable { let detected_language: String? }
            struct Utterance: Decodable { let start: Double; let end: Double; let transcript: String; let speaker: Int? }
            let channels: [Channel]?
            let utterances: [Utterance]?
        }
        let results: Results?
    }

    public func transcribe(audio: URL, language: String?, speaker: String, diarize: Bool) async throws -> TrackResult {
        var c = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        c.queryItems = [
            .init(name: "model", value: "nova-3"), .init(name: "smart_format", value: "true"),
            .init(name: "utterances", value: "true"), .init(name: "diarize", value: diarize ? "true" : "false"),
            language.map { .init(name: "language", value: $0) } ?? .init(name: "detect_language", value: "true"),
        ]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/*", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, fromFile: audio)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DeepgramError(status: status, message: "Deepgram: " + String(decoding: data.prefix(300), as: UTF8.self)) }
        let r = try JSONDecoder().decode(Response.self, from: data)
        let segs = (r.results?.utterances ?? []).map {
            TrackSegment(start: $0.start, end: $0.end, speaker: diarize ? "Speaker \(($0.speaker ?? 0) + 1)" : speaker, text: $0.transcript)
        }
        return TrackResult(segments: segs, language: language ?? r.results?.channels?.first?.detected_language)
    }
}

