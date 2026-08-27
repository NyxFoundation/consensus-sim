import Looper.Core.Json
import Looper.Core.Glob
import Looper.Core.Doc
import Looper.Asl.Check

/-!
`Looper.Asl.Engine` — agentic-state-loop レシピの schema 駆動 canonical
state エンジンの純粋決定核(vendored `files/loop/scripts/state.py` の置換元)。

外部契約(stdout / exit code)は Python 版と同一に保つ: predicate
(should-stop)は exit 0 = yes / 1 = no / ≥ 2 = エンジン失敗(fail closed)。
このモジュールは判定と出力ペイロードの組み立てだけを行い、ファイル・
ロック・時刻は `Looper.Cli.Asl`(IO シェル)が注入する。

Python との裁定済み仕様差(META.md §31.2):
- 未捕捉例外で exit 1(predicate の「no」と同じ符号)に落ちる病的形状
  (非文字列 gate reason の sorted、int() 不能な counters 等)は、明示的な
  ハードエラー(`.error` → exit 2)へ写す。gate を黙って外す方向の
  クラッシュを停止側に倒す fail-closed 化であり、I-021 と同型。
- dict / set の要素撹拌に依存する箇所はない(reasons の sorted は
  コードポイント辞書順で一致)。
-/

namespace Looper.Asl.Engine

open Looper.Core
open Looper.Core.Doc (RawFile pyInt?)
open Looper.Asl.Check

def schemaVersion : String := "1"

/-- 具現化プレースホルダ(`_lib.sh` / recipe.json と同じ綴り)。 -/
def unfilledMarker : String := "ASL-PARAMETER-UNFILLED"

def containsMarker (text : String) : Bool :=
  (text.splitOn unfilledMarker).length ≥ 2

/-! ## schema(instance パラメータ) -/

inductive SchemaLoad where
  | ok (schema : Json.Value)
  | unreadable (detail : String)
  | unfilled
  | invalid (detail : String)
  | notObject

/-- Python `load_schema` の分類部(読み → marker → パース → dict 検査)。
`path` は OSError 文言(`[Errno 2] ...`)の再現用。 -/
def classifySchema (path : String) : RawFile → SchemaLoad
  | .absent => .unreadable s!"[Errno 2] No such file or directory: '{path}'"
  | .ioError e => .unreadable e
  | .text t =>
    if containsMarker t then .unfilled
    else
      match Json.parse t with
      | .error e => .invalid e
      | .ok v => if v matches .obj _ then .ok v else .notObject

/-- strict ロード(ensure / raise-gate / start-run / record-progress /
resume / write-doc / append-log)の die 文言。 -/
def schemaLoadError : SchemaLoad → Option String
  | .ok _ => none
  | .unreadable e => some s!"schema.json unreadable: {e}"
  | .unfilled => some ("schema.json still carries the instantiation placeholder "
      ++ s!"({unfilledMarker}); fill the instance parameters first.")
  | .invalid e => some s!"schema.json is not valid JSON: {e}"
  | .notObject => some "schema.json top-level value must be an object."

structure Policy where
  stopAfterIdleCycles : Int := 3
  stopAfterFailedRuns : Int := 2
  maxSessionCycles : Int := 8
  deriving Repr, DecidableEq

/-- Python `isinstance(v, int) and v > 0`(bool は int の派生)。 -/
private def pyPositiveInt? : Json.Value → Option Int
  | .num m 0 => if m > 0 then some m else none
  | .bool true => some 1
  | _ => none

def schemaPolicy (schema : Json.Value) : Policy :=
  match schema.get? "policy" with
  | some declared =>
    if declared matches .obj _ then
      { stopAfterIdleCycles :=
          ((declared.get? "stop_after_idle_cycles").bind pyPositiveInt?).getD 3
        stopAfterFailedRuns :=
          ((declared.get? "stop_after_failed_runs").bind pyPositiveInt?).getD 2
        maxSessionCycles :=
          ((declared.get? "max_session_cycles").bind pyPositiveInt?).getD 8 }
    else {}
  | none => {}

def schemaDocuments (schema : Json.Value) : List (String × Json.Value) :=
  match schema.get? "documents" with
  | some (.obj entries) => entries
  | _ => []

