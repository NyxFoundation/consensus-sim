import Looper.Core.Essence

/-!
`Looper.Core.GlobHier` — ESSENCE.md の第 4 の機械可読 directive
`writable:`(META.md §11.6)の純粋核: 対象書込み許可の階層 glob 方言。

`deps:` / `recipe:` / `profile:` と同型: `semanticLines` 経由で HTML comment /
fenced code block の外にある active line だけが発効し、位置非依存。1 行に
`,` 区切りで複数パターンを書け、複数行は和集合である(§11.6-1)。

方言は §11.6-1 で閉じる: パターンは `/` 区切りのセグメント列。セグメント内の
`*` は 0 文字以上・`?` は任意 1 文字で、どちらも `/` を跨がない。セグメント
全体がちょうど `**` のときだけ 0 個以上の任意セグメント列(任意の深さ)に
一致する。文字クラス・エスケープは持たず、`a**b` の混合セグメント・空
セグメントはパース不能として**不発効**(安全側)。照合は正規化済み相対パス
全体との完全一致である。

これは許可(allow)面であり、解釈の曖昧さは「広く書込みを許す」危険方向に
倒れる。deny 用途ゆえに過剰一致を安全側とした §29.6 の制限グロブ
(`Core/Glob` — レシピ instance の deny パターン方言)とは設計根拠が逆向き
であり、判定核を共有せず import 関係も持たない。
-/

namespace Looper.Core.GlobHier

open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (pyStrip)
open Looper.Core.Essence (semanticLines)

/-- セグメント内トークン: リテラル 1 文字 / `*`(0 文字以上)/ `?`(任意
1 文字)。`/` を跨がない(跨ぐのは `deepAny` セグメントだけ)。 -/
inductive Tok where
  | lit (c : Char)
  | star
  | qmark
deriving BEq, Repr

/-- 1 セグメント: ちょうど `**`(任意深さ)か、トークン列。 -/
inductive Seg where
  | deepAny
  | plain (toks : List Tok)
deriving BEq, Repr

/-- 方言がパース不能とする文字(文字クラス・エスケープは持たない)。 -/
private def isRejectedChar (c : Char) : Bool :=
  c == '[' || c == ']' || c == '\\'

/-- 1 セグメントのパース。空セグメント・`**` を含む混合セグメント
(`a**b`・`***`)・文字クラス/エスケープ文字はパース不能(§11.6-1)。 -/
def parseSeg? (s : String) : Option Seg :=
  if s == "**" then some .deepAny
  else if s.isEmpty then none
  else if Text.containsSub s "**" then none
  else if s.toList.any isRejectedChar then none
  else some (.plain (s.toList.map fun c =>
    if c == '*' then .star else if c == '?' then .qmark else .lit c))

/-- パターン全体のパース: `/` 区切りの全セグメントがパース可能なときだけ
成立する(空パターン・絶対パス綴り・末尾 `/` は空セグメントとして不能)。 -/
def parsePattern? (pattern : String) : Option (List Seg) :=
  if pattern.isEmpty then none
  else (pattern.splitOn "/").mapM parseSeg?

/-- セグメント内照合: `*` は 0 文字以上、`?` は任意 1 文字、リテラルは
完全一致(`/` はセグメント分割済みなので現れない)。 -/
def matchToks : List Tok → List Char → Bool
  | [], [] => true
  | [], _ :: _ => false
  | .star :: ts, [] => matchToks ts []
  | .star :: ts, c :: cs => matchToks ts (c :: cs) || matchToks (.star :: ts) cs
  | .qmark :: _, [] => false
  | .qmark :: ts, _ :: cs => matchToks ts cs
  | .lit _ :: _, [] => false
  | .lit l :: ts, c :: cs => l == c && matchToks ts cs
termination_by ts cs => (ts.length, cs.length)

/-- パス全体照合: `**` セグメントだけが 0 個以上の任意セグメント列に一致し、
それ以外は 1 セグメント対 1 セグメント。正規化済み相対パス全体との完全一致
(§11.6-1 — `src/*` は `src/a/b.c` に一致しない)。 -/
def matchSegs : List Seg → List String → Bool
  | [], [] => true
  | [], _ :: _ => false
  | .deepAny :: ps, [] => matchSegs ps []
  | .deepAny :: ps, s :: ss => matchSegs ps (s :: ss) || matchSegs (.deepAny :: ps) ss
  | .plain _ :: _, [] => false
  | .plain toks :: ps, s :: ss => matchToks toks s.toList && matchSegs ps ss
termination_by ps ss => (ps.length, ss.length)

/-- 1 パターンの受理判定(パース不能は不発効 = 不受理)。 -/
def patternAccepts (pattern rel : String) : Bool :=
  match parsePattern? pattern with
  | some segs => matchSegs segs (rel.splitOn "/")
  | none => false

/-- `writable:` 許可集合の受理判定: いずれかのパターンが受理すれば許可
(複数行・複数パターンは和集合 — §11.6-1)。 -/
def grantAccepts (patterns : List String) (rel : String) : Bool :=
  patterns.any (patternAccepts · rel)

