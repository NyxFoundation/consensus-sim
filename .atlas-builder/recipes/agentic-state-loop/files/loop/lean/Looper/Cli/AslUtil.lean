import Looper.Asl.Hooks
import Looper.Core.Doc
import Looper.Core.Json
import Looper.Io.Fs

/-!
`Looper.Cli.AslUtil` — レシピ scripts のシェル内インライン Python の置換先
(`asl-loop util ...`)。live 側 `<bin> util` 群(R-7)と同じ収容方針の
レシピ版であり、`_lib.sh` / `loop.sh` の `python3 -c` / ヒアドキュメントと
挙動一致する(META.md §31.2 の配線切替弾)。

- `stop-message`: stdin の should-stop JSON から `message` を印字
  (`_lib.sh` の `stop_message_from_json`)。パース失敗・欠損・非文字列は
  既定文言 `stop condition detected`(Python は `json.load` 失敗で exit 1
  だが、入力は常に asl-loop 自身の should-stop 出力であり、既定文言への
  写像は文言のみの無害側中立差)。exit 常に 0。
- `max-session-cycles [--loop-root <p>]`: `<loop_root>/schema.json` の
  `policy.max_session_cycles` を Python `int()` 意味論(数値は 0 方向切り
  捨て、文字列は10進整数、bool は 1/0)で印字。読取・パース・変換の失敗は
  既定 8(`loop.sh` の except 節と同じ)。exit 常に 0。
- `protected-match <rel> [--loop-root <p>]`: `<loop_root>/schema.json` の
  `protected_paths` に対する一致判定(fnmatch ∨ 等値 ∨ `rstrip("*/")+"/"`
  前方一致 = `_lib.sh` の `is_protected_leftover_path` と同一の三重判定。
  判定核は `Asl.Hooks.protectedPairMatches` の単一定義)。exit 0 = 一致 /
  1 = 不一致(schema 読取不能・非リストは不一致側 = Python の except 節)。

LOOP_ROOT の解決は `Cli/Asl` と同じ規約: `--loop-root` 明示、なければ
実行ファイルの 2 つ上(`<loop_dir>/bin/asl-loop` 配置)。
-/

namespace Looper.Cli.AslUtil

open Looper
open Looper.Core.Json (Value)

/-- `asl-loop util` の全サブコマンド(下の `run` の腕と対。usage と
`Cli.AslMain.usage` の両方をこれ 1 本から導く)。 -/
def commands : List String :=
  ["stop-message", "max-session-cycles", "protected-match"]

private def usage : String :=
  "usage: asl-loop util {" ++ String.intercalate "|"
      (commands.map fun c => if c == "protected-match" then c ++ " <rel>" else c)
    ++ "} [--loop-root <path>]"

/-- `--loop-root <path>` と positional 1 個までを取り出す。 -/
private def parseUtilArgs (args : List String) :
    Except String (Option String × Option String) :=
  go args none none
where
  go : List String → Option String → Option String →
      Except String (Option String × Option String)
    | [], root, pos => .ok (root, pos)
    | "--loop-root" :: v :: rest, _, pos => go rest (some v) pos
    | ["--loop-root"], _, _ => .error "argument --loop-root: expected one argument"
    | arg :: rest, root, none =>
      if arg.startsWith "-" then .error s!"unrecognized arguments: {arg}"
      else go rest root (some arg)
    | arg :: _, _, some _ => .error s!"unrecognized arguments: {arg}"

/-- LOOP_ROOT: `--loop-root` 明示、なければ実行ファイルの 2 つ上
(`Cli/Asl.resolveCtx` と同一規約)。 -/
private def resolveLoopRoot (flag : Option String) :
    IO (Except String System.FilePath) := do
  match flag with
  | some p => pure (.ok (← Io.Fs.resolveNonStrict ⟨p⟩))
  | none =>
    let exe ← IO.appPath
    match exe.parent.bind (·.parent) with
    | some root => pure (.ok root)
    | none => pure (.error "cannot determine LOOP_ROOT from the binary location; pass --loop-root")

private def defaultStopMessage : String := "stop condition detected"

/-- `stop_message_from_json` の純粋部。 -/
def stopMessageOf (input : String) : String :=
  match Core.Json.parse input with
  | .ok v =>
    match v.get? "message" with
    | some (.str s) => s
    | _ => defaultStopMessage
  | .error _ => defaultStopMessage

/-- `max_session_cycles` の純粋部: schema.json テキストから値を導く
(`loop.sh` の `int(json.load(...).get("policy", {}).get(..., 8))`、
失敗は 8)。 -/
def maxSessionCyclesOf (schemaText? : Option String) : Int :=
  let fallback : Int := 8
  match schemaText? with
  | none => fallback
  | some text =>
    match Core.Json.parse text with
    | .error _ => fallback
    | .ok v =>
      match v.get? "policy" with
      | some policy =>
        match policy.get? "max_session_cycles" with
        -- Python `int()` 意味論の単一定義(下線区切り・非 ASCII 空白を含む
        -- 文字列形も忠実)は `Core.Doc.pyInt?` — ここで再実装しない。
        | some value => (Core.Doc.pyInt? value).getD fallback
        | none => fallback
      | none => fallback

