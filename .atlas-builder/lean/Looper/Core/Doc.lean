import Looper.Core.Json
import Looper.Core.Text

/-!
`Looper.Core.Doc` — JSON / JSONL 文書の寛容デコードと Python 互換の数値変換(純粋)。

置換元は `state.py` の読み込みヘルパー群(`read_json_or_empty` /
`read_jsonl_or_empty` / `object_items`)と Python 組み込みの暗黙変換
(`int(x)` / truthiness / 比較)。JSON → モデルのデコードは現行 Python の
寛容さをそのまま写す(LEAN_MIGRATION_PLAN.md §4.5 — 勝手な厳格化は
deny 拡大ではなく挙動変更なので行わない)。

IO シェルは「ファイルが存在したか・読めたか・中身」だけを `RawFile` として
渡し、パース・診断文言の組み立てはすべて本モジュール以降の純粋側で行う
(§31.4-2 注入原則)。診断文言は state.py と同一プレフィクスに揃える —
括弧内の例外詳細のみ Python 例外文字列と一致しない(§5.3 の
「人間向け文言のみの差」として許容し、消費側はプレフィクスと reasons
だけを読む)。

両ループ(Over-Project / In-Project)が共有する核であり、どちらのドメイン
語彙も持たない。
-/

namespace Looper.Core.Doc

/-- ファイル読み取りの結果(IO シェルが組み立てる)。Python の
`path.is_file()` 分岐 + `open()`/`read()` の OSError に対応する。
パースは持たない — それは純粋側の仕事。 -/
inductive RawFile where
  | absent
  | text (contents : String)
  | ioError (msg : String)
  deriving BEq

/-- Python `read_json_or_empty`: 読めない・パース不能・トップレベル非 object は
診断 1 件と空 object。`.absent` は Python 側では `is_file()` ガードで
到達しない経路なので、診断なしの空 object(呼び出し側の
`if path.is_file() else {}` と同じ値)に写す。 -/
def readJsonOrEmpty (name : String) : RawFile → Json.Value × Option String
  | .absent => (.obj [], none)
  | .ioError e => (.obj [], some s!"{name}: unreadable JSON ({e})")
  | .text contents =>
    match Json.parse contents with
    | .error e => (.obj [], some s!"{name}: unreadable JSON ({e})")
    | .ok (.obj entries) => (.obj entries, none)
    | .ok _ => (.obj [], some s!"{name}: top-level value is not an object")

/-- Python `read_jsonl`: universal-newlines 分割 → `strip()` → 空行スキップ →
各行 `json.loads`。1 行でも不正なら全体がエラー(Python は最初の
JSONDecodeError で中断する)。 -/
def parseJsonl (contents : String) : Except String (List Json.Value) :=
  go (Text.splitLinesPy contents) []
where
  go : List String → List Json.Value → Except String (List Json.Value)
    | [], acc => .ok acc.reverse
    | line :: rest, acc =>
      let line := Text.pyStrip line
      if line.isEmpty then go rest acc
      else
        match Json.parse line with
        | .ok v => go rest (v :: acc)
        | .error e => .error e

/-- Python `read_jsonl_or_empty`: 読めない・パース不能は診断 1 件と空リスト。
`.absent` は `read_jsonl` の `is_file()` 早期 return(診断なしの空)。 -/
def readJsonlOrEmpty (name : String) : RawFile → List Json.Value × Option String
  | .absent => ([], none)
  | .ioError e => ([], some s!"{name}: unreadable JSONL ({e})")
  | .text contents =>
    match parseJsonl contents with
    | .ok records => (records, none)
    | .error e => ([], some s!"{name}: unreadable JSONL ({e})")

/-- Python `object_items`: list の中の dict だけを残す。list 以外は空。 -/
def objectItems : Json.Value → List Json.Value
  | .arr items => items.filter fun | .obj _ => true | _ => false
  | _ => []

/-- Python `is_non_empty_string`: str かつ `strip()` 非空。 -/
def isNonEmptyString : Json.Value → Bool
  | .str s => !(Text.pyStrip s).isEmpty
  | _ => false

private def digitsWithUnderscores : List Char → Option (List Char)
  | [] => none
  | cs => go cs false []
where
  go : List Char → Bool → List Char → Option (List Char)
    | [], _, acc => if acc.isEmpty then none else some acc.reverse
    | '_' :: rest, prevDigit, acc =>
      -- アンダースコアは数字と数字の間に単独でのみ許される(int("1_0") = 10)
      if prevDigit then
        match rest with
        | c :: _ => if c.isDigit then go rest false acc else none
        | [] => none
      else none
    | c :: rest, _, acc =>
      if c.isDigit then go rest true (c :: acc) else none

/-- Python `int(s)`(文字列引数): 前後空白を除き、任意個の符号は 1 個まで、
数字列(数字間の単独アンダースコア許容)。それ以外は ValueError = `none`。 -/
def pyIntOfString? (s : String) : Option Int := do
  let (neg, digits) ←
    match (Text.pyStrip s).toList with
    | '-' :: rest => some (true, rest)
    | '+' :: rest => some (false, rest)
    | rest => some (false, rest)
  let ds ← digitsWithUnderscores digits
  let n := ds.foldl (fun acc c => acc * 10 + (c.toNat - '0'.toNat)) 0
  pure (if neg then -(Int.ofNat n) else Int.ofNat n)