/-- `writable:` 1 行分の payload: `^[ \t>*-]*writable:[ \t]*(.+)$`
(`deps:` の `depsLinePayload?` と同じ接頭辞クラス。クラスは `w` を含まない
ため貪欲 dropWhile が唯一の分割)。 -/
private def writableLinePayload? (line : String) : Option String :=
  let rest := line.toList.dropWhile fun c =>
    c == ' ' || c == '\t' || c == '>' || c == '*' || c == '-'
  match dropLit? rest "writable:".toList with
  | none => none
  | some r =>
    let payload := r.dropWhile (fun c => c == ' ' || c == '\t')
    if payload.isEmpty then none else some (String.ofList payload)

/-- ESSENCE テキストの semantic 行(comment / fence 外)に現れる `writable:`
宣言パターンの列(出現順・生綴り)。1 行内は `,` 区切り、各要素は strip、
空要素は落とす。パース可否は分けない — 発効判定(`parsePattern?`)と
不能パターンの可視化(validate warning)の両方がこの列を消費する。 -/
def writablePatterns (text : String) : List String :=
  (semanticLines text).foldl
    (fun acc line =>
      match writableLinePayload? line with
      | none => acc
      | some payload =>
        acc ++ (payload.splitOn ",").filterMap fun raw =>
          let token := pyStrip raw
          if token.isEmpty then none else some token)
    []

/-! ## コンパイル時検査(§11.6-1 の方言の凍結) -/

-- セグメント方言
#guard parseSeg? "**" == some .deepAny
#guard parseSeg? "src" == some (.plain (['s', 'r', 'c'].map Tok.lit))
#guard parseSeg? "*" == some (.plain [.star])
#guard parseSeg? "?" == some (.plain [.qmark])
#guard parseSeg? "a*b?c" == some (.plain
  [.lit 'a', .star, .lit 'b', .qmark, .lit 'c'])
#guard parseSeg? "" == none
#guard parseSeg? "a**b" == none
#guard parseSeg? "***" == none
#guard parseSeg? "[abc]" == none
#guard parseSeg? "a\\b" == none

-- パターン方言(空・絶対綴り・末尾スラッシュ・混合セグメントは不能)
#guard (parsePattern? "src/parser/**").isSome
#guard (parsePattern? "**").isSome
#guard (parsePattern? "src/*.ts").isSome
#guard (parsePattern? "README.md").isSome
#guard parsePattern? "" == none
#guard parsePattern? "/src" == none
#guard parsePattern? "src/" == none
#guard parsePattern? "src//x" == none
#guard parsePattern? "src/a**b" == none

-- 照合: 完全一致・セグメント境界・** の任意深さ・許可面ゆえの過小一致側
#guard patternAccepts "src/parser/**" "src/parser/lex.ts" == true
#guard patternAccepts "src/parser/**" "src/parser/deep/x.ts" == true
#guard patternAccepts "src/parser/**" "src/parser" == true
#guard patternAccepts "src/parser/**" "src/parserx" == false
#guard patternAccepts "src/*" "src/a.c" == true
#guard patternAccepts "src/*" "src/a/b.c" == false
#guard patternAccepts "src/*.ts" "src/a.ts" == true
#guard patternAccepts "src/*.ts" "src/a.js" == false
#guard patternAccepts "**" "any/depth/file" == true
#guard patternAccepts "**" "top.c" == true
#guard patternAccepts "**/test.c" "a/b/test.c" == true
#guard patternAccepts "**/test.c" "test.c" == true
#guard patternAccepts "a?c" "abc" == true
#guard patternAccepts "a?c" "ac" == false
#guard patternAccepts "a?c" "a/c" == false
#guard patternAccepts "README.md" "README.md" == true
#guard patternAccepts "README.md" "sub/README.md" == false
#guard patternAccepts "src/a**b" "src/ab" == false  -- パース不能は不発効
#guard grantAccepts ["src/**", "tests/**"] "tests/x.c" == true
#guard grantAccepts ["src/**"] "docs/x.md" == false
#guard grantAccepts [] "src/x.c" == false

-- 抽出: カンマ区切り・strip・複数行の連結・comment / fence 外のみ
#guard writablePatterns "writable: src/parser/**, tests/**"
  == ["src/parser/**", "tests/**"]
#guard writablePatterns "- writable: ** " == ["**"]
#guard writablePatterns "writable: a\nwritable: b" == ["a", "b"]
#guard writablePatterns "writable:" == []
#guard writablePatterns "writable: a, , b" == ["a", "b"]
#guard writablePatterns "xwritable: a" == []
#guard writablePatterns "prose then writable: a" == []
#guard writablePatterns "<!-- writable: src/** -->" == []
#guard writablePatterns "```\nwritable: src/**\n```" == []
#guard writablePatterns "## 検証対象\nwritable: src/**\n- x" == ["src/**"]

end Looper.Core.GlobHier
