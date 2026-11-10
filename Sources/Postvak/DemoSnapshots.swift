import SwiftUI
import AppKit
import WebKit
import PostvakCore
import GRDB

/// Demo mode only: the app renders its own windows to PNG files, then quits. Used to check layouts on fictional data.
@MainActor
enum DemoSnapshots {
    static func runIfRequested(_ model: AppModel) {
        guard model.demoMode, let dir = ProcessInfo.processInfo.environment["POSTVAK_SNAPSHOT_DIR"] else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            let steps: [(String, () -> Void)] = [
                ("mail-people", { model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people) }),
                ("mail-notifications", { model.destination = .mail(folder: .inbox, accountId: nil, bucket: .notifications) }),
                ("mail-newsletters", { model.destination = .mail(folder: .inbox, accountId: nil, bucket: .newsletters) }),
                ("mail-spam", { model.destination = .mail(folder: .spam, accountId: nil, bucket: nil) }),
                ("record-button", { model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people) }),
                ("name-recording", {
                    model.namingRecording = NamingRecording(meetingId: "demo", title: "", guests: "Jan Peeters <jan@zonnehoek.be>")
                }),
                ("name-recording-closed", { model.namingRecording = nil }),
                ("recording-pill", {
                    // Only the look of a recording in progress: no audio is captured.
                    model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people)
                    model.recordingStartedAt = Date().addingTimeInterval(-754)
                    model.isRecording = true
                    Task { try? await Task.sleep(for: .seconds(3)); model.isRecording = false; model.recordingStartedAt = nil }
                }),
                ("calendar-week", { UserDefaults.standard.set("Week", forKey: "calendarMode"); model.destination = .calendar }),
                ("calendar-month", { UserDefaults.standard.set("Month", forKey: "calendarMode") }),
                ("calendar-day", { UserDefaults.standard.set("Day", forKey: "calendarMode") }),
                ("meetings", { model.destination = .meetings }),
                ("ask-history", {
                    let h = AskHistory(db: model.engine.db)
                    Task {
                        try? await h.save(AskTurnRecord(id: "demo-1", chatId: "demo-a", question: "Wat beloofde ik Panelwerk na de demo?",
                                                        answer: "Een offerte voor 40 omvormers, tegen vrijdag.", error: nil, steps: ["Searching “panelwerk”"],
                                                        askedAt: Date().addingTimeInterval(-86400 * 2)))
                        try? await h.save(AskTurnRecord(id: "demo-2", chatId: "demo-b", question: "Wie was er bij de planning in Gent?",
                                                        answer: "An Peeters en het plaatsingsteam.", error: nil, steps: ["Reading “Planning plaatsing Gent”"],
                                                        askedAt: Date().addingTimeInterval(-3600)))
                        try? await h.save(AskTurnRecord(id: "demo-3", chatId: "demo-b", question: "En wat is de nieuwe datum?",
                                                        answer: "De plaatsing schuift naar **week 48**.", error: nil, steps: [],
                                                        askedAt: Date().addingTimeInterval(-3000)))
                    }
                    model.destination = .ask
                }),
                ("ask-history-opened", { model.ask.open("demo-b") }),
                ("ask-window", { model.destination = .ask; pressMenu("Ask Meetings") }),
                ("ask-window-minimized", { askWindow()?.miniaturize(nil) }),
                ("ask-window-reopened", {
                    print("ask window minimized: \(askWindow()?.isMiniaturized ?? false)")
                    pressMenu("Ask Meetings")
                }),
                ("ask-window-closed", {
                    print("ask window minimized after reopening: \(askWindow()?.isMiniaturized ?? false), visible: \(askWindow()?.isVisible ?? false)")
                    askWindow()?.close()
                    model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people)
                }),
                ("calendar-search", { model.destination = .calendar; model.calendarSearch = "plaatsing" }),
                ("calendar-search-nothing", { model.calendarSearch = "zzz" }),
                ("calendar-search-cleared", { model.calendarSearch = "" }),
                ("composer", {
                    model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people)
                    var s = ComposerState(accountId: model.accounts.first?.id ?? "")
                    s.to = "An Peeters <an.peeters@example.net>"
                    s.subject = "Re: Offerte zonnepanelen Gent"
                    s.body = NSAttributedString(string: "Dag An,\n\nWeek 48 past perfect.", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
                    model.composers.open(s)
                }),
                ("composer-pasted-picture", {
                    // A private pasteboard, so a demo run never touches the real clipboard.
                    guard let tv = composerWindows().first.flatMap({ textView(in: $0.contentView) }) else { print("no composer text"); return }
                    let pb = NSPasteboard(name: NSPasteboard.Name("postvak-demo"))
                    pb.clearContents()
                    let img = NSImage(size: NSSize(width: 900, height: 420), flipped: false) { r in
                        NSColor(srgbRed: 0.16, green: 0.45, blue: 0.85, alpha: 1).setFill(); r.fill()
                        ("Pasted screenshot" as NSString).draw(at: NSPoint(x: 40, y: 190), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white])
                        return true
                    }
                    pb.writeObjects([img])
                    tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
                    print("pasted: \(tv.readSelection(from: pb))")
                    if let d = composerWindows().first?.draft {
                        let i = d.state.composeInput()
                        print("inline pictures: \(i.attachments.filter { $0.contentId != nil }.count), html has cid: \(i.html?.contains("cid:") == true), text: \(i.text.debugDescription)")
                    }
                }),
                ("composer-cc-clicked", {
                    // Straight to the window, so the test needs neither the mouse nor the app in front.
                    guard let w = composerWindows().first else { print("no composer"); return }
                    let at = NSPoint(x: w.frame.width - 72, y: w.frame.height - 95)
                    func event(_ type: NSEvent.EventType) -> NSEvent? {
                        NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    }
                    // The release goes in the queue first: a button follows the mouse until it sees it there.
                    if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: true) }
                    if let down = event(.leftMouseDown) { w.sendEvent(down) }
                }),
                ("composer-formatted", {
                    guard let tv = composerWindows().first.flatMap({ textView(in: $0.contentView) }) else { print("no composer text"); return }
                    tv.setSelectedRange(NSRange(location: 0, length: 7))
                    tv.toggleTrait(.boldFontMask)
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                    tv.insertText("\nPlanning\nPrijs", replacementRange: tv.selectedRange())
                    let start = (tv.string as NSString).range(of: "Planning").location
                    tv.setSelectedRange(NSRange(location: start, length: (tv.string as NSString).length - start))
                    tv.toggleList(.bullet)
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                    print("Return continues the list: \(tv.continueList())")
                    tv.insertText("Datum", replacementRange: tv.selectedRange())
                    if let d = composerWindows().first?.draft { print("formatted html: \(d.state.composeInput().html ?? "")") }
                }),
                ("composer-check", {
                    guard let d = composerWindows().first?.draft else { print("no composer"); return }
                    d.state.body = ComposerState.body("Dag An,\n\nZie bijlage voor de nieuwe planning.")
                    d.state.followUp = .workingDays(3)
                    d.send(at: nil)
                }),
                ("followup-due", {
                    print("check found: \(composerWindows().first?.draft.findings ?? [])")
                    closeComposers()
                    Task {
                        let t = try? await model.engine.mail.threads(ThreadQuery(folder: .inbox, bucket: .people)).first
                        guard let t else { print("no thread"); return }
                        let sent = Date().addingTimeInterval(-60)
                        try? await model.engine.followUps.track(FollowUpRecord(id: "demo-follow-up", accountId: t.accountId, threadId: t.threadId,
                                                                               subject: t.subject, recipients: "an.peeters@example.net",
                                                                               sentAt: sent, dueAt: Date().addingTimeInterval(-60)))
                        let fell = await model.engine.followUps.check()
                        print("fell due: \(fell.map(\.subject))")
                    }
                    model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people)
                }),
                ("morning-overview", { model.showMorningOverview = true }),
                ("composer-second-cascades", { model.compose() }),
                ("composer-minimized", { composerWindows().first?.miniaturize(nil) }),
                ("composer-restored", {
                    print("minimized before restore: \(model.composers.minimized.map(\.title))")
                    if let d = model.composers.minimized.first { model.composers.restore(d) }
                }),
                ("toast", {
                    print("minimized after restore: \(model.composers.minimized.count), composers open: \(composerWindows().count)")
                    closeComposers()
                    model.toast("Sending “Re: Offerte zonnepanelen Gent”", kind: .undoSend(outboxId: "demo", deadline: Date().addingTimeInterval(5)), seconds: 5)
                }),
                ("popout-double-click", { model.toasts = []; doubleClickSecondThread() }),
                ("popout-same-thread", { press("o", in: mainWindow()) }),
                ("popout-reply", { press("r", in: threadWindow()) }),
                ("popout-second-composer", { press("c", in: mainWindow()) }),
                ("popout-composer-closed", { print("composers open: \(composerWindows().count)"); closeComposers() }),
                ("popout-archive-closes-it", { press("e", in: threadWindow()) }),
                ("main-closed", { mainWindow()?.performClose(nil) }),
                ("dock-reopens-main", {
                    let e = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication), targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                    _ = try? e.sendEvent(options: [.noReply], timeout: 5)
                }),
                ("main-closed-again", { mainWindow()?.performClose(nil) }),
                ("new-mail-without-main", {
                    guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.item(withTitle: "New Mail") != nil })?.submenu,
                          let i = menu.indexOfItem(withTitle: "New Mail") as Int?, i >= 0 else { print("no New Mail item"); return }
                    menu.performActionForItem(at: i)
                }),
                ("send-reopens-main-for-undo", {
                    print("main visible before send: \(model.mainWindowVisible)")
                    guard let d = composerWindows().first?.draft else { print("no composer"); return }
                    d.state.to = "An Peeters <an.peeters@example.net>"
                    d.state.subject = "Demo verzonden"
                    d.state.body = NSAttributedString(string: "Test")
                    d.send(at: nil)
                }),
                ("undo-reopens-composer", {
                    print("main visible after send: \(model.mainWindowVisible), composers open: \(composerWindows().count)")
                    let id = model.toasts.compactMap { t -> String? in
                        if case .undoSend(let id, _) = t.kind { return id }
                        return nil
                    }.first
                    if let id { model.undoSend(outboxId: id) } else { print("no undo toast") }
                }),
                ("composer-closed", { print("composers open after undo: \(composerWindows().count)"); closeComposers() }),
                ("outbox-banner-edit", {
                    Task {
                        let mail = OutgoingMail(accountId: model.accounts.first?.id ?? "", to: ["\"Peeters, An\" <an.peeters@example.net>"], subject: "Mislukte mail",
                                                textBody: "Dag An,\n\nDeze tekst blijft bewaard.", htmlBody: "<div>Dag An</div>")
                        _ = try? await model.engine.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
                        try? await model.engine.outbox.markOverdueAtLaunch()
                    }
                }),
                ("outbox-edit-opens-composer", { if let row = model.overdueOutbox.first { model.editQueued(row) } }),
                ("outbox-edit-keeps-row", { print("queued while editing: \(model.overdueOutbox.count), composers open: \(composerWindows().count)") }),
                ("outbox-edit-discarded", { composerWindows().first?.draft.discard() }),
                ("outbox-empty", { print("queued after discard: \(model.overdueOutbox.count)") }),
                ("scheduled", {
                    Task {
                        let a = model.accounts.first?.id ?? ""
                        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date().addingTimeInterval(86400))!
                        let outbox = model.engine.outbox
                        _ = try? await outbox.enqueue(OutgoingMail(accountId: a, to: ["An Peeters <an.peeters@example.net>"], subject: "Re: Offerte zonnepanelen Gent",
                                                                   textBody: "Dag An,\n\nHierbij de aangepaste offerte voor 24 panelen, met de omvormer die we bespraken.\n\nGroeten"),
                                                      sendAt: morning)
                        _ = try? await outbox.enqueue(OutgoingMail(accountId: a, to: ["Jo Maes <jo@panelwerk.example.com>", "planning@brightly.example.com"],
                                                                   cc: ["An Peeters <an.peeters@example.net>"], subject: "Planning plaatsing week 48",
                                                                   textBody: "Hallo allemaal,\n\nDe plaatsing in Gent schuift naar week 48. Laat gerust weten als dat niet past."),
                                                      sendAt: morning.addingTimeInterval(3 * 86400 + 5400))
                        _ = try? await outbox.enqueue(OutgoingMail(accountId: a, to: ["info@luchtzuiver.example.com"], subject: "Vraag over onderhoudscontract",
                                                                   textBody: "Goedemiddag,\n\nKan u mij de voorwaarden van het onderhoudscontract bezorgen?"),
                                                      sendAt: Date().addingTimeInterval(-7200))
                        try? await outbox.markOverdueAtLaunch()
                        // Due while the Mac had no network: it goes by itself once back online.
                        let offline = try? await outbox.enqueue(OutgoingMail(accountId: a, to: ["Jo Maes <jo@panelwerk.example.com>"], subject: "Offerte dakwerken",
                                                                             textBody: "Dag Jo,\n\nZoals beloofd de offerte voor het dak."),
                                                                sendAt: Date().addingTimeInterval(-300))
                        if let id = offline?.id {
                            try? await model.engine.db.pool.write {
                                try $0.execute(sql: "UPDATE outbox SET status = 'waiting', lastError = 'The Internet connection appears to be offline.' WHERE id = ?", arguments: [id])
                            }
                        }
                    }
                    model.destination = .scheduled
                }),
                ("scheduled-waiting-banner", { model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people) }),
                ("review-drafts", {
                    Task {
                        let a = model.accounts.first?.id ?? ""
                        func m(_ db: Database, _ id: String, _ t: String, from: String, to: String, subject: String, body: String, hoursAgo: Double, labels: String) throws {
                            try db.execute(sql: """
                                INSERT OR REPLACE INTO message (accountId, messageId, threadId, rfcMessageId, fromName, fromEmail, toLine, ccLine, subject, date,
                                                                snippet, bodyText, labelIds, hasListUnsubscribe)
                                VALUES (?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?, ?, 0)
                                """, arguments: [a, id, t, "<\(id)@demo>", from == a ? "" : "Jo Maes", from, to, subject, Date().addingTimeInterval(-hoursAgo * 3600),
                                                 String(body.prefix(60)), body, labels])
                        }
                        try? await model.engine.db.pool.write { db in
                            try m(db, "rv1", "rvt1", from: "jo@panelwerk.example.com", to: a, subject: "Vraag over de pilot",
                                  body: "Dag Anna,\n\nGeldt de grens van 20 FTE ook voor kleinere bedrijven? En hoe snel kunnen jullie starten?\n\nGroeten,\nJo",
                                  hoursAgo: 96, labels: "|INBOX|")
                            try m(db, "rv2", "rvt1", from: a, to: "Jo Maes <jo@panelwerk.example.com>", subject: "Re: Vraag over de pilot",
                                  body: "Dag Jo,\n\nBedankt voor je vragen. De grens van 20 FTE is [eigen keuze of wettelijk?]. Starten kan binnen twee weken na akkoord.\n\nGroeten,",
                                  hoursAgo: 0.2, labels: "|DRAFT|")
                            try m(db, "rv3", "rvt2", from: a, to: "An Peeters <an.peeters@example.net>", subject: "Re: Offerte zonnepanelen Gent",
                                  body: "Dag An,\n\nHad je al de kans om de offerte van vorige week te bekijken? Laat gerust weten als er vragen zijn.\n\nGroeten,",
                                  hoursAgo: 0.2, labels: "|DRAFT|")
                        }
                        _ = try? await model.engine.autoDrafts.record(AutoDraftRecord(accountId: a, draftId: "demo-d1", threadId: "rvt1", fromEmail: a,
                            recipients: "Jo Maes <jo@panelwerk.example.com>", subject: "Re: Vraag over de pilot", source: .review,
                            reason: "Jo Maes (Panelwerk) asked about the 20-FTE limit and start date 4 days ago; no answer yet"))
                        _ = try? await model.engine.autoDrafts.record(AutoDraftRecord(accountId: a, draftId: "demo-d2", threadId: "rvt2", fromEmail: a,
                            recipients: "An Peeters <an.peeters@example.net>", subject: "Re: Offerte zonnepanelen Gent", source: .reminder,
                            reason: "No reply to “Offerte zonnepanelen Gent” since 2 Nov"))
                    }
                    model.destination = .mail(folder: .inbox, accountId: nil, bucket: .people)
                }),
                ("review-drafts-page", { model.destination = .review }),
                ("scheduled-edit", {
                    Task {
                        let rows = (try? await model.engine.outbox.rows()) ?? []
                        if let r = rows.first(where: { $0.status == .pending && !$0.isUndoWindow }) { model.editQueued(r) } else { print("no scheduled row") }
                    }
                }),
                ("scheduled-edit-closed", {
                    Task {
                        print("scheduled while editing: \(((try? await model.engine.outbox.rows()) ?? []).map(\.status.rawValue))")
                        composerWindows().first?.close()
                    }
                }),
                ("scheduled-after-close", {
                    Task { print("scheduled after closing the composer: \(((try? await model.engine.outbox.rows()) ?? []).map(\.status.rawValue))") }
                }),
                ("settings", {
                    guard let menu = NSApp.mainMenu?.items.first?.submenu,
                          let i = menu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) else { print("no Settings item"); return }
                    menu.performActionForItem(at: i)
                }),
            ]
            // POSTVAK_SNAPSHOT_STEPS=composer,composer-minimized runs only the steps named, in their usual order.
            let only = ProcessInfo.processInfo.environment["POSTVAK_SNAPSHOT_STEPS"].map { Set($0.split(separator: ",").map(String.init)) }
            for (name, step) in steps where only?.contains(name) ?? true {
                step()
                try? await Task.sleep(for: .seconds(2))
                for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.frame.width > 300 {
                    print("\(name) window \(i): occlusion-visible=\(w.occlusionState.contains(.visible)) title=\(w.title) sheet=\(w.isSheet) hasSheet=\(w.attachedSheet != nil)")
                    capture(w, to: "\(dir)/\(name)-\(i).png")
                    await captureWebViews(in: w, prefix: "\(dir)/\(name)-\(i)-web")
                }
            }
            closeComposers()
            NSApp.terminate(nil)
        }
    }

    // The main window has a 1000 point minimum width, and popped-out windows open narrower.
    private static func mainWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.frame.width >= 1000 } }
    private static func threadWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.canBecomeMain && $0 !== mainWindow() && !($0 is ComposerWindow) }
    }
    private static func textView(in v: NSView?) -> ComposerTextView? {
        guard let v else { return nil }
        if let t = v as? ComposerTextView { return t }
        for s in v.subviews { if let t = textView(in: s) { return t } }
        return nil
    }
    private static func askWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Ask Meetings" && $0.frame.width < 1000 && !$0.isSheet }
    }
    /// Chooses a menu item by its title, as a click in the menu bar would.
    private static func pressMenu(_ title: String) {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.item(withTitle: title) != nil })?.submenu else { print("no \(title) item"); return }
        menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
    }
    private static func composerWindows() -> [ComposerWindow] {
        NSApp.windows.compactMap { $0 as? ComposerWindow }.filter { $0.isVisible || $0.isMiniaturized }
    }
    private static func closeComposers() { composerWindows().forEach { $0.close() } }

    /// Real events through the normal event loop, so the key monitor and the list's own double-click handling run.
    private static func press(_ key: String, in w: NSWindow?) {
        guard let w else { print("no window for key \(key)"); return }
        w.makeKeyAndOrderFront(nil)
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func doubleClickSecondThread() {
        guard let w = mainWindow() else { print("no main window"); return }
        w.makeKeyAndOrderFront(nil)
        let at = NSPoint(x: 420, y: w.frame.height - 150)
        for count in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
    }

    private static func capture(_ w: NSWindow, to path: String) {
        // Asks the window server for this app's own window, so lists and materials come out as displayed.
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        guard let img = fn(.null, 8, UInt32(w.windowNumber), 1)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func captureWebViews(in w: NSWindow, prefix: String) async {
        var found: [WKWebView] = []
        func walk(_ v: NSView) {
            if let web = v as? WKWebView { found.append(web) }
            v.subviews.forEach(walk)
        }
        if let c = w.contentView { walk(c) }
        for (i, web) in found.prefix(2).enumerated() {
            if let img = try? await web.takeSnapshot(configuration: nil), let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(prefix)\(i).png"))
            }
        }
    }
}
