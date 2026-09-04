import Looper.Core.Text
import Looper.Core.ShellLex
import Looper.Core.Classify

/-!
`Looper.Core.Classify.ReadOnly` — read-only セッション(I-022 triage /
I-027 essence)の Bash 許可面の純粋部分。旧 Python guard との等価性は差分
ファザーで検証済み(§31.2-17)。

凍結した意味論(旧 pre_tool_guard.py `read_only_session_bash_allow` 由来)の
純粋/IO 分割:

1. **heredoc 文法**(`heredocForm?`)— **bash 行境界**(`\n`)で 2 行以上で、
   先頭行が次の fullmatch に一致し、
   ```
   \s*(?:mkdir\s+-p\s+PATH\s+&&\s+)?cat\s+>\s*PATH\s+<<\s*'(DELIM)'\s*
   PATH  := '([^']+)' | "SAFE+" | SAFE+     SAFE  := [-A-Za-z0-9._/]
   DELIM := [A-Za-z_][A-Za-z0-9_]*
   ```
   かつ最終行の strip がデリミタに一致し、中間行のどの strip もデリミタに
   一致しないとき、生パス(クォート除去後)とデリミタを返す。抽出パスの
   handoff root への解決(`Path.resolve`)と内包判定は IO の責務
   (`resolves_into_handoff` 相当。純粋側の内包判定は `PathAlg.isRelativeTo`)。
2. **複合シェル文法の遮断**(`hasReadOnlyShellMeta`)—
   `re.search(r"[;&|<>`$\r\n]", command)`。heredoc 以外の許可リストに入る
   コマンドから複合文法を締め出す(2 行以上のコマンドは `\n` で必ず落ちる
   ため、以降の分岐は単一行のみが到達する)。
3. **strict shlex**(`strictArgv?`)— `shlex.split`、`ValueError` は none、
   空 argv も none。第 1 部 `tokensLenient` と違い **`str.split()` 退避を
   しない**(Python 実装のこのパスは `except ValueError: return None`)。
4. **mkdir 形状**(`mkdirHandoffArg?`)— `argv == ["mkdir", "-p", p]` の
   生パス抽出。解決・内包判定(非 strict: handoff root 自身も可)は IO。
5. **triage の state 読み取り形状**(`triageStateShape?` /
   `projectFlagValues` / `triageStateSubcommandsOk`)— `<binary> state
   <args...>`(argv 3 個以上、`bin/<tool> state` 綴り)
   から binary 生パスと唯一の `--project` 生値を取る。バイナリ実体照合
   (CONTROL_ROOT/bin/<tool> への解決一致)と project 解決照合は IO。
   サブコマンド集合は `statePySubcommands`(第 1 部)の非空 ∧
   ⊆ {should-stop, status}。
6. **許可理由文字列** — Python の f-string とバイト一致(§31.2-8 以降の慣行)。

バックトラック消去が受理同値になる根拠(fullmatch の直訳):
- 各 `\s+`/`\s*` の直後に要求される文字(`m` `c` `-` `&` `>` `<` `'` と
  PATH の先頭文字)はいずれも `\s` に属さないため、空白の貪欲な極大 munch は
  バックトラックと同値。
- PATH の 3 択は先頭 1 文字(`'` / `"` / SAFE)で互いに素に分岐する。
  シングルクォート形の `[^']+` は次の `'` まで、bare/double 形の SAFE run は
  極大でよい(SAFE は `\s` `&` `<` `"` を含まないため、run 直後に各継続が
  要求する文字と重ならない)。クォート形の閉じ不成立時に他の選択肢へ
  戻っても先頭のクォート文字では一致し得ない。
- 省略可能な mkdir 節は、完全に読めたときだけ採用してよい(節の先頭
  `mkdir` と後続の `cat` は先頭文字 `m` ≠ `c` で互いに素。節が読めた入力で
  節をスキップする別解は `cat` の一致に失敗する)。
- デリミタはクォートで挟まれ一意。

