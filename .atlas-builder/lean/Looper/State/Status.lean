import Looper.Core.Json
import Looper.Core.Doc
import Looper.Core.Essence
import Looper.State.Model
import Looper.State.Predicates

/-!
`Looper.State.Status` — state.py `cmd_status`(L3077–3156)の純粋核
。

status は人間向けサマリであり、常に exit 0(診断は表示に落とすだけで決して
致命化しない — test_state_status.py の SU 節)。ただし Python が未捕捉例外で
落ちる入力(unhashable / unorderable な todo status、runs.jsonl 最終レコードの
非 object、iterate 不能な spec items、不正 UTF-8 の ESSENCE.md)は exit 2 の
ハードエラーであり、しかも print 済みの行は stdout に残る。この「部分出力 +
ハードエラー」を写すため、`statusRender` は `List String × Option String`
(出力済み行 + 発生したハードエラー)を返す。

Python の表示変換の互換面:
- f-string 補間 = `str()`(`pyStr`): None→`None`、bool→`True`/`False`、
  list/dict→`repr` 埋め込み。
- `repr(str)`(`pyReprStr`)のクォート選択(`'` 優先、`'` を含み `"` を
  含まなければ `"`)とエスケープ。非印字判定は Python `str.isprintable` の
  実用部分集合(C0/C1 制御・DEL・NBSP・SHY を `\xXX` へ)で近似する
  (§31.2-22 裁定 — 表示専用で canonical 状態には現れない)。
- `sorted(by_status.items())`: 要素 1 個は比較が起きず任意型を受理、複数は
  全 str(辞書順)か全数値(bool 含む)のみ。混在は TypeError = ハードエラー。
- float の `str()` は Python `repr` の最短表現を再現しない(LEAN_MIGRATION_PLAN.md §4.4 —
  現行出力に float は現れない。出現時は裁定キュー)。
-/

namespace Looper.State.Status

open Looper.Core
open Looper.Core.Prim (hex2)
open Looper.Core.Doc
open Looper.State.Model

/-! ## Python 表示変換(`str()` / `repr()`) -/

/-- Python repr の非印字近似: C0 制御・DEL(0x7F)・C1 制御(〜0x9F)・
NBSP(0xA0)・SHY(0xAD)。0x100 以上の非印字文字は生のまま(近似の許容差)。 -/
private def isReprEscaped (c : Char) : Bool :=
  c.toNat < 0x20 || (0x7F ≤ c.toNat && c.toNat ≤ 0xA0) || c.toNat == 0xAD

private def escapeReprChar (quote : Char) (c : Char) : String :=
  if c == '\\' then "\\\\"
  else if c == quote then "\\" ++ String.singleton quote
  else if c == '\n' then "\\n"
  else if c == '\r' then "\\r"
  else if c == '\t' then "\\t"
  else if isReprEscaped c then "\\x" ++ hex2 c.toNat
  else String.singleton c

/-- Python `repr(str)`: `'` を含み `"` を含まない文字列だけ `"` で囲み、
それ以外は `'` で囲む(囲み文字のみエスケープ)。 -/
def pyReprStr (s : String) : String :=
  let hasSingle := s.toList.contains '\''
  let hasDouble := s.toList.contains '"'
  let quote : Char := if hasSingle && !hasDouble then '"' else '\''
  String.singleton quote
    ++ s.foldl (fun acc c => acc ++ escapeReprChar quote c) ""
    ++ String.singleton quote

mutual
  /-- Python `repr()` の JSON 値版。数値は `Value.render` と同じ 10 進表現
  (int は一致。float の最短 repr は非再現 — LEAN_MIGRATION_PLAN.md §4.4)。 -/
  def pyRepr : Json.Value → String
    | .null => "None"
    | .bool true => "True"
    | .bool false => "False"
    | .num m e => (Json.Value.num m e).render
    | .str s => pyReprStr s
    | .arr items => "[" ++ pyReprItems items ++ "]"
    | .obj entries => "{" ++ pyReprEntries entries ++ "}"

  private def pyReprItems : List Json.Value → String
    | [] => ""
    | [v] => pyRepr v
    | v :: rest => pyRepr v ++ ", " ++ pyReprItems rest

  private def pyReprEntries : List (String × Json.Value) → String
    | [] => ""
    | [(k, v)] => pyReprStr k ++ ": " ++ pyRepr v
    | (k, v) :: rest => pyReprStr k ++ ": " ++ pyRepr v ++ ", " ++ pyReprEntries rest
end

/-- Python `str()` = f-string 補間。str は生のまま、コンテナは repr。 -/
def pyStr : Json.Value → String
  | .str s => s
  | v => pyRepr v

