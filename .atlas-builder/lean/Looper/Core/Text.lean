import Looper.Core.Prim

/-!
`Looper.Core.Text` — state エンジンのテキスト判定群。旧 Python 実装との
等価性は差分ファザーで検証済み(§31.2-13)。

両ループ(Over-Project / In-Project)が共有する核であり、どちらのドメイン
語彙も持たない — ESSENCE 文書の解析は `Core.Essence`(L1a)にある。

CPython 意味論の実測に基づく互換プリミティブ(すべて実測で固定):
- `isPySpace` — `str.isspace()` と `re` の `\s`(unicode)は同一集合
  (U+0009–000D・001C–001F・0020・0085・00A0・1680・2000–200A・2028・2029・
  202F・205F・3000)。
- `splitLinesPy` — `str.splitlines()` の境界 10 種
  (U+000A–000D・001C–001E・0085・2028・2029、`\r\n` は 1 境界)。
  U+001F・00A0 は空白だが行境界ではない。
- `pyStrip` / `normalizeWs` — `str.strip()` / `" ".join(s.split())`。

裁定済み方言差(§31 参照。いずれも guard の deny 経路に不関与):
- 十進数字は ASCII `0-9` のみ受理する。Python の `\d`・`int()` は Unicode Nd
  (アラビア数字等)も受理するが、Lean 側は list item マーカーと recipe
  pointer の major で非 ASCII 数字を不成立に倒す(項目抽出は prose 行として
  全文を拾う側へ、pointer は不認識側へ)。
- `lowerChar` は Unicode simple lowercase のうち ASCII・Latin-1
  (U+00C0–00DE、×U+00D7 除く)・キリル基本域(U+0400–042F)のみ実装する。
  ギリシャ文字(最終シグマの文脈規則)・Latin Extended-A(İ の多文字化)等は
  無変換。唯一の消費者である類似判定は advisory であり判定に不関与。
-/

namespace Looper.Core.Text

open Looper.Core.Prim (dropLit? digitsToNat)

/-- Python `str.isspace()`(= `re` の `\s`。CPython 3.14 実測で同一集合)。 -/
def isPySpace (c : Char) : Bool :=
  (0x09 ≤ c.val && c.val ≤ 0x0D) || c.val == 0x20
    || (0x1C ≤ c.val && c.val ≤ 0x1F)
    || c.val == 0x85 || c.val == 0xA0 || c.val == 0x1680
    || (0x2000 ≤ c.val && c.val ≤ 0x200A)
    || c.val == 0x2028 || c.val == 0x2029 || c.val == 0x202F
    || c.val == 0x205F || c.val == 0x3000

/-- Python `str.splitlines()` の行境界(実測 10 種)。U+001F・00A0 は空白だが
行境界ではない点が `isPySpace` と異なる。 -/
def isLineBoundary (c : Char) : Bool :=
  (0x0A ≤ c.val && c.val ≤ 0x0D)
    || c.val == 0x1C || c.val == 0x1D || c.val == 0x1E
    || c.val == 0x85 || c.val == 0x2028 || c.val == 0x2029

private def splitLinesAux : List Char → List Char → List String
  | [], acc => if acc.isEmpty then [] else [String.ofList acc.reverse]
  | '\r' :: '\n' :: rest, acc => String.ofList acc.reverse :: splitLinesAux rest []
  | c :: rest, acc =>
    if isLineBoundary c then String.ofList acc.reverse :: splitLinesAux rest []
    else splitLinesAux rest (c :: acc)

/-- `str.splitlines()` 等価(keepends=False)。末尾境界は空行を生まない
(`"a\n"` → `["a"]`)。 -/
def splitLinesPy (s : String) : List String :=
  splitLinesAux s.toList []

private def splitLinesBashAux : List Char → List Char → List String
  | [], acc => if acc.isEmpty then [] else [String.ofList acc.reverse]
  | '\n' :: rest, acc => String.ofList acc.reverse :: splitLinesBashAux rest []
  | c :: rest, acc => splitLinesBashAux rest (c :: acc)