CPython 実挙動の非自明点(実測で固定、#guard に焼き込み):
- **heredoc の行分割は bash 意味論(`\n` のみ、`Text.splitLinesBash`)を使う。**
  旧実装は `str.splitlines()`(`\x0b` `\x0c` `\x1c`〜`\x1e` `\x85` U+2028/2029
  も境界)を使っていたが、bash はこれらを 1 コマンド行の内側の文字として
  扱う。この差で `<<'EOF'\x0b; rm ...` のヘッダ後半が Python 側では「別の行」
  に見えて fullmatch を通過し、`;` 以降が read-only セッションで allow されて
  いた(I-022/I-027 破れ、2026-07-27 修正)。bash 境界に揃えるとヘッダは注入を
  含む line 1 全体になり、fullmatch 失敗 → shell メタ deny(`hasReadOnlyShellMeta`
  は `;`/`&` を検出)へ落ちる。これは Python からの意図的な逸脱(deny 拡大、
  R-6 自動採用)である。
- ヘッダ内の `\s` は NBSP(U+00A0)等の Unicode 空白を含む
  (`Text.isPySpace`)。`cat\xa0>` はヘッダとして成立する。
- 末尾行の判定は `lines[-1]` であり、末尾の行境界 1 個は空行を生まない
  (`"...\nEOF\n"` は受理、`"...\nEOF\n\n"` は最終行が空になり不受理)。

方言差なし: 本モジュールの文字クラスはすべて ASCII リテラル(`\w`/`\b`/`\d`
不使用)で、`\s` は `isPySpace` と同一集合。
-/

namespace Looper.Core.Classify

open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (isPySpace splitLinesBash pyStrip)

/-- heredoc ヘッダから抽出される形。パスは生文字列(クォート除去後)で、
handoff root への解決・内包判定は IO の責務。 -/
structure HeredocForm where
  mkdirRaw : Option String
  targetRaw : String
  delim : String
deriving Repr, BEq

/-- `[-A-Za-z0-9._/]`(原文の `safe_bare` は `-` が末尾だが同一集合。`-` を
先頭へ移して Lean コメントのコメント開始列との衝突を避ける、Bash.lean の
pathish と同じ慣行)。bare / double-quoted パスの安全文字クラス。展開・
グロブ・語分割を起こす文字を含まない)。 -/
def isSafeBareChar (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')
    || c == '.' || c == '_' || c == '/' || c == '-'

/-- `[A-Za-z_]`(heredoc デリミタの先頭)。 -/
def isDelimStart (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || c == '_'

/-- `[A-Za-z0-9_]`(heredoc デリミタの 2 文字目以降)。 -/
def isDelimChar (c : Char) : Bool :=
  isDelimStart c || ('0' ≤ c && c ≤ '9')

/-- `\s+`(1 文字以上、極大 munch)。 -/
private def ws1? : List Char → Option (List Char)
  | c :: rest => if isPySpace c then some (rest.dropWhile isPySpace) else none
  | [] => none

/-- PATH 1 個(`'([^']+)'` | `"SAFE+"` | `SAFE+`)。成功時は (生値, 残り)。
先頭 1 文字で 3 択が互いに素なため決定的(頭注参照)。 -/
private def parsePath? : List Char → Option (String × List Char)
  | '\'' :: rest =>
    let content := rest.takeWhile (· != '\'')
    if content.isEmpty then none
    else match rest.drop content.length with
      | '\'' :: rest' => some (String.ofList content, rest')
      | _ => none
  | '"' :: rest =>
    let content := rest.takeWhile isSafeBareChar
    if content.isEmpty then none
    else match rest.drop content.length with
      | '"' :: rest' => some (String.ofList content, rest')
      | _ => none
  | cs =>
    let content := cs.takeWhile isSafeBareChar
    if content.isEmpty then none
    else some (String.ofList content, cs.drop content.length)

/-- `mkdir\s+-p\s+PATH\s+&&\s+` 節。成功時は (path 生値, 残り)。 -/
private def parseMkdirClause? (cs : List Char) : Option (String × List Char) := do
  let r ← dropLit? cs "mkdir".toList
  let r ← ws1? r
  let r ← dropLit? r "-p".toList
  let r ← ws1? r
  let (p, r) ← parsePath? r
  let r ← ws1? r
  let r ← dropLit? r "&&".toList
  let r ← ws1? r
  pure (p, r)

