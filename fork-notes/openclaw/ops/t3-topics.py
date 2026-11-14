#!/usr/bin/env python3
"""Project topics in Dronk's Telegram group "OpenClaw - Mac Mini M6".

One forum topic per T3 project. t3-watch.py posts a project's cards to its topic (the T3 topic
otherwise), and the "Close topic" button in the dronk-telegram plugin calls `close`.

  t3-topics.py icons                                   emojis Telegram allows as topic icons
  t3-topics.py open --project <id|title> [--name N] [--emoji E]   create, or reopen a closed one
  t3-topics.py close (--topic N | --project <id|title>)
  t3-topics.py list

Map: ~/.t3-watch-topics.json {"projects": {projectId: {"topic", "name", "closed"}}}. The bot token
is read here and never printed.
"""
import argparse
import fcntl
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
GROUP = -1003914415301
T3_TOPIC = 5
TOKEN_FILE = f"{HOME}/.openclaw/secrets/telegram-bot-token"
TOPICS = f"{HOME}/.t3-watch-topics.json"
ICONS = f"{HOME}/.cache/t3-topic-icons.json"
DB = f"{HOME}/.t3/userdata/statev2.sqlite"


def api(method, **params):
    token = open(TOKEN_FILE).read().strip()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(params).encode(), headers={"content-type": "application/json"},
    )
    try:
        body = json.loads(urllib.request.urlopen(req, timeout=20).read())
    except urllib.error.HTTPError as e:
        body = json.loads(e.read() or b"{}")
    if not body.get("ok"):
        raise SystemExit(f"telegram {method} failed: {body.get('description', 'unknown error')}")
    return body["result"]


def icons():
    try:
        return json.load(open(ICONS))
    except (OSError, ValueError):
        found = {s["emoji"]: s["custom_emoji_id"] for s in api("getForumTopicIconStickers") if s.get("emoji")}
        os.makedirs(os.path.dirname(ICONS), exist_ok=True)
        json.dump(found, open(ICONS, "w"), ensure_ascii=False)
        return found


def project(ref):
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    try:
        rows = con.execute(
            "select project_id, title from projection_projects where deleted_at is null"
            " and (project_id = ? or lower(title) = lower(?))", (ref, ref),
        ).fetchall()
    finally:
        con.close()
    if len(rows) != 1:
        raise SystemExit(f"no single T3 project matches {ref!r}; use the id from t3_project_list")
    return rows[0]


class Topics:
    """The project-to-topic map, locked for the whole command."""

    def __enter__(self):
        self.lock = open(TOPICS + ".lock", "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            self.data = json.load(open(TOPICS))
        except (OSError, ValueError):
            self.data = {"projects": {}}
        return self.data["projects"]

    def __exit__(self, *exc):
        if exc[0] is None:
            tmp = TOPICS + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.data, f, ensure_ascii=False, indent=1)
            os.chmod(tmp, 0o600)
            os.replace(tmp, TOPICS)
        self.lock.close()


def link(topic):
    return f"https://t.me/c/{str(GROUP)[4:]}/{topic}"


def cmd_open(args):
    pid, title = project(args.project)
    name = (args.name or title)[:128]
    icon_id = None
    if args.emoji:
        icon_id = icons().get(args.emoji)
        if not icon_id:
            raise SystemExit(f"{args.emoji} is not a topic icon; pick one from `t3-topics.py icons`")
    with Topics() as projects:
        entry = projects.get(pid)
        if entry and not entry.get("closed"):
            state = "exists"
        elif entry:
            api("reopenForumTopic", chat_id=GROUP, message_thread_id=entry["topic"])
            entry["closed"] = False
            state = "reopened"
        else:
            params = {"chat_id": GROUP, "name": name}
            if icon_id:
                params["icon_custom_emoji_id"] = icon_id
            topic = api("createForumTopic", **params)["message_thread_id"]
            entry = projects[pid] = {"topic": topic, "name": name, "closed": False}
            api("sendMessage", chat_id=GROUP, message_thread_id=topic,
                text=f"Topic for the T3 project {title}. Its approval cards and job updates land here.")
            state = "created"
    print(json.dumps({"state": state, "project": title, "projectId": pid, "topic": entry["topic"],
                      "name": entry["name"], "link": link(entry["topic"])}, ensure_ascii=False))


def cmd_close(args):
    with Topics() as projects:
        if args.project:
            pid = project(args.project)[0]
        else:
            pid = next((p for p, e in projects.items() if e["topic"] == args.topic), None)
        entry = projects.get(pid)
        if not entry:
            raise SystemExit("that topic is not a project topic")
        if not entry.get("closed"):
            api("sendMessage", chat_id=GROUP, message_thread_id=entry["topic"],
                text="Topic closed. Ask Dronk in the T3 topic to reopen it when there is new work.")
            api("closeForumTopic", chat_id=GROUP, message_thread_id=entry["topic"])
            entry["closed"] = True
    print(json.dumps({"state": "closed", "topic": entry["topic"], "name": entry["name"]}, ensure_ascii=False))


def cmd_list(_args):
    with Topics() as projects:
        rows = [{"projectId": p, **e, "link": link(e["topic"])} for p, e in projects.items()]
    print(json.dumps(rows, ensure_ascii=False, indent=1))


def main():
    parser = argparse.ArgumentParser(description="Project topics in Dronk's Telegram group")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("icons")
    p = sub.add_parser("open")
    p.add_argument("--project", required=True)
    p.add_argument("--name")
    p.add_argument("--emoji")
    p = sub.add_parser("close")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--topic", type=int)
    g.add_argument("--project")
    sub.add_parser("list")
    args = parser.parse_args()
    if args.command == "icons":
        print(" ".join(icons()))
    else:
        {"open": cmd_open, "close": cmd_close, "list": cmd_list}[args.command](args)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        sys.exit(f"error: {e}")
