import Looper.Core.Prim
import Looper.Core.Text

/-!
`Looper.Core.Frag` — 断片マッチャと検索プリミティブの単一定義点。

正規表現エンジンを持たない方針(§31.1 R-5)の下で、guard 系分類
(`Core.Classify.Bash`)とレシピエンジン(`Asl.Hooks`)が共有する
ドメイン非依存の下部プリミティブ。`Core.Prim` の `dropLit?` と同じ
「各モジュールの private 重複を単一定義へ収斂させる」層に属する。

`\b` の語クラスは ASCII 方言(`isAsciiWord` — 裁定は各消費モジュールの
頭注、R-6 の deny/ask 拡大方向)。
-/

namespace Looper.Core.Frag

open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (isPySpace)

/-- パターン断片: 入力接尾辞の先頭でマッチを試み、消費後の残りを返す。 -/
abbrev Frag := List Char → Option (List Char)

/-- リテラル断片。 -/
def lit (l : String) : Frag := fun cs => dropLit? cs l.toList

/-- 代替(いずれかの断片が成立)。受理判定のみに使うため順序は自由。 -/
def alts (ps : List Frag) : Frag := fun cs =>
  ps.foldl (fun acc p => acc <|> p cs) none

/-- 1 文字クラス断片。 -/
def cls (p : Char → Bool) : Frag
  | c :: rest => if p c then some rest else none
  | _ => none

/-- `\s+`(Python `\s` = `isPySpace`)。貪欲消費 — 全消費モジュールの用途で
直後に非空白開始の断片が続くため、貪欲一致が唯一の分割になる。 -/
def ws1 : Frag
  | c :: rest => if isPySpace c then some (rest.dropWhile isPySpace) else none
  | _ => none

/-- Python `\b` の語クラス(ASCII 方言)。 -/
def isAsciiWord (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_'

/-- 末尾側 `\b`(直前が語構成文字である文脈専用)。消費ゼロ。マッチ末尾文字が
word なら次が非 word / 末尾、非 word なら次が word、の一般規則のうち
「末尾文字 word」側 — 消費モジュールの全 `\b` は語構成文字直後に置かれる。 -/
def wordEnd : Frag
  | [] => some []
  | c :: rest => if isAsciiWord c then none else some (c :: rest)

def boundaryBefore : Option Char → Bool
  | none => true
  | some c => !isAsciiWord c

/-- 各開始位置の(直前文字, 接尾辞)。末尾の空接尾辞位置を含む。 -/
def positions (s : String) : List (Option Char × List Char) :=
  go none s.toList
where
  go (prev : Option Char) : List Char → List (Option Char × List Char)
    | [] => [(prev, [])]
    | c :: rest => (prev, c :: rest) :: go (some c) rest

/-- `re.search(frag, s)`(アンカーなし)。 -/
def search (p : Frag) (s : String) : Bool :=
  (positions s).any fun (_, sfx) => (p sfx).isSome

/-- `re.search(r"\b" ++ frag, s)`(frag は語構成文字で始まる — 先頭 `\b`)。 -/
def searchAtBoundary (p : Frag) (s : String) : Bool :=
  (positions s).any fun (prev, sfx) => boundaryBefore prev && (p sfx).isSome

/-- `re.search(r"(^|[cls])" ++ frag, s)` 等価(クラス文字は消費される)。 -/
def searchPrefixed (clsP : Char → Bool) (p : Frag) (s : String) : Bool :=
  (p s.toList).isSome || search (cls clsP >=> p) s

end Looper.Core.Frag
