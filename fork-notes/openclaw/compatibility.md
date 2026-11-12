# OpenClaw as a T3 ACP provider: compatibility manifest

Fork-only notes for `Borekobama/t3code`. Not part of any upstream PR.

Status: **Phase 1 complete (2026-11-12).** The per-instance MCP opt-out is in commit `40fbb0ca1`,
test-covered and checked live against `openclaw acp`. Phase 2 (conversations, cancel, approvals) needs a
signed-in model runtime on the Gateway.

## Pinned versions

| Component                 | Version / revision                                                             |
| ------------------------- | ------------------------------------------------------------------------------ |
| T3 Code upstream          | `pingdotgg/t3code` `4947db07d319df031028338e71128b5e8ff45b1f` (2026-11-12)     |
| T3 app/server/web/desktop | `0.1.9`                                                                        |
| T3 orchestration protocol | `ORCHESTRATION_PROTOCOL_VERSION = 2` (`packages/contracts/src/environment.ts`) |
| T3 toolchain              | Node `26.12.1` (from `engines`), pnpm `12.14.0`, Vite+ `vp` `1.6.0`            |
| OpenClaw                  | `2026.11.3` (`847611d`), rootless `install-cli.sh` install under `~/.openclaw` |
| OpenClaw private Node     | `24.22.1` (`~/.openclaw/tools/node`)                                           |
| OpenClaw ACP              | Reports `protocolVersion: 1` (ACP v1). No ACP v2 preview.                      |
| Host                      | Mac mini, Apple M6, 16 GB, arm64, macOS 27.0 (26A425), Xcode 27.2              |
| Host user                 | `admin` (decided 2026-11-12; no separate service account)                      |
| Claude Code CLI           | not installed yet                                                              |
| Codex CLI                 | not installed yet (T3-managed ChatGPT accounts planned)                        |

### Node on the host

The iPhone fleet services use Homebrew `node@22`, by absolute path in their LaunchAgents. Vite+ runs in
system-first mode, so `node` on `PATH` stays 22. Source `~/Developer/t3-env.sh` before any T3 work. It puts
Node 26.12.1 first on `PATH` for that shell only.

## Baseline (unpatched, Node 26.12.1)

| Check                                                                                        | Result               |
| -------------------------------------------------------------------------------------------- | -------------------- |
| `packages/effect-acp` tests                                                                  | 6 files, 84 passed   |
| `packages/provider-acp` tests                                                                | 8 files, 105 passed  |
| `apps/server` ACP adapter tests (`AcpAdapterV2`, `AcpRegistryAdapterV2`, `src/provider/acp`) | 11 files, 307 passed |
| Typecheck: `effect-acp`, `provider-acp`, `apps/server`                                       | exit 0, 0 errors     |

## The blocker

T3 adds a per-thread MCP server named `t3-code` to every ACP session. OpenClaw's ACP bridge rejects any
non-empty `mcpServers` list.

### T3 call sites (at the pinned SHA)

- `packages/provider-acp/src/server/adapter.ts`
  - `acpMcpContext()` builds the stdio `t3-code` server (`acp-mcp-bridge`), plus ACP and HTTP variants of it.
    It also builds `processEnvironment` with `T3_ACP_MCP_ENDPOINT` and `T3_ACP_MCP_AUTHORIZATION`, which
    carries the bearer token.
  - `readMcpContext()` is the single entry point for that context. Its result goes to `makeRuntimeInput()` and
    `acpMcpActivation()`.
  - `resolvePromptParts()` sets `hasT3Mcp` when the thread has an MCP session. This adds T3 MCP instructions
    to the prompt.
- `packages/provider-acp/src/server/AcpSessionRuntime.ts`
  - `sessionMcpServers()` picks the ACP, HTTP or stdio list. It feeds every setup request: `session/new`,
    `session/load` and `session/resume` at startup, and `loadSession`, `resumeSession` and `forkSession` on
    later activation.
  - OpenClaw reports `mcpCapabilities: { http: false, sse: false }` with no `acp`. So T3 sends the stdio
    `t3-code` entry.
