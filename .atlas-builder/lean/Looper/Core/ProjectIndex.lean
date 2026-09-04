import Looper.Core.Json
import Looper.Core.StaticConfig

/-!
`Looper.Core.ProjectIndex` — §8.1 registry(project_index.json の単一
`project` オブジェクト)の形状判定の純粋核。

置換元は init スクリプトの 2 つのインライン Python:
1:1 再バインドガード(target 以外の登録を検出)と、--force 再バインド後の
prune(target 以外の登録を明示 null に落とす)。

パス解決(`Path.resolve()` 対応)は IO なので `Cli/Util` 側。ここは
「index JSON → 登録形状」と「prune 後の index JSON」だけを定義する。
-/

namespace Looper.Core.ProjectIndex

open Looper.Core

/-- registry の `project` キーの形状。

- `absent`: `project` が object でない(null・欠落・非 dict)。照合対象なし。
- `registered title rel?`: object。`rel?` は `project_root` が非空文字列の
  ときだけ some(Python の truthiness: null・""・false・0・空配列/objectは
  falsy として「照合するパスなし」に落ちる)。
- `malformed`: `project_root` が truthy な非文字列(Python では
  `control / rel` の TypeError で即死していた形。fail-closed に写す)。 -/
inductive Shape
  | absent
  | registered (titleDisplay : String) (rel? : Option String)
  | malformed
deriving BEq

private def isFalsy : Json.Value → Bool
  | .null => true
  | .bool b => !b
  | .str s => s.isEmpty
  | .num m _ => m == 0
  | .arr items => items.isEmpty
  | .obj entries => entries.isEmpty

/-- `project.get("title", "?")` の表示文字列。非文字列は JSON 直列化で表示する
(Python は `str()` 表示。表示専用の差として凍結)。 -/
private def titleDisplay (project : Json.Value) : String :=
  match project.get? "title" with
  | none => "?"
  | some (.str s) => s
  | some other => other.render

def shape (idx : Json.Value) : Shape :=
  match idx.get? "project" with
  | some (.obj entries) =>
    let project : Json.Value := .obj entries
    match project.get? "project_root" with
    | some (.str rel) =>
      .registered (titleDisplay project) (if rel.isEmpty then none else some rel)
    | some v => if isFalsy v then .registered (titleDisplay project) none else .malformed
    | none => .registered (titleDisplay project) none
  | _ => .absent

/-- prune: `project` キーを明示 null(§8.1 の unbound 形)へ落とした index。
キーを消さず null にするのは配布形と pruned 形を一致させるため(置換元と同一)。 -/
def pruned (idx : Json.Value) : Json.Value :=
  idx.set "project" .null

/-! ## コンパイル時テスト -/

private def sample (root : Json.Value) : Json.Value :=
  .obj [("schema_version", .str StaticConfig.schemaVersion),
        ("project", .obj [("title", .str "demo"), ("project_root", root)])]

#guard shape (.obj []) == .absent
#guard shape (.obj [("project", .null)]) == .absent
#guard shape (.arr []) == .absent
#guard shape (sample (.str "../demo")) == .registered "demo" (some "../demo")
#guard shape (sample (.str "")) == .registered "demo" none
#guard shape (sample .null) == .registered "demo" none
#guard shape (sample (.bool false)) == .registered "demo" none
#guard shape (sample (.num 0 0)) == .registered "demo" none
#guard shape (sample (.num 5 0)) == .malformed
#guard shape (sample (.arr [.str "x"])) == .malformed
#guard shape (.obj [("project", .obj [("project_root", .str "../x")])])
    == .registered "?" (some "../x")
-- prune 後の unbound 形は配布シード(StaticConfig.projectIndexSeed)そのもの
-- (シード定義の正本は StaticConfig 側、バイト凍結もそちらの #guard が担う)
#guard pruned (sample (.str "../demo")) == StaticConfig.projectIndexSeed
#guard (pruned (sample (.str "../demo"))).renderPretty ++ "\n"
    == StaticConfig.projectIndexSeedRendered

end Looper.Core.ProjectIndex
