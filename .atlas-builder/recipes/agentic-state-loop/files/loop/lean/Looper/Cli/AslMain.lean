import Looper.Core.Version
import Looper.Cli.Asl
import Looper.Cli.AslHook
import Looper.Cli.AslUtil
import Looper.Cli.Trust

/-!
レシピ agentic-state-loop のマルチコールバイナリ `asl-loop` のエントリ
ポイント(LEAN_MIGRATION_PLAN.md §3.2 の「共通コアをパラメータ化した
別エントリポイント」)。live 版の製品バイナリと同一パッケージからビルドされ、
共通判定コア(Core / Asl)を共有する(R-8)。

サブコマンドは `version`・`state`(vendored `files/loop/scripts/state.py`
の置換先)・`hook`(vendored `files/claude/hooks/*.py` の置換先: pre-tool /
post-tool / session-start)・`util`(`_lib.sh` / `loop.sh` のインライン
Python の置換先)・`trust`(`_lib.sh` の `require_claude_trust` の判定核。
live 側 `<bin> trust` と単一定義を共有)。
-/

/-- 族ごとの選択肢を `<a|b|c>` 形に畳む。 -/
private def group (name : String) (choices : List String) : String :=
  name ++ " <" ++ String.intercalate "|" choices ++ ">"

/-- 案内するサブコマンドの全量。**手書きの一覧を置かない** — 各族の
ディスパッチ面そのものから導く(抽出計画 Phase 10 の整合性総点検。Over 側では
手書きだったあいだに実装済みの 4 本が案内されないまま残っていた)。 -/
def usage : String :=
  "usage: asl-loop <subcommand>\nimplemented subcommands: version, "
    ++ String.intercalate ", "
         [group "state" Looper.Cli.Asl.commands,
          group "hook" Looper.Cli.AslHook.events,
          group "util" Looper.Cli.AslUtil.commands,
          group "trust" Looper.Cli.Trust.commands]

def main (args : List String) : IO UInt32 := do
  match args with
  | ["version"] =>
    IO.println s!"asl-loop {Looper.Core.versionString}"
    pure 0
  | "state" :: rest =>
    Looper.Cli.Asl.run rest
  | "hook" :: rest =>
    Looper.Cli.AslHook.run rest
  | "util" :: rest =>
    Looper.Cli.AslUtil.run rest
  | "trust" :: rest =>
    Looper.Cli.Trust.run rest (prog := "asl-loop")
  | [] =>
    IO.eprintln usage
    pure 2
  | subcommand :: _ =>
    IO.eprintln s!"asl-loop: unknown subcommand: {subcommand}"
    pure 2
