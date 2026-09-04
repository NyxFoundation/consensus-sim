import Looper.Core.Prim

/-!
`Looper.Core.Json` — 挿入順序を保持する純粋 JSON コア。

Lean 標準の `Lean.Data.Json` はオブジェクトをキー整列の RBNode で持ち挿入順序を
失うため(LEAN_MIGRATION_PLAN.md §4.4)、フレームワークは入出力とも本モジュールの
順序付き assoc-list 表現を使う。シリアライザは Python `json.dumps`
(既定セパレータ `", "` / `": "`)と `ensure_ascii` の真偽両モードで
バイト単位に一致させる(`Value.render` = False / `Value.renderAscii` = True)。

Python `json.loads` との意図的な差(いずれも「受理しない」方向の厳格化):
- `NaN` / `Infinity` / `-Infinity` は受理しない(現行の全出力に float は
  現れないことを実測済み — §31.2-6)
- 孤立サロゲート(`\uD800` 単独等)は受理しない(Lean の `String` は
  不正スカラー値を保持できない)
- 4096 桁を超える指数は受理しない(Python は float の inf に丸める)

exponent > 0 の数値の直列化は素朴な 10 進小数であり、Python の float `repr`
互換を保証しない。出力に float が現れた時点で裁定キューへ(LEAN_MIGRATION_PLAN.md §4.4)。
-/

namespace Looper.Core.Json

open Looper.Core.Prim (hexDigit digitsToNat padLeftZeros)

/-- 挿入順序を保持する JSON 値。数値は 10 進表現 `mantissa / 10^exponent`。 -/
inductive Value where
  | null
  | bool (b : Bool)
  | num (mantissa : Int) (exponent : Nat)
  | str (s : String)
  | arr (items : List Value)
  | obj (entries : List (String × Value))

/-! `Value` の構造等値。`deriving BEq` は nested inductive に対して opaque
(簡約不能)な実装を生成し、`==` を含む判定関数の定理化(§31.3 B-T3)を阻む
ため、証明可能な構造的再帰で手書きする。意味は導出版と同一の構造等値。 -/

mutual
  def Value.beq : Value → Value → Bool
    | .null, .null => true
    | .bool a, .bool b => a == b
    | .num am ae, .num bm be => am == bm && ae == be
    | .str a, .str b => a == b
    | .arr a, .arr b => Value.beqList a b
    | .obj a, .obj b => Value.beqEntries a b
    | _, _ => false
  def Value.beqList : List Value → List Value → Bool
    | [], [] => true
    | a :: as, b :: bs => Value.beq a b && Value.beqList as bs
    | _, _ => false
  def Value.beqEntries :
      List (String × Value) → List (String × Value) → Bool
    | [], [] => true
    | (ak, av) :: as, (bk, bv) :: bs =>
      ak == bk && Value.beq av bv && Value.beqEntries as bs
    | _, _ => false
end

instance instBEqValue : BEq Value := ⟨Value.beq⟩

/-- Python の truthiness(`or` / `if` が偽に落とす値)。`0` / `0.0` /
`""` / `[]` / `{}` / `null` / `false` が偽。 -/
def Value.truthy : Value → Bool
  | .null => false
  | .bool b => b
  | .num mantissa _ => mantissa != 0
  | .str s => !s.isEmpty
  | .arr items => !items.isEmpty
  | .obj entries => !entries.isEmpty

private def lookupEntry : List (String × Value) → String → Option Value
  | [], _ => none
  | (k, v) :: rest, key => if k == key then some v else lookupEntry rest key

/-- object のキー参照(最初の一致。パーサはキーの一意性を保証する)。 -/
def Value.get? : Value → String → Option Value
  | .obj entries, key => lookupEntry entries key
  | _, _ => none

/-- キーパスの多段参照。空パスは値自身。途中が object でない・キーが無い場合は
`none`(`Value.get?` の多段版)。 -/
def Value.getPath? : Value → List String → Option Value
  | v, [] => some v
  | v, key :: rest =>
    match v.get? key with
    | some child => child.getPath? rest
    | none => none

