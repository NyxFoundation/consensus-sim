/-!
`Looper.Core.Glob` — レシピ instance のユーザー定義 deny パターン方言
「制限グロブ」の判定核(META.md §29.6 が仕様の正本)。

方言(§29.6 の要約):
- パターンは「リテラル文字」「`*`(0 文字以上の任意の文字列。`/`・空白・
  改行も跨ぐ)」「先頭の `^`(被検査文字列の先頭に固定)」「末尾の `$`
  (末尾に固定)」だけからなる。大文字小文字は区別する。
- 一致は部分一致(search)意味論: アンカーが無ければ被検査文字列の
  どこかにパターン全体が一致すれば成立。旧 `re.search` と同じ向き。
- 先頭以外の `^`・末尾以外の `$` はリテラル。エスケープ機構は持たない
  (リテラルの `*`・先頭リテラル `^`・末尾リテラル `$` は表現不可。
  deny 用途では `*` の過剰一致が安全側)。
- 空パターン `""` は全文字列に一致する(旧 `re.search("")` と同じ)。

形式定義(META.md §29.6): 本体(アンカーを剥いだ残り)を `*` で分割した
リテラル片 c₀..cₙ が、この順で互いに重ならずに被検査文字列中に出現し、
anchorStart なら c₀ が先頭に、anchorEnd なら cₙ が末尾に一致すること。

実装は leftmost-greedy(各片を可能な最左位置に置き、末尾アンカー片のみ
suffix 判定)。この形のパターン族(リテラル片を `.*` で繋いだ列)に対して
leftmost-greedy は完全 — 先行片を最左に置くことは後続片の探索領域を最大化
するため、どこかに配置が存在すれば greedy でも成立する。等価性は方言の
Python 参照実装(`re.escape` 片を `.*` で結合し `\A`/`\Z` を付ける regex
翻訳)との差分ファザーで相互検証済み — バックトラック regex と greedy 実装の
受理同値(§31.2-27)。

`legacySignals` は旧方言(Python regex)の兆候検出で、doctor / レシピ state
validate の移行警告(advisory)に使う。`.`(regex の任意 1 文字)と反復
`*` は新方言のリテラル / ワイルドカードと字面で区別できないため検出対象外
(§29.6 の変換表が案内する既知の限界)。リテラル `?` 等の偽陽性は
advisory warning として許容する。
-/

namespace Looper.Core.Glob

/-- 解析済みパターン。`chunks` は本体を `*` で分割したリテラル片
(`String.splitOn "*"` と同じ境界規約: 空本体は `[[]]`、`"a**b"` は
`[[a],[],[b]]`。空片はどこでも自明に一致する)。 -/
structure Pattern where
  anchorStart : Bool
  anchorEnd : Bool
  chunks : List (List Char)
  deriving Repr, DecidableEq

private def splitOnStarAux : List Char → List Char → List (List Char)
  | [], acc => [acc.reverse]
  | '*' :: rest, acc => acc.reverse :: splitOnStarAux rest []
  | c :: rest, acc => splitOnStarAux rest (c :: acc)

/-- パターン文字列の解析。先頭の `^` と末尾の `$` だけをアンカーとして
剥がし、残りを `*` で分割する。失敗しない(全文字列が well-formed)。 -/
def parse (pattern : String) : Pattern :=
  let cs := pattern.toList
  let (anchorStart, cs) :=
    match cs with
    | '^' :: rest => (true, rest)
    | _ => (false, cs)
  let (anchorEnd, body) :=
    match cs.reverse with
    | '$' :: rrest => (true, rrest.reverse)
    | _ => (false, cs)
  { anchorStart, anchorEnd, chunks := splitOnStarAux body [] }

/-- `needle` の `hay` 中の最左出現を探し、一致直後の残りを返す。
空 `needle` は位置 0 で一致する。 -/
private def findChunk (needle : List Char) : List Char → Option (List Char)
  | [] => if needle.isEmpty then some [] else none
  | hay@(_ :: rest) =>
    if needle.isPrefixOf hay then some (hay.drop needle.length)
    else findChunk needle rest

/-- 先頭片を配置済みの残り `rem` に対し、残る片列を順に最左配置する。
最終片だけは `anchorEnd` のとき suffix 判定(配置済み領域と重ならない
ことは `isSuffixOf` の長さ条件が同時に保証する)。 -/
private def matchAfter (anchorEnd : Bool) : List Char → List (List Char) → Bool
  | rem, [] => !anchorEnd || rem.isEmpty
  | rem, [c] =>
    if anchorEnd then c.isSuffixOf rem
    else (findChunk c rem).isSome
  | rem, c :: rest =>
    match findChunk c rem with
    | none => false
    | some rem' => matchAfter anchorEnd rem' rest

/-- 解析済みパターンによる判定(§29.6 の形式定義)。 -/
def Pattern.accepts (p : Pattern) (subject : String) : Bool :=
  let s := subject.toList
  match p.chunks with
  | [] =>
    -- parse は空 chunks を作らない(空本体でも `[[]]`)。防御のみ。
    !(p.anchorStart && p.anchorEnd) || s.isEmpty
  | c :: rest =>
    if p.anchorStart then
      c.isPrefixOf s && matchAfter p.anchorEnd (s.drop c.length) rest
    else
      matchAfter p.anchorEnd s (c :: rest)