- `packages/provider-acp-registry/src/settings.ts`
  - `AcpRegistrySettings` is the per-instance config of Registry and **Local ACP command** instances
    (`source: "local"`).
- `packages/provider-acp-registry/src/server/adapter.ts`
  - Builds `AcpAdapterV2Flavor` from those settings (`flavor` near line 212).

### OpenClaw side

- `src/acp/translator.ts`, `assertSupportedSessionSetup()`, throws on any non-empty list. It is called from
  `newSession`, `loadSession` and `resumeSession`.
- `docs/cli/acp.md` names T3: T3 must offer a supported way to send `mcpServers: []`.
- Upstream T3 has no opt-out and no open PR for one (checked 2026-11-12).

### Reproduction

The probe is `~/Developer/openclaw-t3-probe/acp-probe.mjs` on the mini, outside the repo. It is a minimal newline-delimited JSON-RPC client that spawns
`openclaw acp`. It ran against a throwaway Gateway: `openclaw gateway run --dev --bind loopback --auth none`
with a scratch `OPENCLAW_HOME`, removed afterwards.

```text
### T3-shaped mcpServers (stdio "t3-code", dummy env values)
initialize: {"protocolVersion":1,"agentCapabilities":{"loadSession":true,...,"mcpCapabilities":{"http":false,"sse":false},
  "sessionCapabilities":{"list":{},"resume":{},"close":{}}},"agentInfo":{"name":"openclaw-acp",...,"version":"2026.11.3"},"authMethods":[]}
session/new (t3):    {"code":-32603,"message":"Internal error","data":{"details":"ACP bridge mode does not support per-session MCP servers. Configure MCP on the OpenClaw gateway or agent instead."}}
session/load (t3):   (same error)
session/resume (t3): (same error)

### empty mcpServers
session/new (empty): {"sessionId":"e8529d23-…","configOptions":[{"id":"thought_level",…},{"id":"fast_mode",…}]}
notify: session_info_update title "acp-bridge:e8529d23-…"   (isolated per-session key, as documented)
```

Other findings:

- `openclaw acp` connects to the Gateway (`127.0.0.1:18789`) before it answers `initialize`. With no Gateway,
  the client sees no reply at all, and stderr shows `ACP bridge failed: connect ECONNREFUSED 127.0.0.1:18789`.
  T3 must show this as a readable startup failure, not as a hang.
- The error comes back as JSON-RPC `-32603` with the reason in `data.details`.

Still to do: reproduce through T3's own UI with a Local ACP command instance. This needs the T3 server running
(Phase 3).

## Patch design (Phase 1)

One per-instance setting, applied where the adapter is built. It changes nothing for other providers.

1. **Setting.** Add `sessionMcp: "default" | "none"` to `AcpRegistrySettings`.
   - It decodes to `"default"`, so existing instances keep today's behavior.
   - It is shown as a select in the instance form ("Per-session MCP": "T3 tools (default)" / "None").
2. **Flavor.** Add `sessionMcp?: "default" | "none"` to `AcpAdapterV2Flavor`, and set it from the settings in
   the registry adapter.
3. **One choke point.** In `readMcpContext()`, when `sessionMcp === "none"`:
   - Return empty `servers`, `acpServers` and `httpServers`. All six setup requests then send `mcpServers: []`.
     This also suppresses any future injected entry, for example a Cua driver.
   - Drop `T3_ACP_MCP_ENDPOINT`, `T3_ACP_MCP_AUTHORIZATION`, `T3_ACP_MCP_NODE` and `T3_ACP_MCP_ENTRYPOINT` from
     `processEnvironment`, so the T3 MCP bearer token never reaches the agent process.
   - Keep `T3CODE_THREAD_ID`, which is not a secret.
