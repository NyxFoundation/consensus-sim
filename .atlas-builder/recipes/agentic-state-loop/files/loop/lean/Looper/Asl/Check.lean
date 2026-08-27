import Looper.Core.Json
import Looper.Core.Glob
import Looper.Core.Doc

/-!
`Looper.Asl.Check` — agentic-state-loop レシピの schema 駆動ミニバリデータ
(vendored `files/loop/scripts/state.py` の `check_value` の純粋核)。

対応する JSON Schema サブセットは Python 版と同一: type / enum / const /
pattern / required / properties / additionalProperties (false) / items /
minItems / maxItems / minimum / maximum。未知キーワードは無視する。
エラーメッセージは Python の f-string(`{value!r}` は `repr`、`{x}` は
`str`)と一致させるため、`pyRepr` / `pyStr` を同梱する。

Python との裁定済み仕様差(META.md §31.2):
- `pattern` キーワードは Python regex(`re.search`)ではなく §29.6 の制限
  グロブ方言(`Looper.Core.Glob`、search 意味論)で判定する。
- Python が TypeError / AttributeError で落ちる病的 schema 形状
  (非リスト `enum`・非 dict `properties`・数値でない `minimum` 等)は、
  クラッシュ(exit 1)ではなく「キーワード無視」または「不一致 = エラー」
  の決定的挙動に写す(詳細は各判定の注記)。
- `repr` の互換範囲: 文字列はクォート選択(`'` 優先、`'` を含み `"` を
  含まないときだけ `"`)とエスケープ(`\\` / クォート / `\n` `\r` `\t` /
  その他 C0 制御と DEL は `\xXX`)を再現する。U+0080 以上は printable
  非依存でそのまま出す(Python は非印字カテゴリを `\uXXXX` へ逃がすが、
  canonical state に現れる文字種では差が出ない)。float の `repr` は
  `mantissa / 10^exponent` の素朴な 10 進小数であり、指数表記へ切り替わる
  極端な値では Python と異なりうる(`Core/Json` の直列化と同じ凍結差分)。
- 「Python の int」の判定(type "integer" / policy)は「小数点・指数部の
  ない数値リテラル」= `num _ 0` に写す。`3e0` のような整数値の指数表記を
  Python は float と見るが、本実装は int と見る(パース時に正規化される
  ため区別が残らない。裁定キュー済みの低リスク差分)。
-/

namespace Looper.Asl.Check

open Looper.Core
open Looper.Core.Prim (hex2)
open Looper.Core.Doc (pyGE? numEq)

/-! ## Python `repr` / `str` 互換 -/

private def escapeReprChar (quote : Char) (c : Char) : String :=
  if c == '\\' then "\\\\"
  else if c == quote then "\\" ++ quote.toString
  else if c == '\n' then "\\n"
  else if c == '\r' then "\\r"
  else if c == '\t' then "\\t"
  else if c.toNat < 32 || c.toNat == 127 then "\\x" ++ hex2 c.toNat
  else c.toString

/-- Python `repr(<str>)`: `'` 優先のクォート選択 + エスケープ。 -/
def pyReprString (s : String) : String :=
  let quote := if s.contains '\'' && !s.contains '"' then '"' else '\''
  quote.toString ++ String.join (s.toList.map (escapeReprChar quote)) ++ quote.toString

/-- `Core/Json` の `renderNum` と同じ素朴な 10 進小数(`repr(float)` 互換の
主要域)。`exponent == 0` は int の `repr`。 -/
def decimalOfNum (mantissa : Int) (exponent : Nat) : String :=
  if exponent == 0 then toString mantissa
  else
    let raw := toString mantissa.natAbs
    let digits := String.ofList (List.replicate (exponent + 1 - raw.length) '0') ++ raw
    let point := digits.length - exponent
    (if mantissa < 0 then "-" else "") ++ digits.take point ++ "." ++ digits.drop point

mutual
  /-- Python `repr()` の JSON 値版(エラーメッセージの `{value!r}` 用)。 -/
  def pyRepr : Json.Value → String
    | .null => "None"
    | .bool true => "True"
    | .bool false => "False"
    | .num m e => decimalOfNum m e
    | .str s => pyReprString s
    | .arr items => "[" ++ pyReprList items ++ "]"
    | .obj entries => "{" ++ pyReprEntries entries ++ "}"

  private def pyReprList : List Json.Value → String
    | [] => ""
    | [v] => pyRepr v
    | v :: rest => pyRepr v ++ ", " ++ pyReprList rest

  private def pyReprEntries : List (String × Json.Value) → String
    | [] => ""
    | [(k, v)] => pyReprString k ++ ": " ++ pyRepr v
    | (k, v) :: rest => pyReprString k ++ ": " ++ pyRepr v ++ ", " ++ pyReprEntries rest
