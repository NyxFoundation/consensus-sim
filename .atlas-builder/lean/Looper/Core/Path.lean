/-!
`Looper.Core.Path` — POSIX パス文字列の純粋正規化(Python `posixpath` 互換)。

`claude_trust.py` の `display_path`(`os.path.abspath(os.path.expanduser(p))`)
を移すための最小集合。シンボリックリンクは意図的に解決しない: Claude Code が
`~/.claude.json` の `projects` キーへ保存する綴りと一致させるのが仕様であり、
`realpath` ではなく `abspath` でなければならない。

`PathAlg`(解決済みパス上の判定代数)とは役割が異なる: こちらは表記の
正規化、あちらは判定。

Python との既知の差(docstring 参照): `expanduser` の `~user` 形式は
pwd データベースを引かず、常に無展開でそのまま返す。
-/

namespace Looper.Core.Path

/-- Python `posixpath.normpath` 互換の純粋正規化。`.` 除去・`..` 縮約・
連続スラッシュ縮約(POSIX 特例: 先頭のちょうど 2 本は保持)・空入力は `"."`。
シンボリックリンクを解決しないため `..` は字句的に親を消す。 -/
def normpath (p : String) : String :=
  if p.isEmpty then "."
  else
    let initialSlashes : Nat :=
      if p.startsWith "/" then
        if p.startsWith "//" && !p.startsWith "///" then 2 else 1
      else 0
    let comps := p.splitOn "/"
    let newComps := comps.foldl (init := ([] : List String)) fun acc comp =>
      if comp == "" || comp == "." then acc
      else if comp != ".."
          || (initialSlashes == 0 && acc.isEmpty)
          || acc.getLast? == some ".." then
        acc ++ [comp]
      else if !acc.isEmpty then acc.dropLast
      else acc
    let out := String.ofList (List.replicate initialSlashes '/')
      ++ String.intercalate "/" newComps
    if out.isEmpty then "." else out

/-- Python `posixpath.expanduser` 互換の `~` 展開。`home?` は `HOME` 環境変数
(未設定なら `none` = 無展開)。`~user` 形式は Python が pwd データベースを
引くのに対し常に無展開で返す(意図差: trust 候補は絶対パスのみ
なので実行上到達しない)。 -/
def expanduser (home? : Option String) (p : String) : String :=
  if !p.startsWith "~" then p
  else
    let rest := p.drop 1
    if !rest.isEmpty && !rest.startsWith "/" then p
    else
      match home? with
      | none => p
      | some home =>
        let userhome := (home.dropEndWhile (· == '/')).toString
        let out := userhome ++ rest
        if out.isEmpty then "/" else out

/-- Python `posixpath.abspath` 互換: 相対パスは `cwd` に対して解決し、
`normpath` で正規化する(`cwd` は絶対パス前提)。 -/
def abspath (cwd : String) (p : String) : String :=
  if p.startsWith "/" then normpath p
  else normpath (cwd ++ (if cwd.endsWith "/" then "" else "/") ++ p)

/-- `claude_trust.py` の `display_path` =
`os.path.abspath(os.path.expanduser(path))`。 -/
def displayPath (home? : Option String) (cwd : String) (p : String) : String :=
  abspath cwd (expanduser home? p)

private def commonPrefixLen : List String → List String → Nat
  | a :: as, b :: bs => if a == b then commonPrefixLen as bs + 1 else 0
  | _, _ => 0

/-- Python `posixpath.relpath(path, start)` 互換の純粋核。両引数とも
`abspath` 済み(絶対・正規化済み)前提で、共通プレフィクスまで `..` で
上がってから残りを下る字句的相対化。一致は `"."`。 -/
def relpath (start target : String) : String :=
  let startList := (start.splitOn "/").filter (· ≠ "")
  let targetList := (target.splitOn "/").filter (· ≠ "")
  let common := commonPrefixLen startList targetList
  let rel := List.replicate (startList.length - common) ".." ++ targetList.drop common
  if rel.isEmpty then "." else String.intercalate "/" rel

/-! ## コンパイル時テスト(Python `posixpath` の実挙動と突合済み) -/

#guard normpath "" == "."
#guard normpath "/" == "/"
#guard normpath "//" == "//"
#guard normpath "///" == "/"
#guard normpath "/a/b/../c/./d//" == "/a/c/d"
#guard normpath "a/../../b" == "../b"
#guard normpath "/.." == "/"
#guard normpath "../.." == "../.."
#guard normpath "a/b/.." == "a"
#guard normpath "./x" == "x"
#guard expanduser (some "/home/u") "~" == "/home/u"
#guard expanduser (some "/home/u/") "~/x" == "/home/u/x"
#guard expanduser (some "/") "~" == "/"
#guard expanduser none "~/x" == "~/x"
#guard expanduser (some "/home/u") "~other/x" == "~other/x"
#guard expanduser (some "/home/u") "plain" == "plain"
#guard abspath "/cwd" "a/b" == "/cwd/a/b"
#guard abspath "/cwd" "/abs/./p" == "/abs/p"
#guard abspath "/cwd" "" == "/cwd"
#guard displayPath (some "/home/u") "/cwd" "~/w/.." == "/home/u"
#guard relpath "/ws/.looper" "/ws/my-project" == "../my-project"
#guard relpath "/a/b" "/a/b/c" == "c"
#guard relpath "/a/b" "/a/b" == "."
#guard relpath "/a/b" "/a/x/y" == "../x/y"
#guard relpath "/" "/a" == "a"
#guard relpath "/a" "/" == ".."
#guard relpath "/" "/" == "."

end Looper.Core.Path
