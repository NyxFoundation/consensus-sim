import Looper.Core.Json
import Looper.Domain

/-!
`Looper.Hook.StopCheck` — Stop hook(`<tool> hook stop`)の純粋決定核。

移行元: `.claude/hooks/stop_check.py`(移行完了まで凍結)。エージェントのターン終了時、
ディスク状態がクリーンな停止と矛盾していれば(validation.json がまだ error を報告
していれば)、停止をブロックせずに警告だけ出す。

IO シェル(`Looper.Cli.Hook`)は project_index.json と validation.json を読んで
本モジュールへ渡し、返った 1 行を stdout へ書くだけで、分岐ロジックを持たない。

Python 版との対応で意図的に寛容化した点(いずれも registry / validation が壊れて
いる場合にのみ観測され、Python 版はそこで traceback で落ちる。警告抑制 = 無意見側
に倒す):
- `project_index.json` のトップレベルや `project` が object でない → 警告なし
- `project_root` / `title` が文字列でない → 欠損と同じ既定値
- `validation` が object でない → 警告なし
-/

namespace Looper.Hook.StopCheck

open Looper.Core.Json (Value)

private def strField (v : Value) (key : String) (default : String) : String :=
  ((v.get? key).bind Value.asStr?).getD default

/-- project_index.json(パース済み)から対象 project の
`(project_root 相対パス, title)`。META.md §8.1: registry は単一の `project`
object であり、object でなければ(null 含め)対象なし。
Python 版の `project.get("project_root", "")` / `project.get("title", "?")` に対応。 -/
def projectOf (index? : Option Value) : Option (String × String) := do
  let index ← index?
  let project ← index.get? "project"
  match project with
  | .obj _ => pure (strField project "project_root" "", strField project "title" "?")
  | _ => none

/-- Python の `len(validation.get("errors", []))`: 配列は要素数、object はキー数、
文字列は文字数、それ以外(欠損含む)は 0。 -/
private def errorCount (validation : Value) : Nat :=
  match validation.get? "errors" with
  | some (.arr items) => items.length
  | some (.obj entries) => entries.length
  | some (.str s) => s.length
  | _ => 0

/-- validation.json の内容から警告文。`status == "error"` のときだけ警告する。 -/
def warningOf (title : String) : Option Value → Option String
  | some validation =>
    match validation.get? "status" with
    | some (.str "error") =>
      some s!"{title}: validation.json still reports errors ({errorCount validation})."
    | _ => none
  | none => none

/-- 警告があるときだけ、hook が stdout に出す 1 行(`systemMessage` JSON)を返す。
systemMessage は人間に警告として表示されるだけで、停止をブロックせず
次ターンのコンテキストにも入らない(stop_check.py と同じ非ブロッキング設計)。 -/
def outputLine (d : Domain) (warnings : List String) : Option String :=
  match warnings with
  | [] => none
  | ws =>
    let message := "[" ++ d.displayName ++ " stop_check] " ++ String.intercalate " / " ws
    some (Value.render (.obj [("systemMessage", .str message)]))

/-! ## コンパイル時テスト -/

private def parsed (s : String) : Option Value := (Looper.Core.Json.parse s).toOption

#guard projectOf none == none
#guard projectOf (parsed "{\"schema_version\": \"1.0.0\", \"project\": null}") == none
#guard projectOf (parsed "{\"project\": {\"project_root\": \"../x\", \"title\": \"X\"}}")
    == some ("../x", "X")
#guard projectOf (parsed "{\"project\": {}}") == some ("", "?")
#guard warningOf "X" (parsed "{\"status\": \"ok\", \"errors\": []}") == none
#guard warningOf "X" (parsed "{\"status\": \"error\", \"errors\": [1, 2]}")
    == some "X: validation.json still reports errors (2)."
#guard warningOf "X" (parsed "{\"status\": \"error\"}")
    == some "X: validation.json still reports errors (0)."
#guard warningOf "X" none == none
#guard outputLine Domain.fixture [] == none
#guard outputLine Domain.fixture ["X: validation.json still reports errors (2)."]
    == some "{\"systemMessage\": \"[Looper stop_check] X: validation.json still reports errors (2).\"}"

end Looper.Hook.StopCheck
