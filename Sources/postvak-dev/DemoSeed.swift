import Foundation
import GRDB
import PostvakCore

/// Fictional data so the interface and MCP tools can be exercised without a Google account.
enum DemoSeed {
    static func run(_ engine: Engine) async throws {
        let a1 = "anna.demo@example.com", a2 = "anna.work@example.org"
        try await engine.db.pool.write { db in
            var one = Account(id: a1, displayName: "Demo Personal", colorHex: Engine.accountColors[0])
            one.initialSyncDone = true; one.lastSyncAt = Date(); one.historyId = "1"
            var two = Account(id: a2, displayName: "Demo Work", colorHex: Engine.accountColors[1])
            two.initialSyncDone = true; two.lastSyncAt = Date(); two.historyId = "1"
            try one.save(db); try two.save(db)
            try CalendarRecord(accountId: a1, calendarId: a1, summary: "Personal", colorHex: "#3B82F6", isPrimary: true, isSelected: true, accessRole: "owner", syncToken: "x", lastFullSyncAt: Date()).save(db)
            try CalendarRecord(accountId: a2, calendarId: a2, summary: "Work", colorHex: "#10B981", isPrimary: true, isSelected: true, accessRole: "owner", syncToken: "x", lastFullSyncAt: Date()).save(db)
        }
        let now = Date()
        func ms(_ d: Date) -> String { String(Int(d.timeIntervalSince1970 * 1000)) }
        func b64(_ s: String) -> String { Data(s.utf8).base64URL }
        func msg(_ id: String, _ t: String, from: String, to: String, subject: String, body: String, html: String? = nil, ago: Double, labels: [String], list: Bool = false, attachment: Bool = false) -> GmailMessage {
            var headers = [GmailHeader(name: "From", value: from), GmailHeader(name: "To", value: to), GmailHeader(name: "Subject", value: subject), GmailHeader(name: "Message-ID", value: "<\(id)@example.com>")]
            if list { headers.append(GmailHeader(name: "List-Unsubscribe", value: "<mailto:u@example.com>")) }
            var parts = [GmailPart(partId: "0", mimeType: "text/plain", filename: "", headers: nil, body: GmailBody(attachmentId: nil, size: body.count, data: b64(body)), parts: nil)]
            if let html { parts.append(GmailPart(partId: "1", mimeType: "text/html", filename: "", headers: nil, body: GmailBody(attachmentId: nil, size: html.count, data: b64(html)), parts: nil)) }
            if attachment { parts.append(GmailPart(partId: "2", mimeType: "application/pdf", filename: "offerte.pdf", headers: nil, body: GmailBody(attachmentId: "att1", size: 182_000, data: nil), parts: nil)) }
            let payload = GmailPart(partId: "", mimeType: "multipart/mixed", filename: "", headers: headers, body: nil, parts: parts)
            return GmailMessage(id: id, threadId: t, labelIds: labels, snippet: String(body.prefix(90)), historyId: "1", internalDate: ms(now.addingTimeInterval(-ago * 3600)), payload: payload)
        }
        let inbox = ["INBOX"]
        let threads: [(String, GmailThreadDTO)] = [
            (a2, .init(id: "t1", historyId: "1", messages: [
                msg("m1", "t1", from: "An Peeters <an.peeters@example.net>", to: a2, subject: "Offerte zonnepanelen Gent", body: "Dag Anna,\n\nHierbij de offerte zoals besproken. Kan je tegen vrijdag laten weten of dit past?\n\nGroeten,\nAn", ago: 50, labels: inbox + ["CATEGORY_PERSONAL"], attachment: true),
                msg("m2", "t1", from: "Demo Work <\(a2)>", to: "an.peeters@example.net", subject: "Re: Offerte zonnepanelen Gent", body: "Dag An,\n\nBedankt. Ik bekijk het en kom erop terug.", ago: 40, labels: ["SENT"]),
                msg("m3", "t1", from: "An Peeters <an.peeters@example.net>", to: a2, subject: "Re: Offerte zonnepanelen Gent", body: "Prima. Laat je het ook weten als er vragen zijn over de planning?", ago: 30, labels: inbox + ["CATEGORY_PERSONAL"]),
                msg("m4", "t1", from: "Demo Work <\(a2)>", to: "an.peeters@example.net", subject: "Re: Offerte zonnepanelen Gent", body: "Doe ik. Mogen we de plaatsing naar week 48 verschuiven?", ago: 6, labels: ["SENT"]),
                msg("m5", "t1", from: "An Peeters <an.peeters@example.net>", to: a2, subject: "Re: Offerte zonnepanelen Gent", body: "Week 48 kan. Ik pas de planning aan en stuur een nieuwe bevestiging.", html: "<p>Week 48 kan. Ik pas de <b>planning</b> aan en stuur een nieuwe bevestiging.</p>", ago: 1, labels: inbox + ["UNREAD", "CATEGORY_PERSONAL"]),
            ])),
            (a1, .init(id: "t2", historyId: "1", messages: [msg("m6", "t2", from: "Marie Dubois <marie.dubois@example.fr>", to: a1, subject: "Déjeuner jeudi ?", body: "Salut Anna, tu es libre jeudi midi pour déjeuner ?", ago: 3, labels: inbox + ["UNREAD", "CATEGORY_PERSONAL"])])),
            (a2, .init(id: "t3", historyId: "1", messages: [msg("m7", "t3", from: "Vercel <notifications@example-deploys.com>", to: a2, subject: "Deployment ready", body: "Your deployment finished successfully.", ago: 5, labels: inbox + ["UNREAD", "CATEGORY_UPDATES"], list: true)])),
            (a1, .init(id: "t4", historyId: "1", messages: [msg("m8", "t4", from: "De Lijn <info@example-transit.be>", to: a1, subject: "Je factuur staat klaar", body: "Je maandelijkse factuur is beschikbaar.", ago: 20, labels: inbox + ["CATEGORY_UPDATES"], list: true)])),
            (a2, .init(id: "t5", historyId: "1", messages: [msg("m9", "t5", from: "Tech Weekly <newsletter@example-news.com>", to: a2, subject: "This week in Swift", body: "The top stories in Swift this week.", ago: 9, labels: inbox + ["UNREAD", "CATEGORY_PROMOTIONS"], list: true)])),
            (a1, .init(id: "t6", historyId: "1", messages: [msg("m10", "t6", from: "Winkel <promo@example-shop.be>", to: a1, subject: "-30% op alles dit weekend", body: "Enkel dit weekend: dertig procent korting.", ago: 26, labels: inbox + ["CATEGORY_PROMOTIONS"], list: true)])),
            (a1, .init(id: "t7", historyId: "1", messages: [msg("m11", "t7", from: "Prize Desk <winner@example-spam.biz>", to: a1, subject: "You have won a car", body: "Click here now to claim your prize.", ago: 12, labels: ["SPAM"])])),
            (a2, .init(id: "t8", historyId: "1", messages: [msg("m12", "t8", from: "Bouw BV <hello@example-bouw.be>", to: a2, subject: "Voorstel samenwerking", body: "Graag plannen we een gesprek over een samenwerking.", ago: 70, labels: ["IMPORTANT", "CATEGORY_PERSONAL"])])),
        ]
        for (a, t) in threads { try await GmailSync.store(db: engine.db, accountId: a, dto: t) }
        try await engine.db.pool.write { db in
            try SnoozeRow(accountId: a2, threadId: "t8", wakeAt: now.addingTimeInterval(86400)).save(db)
            try db.execute(sql: "UPDATE thread SET needsAIClassification = 0")
        }

        let cal = Calendar.current
        func at(_ dayOffset: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: dayOffset, to: now)!)!
        }
        func attJSON(_ a: [EventAttendee]) -> String { String(decoding: try! JSONEncoder().encode(a), as: UTF8.self) }
        let team = [EventAttendee(email: a2, name: "Demo Work", response: "accepted", isSelf: true), EventAttendee(email: "an.peeters@example.net", name: "An Peeters", response: "accepted")]
        let invite = [EventAttendee(email: a1, response: "needsAction", isSelf: true), EventAttendee(email: "marie.dubois@example.fr", name: "Marie Dubois", response: "accepted", isOrganizer: true)]
        let events: [CalendarEvent] = [
            .init(accountId: a2, calendarId: a2, eventId: "e1", summary: "Planning plaatsing Gent", details: "Week 48 bespreken", location: "", startAt: at(0, 10), endAt: at(0, 11), isAllDay: false, status: "confirmed", transparency: "opaque", organizerEmail: a2, attendeesJSON: attJSON(team), selfResponse: "accepted", meetingLink: "https://meet.google.com/abc-defg-hij", htmlLink: nil, recurringEventId: nil),
            .init(accountId: a1, calendarId: a1, eventId: "e2", summary: "Tandarts", details: "", location: "Gent", startAt: at(0, 14), endAt: at(0, 14, 45), isAllDay: false, status: "confirmed", transparency: "opaque", organizerEmail: a1, attendeesJSON: "[]", selfResponse: nil, meetingLink: nil, htmlLink: nil, recurringEventId: nil),
            .init(accountId: a2, calendarId: a2, eventId: "e3", summary: "Klantgesprek Hasselt", details: "", location: "Hasselt", startAt: at(1, 9, 30), endAt: at(1, 11), isAllDay: false, status: "confirmed", transparency: "opaque", organizerEmail: a2, attendeesJSON: attJSON(team), selfResponse: "accepted", meetingLink: nil, htmlLink: nil, recurringEventId: nil),
            .init(accountId: a1, calendarId: a1, eventId: "e4", summary: "Déjeuner avec Marie", details: "", location: "", startAt: at(1, 12), endAt: at(1, 13), isAllDay: false, status: "confirmed", transparency: "opaque", organizerEmail: "marie.dubois@example.fr", attendeesJSON: attJSON(invite), selfResponse: "needsAction", meetingLink: nil, htmlLink: nil, recurringEventId: nil),
            .init(accountId: a2, calendarId: a2, eventId: "e5", summary: "Beurs Antwerpen", details: "", location: "Antwerpen", startAt: cal.startOfDay(for: at(2, 0)), endAt: cal.startOfDay(for: at(3, 0)), isAllDay: true, status: "confirmed", transparency: "transparent", organizerEmail: a2, attendeesJSON: "[]", selfResponse: nil, meetingLink: nil, htmlLink: nil, recurringEventId: nil),
            .init(accountId: a1, calendarId: a1, eventId: "e6", summary: "Sport", details: "", location: "", startAt: at(2, 18), endAt: at(2, 19), isAllDay: false, status: "confirmed", transparency: "opaque", organizerEmail: a1, attendeesJSON: "[]", selfResponse: nil, meetingLink: nil, htmlLink: nil, recurringEventId: nil),
        ]
        try await engine.db.pool.write { db in for e in events { try e.save(db) } }

        try await engine.meetings.importMeeting(ImportedMeeting(
            source: "demo", sourceId: "1", title: "Planning plaatsing Gent", startedAt: at(-1, 10), endedAt: at(-1, 10, 25),
            attendees: ["An Peeters <an.peeters@example.net>"], language: "nl",
            summary: "De plaatsing in Gent schuift naar week 48. An stuurt een nieuwe bevestiging en de planning wordt aangepast.",
            segments: [
                .init(start: 2, end: 8, speaker: "Me", text: "Goedemorgen An, kunnen we de plaatsing naar week 48 verschuiven?"),
                .init(start: 9, end: 15, speaker: "Speaker 1", text: "Week 48 kan. Ik pas de planning aan en stuur een nieuwe bevestiging."),
                .init(start: 16, end: 21, speaker: "Me", text: "Perfect, dan laat ik de klant weten dat het doorgaat."),
            ],
            actionItems: [ActionItem(task: "Nieuwe bevestiging sturen", owner: "An Peeters", due: "vrijdag"), ActionItem(task: "Klant verwittigen", owner: "Anna")],
            decisions: ["Plaatsing verschuift naar week 48"]))
    }
}
