import Looper.Core.Doc

/-!
`Looper.Io.Proc` — 外部プロセス観測の薄い IO シェル。

置換元は state.py のプロセス系ヘルパー: `_parent_pid`(`ps -o ppid= -p`)、
`os.kill(pid, 0)` の生存確認、`project_worktree_changes` の git 呼び出し。

`os.kill(pid, 0)` は Lean コアに対応 API が無いため `ps -p <pid>` の
exit code と stderr で代替する。ps はゾンビも他ユーザーのプロセスも「存在する」
と報告する。exit 1 かつ stderr が空の通常の「該当 PID なし」だけを死亡とし、
sandbox / 権限 / 起動障害を含むそれ以外は生存扱いへ倒す。生死不明の holder を
stale と誤認して lock を奪うより、回復を人間へ要求する方が I-018 に対して
fail-closed だからである。
-/

namespace Looper.Io.Proc

/-- `subprocess.run([...], capture_output=True)` 相当。起動不能は `none`
(Python の OSError 捕捉側に対応。捕捉しない呼び出し元は `Option` を
剥がしてエラーへ倒す)。 -/
def output? (cmd : String) (args : Array String) :
    IO (Option IO.Process.Output) := do
  try
    pure (some (← IO.Process.output { cmd, args }))
  catch _ =>
    pure none

/-- Python `os.kill(pid, 0)` の生存確認: 確認できた死亡だけ false。

`ps -p` の通常の不存在は macOS / procps とも exit 1 + stderr 空である。
一方、OS sandbox が process inspection を禁じる場合も ps は「起動には成功」して
非ゼロを返し得る。その stderr/exit を死亡と読むと live lock を回収するため、
exit 1 + stderr 空以外の不確実性はすべて true にする。 -/
def pidAlive (pid : Int) : IO Bool := do
  match ← output? "ps" #["-p", toString pid] with
  | some out =>
    if out.exitCode == 0 then
      pure true
    else
      pure (!(out.exitCode == 1 && out.stderr.trimAscii.isEmpty))
  | none => pure true

/-- Python `_parent_pid`: `ps -o ppid= -p <pid>` の stdout を int 解釈。
起動不能・非数値は `none`(祖先性は「不明」であって「否定」ではない)。 -/
def parentPid? (pid : Int) : IO (Option Int) := do
  match ← output? "ps" #["-o", "ppid=", "-p", toString pid] with
  | some out => pure (Looper.Core.Doc.pyIntOfString? out.stdout)
  | none => pure none

/-- `git -C <dir> ...` の実行。Python `subprocess.run(["git", ...], text=True)`
と同じく、git バイナリ不在は例外(呼び出し元のハードエラー枠へ)、
非 UTF-8 出力も例外(Python の decode エラーに対応)。 -/
def git (dir : System.FilePath) (args : List String) : IO IO.Process.Output :=
  IO.Process.output { cmd := "git", args := (["-C", dir.toString] ++ args).toArray }

end Looper.Io.Proc
