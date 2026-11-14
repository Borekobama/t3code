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

`gateway.publicOrigin` is set to the same URL (backup `~/.openclaw/backups/openclaw.json.pre-publicOrigin-*`).
OpenClaw uses it to build links it sends in chat, for example the secure credential card
(`<origin>/ask/<id>`). Without it, Dronk answers "Credential request unavailable here: no reachable Control UI
link". The link opens only on a tailnet device whose browser is paired (see below).

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
- `openclaw config unset gateway.publicOrigin`

## Dronk to T3 (OpenClaw as an outside MCP agent)

- OpenClaw MCP server `t3code` points at `https://mac-mini-m6.tail5d38a1.ts.net:8443/mcp` (streamable-http,
  OAuth). The OAuth redirect is pinned to `http://127.0.0.1:53682/callback`. Access level is Supervised,
  approved in T3. The token lives in OpenClaw's state database and is included in the R2 backup.
- Dronk's rules are in the workspace `AGENTS.md`, section "T3 Code":
  - start only Claude or Codex threads, never OpenClaw (that would loop back to Dronk)
  - report with tailnet links
  - it cannot approve T3 permission requests
- Supervised means `runtimeModeCeiling: approval-required`. T3 lets only full-access clients create projects
  (`t3_project_create` is `writesEnvironment`), so Dronk gets `capability_denied`. Add the project yourself:
  `node ~/t3-fork/current/apps/server/dist/bin.mjs project add --base-dir ~/.t3 --title <name> <path>`
  (load `~/Developer/t3-env.sh </dev/null` first). Full access would also let Dronk start threads that run
  without approvals.
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

- LaunchAgent `local.t3-watch` runs `~/t3-fork/t3-watch.py` every 15 s (log `~/Library/Logs/t3-watch.log`,
  state `~/.t3-watch-state.json`). Each run checks pending runtime requests in T3's database. Every 2 minutes it
  also scans `t3 thread list` for status changes. No model is used.
- It posts to the **T3** topic (thread 5) of the owner-only forum group "OpenClaw - Mac Mini M6"
  (`-1003914415301`, `TELEGRAM_TO` in the script; before 2026-11-14 it was the owner DM). It posts once per
  change, with an **Open in T3** button:
  - a thread needs approval or an answer (a waiting thread still reports `running`)
  - a thread finished, failed or was interrupted
- Approval cards show the command (or the file to edit) and carry **Approve** / **Decline** / **⚡ Full access for
  this task** buttons. A Supervised thread with an active run also gets one "started" card with the Full access
  button. The watcher maps a short id to the request or thread in `~/.t3-watch-requests.json` (0600). Questions
  only get the link.
- Pause it with `launchctl bootout gui/501/local.t3-watch`.

### Telegram topic group

- Group "OpenClaw - Mac Mini M6", id `-1003914415301`, forum topics on. Dronk's bot is admin with Manage Topics.
- OpenClaw config: `channels.telegram.groups["-1003914415301"].requireMention: false`. `groupAllowFrom` is unset,
  so only `allowFrom` (owner 640306272) may talk to Dronk there. Each topic is its own session
  (`...:topic:<id>`); topics share only the workspace memory files.
- Topics: General (1) for chat, **T3** (5) for the watcher, **Ops** (6) for the project-watch automation
  (`openclaw automations edit <id> --to -1003914415301 --thread-id 6`).
- OpenClaw's own exec approval prompts still go to the owner DM (`execApprovals.target: dm`).
- **Project topics** (`~/t3-fork/t3-topics.py`, fork `ops/t3-topics.py`): one topic per T3 project, with an
  icon from Telegram's allowed set (`t3-topics.py icons`). `open --project <id|title> [--name] [--emoji]` creates
  the topic (or reopens a closed one) and posts an intro; `close --topic N | --project <id>` posts "Topic closed"
  and closes it; `list` shows the map `~/.t3-watch-topics.json` (0600, lock file next to it). The bot token is
  read inside the script and never printed.
- t3-watch.py sends a project's cards to its open topic, everything else to T3. A finished thread in a project
  topic gets a **Close topic** button (`tp:c:<topic>`), handled by the dronk-telegram plugin.
- Dronk's rules (workspace AGENTS.md, "Telegram group and project topics"): open the project topic before
  starting a T3 thread, never create topics with the message tool, close only when the user asks.