/-- パターン文字列 `pattern` が `subject` に一致するか(解析 + 判定)。 -/
def accepts (pattern subject : String) : Bool :=
  (parse pattern).accepts subject

/-- 旧方言(Python regex)の兆候となるメタ文字。`.` と反復 `*` は対象外
(モジュール頭注)。 -/
private def legacyMeta : List Char := ['\\', '(', ')', '[', ']', '{', '}', '+', '?', '|']

private def legacySignalsAux (n : Nat) : Nat → List Char → List String → List String
  | _, [], acc => acc.reverse
  | i, c :: rest, acc =>
    let sig? : Option String :=
      if legacyMeta.contains c then some c.toString
      else if c == '^' && i != 0 then some "^ (not at start)"
      else if c == '$' && i + 1 != n then some "$ (not at end)"
      else none
    match sig? with
    | some sig =>
      legacySignalsAux n (i + 1) rest (if acc.contains sig then acc else sig :: acc)
    | none => legacySignalsAux n (i + 1) rest acc

/-- パターン中の旧 regex 方言の兆候を初出順(重複なし)で返す。
検出: `\ ( ) [ ] { } + ? |` のいずれか、先頭以外の `^`、末尾以外の `$`。
空リスト = 兆候なし。警告文の組み立ては消費側の責務。 -/
def legacySignals (pattern : String) : List String :=
  let cs := pattern.toList
  legacySignalsAux cs.length 0 cs []

/-- 旧 regex 方言の疑いがあるか(doctor / validate の advisory 警告用)。 -/
def looksLegacy (pattern : String) : Bool :=
  !(legacySignals pattern).isEmpty

-- 判定: リテラル部分一致(search 意味論)
#guard accepts "foo" "xfooy" = true
#guard accepts "foo" "foo" = true
#guard accepts "foo" "fo" = false
#guard accepts "foo" "" = false
#guard accepts "state/" "loop/state/x.json" = true

-- 判定: アンカー
#guard accepts "^foo" "foobar" = true
#guard accepts "^foo" "xfoo" = false
#guard accepts "foo$" "xfoo" = true
#guard accepts "foo$" "foox" = false
#guard accepts "^foo$" "foo" = true
#guard accepts "^foo$" "foox" = false
#guard accepts "^foo$" "xfoo" = false

-- 判定: `*`(`/`・空白・改行を跨ぐ)
#guard accepts "a*b" "ab" = true
#guard accepts "a*b" "axxb" = true
#guard accepts "a*b" "a/x\ny b" = true
#guard accepts "a*b" "ba" = false
#guard accepts "a**b" "axb" = true
#guard accepts "a*b*c" "aXbYc" = true
#guard accepts "a*b*c" "acb" = false
#guard accepts "^a*b$" "a...b" = true
#guard accepts "^a*b$" "a...bx" = false

-- 判定: 重なり禁止(片は順に、互いに重ならず出現する)
#guard accepts "a*a" "a" = false
#guard accepts "a*a" "aa" = true
#guard accepts "^ab*b$" "ab" = false
#guard accepts "^ab*b$" "abb" = true

-- 判定: 空パターン・アンカーのみ・`*` のみ
#guard accepts "" "anything" = true
#guard accepts "" "" = true
#guard accepts "^" "x" = true
#guard accepts "$" "x" = true
#guard accepts "^$" "" = true
#guard accepts "^$" "x" = false
#guard accepts "*" "" = true
#guard accepts "^*$" "xyz" = true

-- 判定: 先頭以外の `^`・末尾以外の `$` はリテラル
#guard accepts "a^b" "xa^by" = true
#guard accepts "a^b" "xaby" = false
#guard accepts "a$b" "a$b" = true
#guard accepts "$a" "x$a" = true
#guard accepts "$a" "xa" = false
#guard accepts "^^" "^x" = true
#guard accepts "^^" "x^" = false
#guard accepts "$$" "x$" = true
#guard accepts "$$" "$x" = false

-- 判定: Unicode(コードポイント粒度)
#guard accepts "日*語" "日本語" = true
#guard accepts "café$" "un café" = true
#guard accepts "^日本$" "日本語" = false

-- 変換表の代表形(META.md §29.6): `(^|/)secrets/` → 2 本に展開
#guard accepts "^secrets/" "secrets/key" = true
#guard accepts "/secrets/" "config/secrets/key" = true
#guard accepts "^secrets/" "config/secrets/key" = false
#guard accepts ".env$" "proj/.env" = true
#guard accepts ".env." "proj/.env.local" = true

-- 旧方言検出
#guard legacySignals "(^|/)secrets/" = ["(", "^ (not at start)", "|", ")"]
#guard legacySignals "\\bgit\\s+add\\b" = ["\\", "+"]
#guard legacySignals "config/credentials\\.json$" = ["\\"]
#guard legacySignals "^foo*bar$" = []
#guard legacySignals "" = []
#guard legacySignals "^" = []
#guard legacySignals "$" = []
#guard legacySignals "a$b" = ["$ (not at end)"]
#guard legacySignals "[0-9]+" = ["[", "]", "+"]
#guard looksLegacy "\\.env($|\\.)" = true
#guard looksLegacy "^secrets/" = false

end Looper.Core.Glob