/-- ヘッダ行の fullmatch(頭注の文法)。 -/
def heredocHeader? (line : String) : Option HeredocForm := do
  let cs := line.toList.dropWhile isPySpace
  let (mkdirRaw, cs) :=
    match parseMkdirClause? cs with
    | some (p, rest) => (some p, rest)
    | none => (none, cs)
  let r ← dropLit? cs "cat".toList
  let r ← ws1? r
  let r ← dropLit? r ">".toList
  let r := r.dropWhile isPySpace
  let (target, r) ← parsePath? r
  let r ← ws1? r
  let r ← dropLit? r "<<".toList
  let r := r.dropWhile isPySpace
  let r ← dropLit? r "'".toList
  let (delim, r) ← match r with
    | c :: rest =>
      if isDelimStart c then
        let tail := rest.takeWhile isDelimChar
        some (String.ofList (c :: tail), rest.drop tail.length)
      else none
    | [] => none
  let r ← dropLit? r "'".toList
  if (r.dropWhile isPySpace).isEmpty then
    pure ⟨mkdirRaw, target, delim⟩
  else none

/-- heredoc 文法全体: **bash 行境界**(`\n`)で 2 行以上、ヘッダ fullmatch、
最終行の strip == delim、中間行に strip == delim なし(早すぎるデリミタは
以降がシェルに渡る脱出になるため不受理)。行分割に Python `splitlines()` を
使うと、bash が line 1 に載せ続ける `<<'EOF'\x0b; rm ...` の後半が「別の行」に
見えてヘッダ fullmatch を通過し、`;` 以降の注入コマンドが allow されていた
(I-022/I-027 の read-only 封じ込め破れ、2026-07-27)。bash の行境界に揃えると、
ヘッダは注入を含む line 1 全体になり fullmatch に失敗 → shell メタ deny に落ちる。 -/
def heredocForm? (command : String) : Option HeredocForm :=
  match splitLinesBash command with
  | header :: body@(_ :: _) =>
    match heredocHeader? header, body.getLast? with
    | some form, some lastLine =>
      if pyStrip lastLine == form.delim
          && !(body.dropLast.any fun l => pyStrip l == form.delim) then
        some form
      else none
    | _, _ => none
  | _ => none

/-- **本体ガード前段の heredoc 本文除外**(§11.3、G-T1 の是正)。

本体ガードは分類のすべてを生コマンド文字列への照合で行うため、quoted heredoc の
**本文**まで実行文として読まれる。本文は `cat` の標準入力へ渡るデータであって
1 文字も実行されないのに、その中のパス風文字列(`.<tool>/state/...`)や語
(`git commit`)が deny を発火させていた。実走行では「長い Bash heredoc はガードに
誤解析される」という注意書きが handoff で伝承されるところまで行った
(META.md §31.3 の G-T1 が既知として自認していた穴)。

`heredocForm?` が受理する形 —
```
[mkdir -p PATH && ] cat > PATH <<'DELIM'
  …本文…
DELIM
```
— は文法的に「ヘッダ 1 行 + 本文 + 終端デリミタ」で閉じている: 早すぎる
デリミタも末尾の追加コマンドも不受理なので、**ヘッダ以外に実行される文字列は
存在しない**。したがって照合対象をヘッダ 1 行へ縮めてよい。リダイレクト先の
パスはヘッダに載っているので、保護パス・zone・control-surface の判定はすべて
従来どおり効く(`cat > .<tool>/state/todo.json <<'EOF'` は今も deny)。

デリミタが**クォートされていない**形(`<<EOF`)は `heredocForm?` が受理しない
ため対象外 — 本文で変数・コマンド置換が起こり得る以上、本文を実行文として
読み続ける方が正しい(fail-closed)。 -/
def heredocExecutedText (command : String) : String :=
  match heredocForm? command with
  | some _ =>
    match splitLinesBash command with
    | header :: _ => header
    | [] => command
  | none => command

/-- `re.search(r"[;&|<>`$\r\n]", command)` 等価(heredoc 以外の許可リストは
複合シェル文法を一切許さない)。 -/
def hasReadOnlyShellMeta (command : String) : Bool :=
  command.toList.any fun c =>
    c == ';' || c == '&' || c == '|' || c == '<' || c == '>'
      || c == '`' || c == '$' || c == '\r' || c == '\n'

/-- `shlex.split(command)`、`ValueError` は none、空 argv も none。第 1 部の
`tokensLenient` と違い `str.split()` 退避をしない(Python 実装のこのパスは
`except ValueError: return None`)。 -/
def strictArgv? (command : String) : Option (List String) :=
  match ShellLex.split command with
  | .ok [] => none
  | .ok toks => some toks
  | .error _ => none

/-- `argv[:2] == ["mkdir", "-p"] and len(argv) == 3` の生パス抽出。 -/
def mkdirHandoffArg? : List String → Option String
  | ["mkdir", "-p", p] => some p
  | _ => none

