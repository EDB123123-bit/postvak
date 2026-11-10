import SwiftUI
import PostvakCore

@main
struct PostvakApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        // A single window, so "Open Postvak" can bring it back and popped-out threads never stand in for it.
        Window("Postvak", id: mainWindowId) {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            NewMailCommand(model: model)
            CommandMenu("Meeting") {
                Button(model.isRecording ? "Stop Recording" : "Record Call") {
                    model.isRecording ? model.stopRecording() : model.recordNow()
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Record In-Person Meeting") { model.recordNow(captureSystem: false) }.disabled(model.isRecording)
                Divider()
                AskMeetingsButton()
                Button("Today's Meetings") {
                    model.reopenMainWindow?()
                    model.showMorningOverview = true
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("Postvak Guide") {
                    model.reopenMainWindow?()
                    model.showOnboarding = true
                }
            }
        }

        // One window, so asking again brings it forward. ⌘M or the yellow button minimizes it.
        Window("Ask Meetings", id: askWindowId) {
            AskView(ask: model.ask)
                .environmentObject(model)
                .environment(\.isAskWindow, true)
                .frame(minWidth: 560, minHeight: 420)
        }
        // Room for the history beside the chat.
        .defaultSize(width: 900, height: 760)

        WindowGroup("Mail", id: "thread", for: ThreadWindowRef.self) { $ref in
            if let ref {
                ThreadWindowView(ref: ref).environmentObject(model)
            }
        }
        .defaultSize(width: 860, height: 780)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            if model.isRecording {
                Image(systemName: "record.circle.fill")
            } else if model.unreadCount > 0 {
                Label("\(model.unreadCount)", systemImage: "tray.full").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "tray")
            }
        }
    }
}

let mainWindowId = "main"

/// New Mail opens a composer window of its own, wherever you are in the app.
struct NewMailCommand: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Mail") { model.compose() }
                .keyboardShortcut("n")
        }
    }
}

/// Opens the separate Ask Meetings window, from the Meeting menu or the menu bar icon.
struct AskMeetingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Ask Meetings") {
            openWindow(id: askWindowId)
            NSApp.activate()
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // A snapshot run stays in the background, so it never takes the keyboard from whoever is working.
        guard ProcessInfo.processInfo.environment["POSTVAK_SNAPSHOT_DIR"] == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
    // The app keeps running so sync, the outbox and the MCP server stay available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A minimized mail is easy to forget, so quitting asks first while one holds unsaved text.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = ComposerWindow.unsaved
        guard !unsaved.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = unsaved.count == 1 ? "You are still writing a mail." : "You are still writing \(unsaved.count) mails."
        a.informativeText = "Quitting now loses any text that isn't sent or saved as a draft."
        a.addButton(withTitle: "Show Mail")
        a.addButton(withTitle: "Quit Anyway")
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateNow }
        unsaved.forEach { $0.bringForward() }
        return .terminateCancel
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if model.isRecording, let start = model.recordingStartedAt {
            Text("Recording since \(start.formatted(date: .omitted, time: .shortened))")
            Button("Stop Recording") { model.stopRecording() }
        } else {
            Button("Record Call") { model.startRecording() }
            Button("Record In-Person Meeting") { model.startRecording(captureSystem: false) }
        }
        Divider()
        Text("\(model.unreadCount) unread")
        Button("New Mail") { model.compose() }
        ReviewDraftsMenuItem(review: model.draftReview)
        AskMeetingsButton()
        Button("Open Postvak") {
            openWindow(id: mainWindowId)
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

/// "Review Drafts" in the menu bar, with how many wait.
private struct ReviewDraftsMenuItem: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var review: DraftReview
    var body: some View {
        Button(review.pending.isEmpty ? "Review Drafts" : "Review Drafts (\(review.pending.count))") { model.showDraftReview() }
    }
}
