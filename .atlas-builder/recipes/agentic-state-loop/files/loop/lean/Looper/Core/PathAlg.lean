/-!
`Looper.Core.PathAlg` — 正規化済みセグメント列上のパス代数
(LEAN_MIGRATION_PLAN.md §4.3 の純粋側)。

pre_tool_guard.py のパス判定は次の 3 プリミティブに集約される。本モジュールは
それらの **字句的**(ファイルシステムに触れない)部分を Python `pathlib.PurePosixPath`
の実挙動と一致するように提供する。等価性は差分ファザーで検証済み(§31.2-12)。

1. `str(Path(raw))` — pathlib の字句正規化(guard の `path_candidates` が
   `.replace("\\", "/")` と組み合わせて使う)。`render ∘ parse` = `pureStr` が対応。
2. `Path.is_relative_to` — セグメント列の prefix 判定(guard の `_inside` と
   `path_candidates` のルート判定)。`isRelativeTo` が対応。
3. `Path.relative_to(...).as_posix()` — ルート相対の候補文字列生成。
   `relativeTo?` が対応。

pathlib 字句正規化の要点(実測で確認済み):
- 連続スラッシュは縮約。POSIX 特例で先頭のちょうど 2 本(`//a`)だけは保持
  (1 本と 3 本以上は `/`)。
- `.` セグメントは除去。**`..` は保持する**(`a/../b` → `a/../b`)。
  ここが `Core/Path.normpath`(`os.path.normpath` 互換、`..` を字句縮約)との
  本質的な違いで、guard は「resolve() しない絶対パス」を `..` 込みのまま
  prefix 判定に使うため、勝手な縮約は判定変更になる。
- 末尾スラッシュは落ちる。空文字列・`.` のみは `.`。
- `\` は通常文字(セパレータではない)。guard の候補生成はこの正規化の**後**に
  `\`→`/` 置換を行うため、`a\/b` → `a\/b` → `a//b` のような二重スラッシュ
  候補も生じ得る(パターン照合側 = Classify の関心事で、ここでは写すだけ)。

`is_relative_to` の要点: アンカー(ルートのスラッシュ本数)が一致し、かつ
相手のセグメント列が自分のセグメント列の prefix であること。`..` の解決は
行わない(`/a/../b` は `/a` の内側と判定される — guard は resolve 済みパスに
対してこれを使うので実運用では `..` は現れないが、非 resolve 経路の
`path_candidates` とバイト一致させるため Python の挙動をそのまま写す)。

`resolve()`(symlink 解決)は IO の責務で `Io/Fs` 側。
-/

namespace Looper.Core.PathAlg

/-- `PurePosixPath` の字句構造。`rootSlashes` は 0(相対)/ 1(`/`)/ 2(`//`)。 -/
structure PurePath where
  rootSlashes : Nat
  segs : List String
deriving Repr, BEq

/-- `PurePosixPath(raw)` の字句パース。空・`.` セグメントを落とし、`..` は保持。
先頭スラッシュはちょうど 2 本のときのみ 2、それ以外の 1 本以上は 1。 -/
def parse (raw : String) : PurePath :=
  let leading := (raw.toList.takeWhile (· == '/')).length
  let root := if leading == 0 then 0 else if leading == 2 then 2 else 1
  let segs := ((raw.drop leading).toString.splitOn "/").filter fun s => s != "" && s != "."
  ⟨root, segs⟩

/-- `str(PurePosixPath(...))` の再構成。ルートなし・セグメントなしは `"."`。 -/
def render (p : PurePath) : String :=
  if p.rootSlashes == 0 && p.segs.isEmpty then "."
  else String.ofList (List.replicate p.rootSlashes '/') ++ String.intercalate "/" p.segs

/-- `str(Path(raw))` 等価(字句正規化のみ)。 -/
def pureStr (raw : String) : String :=
  render (parse raw)

/-- guard `path_candidates` の生候補: `str(Path(raw)).replace("\\", "/")`。 -/
def candidate (raw : String) : String :=
  (pureStr raw).map fun c => if c == '\\' then '/' else c

/-- `PurePosixPath.is_relative_to` 等価: アンカー一致かつセグメント prefix。
等値(自分自身)も真(Python と同じ)。 -/
def isRelativeTo (p other : PurePath) : Bool :=
  p.rootSlashes == other.rootSlashes && other.segs.isPrefixOf p.segs