- Live typing: `channels.telegram.streaming.mode: partial` streams the answer text by editing a preview message.
  OpenClaw no longer uses Telegram's native `sendMessageDraft`, and no plugin hook exposes partial text.
- Known flake: about 2 in 77 sends on 2026-11-14 failed with `ECONNRESET` (`syscall: read`) on the Gateway's
  Telegram connection. Final text replies get one automatic retry; interactive payloads do not. t3-watch.py does
  not save state when a send fails, so it re-sends that batch 15 s later (possible duplicate).
- DM topics (BotFather threaded mode) did not work on 2026-11-14: `getMe` kept `has_topics_enabled: false`,
  `createForumTopic` in the DM failed with "the chat is not a forum", and a user-started thread hung.

### Approval buttons (OpenClaw plugin `dronk-telegram`)

- Code: `ops/openclaw-plugin/` (linked install: `openclaw plugins install --link <dir> --force`, then
  `openclaw plugins enable dronk-telegram`; after code changes `openclaw plugins reload dronk-telegram`).
  It runs inside the Gateway and claims Telegram callbacks, so taps never reach the agent:
  - `t3:a|d:<id>`: only sender 640306272. Runs `~/t3-fork/t3.sh thread respond --decision accept|decline`
    and edits the card to "✅ Approved" / "❌ Declined", or to the error (for example already answered in T3).
    `t3:s:<id>` (acceptForSession) is supported but has no button yet.
  - `t3:f:<id>`: full access for the current task. Claude sessions cannot change mode in place: T3 restarts the
    session and the active run fails (tested 2026-11-14). So the plugin runs `t3 thread mode <thread>
    full-access`, then `t3 thread send` with a "continue where you stopped" message, and records the new run in
    `~/.t3-watch-grants.json`. When that run ends, the watcher runs `t3 thread mode <thread> approval-required`
    (log line "back to Supervised"). Only works while the thread has an active run.
  - `more:<id>`: the Details button below.
- `t3 thread mode <thread> <mode>` (fork commit 24e6b48ce0) uses the same owner path.
- `t3 thread respond` (fork commit 4b41d2f111) answers as the machine owner: it issues a 5-minute
  `orchestration:read/operate` session, takes a WebSocket ticket and dispatches `runtime-request.respond` over
  the web app's RPC, then revokes the session. T3's MCP tools refuse permission requests on purpose, so Dronk
  still cannot approve anything; only the owner's tap or CLI can.
- Tested 2026-11-14: a Supervised test thread approved via the CLI (command ran, session revoked), and the user
  approved the LeadScout card from Telegram.

### Details button for Dronk's replies

- The same plugin's `reply_payload_sending` hook splits a Telegram reply at a line `[[details]]`: the short
  part goes out with a **Details** button, the rest is stored in `~/.openclaw/state/telegram-details.json`
  (last 300). A tap edits the message to the full text, or replies with the details when they are over 4000
  characters.
- Dronk's `SOUL.md` Voice section says when to use it (1-3 short lines first, longer stuff behind the marker).

## Codex account auto-switch

- Setting "Switch Codex accounts on usage limits" (`autoSwitchCodexAccounts`), on since 2026-11-12. Merged in
  `e72626801a` (branch `codex-auto-switch`).
- When a Codex run stops on a usage limit, T3 moves the thread to another Codex account in the same Codex
  home, continues the turn, and posts a notice.
- The 99 % pre-switch needs 5-hour and weekly window readings. Managed ChatGPT accounts report none today,
  so in practice only the switch after a limit fires.
- Disable it in Settings → Threads.

## Skills on the mini

- `~/skills/global-skill-arsenal` is a full working copy of the private arsenal repo. The MacBook and the mini
  both install, review, deploy and push skills there. Agents on both machines run `git pull --ff-only` in the
  arsenal before a change (rule in `INSTALLATION_RULES.md`).
- Skills Manager runs on the mini too: `~/.skills-manager/bin/skills-manager-cli` 1.38.0 (copied from the
  MacBook), pointed at the clone by `~/Library/Application Support/skills-manager/repo-config.json`. It rebuilds
  its skill IDs from the git-tracked `skills/.skills-manager/skills/<id>.json` files, so both machines share
  one set of IDs (checked: all 100 identical; a skill created on the mini showed up on the MacBook with the
  same ID and approval, and its removal propagated too).