def Value.asStr? : Value → Option String
  | .str s => some s
  | _ => none

/-! ## 直列化(Python `json.dumps` 互換 — `ensure_ascii` の真偽両モード) -/

/-- `\uXXXX`(小文字 4 桁 hex)。Python json の `%04x` に対応。 -/
private def ucHex4 (n : Nat) : String :=
  "\\u" ++ String.ofList
    [hexDigit (n / 4096 % 16), hexDigit (n / 256 % 16), hexDigit (n / 16 % 16), hexDigit (n % 16)]

private def escapeChar (ascii : Bool) (c : Char) : String :=
  match c with
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\t' => "\\t"
  | '\r' => "\\r"
  | c =>
    if c.toNat == 8 then "\\b"
    else if c.toNat == 12 then "\\f"
    else if c.toNat < 0x20 then ucHex4 c.toNat
    else if ascii && c.toNat > 0x7E then
      -- Python の ensure_ascii=True: 0x7F 以上を \uXXXX へ。BMP 外はサロゲートペア。
      if c.toNat < 0x10000 then ucHex4 c.toNat
      else
        let v := c.toNat - 0x10000
        ucHex4 (0xD800 + v / 0x400) ++ ucHex4 (0xDC00 + v % 0x400)
    else String.singleton c

/-- `"` で囲んだ JSON 文字列リテラル。`ascii = false` は
`ensure_ascii=False`(`"` `\` と制御文字のみエスケープ、非 ASCII は生のまま)、
`ascii = true` は Python 既定の `ensure_ascii=True`(0x7F 以上も `\uXXXX`)。 -/
def escapeStringWith (ascii : Bool) (s : String) : String :=
  (s.foldl (fun acc c => acc ++ escapeChar ascii c) "\"") ++ "\""

def escapeString : String → String := escapeStringWith false

private def renderNum (mantissa : Int) (exponent : Nat) : String :=
  if exponent == 0 then toString mantissa
  else
    let digits := padLeftZeros (toString mantissa.natAbs) (exponent + 1)
    let point := digits.length - exponent
    (if mantissa < 0 then "-" else "") ++ digits.take point ++ "." ++ digits.drop point

mutual
  private def renderWith (ascii compact : Bool) : Value → String
    | .null => "null"
    | .bool true => "true"
    | .bool false => "false"
    | .num m e => renderNum m e
    | .str s => escapeStringWith ascii s
    | .arr items => "[" ++ renderList ascii compact items ++ "]"
    | .obj entries => "{" ++ renderEntries ascii compact entries ++ "}"

  private def renderList (ascii compact : Bool) : List Value → String
    | [] => ""
    | [v] => renderWith ascii compact v
    | v :: rest =>
      renderWith ascii compact v ++ (if compact then "," else ", ")
        ++ renderList ascii compact rest

  private def renderEntries (ascii compact : Bool) : List (String × Value) → String
    | [] => ""
    | [(k, v)] =>
      escapeStringWith ascii k ++ (if compact then ":" else ": ")
        ++ renderWith ascii compact v
    | (k, v) :: rest =>
      escapeStringWith ascii k ++ (if compact then ":" else ": ")
        ++ renderWith ascii compact v ++ (if compact then "," else ", ")
        ++ renderEntries ascii compact rest
end

/-- Python `json.dumps(..., ensure_ascii=False)`(既定セパレータ)互換の直列化。 -/
def Value.render : Value → String := renderWith false false

/-- Python `json.dumps(...)` 既定(`ensure_ascii=True`)互換の直列化。
非 ASCII を `\uXXXX`(BMP 外はサロゲートペア)へエスケープする。 -/
def Value.renderAscii : Value → String := renderWith true false

/-- Python `json.dumps(..., separators=(",", ":"))`(`ensure_ascii=True` 既定)
互換のコンパクト直列化。 -/
def Value.renderCompactAscii : Value → String := renderWith true true

/-- Python `json.dumps(..., ensure_ascii=False, separators=(",", ":"))` 互換の
コンパクト直列化(非 ASCII をそのまま出す版)。 -/
def Value.renderCompact : Value → String := renderWith false true

private def spaces (n : Nat) : String := String.ofList (List.replicate n ' ')

mutual
  private def prettyVal (ascii : Bool) (indent level : Nat) : Value → String
    | .arr [] => "[]"
    | .obj [] => "{}"
    | .arr items =>
      "[\n" ++ prettyItems ascii indent (level + 1) items
        ++ "\n" ++ spaces (indent * level) ++ "]"
    | .obj entries =>
      "{\n" ++ prettyEntries ascii indent (level + 1) entries
        ++ "\n" ++ spaces (indent * level) ++ "}"
    | v => renderWith ascii false v

  private def prettyItems (ascii : Bool) (indent level : Nat) : List Value → String
    | [] => ""
    | [v] => spaces (indent * level) ++ prettyVal ascii indent level v
    | v :: rest =>
      spaces (indent * level) ++ prettyVal ascii indent level v
        ++ ",\n" ++ prettyItems ascii indent level rest

  private def prettyEntries (ascii : Bool) (indent level : Nat) :
      List (String × Value) → String
    | [] => ""
    | [(k, v)] =>
      spaces (indent * level) ++ escapeStringWith ascii k ++ ": "
        ++ prettyVal ascii indent level v
    | (k, v) :: rest =>
      spaces (indent * level) ++ escapeStringWith ascii k ++ ": "
        ++ prettyVal ascii indent level v ++ ",\n" ++ prettyEntries ascii indent level rest
end

/-- Python `json.dumps(..., ensure_ascii=False, indent=n)` 互換の整形直列化
(空の配列・オブジェクトは 1 行、要素は `,\n` 区切り、キーは `": "`)。 -/
def Value.renderPretty (v : Value) (indent : Nat := 2) : String :=
  prettyVal false indent 0 v

/-! ## パース(RFC 8259 準拠、fuel による全域関数) -/

private def isWs (c : Char) : Bool :=
  c == ' ' || c == '\t' || c == '\n' || c == '\r'

private def skipWs : List Char → List Char
  | c :: cs => if isWs c then skipWs cs else c :: cs
  | [] => []

private def hexVal? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

private def hex4 (a b c d : Char) : Except String Nat := do
  let go (ch : Char) : Except String Nat :=
    match hexVal? ch with
    | some v => .ok v
    | none => .error "invalid \\u escape"
  pure ((((← go a) * 16 + (← go b)) * 16 + (← go c)) * 16 + (← go d))

private def escChar? (c : Char) : Option Char :=
  match c with
  | '"' => some '"'
  | '\\' => some '\\'
  | '/' => some '/'
  | 'b' => some (Char.ofNat 8)
  | 'f' => some (Char.ofNat 12)
  | 'n' => some '\n'
  | 'r' => some '\r'
  | 't' => some '\t'
  | _ => none

/-- `"` の直後から閉じ `"` まで。サロゲートペアは合成し、孤立サロゲートは拒否する。 -/
private def parseStringBody : List Char → String → Except String (String × List Char)
  | '"' :: rest, acc => .ok (acc, rest)
  | '\\' :: 'u' :: h1 :: h2 :: h3 :: h4 :: rest, acc => do
    let n ← hex4 h1 h2 h3 h4
    if 0xD800 ≤ n && n < 0xDC00 then
      match rest with
      | '\\' :: 'u' :: g1 :: g2 :: g3 :: g4 :: rest' => do
        let lo ← hex4 g1 g2 g3 g4
        if 0xDC00 ≤ lo && lo < 0xE000 then
          let cp := 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
          parseStringBody rest' (acc.push (Char.ofNat cp))
        else
          .error "unpaired surrogate escape"
      | _ => .error "unpaired surrogate escape"
    else if 0xDC00 ≤ n && n < 0xE000 then
      .error "unpaired surrogate escape"
    else
      parseStringBody rest (acc.push (Char.ofNat n))
  | '\\' :: c :: rest, acc =>
    match escChar? c with
    | some e => parseStringBody rest (acc.push e)
    | none => .error "invalid escape"
  | c :: rest, acc =>
    if c.toNat < 0x20 then .error "unescaped control character"
    else parseStringBody rest (acc.push c)
  | [], _ => .error "unterminated string"

private def takeDigits : List Char → List Char × List Char
  | c :: cs =>
    if '0' ≤ c && c ≤ '9' then
      let (ds, rest) := takeDigits cs
      (c :: ds, rest)
    else ([], c :: cs)
  | [] => ([], [])

private def parseNumber (cs : List Char) : Except String (Value × List Char) := do
  let (neg, cs) := match cs with
    | '-' :: rest => (true, rest)
    | _ => (false, cs)
  let (intDigits, cs) ← match cs with
    | '0' :: rest => pure (['0'], rest)
    | c :: _ =>
      if '1' ≤ c && c ≤ '9' then pure (takeDigits cs)
      else .error "invalid number"
    | [] => .error "invalid number"
  let (fracDigits, cs) ← match cs with
    | '.' :: rest =>
      match takeDigits rest with
      | ([], _) => .error "missing fraction digits"
      | (ds, rest') => pure (ds, rest')
    | _ => pure (([] : List Char), cs)
  let (expVal, cs) ← match cs with
    | c :: rest =>
      if c == 'e' || c == 'E' then
        let (expNeg, rest) := match rest with
          | '+' :: r => (false, r)
          | '-' :: r => (true, r)
          | _ => (false, rest)
        match takeDigits rest with
        | ([], _) => .error "missing exponent digits"
        | (ds, rest') =>
          let v : Int := Int.ofNat (digitsToNat ds)
          pure (if expNeg then -v else v, rest')
      else pure ((0 : Int), c :: rest)
    | [] => pure ((0 : Int), ([] : List Char))
  let mantissa0 : Nat := digitsToNat (intDigits ++ fracDigits)
  let signed : Int := if neg then -(Int.ofNat mantissa0) else Int.ofNat mantissa0
  let e10 : Int := expVal - Int.ofNat fracDigits.length
  -- 指数は**両側**を有界にする。正側だけを止めていた旧実装では
  -- `1e-1000000000` が `.num 1 1000000000` として安価に parse され、下流の
  -- `10 ^ exponent`(pyInt? / numGE / renderNum / pyEq)が 10^10⁹ を実体化して
  -- gate 述語(should-stop / should-reset)や validate を hang / OOM させ、
  -- I-021 が要求する「制御されたハードエラー」を回避していた(2026-07-27)。
  -- 4096 桁を超える指数は正負とも parse error(= その正本は state_unreadable /
  -- validate error に落ち、fail-closed に停止する)。
  if e10 > 4096 || e10 < -4096 then
    .error "exponent out of range"
  else if e10 ≥ 0 then
    pure (.num (signed * Int.ofNat (10 ^ e10.toNat)) 0, cs)
  else
    pure (.num signed (-e10).toNat, cs)

/-- Python dict と同じ重複キー規則: 位置は初出、値は最後の代入。 -/
private def insertEntry (entries : List (String × Value)) (key : String) (v : Value) :
    List (String × Value) :=
  if entries.any (fun e => e.1 == key) then
    entries.map (fun e => if e.1 == key then (key, v) else e)
  else
    entries ++ [(key, v)]

/-- object へのキー代入(Python dict 代入と同じ: 既存キーは位置を保って置換、
新規キーは末尾へ追加)。object 以外には作用しない。 -/
def Value.set : Value → String → Value → Value
  | .obj entries, key, v => .obj (insertEntry entries key v)
  | other, _, _ => other

mutual
  private def parseValue : Nat → List Char → Except String (Value × List Char)
    | 0, _ => .error "input too deeply nested"
    | fuel + 1, cs =>
      match skipWs cs with
      | 'n' :: 'u' :: 'l' :: 'l' :: rest => .ok (.null, rest)
      | 't' :: 'r' :: 'u' :: 'e' :: rest => .ok (.bool true, rest)
      | 'f' :: 'a' :: 'l' :: 's' :: 'e' :: rest => .ok (.bool false, rest)
      | '"' :: rest => do
        let (s, rest') ← parseStringBody rest ""
        pure (.str s, rest')
      | '[' :: rest => parseItems fuel rest []
      | '{' :: rest => parseEntries fuel rest []
      | rest => parseNumber rest

  /-- `[` の直後から。`acc` は逆順の確定済み要素。 -/
  private def parseItems : Nat → List Char → List Value → Except String (Value × List Char)
    | 0, _, _ => .error "input too deeply nested"
    | fuel + 1, cs, acc =>
      match skipWs cs with
      | ']' :: rest =>
        if acc.isEmpty then .ok (.arr [], rest) else .error "trailing comma in array"
      | cs' => do
        let (v, rest) ← parseValue fuel cs'
        match skipWs rest with
        | ',' :: rest' => parseItems fuel rest' (v :: acc)
        | ']' :: rest' => .ok (.arr (v :: acc).reverse, rest')
        | _ => .error "expected ',' or ']' in array"

  /-- `{` の直後から。`acc` は挿入順の確定済みエントリ。 -/
  private def parseEntries : Nat → List Char → List (String × Value) →
      Except String (Value × List Char)
    | 0, _, _ => .error "input too deeply nested"
    | fuel + 1, cs, acc =>
      match skipWs cs with
      | '}' :: rest =>
        if acc.isEmpty then .ok (.obj [], rest) else .error "trailing comma in object"
      | '"' :: rest => do
        let (key, rest') ← parseStringBody rest ""
        match skipWs rest' with
        | ':' :: rest'' => do
          let (v, rest''') ← parseValue fuel rest''
          let acc' := insertEntry acc key v
          match skipWs rest''' with
          | ',' :: more => parseEntries fuel more acc'
          | '}' :: more => .ok (.obj acc', more)
          | _ => .error "expected ',' or '}' in object"
        | _ => .error "expected ':' in object"
      | _ => .error "expected key string or '}' in object"
end

/-- JSON テキスト全体をパースする。先頭・末尾の空白は許容、末尾のゴミはエラー。
fuel は「1 消費につき最低 1 文字進む」ため入力長に比例して必ず足りる。 -/
def parse (input : String) : Except String Value := do
  let cs := input.toList
  let (v, rest) ← parseValue (cs.length * 2 + 8) cs
  match skipWs rest with
  | [] => pure v
  | _ => .error "unexpected trailing data"

/-! ## コンパイル時テスト(パース → 再直列化の往復で検査) -/

private def roundTrip (s : String) : Option String :=
  (parse s).toOption.map Value.render

#guard roundTrip "{\"a\": 1, \"b\": [true, null, \"x\"]}"
    == some "{\"a\": 1, \"b\": [true, null, \"x\"]}"
#guard roundTrip "  { }  " == some "{}"
#guard roundTrip "[]" == some "[]"
#guard roundTrip "{\"a\":1,\"a\":2}" == some "{\"a\": 2}"
#guard roundTrip "{\"日本語\": \"café\"}" == some "{\"日本語\": \"café\"}"
#guard roundTrip "\"a\\u00e9\\n\\t\"" == some "\"aé\\n\\t\""
#guard roundTrip "\"\\ud83d\\ude00\"" == some "\"😀\""
#guard roundTrip "[-12, 0, 1.5, 0.05, 1e3, 1E-2]" == some "[-12, 0, 1.5, 0.05, 1000, 0.01]"
-- 指数は両側有界: 4096 桁を超える正負の指数は parse error(DoS 防止、下流の
-- 10^exp 実体化を止める。2026-07-27)。境界内は従来どおり受理。
#guard (parse "1e5000").isOk == false
#guard (parse "1e-5000").isOk == false
#guard (parse "1e-1000000000").isOk == false
#guard (parse "1e4096").isOk == true
#guard (parse "1e-4096").isOk == true
#guard (Value.str (String.ofList [Char.ofNat 1])).render == "\"\\u0001\""
#guard (Value.str (String.ofList [Char.ofNat 8, Char.ofNat 12])).render == "\"\\b\\f\""
-- ensure_ascii=True(renderAscii): 0x7F 以上を \uXXXX、BMP 外はサロゲートペア
#guard (Value.str "é").renderAscii == "\"\\u00e9\""
#guard (Value.str "a—§b").renderAscii == "\"a\\u2014\\u00a7b\""
#guard (Value.str "😀").renderAscii == "\"\\ud83d\\ude00\""
#guard (Value.str (String.ofList [Char.ofNat 0x7F])).renderAscii == "\"\\u007f\""
#guard (Value.str (String.ofList [Char.ofNat 0x7F])).render
    == "\"" ++ String.ofList [Char.ofNat 0x7F] ++ "\""
#guard (Value.obj [("k", .str "日本語")]).renderAscii == "{\"k\": \"\\u65e5\\u672c\\u8a9e\"}"
-- 不受理側: 末尾ゴミ・トレーリングカンマ・孤立サロゲート・先頭ゼロ・NaN
#guard roundTrip "{} x" == none
#guard roundTrip "[1,2,]" == none
#guard roundTrip "{\"a\": 1,}" == none
#guard roundTrip "\"\\ud800\"" == none
#guard roundTrip "01" == none
#guard roundTrip "NaN" == none
#guard ((parse "{\"a\": {\"b\": 2}}").toOption.bind (·.get? "a") |>.bind (·.get? "b")
    |>.map Value.render) == some "2"
-- Value.set: 既存キーは位置保持で置換、新規キーは末尾追加
#guard ((Value.obj [("a", .num 1 0), ("b", .num 2 0)]).set "a" .null).render
    == "{\"a\": null, \"b\": 2}"
#guard ((Value.obj [("a", .num 1 0)]).set "c" (.str "x")).render
    == "{\"a\": 1, \"c\": \"x\"}"
-- renderPretty: Python json.dumps(..., indent=2) 互換
#guard (Value.obj [("a", .num 1 0),
                   ("b", .arr [.num 1 0, .obj [("c", .null)]]),
                   ("d", .arr []), ("e", .obj [])]).renderPretty
    == "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    {\n      \"c\": null\n    }\n  ],\n  \"d\": [],\n  \"e\": {}\n}"
#guard (Value.obj []).renderPretty == "{}"
#guard (Value.str "x").renderPretty == "\"x\""
-- renderCompactAscii: Python json.dumps(..., separators=(",", ":")) 互換
#guard (Value.obj [("a", .num 1 0), ("b", .arr [.bool true, .null, .str "日"])]
    ).renderCompactAscii == "{\"a\":1,\"b\":[true,null,\"\\u65e5\"]}"
#guard (Value.obj []).renderCompactAscii == "{}"
-- getPath?: 多段参照・空パス・非 object 途中
#guard ((parse "{\"a\": {\"b\": {\"c\": 3}}}").toOption.bind
    (·.getPath? ["a", "b", "c"]) |>.map Value.render) == some "3"
#guard ((Value.str "x").getPath? [] |>.map Value.render) == some "\"x\""
#guard ((Value.obj [("a", .num 1 0)]).getPath? ["a", "b"]).isNone

/-! ## `set` / `get?` の代数(証明層 `proofs/` の土台)

`insertEntry` は private のため、`Value.set` の観測的性質はここで定理化して
公開する(挙動追加なし — 実行コードはこの節に依存しない)。 -/

private theorem lookupEntry_append_ne {k k' : String} (hb : (k == k') = false)
    (es : List (String × Value)) (v : Value) :
    lookupEntry (es ++ [(k, v)]) k' = lookupEntry es k' := by
  induction es with
  | nil => simp [lookupEntry, hb]
  | cons e es ih =>
    obtain ⟨k0, v0⟩ := e
    cases h0 : (k0 == k') <;> simp [lookupEntry, h0, ih]

private theorem lookupEntry_replace_ne {k k' : String} (hb : (k == k') = false)
    (es : List (String × Value)) (v : Value) :
    lookupEntry (es.map fun e => if e.1 == k then (k, v) else e) k'
      = lookupEntry es k' := by
  induction es with
  | nil => rfl
  | cons e es ih =>
    obtain ⟨k0, v0⟩ := e
    cases h0 : (k0 == k) with
    | true =>
      have : k0 = k := eq_of_beq h0
      subst this
      simpa [lookupEntry, hb, -beq_iff_eq] using ih
    | false =>
      cases h1 : (k0 == k') <;>
        simp [lookupEntry, h0, h1, ih, -beq_iff_eq]

private theorem lookupEntry_append_self {k : String} (es : List (String × Value))
    (h : es.any (fun e => e.1 == k) = false) (v : Value) :
    lookupEntry (es ++ [(k, v)]) k = some v := by
  induction es with
  | nil => simp [lookupEntry]
  | cons e es ih =>
    obtain ⟨k0, v0⟩ := e
    simp only [List.any_cons, Bool.or_eq_false_iff] at h
    simp [lookupEntry, h.1, ih h.2]

private theorem lookupEntry_replace_self {k : String} (es : List (String × Value))
    (h : es.any (fun e => e.1 == k) = true) (v : Value) :
    lookupEntry (es.map fun e => if e.1 == k then (k, v) else e) k = some v := by
  induction es with
  | nil => simp at h
  | cons e es ih =>
    obtain ⟨k0, v0⟩ := e
    simp only [List.any_cons] at h
    cases h0 : (k0 == k) with
    | true => simp [lookupEntry, h0, -beq_iff_eq]
    | false =>
      simp only [h0, Bool.false_or] at h
      simp [lookupEntry, h0, ih h, -beq_iff_eq]

/-- `set` の結果は常に object(存在形 — エントリ列自体は非公開)。 -/
theorem Value.set_obj (es : List (String × Value)) (k : String) (v : Value) :
    ∃ es', (Value.obj es).set k v = Value.obj es' :=
  ⟨_, rfl⟩

/-- `set` したキーの `get?` は代入値を返す(Python dict 代入の読み戻し)。 -/
theorem Value.get?_set_self (es : List (String × Value)) (k : String) (v : Value) :
    ((Value.obj es).set k v).get? k = some v := by
  show lookupEntry (insertEntry es k v) k = some v
  unfold insertEntry
  cases h : es.any (fun e => e.1 == k) with
  | true => simpa [h] using lookupEntry_replace_self es h v
  | false => simpa [h] using lookupEntry_append_self es h v

/-- `set` は他キーの `get?` を変えない(Python dict 代入の非干渉)。 -/
theorem Value.get?_set_of_ne (es : List (String × Value)) {k k' : String}
    (hne : k ≠ k') (v : Value) :
    ((Value.obj es).set k v).get? k' = (Value.obj es).get? k' := by
  have hb : (k == k') = false := beq_eq_false_iff_ne.mpr hne
  show lookupEntry (insertEntry es k v) k' = lookupEntry es k'
  unfold insertEntry
  cases h : es.any (fun e => e.1 == k) with
  | true => simpa [h] using lookupEntry_replace_ne hb es v
  | false => simpa [h] using lookupEntry_append_ne hb es v

end Looper.Core.Json