end

/-- Python `str()` の JSON 値版(f-string の `{x}` 用): 文字列は生のまま、
それ以外は `repr` と同じ。 -/
def pyStr : Json.Value → String
  | .str s => s
  | v => pyRepr v

/-! ## Python `==` 互換(enum / const / dict 等価) -/

mutual
  /-- Python `==` の JSON 値版: 数値は int / float / bool を跨いで数値比較
  (`True == 1`、`1 == 1.0`)、dict はキー順に依存しない。 -/
  def pyEq : Json.Value → Json.Value → Bool
    | .null, .null => true
    | .bool a, .bool b => a == b
    | .bool a, .num m e => numEq (if a then 1 else 0) 0 m e
    | .num m e, .bool b => numEq m e (if b then 1 else 0) 0
    | .num m1 e1, .num m2 e2 => numEq m1 e1 m2 e2
    | .str a, .str b => a == b
    | .arr a, .arr b => pyEqList a b
    -- JSON object のキーは一意(パーサが重複を畳む)ので、長さ一致 +
    -- 片側包含で dict 等価になる
    | .obj a, .obj b => a.length == b.length && pyEqEntries a b
    | _, _ => false

  private def pyEqList : List Json.Value → List Json.Value → Bool
    | [], [] => true
    | x :: xs, y :: ys => pyEq x y && pyEqList xs ys
    | _, _ => false

  /-- 片側包含: `a` の各エントリが `b` に等しい値で存在する。 -/
  private def pyEqEntries : List (String × Json.Value) → List (String × Json.Value) → Bool
    | [], _ => true
    | (k, v) :: rest, b =>
      (match b.find? (fun (bk, _) => bk == k) with
        | some (_, bv) => pyEq v bv
        | none => false)
      && pyEqEntries rest b
end

/-- Python `x in container`: list は要素等価、str は部分文字列
(非 str の被検索値は Python では TypeError — 「含まれない」側に写す)。 -/
def pyIn (value container : Json.Value) : Bool :=
  match container with
  | .arr items => items.any (pyEq value)
  | .str cs =>
    match value with
    | .str vs => vs.isEmpty || (cs.splitOn vs).length ≥ 2
    | _ => false
  | _ => false

/-! ## check_value 本体 -/

/-- Python `type(value).__name__`。 -/
def typeName : Json.Value → String
  | .obj _ => "dict"
  | .arr _ => "list"
  | .str _ => "str"
  | .bool _ => "bool"
  | .null => "NoneType"
  | .num _ 0 => "int"
  | .num _ _ => "float"

private def knownTypeNames : List String :=
  ["object", "array", "string", "integer", "number", "boolean", "null"]

/-- `_TYPES` の isinstance 判定。Python 同様 bool は int の派生
(`isinstance(True, int)`)なので "integer" / "number" にもマッチし、
bool の除外は呼び出し側のガードが行う。 -/
private def matchesIsinstance (value : Json.Value) : String → Bool
  | "object" => (value matches .obj _)
  | "array" => (value matches .arr _)
  | "string" => (value matches .str _)
  | "integer" => (value matches .num _ 0) || (value matches .bool _)
  | "number" => (value matches .num _ _) || (value matches .bool _)
  | "boolean" => (value matches .bool _)
  | "null" => (value matches .null)
  | _ => false

private def typeError? (value schema : Json.Value) (path : String) : Option (Option String) :=
  match schema.get? "type" with
  | none => none
  | some expected =>
    let types : List Json.Value := match expected with | .arr l => l | v => [v]
    let names := types.filterMap fun v =>
      match v with | .str s => some s | _ => none
    let known := names.filter knownTypeNames.contains
    let isBool := value matches .bool _
    let ok := !known.isEmpty && known.any (matchesIsinstance value)
      && !(isBool && !names.contains "boolean")
    if ok then some none
    else some (some s!"{path}: expected type {pyStr expected}, got {typeName value}")