/-- `is_protected_leftover_path` の純粋部: schema テキスト(読めなければ
none)と対象相対パスから一致を判定。非オブジェクト・非リスト・非文字列
要素は Python の except / isinstance ガードと同じく不一致側へ落ちる。 -/
def protectedMatchOf (schemaText? : Option String) (rel : String) : Bool :=
  match schemaText? with
  | none => false
  | some text =>
    match Core.Json.parse text with
    | .error _ => false
    | .ok v =>
      let (protectedPats, _, _) := Asl.Hooks.dynamicRules v
      protectedPats.any (fun pat => Asl.Hooks.protectedPairMatches pat rel)

private def readSchema? (loopRoot : System.FilePath) : IO (Option String) :=
  Io.Fs.readFile? (loopRoot / "schema.json")

def run (args : List String) : IO UInt32 := do
  match args with
  | "stop-message" :: rest =>
    match parseUtilArgs rest with
    | .error e => IO.eprintln s!"{usage} ({e})"; pure 2
    | .ok (_, some extra) => IO.eprintln s!"{usage} (unrecognized arguments: {extra})"; pure 2
    | .ok (_, none) =>
      let input ← (do
        try pure (← (← IO.getStdin).readToEnd)
        catch _ => pure "")
      IO.println (stopMessageOf input)
      pure 0
  | "max-session-cycles" :: rest =>
    match parseUtilArgs rest with
    | .error e => IO.eprintln s!"{usage} ({e})"; pure 2
    | .ok (_, some extra) => IO.eprintln s!"{usage} (unrecognized arguments: {extra})"; pure 2
    | .ok (root?, none) =>
      match ← resolveLoopRoot root? with
      | .error e => IO.eprintln s!"asl-loop util: {e}"; pure 2
      | .ok loopRoot =>
        IO.println (toString (maxSessionCyclesOf (← readSchema? loopRoot)))
        pure 0
  | "protected-match" :: rest =>
    match parseUtilArgs rest with
    | .error e => IO.eprintln s!"{usage} ({e})"; pure 2
    | .ok (_, none) => IO.eprintln s!"{usage} (the target path is required)"; pure 2
    | .ok (root?, some rel) =>
      match ← resolveLoopRoot root? with
      | .error e => IO.eprintln s!"asl-loop util: {e}"; pure 2
      | .ok loopRoot =>
        pure (if protectedMatchOf (← readSchema? loopRoot) rel then 0 else 1)
  | _ =>
    IO.eprintln usage
    pure 2

-- stop-message: message 文字列はそのまま、欠損・非文字列・パース失敗は既定文言
#guard stopMessageOf "{\"stop\": true, \"message\": \"idle streak\"}" == "idle streak"
#guard stopMessageOf "{\"stop\": true}" == "stop condition detected"
#guard stopMessageOf "{\"message\": null}" == "stop condition detected"
#guard stopMessageOf "not json" == "stop condition detected"

-- Python int() 意味論
#guard Core.Doc.pyInt? (.num 8 0) == some 8
#guard Core.Doc.pyInt? (.num 85 1) == some 8      -- int(8.5) = 8(0 方向切り捨て)
#guard Core.Doc.pyInt? (.num (-85) 1) == some (-8) -- int(-8.5) = -8
#guard Core.Doc.pyInt? (.str " 12 ") == some 12
#guard Core.Doc.pyInt? (.str "8.5") == none
#guard Core.Doc.pyInt? (.bool true) == some 1
#guard Core.Doc.pyInt? (.null) == none

-- max-session-cycles: 正常・欠損・破損
#guard maxSessionCyclesOf (some "{\"policy\": {\"max_session_cycles\": 5}}") == 5
#guard maxSessionCyclesOf (some "{\"policy\": {}}") == 8
#guard maxSessionCyclesOf (some "{}") == 8
#guard maxSessionCyclesOf (some "broken") == 8
#guard maxSessionCyclesOf none == 8

-- protected-match: fnmatch ∨ 等値 ∨ rstrip("*/")+"/" 前方一致
#guard protectedMatchOf (some "{\"protected_paths\": [\"docs/*.md\"]}") "docs/a.md" == true
#guard protectedMatchOf (some "{\"protected_paths\": [\"ESSENCE.md\"]}") "ESSENCE.md" == true
#guard protectedMatchOf (some "{\"protected_paths\": [\"legacy/**\"]}") "legacy/sub/f.c" == true
#guard protectedMatchOf (some "{\"protected_paths\": [\"docs/*.md\"]}") "src/a.md" == false
#guard protectedMatchOf (some "{\"protected_paths\": \"docs\"}") "docs" == false
#guard protectedMatchOf (some "broken") "x" == false
#guard protectedMatchOf none "x" == false

end Looper.Cli.AslUtil
