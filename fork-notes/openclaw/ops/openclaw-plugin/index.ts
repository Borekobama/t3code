// Dronk's Telegram plugin (runs inside the OpenClaw Gateway): answers the T3 approval cards from
// t3-watch.py ("t3:<a|s|d>:<id>"), and puts the part of a reply after a "[[details]]" line behind a
// Details button ("more:<id>"). See runbook.md, "Telegram alerts for T3 threads".
import * as NodeChildProcess from "node:child_process";
import * as NodeCrypto from "node:crypto";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const OWNER = "640306272";
const HOME = NodeOS.homedir();
const T3 = NodePath.join(HOME, "t3-fork/t3.sh");
const REQUESTS = NodePath.join(HOME, ".t3-watch-requests.json"); // written by t3-watch.py
const DETAILS = NodePath.join(HOME, ".openclaw/state/telegram-details.json");
const MARKER = /^\s*\[\[details\]\]\s*$/im;
const KEEP_DETAILS = 300;
const DECISIONS: Record<string, { decision: string; label: string }> = {
  a: { decision: "accept", label: "✅ Approved" },
  s: { decision: "acceptForSession", label: "✅ Approved for this session" },
  d: { decision: "decline", label: "❌ Declined" },
};

type Request = { threadId: string; requestId: string; text: string; status?: string };

function readJson<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(NodeFS.readFileSync(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

function writeJson(path: string, value: unknown) {
  NodeFS.writeFileSync(`${path}.tmp`, JSON.stringify(value), { mode: 0o600 });
  NodeFS.renameSync(`${path}.tmp`, path);
}

function respond(threadId: string, requestId: string, decision: string) {
  return new Promise<{ ok: boolean; detail: string }>((resolve) => {
    NodeChildProcess.execFile(
      T3,
      [
        "thread",
        "respond",
        "--base-dir",
        NodePath.join(HOME, ".t3"),
        "--decision",
        decision,
        threadId,
        requestId,
      ],
      { timeout: 60_000 },
      (error, stdout, stderr) => {
        const detail = (stderr || stdout || error?.message || "").trim().split("\n").pop() ?? "";
        resolve({ ok: !error, detail });
      },
    );
  });
}

export default definePluginEntry({
  id: "dronk-telegram",
  name: "Dronk Telegram",
  description: "T3 approval buttons and a Details button for long replies.",
  register(api) {
    api.registerInteractiveHandler({
      channel: "telegram",
      namespace: "t3",
      handler: async (ctx: any) => {
        if (ctx.senderId !== OWNER || !ctx.auth?.isAuthorizedSender) return { handled: true };
        const [code, id] = String(ctx.callback.payload).split(":");
        const choice = DECISIONS[code];
        const requests = readJson<Record<string, Request>>(REQUESTS, {});
        const request = id ? requests[id] : undefined;
        if (!choice || !request) {
          await ctx.respond.clearButtons();
          await ctx.respond.reply({ text: "That approval is no longer known here. Check T3." });
          return { handled: true };
        }
        await ctx.respond.editMessage({ text: `${request.text}\n\n⏳ Sending…` });
        const result = await respond(request.threadId, request.requestId, choice.decision);
        const footer = result.ok
          ? choice.label
          : `⚠️ Not answered: ${result.detail || "unknown error"}`;
        await ctx.respond.editMessage({ text: `${request.text}\n\n${footer}` });
        if (result.ok) {
          requests[id] = { ...request, status: choice.decision };
          writeJson(REQUESTS, requests);
        }
        return { handled: true };
      },
    });

    api.registerInteractiveHandler({
      channel: "telegram",
      namespace: "more",
      handler: async (ctx: any) => {
        const id = String(ctx.callback.payload);
        const entry = readJson<Record<string, { short: string; details: string }>>(DETAILS, {})[id];
        if (!entry) {
          await ctx.respond.clearButtons();
          return { handled: true };
        }
        const full = `${entry.short}\n\n${entry.details}`;
        // Telegram caps a message at 4096 characters; longer details come as a reply instead.
        if (full.length <= 4000) await ctx.respond.editMessage({ text: full });
        else {
          await ctx.respond.clearButtons();
          await ctx.respond.reply({ text: entry.details });
        }
        return { handled: true };
      },
    });

    api.on("reply_payload_sending", (event: any) => {
      const text: unknown = event.payload?.text;
      if (event.channel !== "telegram" || typeof text !== "string") return;
      const match = MARKER.exec(text);
      if (!match) return;
      const short = text.slice(0, match.index).trim();
      const details = text.slice(match.index + match[0].length).trim();
      if (!details) return { payload: { ...event.payload, text: short } };
      const id = NodeCrypto.createHash("sha256")
        .update(`${Date.now()}:${text}`)
        .digest("hex")
        .slice(0, 12);
      const store = readJson<Record<string, { short: string; details: string; at: number }>>(
        DETAILS,
        {},
      );
      store[id] = { short, details, at: Date.now() };
      const kept = Object.entries(store)
        .sort((a, b) => b[1].at - a[1].at)
        .slice(0, KEEP_DETAILS);
      writeJson(DETAILS, Object.fromEntries(kept));
      const blocks = [...(event.payload.presentation?.blocks ?? [])];
      blocks.push({
        type: "buttons",
        buttons: [{ label: "Details", action: { type: "callback", value: `more:${id}` } }],
      });
      return {
        payload: {
          ...event.payload,
          text: short,
          presentation: { ...event.payload.presentation, blocks },
        },
      };
    });
  },
});