/-- Python `int(x)` の JSON 値版: bool は 0/1、整数はそのまま、小数はゼロ方向
切り捨て、文字列は整数リテラルのみ。null / 配列 / object は
TypeError = `none`(呼び出し側が None 分岐を先に済ませている場合を除く)。 -/
def pyInt? : Json.Value → Option Int
  | .bool b => some (if b then 1 else 0)
  | .num m 0 => some m
  | .num m e => some (Int.tdiv m (Int.ofNat (10 ^ e)))  -- int(x) はゼロ方向切り捨て
  | .str s => pyIntOfString? s
  | _ => none

/-- Python の数値比較 `a >= b`(int / float / bool 混在可)を
`mantissa / 10^exponent` 表現上で行う: `m₁·10^e₂ ≥ m₂·10^e₁`。 -/
def numGE (m1 : Int) (e1 : Nat) (m2 : Int) (e2 : Nat) : Bool :=
  m1 * Int.ofNat (10 ^ e2) ≥ m2 * Int.ofNat (10 ^ e1)

/-- Python の数値比較 `a == b`(int / float / bool 混在可)。`numGE` と同じ
交差乗算で行う: `m₁·10^e₂ = m₂·10^e₁`。 -/
def numEq (m1 : Int) (e1 : Nat) (m2 : Int) (e2 : Nat) : Bool :=
  m1 * Int.ofNat (10 ^ e2) == m2 * Int.ofNat (10 ^ e1)

/-- Python `a >= b` の JSON 値版。数値同士(bool 含む)と文字列同士だけを
定義し、それ以外の組は TypeError = `none`(should-reset ではハードエラー
exit 2 に写る)。Python は list 同士等も比較できるが、counters/policy に
現れた時点で別の TypeError より先に形状が破綻しているため対象外。
文字列比較はコードポイント辞書順 — UTF-8 バイト順と一致するので
Lean の `String` 比較をそのまま使える。 -/
def pyGE? : Json.Value → Json.Value → Option Bool
  | .num m1 e1, .num m2 e2 => some (numGE m1 e1 m2 e2)
  | .bool b1, .num m2 e2 => some (numGE (if b1 then 1 else 0) 0 m2 e2)
  | .num m1 e1, .bool b2 => some (numGE m1 e1 (if b2 then 1 else 0) 0)
  | .bool b1, .bool b2 => some (numGE (if b1 then 1 else 0) 0 (if b2 then 1 else 0) 0)
  | .str s1, .str s2 => some (s1 ≥ s2)
  | _, _ => none

/-! ## コンパイル時テスト -/

-- readJsonOrEmpty: 非 object トップレベル・パース不能・absent
#guard (readJsonOrEmpty "x.json" (.text "[1]")).2
    == some "x.json: top-level value is not an object"
#guard (readJsonOrEmpty "x.json" (.text "{\"a\": 1}")).2 == none
#guard (readJsonOrEmpty "x.json" .absent) == (.obj [], none)
#guard (readJsonOrEmpty "x.json" (.text "{broken")).2.isSome

-- parseJsonl: 空行スキップ・CRLF・不正行
#guard (parseJsonl "{\"a\": 1}\r\n\n {\"b\": 2} \n").toOption.map (·.length) == some 2
#guard (parseJsonl "").toOption == some []
#guard (parseJsonl "{}\nbroken\n").isOk == false

-- objectItems: dict のみ抽出
#guard (objectItems (.arr [.obj [], .num 1 0, .str "x", .obj [("a", .null)]])).length == 2
#guard objectItems (.obj [("items", .arr [])]) == []

-- pyInt?: bool / int / float 切り捨て(ゼロ方向)/ 文字列 / 拒否側
#guard pyInt? (.bool true) == some 1
#guard pyInt? (.num 42 0) == some 42
#guard pyInt? (.num 39 1) == some 3        -- int(3.9) = 3
#guard pyInt? (.num (-39) 1) == some (-3)  -- int(-3.9) = -3(ゼロ方向)
#guard pyInt? (.str " +3 ") == some 3
#guard pyInt? (.str "1_0") == some 10
#guard pyInt? (.str "three") == none
#guard pyInt? (.str "3.5") == none
#guard pyInt? (.str "_1") == none
#guard pyInt? (.str "1_") == none
#guard pyInt? (.str "1__0") == none
#guard pyInt? (.str "") == none
#guard pyInt? (.str "-") == none
#guard pyInt? .null == none
#guard pyInt? (.arr []) == none

-- pyGE?: 数値混在・文字列同士・型不一致
#guard pyGE? (.num 8 1) (.num 8 1) == some true          -- 0.8 >= 0.8
#guard pyGE? (.num 79 2) (.num 8 1) == some false        -- 0.79 >= 0.8
#guard pyGE? (.bool true) (.num 8 1) == some true        -- True >= 0.8
#guard pyGE? (.num 3 0) (.num 25 1) == some true         -- 3 >= 2.5
#guard pyGE? (.str "b") (.str "a") == some true
#guard pyGE? (.str "3") (.num 0 0) == none               -- str >= int は TypeError
#guard pyGE? .null (.num 8 1) == none

-- isNonEmptyString
#guard isNonEmptyString (.str " x ") == true
#guard isNonEmptyString (.str "   ") == false
#guard isNonEmptyString (.num 1 0) == false

end Looper.Core.Doc
