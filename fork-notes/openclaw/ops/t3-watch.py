#!/usr/bin/env python3
"""Telegram alerts when a T3 thread needs the user, with approval buttons.

Runs every 15 s from launchd. Each run checks pending approvals and questions in T3's
database (cheap). Every 2 minutes it also polls `t3 thread list` for every active project
and alerts on thread status changes. Messages go out through `openclaw message send`.
No model is called. The first run only records state, so it never floods old threads.

Approval cards carry Approve / Decline buttons. The OpenClaw plugin `dronk-telegram`
(ops/openclaw-plugin) answers the taps with `t3 thread respond`, using the request map
this script writes to ~/.t3-watch-requests.json.
"""
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from urllib.parse import quote

HOME = os.path.expanduser("~")
NODE = f"{HOME}/.local/share/vite-plus/js_runtime/node/26.12.1/bin/node"
T3 = f"{HOME}/t3-fork/current/apps/server/dist/bin.mjs"
T3_HOME = f"{HOME}/.t3"
DB = f"{T3_HOME}/userdata/statev2.sqlite"
OPENCLAW = f"{HOME}/.openclaw/bin/openclaw"
STATE = f"{HOME}/.t3-watch-state.json"
REQUESTS = f"{HOME}/.t3-watch-requests.json"
TELEGRAM_TO = "640306272"
LINK_BASE = "https://mac-mini-m6.tail5d38a1.ts.net:8443/"
THREAD_SCAN_SECONDS = 120
COMMAND_MAX = 700
KEEP_REQUESTS = 200
STATUS = {
    "waiting": "⏸️ waits for you",
    "completed": "✅ finished",
    "failed": "❌ failed",
    "interrupted": "⏹️ was interrupted",
}
QUESTION_KINDS = ("user_input", "question", "elicitation")


def query(sql, *args):
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


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
    rows = query(
        "select r.runtime_request_id, r.thread_id, r.kind, r.payload_json, t.title, p.title"
        " from orchestration_v2_projection_runtime_requests r"
        " left join orchestration_v2_projection_threads t on t.thread_id = r.thread_id"
        " left join projection_projects p on p.project_id = t.project_id"
        " where r.status = 'pending'"
    )
    return {rid: rest for rid, *rest in rows}


def requested_action(thread_id, payload_json):
    """What the agent wants to do: the command, or the file it wants to change."""
    try:
        native = json.loads(payload_json)["nativeRequestRef"]["nativeId"]
    except (ValueError, KeyError, TypeError):
        return None
    for (item_json,) in query(
        "select payload_json from orchestration_v2_projection_turn_items"
        " where thread_id = ? and type in ('command_execution', 'file_change', 'dynamic_tool')",
        thread_id,
    ):
        item = json.loads(item_json)
        if (item.get("nativeItemRef") or {}).get("nativeId") != native:
            continue
        if isinstance(item.get("input"), str):
            return item["input"]
        if item.get("fileName"):
            return f"edit {item['fileName']}"
        return item.get("title") or item.get("toolName")
    return None


def thread_link(env_id, thread_id):
    return f"{LINK_BASE}{env_id}/{quote(thread_id, safe='')}" if env_id else LINK_BASE


def link_from_list(thread):
    url = thread.get("link") or ""
    marker = "/threads/"
    return LINK_BASE + url.split(marker, 1)[1] if marker in url else LINK_BASE


def esc(text):
    """Keep titles from turning into Markdown formatting."""
    return "".join("\\" + c if c in "*_`[]" else c for c in text)


def send(text, rows):
    """One buttons block per row of buttons."""
    blocks = [{"type": "text", "text": text}] + [{"type": "buttons", "buttons": row} for row in rows]
    presentation = {"blocks": blocks}
    subprocess.run(
        [OPENCLAW, "message", "send", "--channel", "telegram", "-t", TELEGRAM_TO,
         "--presentation", json.dumps(presentation)],
        capture_output=True, text=True, timeout=60, check=True,
    )