/-- Python `check_value` の純粋核: `value` を JSON Schema サブセット
`schema` に対して検査し、エラーメッセージ列を Python と同一順で返す。
`fuel` は入れ子深さの上限(呼び出し側が schema テキスト長を渡せば
尽きない。尽きた場合はそれ以深を検査しない = エラーなし)。 -/
def checkValue (fuel : Nat) (value schema : Json.Value) (path : String) : List String :=
  match fuel with
  | 0 => []
  | fuel + 1 =>
    if !(schema matches .obj _) then []
    else
      match typeError? value schema path with
      | some (some err) => [err]
      | _ =>
        let enumErrs := match schema.get? "enum" with
          | none => []
          | some container =>
            if pyIn value container then []
            else [s!"{path}: {pyRepr value} not in enum {pyStr container}"]
        let constErrs := match schema.get? "const" with
          | none => []
          | some c =>
            if pyEq value c then []
            else [s!"{path}: {pyRepr value} != const {pyRepr c}"]
        let patternErrs := match value, schema.get? "pattern" with
          | .str s, some (.str p) =>
            if Glob.accepts p s then []
            else [s!"{path}: {pyReprString s} does not match {pyReprString p}"]
          | _, _ => []
        let rangeErrs := match value with
          | .num _ _ =>
            let minErr := match schema.get? "minimum" with
              | some minv =>
                match pyGE? value minv with
                | some false => [s!"{path}: {pyStr value} < minimum {pyStr minv}"]
                | _ => []
              | none => []
            let maxErr := match schema.get? "maximum" with
              | some maxv =>
                match pyGE? maxv value with
                | some false => [s!"{path}: {pyStr value} > maximum {pyStr maxv}"]
                | _ => []
              | none => []
            minErr ++ maxErr
          | _ => []
        let dictErrs := match value with
          | .obj ventries =>
            let props : List (String × Json.Value) := match schema.get? "properties" with
              | some (.obj pl) => pl
              | _ => []
            let requiredKeys : List Json.Value := match schema.get? "required" with
              | some (.arr rl) => rl
              | some (.str s) => s.toList.map fun c => .str c.toString
              | _ => []
            let reqErrs := requiredKeys.filterMap fun req =>
              let present := match req with
                | .str k => ventries.any fun (key, _) => key == k
                | _ => false
              if present then none
              else some s!"{path}: missing required key {pyRepr req}"
            let propErrs := props.flatMap fun (k, sub) =>
              match ventries.find? (fun (key, _) => key == k) with
              | some (_, v) => checkValue fuel v sub s!"{path}.{k}"
              | none => []
            let addErrs := match schema.get? "additionalProperties" with
              | some (.bool false) =>
                ventries.filterMap fun (key, _) =>
                  if props.any (fun (pk, _) => pk == key) then none
                  else some s!"{path}: unexpected key {pyReprString key}"
              | _ => []
            reqErrs ++ propErrs ++ addErrs
          | _ => []
        let listErrs := match value with
          | .arr items =>
            let len : Json.Value := .num (Int.ofNat items.length) 0
            let minErr := match schema.get? "minItems" with
              | some m =>
                match pyGE? len m with
                | some false => [s!"{path}: fewer than {pyStr m} items"]
                | _ => []
              | none => []
            let maxErr := match schema.get? "maxItems" with
              | some m =>
                match pyGE? m len with
                | some false => [s!"{path}: more than {pyStr m} items"]
                | _ => []
              | none => []
            let itemErrs := match schema.get? "items" with
              | some itemsSchema =>
                if itemsSchema matches .obj _ then
                  ((List.range items.length).zip items).flatMap fun (i, item) =>
                    checkValue fuel item itemsSchema s!"{path}[{i}]"
                else []
              | none => []
            minErr ++ maxErr ++ itemErrs
          | _ => []
        enumErrs ++ constErrs ++ patternErrs ++ rangeErrs ++ dictErrs ++ listErrs

/-! ## 旧 regex 方言の検出(validate の warnings、K-7 緩和) -/

/-- §29.6: 旧 Python regex 方言の兆候を持つパターンへの警告文言(単一定義)。 -/
def legacyMessage (label pattern : String) : String :=
  let signals := String.intercalate ", " (Glob.legacySignals pattern)
  s!"{label}: {pyReprString pattern} looks like a legacy regex pattern (signals: {signals}); patterns are a restricted glob dialect (literal text + '*' + leading '^' / trailing '$') matched literally — rewrite it per the recipe README conversion table."