def schemaLogs (schema : Json.Value) : List String :=
  let declared := match schema.get? "logs" with
    | some (.arr l) => l
    | _ => []
  declared.foldl (init := ["runs.jsonl"]) fun acc v =>
    match v with
    | .str name =>
      if name.endsWith ".jsonl" && !acc.contains name then acc ++ [name] else acc
    | _ => acc

/-- ensure が書く document の初期内容: `seed`(null 以外)か `{}`。 -/
def documentSeed (spec : Json.Value) : Json.Value :=
  match spec.get? "seed" with
  | some .null | none => .obj []
  | some seed => seed

/-! ## framework documents(control.json / runs.jsonl) -/

def initialControl (now : String) : Json.Value :=
  .obj [
    ("schema_version", .str schemaVersion),
    ("created_at", .str now),
    ("gates", .arr []),
    ("counters", .obj [
      ("cycles_total", .num 0 0),
      ("idle_streak", .num 0 0),
      ("failed_run_streak", .num 0 0)])]

/-- Python `load_control` + 診断: 読めない・パース不能は
`control.json unreadable: ...`、形状破れは固定文言。 -/
def readControl (path : String) : RawFile → Except String Json.Value
  | .absent =>
    .error s!"control.json unreadable: [Errno 2] No such file or directory: '{path}'"
  | .ioError e => .error s!"control.json unreadable: {e}"
  | .text t =>
    match Json.parse t with
    | .error e => .error s!"control.json unreadable: {e}"
    | .ok v =>
      let gatesOk := match v.get? "gates" with
        | some (.arr _) => true
        | _ => false
      if (v matches .obj _) && gatesOk then .ok v
      else .error "control.json has lost its expected shape"

def openGates (control : Json.Value) : List Json.Value :=
  match control.get? "gates" with
  | some (.arr gs) =>
    gs.filter fun g =>
      (g matches .obj _) && g.get? "status" == some (.str "open")
  | _ => []

private def pad3 (n : Nat) : String :=
  let s := toString n
  if s.length ≥ 3 then s else String.ofList (List.replicate (3 - s.length) '0') ++ s

def gateEntry (id reason detail raisedBy now : String) : Json.Value :=
  .obj [
    ("id", .str id), ("reason", .str reason), ("detail", .str detail),
    ("raised_by", .str raisedBy), ("raised_at", .str now),
    ("status", .str "open"), ("resolution", .null), ("resolved_at", .null)]

/-- Python `add_gate`: 同じ reason の open gate があれば何もしない。
gate id は全 gate 数 + 1 の `G-%03d`。 -/
def addGate (control : Json.Value) (reason detail raisedBy now : String) :
    Json.Value × Bool :=
  if (openGates control).any (fun g => g.get? "reason" == some (.str reason)) then
    (control, false)
  else
    let gates := match control.get? "gates" with
      | some (.arr gs) => gs
      | _ => []
    let gate := gateEntry s!"G-{pad3 (gates.length + 1)}" reason detail raisedBy now
    (control.set "gates" (.arr (gates ++ [gate])), true)

/-- Python `dangling_run_ids`: start された run_id のうち end されていない
truthy なもの(記録順)。 -/
def danglingRuns (records : List Json.Value) : List Json.Value :=
  let (started, ended) := records.foldl (init := (([] : List Json.Value), ([] : List Json.Value)))
    fun (acc : List Json.Value × List Json.Value) rec =>
      if !(rec matches .obj _) then acc
      else if rec.get? "event" == some (.str "start") then
        (acc.1 ++ [(rec.get? "run_id").getD .null], acc.2)
      else if rec.get? "event" == some (.str "end") then
        (acc.1, acc.2 ++ [(rec.get? "run_id").getD .null])
      else acc
  started.filter fun r => r.truthy && !ended.any (pyEq r)

/-! ## should-stop -/

private def insertSorted (x : String) : List String → List String
  | [] => [x]
  | y :: ys => if x ≤ y then x :: y :: ys else y :: insertSorted x ys

/-- Python `sorted(set(xs))`(コードポイント辞書順)。 -/
def sortedUnique (xs : List String) : List String :=
  xs.foldl (fun acc x => if acc.contains x then acc else insertSorted x acc) []

