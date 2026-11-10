import Foundation
import GRDB
import PostvakCore
import PostvakAI

/// Audio files to transcript to summary. Runs in the background after a recording ends, one meeting at a time.
public actor MeetingPipeline {
    let store: MeetingStore
    let summarizer: MeetingSummarizer
    let paths: AppPaths
    let secrets: SecretStore
    let db: AppDatabase
    private var running = false
    private var queue: [(String, Bool)] = []

    public init(engine: Engine, summarizer: MeetingSummarizer) {
        store = engine.meetings
        self.summarizer = summarizer
        paths = engine.paths
        secrets = engine.secrets
        db = engine.db
    }

    public func enqueue(meetingId: String, useCloud: Bool = false) {
        queue.append((meetingId, useCloud))
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let (id, cloud) = queue.removeFirst()
            await process(meetingId: id, useCloud: cloud)
        }
        running = false
    }

    /// After a crash or quit, picks up whatever was left in flight.
    public func resumeUnfinished() async {
        let stuck = (try? await db.pool.read { db in
            try MeetingRecord.filter(["recording", "processing", "transcribing", "summarizing"].contains(Column("status"))).fetchAll(db)
        }) ?? []
        for m in stuck { enqueue(meetingId: m.id) }
    }

    func makeEngine(useCloud: Bool, meetingId: String) throws -> TranscriptionEngine {
        if useCloud {
            guard let key = secrets.get(SecretKey.deepgramKey), !key.isEmpty else {
                throw MailError.invalid("Add a Deepgram API key in Settings to use cloud transcription.")
            }
            return DeepgramEngine(apiKey: key)
        }
        let model = db.setting("transcribe.model") ?? WhisperKitEngine.defaultModel
        let store = self.store
        return WhisperKitEngine(model: model, downloadBase: paths.models, onProgress: { detail in
            Task { try? await store.setStatus(meetingId, .transcribing, detail: detail) }
        })
    }

    public func process(meetingId: String, useCloud: Bool) async {
        do {
            try await run(meetingId: meetingId, useCloud: useCloud)
        } catch {
            try? await store.setStatus(meetingId, .failed, detail: error.localizedDescription)
        }
    }

    private func run(meetingId: String, useCloud: Bool) async throws {
        guard let (meeting, _) = try await store.get(meetingId) else { return }
        try await store.setStatus(meetingId, .processing, detail: "Preparing audio")

        // Compress first: the file on disk is then final, whatever happens in transcription.
        var m = meeting
        var systemWarning: String?
        // A recording cut off by a crash ends when its file was last written.
        if m.endedAt == nil, let p = m.micAudioPath,
           let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date {
            m.endedAt = d
        }
        if let p = m.micAudioPath, p.hasSuffix(".caf"), FileManager.default.fileExists(atPath: p) {
            m.micAudioPath = try AudioFiles.compress(URL(fileURLWithPath: p)).path
        }
        if let p = m.systemAudioPath, p.hasSuffix(".caf"), FileManager.default.fileExists(atPath: p) {
            m.systemAudioPath = try AudioFiles.compress(URL(fileURLWithPath: p)).path
        }
        // Only the audio and the end time change here: the title and guests may have been set meanwhile.
        if var fresh = try await store.get(meetingId)?.0 {
            fresh.endedAt = m.endedAt; fresh.micAudioPath = m.micAudioPath; fresh.systemAudioPath = m.systemAudioPath
            m = fresh
        }
        try await store.save(m)

        let micURL = m.micAudioPath.map { URL(fileURLWithPath: $0) }
        let systemURL = m.systemAudioPath.map { URL(fileURLWithPath: $0) }
        let micHasAudio = micURL.map { !AudioFiles.isSilent($0) } ?? false
        let systemHasAudio = systemURL.map { !AudioFiles.isSilent($0) } ?? false
        if m.systemAudioPath != nil, !systemHasAudio {
            systemWarning = "No system audio was captured. For a call, check Privacy & Security, System Audio Recording."
        }
        guard micHasAudio || systemHasAudio else {
            throw MailError.invalid("Both audio tracks are silent. Check the microphone and system audio permissions.")
        }

        try await store.setStatus(meetingId, .transcribing, detail: "Transcribing")
        let engine = try makeEngine(useCloud: useCloud, meetingId: meetingId)
        let diarizeOn = db.settingBool("transcribe.diarize", default: true)

        // A fixed setting wins. Otherwise each track detects its own language, because forcing the wrong
        // language on a track makes Whisper translate it into nonsense instead of transcribing it.
        let fixedLanguage = db.setting("transcribe.language").flatMap { $0 == "auto" ? nil : $0 }
        var language = fixedLanguage

        var micSegs: [TrackSegment] = [], sysSegs: [TrackSegment] = []
        if systemHasAudio, let systemURL {
            var trackLanguage = fixedLanguage
            if trackLanguage == nil { trackLanguage = try await engine.detectLanguage(audio: systemURL) }
            let r = try await engine.transcribe(audio: systemURL, language: trackLanguage, speaker: "Others", diarize: diarizeOn)
            sysSegs = r.segments
            language = language ?? trackLanguage ?? r.language
        }
        if micHasAudio, let micURL {
            // With no call audio this is a room recording, so voices on the mic need separating.
            let inPerson = !systemHasAudio
            var trackLanguage = fixedLanguage
            if trackLanguage == nil { trackLanguage = try await engine.detectLanguage(audio: micURL) }
            let r = try await engine.transcribe(audio: micURL, language: trackLanguage, speaker: "Me", diarize: inPerson && diarizeOn)
            micSegs = r.segments
            language = language ?? trackLanguage ?? r.language
        }
        await engine.finished()

        // The call track started a moment after the microphone, so its times move up to line up with it.
        if let micURL, let systemURL, micHasAudio, systemHasAudio {
            let offset = AudioFiles.callOffset(mic: micURL, system: systemURL)
            if offset > 0 { sysSegs = sysSegs.map { var s = $0; s.start += offset; s.end += offset; return s } }
        }
        let merged = TranscriptMerger.merge(mic: micSegs, system: sysSegs)
        let records = merged.enumerated().map { i, s in
            TranscriptSegmentRecord(meetingId: meetingId, position: i, startSeconds: s.start, endSeconds: s.end, speaker: s.speaker, text: s.text)
        }
        try await store.replaceSegments(meetingId: meetingId, records)
        try await store.linkToBestEvent(meetingId: meetingId)
        try await store.resetSpeakers(meetingId: meetingId, labels: Set(records.map(\.speaker)))
        try await store.assignSpeakers(meetingId: meetingId)
        try await store.fileMeetings(onlyNew: false, ids: [meetingId])

        if var fresh = try await store.get(meetingId)?.0 {
            fresh.language = language
            fresh.transcriptEngine = engine.name
            try await store.save(fresh)
        }

        var detail = systemWarning
        if !records.isEmpty, secrets.get(SecretKey.anthropicKey)?.isEmpty == false {
            try await store.setStatus(meetingId, .summarizing, detail: "Writing the summary")
            do {
                try await summarizer.summarize(meetingId: meetingId)
            } catch {
                // The transcript is safe; the summary can be retried from the meeting screen.
                detail = [systemWarning, "Summary failed: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
            }
        }
        if records.isEmpty { detail = [systemWarning, "No speech was found in the recording."].compactMap { $0 }.joined(separator: " ") }
        try await store.setStatus(meetingId, .ready, detail: detail)
    }
}