/-- JSON 値を再帰的に歩き、`pattern` キーの旧方言兆候を警告として集める
(document schema 用。`label` は `documents.<name>.schema` 起点)。 -/
def legacyPatternWarnings (fuel : Nat) (v : Json.Value) (label : String) : List String :=
  match fuel with
  | 0 => []
  | fuel + 1 =>
    match v with
    | .obj entries =>
      entries.flatMap fun (k, sub) =>
        let here :=
          match k, sub with
          | "pattern", .str p =>
            if Glob.looksLegacy p then [legacyMessage s!"{label}.pattern" p] else []
          | _, _ => []
        here ++ legacyPatternWarnings fuel sub s!"{label}.{k}"
    | .arr items =>
      ((List.range items.length).zip items).flatMap fun (i, item) =>
        legacyPatternWarnings fuel item s!"{label}[{i}]"
    | _ => []

/-! ## コンパイル時テスト -/

-- pyRepr / pyStr
#guard pyRepr .null == "None"
#guard pyRepr (.bool true) == "True"
#guard pyRepr (.num 3 0) == "3"
#guard pyRepr (.num (-30) 1) == "-3.0"
#guard pyRepr (.str "a'b") == "\"a'b\""
#guard pyRepr (.str "a'b\"c") == "'a\\'b\"c'"
#guard pyRepr (.str "t\tn\n") == "'t\\tn\\n'"
#guard pyRepr (.str "\x01") == "'\\x01'"
#guard pyRepr (.str "日") == "'日'"
#guard pyRepr (.arr [.num 1 0, .str "x", .null]) == "[1, 'x', None]"
#guard pyRepr (.obj [("a", .num 1 0), ("b", .bool false)]) == "{'a': 1, 'b': False}"
#guard pyStr (.str "raw") == "raw"
#guard pyStr (.arr [.str "R-1"]) == "['R-1']"

-- pyEq(Python `==`: bool ↔ int ↔ float、dict はキー順非依存)
#guard pyEq (.num 1 0) (.num 10 1)
#guard pyEq (.bool true) (.num 1 0)
#guard pyEq (.bool false) (.num 0 0)
#guard !pyEq (.num 1 0) (.str "1")
#guard pyEq (.obj [("a", .num 1 0), ("b", .num 2 0)]) (.obj [("b", .num 2 0), ("a", .num 1 0)])
#guard !pyEq (.obj [("a", .num 1 0)]) (.obj [("a", .num 1 0), ("b", .num 2 0)])
#guard pyEq (.arr [.num 1 0]) (.arr [.num 10 1])
#guard !pyEq (.arr [.num 1 0]) (.arr [.num 1 0, .num 2 0])

-- pyIn(str コンテナは部分文字列)
#guard pyIn (.str "b") (.str "abc")
#guard pyIn (.str "") (.str "abc")
#guard !pyIn (.num 1 0) (.str "1")
#guard pyIn (.num 1 0) (.arr [.bool true])

-- checkValue: type
#guard checkValue 9 (.str "x") (.obj [("type", .str "string")]) "d" == []
#guard checkValue 9 (.num 3 0) (.obj [("type", .str "string")]) "d"
  == ["d: expected type string, got int"]
#guard checkValue 9 (.num 30 1) (.obj [("type", .str "integer")]) "d"
  == ["d: expected type integer, got float"]
#guard checkValue 9 (.bool true) (.obj [("type", .str "integer")]) "d"
  == ["d: expected type integer, got bool"]
#guard checkValue 9 (.bool true) (.obj [("type", .arr [.str "integer", .str "boolean"])]) "d" == []
#guard checkValue 9 (.num 30 1) (.obj [("type", .str "number")]) "d" == []
#guard checkValue 9 .null (.obj [("type", .arr [.str "string", .str "null"])]) "d" == []
#guard checkValue 9 (.num 3 0) (.obj [("type", .arr [.str "string", .str "null"])]) "d"
  == ["d: expected type ['string', 'null'], got int"]
#guard checkValue 9 (.num 3 0) (.obj [("type", .str "nonsense")]) "d"
  == ["d: expected type nonsense, got int"]
-- type エラー時は以降の検査に進まない(Python の early return)
#guard checkValue 9 (.num 3 0)
  (.obj [("type", .str "string"), ("enum", .arr [.str "a"])]) "d"
  == ["d: expected type string, got int"]