/-- Python `cmd_should_stop` のペイロード。非文字列の gate reason は Python
では `sorted` の TypeError(exit 1 = 「no」誤読)だが、fail-closed の
ハードエラーへ写す(モジュール頭注)。 -/
def shouldStopPayload (gates dangling : List Json.Value) :
    Except String Json.Value := do
  let reasonStrs ← gates.mapM fun g =>
    match (g.get? "reason").getD (.str "gate") with
    | .str s => Except.ok s
    | v => Except.error
        s!"control.json gate reason {pyRepr v} is not a string; refusing to evaluate stop gates."
  let reasons := sortedUnique reasonStrs
    ++ (if dangling.isEmpty then [] else ["dangling_run"])
  let gateMessages := gates.map fun g =>
    let r := pyStr ((g.get? "reason").getD .null)
    let d := pyStr ((g.get? "detail").getD .null)
    s!"{r}: {d}"
  let joined := String.intercalate "; " gateMessages
  let message :=
    if !joined.isEmpty then joined
    else if !dangling.isEmpty then "crashed run(s) need `resume --force`"
    else "no stop"
  pure (.obj [
    ("stop", .bool (!reasons.isEmpty)),
    ("reasons", .arr (reasons.map .str)),
    ("gates", .arr gates),
    ("dangling_runs", .arr dangling),
    ("message", .str message)])

/-! ## record-progress / resume -/

/-- counters の Python `int()` 読み(存在しないキーは 0)。int() 不能は
ハードエラー(モジュール頭注)。 -/
private def counterInt (counters : Json.Value) (key : String) : Except String Int :=
  match counters.get? key with
  | none => .ok 0
  | some v =>
    match pyInt? v with
    | some n => .ok n
    | none => .error s!"control.json counter {pyReprString key} cannot be read as an integer."

private def countersOf (control : Json.Value) : Except String Json.Value :=
  match control.get? "counters" with
  | none => .ok (.obj [])
  | some c =>
    if c matches .obj _ then .ok c
    else .error "control.json counters have lost their expected shape."

def idleGateDetail (idle : Int) : String :=
  s!"{idle} consecutive cycles produced no change outside the state directory; "
    ++ "the loop is spinning without progress and needs a human look."

def failedGateDetail (failed : Int) : String :=
  s!"{failed} consecutive agent runs exited nonzero; "
    ++ "the environment or the task needs a human look."

/-- Python `cmd_record_progress` の決定核: 更新後 control と stdout
ペイロード(`{"counters": ...}`)。 -/
def recordProgress (control : Json.Value) (policy : Policy)
    (changed runOk : Bool) (now : String) :
    Except String (Json.Value × Json.Value) := do
  let counters ← countersOf control
  let cycles := (← counterInt counters "cycles_total") + 1
  -- Python は `0 if changed else int(...) + 1` の遅延評価だが、読めない
  -- streak を changed=yes が黙って通すより停止側が正しい(I-021 と同型)
  let idle ← if changed then pure (0 : Int)
    else (counterInt counters "idle_streak").map (· + 1)
  let failed ← if runOk then pure (0 : Int)
    else (counterInt counters "failed_run_streak").map (· + 1)
  let counters := ((counters.set "cycles_total" (.num cycles 0)).set
    "idle_streak" (.num idle 0)).set "failed_run_streak" (.num failed 0)
  let control := control.set "counters" counters
  let control := if idle ≥ policy.stopAfterIdleCycles then
      (addGate control "idle_cycles" (idleGateDetail idle) "loop" now).1
    else control
  let control := if failed ≥ policy.stopAfterFailedRuns then
      (addGate control "failed_runs" (failedGateDetail failed) "loop" now).1
    else control
  pure (control, .obj [("counters", counters)])