/-- Python `x or ""` を通した f-string 断片(falsy は空文字列)。 -/
private def orEmpty (v : Json.Value) : String :=
  if v.truthy then pyStr v else ""

/-! ## by_status(`t.get("status", "unknown")` の度数分布) -/

private def bumpCount (key : Json.Value) : List (Json.Value × Nat) →
    List (Json.Value × Nat)
  | [] => [(key, 1)]
  | (k, n) :: rest =>
    if k == key then (k, n + 1) :: rest else (k, n) :: bumpCount key rest

/-- Python の `by_status[status] = by_status.get(status, 0) + 1`(挿入順保持)。
list / dict の status は dict キーになれない(TypeError = ハードエラー)。
数値横断等値(`1 == 1.0 == True` が同一キーへ合流する Python dict の規則)は
非再現 — canonical todo の status は文字列で、混在した時点で後段の sorted が
どのみち TypeError になる。 -/
def countByStatus (items : List Json.Value) :
    Except String (List (Json.Value × Nat)) :=
  items.foldlM (init := []) fun acc t =>
    match (t.get? "status").getD (.str "unknown") with
    | .arr _ => .error "unhashable type: 'list'"
    | .obj _ => .error "unhashable type: 'dict'"
    | key => .ok (bumpCount key acc)

private def insertLe (le : α → α → Bool) (x : α) : List α → List α
  | [] => [x]
  | y :: ys => if le x y then x :: y :: ys else y :: insertLe le x ys

private def sortLe (le : α → α → Bool) : List α → List α
  | [] => []
  | x :: xs => insertLe le x (sortLe le xs)

private def numKey? : Json.Value → Option (Int × Nat)
  | .num m e => some (m, e)
  | .bool b => some (if b then 1 else 0, 0)
  | _ => none

/-- Python `', '.join(f"{k}={v}" for k, v in sorted(by_status.items()))`。
sorted は要素 1 個なら比較せず任意型を受理する(CPython の実挙動)。複数は
全 str の辞書順(コードポイント順 = Lean `String` 比較)か全数値(bool 含む)
のみ定義され、混在は TypeError = ハードエラー。 -/
def statusSummary (pairs : List (Json.Value × Nat)) : Except String String :=
  let fmt (p : Json.Value × Nat) : String := s!"{pyStr p.1}={p.2}"
  match pairs with
  | [] => .ok ""
  | [p] => .ok (fmt p)
  | pairs =>
    if pairs.all (fun p => match p.1 with | .str _ => true | _ => false) then
      let le (a b : Json.Value × Nat) : Bool :=
        match a.1, b.1 with
        | .str s1, .str s2 => s1 ≤ s2
        | _, _ => true
      .ok (String.intercalate ", " ((sortLe le pairs).map fmt))
    else
      match pairs.mapM (fun p => (numKey? p.1).map fun k => (k, p)) with
      | some keyed =>
        let le (a b : (Int × Nat) × (Json.Value × Nat)) : Bool :=
          numGE b.1.1 b.1.2 a.1.1 a.1.2
        .ok (String.intercalate ", " ((sortLe le keyed).map fun kp => fmt kp.2))
      | none => .error "'<' not supported between mixed todo status key types"

/-! ## acceptance_evidence_map(state.py L471–515、§20.2-6 / §22) -/

structure AcceptanceEntry where
  condition : String
  mapped : Bool
  todos : List Json.Value
  deriving BEq

private def putLast (k v : Json.Value) : List (Json.Value × Json.Value) →
    List (Json.Value × Json.Value)
  | [] => [(k, v)]
  | (k', v') :: rest =>
    if k' == k then (k, v) :: rest else (k', v') :: putLast k v rest

