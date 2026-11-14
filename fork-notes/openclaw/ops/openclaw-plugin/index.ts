// Dronk's Telegram plugin (runs inside the OpenClaw Gateway): answers the T3 cards from t3-watch.py
// ("t3:<a|s|d|f>:<id>", f = full access for the current task), and puts the part of a reply after a
// "[[details]]" line behind a Details button ("more:<id>"). See runbook.md, "Telegram alerts for T3 threads".
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
// Full-access grants; t3-watch.py switches the thread back to Supervised when the run ends.
const GRANTS = NodePath.join(HOME, ".t3-watch-grants.json");
const BASE_DIR = ["--base-dir", NodePath.join(HOME, ".t3")];
const ACTIVE = new Set(["queued", "preparing", "starting", "running", "waiting"]);
const RESUME =
  "The user switched this thread to full access, which interrupted your last step. Continue the task from where you stopped.";
const DETAILS = NodePath.join(HOME, ".openclaw/state/telegram-details.json");
const MARKER = /^\s*\[\[details\]\]\s*$/im;
const KEEP_DETAILS = 300;
const DECISIONS: Record<string, { decision: string; label: string }> = {
  a: { decision: "accept", label: "✅ Approved" },
  s: { decision: "acceptForSession", label: "✅ Approved for this session" },
  d: { decision: "decline", label: "❌ Declined" },
};

type Request = { threadId: string; requestId?: string; text: string; status?: string };
type Result = { ok: boolean; detail: string; stdout: string };

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

function t3(args: string[]) {
  return new Promise<Result>((resolve) => {
    NodeChildProcess.execFile(
      T3,
      [...args.slice(0, 2), ...BASE_DIR, ...args.slice(2)],
      { timeout: 90_000 },
      (error, stdout, stderr) => {
        const detail = (stderr || stdout || error?.message || "").trim().split("\n").pop() ?? "";
        resolve({ ok: !error, detail, stdout });
      },
    );
  });
}

// Claude sessions cannot change mode in place: T3 restarts the session and the active run fails,
// so the task is resumed with a follow-up message, which runs in full access.
async function fullAccessForTask(threadId: string): Promise<Result> {
  const shown = await t3(["thread", "show", threadId, "--messages", "1", "--json"]);
  if (!shown.ok) return shown;
  if (!ACTIVE.has(JSON.parse(shown.stdout).thread?.status)) {
    return { ok: false, detail: "this job is not running anymore", stdout: "" };
  }
  const mode = await t3(["thread", "mode", threadId, "full-access"]);
  if (!mode.ok) return mode;
  const sent = await t3(["thread", "send", threadId, RESUME, "--json"]);
  if (!sent.ok) return { ...sent, detail: `switched, but resuming failed: ${sent.detail}` };
  const grants = readJson<Record<string, { runId: string; at: number }>>(GRANTS, {});
  grants[threadId] = { runId: JSON.parse(sent.stdout).runId, at: Date.now() };
  writeJson(GRANTS, grants);
  return sent;
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
        const choice =
          code === "f"
            ? {
                decision: "full-access",
                label: "⚡ Full access for this task. Back to Supervised when it ends.",
              }
            : DECISIONS[code];
        const requests = readJson<Record<string, Request>>(REQUESTS, {});
        const request = id ? requests[id] : undefined;
        if (!choice || !request || (code !== "f" && !request.requestId)) {
          await ctx.respond.clearButtons();
          await ctx.respond.reply({ text: "That card is no longer known here. Check T3." });
          return { handled: true };
        }
        await ctx.respond.editMessage({ text: `${request.text}\n\n⏳ Sending…` });
        const result =
          code === "f"
            ? await fullAccessForTask(request.threadId)
            : await t3([
                "thread",
                "respond",
                "--decision",
                choice.decision,
                request.threadId,
                request.requestId!,
              ]);
        const footer = result.ok
          ? choice.label
          : `⚠️ Not done: ${result.detail || "unknown error"}`;
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