/-- Python `cmd_resume` の gate 解放 + streak ゼロ化: 更新後 control と
解放 gate id 列。 -/
def resumeApply (control : Json.Value) (note now : String) :
    Except String (Json.Value × List Json.Value) := do
  let gates := match control.get? "gates" with
    | some (.arr gs) => gs
    | _ => []
  let step := fun (acc : List Json.Value × List Json.Value) (g : Json.Value) =>
    if (g matches .obj _) && g.get? "status" == some (.str "open") then
      let g' := ((g.set "status" (.str "resolved")).set
        "resolution" (.str note)).set "resolved_at" (.str now)
      (acc.1 ++ [g'], acc.2 ++ [(g.get? "id").getD .null])
    else (acc.1 ++ [g], acc.2)
  let (gates, released) := gates.foldl step ([], [])
  let control := control.set "gates" (.arr gates)
  let counters ← countersOf control
  let counters := (counters.set "idle_streak" (.num 0 0)).set
    "failed_run_streak" (.num 0 0)
  pure (control.set "counters" counters, released)

def resumePayload (released closed : List Json.Value) (note : String) : Json.Value :=
  .obj [("released_gates", .arr released), ("closed_runs", .arr closed),
        ("note", .str note)]

def runEndRecord (runId : Json.Value) (now status : String) : Json.Value :=
  .obj [("run_id", runId), ("event", .str "end"), ("at", .str now),
        ("status", .str status)]

def runStartRecord (runId now : String) : Json.Value :=
  .obj [("run_id", .str runId), ("event", .str "start"), ("at", .str now)]

def danglingStartRunError (dangling : List Json.Value) : String :=
  s!"dangling run(s) {pyRepr (.arr dangling)}: a previous cycle crashed; the "
    ++ "human recovers with `resume --force` before a new run starts."

def danglingResumeError (dangling : List Json.Value) : String :=
  s!"dangling run(s) {pyRepr (.arr dangling)} from a crashed cycle; re-run with "
    ++ "--force after reviewing the leftover diff."

/-! ## raise-gate -/

/-- Python `re.fullmatch(r"[a-z][a-z0-9_]*", reason)`。 -/
def isReasonSlug (reason : String) : Bool :=
  match reason.toList with
  | [] => false
  | c :: rest =>
    ('a' ≤ c && c ≤ 'z')
      && rest.all fun c => ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_'

/-! ## validate -/

structure ValidateInputs where
  /-- 入れ子深さの上限(schema.json テキスト長で十分)。 -/
  fuel : Nat
  schemaLoad : SchemaLoad
  /-- `prompts/cycle.md` の読み出し結果。 -/
  prompt : RawFile
  stateDirExists : Bool
  /-- `control.json`(`readControl` 済み)。state ディレクトリがある場合のみ意味を持つ。 -/
  control : Except String Json.Value
  /-- schema が宣言する documents の読み出し結果(schema 順)。 -/
  docs : List (String × Json.Value × RawFile)
  /-- schema が宣言する logs の読み出し結果(schema 順)。 -/
  logs : List (String × RawFile)
  /-- 既存 validation.json のパース結果(読めなければ `{}` 相当)。 -/
  previous : Json.Value
  now : String

structure ValidateOutcome where
  /-- stdout へ印字し、必要なら書き込む validation 値。 -/
  validation : Json.Value
  /-- validation.json の書き換えが必要か(inspection idempotency)。 -/
  write : Bool
  hasErrors : Bool

private def schemaErrors : SchemaLoad → List String
  | .ok _ => []
  | .unfilled => [s!"schema.json still carries {unfilledMarker}; the instance "
      ++ "parameters were never filled at instantiation."]
  | .unreadable _ => ["schema.json does not exist."]
  | .invalid _ | .notObject => ["schema.json is unreadable or not a JSON object."]

private def promptErrors : RawFile → List String
  | .absent | .ioError _ => ["prompts/cycle.md does not exist."]
  | .text t =>
    if containsMarker t then
      [s!"prompts/cycle.md still carries {unfilledMarker}; write the "
        ++ "domain instructions before running the loop."]
    else []

private def docErrors (fuel : Nat) (name : String) (spec : Json.Value) :
    RawFile → List String
  | .absent => [s!"missing canonical document: {name}"]
  | .ioError e => [s!"invalid JSON in {name}: {e}"]
  | .text t =>
    match Json.parse t with
    | .error e => [s!"invalid JSON in {name}: {e}"]
    | .ok payload =>
      match spec.get? "schema" with
      | some docSchema =>
        if docSchema matches .obj _ then checkValue fuel payload docSchema name
        else []
      | none => []

private def logErrors (name : String) : RawFile → List String
  | .absent => [s!"missing canonical log: {name}"]
  | .ioError e => [s!"invalid JSONL in {name}: {e}"]
  | .text t =>
    match Looper.Core.Doc.parseJsonl t with
    | .ok _ => []
    | .error e => [s!"invalid JSONL in {name}: {e}"]

/-- schema.json の `deny_patterns` / `deny_bash_patterns` の旧方言検出。 -/
def denyListWarnings (schema : Json.Value) (key : String) : List String :=
  match schema.get? key with
  | some (.arr items) =>
    ((List.range items.length).zip items).filterMap fun (i, v) =>
      match v with
      | .str p => if Glob.looksLegacy p then some (legacyMessage s!"{key}[{i}]" p) else none
      | _ => none
  | _ => []

/-- validate の warnings(§29.6 の旧方言検出、K-7 緩和): deny リスト 2 本 +
各 document schema の `pattern`。 -/
def legacyWarnings (fuel : Nat) (schema : Json.Value) : List String :=
  denyListWarnings schema "deny_patterns"
    ++ denyListWarnings schema "deny_bash_patterns"
    ++ (schemaDocuments schema).flatMap fun (name, spec) =>
      match spec.get? "schema" with
      | some docSchema => legacyPatternWarnings fuel docSchema s!"documents.{name}.schema"
      | none => []

/-- last_validated_at を除いた dict 等価(inspection idempotency)。 -/
private def semanticallyEqual (a b : Json.Value) : Bool :=
  match a, b with
  | .obj ea, .obj eb =>
    let strip := fun (l : List (String × Json.Value)) =>
      l.filter fun (k, _) => k != "last_validated_at"
    pyEq (.obj (strip ea)) (.obj (strip eb))
  | _, _ => false

def validateOutcome (inp : ValidateInputs) : ValidateOutcome :=
  let schema := match inp.schemaLoad with
    | .ok v => v
    | _ => .obj []
  let stateErrors :=
    if !inp.stateDirExists then
      ["state/ does not exist; run `asl-loop state ensure` first."]
    else
      (match inp.control with
        | .error diag => [s!"control.json missing or corrupt ({diag}); restore it "
            ++ "from the last checkpoint (git restore) — never rebuild it from defaults."]
        | .ok _ => [])
      ++ inp.docs.flatMap (fun (name, spec, raw) => docErrors inp.fuel name spec raw)
      ++ inp.logs.flatMap (fun (name, raw) => logErrors name raw)
  let errors := schemaErrors inp.schemaLoad ++ promptErrors inp.prompt ++ stateErrors
  let warnings := legacyWarnings inp.fuel schema
  let status := if !errors.isEmpty then "error"
    else if !warnings.isEmpty then "warning" else "ok"
  let validation : Json.Value := .obj [
    ("schema_version", .str schemaVersion),
    ("last_validated_at", .str inp.now),
    ("status", .str status),
    ("errors", .arr (errors.map .str)),
    ("warnings", .arr (warnings.map .str))]
  let keepPrevious := (inp.previous matches .obj _)
    && semanticallyEqual inp.previous validation
  { validation := if keepPrevious then inp.previous else validation
    write := inp.stateDirExists && !keepPrevious
    hasErrors := !errors.isEmpty }

/-! ## write-doc / append-log -/

def unknownDocumentError (name : String) (docs : List (String × Json.Value)) : String :=
  let names := String.intercalate ", " (sortedUnique (docs.map (·.1)))
  s!"unknown document {pyReprString name}; write-doc writes only documents "
    ++ s!"declared in schema.json ({if names.isEmpty then "none" else names})."

def unknownLogError (name : String) : String :=
  s!"unknown or loop-owned log {pyReprString name}; append-log appends to logs "
    ++ "declared in schema.json (runs.jsonl is loop-owned)."

/-- Python `record.setdefault("at", now_local())`。 -/
def withDefaultAt (record : Json.Value) (now : String) : Json.Value :=
  match record.get? "at" with
  | some _ => record
  | none => record.set "at" (.str now)

/-! ## status -/

private def pyLen : Json.Value → Nat
  | .arr items => items.length
  | .obj entries => entries.length
  | .str s => s.length
  | _ => 0

private def counterText (counters : Json.Value) (key : String) : String :=
  match counters.get? key with
  | some v => pyStr v
  | none => "?"

structure StatusInputs where
  loopName : String
  targetRoot : String
  control : Except String Json.Value
  schema : Json.Value
  validation : Json.Value

def statusLines (inp : StatusInputs) : List String :=
  let control := match inp.control with
    | .ok c => c
    | .error _ => .obj []
  let counters := match control.get? "counters" with
    | some c => if c matches .obj _ then c else .obj []
    | none => .obj []
  let gates := match inp.control with
    | .ok c => openGates c
    | .error _ => []
  let validationStatus := pyStr ((inp.validation.get? "status").getD (.str "never ran"))
  let errorsSuffix := match inp.validation.get? "errors" with
    | some errs => if errs.truthy then s!" ({pyLen errs} errors)" else ""
    | none => ""
  let documents := String.intercalate ", " ((schemaDocuments inp.schema).map (·.1))
  let cyclesText := counterText counters "cycles_total"
  let idleText := counterText counters "idle_streak"
  let failedText := counterText counters "failed_run_streak"
  let documentsText := if documents.isEmpty then "(none declared)" else documents
  let head := [
    s!"instance   : {inp.loopName} (agentic-state-loop) at {inp.targetRoot}",
    s!"cycles     : {cyclesText} total, idle streak {idleText}, failed-run streak {failedText}",
    s!"validation : {validationStatus}{errorsSuffix}",
    s!"documents  : {documentsText}"]
  let problem := match inp.control with
    | .error diag => [s!"PROBLEM    : {diag}"]
    | .ok _ => []
  let gateLines :=
    if gates.isEmpty then ["open gates : none"]
    else ["open gates :"]
      ++ gates.map (fun g =>
        let id := pyStr ((g.get? "id").getD .null)
        let r := pyStr ((g.get? "reason").getD .null)
        let d := pyStr ((g.get? "detail").getD .null)
        s!"  - [{id}] {r}: {d}")
      ++ ["next       : review, then `bash <loop>/scripts/resume.sh --note \"...\"`"]
  head ++ problem ++ gateLines

/-! ## コンパイル時テスト -/

/-- テスト専用: `Except` の構造等価(`#guard` 用)。 -/
private instance {ε α : Type} [BEq ε] [BEq α] : BEq (Except ε α) :=
  ⟨fun a b =>
    match a, b with
    | .ok x, .ok y => x == y
    | .error e, .error f => e == f
    | _, _ => false⟩

-- schema 分類
#guard (match classifySchema "p" (.text "{\"a\": 1}") with
  | .ok _ => true | _ => false)
#guard (match classifySchema "p" (.text "not json") with
  | .invalid _ => true | _ => false)
