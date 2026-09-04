import Looper.Core.Json
import Looper.Domain

/-!
`Looper.Core.Render` — バインドテンプレート描画とシード置換の純粋核。

置換元は init スクリプトの `render()` インライン Python(トークンの
文脈依存置換: settings.json は JSON 文字列エスケープ、justfile は Just
文字列エスケープ、Markdown は生のまま)と、bootstrap スクリプトの
`seed()` / init の workspace README シード(単純な逐次トークン置換)。

バインドトークンは `__<PREFIX>_PROJECT_TITLE__`(basename)と
`__<PREFIX>_PROJECT_PATH__`(CONTROL_ROOT からの相対パス)の 2 種のみ
(§16.1)。かつての ABS 2 種は base/overlay 分割で全廃された — マシン依存の
絶対パスは起動毎の overlay(`Core.Settings.boundSession`)の管轄であり、
テンプレに焼くものが存在しない。

IO(読み書き・アトミック置換)は `Cli/Util` 側。ここは
「テキスト + 束縛 → テキスト or 拒否」の全域関数のみを持つ。
-/

namespace Looper.Core.Render

open Looper.Core

/-- 描画モード。置換元 Python の `mode` 引数(`json` / `just` / `raw`)。 -/
inductive Mode
  | json
  | just
  | raw
deriving BEq

def Mode.parse? : String → Option Mode
  | "json" => some .json
  | "just" => some .just
  | "raw" => some .raw
  | _ => none

/-- Python `any(ord(ch) < 32 for ch in value)`。 -/
def hasControlChar (s : String) : Bool :=
  s.foldl (fun acc c => acc || c.toNat < 32) false

/-- Python `json.dumps(value, ensure_ascii=False)[1:-1]`(囲みの `"` を
剥いだ JSON 文字列エスケープ)。 -/
def jsonInner (s : String) : String :=
  (((Json.escapeString s).drop 1).dropEnd 1).toString

/-- Python `just_inner`: 制御文字を拒否し、`\` と `"` をエスケープする。 -/
def justInner (label : String) (s : String) : Except String String :=
  if hasControlChar s then
    .error s!"{label} contains a control character; refusing to render templates"
  else
    .ok ((s.replace "\\" "\\\\").replace "\"" "\\\"")

/-- 逐次トークン置換(Python の `str.replace` 連鎖と同一: リスト順に適用)。 -/
def substitute (text : String) (pairs : List (String × String)) : String :=
  pairs.foldl (fun acc (token, value) => acc.replace token value) text

/-- init のバインド描画に渡る 2 値。 -/
structure Binding where
  title : String
  rel : String

private def escaped (mode : Mode) (b : Binding) : Except String Binding :=
  match mode with
  | .json =>
    .ok { title := jsonInner b.title, rel := jsonInner b.rel }
  | .just => do
    -- Python は両値を同一ラベル "project path/title" で検証する。
    let title ← justInner "project path/title" b.title
    let rel ← justInner "project path/title" b.rel
    .ok { title, rel }
  | .raw => do
    let check (label : String) (v : String) : Except String String :=
      if hasControlChar v then
        .error s!"{label} contains a control character; refusing to render templates"
      else .ok v
    let title ← check "project title" b.title
    let rel ← check "project path" b.rel
    .ok { title, rel }

/-- バインドテンプレート描画(init スクリプト `render()` の純粋核)。
`json` モードは置換後テキストが JSON として妥当でなければ拒否する
(壊れた live settings.json を作らない)。 -/
def renderBind (d : Domain) (mode : Mode) (b : Binding) (text : String) : Except String String := do
  let e ← escaped mode b
  let out := substitute text [
    (s!"__{d.envPrefix}_PROJECT_TITLE__", e.title),
    (s!"__{d.envPrefix}_PROJECT_PATH__", e.rel)]
  if mode == .json then
    match Json.parse out with
    | .ok _ => .ok out
    | .error err => .error s!"rendered output is not valid JSON: {err}"
  else
    .ok out

/-! ## コンパイル時テスト(置換元 Python の実挙動と突合) -/

#guard jsonInner "plain" == "plain"
#guard jsonInner "a\"b\\c" == "a\\\"b\\\\c"
#guard jsonInner "日本語" == "日本語"
#guard (justInner "l" "a\\b\"c").toOption == some "a\\\\b\\\"c"
#guard (justInner "project path/title" "a\nb").isOk == false
#guard hasControlChar "tab\there" == true
#guard hasControlChar "plain ~" == false
#guard substitute "x __A__ y __A__" [("__A__", "v")] == "x v y v"
#guard substitute "__AB____B__" [("__AB__", "1"), ("__B__", "2")] == "12"
#guard (renderBind Domain.fixture .raw {title := "t", rel := "../t"}
    "T=__LOOPER_PROJECT_TITLE__ P=__LOOPER_PROJECT_PATH__").toOption
    == some "T=t P=../t"
#guard (renderBind Domain.fixture .json {title := "t\"x", rel := "../t"}
    "{\"title\": \"__LOOPER_PROJECT_TITLE__\"}").toOption
    == some "{\"title\": \"t\\\"x\"}"
#guard (renderBind Domain.fixture .json {title := "t", rel := "../t"}
    "not json __LOOPER_PROJECT_TITLE__").isOk == false
#guard (match renderBind Domain.fixture .raw {title := "bad\ntitle", rel := "../t"} "x" with
  | .error e => e == "project title contains a control character; refusing to render templates"
  | .ok _ => false)
#guard (renderBind Domain.fixture .just {title := "t", rel := "p\\q"}
    "\"__LOOPER_PROJECT_PATH__\"").toOption == some "\"p\\\\q\""

end Looper.Core.Render