-- enum / const
#guard checkValue 9 (.str "b") (.obj [("enum", .arr [.str "a", .str "b"])]) "d" == []
#guard checkValue 9 (.str "c") (.obj [("enum", .arr [.str "a", .str "b"])]) "d"
  == ["d: 'c' not in enum ['a', 'b']"]
#guard checkValue 9 (.bool true) (.obj [("enum", .arr [.num 1 0])]) "d" == []
#guard checkValue 9 (.num 2 0) (.obj [("const", .num 2 0)]) "d" == []
#guard checkValue 9 (.num 3 0) (.obj [("const", .num 2 0)]) "d" == ["d: 3 != const 2"]

-- pattern(制限グロブ方言、search 意味論)
#guard checkValue 9 (.str "R-123") (.obj [("pattern", .str "^R-")]) "d" == []
#guard checkValue 9 (.str "xR-123") (.obj [("pattern", .str "^R-")]) "d"
  == ["d: 'xR-123' does not match '^R-'"]
#guard checkValue 9 (.num 3 0) (.obj [("pattern", .str "^R-")]) "d" == []

-- minimum / maximum(bool は対象外、非数値の境界は無視)
#guard checkValue 9 (.num 1 0) (.obj [("minimum", .num 2 0)]) "d" == ["d: 1 < minimum 2"]
#guard checkValue 9 (.num 3 0) (.obj [("maximum", .num 2 0)]) "d" == ["d: 3 > maximum 2"]
#guard checkValue 9 (.num 2 0) (.obj [("minimum", .num 2 0), ("maximum", .num 2 0)]) "d" == []
#guard checkValue 9 (.bool true) (.obj [("minimum", .num 2 0)]) "d" == []
#guard checkValue 9 (.num 1 0) (.obj [("minimum", .str "2")]) "d" == []

-- required / properties / additionalProperties
#guard checkValue 9 (.obj [("a", .num 1 0)])
  (.obj [("required", .arr [.str "a", .str "b"])]) "d"
  == ["d: missing required key 'b'"]
#guard checkValue 9 (.obj [("a", .str "x")])
  (.obj [("properties", .obj [("a", .obj [("type", .str "integer")])])]) "d"
  == ["d.a: expected type integer, got str"]
#guard checkValue 9 (.obj [("a", .num 1 0), ("z", .num 2 0)])
  (.obj [("properties", .obj [("a", .obj [])]), ("additionalProperties", .bool false)]) "d"
  == ["d: unexpected key 'z'"]
#guard checkValue 9 (.obj [("z", .num 2 0)])
  (.obj [("additionalProperties", .bool true)]) "d" == []
-- required が文字列なら Python は文字単位に反復する
#guard checkValue 9 (.obj [("a", .num 1 0)]) (.obj [("required", .str "ab")]) "d"
  == ["d: missing required key 'b'"]

-- items / minItems / maxItems
#guard checkValue 9 (.arr [.num 1 0]) (.obj [("minItems", .num 2 0)]) "d"
  == ["d: fewer than 2 items"]
#guard checkValue 9 (.arr [.num 1 0, .num 2 0, .num 3 0]) (.obj [("maxItems", .num 2 0)]) "d"
  == ["d: more than 2 items"]
#guard checkValue 9 (.arr [.str "x", .num 1 0])
  (.obj [("items", .obj [("type", .str "string")])]) "d"
  == ["d[1]: expected type string, got int"]

-- エラーの蓄積順は Python と同一(enum → const → dict ブロック)
#guard checkValue 9 (.obj [("a", .num 1 0)])
  (.obj [("enum", .arr [.str "x"]), ("required", .arr [.str "b"])]) "d"
  == ["d: {'a': 1} not in enum ['x']", "d: missing required key 'b'"]

-- 旧方言検出
#guard legacyPatternWarnings 9
  (.obj [("properties", .obj [("id", .obj [("pattern", .str "^R-\\d+$")])])]) "documents.x.schema"
  == [legacyMessage "documents.x.schema.properties.id.pattern" "^R-\\d+$"]
#guard legacyPatternWarnings 9
  (.obj [("properties", .obj [("id", .obj [("pattern", .str "^R-*$")])])]) "documents.x.schema"
  == []

end Looper.Asl.Check
