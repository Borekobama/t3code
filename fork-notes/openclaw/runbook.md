# Runbook: patched T3 + OpenClaw on the Mac mini

Host `mac-mini-m6`, user `admin`. All commands run on the mini, over `ssh mac-mini-m6` unless noted.
Nothing in this runbook deletes projects, worktrees, thread history, transcripts or login credentials.

## What runs where

| Piece              | How it runs                                                                   | Data                                           | Log                                                                        |
| ------------------ | ----------------------------------------------------------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------- |
| T3 server (fork)   | LaunchAgent `local.t3code-fork`, `127.0.0.1:3773`                             | `~/.t3`                                        | `~/Library/Logs/t3code-fork/server.log` (contains pairing codes, mode 600) |
| T3 releases        | `~/t3-fork/releases/<sha12>` worktrees; `~/t3-fork/current` is live           | none                                           | none                                                                       |
| OpenClaw Gateway   | LaunchAgent `ai.openclaw.gateway`, `127.0.0.1:18789`, token auth              | `~/.openclaw`                                  | `/tmp/openclaw/openclaw-<date>.log`, `~/Library/Logs/openclaw/gateway.log` |
| Tailnet access     | `tailscale serve`: `:443` to fleet `7300`, `:8443` to T3 `3773`               | none                                           | none                                                                       |
| Claude Code CLI    | `~/.local/bin/claude`, linked from `/opt/homebrew/bin/claude` for the Gateway | `~/.claude` + login keychain                   | none                                                                       |
| Codex (4 accounts) | started by T3 per instance (`Codex - 0..3`)                                   | `~/.codex`, `~/.t3/userdata/providers/codex/*` | none                                                                       |

Before running any T3 command by hand, source `~/Developer/t3-env.sh` (Node 26). The fleet services keep
Node 22.

## Status and health

```bash
launchctl print gui/501/local.t3code-fork | grep -E "state|pid"
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3773/
openclaw gateway status
openclaw approvals pending
tailscale serve status
~/t3-fork/deploy.sh --list
```

Run checks that need the Claude login, such as `claude auth status`, through `~/t3-fork/gui-run.sh '<cmd>'`.
SSH sessions cannot read the login keychain.

## Start, stop, restart

```bash
launchctl kickstart -k gui/501/local.t3code-fork      # restart T3
launchctl bootout gui/501/local.t3code-fork           # stop T3 (until next login or bootstrap)
launchctl bootstrap gui/501 ~/Library/LaunchAgents/local.t3code-fork.plist   # start T3
openclaw gateway restart | stop --force | start       # Gateway
```

Restarting T3 ends running turns. Threads reattach afterwards through `session/load`. A Gateway restart
needs about 5 s before it serves; a message sent in that window fails with "Internal error". Retry it.

## Deploy a new fork commit

```bash
cd ~/Developer/t3code && git pull          # or rebase on upstream; see "Update" below
~/t3-fork/deploy.sh                          # builds HEAD as a release, switches, restarts T3
```

## Roll back

1. **Previous T3 build:** `~/t3-fork/deploy.sh <older-commit>`. A built release is reused. Thread data in
   `~/.t3` stays. Do not roll back across a T3 database migration without checking the upstream release
   notes first.
2. **Back to stock T3, keeping data:**
   - Stop the fork: `launchctl bootout gui/501/local.t3code-fork`.
   - Install a stock release: `t3 service install` from an official `t3` CLI.
   - The OpenClaw instance then fails to start sessions again, because stock T3 has no Per-session MCP
     setting. Disable it in Settings → Providers.
3. **Disable only OpenClaw in T3:** Settings → Providers → OpenClaw → switch off. Claude and Codex are
   unaffected.
4. **Undo the OpenClaw hardening:**
   - `openclaw gateway stop --force`
   - `cp ~/.openclaw/openclaw.json.pre-hardening-20261112 ~/.openclaw/openclaw.json`
   - `openclaw exec-policy preset yolo` (the onboarding default; not recommended)
   - `openclaw gateway start`
5. **Remove tailnet access to T3:** `tailscale serve --https=8443 off`. The fleet route on 443 stays.
6. **Revoke a T3 client:** `node ~/t3-fork/current/apps/server/dist/bin.mjs auth session list --base-dir ~/.t3`,
   then `... auth session revoke <id>`.

## Update procedure

- Never run `t3 update` or `t3 service install` for this host. They install the stock release binary.
- To take upstream changes:
  - `git fetch upstream`
  - Rebase `openclaw-acp-session-mcp` on `upstream/main`.
  - Run the ACP and settings tests. See `compatibility.md` for the commands.
  - `deploy.sh`.
  - Run one live OpenClaw thread.
- OpenClaw updates (`openclaw update`): re-run the live thread afterwards, and check that `openclaw acp` still
  rejects non-empty `mcpServers` or now accepts them.
- Client: use the web app served by the mini (`https://mac-mini-m6.tail5d38a1.ts.net:8443`). The stock
  desktop app may not match the fork's version.

## OpenClaw dashboard (approvals from the MacBook)

`https://mac-mini-m6.tail5d38a1.ts.net:8444` is tailnet only. It is an externally managed Serve route,
because OpenClaw's managed Serve always takes 443, which the fleet dashboard owns. The config is
`gateway.trustedProxies: ["127.0.0.1"]` plus `gateway.controlUi.allowedOrigins`
(backup `~/.openclaw/openclaw.json.pre-tailnet-20261112`). Token auth and per-browser device pairing stay
on. `127.0.0.1` as a trusted proxy means same-host processes may supply proxy attribution. That is accepted
here because everything runs as `admin`.

Pair another browser:

- Run `openclaw dashboard --json` on the mini.
- Take `browserUrl`, and replace its base with `https://mac-mini-m6.tail5d38a1.ts.net:8444`.
- Replace the `gatewayUrl` fragment value with `wss://mac-mini-m6.tail5d38a1.ts.net:8444`.
- Open it within 10 minutes.

Remove a browser: `openclaw devices list`, then `openclaw devices remove <id>`.

Disable the dashboard route:

- `tailscale serve --https=8444 off`
- `openclaw config unset gateway.trustedProxies`
- `openclaw config unset gateway.controlUi.allowedOrigins`

## Exec approvals (known limitation)

OpenClaw does not relay exec approvals to T3 over ACP. The approval waits in the Gateway for up to
30 minutes, then is denied. Answer it in the dashboard above, or on the mini:

```bash
openclaw approvals pending
openclaw approvals resolve <id> allow-once   # or allow-always, deny
```

Or allowlist safe binaries: `openclaw approvals allowlist add --agent main /usr/bin/git`.
