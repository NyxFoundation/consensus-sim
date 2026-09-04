import Looper.Core.Trust
import Looper.Core.Path
import Looper.Io.Fs

/-!
`Looper.Cli.Trust` — `<prog> trust status|ensure [--quiet] <paths...>` の
IO シェル(`scripts/claude_trust.py` の置換先)。

契約(claude_trust.py と同一):
- `status`: 全候補が信頼済みなら exit 0、1 つでも欠けていれば exit 1。
  `--quiet` でなければ `Claude config:` 行と各パスの `trusted:`/`untrusted:`。
  読み取り専用(書き込みなし)。
- `ensure`: 未信頼のパスに `hasTrustDialogAccepted: true` を立て、変更が
  あったときのみ `~/.claude.json` をアトミックに書き戻す。exit 0。
- 設定読み取り不能・JSON 不正・形状不正は stderr + exit 1
  (Python の `SystemExit(msg)`)。引数不正は stderr + exit 2。

Python との意図差(いずれも docstring 明記の上で採用):
- 書き込みパーミッション: Python は既存ファイルの mode を保持(新規は 0600)
  するが、Lean コアには mode の読み取りが無いため常に 0600 へ固定する。
  `~/.claude.json` は機微ファイルであり厳格側への一方向の差。
- 空白のみの設定ファイル判定: Python `str.strip` は垂直タブ・改ページも
  空白に含むが、Lean `String.trim` は含まない(実ファイルでは現れない)。
-/

namespace Looper.Cli.Trust

open Looper

/-- `trust` の全サブコマンド(usage とトップレベル usage の導出元)。 -/
def commands : List String := ["status", "ensure"]

/-- usage(`prog` はマルチコールバイナリ名 — 製品バイナリとレシピの
`asl-loop` の両方から共有される)。 -/
private def usage (prog : String) : String :=
  "usage: " ++ prog ++ " trust {" ++ String.intercalate "|" commands
    ++ "} [--quiet] <paths...>"

/-- 所有者のみ読み書き(0600)。`~/.claude.json` の新規作成時の Python 挙動
に一致し、既存ファイルにも同じ厳格側へ倒す(モジュール docstring 参照)。 -/
private def ownerReadWrite : IO.FileRight :=
  { user := { read := true, write := true, execution := false }
    group := {}
    other := {} }

/-- `claude_trust.py` の `load_config`: 不存在・空白のみは空オブジェクト、
読めない・JSON 不正・トップレベルがオブジェクトでないものはエラー文字列。 -/
private def loadConfig (path : System.FilePath) :
    IO (Except String Core.Json.Value) := do
  if !(← path.pathExists) then
    return .ok (.obj [])
  match ← Io.Fs.readFileResult path with
  | .error e => return .error s!"cannot read {path}: {e}"
  | .ok text =>
    if text.trimAscii.isEmpty then
      return .ok (.obj [])
    match Core.Json.parse text with
    | .error e => return .error s!"{path} is not valid JSON: {e}"
    | .ok v@(.obj _) => return .ok v
    | .ok _ => return .error s!"{path} must contain a JSON object"

private structure Parsed where
  ensure : Bool
  quiet : Bool
  paths : List String

private def parseArgs : List String → Option Parsed
  | cmd :: rest => do
    let ensure ← match cmd with
      | "ensure" => some true
      | "status" => some false
      | _ => none
    let quiet := rest.contains "--quiet"
    let paths := rest.filter (· != "--quiet")
    if paths.isEmpty then none else some { ensure, quiet, paths }
  | [] => none

/-- `prog` は**必須引数**である(抽出計画 6e)。L0 はドメインを知らないので、
既定値に製品綴りを置くと純粋核が製品を知ってしまう — 呼び出し側(製品の
`Main` が渡す `Domain` / レシピの `asl-loop`)が必ず名乗る。 -/
def run (args : List String) (prog : String) : IO UInt32 := do
  let some parsed := parseArgs args
    | do
      IO.eprintln (usage prog)
      pure 2
  let home? ← IO.getEnv "HOME"
  if home?.isNone then
    IO.eprintln s!"{prog}: HOME is not set; cannot locate ~/.claude.json"
    return 1
  let cwd ← IO.currentDir
  let paths := Core.Trust.uniquePaths
    (parsed.paths.map (Core.Path.displayPath home? cwd.toString))
  -- Python `Path.home() / ".claude.json"` と同じ綴りにする(末尾スラッシュ除去)
  let configPath : System.FilePath :=
    ⟨Core.Path.expanduser home? "~"⟩ / ".claude.json"
  match ← loadConfig configPath with
  | .error msg =>
    IO.eprintln msg
    pure 1
  | .ok payload =>
    if parsed.ensure then
      match Core.Trust.ensureUpdate payload paths with
      | .error msg =>
        IO.eprintln msg
        pure 1
      | .ok (updated, changed) =>
        if !changed.isEmpty then
          if let some parent := configPath.parent then
            IO.FS.createDirAll parent
          Io.Fs.writeFileAtomicWithMode configPath
            (updated.renderPretty ++ "\n") ownerReadWrite
        unless parsed.quiet do
          IO.println s!"Claude config: {configPath}"
          if changed.isEmpty then
            IO.println "already trusted"
          else
            for p in changed do
              IO.println s!"trusted: {p}"
        pure 0
    else
      let missing := paths.filter (fun p => !Core.Trust.isTrusted payload p)
      unless parsed.quiet do
        IO.println s!"Claude config: {configPath}"
        for p in paths do
          if Core.Trust.isTrusted payload p then
            IO.println s!"trusted: {p}"
          else
            IO.println s!"untrusted: {p}"
      pure (if missing.isEmpty then 0 else 1)

end Looper.Cli.Trust
