/-!
`Looper.Core.ShellLex` — POSIX shlex 等価の字句解析器(LEAN_MIGRATION_PLAN.md §4.2)。

guard 判定 6 箇所(pre_tool_guard.py の `shlex.split` 呼び出し)の共通基盤。
Python `shlex.split(s)`(= posix=True・whitespace_split=True・comments=False)の
実挙動を正とし、CPython 3.14 `shlex.shlex.read_token` の状態機械を全域関数として
写し取る。等価性は差分ファザー(10 万件以上)で検証済み(§31.2-11)。

写し取った意味論(CPython ソース準拠、実測で確認済み):

- 空白は `' '` `'\t'` `'\r'` `'\n'` の 4 文字のみ。Unicode 空白・`\x0c`(FF)・
  `\x0b`(VT)は語構成文字。
- シングルクォート内は一切のエスケープなし(`\` もリテラル)。
- ダブルクォート内の `\` は直後が `"` または `\` のときだけエスケープとして
  解決し、それ以外は `\` ごとリテラルに残る(`"a\nb"` → `a\nb` の 4 文字)。
- クォート外の `\` は直後の 1 文字を無条件にリテラル化する。改行も対象で、
  シェルの行継続(除去)とは違い **リテラル改行になる**(`a\<LF>b` → `a<LF>b`)。
- 隣接連結: `cl""aude` → `claude`、`x="1 2"y` → `x=1 2y`。
- クォートされた空トークンは残る: `'' ''` → `["", ""]`。
- `#` はコメントではなく語構成文字(comments=False)。`;` `|` `&` 等の
  シェルメタ文字も単なる語構成文字(セグメント分割は上位層の責務)。
- 未閉クォート → `ValueError("No closing quotation")` ≙ `.unclosedQuote`。
- 入力末尾の `\` → `ValueError("No escaped character")` ≙ `.danglingEscape`。
  ダブルクォート内で `\` の直後に EOF が来た場合も CPython と同じく
  `.danglingEscape`(escape 状態が quote 状態より先に EOF を見る)。

エラー時のフォールバック(Python guard の `str.split()` 退避)は本モジュールでは
行わない。「字句解析不能」を `Except` の値として返し、扱いは呼び出し側の責務に
する(§4.1 裁定 1 の「厳しい側に倒す」判断は guard の決定木側で実装する)。

`Token` は値(クォート・エスケープ解決後)に加えて元表層 `surface` を保持する
(`bash -c` ネスト再帰で表層文字列を使うため。§4.2)。surface はそのトークンに
寄与した入力文字の連続区間そのもので、トークン間の区切り空白は含まない。
-/

namespace Looper.Core.ShellLex

/-- 字句解析エラー。CPython `shlex` の `ValueError` メッセージと 1:1 対応。 -/
inductive LexError where
  /-- `ValueError("No closing quotation")` 相当(EOF がクォート内)。 -/
  | unclosedQuote
  /-- `ValueError("No escaped character")` 相当(EOF が `\` の直後)。 -/
  | danglingEscape
deriving Repr, BEq

/-- トークン。`value` は解決後の値(`shlex.split` の要素と一致)、`surface` は
入力中の元表層(そのトークンの開始文字から終了文字まで)。 -/
structure Token where
  value : String
  surface : String
deriving Repr, BEq

/-- `shlex.whitespace = " \t\r\n"`(Python と同一。これ以外は空白扱いしない)。 -/
def isWhitespace (c : Char) : Bool :=
  c == ' ' || c == '\t' || c == '\r' || c == '\n'

/-- 構築途中のトークン(解決後の値と元表層を並行して蓄積する)。 -/
private structure Acc where
  value : String
  surface : String

/-- 値・表層の両方に 1 文字追加。 -/
private def Acc.push (a : Acc) (c : Char) : Acc :=
  ⟨a.value.push c, a.surface.push c⟩

/-- 表層のみに追加(クォート記号・エスケープ記号など、値に現れない文字)。 -/
private def Acc.pushSurface (a : Acc) (c : Char) : Acc :=
  ⟨a.value, a.surface.push c⟩

private def Acc.toToken (a : Acc) : Token :=
  ⟨a.value, a.surface⟩

/-- 状態機械のモード。CPython `read_token` の `self.state` に対応する。

`word` は CPython の `'a'` と「トークン蓄積中の `' '`」の両状態を畳み込んだもの
(commenters が空・punctuation_chars が空の設定では両者の遷移が一致するため)。
escape の戻り先(`escapedstate`)はクォート外なら常に word、ダブルクォート内なら
doubleQ で、これをモード自体に畳み込む。 -/
private inductive Mode where
  | word
  | singleQ
  | doubleQ
  | escWord
  | escDouble

/-- 1 文字ずつ消費する全域の状態機械(構造的再帰)。`acc? = none` はトークン間。
出力トークンは逆順に積み、最後に反転する。 -/
private def go : List Char → Option (Mode × Acc) → List Token →
    Except LexError (List Token)
  | [], none, toks => .ok toks.reverse
  | [], some (mode, acc), toks =>
    match mode with
    | .word => .ok (acc.toToken :: toks).reverse
    | .singleQ | .doubleQ => .error .unclosedQuote
    | .escWord | .escDouble => .error .danglingEscape
  | c :: rest, none, toks =>
    if isWhitespace c then
      go rest none toks
    else if c == '\\' then
      go rest (some (.escWord, ⟨"", "\\"⟩)) toks
    else if c == '\'' then
      go rest (some (.singleQ, ⟨"", "'"⟩)) toks
    else if c == '"' then
      go rest (some (.doubleQ, ⟨"", "\""⟩)) toks
    else
      go rest (some (.word, ⟨String.singleton c, String.singleton c⟩)) toks
  | c :: rest, some (mode, acc), toks =>
    match mode with
    | .word =>
      if isWhitespace c then
        go rest none (acc.toToken :: toks)
      else if c == '\\' then
        go rest (some (.escWord, acc.pushSurface c)) toks
      else if c == '\'' then
        go rest (some (.singleQ, acc.pushSurface c)) toks
      else if c == '"' then
        go rest (some (.doubleQ, acc.pushSurface c)) toks
      else
        go rest (some (.word, acc.push c)) toks
    | .singleQ =>
      if c == '\'' then
        go rest (some (.word, acc.pushSurface c)) toks
      else
        go rest (some (.singleQ, acc.push c)) toks
    | .doubleQ =>
      if c == '"' then
        go rest (some (.word, acc.pushSurface c)) toks
      else if c == '\\' then
        go rest (some (.escDouble, acc.pushSurface c)) toks
      else
        go rest (some (.doubleQ, acc.push c)) toks
    | .escWord =>
      go rest (some (.word, acc.push c)) toks
    | .escDouble =>
      if c == '"' || c == '\\' then
        go rest (some (.doubleQ, acc.push c)) toks
      else
        go rest (some (.doubleQ, ⟨(acc.value.push '\\').push c, acc.surface.push c⟩))
          toks

/-- 入力全体をトークン列へ。`shlex.split` が `ValueError` を投げる入力では
`.error`(種別は docstring の対応表どおり)。 -/
def tokenize (input : String) : Except LexError (List Token) :=
  go input.toList none []

/-- `shlex.split(input)` 等価(値のみ)。 -/
def split (input : String) : Except LexError (List String) :=
  (tokenize input).map (List.map Token.value)

/-- #guard 用: エラー種別の取り出し。 -/
private def lexErrorOf? (input : String) : Option LexError :=
  match tokenize input with
  | .error e => some e
  | .ok _ => none

-- 基本の分割と空白の扱い(期待値はすべて CPython 3.14 `shlex.split` の実測)
#guard (split "").toOption == some []
#guard (split "   ").toOption == some []
#guard (split "a b").toOption == some ["a", "b"]
#guard (split "  a\t\nb\r  ").toOption == some ["a", "b"]
#guard (split "a\x0bb").toOption == some ["a\x0bb"]
#guard (split "a\x0cb").toOption == some ["a\x0cb"]
#guard (split "a #b").toOption == some ["a", "#b"]
#guard (split "a;b|c&d").toOption == some ["a;b|c&d"]
#guard (split "あ 'あ い'").toOption == some ["あ", "あ い"]
#guard (split "a\x00b").toOption == some ["a\x00b"]

-- クォートと隣接連結
#guard (split "'a b'").toOption == some ["a b"]
#guard (split "cl\"\"aude").toOption == some ["claude"]
#guard (split "''").toOption == some [""]
#guard (split "'' ''").toOption == some ["", ""]
#guard (split "a''b").toOption == some ["ab"]
#guard (split "a'b\"c'd").toOption == some ["ab\"cd"]
#guard (split "\"a'b\"").toOption == some ["a'b"]
#guard (split "--flag='v a l'").toOption == some ["--flag=v a l"]
#guard (split "x=\"1 2\"y").toOption == some ["x=1 2y"]

-- エスケープ(クォート外: 次の 1 文字を無条件リテラル化。改行も)
#guard (split "a\\ b").toOption == some ["a b"]
#guard (split "\\a").toOption == some ["a"]
#guard (split "a\\\nb").toOption == some ["a\nb"]
#guard (split "  \\ ").toOption == some [" "]
#guard (split "\\\\").toOption == some ["\\"]

-- エスケープ(シングルクォート内は無効、ダブルクォート内は `\"` と `\\` のみ)
#guard (split "'\\'").toOption == some ["\\"]
#guard (split "\"a\\\"b\"").toOption == some ["a\"b"]
#guard (split "\"\\\\\"").toOption == some ["\\"]
#guard (split "\"a\\nb\"").toOption == some ["a\\nb"]
#guard (split "\"\\`\"").toOption == some ["\\`"]

-- エラー(フォールバックなし。§4.1 裁定 1)
#guard lexErrorOf? "a\\" == some .danglingEscape
#guard lexErrorOf? "\\" == some .danglingEscape
#guard lexErrorOf? "'a" == some .unclosedQuote
#guard lexErrorOf? "\"a" == some .unclosedQuote
#guard lexErrorOf? "\"a\\\"" == some .unclosedQuote
#guard lexErrorOf? "\"a\\" == some .danglingEscape
#guard lexErrorOf? "a b 'c" == some .unclosedQuote

-- 表層(surface)の保持
#guard (tokenize "  'a b'  x").toOption == some [⟨"a b", "'a b'"⟩, ⟨"x", "x"⟩]
#guard (tokenize "a\\ b").toOption == some [⟨"a b", "a\\ b"⟩]
#guard (tokenize "cl\"\"aude").toOption == some [⟨"claude", "cl\"\"aude"⟩]
#guard (tokenize "\"a\\nb\"").toOption == some [⟨"a\\nb", "\"a\\nb\""⟩]
#guard (tokenize "bash -c 'echo hi'").toOption ==
    some [⟨"bash", "bash"⟩, ⟨"-c", "-c"⟩, ⟨"echo hi", "'echo hi'"⟩]

/-! ## 全域性の観測的帰結(証明層 `proofs/` の土台 — LEAN_MIGRATION_PLAN.md §4.6 B-T2)

`go` は `List Char` の構造的再帰による全域関数であり(`partial` なし —
§31.4-1 の純度ゲートが機械検査)、停止性は定義の型検査そのものが保証する。
`go` は private のため、その観測的帰結(出力トークン数の入力長による有界性)
はここで定理化して公開する(`Core/Json` の `set`/`get?` 代数と同じ扱い。
挙動追加なし — 実行コードは本節に依存しない)。 -/

/-- `go` の成功出力は「確定済みトークン + 入力文字数 + 蓄積中トークン高々 1」
で抑えられる: トークンが閉じるのは空白消費時(1 文字につき高々 1)と EOF 時
(高々 1)のみ、という状態機械の消費規律。 -/
private theorem go_ok_length : ∀ (cs : List Char) (st : Option (Mode × Acc))
    (toks res : List Token), go cs st toks = .ok res →
    res.length ≤ toks.length + cs.length + 1 := by
  intro cs
  induction cs with
  | nil =>
    -- EOF: 確定分 + 蓄積中高々 1 で閉じる(エラー葉は反射で消える)
    intro st toks res h
    rcases st with _ | ⟨mode, acc⟩ <;> try cases mode
    all_goals simp only [go] at h
    all_goals first
      | (injection h with h; subst h; simp; try omega)
      | exact absurd h (by simp)
  | cons c rest ih =>
    -- 1 文字消費: どの遷移でも確定トークンは高々 1 増える(word の空白分岐のみ)
    intro st toks res h
    rcases st with _ | ⟨mode, acc⟩ <;> try cases mode
    all_goals simp only [go] at h
    all_goals repeat' split at h
    all_goals (
      have hb := ih _ _ _ h
      try simp only [List.length_cons] at hb ⊢
      omega)

/-- **出力有界性**: `tokenize` が返すトークン数は入力文字数 + 1 を超えない。
全域性(構造的再帰)の帰納構造をそのまま消費規律の証明に使えることの
witness であり、B-T2 の観測面。 -/
theorem tokenize_length_le (input : String) (toks : List Token)
    (h : tokenize input = .ok toks) : toks.length ≤ input.length + 1 := by
  simpa [String.length] using go_ok_length input.toList none [] toks h

end Looper.Core.ShellLex
