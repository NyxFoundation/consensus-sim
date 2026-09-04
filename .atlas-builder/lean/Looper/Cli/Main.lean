import Looper

/-!
マルチコールバイナリのサブコマンドディスパッチ。判定ロジック自体は
`Looper.Core` / `Looper.Hook` 側の純粋定義に委譲する IO シェルである。

**エントリポイントそのものはここではない。** 実行ファイルの `main` は製品
名前空間にあり(`<Product>.Main`)、製品の `Domain` を第 1 引数として
`run` を呼ぶ(抽出計画 §4.2 / D-9)。バイナリ名を決めるのも
製品側の `lakefile.lean` である。この分離により、本ファイルは製品ごとの
実体を知らないまま両製品で共有できる。
-/

namespace Looper.Cli.Main

/-- 受け付ける hook イベント(下の `run` の腕と対)。 -/
def hookEvents : List String :=
  ["stop", "session-start", "pre-compact", "pre-tool", "post-tool"]

/-- 案内するサブコマンドの全量。**手書きの一覧を置かない** — 各族の
ディスパッチ面そのものから導く。手書きだったあいだ、5h で足した追記系 3 本と
8 で足した `util domain-spec` が実装済みのまま usage に載らず、META だけが
正しいという三点のずれが残っていた(抽出計画 Phase 10 の整合性総点検)。

`state watch-render` だけは `Cli.State` の argparse を通らず(state.py 由来の
凍結面に触れないため `run` がその手前で受ける)`allCommands` に無いので、
ここで state 族へ足す。 -/
def subcommands : List String :=
  ["version"]
    ++ hookEvents.map ("hook " ++ ·)
    ++ Looper.Cli.Recipe.commands.map ("recipe " ++ ·)
    ++ Looper.Cli.Trust.commands.map ("trust " ++ ·)
    ++ (Looper.Cli.State.allCommands ++ ["watch-render"]).map ("state " ++ ·)
    ++ Looper.Cli.Util.commands.map ("util " ++ ·)

def usage (d : Domain) : String :=
  s!"usage: {d.binCommand} <subcommand>\nimplemented subcommands: "
    ++ String.intercalate ", " subcommands

/-- サブコマンドのディスパッチ。`d` は製品が注入するドメイン軸(D-9)—
まだ消費点は無く、6b 以降で軸ごとに配線される。 -/
def run (d : Domain) (args : List String) : IO UInt32 := do
  match args with
  | ["version"] =>
    IO.println s!"{d.tool} {Looper.Core.versionString}"
    pure 0
  | ["hook", "stop"] =>
    Looper.Cli.Hook.runStop d
  | ["hook", "session-start"] =>
    Looper.Cli.Hook.runSessionStart d
  | ["hook", "pre-compact"] =>
    Looper.Cli.Hook.runPreCompact d
  | ["hook", "pre-tool"] =>
    Looper.Cli.Hook.runPreTool d
  | ["hook", "post-tool"] =>
    Looper.Cli.Hook.runPostTool d
  | "recipe" :: rest =>
    Looper.Cli.Recipe.run d rest
  | "trust" :: rest =>
    Looper.Cli.Trust.run rest (prog := s!"bin/{d.tool}")
  | "state" :: "watch-render" :: rest =>
    -- watch の単発描画面(§15.3)。`Cli.State.run` より前に受けることで、
    -- state.py 由来の凍結面(argparse / mutatingCommands)に触れない。
    Looper.Cli.Watch.run d rest
  | "state" :: rest =>
    Looper.Cli.State.run d rest
  | "util" :: rest =>
    Looper.Cli.Util.run d rest
  | "hook" :: rest =>
    -- 未知の hook イベントは配線ミス(運用者エラー)なので、hooks の
    -- fail-open 契約(常に exit 0)ではなく、他の未知サブコマンドと同じく
    -- exit 2 で大きく落とす。
    let event := String.intercalate " " rest
    IO.eprintln s!"{d.tool}: unknown hook event: {event}"
    pure 2
  | [] =>
    IO.eprintln (usage d)
    pure 2
  | subcommand :: _ =>
    IO.eprintln s!"{d.tool}: unknown subcommand: {subcommand}"
    pure 2

end Looper.Cli.Main