#guard (match classifySchema "p" (.text "[1]") with
  | .notObject => true | _ => false)
#guard (match classifySchema "p" (.text "{\"x\": \"ASL-PARAMETER-UNFILLED\"}") with
  | .unfilled => true | _ => false)
#guard schemaLoadError (classifySchema "/x/schema.json" .absent)
  == some "schema.json unreadable: [Errno 2] No such file or directory: '/x/schema.json'"

-- policy(bool は Python では int、正のみ採用)
#guard schemaPolicy (.obj [("policy", .obj [("stop_after_idle_cycles", .num 5 0)])])
  == { stopAfterIdleCycles := 5 }
#guard schemaPolicy (.obj [("policy", .obj [("stop_after_idle_cycles", .num 0 0)])]) == {}
#guard schemaPolicy (.obj [("policy", .obj [("stop_after_idle_cycles", .num 50 1)])]) == {}
#guard schemaPolicy (.obj [("policy", .obj [("stop_after_idle_cycles", .bool true)])])
  == { stopAfterIdleCycles := 1 }
#guard schemaPolicy (.obj [("policy", .arr [])]) == {}

-- logs(runs.jsonl 先頭、.jsonl のみ、重複除去)
#guard schemaLogs (.obj [("logs", .arr [.str "a.jsonl", .str "runs.jsonl", .str "b.txt"])])
  == ["runs.jsonl", "a.jsonl"]