4. **Prompt and capabilities.** Make `hasT3Mcp` and `hasDeviceTools` false in `resolvePromptParts()` under
   `none`, so OpenClaw is never told about T3 tools it does not have. Review `OrchestrationV2ProviderCapabilities`
   for features that depend on T3 MCP, and hide them for the instance.
5. **Tests.** Extend existing cases and fixtures rather than adding new layers:
   - `none` sends `mcpServers: []` on new, load, resume and fork.
   - `default` still sends `t3-code` (regression).
   - The process environment under `none` carries no `T3_ACP_MCP_*`.
   - Settings decode with the default.
   - A replay fixture recorded from real `openclaw acp` output.

Not planned: an OpenClaw-specific driver, a check of the agent's name, or any client-only conditional.

## Phase 1 result

Commit `40fbb0ca1` `feat(acp): let an ACP instance opt out of per-session MCP`.

| File                                                   | Change                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `packages/provider-acp-registry/src/settings.ts`       | New `sessionMcp` setting, default `"default"`, select "Per-session MCP"                                                                                                                                                                                                  |
| `packages/provider-acp-registry/src/server/adapter.ts` | Passes the setting into the ACP flavor                                                                                                                                                                                                                                   |
| `packages/provider-acp/src/server/adapter.ts`          | `acpMcpContext()` returns no servers and only `T3CODE_THREAD_ID` under `"none"`. This also skips the MCP-over-ACP bridge, which needs the endpoint. `resolvePromptParts()` omits the T3 tool instructions. `negotiatedCapabilities()` reports `supportsMcpTools: false`. |
| `apps/server/.../AcpRegistryAdapterV2.test.ts`         | `"none"` row in the `mcpServers` table (new and load). The process-env test now runs for `"default"` and `"none"`: env, capability and first prompt.                                                                                                                     |
| `docs/user/providers-acp.md`                           | One paragraph on the setting                                                                                                                                                                                                                                             |

Design change from the plan: the setting is applied in `acpMcpContext()`, which `readMcpContext()` calls, rather
than in `readMcpContext()` itself. Same single choke point.

### Verification

- The two new cases fail on the unpatched source and pass with the patch.
- Tests: `provider-acp` 105, `provider-acp-registry` 64, server ACP suites 308 (was 307), all passing.
- Server `src/orchestration-v2/Adapters` plus `src/provider`: 1867 of 1870 pass. The 3 failures
  (`AntigravityInstallation`, two `ClaudeSkills` cases, one an `EEXIST` in a temp dir) fail identically on
  unpatched upstream, so they are pre-existing.
- Typecheck: `provider-acp`, `provider-acp-registry`, `apps/server`, `apps/web` all exit 0 with 0 errors.
  Lint and knip are clean.
- Live check: a temporary, uncommitted vitest file ran T3's registry adapter and ACP runtime against real
  `openclaw acp` 2026.11.3, with a throwaway loopback Gateway.
  - `"default"`: `session/new` with `t3-code` is rejected. T3 shows only the generic "The provider session
    could not be opened. Check that the provider is installed and signed in" and hides OpenClaw's reason.
  - `"none"`: `session/new` `[]` succeeds. A fresh process then sends `initialize`, `session/new` `[]` and
    `session/load` `[]`, and the load succeeds.

### Findings for Phase 2

- On reopen, the adapter opened a new OpenClaw session before loading the old one. That leaves an extra
  `acp-bridge:<uuid>` session in the Gateway each time. Check whether the real orchestrator path does the same
  (it passes `initialNativeThreadId`).
- Agent setup errors are reduced to the generic message above. Phase 2 should show the agent's reason, for
  example a Gateway that is down or a rejected setup.
- Whether a fork works was not tested: OpenClaw does not advertise `session/fork`.

## Phase 3 progress (2026-11-12)

Host setup on the mini, all as user `admin`:

