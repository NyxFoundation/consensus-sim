import Looper.Core.Json

/-!
`Looper.Core.Runs` — runs.jsonl の未終了 run 走査の純粋核。

置換元は doctor スクリプトのインライン Python: `start`/`end` イベントを
突合し、最後に開いたまま残っている run_id を報告する(§13.5 のクラッシュ
リカバリ案内)。読めない・形の壊れた行は「in-flight unknown」= unreadable
として fail-closed に報告する(I-021: 「無し」と偽らない)。

Python との凍結差(いずれも停止側 = 厳格方向、置換元は doctor ごと
abort していた形):
- object でない JSON 行・truthy な非文字列 run_id は unreadable に写す
  (Python は未捕捉例外で doctor 全体が exit 1 していた)。
-/

namespace Looper.Core.Runs

open Looper.Core

inductive Scan
  | unreadable
  | dangling (runId : String)
  | clean
deriving BEq

private def applyEvent (opens : List String) (record : Json.Value) :
    Option (List String) := do
  let rid ← match record.get? "run_id" with
    | some (.str s) => if s.isEmpty then some none else some (some s)
    | some .null | none => some none
    | some (.bool false) => some none
    | some (.num 0 _) => some none
    | some _ => none  -- truthy 非文字列 → unreadable
  match rid with
  | none => some opens
  | some rid =>
    match record.get? "event" with
    | some (.str "start") =>
      -- Python dict 代入と同じ: 既存キーは位置を保つ(再 start は無移動)。
      some (if opens.contains rid then opens else opens ++ [rid])
    | some (.str "end") => some (opens.filter (· ≠ rid))
    | _ => some opens

/-- runs.jsonl 全文を走査し、最後に開いた未終了 run を返す。
空白行はスキップ、パース不能・非 object 行は `unreadable`。
複数残っていれば挿入順の最後(Python `next(reversed(open_runs))`)。 -/
def scan (text : String) : Scan :=
  go ((text.splitOn "\n").map (·.trimAscii.toString)) []
where
  go : List String → List String → Scan
    | [], opens =>
      match opens.getLast? with
      | some rid => .dangling rid
      | none => .clean
    | line :: rest, opens =>
      if line.isEmpty then go rest opens
      else
        match Json.parse line with
        | .error _ => .unreadable
        | .ok (.obj entries) =>
          match applyEvent opens (.obj entries) with
          | some opens' => go rest opens'
          | none => .unreadable
        | .ok _ => .unreadable

/-! ## コンパイル時テスト -/

private def line (rid event : String) : String :=
  "{\"run_id\": \"" ++ rid ++ "\", \"event\": \"" ++ event ++ "\"}"

#guard scan "" == .clean
#guard scan "\n \n" == .clean
#guard scan (line "R-1" "start") == .dangling "R-1"
#guard scan (line "R-1" "start" ++ "\n" ++ line "R-1" "end") == .clean
#guard scan (line "R-1" "start" ++ "\n" ++ line "R-2" "start"
    ++ "\n" ++ line "R-1" "end") == .dangling "R-2"
#guard scan (line "R-1" "start" ++ "\n" ++ line "R-2" "start") == .dangling "R-2"
-- 再 start は挿入位置を保つ(dict 代入と同じ)
#guard scan (line "R-1" "start" ++ "\n" ++ line "R-2" "start"
    ++ "\n" ++ line "R-1" "start") == .dangling "R-2"
#guard scan "{\"event\": \"start\"}" == .clean            -- run_id 欠落はスキップ
#guard scan "{\"run_id\": null, \"event\": \"start\"}" == .clean
#guard scan "{\"run_id\": \"\", \"event\": \"start\"}" == .clean
#guard scan "{\"run_id\": \"R-1\", \"event\": \"other\"}" == .clean
#guard scan "not json" == .unreadable
#guard scan "[1, 2]" == .unreadable
#guard scan "{\"run_id\": 5, \"event\": \"start\"}" == .unreadable
#guard scan (line "R-1" "start" ++ "\nbroken") == .unreadable

end Looper.Core.Runs
