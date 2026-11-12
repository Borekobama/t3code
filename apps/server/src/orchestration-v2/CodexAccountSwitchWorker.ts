import {
  CommandId,
  MessageId,
  type OrchestrationV2Command,
  type OrchestrationV2ThreadProjection,
  type RunId,
  type ServerProvider,
  type ThreadId,
} from "@t3tools/contracts";
import {
  latestExecutedRun,
  latestRootProviderFailure,
} from "@t3tools/shared/orchestrationV2ThreadError";
import { pickCodexAccountSwitch } from "@t3tools/shared/usageLimits";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";

import { forkParked } from "../serverActivation.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as Orchestrator from "./Orchestrator.ts";
import * as ProviderAdapterRegistry from "./ProviderAdapterRegistry.ts";
import * as ThreadManagement from "./ThreadManagementService.ts";

/**
 * Continues a Codex run that stopped on its usage limit when another account of the same Codex
 * home can take it. The continuation's start moves the thread to that account and posts the
 * notice; without a target nothing is sent and resume-at-reset applies as before.
 */
export function codexAccountSwitchCommands(input: {
  readonly projection: Pick<
    OrchestrationV2ThreadProjection,
    "thread" | "runs" | "turnItems" | "runtimeRequests"
  >;
  readonly runId: RunId;
  readonly providers: ReadonlyArray<ServerProvider>;
  readonly now: number;
}): ReadonlyArray<OrchestrationV2Command> {
  const { projection, runId } = input;
  const run = latestExecutedRun(projection.runs);
  if (
    run?.id !== runId ||
    latestRootProviderFailure(run, projection.turnItems)?.class !== "usage_limit" ||
    projection.thread.archivedAt !== null ||
    projection.thread.deletedAt !== null ||
    projection.runtimeRequests.some((request) => request.status === "pending")
  )
    return [];
  const limited = Orchestrator.usageLimitedInstanceIds(projection, input.now);
  const target = pickCodexAccountSwitch({
    providers: input.providers,
    currentInstanceId: projection.thread.modelSelection.instanceId,
    now: input.now,
    limitReached: limited.has(projection.thread.modelSelection.instanceId),
    excludedInstanceIds: limited,
  });
  if (target === null) return [];
  const threadId = projection.thread.id;
  const continuation: OrchestrationV2Command = {
    type: "message.dispatch",
    commandId: CommandId.make(`codex-switch:${runId}`),
    messageId: MessageId.make(`codex-switch:${runId}`),
    threadId,
    manualContinuationOfRunId: runId,
    text: "Continue where you left off.",
    attachments: [],
    dispatchMode: { type: "start_immediately" },
    createdBy: "agent",
    creationSource: "server",
  };
  // The limit held the queue; a server continuation does not release it.
  return projection.runs.some((candidate) => candidate.status === "queued" && candidate.queueHeld)
    ? [
        continuation,
        {
          type: "queue.resume",
          commandId: CommandId.make(`codex-switch-queue:${runId}`),
          threadId,
        },
      ]
    : [continuation];
}

export const layer = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrator = yield* Orchestrator.OrchestratorV2;
    const threads = yield* ThreadManagement.ThreadManagementService;
    const settings = yield* ServerSettings.ServerSettingsService;
    const { listProviders } = yield* ProviderAdapterRegistry.ProviderAdapterRegistryV2;
    if (listProviders === undefined) return;
    const continueOnAnotherAccount = Effect.fn("CodexAccountSwitchWorker.continue")(function* (
      threadId: ThreadId,
      runId: RunId,
    ) {
      if (!(yield* settings.getSettings).autoSwitchCodexAccounts) return;
      const projection = yield* orchestrator.getThreadRecords(
        threadId,
        ["runs", "turnItems", "runtimeRequests"],
        { turnItemTypes: ["error"] },
      );
      const commands = codexAccountSwitchCommands({
        projection,
        runId,
        providers: yield* listProviders(),
        now: DateTime.toEpochMillis(yield* DateTime.now),
      });
      // The continuation's command id makes a repeated event a no-op.
      for (const command of commands) yield* threads.dispatch(command);
    });
    yield* forkParked(
      Stream.runForEach(orchestrator.streamDomainEvents, (event) => {
        // The failure item and the failed run can commit in either order.
        const runId =
          event.type === "run.updated" && event.payload.status === "failed"
            ? event.runId
            : event.type === "turn-item.updated" && event.payload.type === "error"
              ? event.payload.runId
              : null;
        return runId == null
          ? Effect.void
          : continueOnAnotherAccount(event.threadId, runId).pipe(
              Effect.catchCause((cause) =>
                Effect.logWarning("orchestration-v2.codex-account-switch.failed", {
                  threadId: event.threadId,
                  runId,
                  cause,
                }),
              ),
            );
      }),
    );
  }),
);