private def lookupBEq (k : Json.Value) : List (Json.Value × Json.Value) →
    Option Json.Value
  | [] => none
  | (k', v) :: rest => if k' == k then some v else lookupBEq k rest

/-- Python `acceptance_evidence_map(conditions, todo_items, spec_items)` 等価:
done かつ must で command evidence を持つ Todo の検索テキスト(command +
summary・title・参照 Spec の str 値)に対する `_texts_relate` の当たりを、
成功条件の順に列挙する。`spec_items` は生の JSON 値(Python の
`d["spec.json"].get("items", [])`)— list 以外の iterate 可能形(dict / str)は
dict 項目ゼロと同値、None / 数値 / bool は TypeError = ハードエラー。
spec id の照合は構造等値で、Python の数値横断等値は非再現(id は文字列)。 -/
def acceptanceEvidenceMap (conditions : List String)
    (todoItems : List Json.Value) (specItems : Json.Value) :
    Except String (List AcceptanceEntry) := do
  let specList : List Json.Value ←
    match specItems with
    | .arr items => .ok items
    | .obj _ | .str _ => .ok []
    | .null => .error "'NoneType' object is not iterable"
    | _ => .error "spec items value is not iterable"
  let specById := specList.foldl (init := ([] : List (Json.Value × Json.Value)))
    fun acc s =>
      match s with
      | .obj _ =>
        let id := (s.get? "id").getD .null
        if id.truthy then putLast id s acc else acc
      | _ => acc
  let candidates := todoItems.filterMap fun t =>
    if t.get? "priority" != some (.str "must")
        || t.get? "status" != some (.str "done") then
      none
    else
      let evidence := match t.get? "evidence" with
        | some (.arr l) => l
        | _ => []
      let cmdTexts := evidence.filterMap fun ev =>
        match ev with
        | .obj _ =>
          if ev.get? "type" == some (.str "command") then
            some (orEmpty ((ev.get? "command").getD .null) ++ " "
              ++ orEmpty ((ev.get? "summary").getD .null))
          else none
        | _ => none
      -- §22: acceptance check は command evidence — diff だけの Todo は
      -- 成功条件の検証を主張できない。
      if cmdTexts.isEmpty then none
      else
        let titleText := orEmpty ((t.get? "title").getD .null)
        let specIds := match t.get? "spec" with
          | some (.arr l) => l
          | _ => []
        let specTexts := specIds.filterMap fun sid =>
          match lookupBEq sid specById with
          | some (.obj entries) =>
            some (String.intercalate " " (entries.filterMap fun (k, v) =>
              match v with
              | .str s => if k == "id" then none else some s
              | _ => none))
          | _ => none
        some ((t.get? "id").getD .null,
          String.intercalate " " (cmdTexts ++ [titleText] ++ specTexts))
  pure <| conditions.map fun cond =>
    let hits := (candidates.filter fun c => Essence.textsRelate cond c.2).map (·.1)
    { condition := cond, mapped := !hits.isEmpty, todos := hits }

/-- Python `essence_success_conditions`: OSError(不在・読取失敗)は []、
不正 UTF-8 は uncaught UnicodeDecodeError = ハードエラー。 -/
def successConditions : EssenceRead → Except String (List String)
  | .absent => .ok []
  | .ioError _ => .ok []
  | .file bytes =>
    match String.fromUTF8? bytes with
    | some text => .ok (Essence.essenceSuccessItems text)
    | none => .error "ESSENCE.md is not valid UTF-8"

/-! ## statusRender(cmd_status の本体) -/

/-- status の入力。gate 保持面は `stop` に一本化してあり、status が独自に
`Predicates.StopInputs` を組み立てることはない(I-017)。

かつては gate 保持面を平坦に持ち、`statusRender` の側で `StopInputs` を
組み直していた。その組み直しが `essencesDir` を落としたため、`just status`
の Gate 行だけが essences/ を不在として評価し、`state should-stop` と食い違う
表示(全資産 removed・全言及 dangling)を出した。同じ 1 個の観測を両方が
使う形にすれば、フィールドが増えても表示と述語は構造的に一致する。 -/
structure StatusInputs where
  /-- `str(ctx.project_root)`(解決済み)。 -/
  projectRoot : String
  stateIndex : RawFile
  validation : RawFile
  /-- gate 評価の入力そのもの。`ctx.title`(`projectTitle`)、
  `ctx.state_dir.is_dir()`(`stateInitialized`)、canonical state、
  ESSENCE.md、essences/ はすべてここから読む。 -/
  stop : Predicates.StopInputs
  /-- §20.5-3 の鮮度マーカー(`PROJECT_STATE_ROOT/tmp/validation_check.json`)。
  不在は「validate がまだ走っていない」= `never`。 -/
  validationCheck : RawFile := .absent

private def readDiag (name : String) (raw : RawFile) : Json.Value × List String :=
  let (v, d) := readJsonOrEmpty name raw
  (v, d.toList)

private def payloadField (p : Json.Value) (key : String) : String :=
  pyStr ((p.get? key).getD .null)

/-- `cmd_status` 等価の表示行生成。返り値は(print 済みの行, ハードエラー):
Python は f-string 評価中の未捕捉例外でもそこまでの print が stdout に
残ったまま exit 2 するので、行リストは常に「エラー発生時点までの出力」。 -/
def statusRender (i : StatusInputs) : List String × Option String := Id.run do
  -- gate 保持面の唯一の観測。表示も述語もここからしか読まない。
  let g := i.stop
  -- load_all(CANONICAL_JSON の読み順 = 診断の蓄積順)
  let (_, d1) := readDiag "state_index.json" i.stateIndex
  let (_, d2) := readDiag "project.json" g.project
  let (specJson, d3) := readDiag "spec.json" g.spec
  let (todoJson, d4) := readDiag "todo.json" g.todo
  let (_, d5) := readDiag "recommendations.json" g.recommendations
  let (blockersJson, d6) := readDiag "blockers.json" g.blockers
  let (contextJson, d7) := readDiag "context.json" g.context
  let (validationJson, d8) := readDiag "validation.json" i.validation
  let mut diagnostics := d1 ++ d2 ++ d3 ++ d4 ++ d5 ++ d6 ++ d7 ++ d8
  let todoItems := objectItems ((todoJson.get? "items").getD (.arr []))
  -- by_status は最初の print より前に構築される(unhashable はここで出力ゼロの
  -- ハードエラー)
  let byStatus ← match countByStatus todoItems with
    | .error e => return ([], some e)
    | .ok m => pure m
  let blockers := (objectItems ((blockersJson.get? "items").getD (.arr []))).filter
    (·.get? "status" == some (.str "active"))
  let specCount := (objectItems ((specJson.get? "items").getD (.arr []))).length
  let mut lines : List String := [
    s!"Project      : {g.projectTitle}",
    s!"PROJECT_ROOT : {i.projectRoot}",
    s!"Spec items   : {specCount}"
  ]
  -- sorted(by_status.items()) は Todos 行の f-string 内で評価される
  -- (unorderable は 3 行出力後のハードエラー)
  let summary ← match statusSummary byStatus with
    | .error e => return (lines, some e)
    | .ok s => pure s
  lines := lines
    ++ [s!"Todos        : {todoItems.length} ({if summary.isEmpty then "none" else summary})"]
  let activeBatch := (todoJson.get? "active_batch").getD (.arr [])
  let batchStr := if activeBatch.truthy then pyStr activeBatch else "none"
  let vStatus := pyStr ((validationJson.get? "status").getD (.str "unknown"))
  let vLast := payloadField validationJson "last_validated_at"
  -- §20.5-3: 2 つの時刻は意味が違う。`last_validated_at` は「診断が最後に
  -- **変わった**時刻」(§20.5-1 の温存判定の定義)、`last_checked_at` は
  -- 「validate が最後に**走った**時刻」。前者だけを裸で出していたため
  -- 「検証が古い」と読まれていた(実走行 2026-08-12)。両方をそれぞれの
  -- 意味を明示した形で出す。
  let vChecked :=
    let (stamp, _) := readJsonOrEmpty "validation_check.json" i.validationCheck
    match stamp.get? "last_checked_at" with
    | some (.str s) => if s.isEmpty then "never" else s
    | _ => "never"
  lines := lines ++ [
    s!"Active batch : {batchStr}",
    s!"Blockers     : {blockers.length}",
    s!"Validation   : {vStatus} (checked {vChecked}; diagnostics unchanged since {vLast})"
  ]
  let (runRecords, dRuns) := readJsonlOrEmpty "runs.jsonl" g.runs
  diagnostics := diagnostics ++ dRuns.toList
  -- runs[-1].get(...): 最終レコードが object でないのは AttributeError
  let runsSuffix ← match runRecords.getLast? with
    | none => pure ""
    | some last =>
      match last with
      | .obj _ =>
        pure (" (last: " ++ payloadField last "run_id" ++ " "
          ++ payloadField last "event" ++ ")")
      | _ => return (lines, some "last runs.jsonl record has no attribute 'get'")
  lines := lines ++ [s!"Runs logged  : {runRecords.length}{runsSuffix}"]
  -- §13.4 / I-017: gate 評価はここで読めなければならない — この出力
  -- (`just status`)と loop の exit message が latched stop の人間向け面。
  let gate ← match Predicates.shouldStopPayload g with
    | .error e => return (lines, some e)
    | .ok v => pure v
  let completion ← match Predicates.completionPayload
      { domain := g.domain, todo := g.todo, spec := g.spec, context := g.context,
        essence := g.essence, ledgers := g.ledgers,
        observations := g.observations } with
    | .error e => return (lines, some e)
    | .ok v => pure v
  lines := lines ++ [
    s!"Phase        : {payloadField completion.payload "phase"}",
    s!"Must todos   : {payloadField completion.payload "must_done"}/{payloadField completion.payload "must_total"} done",
    s!"Idle cycles  : {payloadField gate.payload "idle_cycles_since_progress"}/{payloadField gate.payload "stop_after_idle_cycles"}",
    -- §13.1-12/12': 「起動できなかった」を「停滞した」と読み違えさせない。
    -- 実走行 2026-08-12 では、上限到達の連続起動失敗が idle として提示され、
    -- 人間が runs.jsonl の実行時間を目視するまで原因が分からなかった。
    s!"Run failures : infra {payloadField gate.payload "infra_fails_since_ok"}/{payloadField gate.payload "stop_after_infra_fails"}, usage-limit {payloadField gate.payload "usage_limited_since_ok"}/{payloadField gate.payload "stop_after_usage_limited"}"
  ]
  if gate.stop then
    let reasons := match gate.payload.get? "reasons" with
      | some (.arr l) => l.filterMap (·.asStr?)
      | _ => []
    let message := ((gate.payload.get? "message").bind (·.asStr?)).getD ""
    lines := lines ++ [
      s!"Gate         : STOP ({String.intercalate ", " reasons})",
      s!"  - {message}"
    ]
  -- ここに「must 境界 = awaiting phase approval」の専用分岐は置かない。
  -- S-T3(§31.3)が `mustPhaseComplete ∧ phase = must ⇒ 停止` を証明しており、
  -- `completion.awaitingPhaseApproval` が真なら上の STOP 分岐が必ず先に立つ —
  -- つまりそのような分岐は**到達不能**である。実際、二択(`--approve-should` /
  -- `--close-at-must`)の案内をそこに置いていたため、§13.4-2 が要求する案内が
  -- 人間に一度も届いていなかった。案内は should-stop の message(表示と述語の
  -- 単一導出点)が持つ — §13.4-2 の「status は should-stop の別実装であっては
  -- ならない」を、コマンド形の案内にも適用する。
  else if completion.complete then
    lines := lines ++ [s!"Gate         : COMPLETE (full_complete, "
      ++ s!"{payloadField completion.payload "completion_scope"} scope, §19.3)"]
  else
    lines := lines ++ ["Gate         : none (runnable)"]
  -- §19.3: resume note 未消費ガード — gate release resume の note を消費する
  -- cycle が走るまで COMPLETE は成立しない(pending の間だけ表示する)
  if completion.payload.get? "resume_pending_cycle" == some (.bool true) then
    lines := lines ++ ["Resume note  : unconsumed — the next cycle consumes the "
      ++ "gate-release resume note before COMPLETE can latch (§19.3)"]
  -- §22 / §20.2-6: 成功条件 ↔ evidence の per-condition 対応(ヒューリスティック。
  -- ✗ は「人間が手で確認せよ」であって「作業が誤り」ではない)
  let conditions ← match successConditions g.essence with
    | .error e => return (lines, some e)
    | .ok cs => pure cs
  if !conditions.isEmpty then
    let mapping ← match acceptanceEvidenceMap conditions todoItems
        ((specJson.get? "items").getD (.arr [])) with
      | .error e => return (lines, some e)
      | .ok m => pure m
    let mappedCount := (mapping.filter (·.mapped)).length
    lines := lines ++ [s!"成功条件      : {mappedCount}/{mapping.length} mapped to "
      ++ "acceptance-check command evidence on done must Todos "
      ++ "(§22 heuristic aid)"]
    let mut idx := 1
    for entry in mapping do
      let mark := if entry.mapped then "✓" else "✗"
      let via := if entry.todos.isEmpty then ""
        else "  [" ++ String.intercalate ", " (entry.todos.map pyStr) ++ "]"
      lines := lines ++ [s!"  {mark} {idx}. {Text.normalizeWs entry.condition}{via}"]
      idx := idx + 1
  -- ドメイン固有の表示行(§15.1)。**位置は成功条件ブロックの直後・診断行の
  -- 前で固定**であり、返り値の順序がそのまま表示順である。入力は gate と同じ
  -- 1 個の観測から組み立てる(I-017 — status が canonical state を読み直さない)。
  lines := lines ++ g.domain.statusLines {
    ledgers := Predicates.ledgerDocsOf g.domain g.ledgers
    specItems := objectItems ((specJson.get? "items").getD (.arr []))
    context := contextJson
    observations := g.observations
    awaitingPhaseApproval := completion.awaitingPhaseApproval }
  if !diagnostics.isEmpty then
    lines := lines ++ [s!"State reads  : {diagnostics.length} issue(s)"]
    for item in diagnostics do
      lines := lines ++ ["  - " ++ item]
  return (lines, none)

/-! ## コンパイル時テスト -/

-- pyStr / pyRepr(f-string 補間の互換面)
#guard pyStr .null == "None"
#guard pyStr (.bool true) == "True"
#guard pyStr (.num 42 0) == "42"
#guard pyStr (.num (-3) 0) == "-3"
#guard pyStr (.str "raw text") == "raw text"
#guard pyStr (.arr [.str "T-001", .str "T-002"]) == "['T-001', 'T-002']"
#guard pyStr (.arr []) == "[]"
#guard pyStr (.arr [.null, .bool false, .num 1 0]) == "[None, False, 1]"
#guard pyStr (.obj [("a", .num 1 0), ("b", .str "x")]) == "{'a': 1, 'b': 'x'}"
#guard pyReprStr "it's" == "\"it's\""                 -- ' を含み " を含まない → "
#guard pyReprStr "both '\"" == "'both \\'\"'"          -- 両方含む → ' でエスケープ
#guard pyReprStr "tab\there" == "'tab\\there'"
#guard pyReprStr "日本語" == "'日本語'"
#guard pyReprStr (String.ofList [Char.ofNat 1]) == "'\\x01'"

-- countByStatus / statusSummary
private def todoWith (status : Json.Value) : Json.Value := .obj [("status", status)]
private def errOf : Except String α → Option String
  | .error e => some e
  | .ok _ => none
#guard (countByStatus [todoWith (.str "done"), todoWith (.str "pending"),
    todoWith (.str "done"), .obj []]).toOption
    == some [(.str "done", 2), (.str "pending", 1), (.str "unknown", 1)]