/-- **Bash** の行境界(`\n` = 0x0A のみ)で分割する。`str.splitlines()` と違い
`\x0b` `\x0c` `\x1c`〜`\x1e` `\x85` U+2028/2029 や単独 `\r` を境界にしない —
これらは Python が「行境界」と数える一方、bash は 1 コマンド行の内側の
ただの文字として扱う。末尾境界は空行を生まない(`"a\n"` → `["a"]`、
keepends=False)。heredoc 検出はこちらを使う: Python splitlines で header を
切ると、bash がまだ line 1 に載せている `<<'EOF'\x0b; rm ...` の後半が
「別の行」に見え、header の fullmatch を通過して `;` 以降の注入コマンドが
allow されていた(I-022/I-027 の read-only 封じ込め破れ、2026-07-27)。 -/
def splitLinesBash (s : String) : List String :=
  splitLinesBashAux s.toList []

/-- `str.strip()` 等価。 -/
def pyStrip (s : String) : String :=
  String.ofList (((s.toList.dropWhile isPySpace).reverse.dropWhile isPySpace).reverse)

private def runsAux (p : Char → Bool) : List Char → List Char → List (List Char)
  | [], acc => if acc.isEmpty then [] else [acc.reverse]
  | c :: cs, acc =>
    if p c then runsAux p cs (c :: acc)
    else if acc.isEmpty then runsAux p cs []
    else acc.reverse :: runsAux p cs []

/-- `p` を満たす文字の極大 run の列。 -/
def runsOf (p : Char → Bool) (s : String) : List (List Char) :=
  runsAux p s.toList []

/-- 引数なし `str.split()` 等価(空白 run で分割、空要素なし)。 -/
def pySplitWs (s : String) : List String :=
  (runsOf (fun c => !isPySpace c) s).map String.ofList

/-- `" ".join(s.split())` 等価(`_texts_relate` の空白正規化)。 -/
def normalizeWs (s : String) : String :=
  String.intercalate " " (pySplitWs s)

/-- Python `str.lower()` の simple mapping 部分実装: ASCII・Latin-1
(U+00C0–00DE、U+00D7 × を除く)・キリル(U+0400–040F は +0x50、
U+0410–042F は +0x20)。他域は無変換(モジュール頭注の裁定参照)。 -/
def lowerChar (c : Char) : Char :=
  let v := c.val
  if 0x41 ≤ v && v ≤ 0x5A then Char.ofNat (v.toNat + 0x20)
  else if 0xC0 ≤ v && v ≤ 0xDE && v != 0xD7 then Char.ofNat (v.toNat + 0x20)
  else if 0x400 ≤ v && v ≤ 0x40F then Char.ofNat (v.toNat + 0x50)
  else if 0x410 ≤ v && v ≤ 0x42F then Char.ofNat (v.toNat + 0x20)
  else c

/-- `str.lower()` の部分実装(`lowerChar` 参照)。 -/
def lowerStr (s : String) : String :=
  s.map lowerChar

/-- Python `needle in hay`(部分文字列)。 -/
def containsSub (hay needle : String) : Bool :=
  if needle.isEmpty then true else (hay.splitOn needle).length > 1

private def dedupAux : List String → List String → List String
  | [], _ => []
  | x :: xs, seen =>
    if seen.contains x then dedupAux xs seen else x :: dedupAux xs (x :: seen)

/-- 先頭出現順を保つ重複排除(Python の set 相当。集合演算にのみ使う)。 -/
def dedup (l : List String) : List String :=
  dedupAux l []

/-! ## 端末表示幅(watch の表示専用近似、META.md §15.3) -/

/-- 端末表示幅の近似: East Asian Wide / Fullwidth の主要レンジ + 絵文字
ブロックを 2、それ以外を 1 と数える。曖昧幅(East Asian Ambiguous — 罫線
`─` 等)は端末既定に合わせて 1 に倒す。canonical 状態には現れない表示専用の
近似であり、判定には使わない。 -/
def charDisplayWidth (c : Char) : Nat :=
  let n := c.toNat
  if (0x1100 ≤ n && n ≤ 0x115F)      -- Hangul Jamo
      || (0x2E80 ≤ n && n ≤ 0x303E)  -- CJK 部首〜記号(罫線 U+25xx は含まない)
      || (0x3041 ≤ n && n ≤ 0x33FF)  -- かな〜CJK 互換
      || (0x3400 ≤ n && n ≤ 0x4DBF)  -- CJK 拡張 A
      || (0x4E00 ≤ n && n ≤ 0x9FFF)  -- CJK 統合漢字
      || (0xA000 ≤ n && n ≤ 0xA4CF)  -- Yi
      || (0xAC00 ≤ n && n ≤ 0xD7A3)  -- Hangul 音節
      || (0xF900 ≤ n && n ≤ 0xFAFF)  -- CJK 互換漢字
      || (0xFE30 ≤ n && n ≤ 0xFE4F)  -- CJK 互換形
      || (0xFF00 ≤ n && n ≤ 0xFF60)  -- 全角形
      || (0xFFE0 ≤ n && n ≤ 0xFFE6)  -- 全角記号
      || (0x1F000 ≤ n && n ≤ 0x1FAFF) -- 絵文字ブロック近似
      || (0x20000 ≤ n && n ≤ 0x3FFFD) -- CJK 拡張 B〜
  then 2
  else 1

