# OpenClaw as a T3 ACP provider: compatibility manifest

Fork-only notes for `Borekobama/t3code`. Not part of any upstream PR.

Status: **Phase 0 complete (2026-11-12).** The baseline is green, the blocker is reproduced, and the patch
design is below. No T3 source has been changed yet.

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

## Open items

- Phase 3 host setup needs the user: Claude Code login, OpenClaw onboarding, Codex accounts in T3, and pairing.
- Anthropic route: API key first (only if the Max monthly credit is shown as Console credit), with fallback to
  Claude CLI (subscription) via `agents.defaults.model.fallbacks`. An explicit model pick in T3 disables the
  fallback.
- Fleet dashboard owns Tailscale HTTPS port 443. T3 must use `--tailscale-serve-port 8443`.
- Pushing from the mini over SSH fails: `gh` stores its token in the login keychain, which is locked in SSH
  sessions.
