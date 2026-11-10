#!/usr/bin/env python3
"""Copies past meetings from Anarlog into Postvak, through Postvak's own MCP endpoint.

Postvak must be running. Reads through the `anarlog` command, so Anarlog's database is never opened directly.
Importing twice updates the same meetings instead of duplicating them.

A meeting Postvak already has from another source (its own recording or a Granola import starting within
10 minutes) is not added twice: when that meeting has no transcript yet, Anarlog's transcript is added to it,
and a meeting Postvak recorded itself is left as it is. Postvak's database is only read, to find those matches.
Meetings with neither a transcript nor a summary, and Anarlog's own sample meeting, are skipped.

Usage:
  Scripts/import_anarlog.py [--url http://127.0.0.1:7444/mcp] [--limit N] [--dry-run]
The MCP token is read from the Keychain (macOS asks once; click Always Allow), or from POSTVAK_MCP_TOKEN if set.
"""
import argparse, json, os, re, shutil, sqlite3, subprocess, sys, urllib.request
from datetime import datetime, timezone

ANARLOG = shutil.which("anarlog") or os.path.expanduser("~/.local/bin/anarlog")
PAUSE_MS = 1500
MATCH_SECONDS = 10 * 60
POSTVAK_DB = os.path.expanduser(os.environ.get("POSTVAK_DATA_DIR", "~/Library/Application Support/Postvak") + "/postvak.sqlite")
SPEAKERS = {0: "Me", 1: "Others"}