def displayWidth (s : String) : Nat :=
  s.foldl (fun acc c => acc + charDisplayWidth c) 0

/-- 幅 `budget` に収まる最長プレフィクス(最初に収まらない文字で打ち切る —
以降に細い文字があっても「プレフィクス」を保つ)。 -/
def takeDisplayPrefix : Nat → List Char → List Char
  | _, [] => []
  | budget, c :: rest =>
    let w := charDisplayWidth c
    if w ≤ budget then c :: takeDisplayPrefix (budget - w) rest else []

/-- 表示幅 `w` 以内への決定的切り詰め: 収まるならそのまま、超過は幅 `w-1`
以内の最長プレフィクス + `…`(「cols 超過直前で切る」規則)。全角境界では
結果幅が `w-1` になり得る(呼び出し側がパディングで揃える)。 -/
def truncateDisplay (w : Nat) (s : String) : String :=
  if w == 0 then ""
  else if displayWidth s ≤ w then s
  else String.ofList (takeDisplayPrefix (w - 1) s.toList) ++ "…"

/-! ## コンパイル時検査(期待値はすべて CPython 3.14 実測) -/

-- 互換プリミティブ
#guard splitLinesPy "" == []
#guard splitLinesPy "a" == ["a"]
#guard splitLinesPy "a\n" == ["a"]
#guard splitLinesPy "a\r\nb\rc\nd" == ["a", "b", "c", "d"]
#guard splitLinesPy "a\n\nb" == ["a", "", "b"]
#guard splitLinesPy "a bc\x0cd" == ["a", "b", "c", "d"]
#guard splitLinesPy "a\x1cb\x1fc" == ["a", "b\x1fc"]
-- splitLinesBash: 境界は `\n` のみ(bash 意味論)。Python が行境界にする
-- `\x0b` `\x0c` `\x1c`〜`\x1e` `\x85` U+2028/2029 や単独 `\r` は 1 行の内側。
#guard splitLinesBash "" == []
#guard splitLinesBash "a\nb\nEOF\n" == ["a", "b", "EOF"]
#guard splitLinesBash "a\n" == ["a"]
#guard splitLinesBash "cat<<'EOF'\x0b; rm\nbody\nEOF" == ["cat<<'EOF'\x0b; rm", "body", "EOF"]
#guard splitLinesBash "a\x0cb\rc" == ["a\x0cb\rc"]
#guard splitLinesBash "a\r\nb" == ["a\r", "b"]
#guard pyStrip " 　a b\t" == "a b"
#guard normalizeWs " a\tb　 c " == "a b c"
#guard lowerStr "Épreuve" == "épreuve"
#guard lowerStr "ПРОВЕРКА Ёж" == "проверка ёж"
#guard lowerStr "ß×Þ" == "ß×þ"
#guard containsSub "abc" "bc" == true
#guard containsSub "abc" "" == true
#guard containsSub "ab" "abc" == false

-- displayWidth / truncateDisplay(watch の表示規則、§15.3)
#guard displayWidth "abc" == 3
#guard displayWidth "日本語" == 6
#guard displayWidth "ワタシA1" == 8
#guard displayWidth "─" == 1          -- 罫線は幅 1(曖昧幅は 1 に倒す)
#guard displayWidth "…" == 1
#guard displayWidth "·" == 1
#guard truncateDisplay 5 "hello" == "hello"
#guard truncateDisplay 4 "hello" == "hel…"
#guard truncateDisplay 6 "日本語" == "日本語"
#guard truncateDisplay 5 "日本語" == "日本…"  -- 幅 4 まで + …
#guard truncateDisplay 4 "日本語" == "日…"    -- 全角境界: 結果幅 3(< 4)
#guard truncateDisplay 1 "ab" == "…"
#guard truncateDisplay 0 "ab" == ""
#guard truncateDisplay 3 "" == ""

end Looper.Core.Text