/-- `targets_expected_project` の値抽出部: `--project <v>`(直後トークン。
消費せず全走査 — 直後トークン自身も次の反復で照合される)と
`--project=<v>`(最初の `=` 以降)の両形、出現順。 -/
def projectFlagValues : List String → List String
  | [] => []
  | "--project" :: next :: rest => next :: projectFlagValues (next :: rest)
  | tok :: rest =>
    if tok.startsWith "--project=" then
      (tok.drop "--project=".length).toString :: projectFlagValues rest
    else projectFlagValues rest

/-- ちょうど 1 個の `--project` 値(`len(values) != 1` は不成立)。 -/
def projectFlagValue? (args : List String) : Option String :=
  match projectFlagValues args with
  | [v] => some v
  | _ => none

/-- triage の state 読み取り形状(純粋部): `<binary> state <args...>`
(argv 3 個以上)から (binary 生パス, --project 生値)。実体照合
(CONTROL_ROOT/bin/<tool> への解決一致)は IO 側の表引きが行う。 -/
def triageStateShape? : List String → Option (String × String)
  | binary :: "state" :: rest@(_ :: _) =>
    (projectFlagValue? rest).map fun proj => (binary, proj)
  | _ => none

/-- `state_py_subcommands(command) <= {"should-stop", "status"} and
state_py_subcommands(command)`(非空かつ全部が read-only の 2 種)。 -/
def triageStateSubcommandsOk (d : Domain) (command : String) : Bool :=
  let subs := statePySubcommands d command
  !subs.isEmpty && subs.all fun s => s == "should-stop" || s == "status"

/-! ## 許可理由(Python の f-string とバイト一致) -/

/-- `f"{mode} read-only handoff write (I-022/I-027)"`。 -/
def handoffWriteReason (mode : String) : String :=
  s!"{mode} read-only handoff write (I-022/I-027)"

/-- `f"{mode} handoff directory creation (I-022/I-027)"`。 -/
def handoffMkdirReason (mode : String) : String :=
  s!"{mode} handoff directory creation (I-022/I-027)"

/-- `f"{mode} read-only state inspection (I-022/I-027)"`。 -/
def stateInspectionReason (mode : String) : String :=
  s!"{mode} read-only state inspection (I-022/I-027)"

/-! ## コンパイル時検査(期待値はすべて pre_tool_guard.py の実文法・実関数の
CPython 3.14 実測) -/

-- heredocForm?: 受理形
#guard heredocForm? "cat > h/x <<'EOF'\nbody\nEOF"
  == some ⟨none, "h/x", "EOF"⟩
#guard heredocForm? "cat > h/x <<'EOF'\nEOF" == some ⟨none, "h/x", "EOF"⟩
#guard heredocForm? "  cat  >  h/x  <<  'EOF'  \nbody\nEOF"
  == some ⟨none, "h/x", "EOF"⟩
#guard heredocForm? "\tcat\t>\th/x\t<<'D_1'\nx\nD_1" == some ⟨none, "h/x", "D_1"⟩
#guard heredocForm? "cat >h/x <<'E'\nb\nE" == some ⟨none, "h/x", "E"⟩
#guard heredocForm? "cat > h/x <<'_e9'\nb\n_e9" == some ⟨none, "h/x", "_e9"⟩
#guard heredocForm? "cat > 'h/a b' <<'E'\nb\nE" == some ⟨none, "h/a b", "E"⟩
#guard heredocForm? "cat > \"h/ab\" <<'E'\nb\nE" == some ⟨none, "h/ab", "E"⟩
#guard heredocForm? "cat > h/x <<'EOF'\nbody\n EOF\t" == some ⟨none, "h/x", "EOF"⟩
#guard heredocForm? "cat > h/x <<'EOF'\nbody\nEOF\n" == some ⟨none, "h/x", "EOF"⟩
#guard heredocForm? "mkdir -p h && cat > h/x <<'E'\nb\nE"
  == some ⟨some "h", "h/x", "E"⟩
#guard heredocForm? "mkdir -p 'h dir' && cat > h/x <<'E'\nb\nE"
  == some ⟨some "h dir", "h/x", "E"⟩
#guard heredocForm? "mkdir -p \"hd\" && cat > h/x <<'E'\nb\nE"
  == some ⟨some "hd", "h/x", "E"⟩