#guard schemaLogs (.obj []) == ["runs.jsonl"]

-- documentSeed(seed: null と欠落は {}、それ以外は seed)
#guard documentSeed (.obj [("seed", .arr [.num 1 0])]) == .arr [.num 1 0]
#guard documentSeed (.obj [("seed", .null)]) == .obj []
#guard documentSeed (.obj []) == .obj []

-- control 形状
#guard (match readControl "p" (.text "{\"gates\": []}") with
  | .ok _ => true | _ => false)
#guard readControl "p" (.text "{\"gates\": {}}")
  == .error "control.json has lost its expected shape"
#guard readControl "p" (.text "[1]")
  == .error "control.json has lost its expected shape"

-- addGate(open 重複は無視、id は全 gate 数 + 1)
#guard (addGate (initialControl "T") "r" "d" "agent" "T").2
#guard !(addGate (addGate (initialControl "T") "r" "d" "agent" "T").1 "r" "d2" "agent" "T").2
#guard ((addGate (initialControl "T") "r" "d" "agent" "T").1.get? "gates"
  |>.map fun | .arr gs => gs.length | _ => 0) == some 1
#guard (((addGate (initialControl "T") "r" "d" "agent" "T").1.getPath? ["gates"]).map
  fun | .arr (g :: _) => g.get? "id" == some (.str "G-001") | _ => false) == some true