#guard errOf (countByStatus [todoWith (.arr [])]) == some "unhashable type: 'list'"
#guard (statusSummary []).toOption == some ""
#guard (statusSummary [(.null, 2)]).toOption == some "None=2"  -- 単一要素は比較しない
#guard (statusSummary [(.str "pending", 1), (.str "done", 2)]).toOption
    == some "done=2, pending=1"
#guard (statusSummary [(.num 3 0, 1), (.num 1 0, 2), (.bool true, 1)]).toOption
    == some "1=2, True=1, 3=1"                         -- 全数値は数値順(bool 含む)
#guard (statusSummary [(.str "done", 1), (.num 1 0, 1)]).isOk == false

-- acceptanceEvidenceMap
private def doneMustTodo : Json.Value := .obj [
  ("id", .str "T-001"), ("title", .str "Ship the gate"),
  ("priority", .str "must"), ("status", .str "done"),
  ("spec", .arr [.str "S-001"]),
  ("evidence", .arr [.obj [("type", .str "command"),
    ("command", .str "pytest -q"), ("summary", .str "all green")]])
]
private def specItemsFixture : Json.Value := .arr [.obj [
  ("id", .str "S-001"), ("title", .str "acceptance-gate-xyz passes")]]

#guard (acceptanceEvidenceMap ["pytest 全緑"] [doneMustTodo] (.arr [])).toOption
    == some [{ condition := "pytest 全緑", mapped := true, todos := [.str "T-001"] }]
