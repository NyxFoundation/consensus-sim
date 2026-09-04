import Looper.Core.Doc
import Looper.State.Model
import Looper.State.Predicates
import Looper.Domain

/-!
`Looper.State.Supervise` — human-supervised High-Risk session の read-only
preflight。

対話 session の prompt は semantic scope を守る最後の規律だが、session を
起動してよい canonical identity / risk / authorization まで prompt に委ねない。
Todo と任意 Recommendation を state 上で exact ID 解決し、共有 `target` が
一致した場合だけ、wrapper が prompt へ渡す承認済み scope payload を返す。
-/

namespace Looper.State.Supervise

open Looper.Core
open Looper.Core.Doc
open Looper.State.Model

structure Inputs where
  /-- 製品識別子の 1 語幹(§9.1 の executor 語彙。抽出計画 6e)。 -/
  tool : String
  todo : RawFile
  recommendations : RawFile
  todoId : String
  recommendationId : Option String := none

private def objectPayload (name : String) (raw : RawFile) : Except String Json.Value :=
  let (payload, diagnostic) := readJsonOrEmpty name raw
  match diagnostic with
  | some e => .error e
  | none => .ok payload

private def itemList (name : String) (payload : Json.Value) :
    Except String (List Json.Value) :=
  match payload.get? "items" with
  | some (.arr items) => .ok items
  | _ => .error s!"{name}.items must be a list"

private def exactItem (kind id : String) (items : List Json.Value) :
    Except String Json.Value :=
  let found := items.filter fun item => item.get? "id" == some (.str id)
  match found with
  | [item@(.obj _)] => .ok item
  | [] => .error s!"{kind} {id} does not exist"
  | [_] => .error s!"{kind} {id} is not an object"
  | _ => .error s!"{kind} {id} is duplicated; canonical identity is ambiguous"

private def nonEmptyField (kind : String) (item : Json.Value)
    (field : String) : Except String String :=
  match item.get? field with
  | some (.str value) =>
    let value := Text.pyStrip value
    if value.isEmpty then .error s!"{kind}.{field} must be a non-empty string"
    else .ok value
  | _ => .error s!"{kind}.{field} must be a non-empty string"

private def stringListField (kind : String) (item : Json.Value)
    (field : String) : Except String (List String) :=
  match item.get? field with
  | some (.arr values) => values.mapM fun value =>
      match value with
      | .str text =>
        let text := Text.pyStrip text
        if text.isEmpty then .error s!"{kind}.{field} contains an empty string"
        else .ok text
      | _ => .error s!"{kind}.{field} must contain only strings"
  | _ => .error s!"{kind}.{field} must be a list of strings"

/-- `target` is displayed on the terminal and embedded in the session prompt.
Reject line/control injection; ordinary paths and globs remain valid. -/
private def targetField (kind : String) (item : Json.Value) : Except String String := do
  let target ← nonEmptyField kind item "target"
  if target.toList.any fun c => c.toNat < 32 || c.toNat == 127 then
    throw s!"{kind}.target must be a single control-free line"
  pure target

/-- Exact Todo / optional Recommendation authorization check. No writes. -/
def preflight (i : Inputs) : Except String Json.Value := do
  let todoPayload ← objectPayload "todo.json" i.todo
  let todoItems ← itemList "todo.json" todoPayload
  let todo ← exactItem "Todo" i.todoId todoItems
  if todo.get? "risk_level" != some (.str "high") then
    throw s!"Todo {i.todoId} is not high-risk"
  let _ ← nonEmptyField s!"Todo {i.todoId}" todo "risk_reason"
  let target ← targetField s!"Todo {i.todoId}" todo
  let status ← nonEmptyField s!"Todo {i.todoId}" todo "status"
  if !["pending", "in_progress", "blocked"].contains status then
    throw s!"Todo {i.todoId} is not unfinished (status={status})"
  if (todo.get? "executor").bind (·.get? "mode") != some (.str i.tool) then
    throw s!"Todo {i.todoId} must have executor.mode={i.tool}"

  let recommendationIdJson ← match i.recommendationId with
    | none => pure Json.Value.null
    | some recommendationId => do
      let recPayload ← objectPayload "recommendations.json" i.recommendations
      let recItems ← itemList "recommendations.json" recPayload
      let rec ← exactItem "Recommendation" recommendationId recItems
      if !Predicates.recommendationRequiresHuman rec then
        throw s!"Recommendation {recommendationId} is not an open human approval gate"
      let sources ← stringListField s!"Recommendation {recommendationId}" rec "source"
      if !sources.contains i.todoId then
        throw s!"Recommendation {recommendationId} does not authorize Todo {i.todoId}"
      let recTarget ← targetField s!"Recommendation {recommendationId}" rec
      if recTarget != target then
        throw s!"Recommendation {recommendationId} target does not match Todo {i.todoId} target"
      pure (.str recommendationId)

  pure (.obj [
    ("ok", .bool true),
    ("todo_id", .str i.todoId),
    ("target", .str target),
    ("recommendation_id", recommendationIdJson)])