-- danglingRuns
#guard danglingRuns [
    .obj [("event", .str "start"), ("run_id", .str "R-1")],
    .obj [("event", .str "end"), ("run_id", .str "R-1")],
    .obj [("event", .str "start"), ("run_id", .str "R-2")]]
  == [.str "R-2"]
#guard danglingRuns [.obj [("event", .str "start"), ("run_id", .str "")]] == []
#guard danglingRuns [.obj [("event", .str "start")]] == []

-- shouldStopPayload(reasons は sorted(set) + dangling_run 末尾)
#guard (shouldStopPayload [] [] |>.map fun p => p.get? "stop") == .ok (some (.bool false))
#guard (shouldStopPayload [] [] |>.map fun p => p.get? "message")
  == .ok (some (.str "no stop"))
#guard (shouldStopPayload [] [.str "R-1"] |>.map fun p => p.get? "message")
  == .ok (some (.str "crashed run(s) need `resume --force`"))
#guard (shouldStopPayload
    [.obj [("reason", .str "b"), ("detail", .str "D")],
     .obj [("reason", .str "a"), ("detail", .str "E")],
     .obj [("reason", .str "b"), ("detail", .str "F")]] [.str "R-1"]
  |>.map fun p => p.get? "reasons")
  == .ok (some (.arr [.str "a", .str "b", .str "dangling_run"]))
#guard (shouldStopPayload [.obj [("reason", .str "a"), ("detail", .str "D")]] []
  |>.map fun p => p.get? "message") == .ok (some (.str "a: D"))
#guard (shouldStopPayload [.obj [("reason", .num 1 0)]] [] matches .error _)

-- recordProgress(streak 更新と gate 具現化)
#guard (recordProgress (initialControl "T") {} true true "T"
  |>.map fun (_, payload) => payload.getPath? ["counters", "cycles_total"])
  == .ok (some (.num 1 0))
#guard (recordProgress (initialControl "T") { stopAfterIdleCycles := 1 } false true "T"
  |>.map fun (control, _) => (openGates control).length) == .ok 1
#guard (recordProgress (initialControl "T") { stopAfterFailedRuns := 1 } true false "T"
  |>.map fun (control, _) =>
    (openGates control).map (fun g => g.get? "reason") == [some (.str "failed_runs")])
  == .ok true
#guard (recordProgress (.obj [("gates", .arr []),
    ("counters", .obj [("idle_streak", .str "x")])]) {} false true "T" matches .error _)

-- resumeApply(open のみ解放、streak ゼロ化)
#guard (resumeApply (addGate (initialControl "T") "r" "d" "agent" "T").1 "note" "T2"
  |>.map fun (_, released) => released) == .ok [.str "G-001"]