#guard (acceptanceEvidenceMap ["acceptance-gate-xyz が通る"] [doneMustTodo]
    specItemsFixture).toOption
    == some [{ condition := "acceptance-gate-xyz が通る", mapped := true,
               todos := [.str "T-001"] }]
#guard (acceptanceEvidenceMap ["unrelated-condition-999"] [doneMustTodo]
    (.arr [])).toOption
    == some [{ condition := "unrelated-condition-999", mapped := false, todos := [] }]
-- diff だけの Todo は候補にならない(§22)
#guard (acceptanceEvidenceMap ["pytest"]
    [(doneMustTodo.set "evidence" (.arr [.obj [("type", .str "diff")]]))]
    (.arr [])).toOption
    == some [{ condition := "pytest", mapped := false, todos := [] }]
-- spec items の TypeError 面
#guard (acceptanceEvidenceMap ["x"] [] .null).isOk == false
#guard (acceptanceEvidenceMap ["x"] [] (.num 1 0)).isOk == false
#guard (acceptanceEvidenceMap ["x"] [] (.obj [("k", .null)])).isOk == true

-- statusRender: クリーンな初期化済み state の全行
-- ESSENCE.md は正準見出し契約(§2.1.1'・§13.1-15)を満たす形でなければ
-- `essence_structure` で停止するため、フィクスチャも**軸の正準列から**組み立てる
-- (綴りを直書きすると、軸が変わった瞬間にフィクスチャだけが古い契約を主張する)
private def canonicalEssence (d : Domain) (title motivation extra : String) :
    String :=
  "# ESSENCE — " ++ title ++ "\n"
    ++ String.intercalate "" (d.essenceHeadings.mapIdx fun i h =>
      if h == Essence.essenceSuccessHeading then "## " ++ h ++ "\n" ++ extra
      else "## " ++ h ++ "\n- "
        ++ (if i == 0 then motivation else "Determinism over cleverness.")
        ++ "\n")
-- 成功条件 節は「見出しだけ」— 構造検査は見出し列しか見ないので契約は満たしつつ、
-- 成功条件 ↔ evidence 表示(§20.2-6)は本節を持つフィクスチャで別途凍結する
private def realEssence : String :=
  canonicalEssence Domain.fixture "Deterministic Test"
    "A deterministic test project." ""
private def cleanStatus : StatusInputs := {
  projectRoot := "/ws/sample-project"
  stateIndex := .text "{}"
  validation := .text "{\"status\": \"ok\", \"last_validated_at\": \"2026-07-16T00:00:00+09:00\"}"
  stop := {
    domain := Domain.fixture
    projectTitle := "sample-project"
    stateInitialized := true
    project := .text ("{\"essence_sha256\": \""
      ++ Looper.Core.Sha256.hexDigest (String.toUTF8 realEssence) ++ "\"}")
    spec := .text "{\"items\": [{\"id\": \"S-001\"}]}"
    todo := .text ("{\"items\": [{\"id\": \"T-001\", \"status\": \"pending\", "
      ++ "\"priority\": \"must\", \"executor\": {\"mode\": \"looper\"}}], "
      ++ "\"active_batch\": []}")
    recommendations := .text "{\"items\": []}"
    blockers := .text "{\"items\": []}"
    context := .text "{\"progress\": {}, \"stop_policy\": {}}"
    reflection := .text ""
    runs := .text ""
    ledgers := []
    observations := []
    attestations := .absent
    essence := .file (String.toUTF8 realEssence)
    essencesDir := .absent
  }
}

/-- gate 保持面だけを差し替えたフィクスチャ。 -/
private def cleanWith (f : Predicates.StopInputs → Predicates.StopInputs) :
    StatusInputs :=
  { cleanStatus with stop := f cleanStatus.stop }

private def gateLines (i : StatusInputs) : List String :=
  (statusRender i).1.filter (·.startsWith "Gate")

#guard (statusRender cleanStatus).2 == none
#guard (statusRender cleanStatus).1 == [
  "Project      : sample-project",
  "PROJECT_ROOT : /ws/sample-project",
  "Spec items   : 1",
  "Todos        : 1 (pending=1)",
  "Active batch : none",
  "Blockers     : 0",
  "Validation   : ok (checked never; diagnostics unchanged since 2026-07-16T00:00:00+09:00)",
  "Runs logged  : 0",
  "Phase        : must",
  "Must todos   : 0/1 done",
  "Idle cycles  : 0/3",
  "Run failures : infra 0/2, usage-limit 0/4",
  "Gate         : none (runnable)"
]

