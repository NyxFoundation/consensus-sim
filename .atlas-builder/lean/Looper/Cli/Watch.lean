import Looper.State.Watch
import Looper.Cli.State
import Looper.Io.Fs
import Looper.Domain

/-!
`<tool> state watch-render` — watch の 1 フレーム描画(IO シェル、META.md
§15.3)。

`Cli.Main` が `state watch-render` を `Cli.State.run` より前にディスパッチする
— read-only の描画面であり、state.py 由来の凍結面(`Cli/State` の
argparse / mutatingCommands)には触れない。観測は `Cli.State.stopInputs`
(should-stop と同一、I-017)+ 表示専用面(heartbeat / lock / drain /
validation / tails — driver の watch スクリプトが観測してフラグ・パスで渡す)。

観測収集のハード失敗(不正 UTF-8 の canonical file 等、I-021 の exit 2 経路)は
ここでは exit 2 にせず EVAL ERROR フレームへ落とす — 述語はどのみち同じ入力で
同じ失敗を報告するし、state が壊れているときこそ人間の窓が要る(§19.1-3)。
契約: 常に exit 0(usage・PROJECT_ROOT 解決失敗のみ 2)、stdout はちょうど
`--rows` 行の 1 フレーム。
-/

namespace Looper.Cli.Watch

open Looper.Core
open Looper.State

private def usage (d : Domain) : String :=
  s!"usage: {d.binCommand} state watch-render --project <PROJECT_ROOT> --cols <n> --rows <n> --now <epoch> [--no-color] [--lock-pid <pid>] [--lock-alive yes|no] [--drain-pending] [--heartbeat <path>] [--transcript-tail <path>]"

private def die (tool msg : String) : IO UInt32 := do
  IO.eprintln s!"[{tool} state] ERROR: {msg}"
  pure 2

private structure Args where
  project : String
  cols : Nat
  rows : Nat
  now : Int
  color : Bool
  lockPid : Option String
  lockAlive : Bool
  drainPending : Bool
  heartbeat : Option String
  transcriptTail : Option String

private structure ArgsAcc where
  project : Option String := none
  cols : Option Nat := none
  rows : Option Nat := none
  now : Option Int := none
  color : Bool := true
  lockPid : Option String := none
  lockAlive : Bool := false
  drainPending : Bool := false
  heartbeat : Option String := none
  transcriptTail : Option String := none

/-- strict パース: 未知フラグ・値欠落・非数値・`--lock-alive` の閉集合外は
none(= usage)。必須 4 欄の検査は最後の構築が担う。 -/
private def parseArgs : List String → ArgsAcc → Option Args
  | [], acc => do
    pure { project := ← acc.project, cols := ← acc.cols, rows := ← acc.rows,
           now := ← acc.now, color := acc.color, lockPid := acc.lockPid,
           lockAlive := acc.lockAlive, drainPending := acc.drainPending,
           heartbeat := acc.heartbeat, transcriptTail := acc.transcriptTail }
  | "--project" :: v :: rest, acc => parseArgs rest { acc with project := some v }
  | "--cols" :: v :: rest, acc =>
    (v.toNat?).bind fun n => parseArgs rest { acc with cols := some n }
  | "--rows" :: v :: rest, acc =>
    (v.toNat?).bind fun n => parseArgs rest { acc with rows := some n }
  | "--now" :: v :: rest, acc =>
    (v.toInt?).bind fun n => parseArgs rest { acc with now := some n }
  | "--no-color" :: rest, acc => parseArgs rest { acc with color := false }
  | "--lock-pid" :: v :: rest, acc => parseArgs rest { acc with lockPid := some v }
  | "--lock-alive" :: v :: rest, acc =>
    if v == "yes" then parseArgs rest { acc with lockAlive := true }
    else if v == "no" then parseArgs rest { acc with lockAlive := false }
    else none
  | "--drain-pending" :: rest, acc => parseArgs rest { acc with drainPending := true }
  | "--heartbeat" :: v :: rest, acc => parseArgs rest { acc with heartbeat := some v }
  | "--transcript-tail" :: v :: rest, acc =>
    parseArgs rest { acc with transcriptTail := some v }
  | _, _ => none

/-- 表示専用面の寛容読み: 不在・権限・不正 UTF-8 のすべてを none へ
(fail-closed が要るのは canonical 観測だけ — そちらは `stopInputs` が担う)。 -/
private def readTail? : Option String → IO (Option String)
  | none => pure none
  | some p => Io.Fs.readFile? p

private def readBytes? : Option String → IO (Option ByteArray)
  | none => pure none
  | some p =>
    try
      pure (some (← IO.FS.readBinFile p))
    catch _ =>
      pure none

def run (d : Domain) (args : List String) : IO UInt32 := do
  let some parsed := parseArgs args {}
    | return ← die d.tool (usage d)
  match ← Cli.State.resolveCtx d parsed.project with
  | .error msg => die d.tool msg
  | .ok ctx =>
    -- 表示用現在時刻は --now の epoch から決定的に整形する(golden の前提)
    let offsetMinutes := (((← IO.getEnv (d.envPrefix ++ "_TZ")).getD "")
      |> Core.Time.parseTzOffset?).getD Core.Time.defaultOffsetMinutes
    let stop ← try
        pure (Except.ok (← Cli.State.stopInputs ctx))
      catch e =>
        pure (Except.error (toString e))
    let inputs : Watch.WatchInputs := {
      tool := d.tool
      projectTitle := ctx.title
      nowEpoch := parsed.now
      nowLocal := Core.Time.isoTimestamp parsed.now offsetMinutes
      cols := parsed.cols
      rows := parsed.rows
      color := parsed.color
      lockPid := parsed.lockPid
      lockAlive := parsed.lockAlive
      drainPending := parsed.drainPending
      heartbeat := ← readTail? parsed.heartbeat
      stop
      validation := ← readTail? (some (ctx.stateDir / "validation.json").toString)
      transcriptTail := ← readBytes? parsed.transcriptTail
    }
    for line in Watch.render inputs do
      IO.println line
    pure 0

end Looper.Cli.Watch