#guard heredocForm? "mkdir  -p  h  &&  cat > h/x <<'E'\nb\nE"
  == some ⟨some "h", "h/x", "E"⟩
-- bash 行境界は `\n` のみ: Python が行境界にする `\x0b` `\x0c` U+2028 を
-- ヘッダに挟んだ形は bash では 1 行のまま。ヘッダ後半が fullmatch を壊すため
-- none に落ち、shell メタ deny へ回る(read-only 注入封止、2026-07-27)。
-- 末尾の `\x1c` / ヘッダ内の NBSP は pyStrip/\s が食う空白なので従来どおり。
#guard heredocForm? "cat > h/x <<'E'\x0bb\nE" == none
#guard heredocForm? "cat > h/x <<'EOF'\x0b; rm -rf /\nbody\nEOF" == none
#guard heredocForm? "cat > h/x <<'E'\x0cb\x0cE" == none
#guard heredocForm? "cat > h/x <<'E'\u2028b\u2028E" == none
#guard heredocForm? "cat > h/x <<'E'\nb\nE\x1c" == some ⟨none, "h/x", "E"⟩
#guard heredocForm? "cat\u00A0> h/x <<'E'\nb\nE" == some ⟨none, "h/x", "E"⟩
#guard heredocForm? "cat > h/x\u00A0<<'E'\nb\nE" == some ⟨none, "h/x", "E"⟩
-- heredocForm?: 不受理形
#guard heredocForm? "cat > h/x <<'EOF'\nbody" == none
#guard heredocForm? "cat > h/x <<'EOF'\nEOF\nEOF" == none
#guard heredocForm? "cat > h/x <<'EOF'\n EOF \ntail\nEOF" == none
#guard heredocForm? "cat > h/x <<'EOF'\nbody\nEOF\n\n" == none
#guard heredocForm? "cat > h/x <<'EOF'" == none
#guard heredocForm? "cat> h/x <<'E'\nb\nE" == none
#guard heredocForm? "cat > h/x<<'E'\nb\nE" == none
#guard heredocForm? "cat > h/x <<'E' extra\nb\nE" == none
#guard heredocForm? "cat > h/x <<E\nb\nE" == none
#guard heredocForm? "cat > h/x <<\"E\"\nb\nE" == none
#guard heredocForm? "cat > h/x <<'1E'\nb\n1E" == none
#guard heredocForm? "cat > h/x <<''\nb\n" == none
#guard heredocForm? "cat > \"h/a b\" <<'E'\nb\nE" == none
#guard heredocForm? "cat > 'h/a'b <<'E'\nb\nE" == none
#guard heredocForm? "cat > 'h/x'\"y\" <<'E'\nb\nE" == none
#guard heredocForm? "cat > '' <<'E'\nb\nE" == none
#guard heredocForm? "cat > h/€x <<'E'\nb\nE" == none
#guard heredocForm? "mkdir -p h x && cat > h/x <<'E'\nb\nE" == none
#guard heredocForm? "mkdir -p h && mkdir -p h && cat > h/x <<'E'\nb\nE" == none
#guard heredocForm? "mkdir -p h &&& cat > h/x <<'E'\nb\nE" == none
#guard heredocForm? "mkdir -p h && cat > h/x <<'E' && rm x\nb\nE" == none
#guard heredocForm? "mkdir -p h&&cat > h/x <<'E'\nb\nE" == none
#guard heredocForm? "mkdir -P h && cat > h/x <<'E'\nb\nE" == none
#guard heredocForm? "MKDIR -p h && cat > h/x <<'E'\nb\nE" == none
#guard heredocForm? "echo hi && cat > h/x <<'E'\nb\nE" == none
#guard heredocForm? "cat > 'h/x' <<'E'\nE\nb\nE" == none

-- heredocExecutedText: 受理形はヘッダ 1 行へ縮む / 非受理形は素通し
#guard heredocExecutedText "cat > h/x <<'EOF'\ngit commit -m x\nEOF"
  == "cat > h/x <<'EOF'"
#guard heredocExecutedText "mkdir -p h && cat > h/x <<'E'\nrm -rf /\nE"
  == "mkdir -p h && cat > h/x <<'E'"
-- 展開が起こり得る非クォート デリミタは縮めない(fail-closed)
#guard heredocExecutedText "cat > h/x <<EOF\ngit commit\nEOF"
  == "cat > h/x <<EOF\ngit commit\nEOF"
