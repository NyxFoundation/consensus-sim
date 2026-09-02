// Public surface of the domain layer (最抽象モデル).
// UI and infrastructure import from here; nothing here imports them back.
//
// The layer is two modules, split by one question — is the type what a
// formalization of the protocol would take as its object?
//
// - model/ (本質的仕様): the types a Lean formalization targets as they are —
//   View / Vote / Block (with its body) / BlockTree / Equivocation /
//   ChainState / ProtocolParams and the presets / the inputs and outputs of
//   fork choice and finality / message identity / the proposer and committee
//   schedule / the initial conditions the protocol reads / the attack triple,
//   the attacker's action vocabulary, the goal predicates and strategies.
// - sim/ (シミュレーション上の制約): what this simulator adds for its own
//   purposes — the message log and delivery rules, the slot driver and its
//   directives, interventions and their queue, the execution of an attack's
//   strategy against the queue (generated actions and their discards),
//   scenarios and their codec, validator names and the 4〜10 bound, the fork
//   limit.
//
// sim/ may import model/; model/ never imports sim/ (enforced by
// tests/domain/purity.test.ts). The type catalog (型一覧) shows model/ only.

export * from "./model/types";
export * from "./model/blockTree";
export * from "./model/view";
export * from "./model/messageRef";
export * from "./model/forkChoice";
export * from "./model/finality";
export * from "./model/inclusion";
export * from "./model/chainState";
export * from "./model/protocolParams";
export * from "./model/config";
export * from "./model/schedule";
export * from "./model/protocol";
export * from "./model/action";
export * from "./model/attackGoal";
export * from "./model/attack";

export * from "./sim/validatorSet";
export * from "./sim/messages";
export * from "./sim/localView";
export * from "./sim/simulation";
export * from "./sim/intervention";
export * from "./sim/attackRun";
export * from "./sim/scenario";
export * from "./sim/scenarioCodec";
