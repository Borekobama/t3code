#!/usr/bin/env python3
"""Telegram alerts when a T3 thread changes to a state that needs the user.

Polls `t3 thread list` for every active project, compares each thread's status with the
previous run, and sends one Telegram message per change through `openclaw message send`.
No model is called. The first run only records state, so it never floods old threads.

Alerts: waiting (approval or answer needed), completed, failed, interrupted.
"""
import json
import os
import sqlite3
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
NODE = f"{HOME}/.local/share/vite-plus/js_runtime/node/26.12.1/bin/node"
T3 = f"{HOME}/t3-fork/current/apps/server/dist/bin.mjs"
T3_HOME = f"{HOME}/.t3"
DB = f"{T3_HOME}/userdata/statev2.sqlite"
OPENCLAW = f"{HOME}/.openclaw/bin/openclaw"
STATE = f"{HOME}/.t3-watch-state.json"
TELEGRAM_TO = "640306272"
LINK_BASE = "https://mac-mini-m6.tail5d38a1.ts.net:8443/"
MESSAGES = {
    "waiting": "waits for you (approval or answer)",
    "completed": "finished",
    "failed": "failed",
    "interrupted": "was interrupted",
}


def projects():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        rows = con.execute(
            "select project_id, title from projection_projects"
            " where deleted_at is null and archived_at is null"
        ).fetchall()
    finally:
        con.close()
    return rows


def threads(project_id):
    out = subprocess.run(
        [NODE, T3, "thread", "list", "--base-dir", T3_HOME, "--project", project_id, "--json"],
        capture_output=True, text=True, timeout=60,
    )
    if out.returncode != 0:
        raise RuntimeError(f"thread list failed for {project_id}: {out.stderr.strip()[:200]}")
    data = json.loads(out.stdout)
    return data if isinstance(data, list) else data.get("threads", [])


def pending_requests():
    """Pending approvals and questions; a thread waiting on one still reports status "running"."""
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        rows = con.execute(
            "select runtime_request_id, thread_id, kind"
            " from orchestration_v2_projection_runtime_requests where status = 'pending'"
        ).fetchall()
    finally:
        con.close()
    return {rid: (tid, kind) for rid, tid, kind in rows}


def request_text(kind):
    return "asks you a question" if kind in ("user_input", "question", "elicitation") else f"needs your approval ({kind})"


def link(thread):
    url = thread.get("link") or ""
    marker = "/threads/"
    return LINK_BASE + url.split(marker, 1)[1] if marker in url else LINK_BASE


def send(text):
    subprocess.run(
        [OPENCLAW, "message", "send", "--channel", "telegram", "-t", TELEGRAM_TO, "-m", text],
        capture_output=True, text=True, timeout=60, check=True,
    )


def main():
    try:
        previous = json.load(open(STATE))
    except (OSError, ValueError):
        previous = None  # first run: record only
    if previous is not None and "threads" not in previous:  # state file from the first version
        previous = {"threads": previous, "requests": []}
    prev_threads = (previous or {}).get("threads", {})
    prev_requests = set((previous or {}).get("requests", []))
    current, known, alerts = {}, {}, []
    for project_id, project_title in projects():
        for t in threads(project_id):
            tid, status = t.get("threadId"), t.get("status")
            if not tid or not status:
                continue
            known[tid.split(":", 1)[-1]] = (t, project_title)
            key = f"{tid}|{t.get('latestRunId')}"
            current[tid] = {"status": status, "key": key}
            before = prev_threads.get(tid)
            changed = before is None or before["status"] != status or before["key"] != key
            # Unchanged threads stay quiet; a new or changed thread alerts once per state.
            if previous is not None and changed and status in MESSAGES:
                alerts.append(f"T3: \"{t.get('title') or 'thread'}\" ({project_title}) {MESSAGES[status]}\n{link(t)}")
    pending = pending_requests()
    if previous is not None:
        for rid, (tid, kind) in pending.items():
            if rid in prev_requests:
                continue
            t, project_title = known.get(tid.split(":", 1)[-1], ({}, "unknown project"))
            alerts.append(f"T3: \"{t.get('title') or 'thread'}\" ({project_title}) {request_text(kind)}\n{link(t)}")
    for text in alerts:
        send(text)
        time.sleep(1)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"threads": current, "requests": sorted(pending)}, f)
    os.replace(tmp, STATE)
    print(f"{time.strftime('%H:%M:%S')} threads={len(current)} pending={len(pending)} alerts={len(alerts)}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # keep launchd quiet but leave a trace
        print(f"{time.strftime('%H:%M:%S')} error: {e}", file=sys.stderr)
        sys.exit(1)