- T3 server: patched release `47ebce46c` runs as LaunchAgent `local.t3code-fork` on `127.0.0.1:3773` with
  `--base-dir ~/.t3` and telemetry off. Tailscale Serve maps `https://mac-mini-m6.tail5d38a1.ts.net:8443` to
  it (tailnet only); the fleet dashboard keeps 443. `t3 service install` was not usable: it downloads the
  stock release binary even when run from the fork, and that binary crash-looped on the newer state file.
  `ops/deploy.sh` builds a commit as a release worktree under `~/t3-fork/releases/` and switches
  `~/t3-fork/current`; deploying an older commit is the rollback.
- Claude Code CLI 2.1.322 at `~/.local/bin/claude`, logged in (Max) from the GUI session. SSH sessions cannot
  read the login keychain; `ops/gui-run.sh` runs keychain-bound checks as a one-shot GUI LaunchAgent.
- OpenClaw Gateway: LaunchAgent `ai.openclaw.gateway`, loopback `127.0.0.1:18789`, token auth, model
  `anthropic/claude-opus-5-5` on the `claude-cli` runtime; no API key. The Gateway service PATH is fixed by
  OpenClaw on macOS, so `/opt/homebrew/bin/claude` links to `~/.local/bin/claude`.
- OpenClaw hardening: `tools.profile coding`, `tools.deny [group:web, cron]`, elevated off, browser plugin
  off, `tools.fs.workspaceOnly`, exec preset `cautious` (allowlist empty, ask on miss, fallback deny). A shell
  command with no approver attached was denied. `security audit --deep`: 0 critical; the deep probe lacks
  `operator.read` (no device pairing to grant it to).
- T3 providers: Claude (native), 4 managed ChatGPT Codex instances (`Codex - 0..3`, four distinct accounts),
  OpenClaw as Local ACP command with Per-session MCP = None. Remote ChatGPT sign-in ends on a localhost page
  on the mini; paste that URL into T3.
- Fix found during setup: `47ebce46c fix(web): show Per-session MCP for local ACP commands`.

First live T3 → OpenClaw thread (project `~/Developer/openclaw-t3-test`, Supervised):

- Turn 1: exact reply `T3_OPENCLAW_OK`. No per-session MCP error.
- Turn 2 (follow-up): recalled the previous reply, read `README.md` from the project (marker `tangerine-42`),
  reported cwd `openclaw-t3-test`. File reads needed no approval.
- OpenClaw exposes one model entry (`Default`) plus its ACP config options (thought level, fast mode, ...).

### Live end-to-end results (2026-11-12, release `47ebce46c`)

| Check                                                                        | Result                                                                                                                                                                                                           |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OpenClaw selectable in T3, new thread, no per-session MCP error              | pass                                                                                                                                                                                                             |
| Prompt, streamed reply, follow-up with context                               | pass                                                                                                                                                                                                             |
| Reads project file in thread cwd (`~/Developer/openclaw-t3-test`)            | pass                                                                                                                                                                                                             |
| Exec deny: command not executed, thread reports it was blocked               | pass, but only when resolved on the mini (`openclaw approvals resolve <id> deny`)                                                                                                                                |
| Exec approve: command runs only after `allow-once`; T3 shows the file change | pass, same caveat                                                                                                                                                                                                |
| Exec approval shown in T3                                                    | **fail**: OpenClaw 2026.11.3 (claude-cli runtime) sends a `tool_call` update but no `session/request_permission`; confirmed with a standalone ACP client. The approval waits in the Gateway (30 min, then deny). |
| Client disconnect mid-approval                                               | run aborted, approval cancelled, nothing executed                                                                                                                                                                |
| Cancel (Stop) a long reply                                                   | pass: "Run interrupted"; Gateway `chat.abort`, no leftover `claude` workers                                                                                                                                      |
| Two concurrent OpenClaw threads                                              | pass: separate `acp-bridge:<uuid>` sessions, no shared context                                                                                                                                                   |
| Reload / T3 server restart                                                   | pass: `session/close` on shutdown, then `initialize` and `session/load` (no extra `session/new`), history intact, bridges exit with T3                                                                           |
| Gateway restart while T3 runs                                                | pass: bridge reconnects, history intact                                                                                                                                                                          |
| Gateway down                                                                 | fails fast with "Provider error · Internal error" (not descriptive); a message during the ~5 s Gateway startup fails the same way; retry works                                                                   |
| Claude native thread writes a file                                           | pass (Sonnet 5.5, native diff)                                                                                                                                                                                   |
| Codex account 0 and 1 threads write files                                    | pass; separate `codex app-server` per account (`~/.codex` and a T3 shadow home)                                                                                                                                  |
| Files exist only on the mini                                                 | pass                                                                                                                                                                                                             |
| Secrets                                                                      | none in argv, `settings.json`, T3/provider/Gateway logs; the `openclaw acp` process env has only `T3CODE_THREAD_ID`                                                                                              |