- `content_hash` ignores `.DS_Store` (arsenal 9e0d712). Before that, Finder files made the machines disagree on
  hashes and flip skills to needs-review.
- `~/t3-fork/skills-sync.sh` (LaunchAgent `local.skills-sync`, daily 05:00) pulls the arsenal, runs
  `./arsenal refresh`, and deploys the baseline in `~/t3-fork/skills-manifest.txt` through Skills Manager
  (idempotent). The baseline mirrors the MacBook's deployments of 2026-11-12, including legacy skills that were
  never reviewed. Skills deployed on the mini with `./arsenal deploy` stay; the script never undeploys. It
  warns about uncommitted arsenal changes and broken skill links.
- `portless-dev` is MacBook-only (MacBook paths). Skills Manager also detects OpenClaw on the mini; nothing is
  deployed to it, because Dronk already loads `~/.claude/skills`.
- The same script writes the global instruction files `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
  Each file is a static header (`~/t3-fork/global-claude.md` or `global-codex.md`, copied from the MacBook)
  plus the arsenal block: `INSTALLATION_RULES.md` with the mini's arsenal path, the mini's pull-first and
  deploy notes, and every skill listed as `native <skill>` in the manifest (caveman, ponytail).
  A changed file is backed up as `*.bak-<timestamp>` before it is rewritten.
- All 4 Codex accounts read it: T3 links new `~/.codex` entries into each account's shadow home when it
  prepares that account (a T3 restart is enough).
- OpenClaw runs `claude --setting-sources user`, so Dronk also loads `~/.claude/CLAUDE.md` and the Claude
  skills. The "MINI SCOPE" block in the header keeps Dronk's SOUL.md voice for chat.
- After a T3 restart, each OpenClaw session's first t3code call fails once ("Streamable HTTP error", then
  "not connected") until OpenClaw recycles the expired MCP session. `openclaw mcp reload` does not prevent it.
  The workspace AGENTS.md tells Dronk to retry up to 3 times.

## Projects on the mini

- `~/Projects/<path>` mirrors the MacBook's `~/Downloads/Projects/<path>`: all 145 git repos (2026-11-12),
  each added as a T3 project titled by its folder name. Dronk finds them with `t3_project_list`.
- `ops/transfer-repos.sh` (run on the MacBook) streams a `git bundle --all` of each repo over SSH and clones it
  on the mini, so local branches and unpushed commits come along and nothing is pushed to GitHub. It then
  points `origin` at GitHub, fetches, sets upstreams, and pulls LFS files. Existing clones are skipped, so it
  can be rerun with a list of new repos: `zsh transfer-repos.sh list.txt` (one relative path per line), then
  `t3 project add --base-dir ~/.t3 --title <name> ~/Projects/<path>` on the mini.
- Shallow repos can't be bundled (OF-Scraper, ai-website-cloner-template): those were cloned from GitHub.
- Untracked `.env*` files (63) were copied with mode 600. Uncommitted MacBook changes were not copied.
- `Website/Como/configurator` and `Website/vional.com/vional-admin` now push to the private repos
  `Borekobama/website-como-configurator` and `Borekobama/website-vional-admin` (2026-11-12).
  `skills/supervisor-shunt` still has no remote, and `skills/chat-on-steroids` is someone else's repo
  (read-only); both are covered by the R2 backup below.
- 13 folders that had no git at all were put into git on 2026-11-12 (initial commit on the MacBook, a
  `.gitignore` block for `.env`, `node_modules`, `.DS_Store`, `.playwright-mcp`), pushed to new private repos,
  cloned to the mini and added to T3 (159 projects): `tools-ziviScraper`, `tools-icloudKeepAlive`,
  `tools-plateRecognition`, `tools-cloakBrowser-new`, `tools-cloakBrowser-old`, `tools-infloww`,
  `website-como-shop-v2`, `website-magicnetwork.co.uk`, `website-fonioAi`, `website-fishAudio-fonioAi`,
  `website-template-eliseai`, `website-template-danielrltan.com`, `website-template-phonely`.
  Kept out of git and only on the MacBook: ZiviScraper `state/` and `bin/`, PlateRecognition
  `demo-test-videos/` (files over GitHub's 100 MB limit), Infloww `Contents/` (the app bundle), `*.zip`,
  disassembly dumps and `analysis/source-recovery/tools/` (public tool checkouts). gitleaks found only keys
  embedded in cloned third-party sites and apps, no own secrets. `tools-infloww` holds another company's
  decompiled code: keep it private.
  GitHub limits repo creation bursts ("created too many repositories, too quickly"): retry after a few minutes.
- Nightly `projects-backup.sh`, called at the end of `backup-t3.sh` (03:30):
  - Unpushed commits in repos with a `Borekobama/*` origin are force-pushed to hidden refs
    `refs/backup/mac-mini-m6/<branch>`. Real branches are never pushed, so no CI or platform deploy runs.
    Restore: `git fetch origin 'refs/backup/mac-mini-m6/*:refs/remotes/backup/*'`.
  - Every `.env*` file (examples excluded) and the `.git` folder of each repo without a pushable origin go to
    the restic repo on R2 with tag `projects` (7 daily / 4 weekly / 12 monthly).
  - Telegram: one message per branch that has had unpushed commits for over a day (state in
    `~/.projects-backup-state`, keyed repo|branch|tip), and any fetch/push/restic failure.
  - The first run was `--seed`, so the 42 branches already unpushed on 2026-11-12 were not reported.
- Dependencies (`node_modules`, venvs) are not installed; install them per project when needed.
- From now on there are two working copies of each repo. Commit and push on one machine, pull on the other.

## Dronk memory search (local embeddings)

- `memory.search.provider` is `local` (2026-11-12): plugin `@openclaw/llama-cpp-provider`, embedding-only
  setup. The model is EmbeddingGemma 300M Q8 (`~/.openclaw/models/llama.cpp`, 324 MB), served by a managed
  Metal `llama-server` on 127.0.0.1:54409. OpenClaw starts it on demand and stops it after 10 idle minutes.
  The chat model is unchanged. No API key; nothing leaves the mini.
- Setup and `openclaw memory ...` commands need the Gateway stopped: `openclaw gateway stop --force`, run the
  command, then `openclaw gateway start`. Setup was `openclaw config set memory.search.provider local` plus
  `openclaw models auth login --provider llama-cpp --method local` (answer No to the chat model, Yes to
  embeddings only).
- Rebuild after a provider or model change: `openclaw memory status --index --agent main` (about 40 s for
  64 files / 1,438 chunks).
- The daily R2 backup skips `~/.openclaw/tools` but includes the 324 MB model in `~/.openclaw/models`.
- Indexed sources are `MEMORY.md`, `USER.md`, `memory/` and sessions; `IDENTITY.md` and `SOUL.md` are not.

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

## Exec approvals

Dronk's exec runs through OpenClaw's reviewer first (`tools.exec.mode: auto`, Haiku). Low-risk commands run
without a prompt. Anything it defers goes to a human:

- Telegram: `channels.telegram.execApprovals` (`target: dm`, approver 640306272) sends the prompt with buttons
  to your DM. This works for sessions that did not start in Telegram too (tested 2026-11-14 from an
  `openclaw agent` CLI session). After a decision or timeout, the message changes to "Exec approval resolved".
- OpenClaw does not relay exec approvals to T3 over ACP, so a T3-started OpenClaw thread shows nothing in T3.
  Answer it in Telegram, the dashboard above, or on the mini:

```bash
openclaw approvals pending
openclaw approvals resolve <id> allow-once   # or allow-always, deny
```

- The approval itself expires after 30 minutes, but a claude-cli run gives up sooner: in the test the run
  aborted after about 12 minutes (`run-aborted`), and the approval was cancelled as denied.
- A command whose executable path starts with `~/` is denied before any prompt (`SYSTEM_RUN_DENIED: approval
  cannot safely bind this interpreter/runtime command`). OpenClaw cannot resolve the file it must bind the
  approval to. Use absolute paths.
- T3 projects: Dronk runs `/Users/admin/t3-fork/t3.sh project add|rename|remove` through exec, as the
  workspace `AGENTS.md` says. In the test, add was auto-allowed (medium risk) and remove went to a human
  (high risk).

Or allowlist safe binaries: `openclaw approvals allowlist add --agent main /usr/bin/git`. On darwin the
allowlist does not auto-run commands; the reviewer still decides.
