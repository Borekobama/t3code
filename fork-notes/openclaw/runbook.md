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

## Dronk to T3 (OpenClaw as an outside MCP agent)

- OpenClaw MCP server `t3code` points at `https://mac-mini-m6.tail5d38a1.ts.net:8443/mcp` (streamable-http,
  OAuth). The OAuth redirect is pinned to `http://127.0.0.1:53682/callback`. Access level is Supervised,
  approved in T3. The token lives in OpenClaw's state database and is included in the R2 backup.
- Dronk's rules are in the workspace `AGENTS.md`, section "T3 Code":
  - start only Claude or Codex threads, never OpenClaw (that would loop back to Dronk)
  - report with tailnet links
  - it cannot approve T3 permission requests
- Re-authorize after a revoke or expiry. Stop the Gateway first, because OpenClaw's MCP commands refuse to write
  while it runs:

```bash
openclaw gateway stop --force
ssh -t -L 53682:127.0.0.1:53682 mac-mini-m6 'export PATH=$HOME/.openclaw/bin:$PATH; openclaw mcp login t3code'   # from the MacBook
openclaw gateway start
openclaw mcp status --verbose
```

- Remove it: `openclaw mcp unset t3code`. Also revoke the session in T3 (`auth session list` / `revoke`).
- Tested 2026-11-12: Dronk listed projects, then started a Claude thread that read a project file, and reported
  back (12 s).

## Telegram alerts for T3 threads

- LaunchAgent `local.t3-watch` runs `~/t3-fork/t3-watch.py` every 2 minutes (log `~/Library/Logs/t3-watch.log`,
  state `~/.t3-watch-state.json`). No model is used.
- It messages the user's Telegram once per change:
  - a thread needs approval or an answer, read from pending runtime requests (a waiting thread still reports
    `running`)
  - a thread finished, failed or was interrupted
- Each alert carries the tailnet thread link. Pause it with `launchctl bootout gui/501/local.t3-watch`.

## Codex account auto-switch

- Setting "Switch Codex accounts on usage limits" (`autoSwitchCodexAccounts`), on since 2026-11-12. Merged in
  `e72626801a` (branch `codex-auto-switch`).
- When a Codex run stops on a usage limit, T3 moves the thread to another Codex account in the same Codex
  home, continues the turn, and posts a notice.
- The 99 % pre-switch needs 5-hour and weekly window readings. Managed ChatGPT accounts report none today,
  so in practice only the switch after a limit fires.
- Disable it in Settings → Threads.

## Skills on the mini

- `~/skills/global-skill-arsenal` is a clone of the private arsenal repo.
- `~/t3-fork/skills-sync.sh` pulls it and links every skill listed in `~/t3-fork/skills-manifest.txt` into
  `~/.claude/skills` and `~/.codex/skills`. It only manages symlinks into the arsenal, so T3's own `synced`
  folder is left alone. LaunchAgent `local.skills-sync` runs it daily at 05:00.
- The manifest mirrors the MacBook's deployments (91 Claude, 92 Codex). `portless-dev` is excluded because it
  has MacBook paths.