### Resources (sampler every 30 s, 15:09-15:29)

| Window                                                                   | mem free min | swap | compressed max | CPU busy avg/max | agent+service RSS max |
| ------------------------------------------------------------------------ | ------------ | ---- | -------------- | ---------------- | --------------------- |
| idle                                                                     | 77 %         | 0    | 1.35 GB        | 4 % / 6 %        | 3.1 GB                |
| E2E tests                                                                | 75 %         | 0    | 1.34 GB        | 4 % / 15 %       | 4.2 GB                |
| 3 agents (OpenClaw, Claude, Codex) + T3 test-suite loop + fleet services | 77 %         | 0    | 1.21 GB        | 15 % / 47 %      | 6.7 GB                |

About 9 minutes of heavy concurrent load, not a continuous 30-minute soak. Xcode builds and simulators were
not part of the load. Recommended start: up to 3 concurrent agent threads plus normal builds; measure again
before adding simulator-heavy work.

### Other findings

- OpenClaw runs a heartbeat turn every 30 minutes on the default model (Opus 5.5) and short Haiku summaries
  after activity, on the Claude subscription.
- `memory_pressure` free % stays high while RSS grows, because it counts inactive and purgeable memory; swap
  and compression are the better warning signs.

## Open items

- Phase 3 host setup needs the user: Claude Code login, OpenClaw onboarding, Codex accounts in T3, and pairing.
- Anthropic route: API key first (only if the Max monthly credit is shown as Console credit), with fallback to
  Claude CLI (subscription) via `agents.defaults.model.fallbacks`. An explicit model pick in T3 disables the
  fallback.
- Fleet dashboard owns Tailscale HTTPS port 443. T3 must use `--tailscale-serve-port 8443`.
- Over SSH, `gh` cannot read its token, because the login keychain is locked in SSH sessions. Git uses the
  account SSH key `~/.ssh/github_account_admin` instead. Run `gh` API calls (PRs) from the MacBook.

## Phase 2 hardening (2026-11-12)

Branch `openclaw-hardening`. Commits: `09e0daae3` (readable errors), `d04797bbd` (no rollback for ACP Registry
agents), `d752f28b2` (OpenClaw replay fixture, log check), plus these notes. Deployed release: `d752f28b2c4a`.

### Findings against the real agent (openclaw acp 2026.11.3)