-- ドメイン表示行(`Domain.statusLines`)の**位置**を凍結する: 成功条件ブロックの
-- 直後・診断行の前。軸を持たないドメインでは 1 行も増えない(上の全行凍結)。
-- 表示の中身は製品の黒箱 conformance が覆う(K-7)。
#guard (statusRender { cleanStatus with
    stop := { cleanStatus.stop with
      domain := Domain.fixtureRich
      ledgers := [("extra.json", .text "{\"items\": []}")]
      essence := .file (String.toUTF8
        (canonicalEssence Domain.fixtureRich "Deterministic Test"
          "A deterministic test project." ""))
      project := .text ("{\"essence_sha256\": \""
        ++ Looper.Core.Sha256.hexDigest (String.toUTF8
          (canonicalEssence Domain.fixtureRich "Deterministic Test"
            "A deterministic test project." "")) ++ "\"}") } }).1
    == [
  "Project      : sample-project",
  "PROJECT_ROOT : /ws/sample-project",
  "Spec items   : 1",
  "Todos        : 1 (pending=1)",
  "Active batch : none",
  "Blockers     : 0",
  "Validation   : ok (checked never; diagnostics unchanged since 2026-07-16T00:00:00+09:00)",
  "Runs logged  : 0",
  "Phase        : must",
  "Must todos   : 0/1 done",
  "Idle cycles  : 0/3",
  "Run failures : infra 0/2, usage-limit 0/4",
  "Gate         : none (runnable)",
  "Domain       : 1 ledger(s)"
]