def run(*args):
    out = subprocess.run([ANARLOG, *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def segments(transcript):
    """Groups word timings into speaker turns: a new segment on a channel change or a long pause."""
    words = sorted(transcript.get("words") or [], key=lambda w: w.get("start_ms", 0))
    if not words:
        text = (transcript.get("text") or "").strip()
        return [{"text": text, "speaker": "Unknown"}] if text else []
    offset = transcript.get("started_at_ms", 0) if words[0].get("start_ms", 0) > 100_000_000_000 else 0
    out, cur = [], None
    for w in words:
        ch, start, end = w.get("channel", 0), w.get("start_ms", 0) - offset, w.get("end_ms", 0) - offset
        if cur is None or cur["channel"] != ch or start - cur["end_ms"] > PAUSE_MS:
            cur = {"channel": ch, "start_ms": start, "end_ms": end, "parts": []}
            out.append(cur)
        cur["end_ms"] = end
        cur["parts"].append(w.get("text", ""))
    result = []
    for s in out:
        text = re.sub(r"\s+", " ", "".join(p if p.startswith(" ") else " " + p for p in s["parts"])).strip()
        if text:
            result.append({"start": s["start_ms"] / 1000, "end": s["end_ms"] / 1000,
                           "speaker": SPEAKERS.get(s["channel"], "Speaker"), "text": text})
    return result


def to_arguments(m):
    summary = "\n\n".join(s.get("markdown", "") for s in m.get("summaries") or [] if s.get("markdown"))
    if not summary and (m.get("note") or {}).get("markdown"):
        summary = m["note"]["markdown"]
    segs = [s for t in m.get("transcripts") or [] for s in segments(t)]
    people = []
    for p in m.get("participants") or []:
        name, email = p.get("display_name") or "", p.get("email") or ""
        people.append(f"{name} <{email}>" if name and email else (email or name))
    args = {"source": "anarlog", "source_id": m["id"], "title": m.get("title") or "Untitled meeting",
            "started_at": m.get("started_at") or m["created_at"], "attendees": [p for p in people if p], "transcript": segs}
    if m.get("ended_at"):
        args["ended_at"] = m["ended_at"]
    language = m.get("language") or next((t["language"] for t in m.get("transcripts") or [] if t.get("language")), None)
    if language:
        args["language"] = language
    if summary:
        args["summary"] = summary
    return args


def parse_time(text):
    """ISO 8601 from Anarlog, or GRDB's 'YYYY-MM-DD HH:MM:SS.SSS' in UTC from Postvak."""
    text = text.strip().replace("Z", "+00:00")
    if "T" not in text:
        text = text.replace(" ", "T") + "+00:00"
    return datetime.fromisoformat(text).astimezone(timezone.utc)


def postvak_meetings(path):
    """Meetings Postvak has from other sources, read-only, with their transcript size."""
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    rows = db.execute("""SELECT m.source, m.sourceId, m.title, m.startedAt, m.endedAt, m.attendeesJSON,
                                (SELECT count(*) FROM transcript_segment s WHERE s.meetingId = m.id)
                         FROM meeting m WHERE m.source != 'anarlog'""").fetchall()
    db.close()
    return [{"source": r[0], "source_id": r[1], "title": r[2], "start": parse_time(r[3]), "started_at": r[3],
             "ended_at": r[4], "attendees": json.loads(r[5] or "[]"), "segments": r[6]} for r in rows]


def match(existing, started_at):
    """The meeting from another source that starts closest to this one, within MATCH_SECONDS."""
    start = parse_time(started_at)
    near = [(abs((e["start"] - start).total_seconds()), e) for e in existing]
    near = [n for n in near if n[0] <= MATCH_SECONDS]
    return min(near, key=lambda n: n[0])[1] if near else None


def merged_into(e, args):
    """import_meeting arguments that add Anarlog's transcript to an existing Granola meeting, keeping its own title,
    time and summary, and adding Anarlog's attendees to its own."""
    people = [f"{a['name']} <{a['email']}>" if a.get("name") and a.get("email") else (a.get("email") or a.get("name") or "")
              for a in e["attendees"]]
    known = {p.lower() for p in people}
    people += [p for p in args["attendees"] if p.lower() not in known]
    out = {"source": e["source"], "source_id": e["source_id"], "title": e["title"],
           "started_at": parse_time(e["started_at"]).isoformat(), "attendees": [p for p in people if p], "transcript": args["transcript"]}
    ended = e["ended_at"] and parse_time(e["ended_at"]).isoformat() or args.get("ended_at")
    if ended:
        out["ended_at"] = ended
    if args.get("language"):
        out["language"] = args["language"]
    return out


def keychain_token():
    """The token Postvak keeps in the Keychain, or None."""
    service = os.environ.get("POSTVAK_KEYCHAIN_SERVICE", "be.postvak.app")
    r = subprocess.run(["security", "find-generic-password", "-s", service, "-a", "mcp.token", "-w"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def call(url, token, name, arguments):
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        result = json.load(r)["result"]
    return result["isError"], result["content"][0]["text"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:7444/mcp")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--dry-run", action="store_true", help="Show what would happen without changing Postvak.")
    a = ap.parse_args()
    token = os.environ.get("POSTVAK_MCP_TOKEN") or (None if a.dry_run else keychain_token())
    if not token and not a.dry_run:
        sys.exit("No Postvak MCP token found. Start Postvak once, or set POSTVAK_MCP_TOKEN from Settings, Claude, Show Token.")
    existing = postvak_meetings(POSTVAK_DB)

    meetings, offset = [], 0
    while True:
        page = run("meetings", "list", "--json", "--limit", "200", "--offset", str(offset))["data"]
        items = page if isinstance(page, list) else next(v for v in page.values() if isinstance(v, list))
        meetings += items
        offset += len(items)
        if len(items) < 200:
            break
    if a.limit:
        meetings = meetings[: a.limit]

    counts = {"imported": 0, "transcript added": 0, "kept": 0, "empty": 0, "failed": 0}
    segs = 0
    for item in meetings:
        try:
            args = to_arguments(run("meetings", "export", item["id"], "--format", "json"))
            label = f"{args['started_at'][:16]}  {args['title']}"
            if not args["transcript"] and not args.get("summary") or args["title"] == "Welcome to Anarlog":
                counts["empty"] += 1
                print(f"skip, empty          {label}")
                continue
            e = match(existing, args["started_at"])
            if e and (e["segments"] or not args["transcript"] or not e["source_id"]):
                counts["kept"] += 1
                print(f"skip, Postvak has it {label}  =  {e['source']}: {e['title']}")
                continue
            if e:
                args, outcome = merged_into(e, args), "transcript added"
                print(f"add transcript       {label}  ->  {e['source']}: {e['title']}")
            else:
                outcome = "imported"
                print(f"import               {label}")
            if not a.dry_run:
                is_error, text = call(a.url, token, "import_meeting", args)
                if is_error:
                    raise RuntimeError(text)
            counts[outcome] += 1
            segs += len(args["transcript"])
        except Exception as ex:
            counts["failed"] += 1
            print(f"Failed {item['id']}: {ex}", file=sys.stderr)
    verb = "Would import or update" if a.dry_run else "Imported or updated"
    print(f"{verb} {counts['imported']} meetings and added transcripts to {counts['transcript added']} others "
          f"({segs} segments) out of {len(meetings)}. Already in Postvak: {counts['kept']}. Empty: {counts['empty']}. Failed: {counts['failed']}.")
    sys.exit(1 if counts["failed"] else 0)


if __name__ == "__main__":
    main()