- To add or remove a skill on the mini, edit the manifest, then run the script.
- New skills reach the mini after they are pushed to the arsenal repo and added to the manifest.
- The same script writes the global instruction files `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
  Each file is a static header (`~/t3-fork/global-claude.md` or `global-codex.md`, copied from the MacBook)
  plus the arsenal block: `INSTALLATION_RULES.md` with the mini's arsenal path, a note that the mini is a
  read-only mirror, and every skill listed as `native <skill>` in the manifest (caveman, ponytail).
  A changed file is backed up as `*.bak-<timestamp>` before it is rewritten.
- All 4 Codex accounts read it: T3 links new `~/.codex` entries into each account's shadow home when it
  prepares that account (a T3 restart is enough).
- OpenClaw runs `claude --setting-sources user`, so Dronk also loads `~/.claude/CLAUDE.md` and the Claude
  skills. The "MINI SCOPE" block in the header keeps Dronk's SOUL.md voice for chat.
- The arsenal itself (install, review, deploy) stays on the MacBook. Review approvals are in git
  (`catalog/*.json`), but the arsenal wraps Skills Manager, which assigns the skill IDs the catalog is keyed on.
  A second Skills Manager on the mini would write different IDs into the same catalog.
- After a T3 restart, each OpenClaw session's first t3code call fails once ("Streamable HTTP error", then
  "not connected") until OpenClaw recycles the expired MCP session. `openclaw mcp reload` does not prevent it.
  The workspace AGENTS.md tells Dronk to retry up to 3 times.

## Backups (OpenClaw to Cloudflare R2)

- Location `offsite` is `r2://openclaw-backups/mac-mini-m6`: a private bucket in WEUR, with archives encrypted
  before upload.
- Daily job `openclaw-backup-offsite` (a command job, no model use) keeps 7 daily, 4 weekly and 12 monthly
  archives.
- Included: all of `~/.openclaw` (config, both SQLite databases, the Telegram token file, `.env`) and the
  workspace `~/Developer/openclaw-workspace`.
- Not included here: T3 and Codex (see below), the Claude keychain login, and OpenClaw's reinstallable tools.
- Secrets: `~/.openclaw/.env` holds `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` and
  `OPENCLAW_STORAGE_PASSPHRASE`. The passphrase is also in the user's password manager. Without it the
  archives cannot be decrypted. The R2 token is bucket-scoped Object Read & Write; replace it with
  `~/t3-fork/set-r2-secrets.sh` (keeps the passphrase).

```bash
openclaw backup list --from offsite
openclaw backup create --to offsite --verify --keep-daily 7 --keep-weekly 4 --keep-monthly 12   # on demand
openclaw backup restore --from offsite latest --target <fresh-dir>                               # staging only
```

Restore onto a new Mac:

1. Install OpenClaw (`install-cli.sh`).
2. Put the three variables into `~/.openclaw/.env` (mode 600).
3. Add the same `storage.locations.offsite` config.
4. Restore into a fresh directory.
5. Stop the Gateway and move the restored state into place.
6. Run `openclaw doctor`, then `claude auth login` in the GUI session.

Approvals and delivery state roll back to the archive's time.
Tested 2026-11-12: restore from R2 passed SQLite `integrity_check` for all databases; config, token file and
persona files were present.

## Backups (T3 and Codex to Cloudflare R2, restic)

- Repository `r2://openclaw-backups/mac-mini-m6/t3`, encrypted by restic. Its password is the same
  `OPENCLAW_STORAGE_PASSPHRASE`.
- LaunchAgent `local.t3-backup` runs `~/t3-fork/backup-t3.sh` daily at 03:30 (log
  `~/Library/Logs/t3-backup.log`). It takes consistent SQLite copies of `statev2.sqlite` (T3) and
  `state_5.sqlite` (Codex) while both keep running. It then backs up `~/.t3/userdata` (without logs),
  `~/.t3/service.env` and `~/.codex`, keeps 7 daily, 4 weekly and 12 monthly snapshots, and runs `restic check`.
- Not included: `~/.t3/tools` (reinstallable) and T3 worktrees (their commits live in the git repositories).

```bash
~/t3-fork/backup-t3.sh snapshots
launchctl kickstart gui/501/local.t3-backup                            # back up now
~/t3-fork/backup-t3.sh restore latest --target <fresh-dir>             # staging restore
```

Restore T3 data:

1. Stop T3: `launchctl bootout gui/501/local.t3code-fork`.
2. Copy `userdata` back into `~/.t3/`.
3. Put `.t3-backup-staging/t3-statev2.sqlite` back as `~/.t3/userdata/statev2.sqlite`, and remove any old
   `-wal`/`-shm` files.
4. Start T3 again.

Restore the Codex sign-in only if the old machine no longer uses it: Codex refresh tokens are single-use.
Tested 2026-11-12: restored `statev2.sqlite` passed `integrity_check` with the same thread count as live.

## Exec approvals (known limitation)

OpenClaw does not relay exec approvals to T3 over ACP. The approval waits in the Gateway for up to
30 minutes, then is denied. Answer it in the dashboard above, or on the mini:

```bash
openclaw approvals pending
openclaw approvals resolve <id> allow-once   # or allow-always, deny
```

Or allowlist safe binaries: `openclaw approvals allowlist add --agent main /usr/bin/git`.