-- STOP 表示(ESSENCE.md 不在)と runs の last 表示
#guard gateLines (cleanWith fun s => { s with essence := .absent })
    == ["Gate         : STOP (essence_missing)"]
#guard (statusRender (cleanWith fun s => { s with
    runs := .text "{\"run_id\": \"r-1\", \"event\": \"start\"}\n{\"run_id\": \"r-1\", \"event\": \"end\"}\n"
  })).1.filter (·.startsWith "Runs logged")
    == ["Runs logged  : 2 (last: r-1 end)"]
-- runs 最終レコード非 object は部分出力 + ハードエラー
#guard (statusRender (cleanWith fun s => { s with runs := .text "[1, 2]\n" })).2.isSome
#guard ((statusRender (cleanWith fun s =>
    { s with runs := .text "[1, 2]\n" })).1.length) == 7
-- active_batch の repr 埋め込み
#guard (statusRender (cleanWith fun s => { s with
    todo := .text "{\"items\": [], \"active_batch\": [\"T-001\", \"T-002\"]}"
  })).1.filter (·.startsWith "Active batch")
    == ["Active batch : ['T-001', 'T-002']"]
-- 破損 state は診断行に落ち、exit は 0 のまま(表示は致命化しない)
#guard (statusRender (cleanWith fun s => { s with spec := .text "{broken" })).2 == none
#guard ((statusRender (cleanWith fun s =>
    { s with spec := .text "{broken" })).1.filter
    (·.startsWith "State reads")) == ["State reads  : 1 issue(s)"]

