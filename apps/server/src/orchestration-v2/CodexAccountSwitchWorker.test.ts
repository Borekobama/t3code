import { assert, describe, it } from "@effect/vitest";
import {
  type OrchestrationV2ServerCommand,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2Run,
  type ServerProvider,
  MessageId,
  NodeId,
  ProviderDriverKind,
  ProviderInstanceId,
  RunId,
  ThreadId,
  TurnItemId,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";

import * as ServerSettings from "../serverSettings.ts";
import * as CodexAccountSwitchWorker from "./CodexAccountSwitchWorker.ts";
import { codexAccountSwitchCommands } from "./CodexAccountSwitchWorker.ts";
import * as Orchestrator from "./Orchestrator.ts";
import * as ProviderAdapterRegistry from "./ProviderAdapterRegistry.ts";
import * as ThreadManagement from "./ThreadManagementService.ts";

const nowMs = Date.parse("2026-11-12T12:00:00.000Z");
const threadId = ThreadId.make("thread:limited");
const main = ProviderInstanceId.make("codex");
const spare = ProviderInstanceId.make("codex-spare");
const claude = ProviderInstanceId.make("claude");

const account = (instanceId: ProviderInstanceId, usedPercent: number | null): ServerProvider => ({
  instanceId,
  driver: ProviderDriverKind.make(instanceId === claude ? "claudeAgent" : "codex"),
  enabled: true,
  installed: true,
  version: null,
  status: "ready",
  auth: { status: "authenticated" },
  checkedAt: "2026-11-12T11:00:00.000Z",
  models: [],
  slashCommands: [],
  skills: [],
  continuation: { groupKey: "codex:home:/shared" },
  ...(usedPercent === null
    ? {}
    : {
        usageLimits: {
          checkedAt: "2026-11-12T11:00:00.000Z",
          windows: [{ id: "primary", kind: "session", label: "Session", usedPercent }],
        },
      }),
});

const run = (
  ordinal: number,
  instanceId: ProviderInstanceId,
  status: OrchestrationV2Run["status"],
  overrides: Partial<OrchestrationV2Run> = {},
): OrchestrationV2Run => {
  const endedAt = DateTime.makeUnsafe(nowMs - (10 - ordinal) * 60_000);
  return {
    id: RunId.make(`run:${ordinal}`),
    threadId,
    ordinal,
    providerInstanceId: instanceId,
    modelSelection: { instanceId, model: "gpt-5.5" },
    providerThreadId: null,
    userMessageId: MessageId.make(`message:${ordinal}`),
    rootNodeId: NodeId.make(`node:${ordinal}`),
    activeAttemptId: null,
    status,
    requestedAt: endedAt,
    startedAt: status === "queued" ? null : endedAt,
    completedAt: status === "queued" ? null : endedAt,
    checkpointId: null,
    contextHandoffId: null,
    ...overrides,
  };
};

const failure = (failed: OrchestrationV2Run, failureClass: "usage_limit" | "provider_error") =>
  ({
    id: TurnItemId.make(`error:${failed.id}`),
    type: "error",
    status: "failed",
    runId: failed.id,
    nodeId: failed.rootNodeId,
    ordinal: failed.ordinal * 100,
    updatedAt: failed.completedAt,
    failure: { class: failureClass, message: "Limit reached", code: null, retryable: null },
  }) as never;

const limited = run(1, main, "failed");
const projectionFor = (input: {
  readonly runs: ReadonlyArray<OrchestrationV2Run>;
  readonly failed?: ReadonlyArray<OrchestrationV2Run>;
  readonly failureClass?: "usage_limit" | "provider_error";
  readonly threadInstance?: ProviderInstanceId;
}) => ({
  thread: {
    id: threadId,
    archivedAt: null,
    deletedAt: null,
    modelSelection: { instanceId: input.threadInstance ?? main, model: "gpt-5.5" },
  } as never,
  runs: input.runs,
  turnItems: (input.failed ?? [limited]).map((failed) =>
    failure(failed, input.failureClass ?? "usage_limit"),
  ),
  runtimeRequests: [],
});

describe("codexAccountSwitchCommands", () => {
  it.each([
    [
      "continues on another account",
      { runs: [limited] },
      [account(spare, null)],
      ["message.dispatch"],
    ],
    [
      "then resumes the queue the limit held",
      { runs: [limited, run(2, main, "queued", { queueHeld: true })] },
      [account(spare, 20)],
      ["message.dispatch", "queue.resume"],
    ],
    ["nothing without another account", { runs: [limited] }, [account(spare, 99)], []],
    [
      "nothing when the other account already hit its limit here",
      {
        runs: [run(0, spare, "failed"), limited],
        failed: [run(0, spare, "failed"), limited],
      },
      [account(spare, null)],
      [],
    ],
    [
      "nothing for another provider",
      {
        runs: [run(1, claude, "failed")],
        failed: [run(1, claude, "failed")],
        threadInstance: claude,
      },
      [account(claude, null), account(spare, null)],
      [],
    ],
    [
      "nothing for another failure",
      { runs: [limited], failureClass: "provider_error" as const },
      [account(spare, null)],
      [],
    ],
    [
      "nothing once a later run started",
      { runs: [limited, run(2, spare, "running")] },
      [account(spare, null)],
      [],
    ],
  ] as const)("sends %s", (_name, projection, others, expected) => {
    const commands = codexAccountSwitchCommands({
      projection: projectionFor(projection),
      runId: (projection.runs.find((candidate) => candidate.status === "failed") ?? limited).id,
      providers: [account(main, null), ...others],
      now: nowMs,
    });
    assert.deepEqual(
      commands.map((command) => command.type),
      [...expected],
    );
    const continuation = commands[0];
    if (continuation?.type === "message.dispatch") {
      assert.equal(continuation.manualContinuationOfRunId, limited.id);
      assert.equal(continuation.commandId, `codex-switch:${limited.id}`);
    }
  });
});

it.effect("continues only while the setting is on", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(nowMs);
    const events = yield* Queue.unbounded<OrchestrationV2DomainEvent>();
    const dispatched = yield* Queue.unbounded<OrchestrationV2ServerCommand>();
    const settingsReads = yield* Ref.make(0);
    const limitedIn = (id: ThreadId) => run(1, main, "failed", { id: RunId.make(`run:${id}`) });
    const layer = CodexAccountSwitchWorker.layer.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(Orchestrator.OrchestratorV2)({
            streamDomainEvents: Stream.fromQueue(events),
            getThreadRecords: ((id: ThreadId) =>
              Effect.succeed(
                projectionFor({ runs: [limitedIn(id)], failed: [limitedIn(id)] }),
              )) as never,
          }),
          Layer.mock(ThreadManagement.ThreadManagementService)({
            dispatch: (command) => Queue.offer(dispatched, command).pipe(Effect.as({} as never)),
          }),
          Layer.mock(ProviderAdapterRegistry.ProviderAdapterRegistryV2)({
            listProviders: () => Effect.succeed([account(main, null), account(spare, null)]),
          }),
          Layer.mock(ServerSettings.ServerSettingsService)({
            // Off for the first event, on for the second.
            getSettings: Ref.getAndUpdate(settingsReads, (reads) => reads + 1).pipe(
              Effect.map((reads) => ({ autoSwitchCodexAccounts: reads > 0 }) as never),
            ),
          }),
        ),
      ),
    );
    yield* Effect.gen(function* () {
      for (const id of ["thread:off", "thread:on"].map((value) => ThreadId.make(value))) {
        yield* Queue.offer(events, {
          type: "run.updated",
          threadId: id,
          runId: limitedIn(id).id,
          payload: { status: "failed" },
        } as never);
      }
      // Events run in order, so the first dispatch shows the earlier event sent nothing.
      const command = yield* Queue.take(dispatched);
      assert.equal(command.commandId, "codex-switch:run:thread:on");
    }).pipe(Effect.provide(layer));
  }),
);