| Case                                 | What OpenClaw does                                                                                   | T3 before                                                            | T3 now                                                                                                      |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Per-session MCP rejected             | `-32603 Internal error`, `data.details: "ACP bridge mode does not support per-session MCP servers…"` | "The provider session could not be opened. Check that … signed in"   | "The provider session could not be opened: ACP bridge mode does not support per-session MCP servers. …"     |
| Gateway down at start                | No stdout; stderr `ACP bridge failed: connect ECONNREFUSED 127.0.0.1:<port>`; exit 1 within ~1 s     | "… the provider process exited with code 1. Check the server logs …" | Same, plus `(ACP bridge failed: connect ECONNREFUSED 127.0.0.1:<port>)`                                     |
| Gateway dies during a session        | Prompt gets `-32603 Internal error`, `data.details: "gateway not connected"`; bridge stays up        | "Provider error · Internal error"                                    | "Internal error: gateway not connected"                                                                     |
| Executable missing                   | (spawn `ENOENT`)                                                                                     | "The provider session could not be opened. Check that … signed in"   | "…: the provider executable was not found. Check the executable path in the provider settings, …"           |
| Malformed stdout (e.g. no `acp` arg) | Help text on stdout                                                                                  | Generic "could not be opened" (fails fast, no hang)                  | "…: the provider wrote output that is not ACP. Check that the command and its arguments start an ACP agent" |
| Fork from this response              | No `session/fork` advertised                                                                         | Works as T3 **Context handoff** (new `session/new` + transcript)     | Unchanged. Live: the fork recalled the last file name. Native fork was already off (`canForkThread=false`). |
| Edit from here (rollback)            | No truncation in ACP v1                                                                              | Files and T3 history roll back, but the agent restarts **empty**     | Hidden for ACP Registry and Local ACP command instances; the server policy rejects it too                   |

The rollback gap is not OpenClaw-specific: the shared ACP adapter's `rollbackThread` always starts a fresh agent
session and T3 sends no history afterwards. Live check before the fix: after rollback in a forked OpenClaw thread,
the agent answered "This is the first message I can see in this conversation."

### Change

- `packages/provider-core/src/server/failure.ts` (shared mapping, no agent-name checks): first line of
  `data.details`; last stderr line that reads as an error; missing executable; non-ACP stdout. Each reason is at
  most 300 characters and goes through the existing redaction (URL credentials and queries, `Bearer`, `token=`,
  `sk-…`). Stderr lines with no error word (banners, echoed prompts) stay hidden, so the old wording stays for them.
- `packages/provider-acp-registry`: prompt failures append `data.details` to the agent's message unless the message
  already contains it. Registry and Local ACP command instances report `canRollbackThread`,
  `providerCanRollbackConversation` and `providerRollbackReturnsSnapshot` as false, and the provider snapshot sets
  `supportsConversationRollback: false` (as Cursor and Grok do), which hides **Edit from here**.
- `docs/user/providers-acp.md`: one paragraph on rollback and fork for ACP agents.

### Tests

- `provider-core/failure.test.ts`: stderr error line (bounded, redacted, banner lines stay hidden),
  `data.details` (first line, redacted, generic text kept without it), missing executable. All three fail on the
  old code.
- `AcpRegistryAdapterV2.test.ts`, real child processes through the registry adapter (local `openclaw acp` settings):
  missing executable; agent writes `ACP bridge failed: connect ECONNREFUSED …` and exits before `initialize`;
  malformed stdout (fails at once, no hang); `session/new` rejected with OpenClaw's `data.details`. Prompt
  failure with `gateway not connected`. Rollback capabilities are false. All fail on the old code.
- Same file: with Per-session MCP `none`, the native request and protocol logs and the agent environment carry no
  `T3_ACP_MCP_*` and no bearer token (with `default` they do, so the check is not empty).
- Replay fixture `apps/server/src/orchestration-v2/Adapters/fixtures/openclaw/{new_prompt,load_prompt}.ndjson`,
  recorded from `openclaw acp` 2026.11.3 with a raw ACP client (scripts kept outside the repo in
  `~/Developer/openclaw-t3-probe/acp-record.mjs` and `to-fixture.py`). Session id and home path replaced; no
  credentials in the frames. The test checks capabilities, the reply, and that a reopen sends `session/load`
  for the same session (no extra `session/new`). Breaking an outbound expectation or an inbound reply fails it.
- The recording used the real Gateway only as an ordinary ACP client (as T3 does) and closed the session. The
  Gateway-down data came from a throwaway `--dev --auth none` Gateway on port 18801 with a scratch home, removed
  afterwards. The real Gateway (`ai.openclaw.gateway`, 18789) was not stopped or reconfigured.
