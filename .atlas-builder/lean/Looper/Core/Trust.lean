import Looper.Core.Json

/-!
`Looper.Core.Trust` — Claude Code workspace trust 判定の純粋核
(`claude_trust.py` 対応)。

`~/.claude.json` の読み書きそのものは `Looper.Cli.Trust`(IO シェル)が行い、
ここは「payload とパス列から判定・更新後 payload を計算する」純粋関数のみを
置く(§31.4-2 の注入原則)。
-/

namespace Looper.Core.Trust

open Looper.Core

/-- 順序を保った重複除去(`claude_trust.py` の `unique_paths`。
入力は正規化済みパス)。 -/
def uniquePaths (paths : List String) : List String :=
  (paths.foldl (init := ([] : List String)) fun acc p =>
    if acc.contains p then acc else p :: acc).reverse

/-- `projects[path].hasTrustDialogAccepted` が JSON の `true` であるときのみ
信頼済み(Python の `is True` 厳密比較に対応: 数値 `1` や文字列は不可)。 -/
def isTrusted (payload : Json.Value) (path : String) : Bool :=
  match payload.get? "projects" with
  | some projects =>
    match projects.get? path with
    | some entry =>
      match entry, entry.get? "hasTrustDialogAccepted" with
      | .obj _, some (.bool true) => true
      | _, _ => false
    | none => false
  | none => false

/-- `ensure` の純粋部: 各パスの `projects[path].hasTrustDialogAccepted` を
`true` にした更新後 payload と、実際に変更したパスの列を返す。
`projects` フィールドや既存エントリがオブジェクトでない場合は
`claude_trust.py` と同じ文言のエラー(呼び出し側が exit 1)。 -/
def ensureUpdate (payload : Json.Value) (paths : List String) :
    Except String (Json.Value × List String) := do
  let mut projects ← match payload.get? "projects" with
    | none => pure (Json.Value.obj [])
    | some v@(.obj _) => pure v
    | some _ => throw "~/.claude.json field 'projects' must be an object"
  let mut changed : List String := []
  for path in paths do
    let entry ← match projects.get? path with
      | none => pure (Json.Value.obj [])
      | some v@(.obj _) => pure v
      | some _ => throw s!"~/.claude.json projects['{path}'] must be an object"
    match entry.get? "hasTrustDialogAccepted" with
    | some (.bool true) => pure ()
    | _ =>
      projects := projects.set path (entry.set "hasTrustDialogAccepted" (.bool true))
      changed := changed ++ [path]
  pure (payload.set "projects" projects, changed)

/-! ## コンパイル時テスト -/

private def sample : Json.Value :=
  .obj [("projects", .obj
    [("/a", .obj [("hasTrustDialogAccepted", .bool true)]),
     ("/b", .obj [("hasTrustDialogAccepted", .bool false)]),
     ("/c", .obj []),
     ("/d", .num 1 0)])]

#guard uniquePaths ["/a", "/b", "/a", "/c", "/b"] == ["/a", "/b", "/c"]
#guard isTrusted sample "/a" == true
#guard isTrusted sample "/b" == false          -- false は信頼ではない
#guard isTrusted sample "/c" == false          -- キー欠損
#guard isTrusted sample "/d" == false          -- エントリが object でない
#guard isTrusted sample "/e" == false          -- エントリなし
#guard isTrusted (.obj []) "/a" == false       -- projects なし
#guard isTrusted (.obj [("projects", .str "x")]) "/a" == false  -- projects が object でない
-- ensure: 既信頼はスキップ、未信頼・欠損・新規は変更
#guard (ensureUpdate sample ["/a"]).toOption.map (fun r => r.2) == some []
#guard (ensureUpdate sample ["/a", "/b", "/e"]).toOption.map (fun r => r.2)
    == some ["/b", "/e"]
#guard (ensureUpdate sample ["/b"]).toOption.map (fun r => isTrusted r.1 "/b")
    == some true
#guard (ensureUpdate (.obj []) ["/x"]).toOption.map (fun r => isTrusted r.1 "/x")
    == some true
-- エントリが object でなければエラー(Python: SystemExit)
#guard (ensureUpdate sample ["/d"]).isOk == false
#guard (ensureUpdate (.obj [("projects", .arr [])]) ["/x"]).isOk == false
-- 更新は既存エントリの他フィールドと挿入順序を保つ
#guard ((ensureUpdate (.obj [("projects", .obj [("/p", .obj [("k", .str "v")])])])
      ["/p"]).toOption.map (fun r => r.1.render))
    == some "{\"projects\": {\"/p\": {\"k\": \"v\", \"hasTrustDialogAccepted\": true}}}"

end Looper.Core.Trust
