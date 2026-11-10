import Foundation
import GRDB
import PostvakCore
import PostvakAI
import PostvakAudio
import PostvakMCP

// Developer tool. Never touches real data unless POSTVAK_DATA_DIR is left unset, so it refuses to run without it.
guard let dir = ProcessInfo.processInfo.environment["POSTVAK_DATA_DIR"], !dir.isEmpty else {
    print("Set POSTVAK_DATA_DIR to a scratch folder first.")
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
let secrets = MemorySecretStore([SecretKey.mcpToken: "dev-token"])
let engine = try Engine(paths: AppPaths(root: URL(fileURLWithPath: dir)), secrets: secrets)

switch args.first {
case "seed":
    try await DemoSeed.run(engine)
    print("Seeded demo data in \(dir)")
case "transcribe":
    // postvak-dev transcribe <audio> <model>: runs the real engine on a file.
    let url = URL(fileURLWithPath: args[1])
    let eng = WhisperKitEngine(model: args.count > 2 ? args[2] : WhisperKitEngine.defaultModel, downloadBase: engine.paths.models) { print("…", $0) }
    let lang = try await eng.detectLanguage(audio: url)
    print("language:", lang ?? "nil")
    let r = try await eng.transcribe(audio: url, language: lang, speaker: "Me", diarize: args.contains("--diarize"))
    for s in r.segments { print(String(format: "[%.1f-%.1f] %@: %@", s.start, s.end, s.speaker, s.text)) }
    await eng.finished()
case "languages":
    // postvak-dev languages <audio> [models dir]: how each window of a track votes on its language.
    let models = args.count > 2 ? URL(fileURLWithPath: args[2]) : engine.paths.models
    let eng = WhisperKitEngine(downloadBase: models) { print("…", $0) }
    let samples = try await eng.languageSamples(audio: URL(fileURLWithPath: args[1]))
    for s in samples { print(String(format: "%6.0fs  %@  %.2f", s.start, s.language, s.confidence)) }
    print("winner:", LanguageVote.winner(samples) ?? "nil")
    await eng.finished()
case "pipeline":
    // postvak-dev pipeline <mic> <system|-> <model>: full meeting flow on existing files.
    let tmp = engine.paths.meetings.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    var meeting = MeetingRecord(title: MeetingRecord.untitled, startedAt: Date().addingTimeInterval(-60), endedAt: Date(), status: .processing)
    let mic = tmp.appendingPathComponent("mic.caf")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: args[1]), to: mic)
    meeting.micAudioPath = mic.path
    if args[2] != "-" {
        let sys = tmp.appendingPathComponent("system.caf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: sys)
        meeting.systemAudioPath = sys.path
    }
    try await engine.meetings.save(meeting)
    if args.count > 3 { try engine.db.setSetting("transcribe.model", args[3]) }
    let claude = ClaudeClient(session: .shared) { secrets.get(SecretKey.anthropicKey) }
    let pipeline = MeetingPipeline(engine: engine, summarizer: MeetingSummarizer(claude: claude, store: engine.meetings))
    await pipeline.process(meetingId: meeting.id, useCloud: false)
    let (m, _) = try await engine.meetings.get(meeting.id)!
    print("status:", m.status.rawValue, "| detail:", m.statusDetail ?? "-", "| language:", m.language ?? "-")
    print("audio:", m.micAudioPath ?? "-", m.systemAudioPath ?? "-")
    for s in try await engine.meetings.segments(meetingId: m.id) {
        print(String(format: "[%.1f-%.1f] %@: %@", s.startSeconds, s.endSeconds, s.speaker, s.text))
    }
case "record":
    // postvak-dev record <seconds>: real mic and system capture.
    let secs = Double(args.count > 1 ? args[1] : "5") ?? 5
    let rec = MeetingRecorder()
    let folder = engine.paths.meetings.appendingPathComponent("record-test", isDirectory: true)
    try await rec.start(folder: folder)
    try await Task.sleep(for: .seconds(secs))
    let out = try rec.stop()
    print("mic:", out.mic.path, "silent:", AudioFiles.isSilent(out.mic))
    if let s = out.system { print("system:", s.path, "silent:", AudioFiles.isSilent(s)) } else { print("system: not captured") }
case "serve":
    // postvak-dev serve [port]: MCP server on the demo data, without the app.
    let port = UInt16(args.count > 1 ? args[1] : "7445") ?? 7445
    let server = MCPServer(tools: PostvakTools.all(engine: engine, recorder: nil, ui: nil)) { secrets.get(SecretKey.mcpToken) }
    try await server.start(port: port)
    print("MCP on http://127.0.0.1:\(server.port)/mcp, token dev-token")
    try await Task.sleep(for: .seconds(3600))
case "link-imports":
    // Safe on the live data folder: only links imported meetings to their calendar events, then files those meetings.
    let ids = try await engine.meetings.linkImportedMeetings()
    if !ids.isEmpty { try await engine.meetings.fileMeetings(onlyNew: false, ids: ids) }
    print("Changed the event link of \(ids.count) imported meetings.")
case "deals":
    // postvak-dev deals: the companies the deals overview would read, busiest first, without calling Claude.
    let (identity, list) = try await Deals(db: engine.db).candidates()
    print("own addresses:", identity.addresses.sorted().joined(separator: ", "))
    print("own domains:", identity.domains.sorted().joined(separator: ", "), "| colleagues:", identity.teamNames.sorted().joined(separator: ", "))
    for c in list.prefix(DealAnalyzer.maxCompanies) {
        print(String(format: "%3d  %@  in %d  out %d  held %d  booked %d", c.score, c.key.padding(toLength: 34, withPad: " ", startingAt: 0),
                     c.mailsIn, c.mailsOut, c.meetingsHeld, c.meetingsBooked))
    }
    print("\(list.count) companies in all")
case "follow-up":
    // postvak-dev follow-up <meetingId>: writes a meeting's follow-up as a new mail and prints it; saves nothing.
    // Reads the Claude key from ANTHROPIC_API_KEY.
    let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    let claude = ClaudeClient(session: .shared) { key }
    guard let (m, summary) = try await engine.meetings.get(args[1]) else { print("No such meeting"); exit(1) }
    let (people, account) = try await engine.db.pool.read { (try MeetingFollowUp.addressees(m, $0), try MeetingFollowUp.account(m, $0)) }
    let samples = try await engine.db.pool.read { db in
        try MailMessage.filter(Column("accountId") == (account ?? "") && Column("labelIds").like("%|SENT|%") && !Column("labelIds").like("%|DRAFT|%"))
            .order(Column("date").desc).limit(5).fetchAll(db)
    }.map { FollowUpWriter.ownText($0.bodyText) }.filter { !$0.isEmpty }
    let out = try await MeetingFollowUpWriter(claude: claude).write(
        meeting: m, summary: summary, segments: try await engine.meetings.segments(meetingId: m.id),
        names: try await engine.meetings.speakerNames(meetingId: m.id),
        hints: try await engine.meetings.speakers(meetingId: m.id).filter { $0.source == .suggested }.reduce(into: [:]) { $0[$1.label] = $1.name }, me: try await engine.meetings.speakerCandidates(meetingId: m.id).first?.name,
        recipients: people.to, cc: people.cc, lastInThread: nil, samples: samples)
    print("From:", account ?? "-", "\nTo:", people.to.joined(separator: ", "), "\nCc:", people.cc.joined(separator: ", "))
    print("Subject:", out.subject, "\n\n" + out.text)
    print("\n(\(out.text.split(whereSeparator: \.isWhitespace).count) words)")
default:
    print("Commands: seed, transcribe, pipeline, record, serve, link-imports, deals, follow-up")
}