#guard (resumeApply (addGate (initialControl "T") "r" "d" "agent" "T").1 "note" "T2"
  |>.map fun (control, _) => (openGates control).isEmpty) == .ok true
#guard (resumeApply (initialControl "T") "note" "T2"
  |>.map fun (_, released) => released.isEmpty) == .ok true

-- raise-gate slug
#guard isReasonSlug "human_input_required"
#guard !isReasonSlug "Human"
#guard !isReasonSlug ""
#guard !isReasonSlug "a-b"

-- validate: 主要経路
#guard (validateOutcome {
    fuel := 99
    schemaLoad := classifySchema "p" (.text "{}")
    prompt := .text "domain"
    stateDirExists := true
    control := readControl "p" (.text "{\"gates\": []}")
    docs := [], logs := [("runs.jsonl", .text "")]
    previous := .obj [], now := "T" }).hasErrors == false
#guard (validateOutcome {
    fuel := 99
    schemaLoad := classifySchema "p" .absent
    prompt := .absent
    stateDirExists := false
    control := .error "x"
    docs := [], logs := []
    previous := .obj [], now := "T" }).validation.get? "errors"
  == some (.arr [.str "schema.json does not exist.",
                 .str "prompts/cycle.md does not exist.",
                 .str "state/ does not exist; run `asl-loop state ensure` first."])
-- inspection idempotency: 意味的に同じなら previous を保持し write しない
#guard (
  let inputs : ValidateInputs := {
    fuel := 99
    schemaLoad := classifySchema "p" (.text "{}")
    prompt := .text "domain"
    stateDirExists := true
    control := readControl "p" (.text "{\"gates\": []}")
    docs := [], logs := [("runs.jsonl", .text "")]
    previous := .obj [], now := "T1" }
  let first := (validateOutcome inputs).validation
  let second := validateOutcome { inputs with previous := first, now := "T2" }
  second.validation == first && second.write == false)
-- 旧方言 deny パターンは warning(status = "warning")
#guard (validateOutcome {
    fuel := 99
    schemaLoad := classifySchema "p" (.text "{\"deny_patterns\": [\"(^|/)legacy/\"]}")
    prompt := .text "domain"
    stateDirExists := true
    control := readControl "p" (.text "{\"gates\": []}")
    docs := [], logs := [("runs.jsonl", .text "")]
    previous := .obj [], now := "T" }).validation.get? "status"
  == some (.str "warning")

-- write-doc / append-log の文言部品
#guard unknownDocumentError "x" [("b", .obj []), ("a", .obj [])]
  == "unknown document 'x'; write-doc writes only documents declared in schema.json (a, b)."
#guard unknownDocumentError "x" []
  == "unknown document 'x'; write-doc writes only documents declared in schema.json (none)."
#guard withDefaultAt (.obj [("k", .num 1 0)]) "T"
  == .obj [("k", .num 1 0), ("at", .str "T")]
#guard withDefaultAt (.obj [("at", .str "X")]) "T" == .obj [("at", .str "X")]

-- status 行
#guard statusLines {
    loopName := ".loop", targetRoot := "/t"
    control := .ok (initialControl "T")
    schema := .obj [("documents", .obj [("todo.json", .obj [])])]
    validation := .obj [("status", .str "ok")] }
  == ["instance   : .loop (agentic-state-loop) at /t",
      "cycles     : 0 total, idle streak 0, failed-run streak 0",
      "validation : ok",
      "documents  : todo.json",
      "open gates : none"]
#guard statusLines {
    loopName := ".loop", targetRoot := "/t"
    control := .error "control.json unreadable: x"
    schema := .obj []
    validation := .obj [("status", .str "error"),
      ("errors", .arr [.str "e1", .str "e2"])] }
  == ["instance   : .loop (agentic-state-loop) at /t",
      "cycles     : ? total, idle streak ?, failed-run streak ?",
      "validation : error (2 errors)",
      "documents  : (none declared)",
      "PROBLEM    : control.json unreadable: x",
      "open gates : none"]

end Looper.Asl.Engine