/// Owns the one running recording. Used by the UI, the menu bar and MCP.
public actor RecordingCoordinator {
    let engine: Engine
    let pipeline: MeetingPipeline
    let recorder = MeetingRecorder()
    public private(set) var currentMeetingId: String?
    public private(set) var startedAt: Date?

    public init(engine: Engine, pipeline: MeetingPipeline) {
        self.engine = engine
        self.pipeline = pipeline
    }

    public var isRecording: Bool { currentMeetingId != nil }

    public func start(title: String? = nil, captureSystem: Bool = true) async throws -> String {
        guard currentMeetingId == nil else { throw RecorderError.alreadyRecording }
        var meeting = MeetingRecord(title: title?.isEmpty == false ? title! : MeetingRecord.untitled, startedAt: Date())
        let folder = engine.paths.meetings.appendingPathComponent(meeting.id, isDirectory: true)
        try await recorder.start(folder: folder, captureSystem: captureSystem)
        meeting.micAudioPath = folder.appendingPathComponent("mic.caf").path
        if captureSystem { meeting.systemAudioPath = folder.appendingPathComponent("system.caf").path }
        try await engine.meetings.save(meeting)
        try await engine.meetings.linkToBestEvent(meetingId: meeting.id)
        try? await engine.meetings.fileMeetings(onlyNew: false, ids: [meeting.id])
        currentMeetingId = meeting.id
        startedAt = meeting.startedAt
        return meeting.id
    }

    public func stop() async throws -> String {
        guard let id = currentMeetingId else { throw RecorderError.notRecording }
        let output = try recorder.stop()
        currentMeetingId = nil
        startedAt = nil
        if var m = try await engine.meetings.get(id)?.0 {
            m.endedAt = Date()
            m.status = .processing
            m.systemAudioPath = output.system?.path
            m.micAudioPath = output.mic.path
            try await engine.meetings.save(m)
        }
        try await engine.meetings.linkToBestEvent(meetingId: id)
        await pipeline.enqueue(meetingId: id)
        return id
    }
}
