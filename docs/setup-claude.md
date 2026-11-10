# Connect Claude

Postvak's MCP server runs on this Mac at `http://127.0.0.1:7444/mcp`, while the app is running. Only clients on this Mac can reach it, with a bearer token. Claude on the web or on a phone cannot reach it.

Both Claude Code and Claude Desktop connect through a small script Postvak keeps at `~/Library/Application Support/Postvak/postvak-mcp-bridge`. It reads the token from the Keychain as it starts, so the token is never written into a configuration file. Node.js is required: the script looks for it in the usual places (Homebrew, nvm, Volta, `/usr/local/bin`).

## Claude Code

In **Settings, Claude**, click **Copy Claude Code Command**, then run it in a terminal.

## Claude Desktop

1. In **Settings, Claude**, click **Copy Claude Desktop Config**.
2. Open `~/Library/Application Support/Claude/claude_desktop_config.json` and paste the block inside `mcpServers`.
3. Restart Claude Desktop.

The first time either client connects, macOS asks whether `security` may read the Postvak token from your Keychain. Click **Always Allow**. If Claude reports that the server could not start, run the script by hand in a terminal: it prints what is missing.

## Safeguards

- `send_mail` and `reply` need `confirm_send: true`, and go through the same 5 second undo window as the app, with the same Undo button on screen.
- `delete_event` needs `confirm_delete: true`.
- Claude is told that mail, event and transcript text is third-party data, not instructions. A prompt injection in an incoming mail remains a real risk with any mail tool, so review what Claude proposes to send.

## Bring your meeting history

**Anarlog** (Postvak must be running; the script reads the token from the Keychain):

```bash
Scripts/import_anarlog.py
```

**Granola** has no export to script against, and its local files are encrypted. With both connected, ask Claude:

> Go through all my Granola meetings. For each one, read the notes and, if available, the transcript. Then call Postvak's import_meeting with source "granola", the Granola id as source_id, the title, date, attendees, summary and transcript.

Granola's free plan only exposes the last 30 days through its connector, and transcripts need a paid plan. To keep older meetings, upgrade for a month before importing, or export what you need from Granola itself.

Importing the same meeting twice updates it rather than duplicating it.

## Switching off Spark

Once Postvak has run for a few days, remove the Spark plugin from Claude so Claude has one mail source, then quit Spark.