def open_button(url):
    return {"label": "Open in T3", "action": {"type": "url", "url": url}}


def request_card(rid, tid, kind, payload_json, title, project, env_id):
    head = f"**{esc(title or 'T3 thread')}** · {esc(project or 'unknown project')}"
    link = thread_link(env_id, tid)
    if kind in QUESTION_KINDS:
        return f"❓ {head}\nasks you a question. Answer it in T3.", [[open_button(link)]], None
    action = requested_action(tid, payload_json)
    body = f"🔐 {head}\nwants to run:" if kind == "command" else f"🔐 {head}\nneeds your approval ({kind}):"
    if action:
        shown = action if len(action) <= COMMAND_MAX else action[:COMMAND_MAX] + " …"
        body += f"\n```\n{shown.replace('```', '` ` `')}\n```"
    short = hashlib.sha256(rid.encode()).hexdigest()[:10]
    buttons = [
        [
            {"label": "✅ Approve", "action": {"type": "callback", "value": f"t3:a:{short}"}, "style": "success"},
            {"label": "Decline", "action": {"type": "callback", "value": f"t3:d:{short}"}, "style": "danger"},
        ],
        [open_button(link)],
    ]
    return body, buttons, (short, {"threadId": tid, "requestId": rid, "text": body, "at": time.time()})


def save(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main():
    try:
        previous = json.load(open(STATE))
    except (OSError, ValueError):
        previous = None  # first run: record only
    if previous is not None and "threads" not in previous:  # state file from the first version
        previous = {"threads": previous, "requests": []}
    state = previous or {}
    prev_threads = state.get("threads", {})
    prev_requests = set(state.get("requests", []))
    env_id = state.get("env")
    current, alerts = prev_threads, []

    scan = previous is None or time.time() - state.get("scannedAt", 0) >= THREAD_SCAN_SECONDS
    if scan:
        current = {}
        for project_id, project_title in query(
            "select project_id, title from projection_projects where deleted_at is null and archived_at is null"
        ):
            for t in threads(project_id):
                tid, status = t.get("threadId"), t.get("status")
                if not tid or not status:
                    continue
                url = link_from_list(t)
                if url != LINK_BASE:
                    env_id = url[len(LINK_BASE):].split("/", 1)[0]
                key = f"{tid}|{t.get('latestRunId')}"
                current[tid] = {"status": status, "key": key}
                before = prev_threads.get(tid)
                changed = before is None or before["status"] != status or before["key"] != key
                # Unchanged threads stay quiet; a new or changed thread alerts once per state.
                if previous is not None and changed and status in STATUS:
                    text = f"{STATUS[status]}: **{esc(t.get('title') or 'thread')}** · {esc(project_title)}"
                    alerts.append((text, [[open_button(url)]], None))

    pending = pending_requests()
    if previous is not None:
        for rid, (tid, kind, payload_json, title, project) in pending.items():
            if rid not in prev_requests:
                alerts.append(request_card(rid, tid, kind, payload_json, title, project, env_id))

    requests = {}
    try:
        requests = json.load(open(REQUESTS))
    except (OSError, ValueError):
        pass
    for text, rows, mapping in alerts:
        if mapping:
            requests[mapping[0]] = mapping[1]
            save(REQUESTS, dict(sorted(requests.items(), key=lambda kv: -kv[1].get("at", 0))[:KEEP_REQUESTS]))
        send(text, rows)
        time.sleep(1)

    save(STATE, {
        "threads": current,
        "requests": sorted(pending),
        "env": env_id,
        "scannedAt": time.time() if scan else state.get("scannedAt", 0),
    })
    if scan or alerts:
        print(f"{time.strftime('%H:%M:%S')} threads={len(current)} pending={len(pending)} alerts={len(alerts)}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # keep launchd quiet but leave a trace
        print(f"{time.strftime('%H:%M:%S')} error: {e}", file=sys.stderr)
        sys.exit(1)