- `provider-acp-registry/driver.test.ts`: snapshot reports `supportsConversationRollback: false`.

| Suite                                                                              | Result                            |
| ---------------------------------------------------------------------------------- | --------------------------------- |
| `packages/provider-core`                                                           | 245 passed                        |
| `packages/provider-acp`                                                            | 105 passed                        |
| `packages/provider-acp-registry`                                                   | 64 passed                         |
| `apps/server` `src/orchestration-v2/Adapters`, `src/provider`, registry replays    | 1888 of 1891 (3 known, below)     |
| Typecheck: `provider-core`, `provider-acp`, `provider-acp-registry`, `apps/server` | exit 0, 0 errors                  |
| `vp lint` / `vp fmt --check`                                                       | 0 errors (8 old warnings) / clean |

The 3 failures are the known pre-existing ones (`AntigravityInstallation`, two `ClaudeSkills` cases); they fail
the same way on unpatched upstream on this host. `apps/web` was not touched.

### Live verification

Release `d752f28b2c4a` via `~/t3-fork/deploy.sh` (rollback: deploy `47ebce46c`).

- A temporary Local ACP instance (`openclaw acp`, Per-session MCP left on "T3 Code tools") showed, in the thread
  and its banner: "The provider session could not be opened: ACP bridge mode does not support per-session MCP
  servers. Configure MCP on the OpenClaw gateway or agent instead." Screenshot in the session notes folder.
- A temporary instance with a missing executable is marked "Unavailable" in the model picker (Settings: "Not
  found"), so no thread starts on it; the new message covers an executable that disappears after the probe.
- OpenClaw threads no longer show **Edit from here**; **Fork from this response** is still there.
- The OpenClaw instance (Per-session MCP = None) still answers (`PHASE2_LIVE_OK`).
- Both temporary instances were removed. Test threads "Dashboard Approval Probe" (the fork) and "MCP Reject
  Probe" remain in `openclaw-t3-test`.
- Not checked live: Gateway down during a T3 thread (that would mean stopping the real Gateway); covered by the
  recorded reply and the tests.

### Still unsupported

- Exec approvals in T3: OpenClaw sends no `session/request_permission` (separate OpenClaw issue).
- Conversation rollback for any ACP agent (protocol limit). Upstream could replay the kept turns as a context
  handoff after rollback instead of hiding it; that touches the orchestrator and is not done here.
- Native fork (`session/fork`): not advertised by OpenClaw; fork uses the context handoff.

## Codex auto-switch (2026-11-12)

Opt-in setting `autoSwitchCodexAccounts` (default off, "Switch Codex accounts on usage limits"). It moves a Codex
thread to another enabled, signed-in Codex instance with the same continuation key (one shared Codex home).

- Picker: `pickCodexAccountSwitch` in `packages/shared/src/usageLimits.ts`. Score = lower remaining percent of the
  5-hour and weekly windows; ties go to the newer `checkedAt`; a passed reset counts as 0 % used.
- Before a start (`Orchestrator.resolveCodexAccountSwitch`): immediate starts and queued starts that continue the
  conversation. Triggers on a window at 99 % or more with a future reset, or on a usage-limit stop of that account in
  the same thread (an unknown reset is assumed to hold 5 hours). Skipped while the active session runs background
  work. The new run gets a `system_notice` turn item.
- Mid-work: `CodexAccountSwitchWorker` sends `message.dispatch` with `manualContinuationOfRunId` and command id
  `codex-switch:<runId>` when a target exists; it never sends without one, so resume-at-reset keeps working.
- Managed Codex: `CodexManagedProvider` keeps rate-limit windows from live sessions and publishes them in its
  snapshot. On the mini, managed sessions on 2026-11-12 reported `primary: null, secondary: null`, so the
  window trigger has no data there today; the usage-limit stop is the trigger that applies.
