// Attack execution (攻撃の実行) — running an attack's strategy against a
// scenario's manual interventions, one slot boundary at a time. The
// strategy's actions become interventions of the slots ahead, marked as the
// attackers' (必須 21); an action is discarded — kept in the list with its
// mark and reason — when it
//   - would act on a slot already computed (not causal: a strategy sees the
//     boundary and decides for the slots after it),
//   - lies outside the attackers' capability range (必須 18),
//   - contradicts a manual intervention of the same slot and validator
//     (手動介入を優先, 必須 21), or
//   - would create a fork past the fork limit (必須 10).
// The generated actions are never edited by hand and never saved: a scenario
// holds the attack instance and regenerates them deterministically on replay.

import type { Action } from "../model/action";
import {
  capabilityOf,
  observeAsAttackers,
  type Attack,
  type AttackParams,
  type AttackerObservation,
} from "../model/attack";
import { forkCountAfter } from "../model/chainState";
import type { InitialConditions } from "../model/initialConditions";
import { coversMessage, type MessageRef } from "../model/messageRef";
import { proposerForSlot } from "../model/schedule";
import { atEnd, type SlotIndex, type ValidatorIndex } from "../model/types";
import {
  MAX_FORKS,
  pendingForkParents,
  spanCovers,
  type Intervention,
} from "./intervention";
import { viewOf, type Delivery } from "./localView";
import { scheduleOf } from "./schedule";
import type { SimulationState } from "./simulation";

/** An attack bound into a scenario: which attack (`id` names it in the
 * library and in saved scenarios), the concrete attacker set and the
 * parameters. At most one per scenario. */
export interface AttackInstance {
  readonly id: string;
  readonly attack: Attack;
  readonly attackers: readonly ValidatorIndex[];
  readonly params: AttackParams;
}

export type DiscardReason =
  | "not-causal"
  | "outside-capability"
  | "conflicts-with-manual"
  | "fork-limit";

/** One action a strategy produced, with the boundary it was produced at
 * (the attackers' mark) and, when discarded, why. */
export interface GeneratedAction {
  readonly action: Action;
  readonly generatedAt: SlotIndex;
  readonly discarded?: DiscardReason;
}

/** The attackers' observation at the boundary `state` ends on. */
export function attackerObservation(
  state: SimulationState,
  instance: AttackInstance,
  config: InitialConditions,
  delivery: Delivery,
): AttackerObservation {
  const views = instance.attackers.map((a) =>
    viewOf(state.log, a, atEnd(state.slot), delivery),
  );
  return observeAsAttackers(instance.attackers, views, state.slot, config, scheduleOf(config));
}

/** The first slot an action takes effect in — what the intervention list
 * orders a generated action by. */
export function effectSlot(action: Action): SlotIndex {
  switch (action.kind) {
    case "partition":
    case "stop":
      return action.fromSlot;
    case "delay":
    case "drop":
      return action.message.slot;
    default:
      return action.slot;
  }
}

interface ActorSpan {
  readonly validators: readonly ValidatorIndex[];
  readonly fromSlot: SlotIndex;
  readonly toSlot: SlotIndex | undefined;
}

/** Who an intervention makes act (or not) and when — the action axis. */
function actorSpan(i: Intervention, config: InitialConditions): ActorSpan | undefined {
  switch (i.kind) {
    case "stop":
    case "offline":
      return { validators: i.validators, fromSlot: i.fromSlot, toSlot: i.toSlot };
    case "double-propose":
    case "double-vote":
    case "vote-target":
      return { validators: [i.validator], fromSlot: i.slot, toSlot: i.slot };
    case "propose-parent":
    case "omit-inclusion":
      return {
        validators: [proposerForSlot(i.slot, config)],
        fromSlot: i.slot,
        toSlot: i.slot,
      };
    default:
      return undefined;
  }
}

const spansOverlap = (a: ActorSpan, b: ActorSpan): boolean =>
  spanCovers(a.fromSlot, a.toSlot, Math.max(a.fromSlot, b.fromSlot)) &&
  spanCovers(b.fromSlot, b.toSlot, Math.max(a.fromSlot, b.fromSlot));

const shareValidator = (
  a: readonly ValidatorIndex[],
  b: readonly ValidatorIndex[],
): boolean => a.some((v) => b.includes(v));

/** Whether two message references can name the same message: one covers
 * the other (the same reference, or an exact reference inside a reference
 * to everything of its sender, slot and kind). */
const messagesOverlap = (a: MessageRef, b: MessageRef): boolean =>
  coversMessage(a, b) || coversMessage(b, a);

/**
 * Whether a generated action contradicts a manual intervention — same slot,
 * same validator, same axis: both make the validator act (or stay silent)
 * in that slot, both bend the delivery of the same message, or both
 * partition a validator in that slot.
 */
function conflicts(action: Action, manual: Intervention, config: InitialConditions): boolean {
  const a = actorSpan(action, config);
  const m = actorSpan(manual, config);
  if (a && m) return shareValidator(a.validators, m.validators) && spansOverlap(a, m);
  if (
    (action.kind === "delay" || action.kind === "drop") &&
    (manual.kind === "delay" || manual.kind === "drop")
  ) {
    return messagesOverlap(action.message, manual.message);
  }
  if (action.kind === "partition" && manual.kind === "partition") {
    return (
      shareValidator(action.groups.flat(), manual.groups.flat()) &&
      spansOverlap(
        { validators: [], fromSlot: action.fromSlot, toSlot: action.toSlot },
        { validators: [], fromSlot: manual.fromSlot, toSlot: manual.toSlot },
      )
    );
  }
  return false;
}

/**
 * Run the strategy at the boundary `state` ends on and judge each action in
 * order: the accepted ones are appended to `effective` (the manual
 * interventions plus every action accepted so far), so a later fork
 * designation is charged against the earlier ones.
 */
export function generateActions(
  state: SimulationState,
  instance: AttackInstance,
  config: InitialConditions,
  manual: readonly Intervention[],
  effective: Intervention[],
  delivery: Delivery,
): GeneratedAction[] {
  const observation = attackerObservation(state, instance, config, delivery);
  const boundary = state.slot;
  const generated: GeneratedAction[] = [];
  for (const action of instance.attack.strategy(observation, instance.params)) {
    const reason = ((): DiscardReason | undefined => {
      if (effectSlot(action) <= boundary) return "not-causal";
      if (
        capabilityOf(
          action,
          instance.attackers,
          observation.schedule,
          instance.params.maxDelay,
        ) === undefined
      ) {
        return "outside-capability";
      }
      if (manual.some((m) => conflicts(action, m, config))) return "conflicts-with-manual";
      if (
        action.kind === "propose-parent" &&
        forkCountAfter(state.tree, state.chainStates, [
          ...pendingForkParents(effective, boundary),
          action.parent,
        ]) > MAX_FORKS
      ) {
        return "fork-limit";
      }
      return undefined;
    })();
    generated.push(
      reason === undefined
        ? { action, generatedAt: boundary }
        : { action, generatedAt: boundary, discarded: reason },
    );
    if (reason === undefined) effective.push(action);
  }
  return generated;
}