/-- `PurePosixPath.relative_to(other).as_posix()` 等価。`is_relative_to` が
偽なら `none`(Python の `ValueError`)。等値は `"."`。 -/
def relativeTo? (p other : PurePath) : Option String :=
  if isRelativeTo p other then
    let rest := p.segs.drop other.segs.length
    some (if rest.isEmpty then "." else String.intercalate "/" rest)
  else
    none

/-- 文字列引数の便宜形。 -/
def isRelativeToStr (p other : String) : Bool :=
  isRelativeTo (parse p) (parse other)

/-- 文字列引数の便宜形。 -/
def relativeToStr? (p other : String) : Option String :=
  relativeTo? (parse p) (parse other)

/-- `parent / rel` の str(Python `Path.__truediv__`、rel は相対前提)。
`Hook.PostTool` の表記代数と同一意味論の単一定義(live post-tool とレシピ側
`Cli/AslHook` が共有するため Core に置く、R-8)。 -/
def childPath (parent rel : String) : String :=
  let p := parse parent
  render { p with segs := p.segs ++ (parse rel).segs }

-- 字句正規化(期待値はすべて CPython 3.14 `PurePosixPath` の実測)
#guard pureStr "" == "."
#guard pureStr "." == "."
#guard pureStr ".." == ".."
#guard pureStr "a/./b" == "a/b"
#guard pureStr "a/../b" == "a/../b"
#guard pureStr "/" == "/"
#guard pureStr "//" == "//"
#guard pureStr "///" == "/"
#guard pureStr "//a" == "//a"
#guard pureStr "///a" == "/a"
#guard pureStr "a//b" == "a/b"
#guard pureStr "a/" == "a"
#guard pureStr "./a" == "a"
#guard pureStr "/a/b/" == "/a/b"
#guard pureStr "a/b/." == "a/b"
#guard pureStr "./." == "."
#guard pureStr "..." == "..."
#guard pureStr "a/..." == "a/..."
#guard pureStr "..a" == "..a"
#guard pureStr "//a//b/" == "//a/b"
#guard pureStr "/./a" == "/a"
#guard pureStr "/../a" == "/../a"
#guard pureStr "././." == "."
#guard pureStr "あ/い" == "あ/い"

-- `\` は通常文字。候補生成は正規化後に置換
#guard pureStr "a\\b" == "a\\b"
#guard pureStr "a\\/b" == "a\\/b"
#guard candidate "a\\b" == "a/b"
#guard candidate "a\\/b" == "a//b"
#guard candidate ".claude\\settings.json" == ".claude/settings.json"
#guard candidate "a/./b" == "a/b"

-- is_relative_to / relative_to
#guard isRelativeToStr "/a/b" "/a" == true
#guard isRelativeToStr "/a/b" "/" == true
#guard isRelativeToStr "/a" "/a" == true
#guard isRelativeToStr "a/b" "a" == true
#guard isRelativeToStr "a" "a/b" == false
#guard isRelativeToStr "//a" "/a" == false
#guard isRelativeToStr "/a/../b" "/a" == true
#guard isRelativeToStr "a/b" "" == true
#guard isRelativeToStr "" "a" == false
#guard isRelativeToStr "" "" == true
#guard isRelativeToStr "/a/b" "a" == false
#guard isRelativeToStr "a/b" "/" == false
#guard isRelativeToStr "/a/bc" "/a/b" == false
#guard isRelativeToStr "/a/b/c" "/a/b" == true
#guard relativeToStr? "/a/b" "/a" == some "b"
#guard relativeToStr? "/a/b" "/" == some "a/b"
#guard relativeToStr? "/a" "/a" == some "."
#guard relativeToStr? "/a/../b" "/a" == some "../b"
#guard relativeToStr? "/a/../b" "/a/.." == some "b"
#guard relativeToStr? "a/b" "" == some "a/b"
#guard relativeToStr? "" "" == some "."
#guard relativeToStr? "a" "a/b" == none
#guard relativeToStr? "/a/bc" "/a/b" == none
#guard relativeToStr? "." "." == some "."

-- childPath(Path.__truediv__)
#guard childPath "." "rel" == "rel"
#guard childPath "/" "x" == "/x"
#guard childPath "/a" ".looper/state" == "/a/.looper/state"

end Looper.Core.PathAlg