/-! ## 受理集合の凍結(§13.3-4'')

`Predicates.superviseAuthorizedTodo?` は「この Recommendation を渡した
supervise が preflight を通るか」の**単一定義**として resume の受理集合と
停止 message の案内を駆動する。preflight 本体(granular な拒否文言を持つ側)
と受理集合がずれると、『resume が守る gate』と『supervise が使える gate』が
乖離して 2026-08-04 の実障害(承認時 resolve による binding 自壊)が再発する
ため、代表点での一致をここで凍結する。 -/

private def probeTodo (status : String) : RawFile := .text
  ("{\"items\": [{\"id\": \"T-HR\", \"status\": \"" ++ status ++ "\", "
    ++ "\"executor\": {\"mode\": \"looper\"}, \"risk_level\": \"high\", "
    ++ "\"risk_reason\": \"agent runtime\", \"target\": \"agent/**\"}]}")

private def probeRec (status target : String) : RawFile := .text
  ("{\"items\": [{\"id\": \"R-A\", \"type\": \"Human-input Recommendation\", "
    ++ "\"status\": \"" ++ status ++ "\", \"requires_human_approval\": true, "
    ++ "\"source\": [\"T-HR\"], \"target\": \"" ++ target ++ "\"}]}")

private def agrees (todoRaw recRaw : RawFile) : Bool :=
  let viaPreflight := (preflight {
    tool := "looper",
    todo := todoRaw, recommendations := recRaw,
    todoId := "T-HR", recommendationId := some "R-A" }).isOk
  let todoItems := match (readJsonOrEmpty "todo.json" todoRaw).1.get? "items" with
    | some (.arr xs) => xs
    | _ => []
  let recItems := match (readJsonOrEmpty "recommendations.json" recRaw).1.get? "items" with
    | some (.arr xs) => xs
    | _ => []
  let viaPredicate := recItems.any fun r =>
    Predicates.superviseAuthorizedTodo? Domain.fixture r todoItems == some "T-HR"
  viaPreflight == viaPredicate

#guard agrees (probeTodo "pending") (probeRec "proposed" "agent/**")      -- 受理
#guard agrees (probeTodo "in_progress") (probeRec "proposed" "agent/**")  -- 受理
#guard agrees (probeTodo "blocked") (probeRec "proposed" "agent/**")      -- 受理
#guard agrees (probeTodo "done") (probeRec "proposed" "agent/**")         -- 両拒否
#guard agrees (probeTodo "pending") (probeRec "resolved" "agent/**")      -- 両拒否
#guard agrees (probeTodo "pending") (probeRec "proposed" "other/**")      -- 両拒否
#guard agrees .absent (probeRec "proposed" "agent/**")                    -- 両拒否
#guard agrees (probeTodo "pending") .absent                               -- 両拒否
-- 受理側が実際に受理であること(agrees が「両偽」で膠着していないことの確認)
#guard (preflight {
    tool := "looper",
    todo := probeTodo "pending", recommendations := probeRec "proposed" "agent/**",
    todoId := "T-HR", recommendationId := some "R-A" }).isOk

end Looper.State.Supervise
