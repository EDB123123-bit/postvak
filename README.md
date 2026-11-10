# Postvak

A native Mac app that replaces Spark Desktop for one person: unified mail and agenda across several Gmail accounts, local meeting recording and transcription, and all of it available to Claude through a local MCP server. All data stays on this Mac, apart from what goes to Google and to the Claude API; see [Privacy and security](#privacy-and-security) for the full list.

## Build and run

Needs the Xcode command line tools only.

```bash
Scripts/build_app.sh
```

```bash
open build/Postvak.app
```

On first launch a short guide walks you through connecting your Google accounts, the optional Anthropic key, meeting recording and Claude, and shows where everything is. Open it again from **Help → Postvak Guide**. The full steps are in [docs/setup-google.md](docs/setup-google.md) and [docs/setup-claude.md](docs/setup-claude.md).

## Try it on fictional data

```bash
swift build --product postvak-dev && POSTVAK_DATA_DIR=/tmp/postvak-demo .build/debug/postvak-dev seed
```

```bash
POSTVAK_DEMO=1 POSTVAK_DATA_DIR=/tmp/postvak-demo build/Postvak.app/Contents/MacOS/Postvak
```

Demo mode uses a separate folder, stores nothing in the Keychain and never contacts Google.

## Tests

```bash
swift run postvak-tests --no-parallel
```

A plain executable target, because `swift test` does not run Swift Testing without full Xcode.

## Layout

| Path | What |
|---|---|
| `Sources/PostvakCore` | SQLite store, Google sign-in, Gmail and Calendar sync, outbox, snooze, signatures |
| `Sources/PostvakAI` | Claude API client, inbox classifier, meeting summaries, the Ask Meetings chat |
| `Sources/PostvakAudio` | System audio and mic capture, WhisperKit, SpeakerKit, Deepgram, meeting pipeline |
| `Sources/PostvakMCP` | MCP server and its tools |
| `Sources/Postvak` | SwiftUI app |
| `Sources/postvak-dev` | Demo seed and test commands. Refuses to run without `POSTVAK_DATA_DIR` |
| `Scripts` | App bundling, icon, Anarlog import |

## Good to know

- **It has to be running.** Scheduled mail, snooze and Claude's access only work while Postvak runs. Closing the window keeps it in the menu bar. Mail scheduled while it was closed waits for a decision, and is never sent unannounced.
- **The signature is ad hoc.** After each rebuild macOS may ask again for Keychain, microphone and system audio access, because it treats the new build as a new app.
- **Recurring events** can be created, but editing changes one occurrence only.
- **Recording laws** differ per country. Tell people before you record them.

## Privacy and security

Postvak is built for one person's own Mac. Each user brings their own Google Cloud project and their own API keys: nothing of the author's is in the code or the repository.

**Where your data lives.** Everything is in `~/Library/Application Support/Postvak`: the SQLite database with mail, calendar and transcripts, downloaded attachments, meeting recordings and the transcription models. Postvak does not encrypt it itself; FileVault protects it at rest, and Time Machine backs it up along with the rest of your home folder. Removing an account in Settings deletes its local mail and its saved sign-in; the folder can be deleted to remove everything.

**Secrets.** Your Google client ID and secret, the refresh token of each account, the Anthropic key, the optional Deepgram key and the MCP token live in the macOS Keychain under the service `be.postvak.app`. Nothing is written to files or settings, and nothing is logged. Google access tokens are kept in memory only.

**What leaves your Mac.**

| Destination | When | What |
|---|---|---|
| Google (Gmail and Calendar APIs) | While running | Your mail and calendar, through your own OAuth client |
| Anthropic (Claude API) | Only with your API key | Inbox sorting: sender, subject and 300 characters of threads Gmail's categories miss. Meeting summaries, Ask, follow-up drafts, prep briefs and deals: the transcripts, mail and notes those features read. The send check: the draft and its thread. Each pane in Settings → AI says what its feature sends, and can be switched off |
| Hugging Face | First meeting transcribed locally | Downloads the WhisperKit and speaker models, about 650 MB. No data of yours goes out |
| Deepgram | Only for a meeting where you choose cloud transcription | That meeting's audio |
| cal.com | Only when you insert a booking card | Your public cal.com username and the dates asked for; no key is needed |

There is no telemetry, no crash reporting and no update check.

**Mail rendering.** HTML mail is shown with scripts off, in a web view that keeps no cookies or cache. Every remote load (images, stylesheets, fonts, frames, link pings) is blocked until you click Show on that mail, so a sender does not learn that you opened it. The mail pane never navigates away from the mail: links open in your browser, and a meta refresh, form or frame inside a mail does nothing.

**The MCP server.** It listens on `127.0.0.1` only, while the app runs, and answers only requests that carry its bearer token; a browser page cannot reach it because of the Origin check. The token is random and kept in the Keychain. Claude Code and Claude Desktop connect through a small bridge script that reads the token from the Keychain as it starts, so no configuration file ever holds it. **New Token** in Settings → Claude revokes the old one. `send_mail` and `reply` need `confirm_send: true` and pass through the same 5 second undo window as the app; `delete_event` needs `confirm_delete: true`. Creating or changing events and setting a signature take effect immediately.

**Prompt injection.** Claude is told that mail, event descriptions and transcripts are third-party data, not instructions, and the Ask chat can only read. Any mail tool connected to an AI assistant still carries this risk: read what Claude proposes to send before you confirm it.

**Recording.** Recordings start by hand unless you switch on automatic recording under Settings → Meetings. With it on, calls in Zoom, Teams and Webex and calendar meetings you accepted are recorded, and a notification appears each time with a button to stop. Tell people before you record them.

Found a problem? Open an issue, or if it could expose someone's data, write to the maintainer first.

## For the maintainer: publishing

Development happens on private branches that hold the maintainer's own test data and never leave their Mac. Only the branch `public` goes to GitHub, as one clean commit per release:

```bash
Scripts/publish.sh "What changed"
```

It installs `Scripts/git-hooks/pre-push`, which refuses any push that is not the `public` branch, or that contains a word from a private list kept outside the repository, anything shaped like an API key, or a person, address or company found in the maintainer's own Postvak database. Tests and examples therefore use fictional people and companies only.