-- 早すぎるデリミタ・末尾コマンドは heredocForm? が落とすので素通し
#guard heredocExecutedText "cat > h/x <<'E'\nE\nrm -rf /\nE"
  == "cat > h/x <<'E'\nE\nrm -rf /\nE"
#guard heredocExecutedText "echo hi" == "echo hi"

-- hasReadOnlyShellMeta
#guard hasReadOnlyShellMeta "mkdir -p x; ls" == true
#guard hasReadOnlyShellMeta "mkdir -p `ls`" == true
#guard hasReadOnlyShellMeta "mkdir -p $X" == true
#guard hasReadOnlyShellMeta "a > b" == true
#guard hasReadOnlyShellMeta "a\rb" == true
#guard hasReadOnlyShellMeta "mkdir -p 'x y'" == false
#guard hasReadOnlyShellMeta "a\x0bb" == false

-- strictArgv?
#guard strictArgv? "mkdir -p x" == some ["mkdir", "-p", "x"]
#guard strictArgv? "mkdir -p 'x" == none
#guard strictArgv? "" == none
#guard strictArgv? "   " == none
#guard strictArgv? "mkdir -p 'a b'" == some ["mkdir", "-p", "a b"]

-- mkdirHandoffArg?
#guard mkdirHandoffArg? ["mkdir", "-p", "x"] == some "x"
#guard mkdirHandoffArg? ["mkdir", "-p", "x", "y"] == none
#guard mkdirHandoffArg? ["mkdir", "x"] == none
#guard mkdirHandoffArg? ["mkdir", "-p"] == none

-- projectFlagValues / projectFlagValue?(実測: probe_readonly の loop 逐語)
#guard projectFlagValues ["--project", "x"] == ["x"]
#guard projectFlagValues ["--project"] == []
#guard projectFlagValues ["--project=x"] == ["x"]
#guard projectFlagValues ["--project=a=b"] == ["a=b"]
#guard projectFlagValues ["--project", "--project", "x"] == ["--project", "x"]
#guard projectFlagValues ["--project", "--project=x"] == ["--project=x", "x"]
#guard projectFlagValues ["a", "--project=", "b"] == [""]
#guard projectFlagValues ["--projectx=1"] == []
#guard projectFlagValues ["--Project", "x"] == []
#guard projectFlagValues ["--project", "x", "--project=y"] == ["x", "y"]
#guard projectFlagValues ["x", "--project", "--project"] == ["--project"]
#guard projectFlagValue? ["--project", "x"] == some "x"
#guard projectFlagValue? ["--project", "x", "--project=y"] == none
#guard projectFlagValue? ["s"] == none

-- triageStateShape?
#guard triageStateShape? ["bin/looper", "state", "--project", "p", "status"]
  == some ("bin/looper", "p")
#guard triageStateShape? ["bin/looper", "state", "--project=p", "status"]
  == some ("bin/looper", "p")
#guard triageStateShape? ["/cr/bin/looper", "state", "--project", "p", "status"]
  == some ("/cr/bin/looper", "p")
#guard triageStateShape? ["bin/looper", "status", "--project", "p"] == none
#guard triageStateShape? ["bin/looper", "state"] == none
#guard triageStateShape? ["bin/looper", "state", "status"] == none
-- 旧 python3 綴りは受理形に含まれない(deny 側へ倒れる)
#guard triageStateShape? ["python3", "scripts/state.py", "--project", "p", "status"]
  == none

-- triageStateSubcommandsOk
#guard triageStateSubcommandsOk Domain.fixture "bin/looper state --project p should-stop"
  == true
#guard triageStateSubcommandsOk Domain.fixture "bin/looper state --project p status" == true
#guard triageStateSubcommandsOk Domain.fixture "bin/looper state --project p validate"
  == false
#guard triageStateSubcommandsOk Domain.fixture "bin/looper state --project p" == false
#guard triageStateSubcommandsOk Domain.fixture
  "bin/looper state status; bin/looper state should-stop" == true
#guard triageStateSubcommandsOk Domain.fixture "python3 scripts/state.py --project p status" == true

-- 許可理由
#guard handoffWriteReason "triage" == "triage read-only handoff write (I-022/I-027)"
#guard handoffMkdirReason "essence"
  == "essence handoff directory creation (I-022/I-027)"
#guard stateInspectionReason "triage"
  == "triage read-only state inspection (I-022/I-027)"

end Looper.Core.Classify
