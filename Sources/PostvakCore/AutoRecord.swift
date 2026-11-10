import Foundation

/// When Postvak starts recording a meeting by itself, and with which sound.
/// A call records the call's sound as well as the microphone; a meeting in a room records the microphone only.
public enum AutoRecord {
    /// Apps that only take the microphone for a call. A browser (Google Meet) or FaceTime counts only
    /// during a meeting in the calendar, so dictation or a personal FaceTime call is not recorded.
    public static let callApps: Set<String> = ["Zoom", "Microsoft Teams", "Webex"]
    /// A room meeting starts recording only in its first minutes, so opening Postvak halfway through doesn't.
    public static let roomStartWindow: TimeInterval = 5 * 60
    /// A room recording stops this long after the meeting's scheduled end, in case it runs over.
    public static let roomStopGrace: TimeInterval = 10 * 60

    /// A call app just took the microphone. Says whether to record, and which calendar meeting the call is.
    /// `events` are those running now or starting within 15 minutes.
    public static func call(app: String, events: [CalendarEvent], now: Date) -> (record: Bool, meeting: CalendarEvent?) {
        let meeting = events
            .filter { isMeeting($0) && $0.startAt <= now.addingTimeInterval(15 * 60) && $0.endAt > now }
            .min { rank($0, now) < rank($1, now) }
        return (callApps.contains(app) || meeting != nil, meeting)
    }

    /// A meeting in a room that has just begun: accepted, with other guests, no video link, and blocking time.
    public static func roomMeeting(events: [CalendarEvent], now: Date, alreadyStarted: Set<String>) -> CalendarEvent? {
        events.filter { e in
            !e.isAllDay && e.meetingLink == nil && e.attendees.count >= 2 && e.selfResponse == "accepted" && e.isBusy
                && e.startAt <= now && now.timeIntervalSince(e.startAt) <= roomStartWindow && e.endAt > now
                && !alreadyStarted.contains(e.id)
        }
        .max { $0.startAt < $1.startAt }
    }

    static func isMeeting(_ e: CalendarEvent) -> Bool {
        !e.isAllDay && e.isBusy && (e.meetingLink != nil || e.attendees.count >= 2)
    }

    /// Prefers a meeting with a video link, then the one starting closest to now.
    static func rank(_ e: CalendarEvent, _ now: Date) -> (Int, TimeInterval) {
        (e.meetingLink != nil ? 0 : 1, abs(e.startAt.timeIntervalSince(now)))
    }
}