-- essences/ の観測が Gate 行へ届いていること(回帰: status だけが essences/ を
-- 不在として評価し、全資産 removed + 全言及 dangling を報告した)。
private def assetEssence : String :=
  canonicalEssence Domain.fixture "Asset Test"
    "See essences/logo.png for the mark." ""
private def assetStatus : StatusInputs := cleanWith fun s => { s with
  essence := .file (String.toUTF8 assetEssence)
  project := .text ("{\"essence_sha256\": \""
    ++ Looper.Core.Sha256.hexDigest (String.toUTF8 assetEssence)
    ++ "\", \"essences_manifest\": {\"logo.png\": \""
    ++ Looper.Core.Sha256.hexDigest (String.toUTF8 "IMG") ++ "\"}}")
  essencesDir := .dir [("logo.png", .file (String.toUTF8 "IMG"))] [] []
}
-- 実在し、baseline と一致する資産は runnable のまま
#guard gateLines assetStatus == ["Gate         : none (runnable)"]
-- Gate 行の理由は同一入力に対する should-stop の reasons と一致する(I-017)
#guard (Predicates.shouldStopPayload assetStatus.stop).toOption.map (·.stop)
    == some false
-- 資産の実変更だけが理由として立つ(全件 removed にはならない)
private def assetChanged : StatusInputs :=
  { assetStatus with stop := { assetStatus.stop with
      essencesDir := .dir [("logo.png", .file (String.toUTF8 "IMG2"))] [] [] } }
#guard gateLines assetChanged
    == ["Gate         : STOP (essence_unreviewed_change)"]
#guard ((statusRender assetChanged).1.filter (·.startsWith "  - ")).any
    (Text.containsSub · "changed logo.png")
#guard !((statusRender assetChanged).1.any (Text.containsSub · "removed logo.png"))
#guard !((statusRender assetChanged).1.any
    (Text.containsSub · "essence_asset_integrity"))

-- 成功条件セクション(mapped / unmapped の ✓✗ と via 表示)
private def essenceWithSuccess : String :=
  canonicalEssence Domain.fixture "Success Test" "A deterministic test project."
    "- pytest 全緑\n- acceptance-gate-xyz が全通過する\n"
private def successStatus : StatusInputs := cleanWith fun s => { s with
  essence := .file (String.toUTF8 essenceWithSuccess)
  project := .text ("{\"essence_sha256\": \""
    ++ Looper.Core.Sha256.hexDigest (String.toUTF8 essenceWithSuccess) ++ "\"}")
  todo := .text ("{\"items\": [{\"id\": \"T-001\", \"title\": \"Run tests\", "
    ++ "\"priority\": \"must\", \"status\": \"done\", \"spec\": [], "
    ++ "\"evidence\": [{\"type\": \"command\", \"command\": \"pytest -q\", "
    ++ "\"summary\": \"all green\"}]}]}")
}
#guard ((statusRender successStatus).1.filter (·.startsWith "成功条件"))
    == ["成功条件      : 1/2 mapped to acceptance-check command evidence on done must Todos (§22 heuristic aid)"]
#guard ((statusRender successStatus).1.filter (fun l =>
    l.startsWith "  ✓" || l.startsWith "  ✗"))
    == ["  ✓ 1. pytest 全緑  [T-001]", "  ✗ 2. acceptance-gate-xyz が全通過する"]

end Looper.State.Status
