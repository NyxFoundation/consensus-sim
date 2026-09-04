import Looper.Core.Json
import Looper.Core.Text
import Looper.Core.PathAlg
import Looper.Core.Glob
import Looper.Core.ShellLex
import Looper.Core.Frag

/-!
`Looper.Asl.Hooks` — agentic-state-loop レシピの hooks 3 本
(`asl-loop hook pre-tool|post-tool|session-start` の判定部)の純粋決定核。

判定はすべて本モジュールの純粋関数が行い、外部状態(stdin payload・解決済み
パス・schema.json・現在時刻)は `Looper.Cli.AslHook`(IO シェル)が注入する
(§3.3-3 の 3 手)。live 版 guard(`Guard.*`)とは別系統 — レシピ hooks は
Over-Project 側の語彙を持たず、`LOOP_DIR` 名を実行時に導出する自己完結面である
(§6.2・§17・§29)。

LOOP_DIR 名の置換トークン(instantiation 時に settings/justfile/prompts が
受ける記号)は本モジュールには現れない。このソースは vendoring 先へバイト同一で
複製されるので、リテラルのトークンを含めないことが「置換トークン残存なし」の
post-install 検査(vendored `lean/` を含む全ファイル対象)をそのまま通す前提に
なる。LOOP_DIR 名は IO シェルが実行ファイル配置(`<loop_dir>/bin/asl-loop`)から
導出して注入する。

**正規表現 → 判定関数の等価性(R-5、META.md §31.2-29)**:
正規表現エンジンは書かず、各パターンを「断片マッチャ `Frag`(接尾辞を消費して
残りを返す)+ 全開始位置の走査」に直訳する(live 版 `Core.Classify.Bash` と同じ
原理)。本カタログのバックトラック消去が受理同値になる根拠は各所に注記する。

CPython `re` 意味論の写し(R-5、実測で固定):
- `\s`(および SECRET_BASH の文字クラス内 `\s`)は CPython sre の str 用空白
  集合そのもの = `Core.Text.isPySpace`(U+0009–000D・001C–001F・0020・0085・
  00A0・1680・2000–200A・2028・2029・202F・205F・3000)。
- `\w` / `\b` は ASCII 近似(word = `[A-Za-z0-9_]`、非 ASCII は非 word =
  `isAsciiWord`)。この近似はこれらの deny パターン群では**マッチ増加(deny
  拡大)方向にしか働かない**ことが裁定済み(R-6 自動採用、META.md §31.2-29-e)。
- `$`(MULTILINE なし)は「文字列末尾、または末尾が改行 1 個ならその直前」。
  `^` は文字列先頭のみ。
- `(curl|wget)[^|]*\|\s*(ba)?sh\b` は curl/wget の各出現(語境界なし)につき
  「直後の最初の `|`」だけを検査する(複数出現を全部試す)。

**病的入力の裁定(META.md §31.2-29-b、実装は無意見側)**: tool_input が object
でない / file_path・notebook_path・command が非文字列 / パスに NUL — Python は
未捕捉例外で exit 1(無決定)だが、Lean は当該値を欠損扱い(ないし解決失敗
スキップ)にして通常の決定木を継続し、決定が出なければ無意見(exit 0)。方向は
どちらも「判定を発しない」で安全同値。

理由文字列は Python ソースの文言と完全一致で転記する(LOOP_DIR 名・target・
パターン文字列の埋め込み込み。§5.3: Claude Code が利用者へそのまま表示し、
シャドー検証が stdout ごとバイト比較する)。
-/

namespace Looper.Asl.Hooks

open Looper.Core.Json (Value)
open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (isPySpace)
open Looper.Core.Frag

/-- `(^|/)lit` 形の `re.search`: 先頭または `/` 直後に lit(その後の tail)。 -/
private def searchSlashPrefixed (p : Frag) (s : String) : Bool :=
  (p s.toList).isSome || search (cls (· == '/') >=> p) s

/-- 末尾 `$`(MULTILINE なし): 文字列末尾、または末尾が改行 1 個ならその直前
(`re.search(... "$")` の写し)。消費ゼロ。 -/
private def dollarEnd : Frag
  | [] => some []
  | ['\n'] => some ['\n']
  | _ => none

/-! ## LOOP_DIR 名の埋め込み(`re.escape(LOOP_DIR)` はリテラルに写す)

LOOP_DIR 名(例 ".loop")は Python では `re.escape` されてパターンに入る。
インストール時に選ばれる名前は `.` 始まりの通常ディレクトリ名で、`re.escape`
後もリテラル一致になる(方言上の正規表現メタは含まない前提)。本モジュールは
名前をリテラル断片として扱い、`.` 等のメタ文字解釈をしない(Python の
`re.escape` と同方向)。 -/

/-! ## Write 系ツールの deny/ask パターン(pre_tool_guard.py) -/

/-- `DENY_PATTERNS`(組み込み 4 本、Write 系パス候補用)× `re.search`。
`(^|/)<LOOP_DIR>/state/` / `(^|/)\.env($|\.)` / `(^|/)secrets/` /
`(^|/)config/credentials\.json$`。 -/
def matchesBuiltinDeny (loopDir : String) (cand : String) : Bool :=
  searchSlashPrefixed (lit (loopDir ++ "/state/")) cand
    || searchSlashPrefixed
        (lit ".env" >=> alts [dollarEnd, lit "."]) cand
    || searchSlashPrefixed (lit "secrets/") cand
    || searchSlashPrefixed (lit "config/credentials.json" >=> dollarEnd) cand

/-- `ASK_PATTERNS`(組み込み 8 本、instance の enforcement 面)× `re.search`。
`(^|/)<LOOP_DIR>/scripts/` / `(^|/)<LOOP_DIR>/lean/` / `(^|/)<LOOP_DIR>/bin/` /
`(^|/)<LOOP_DIR>/schema\.json$` / `(^|/)<LOOP_DIR>/prompts/` / `(^|/)\.claude/` /
`(^|/)CLAUDE\.md$` / `(^|/)settings\.json$`。

`lean/` と `bin/` は**判定を実行しているエンジンそのもの**(同梱 Lean ソースと
ビルド済みバイナリ)である。instance の settings は既に sandbox `denyWrite` で
両方を、permissions deny で `bin/**` を覆っている(matrix C-008)が、hook だけが
無意見だと「ハーネスの実行体を、ハーネス自身は何も言わずに書き換えられる」層が
残る。`scripts/` と同じ ask(= 人間承認付きでのみ変更可)に揃える。 -/
def matchesAsk (loopDir : String) (cand : String) : Bool :=
  searchSlashPrefixed (lit (loopDir ++ "/scripts/")) cand
    || searchSlashPrefixed (lit (loopDir ++ "/lean/")) cand
    || searchSlashPrefixed (lit (loopDir ++ "/bin/")) cand
    || searchSlashPrefixed (lit (loopDir ++ "/schema.json") >=> dollarEnd) cand
    || searchSlashPrefixed (lit (loopDir ++ "/prompts/")) cand
    || searchSlashPrefixed (lit ".claude/") cand
    || searchSlashPrefixed (lit "CLAUDE.md" >=> dollarEnd) cand
    || searchSlashPrefixed (lit "settings.json" >=> dollarEnd) cand

/-! ## Bash ツールの deny パターン(pre_tool_guard.py) -/

/-- `DENIED_BASH` = `\bgit\s+add\b` / `\bgit\s+commit\b`。 -/
def isDeniedBash (command : String) : Bool :=
  searchAtBoundary (lit "git" >=> ws1 >=> lit "add" >=> wordEnd) command
    || searchAtBoundary (lit "git" >=> ws1 >=> lit "commit" >=> wordEnd) command

/-- `SECRET_BASH` × `re.search`。接頭辞クラスは `[\s\"'=/]`(その中の `\s` も
`isPySpace`)。`(^|[\s\"'=/])\.env\b` / `...secrets/` /
`...config/credentials\.json\b`。 -/
private def secretCls (c : Char) : Bool :=
  isPySpace c || c == '"' || c == '\'' || c == '=' || c == '/'

def isSecretBash (command : String) : Bool :=
  searchPrefixed secretCls (lit ".env" >=> wordEnd) command
    || searchPrefixed secretCls (lit "secrets/") command
    || searchPrefixed secretCls (lit "config/credentials.json" >=> wordEnd) command

/-! ### `protected_write_target`(main() ローカル、mutator との連言は決定木側) -/

/-- `<LOOP_DIR>/state/|\.env($|\.|\s)|secrets/|config/credentials\.json`
× `re.search`(接頭辞クラスなしの生部分一致)。`\.env($|\.|\s)` は
「`.env` の後が 末尾 / `.` / 空白」。`$` の末尾改行特例は `\s`(= `\n`)が
吸収するため、真の末尾のみで写す。 -/
def isProtectedWriteTarget (loopDir : String) (command : String) : Bool :=
  Looper.Core.Text.containsSub command (loopDir ++ "/state/")
    || search
        (lit ".env"
          >=> alts [fun cs => if cs.isEmpty then some [] else none,
                    cls fun c => c == '.' || isPySpace c])
        command
    || Looper.Core.Text.containsSub command "secrets/"
    || Looper.Core.Text.containsSub command "config/credentials.json"

/-- `WRITE_REDIRECT_OR_MUTATOR = (?:[0-9]?>>?|&>>?|\b(?:sed\s+-i|tee|mv|cp|rm)\b)`。 -/
private def gt1or2 : Frag
  | '>' :: '>' :: rest => some rest
  | '>' :: rest => some rest
  | _ => none

private def wordMutator : Frag :=
  alts [lit "sed" >=> ws1 >=> lit "-i", lit "tee", lit "mv", lit "cp", lit "rm"]
    >=> wordEnd

private def mutatorAt (prev : Option Char) : Frag := fun cs =>
  (match cs with
    | '&' :: rest => gt1or2 rest
    | c :: rest => if c.isDigit then gt1or2 rest else gt1or2 cs
    | [] => none)
  <|> (if boundaryBefore prev then wordMutator cs else none)

/-- `re.search(WRITE_REDIRECT_OR_MUTATOR, command)` 等価。 -/
def hasWriteRedirectOrMutator (command : String) : Bool :=
  (positions command).any fun (prev, sfx) => (mutatorAt prev sfx).isSome

/-! ### DANGEROUS_BASH — 一致した正規表現リテラルを理由文言へ埋め込む -/

/-- `[^|]*\|\s*(ba)?sh\b` の断片(curl/wget の直後から): 直後の最初の `|` まで
進み(`[^|]` は `|` を跨げない)、`\s*` を剥いで `bash\b` / `sh\b` を試す。 -/
private def pipeShTail : Frag := fun cs =>
  match cs.dropWhile (· != '|') with
  | '|' :: rest =>
    alts [lit "bash" >=> wordEnd, lit "sh" >=> wordEnd] (rest.dropWhile isPySpace)
  | _ => none

/-- `DANGEROUS_BASH` のパターン順走査で最初に一致したパターンの**元正規表現
リテラル文字列**(理由文言 `f"Forbidden Bash pattern (safety rule): {pat}"` が
これを埋め込むため、データとして保持する)。curl/wget に `\b` はない
(`mycurl x | sh` も一致 — Python の実挙動)。 -/
def dangerousBashReason? (command : String) : Option String :=
  if searchAtBoundary (lit "rm" >=> ws1 >=> lit "-rf" >=> wordEnd) command then
    some "\\brm\\s+-rf\\b"
  else if searchAtBoundary (lit "sudo" >=> wordEnd) command then
    some "\\bsudo\\b"
  else if searchAtBoundary (lit "git" >=> ws1 >=> lit "push" >=> wordEnd) command then
    some "\\bgit\\s+push\\b"
  else if searchAtBoundary
      (lit "git" >=> ws1 >=> lit "reset" >=> ws1 >=> lit "--hard" >=> wordEnd) command then
    some "\\bgit\\s+reset\\s+--hard\\b"
  else if searchAtBoundary
      (lit "git" >=> ws1 >=> lit "clean" >=> ws1 >=> lit "-fd" >=> wordEnd) command then
    some "\\bgit\\s+clean\\s+-fd\\b"
  else if search (alts [lit "curl", lit "wget"] >=> pipeShTail) command then
    some "(curl|wget)[^|]*\\|\\s*(ba)?sh\\b"
  else
    none

/-! ### HUMAN_ONLY_BASH / LOOP_ONLY_BASH の regex(`state.py` サブコマンド積は
`statePySubcommands` が別途担う) -/

/-- `_JUST_PREFIX = \bjust\s+(?:--?[\w-]+(?:=\S*)?\s+)*`。`[\w-]` の `\w` は
`isAsciiWord`(R-6 方言、非 ASCII は非 word)。 -/
private def isFlagChar (c : Char) : Bool := isAsciiWord c || c == '-'

/-- フラグ 1 反復 `--?[\w-]+(?:=\S*)?\s+`。言語として `-[\w-]+...` と同値
(2 本目の `-` は `[\w-]+` が吸収する — live 版 `Core.Classify.Bash` と同じ写し。
`just -- resume` は `-` を name として一致する)。`=\S*` の貪欲消費は直後の
`\s+` と排反で唯一の分割。 -/
private def flagOnce : Frag
  | '-' :: rest =>
    let (name, rest) := rest.span isFlagChar
    if name.isEmpty then none
    else
      ws1 (match rest with
        | '=' :: r => r.dropWhile (fun c => !isPySpace c)
        | _ => rest)
  | _ => none

/-- star 反復 + tail。tail の全代替は英字開始(`resume` / `loop` / `once` /
`state`)・フラグは `-` 開始で排反のため、各位置で tail を先に試す決定的評価が
CPython のバックトラックと受理一致する(モジュール頭注)。フラグ 1 反復は
2 文字以上消費するので fuel = 入力長で十分。 -/
private def flagsStar (tail : Frag) : Nat → Frag
  | 0 => tail
  | fuel + 1 => fun cs => tail cs <|> (flagOnce cs).bind (flagsStar tail fuel)

/-- `re.search(_JUST_PREFIX ++ tail, s)`。 -/
private def searchJustPrefix (tail : Frag) (s : String) : Bool :=
  searchAtBoundary
    (fun cs => ((lit "just" >=> ws1) cs).bind fun rest =>
      flagsStar tail (rest.length + 1) rest)
    s

/-- `HUMAN_ONLY_BASH`(regex 部) × `re.search`:
`state\.py\s+resume\b` / `(^|/)resume\.sh\b` / `(^|/)loop\.sh\b` /
`(^|/)once\.sh\b` / `{_JUST_PREFIX}(?:resume|loop|once)\b` /
`{_JUST_PREFIX}state\s+resume\b`。`state\.py` はリテラル(境界なし、
`mystate.py` も一致 — Python の `\.` はドットのみエスケープ)。
配線切替(§31.2)後の新綴り `asl-loop\s+state\s+resume\b` も同列に deny する
(旧綴りの遮断は継続 = deny 拡大方向、R-6)。 -/
def isHumanOnlyBash (command : String) : Bool :=
  search (lit "state.py" >=> ws1 >=> lit "resume" >=> wordEnd) command
    || search (lit "asl-loop" >=> ws1 >=> lit "state" >=> ws1 >=>
               lit "resume" >=> wordEnd) command
    || searchSlashPrefixed (lit "resume.sh" >=> wordEnd) command
    || searchSlashPrefixed (lit "loop.sh" >=> wordEnd) command
    || searchSlashPrefixed (lit "once.sh" >=> wordEnd) command
    || searchJustPrefix (alts [lit "resume" >=> wordEnd, lit "loop" >=> wordEnd,
                               lit "once" >=> wordEnd]) command
    || searchJustPrefix (lit "state" >=> ws1 >=> lit "resume" >=> wordEnd) command

/-- `LOOP_ONLY_BASH`(regex 部) × `re.search`:
`{_JUST_PREFIX}state\s+(?:start-run|end-run|record-progress)\b`。新綴り
`asl-loop\s+state\s+(?:start-run|end-run|record-progress)\b` も同列に deny。 -/
def isLoopOnlyBash (command : String) : Bool :=
  searchJustPrefix
    (lit "state" >=> ws1 >=>
      alts [lit "start-run" >=> wordEnd, lit "end-run" >=> wordEnd,
            lit "record-progress" >=> wordEnd])
    command
    || search
      (lit "asl-loop" >=> ws1 >=> lit "state" >=> ws1 >=>
        alts [lit "start-run" >=> wordEnd, lit "end-run" >=> wordEnd,
              lit "record-progress" >=> wordEnd])
      command

/-! ## state エンジンのサブコマンド抽出(`state_py_subcommands` の拡張面 —
旧 `state.py` 綴りに加え、配線切替後の `asl-loop state` 綴りも認識する) -/

/-- `_STATE_VALUE_FLAGS`: 次の 1 トークンを値としてスキップする既知フラグ。 -/
def stateValueFlags : List String :=
  ["--run-id", "--status", "--note", "--reason", "--detail", "--changed",
   "--run-status", "--doc", "--content-file", "--log", "--entry"]

/-- basename(最後の `/` より後)。`tok.rsplit("/", 1)[-1]`。 -/
private def basename (tok : String) : String :=
  match (tok.toList.reverse.takeWhile (· != '/')).reverse with
  | cs => String.ofList cs

/-- 1 セグメントのトークン列から、state エンジン呼び出し後の最初の positional
サブコマンドを 1 個返す(main() の内側ループ)。エンジン呼び出しは 2 綴り —
旧 `state.py`(basename 一致)と、配線切替後の `asl-loop state`(basename
`asl-loop` の直後トークンが `state`。§31.2)。既知値付きフラグは次トークンを
スキップ、`--` 始まりは値スキップ判定のみ、`-` 始まりはスキップ、最初の
positional を採ってセグメント終了。`asl-loop` の直後が `state` でなければ
(`asl-loop version` / `asl-loop hook ...`)残りを走査し続ける。新綴りでは
Lean 版共通フラグ `--loop-root` も値付きとしてスキップする(エンジン自身の
パースと同型 — さもなくばフラグ値が偽 positional になり deny が素通りする)。
旧綴りの値付きフラグ集合は Python 凍結挙動のまま変えない。 -/
private def subOfSegment (tokens : List String) : Option String :=
  seek tokens
where
  scan (valueFlags : List String) (skipValue : Bool) : List String → Option String
    | [] => none
    | tok :: rest =>
      if skipValue then scan valueFlags false rest
      else if tok.startsWith "--" then scan valueFlags (valueFlags.contains tok) rest
      else if tok.startsWith "-" then scan valueFlags false rest
      else some tok
  seek : List String → Option String
    | [] => none
    | tok :: rest =>
      if basename tok == "state.py" then scan stateValueFlags false rest
      else if basename tok == "asl-loop" then
        match rest with
        | "state" :: afterState =>
          scan ("--loop-root" :: stateValueFlags) false afterState
        | _ => seek rest
      else seek rest

private def isSep (c : Char) : Bool := c == ';' || c == '&' || c == '|'

/-- `re.split(r"[;&|]+", command)` の走査。fuel は入力長で全域(1 歩ごとに
1 文字以上消費: セパレータ run は `dropWhile` でまとめて進む)。 -/
private def splitSegmentsAux : Nat → List Char → List Char → List String
  | _, [], acc => [String.ofList acc.reverse]
  | 0, _, acc => [String.ofList acc.reverse]
  | fuel + 1, c :: cs, acc =>
    if isSep c then
      String.ofList acc.reverse :: splitSegmentsAux fuel (cs.dropWhile isSep) []
    else splitSegmentsAux fuel cs (c :: acc)

/-- `re.split(r"[;&|]+", command)`: `;` `&` `|` の 1 個以上の連続で分割
(空セグメントも生じ得る — 先頭/末尾セパレータで前後に空文字列)。 -/
private def splitSegments (command : String) : List String :=
  splitSegmentsAux (command.length + 1) command.toList []

/-- 1 セグメントのトークン化: `shlex.split`、`LexError` は Python の
`except ValueError` = `str.split()`(空白 run 分割・前後トリム)へフォールバック
(META.md §31.2-29-c: レシピは Python 忠実再現。live guard の裁定 1 とは独立)。 -/
private def segmentTokens (segment : String) : List String :=
  match Looper.Core.ShellLex.split segment with
  | .ok toks => toks
  | .error _ => Looper.Core.Text.pySplitWs segment

/-- `state_py_subcommands(command)` 等価 + 新綴り拡張: 全セグメントの
positional サブコマンドの和集合(判定は集合の交わりなので順序・重複は観測に
無影響)。 -/
def statePySubcommands (command : String) : List String :=
  (splitSegments command).filterMap (fun seg => subOfSegment (segmentTokens seg))

/-- `subs & HUMAN_ONLY_STATE_SUBCOMMANDS`({resume})。 -/
def hasHumanOnlySubcommand (command : String) : Bool :=
  (statePySubcommands command).contains "resume"

/-- `subs & LOOP_ONLY_STATE_SUBCOMMANDS`({start-run, end-run, record-progress})。 -/
def hasLoopOnlySubcommand (command : String) : Bool :=
  let subs := statePySubcommands command
  subs.contains "start-run" || subs.contains "end-run"
    || subs.contains "record-progress"

/-! ## protected_paths(fnmatch 意味論の忠実移植) -/

/-- fnmatch の文字クラス `[...]` の 1 文字判定。`negate` は先頭 `!`、`items` は
`translate` 済みの (単一文字, 範囲) 列。範囲 lo-hi は lo≤c≤hi(lo>hi は空 —
病的でファザー対象外)。 -/
private inductive ClassItem where
  | one (c : Char)
  | range (lo hi : Char)

/-- `fnmatch.translate`(Python 3.12)のクラススキャン: `[` の次から。`negate`
は先に剥がした `!`。`atStart` が真の位置(クラス冒頭)の `]` はリテラルとして
クラスに含め、それ以外の `]` で閉じる。閉じない場合は `none`(呼び出し側が
リテラル `[` として扱う)。fuel は入力長で全域(1 歩ごとに 1 文字以上消費)。 -/
private def scanClass (negate : Bool) : Nat → Bool → List Char → List ClassItem →
    Option (Bool × List ClassItem × List Char)
  | 0, _, _, _ => none
  | _ + 1, _, [], _ => none  -- 閉じない `[`
  | fuel + 1, atStart, ']' :: rest, acc =>
    if atStart then scanClass negate fuel false rest (ClassItem.one ']' :: acc)
    else some (negate, acc.reverse, rest)
  | fuel + 1, _, lo :: '-' :: hi :: rest, acc =>
    if hi == ']' then
      some (negate, (ClassItem.one '-' :: ClassItem.one lo :: acc).reverse, rest)
    else scanClass negate fuel false rest (ClassItem.range lo hi :: acc)
  | fuel + 1, _, c :: rest, acc =>
    scanClass negate fuel false rest (ClassItem.one c :: acc)

private def classMatches (negate : Bool) (items : List ClassItem) (c : Char) : Bool :=
  let inSet := items.any fun
    | .one x => x == c
    | .range lo hi => lo ≤ c && c ≤ hi
  if negate then !inSet else inSet

/-- `fnmatch.fnmatch(name, pat)`(POSIX = normcase 恒等 = fnmatchcase)の全文一致。
`*`(`/` も跨ぐ)/ `?`(任意 1 文字)/ `[seq]` `[!seq]`。fuel は name 長 + pat 長。 -/
private def fnmatchAux : Nat → List Char → List Char → Bool
  | 0, _, _ => false
  | _ + 1, [], [] => true
  | _ + 1, _ :: _, [] => false  -- name 残・pattern 尽き → 不一致
  | fuel + 1, name, '*' :: prest =>
    -- `*` は 0 文字以上を任意消費。残り name の各接尾辞で継続を試す。
    (fnmatchAux fuel name prest)
      || (match name with
          | [] => false
          | _ :: nrest => fnmatchAux fuel nrest ('*' :: prest))
  | _ + 1, [], _ :: _ => false
  | fuel + 1, _ :: nrest, '?' :: prest => fnmatchAux fuel nrest prest
  | fuel + 1, n :: nrest, '[' :: prest =>
    let (negate, prest0) := match prest with
      | '!' :: r => (true, r)
      | _ => (false, prest)
    match scanClass negate prest0.length true prest0 [] with
    | some (neg, items, after) =>
      classMatches neg items n && fnmatchAux fuel nrest after
    | none =>
      -- 閉じない `[` はリテラル
      n == '[' && fnmatchAux fuel nrest prest
  | fuel + 1, n :: nrest, p :: prest =>
    n == p && fnmatchAux fuel nrest prest

private def fnmatch (name pat : String) : Bool :=
  let ns := name.toList
  let ps := pat.toList
  fnmatchAux (ns.length + ps.length + 1) ns ps

/-- `pat.rstrip("*/")`: 末尾から `*` と `/` を剥がす。 -/
private def rstripStarSlash (pat : String) : String :=
  String.ofList (pat.toList.reverse.dropWhile (fun c => c == '*' || c == '/')).reverse

/-- `protected_match(protected, candidates)` の 1 (pat, cand): `fnmatch` ∨
等値 ∨ `cand.startswith(rstrip(pat,"*/") + "/")`。 -/
def protectedPairMatches (pat cand : String) : Bool :=
  fnmatch cand pat
    || cand == pat
    || cand.startsWith (rstripStarSlash pat ++ "/")

/-- `protected_match`: いずれかの (pat, cand) が一致。 -/
def protectedMatch (protectedPats : List String) (cands : List String) : Bool :=
  protectedPats.any fun pat => cands.any fun cand => protectedPairMatches pat cand

/-! ## path_candidates(候補集合の組み立て — IO 部は Cli 側)

Python `path_candidates(raw, cwd)` の純粋部。IO シェルは raw の絶対/相対を
解決した結果 `resolved?`(解決失敗 = OSError は `none`)を注入する。
- cand1 = `str(Path(raw)).replace("\\", "/")` = `Core.PathAlg.candidate`
- cand2 = `str(resolved).replace("\\", "/")`(resolved が `some` のとき)
- cand3 = resolved が TARGET_ROOT 配下(`is_relative_to`、字句比較)なら
  `relative_to(...).as_posix()`。**cand3 にはバックスラッシュ置換をしない**
  (Python コードの忠実な写し)。
raw が空なら空集合。 -/
def pathCandidates (raw : String) (resolved? : Option String) (targetRoot : String) :
    List String :=
  if raw.isEmpty then []
  else
    let backToSlash (s : String) : String :=
      s.map fun c => if c == '\\' then '/' else c
    let cand1 := Looper.Core.PathAlg.candidate raw
    match resolved? with
    | none => [cand1]
    | some r =>
      let cand2 := backToSlash r
      let cand3? :=
        if Looper.Core.PathAlg.isRelativeToStr r targetRoot then
          Looper.Core.PathAlg.relativeToStr? r targetRoot
        else none
      [cand1, cand2] ++ cand3?.toList

/-! ## schema.json 動的ルール(抽出の純粋部) -/

/-- `str_list(key)`: 値が list ならその文字列要素のみ、それ以外は空。 -/
private def strList (schema : Value) (key : String) : List String :=
  match schema.get? key with
  | some (.arr items) => items.filterMap Value.asStr?
  | _ => []

/-- `load_dynamic_rules` の分類部: パース済み JSON(object でなければ、または
読取/パース失敗なら `.null` を渡せば全空)から
`(protected_paths, deny_patterns, deny_bash_patterns)` を抽出。 -/
def dynamicRules (schema : Value) : List String × List String × List String :=
  match schema with
  | .obj _ => (strList schema "protected_paths", strList schema "deny_patterns",
               strList schema "deny_bash_patterns")
  | _ => ([], [], [])

/-! ## 決定木(pre_tool_guard.py main() の評価順を厳密に保つ) -/

/-- `permissionDecision` の 3 値。 -/
inductive Permission where
  | deny
  | ask
deriving BEq, Repr

def Permission.tag : Permission → String
  | .deny => "deny"
  | .ask => "ask"

/-- `decision(permission, reason)` が stdout へ出す判定。 -/
structure Decision where
  permission : Permission
  reason : String
deriving BEq, Repr

/-- `decision()` の stdout 1 行(Python `json.dumps` 既定 = `ensure_ascii=True`・
セパレータ `", "` / `": "`)。live 版 `Guard.Types.Decision.render` と同形。 -/
def Decision.render (d : Decision) : String :=
  (Value.obj
    [("hookSpecificOutput", .obj
      [("hookEventName", .str "PreToolUse"),
       ("permissionDecision", .str d.permission.tag),
       ("permissionDecisionReason", .str d.reason)])]).renderAscii

/-! ### 理由文言(Python ソースの f-string / 隣接連結の評価結果とバイト一致) -/

/-- DENY_PATTERNS + deny_patterns 一致(Write 系)。エンジン綴りは配線切替後の
`bin/asl-loop state`(人間向け文言のみの差、§5.3 裁定)。 -/
def writeDenyReason (loopDir target : String) : String :=
  s!"Harness invariant: '{target}' is canonical state, a secret, or a denied path. State mutations go through {loopDir}/bin/asl-loop state."

/-- protected_paths 一致(Write 系)。 -/
def protectedDenyReason (target : String) : String :=
  s!"'{target}' is a protected path (schema.json protected_paths): only a human may change it; its edits enter history through a human resume checkpoint."

/-- ASK_PATTERNS 一致(Write 系)。 -/
def askReason (target : String) : String :=
  s!"Harness self-modification: '{target}' decides what this loop enforces. It requires explicit human approval, never a side effect of cycle work."

/-- Bash: protected_write_target × mutator。 -/
def protectedWriteDenyReason (loopDir : String) : String :=
  s!"Bash command appears to modify canonical state or a secret path directly; use {loopDir}/bin/asl-loop state."

/-- Bash: SECRET_BASH。 -/
def secretDenyReason : String :=
  "Bash command references a secret path (.env / secrets / credentials)."

/-- Bash: DENIED_BASH(git add/commit)。 -/
def commitDenyReason : String :=
  "Cycle commits are owned by loop.sh; agents may inspect git status/diff but must not stage or commit directly."

/-- Bash: HUMAN_ONLY_BASH / resume サブコマンド。 -/
def humanOnlyDenyReason : String :=
  "Human-only transition: resume / loop / once are operated by the human. Agents never release their own gates or spawn their own loop; raise a gate and end the turn instead."

/-- Bash: LOOP_ONLY_BASH / loop-only サブコマンド。 -/
def loopOnlyDenyReason : String :=
  "Loop-owned transition: start-run / end-run / record-progress are invoked by loop.sh at the cycle boundary; a mid-cycle invocation corrupts run records and the progress streaks."

/-- Bash: DANGEROUS_BASH(pat は一致した Python 正規表現リテラル)。 -/
def dangerousDenyReason (pat : String) : String :=
  s!"Forbidden Bash pattern (safety rule): {pat}"

/-- Bash: deny_bash_patterns 一致(§29.6 制限グロブ、pat は一致パターン)。 -/
def denyBashPatternReason (pat : String) : String :=
  s!"Denied by this instance's schema.json deny_bash_patterns: {pat}"

/-! ### Write 系ツールの決定(pre_tool_guard.py の WRITE_TOOLS 分岐) -/

/-- `tool in WRITE_TOOLS`。 -/
def isWriteTool (tool : Value) : Bool :=
  tool == .str "Edit" || tool == .str "Write" || tool == .str "NotebookEdit"

/-- WRITE_TOOLS 分岐の決定(候補・動的ルールは注入)。target は Python の
`file_path or notebook_path or ""`(理由文言へ埋め込む生ターゲット)。評価順:
DENY_PATTERNS + deny_patterns → protected_paths → ASK_PATTERNS。 -/
def decideWrite (loopDir target : String) (cands : List String)
    (protectedPats denyPats : List String) : Option Decision :=
  -- 1. DENY_PATTERNS(組み込み)+ deny_patterns(§29.6 制限グロブ)
  if cands.any (fun c => matchesBuiltinDeny loopDir c)
      || denyPats.any (fun p => cands.any (Looper.Core.Glob.accepts p)) then
    some ⟨.deny, writeDenyReason loopDir target⟩
  -- 2. protected_paths(fnmatch)
  else if protectedMatch protectedPats cands then
    some ⟨.deny, protectedDenyReason target⟩
  -- 3. ASK_PATTERNS
  else if cands.any (fun c => matchesAsk loopDir c) then
    some ⟨.ask, askReason target⟩
  else none

/-! ### Bash ツールの決定(pre_tool_guard.py の Bash 分岐) -/

/-- Bash 分岐の決定。評価順(安全性の核):
1. protected_write_target ∧ WRITE_REDIRECT_OR_MUTATOR
2. SECRET_BASH
3. DENIED_BASH
4. HUMAN_ONLY_BASH ∨ (subs ∩ {resume})
5. (subs ∩ {start-run,end-run,record-progress}) ∨ LOOP_ONLY_BASH
6. DANGEROUS_BASH(一致パターンを理由に埋め込む)
7. deny_bash_patterns(§29.6 制限グロブ、一致パターンを理由に埋め込む) -/
def decideBash (loopDir command : String) (denyBashPats : List String) :
    Option Decision :=
  if isProtectedWriteTarget loopDir command && hasWriteRedirectOrMutator command then
    some ⟨.deny, protectedWriteDenyReason loopDir⟩
  else if isSecretBash command then
    some ⟨.deny, secretDenyReason⟩
  else if isDeniedBash command then
    some ⟨.deny, commitDenyReason⟩
  else if isHumanOnlyBash command || hasHumanOnlySubcommand command then
    some ⟨.deny, humanOnlyDenyReason⟩
  else if hasLoopOnlySubcommand command || isLoopOnlyBash command then
    some ⟨.deny, loopOnlyDenyReason⟩
  else
    match dangerousBashReason? command with
    | some pat => some ⟨.deny, dangerousDenyReason pat⟩
    | none =>
      match denyBashPats.find? (fun p => Looper.Core.Glob.accepts p command) with
      | some pat => some ⟨.deny, denyBashPatternReason pat⟩
      | none => none

/-! ## session-start(session_start_guard.py) -/

/-- CWD と TARGET_ROOT の不一致時の stderr 文言(Python と同文)。cwd・
targetRoot は解決済み `str(Path)` 表記(IO 側で resolveNonStrict 済み)。 -/
def sessionCwdMismatchMessage (targetRoot cwd : String) : String :=
  s!"[agentic-state-loop] Claude Code must be launched from the product root ({targetRoot}), but the session CWD is {cwd}. Start again with: cd {targetRoot} && claude"

/-- 一致時の hookSpecificOutput JSON の additionalContext(Python と同文、
LOOP_DIR 名込み)。 -/
def sessionAdditionalContext (loopDir : String) : String :=
  s!"Harnessed loop session confirmed at the product root. Canonical state is {loopDir}/state/ — mutate it only through {loopDir}/bin/asl-loop state. Never git add/commit (loop.sh owns the cycle checkpoint); raise a gate and end the turn when a human decision is needed."

/-- 一致時の stdout 1 行(`json.dumps` 既定 = `renderAscii`)。 -/
def sessionConfirmedLine (loopDir : String) : String :=
  (Value.obj
    [("hookSpecificOutput", .obj
      [("hookEventName", .str "SessionStart"),
       ("additionalContext", .str (sessionAdditionalContext loopDir))])]).renderAscii

/-! ## post-tool(post_tool_audit.py) -/

/-- `(tool_input.get("command") or "")[:500] or None` の command フィールド。
文字列は先頭 500 コードポイント(空なら null)。command キー欠損・null・falsy は
null。**非文字列の truthy** は Python の `[:500]` スライス失敗 = IO 側で監査を
スキップし exit 0 とする裁定(§31.2-29-b)のため、ここでは扱わない(IO 側で
`bashCommand?` 相当の判定を先に行う)。 -/
private def auditCommandField (command? : Option String) : Value :=
  match command? with
  | some s => if s.isEmpty then .null else .str (s.take 500).toString
  | none => .null

/-- 監査レコード(post_tool_audit.py の `json.dumps(..., ensure_ascii=False)`)。
キーは Python の挿入順。`sessionId` は `payload.get("session_id")`(欠損は null)。
`tool` は `payload.get("tool_name", "")`(非文字列もそのまま JSON 値へ)。
`file` は `tool_input.get("file_path") or tool_input.get("notebook_path")`
(falsy 連鎖、両方 falsy なら null)。`command` は上記フィールド。 -/
def auditRecord (now : String) (sessionId tool file : Value) (command? : Option String) :
    Value :=
  .obj
    [("at", .str now),
     ("session_id", sessionId),
     ("tool", tool),
     ("file", file),
     ("command", auditCommandField command?)]

/-- Python `a or b` の意味論(file フィールドの or 連鎖用)。`a` が truthy な
ら `a`、そうでなければ `a` の truthy 判定は行わず無条件に `b` をそのまま
返す(`b` 自身が falsy でも `b` を返す — Python は「2 番目の被演算子を
条件判定しない」ため、`None or ""` は `""` になる。呼び出し側が `b` に
`.null` を渡した場合のみ結果が `.null` になる)。 -/
def orValue3 (a b : Value) : Value :=
  if a.truthy then a else b

/-! ## コンパイル時検査(期待値は pre/post/session hooks の CPython 3.14 実測) -/

-- matchesBuiltinDeny(組み込み DENY_PATTERNS、LOOP_DIR = ".loop")
#guard matchesBuiltinDeny ".loop" ".loop/state/x.json" == true
#guard matchesBuiltinDeny ".loop" "sub/.loop/state/x" == true
#guard matchesBuiltinDeny ".loop" "x.loop/state/y" == false  -- (^|/) アンカー
#guard matchesBuiltinDeny ".loop" ".loop/state" == false     -- 末尾スラッシュ必須
#guard matchesBuiltinDeny ".loop" ".env" == true
#guard matchesBuiltinDeny ".loop" "proj/.env" == true
#guard matchesBuiltinDeny ".loop" ".env.local" == true
#guard matchesBuiltinDeny ".loop" ".environ" == false        -- ($|\.) 直後は末尾か .
#guard matchesBuiltinDeny ".loop" "x.env" == false           -- (^|/) アンカー
#guard matchesBuiltinDeny ".loop" "secrets/k" == true
#guard matchesBuiltinDeny ".loop" "a/secrets/k" == true
#guard matchesBuiltinDeny ".loop" "config/credentials.json" == true
#guard matchesBuiltinDeny ".loop" "config/credentials.json\n" == true  -- $ の末尾改行特例
#guard matchesBuiltinDeny ".loop" "config/credentials.jsonx" == false

-- matchesAsk(ASK_PATTERNS)
#guard matchesAsk ".loop" ".loop/scripts/x.py" == true
#guard matchesAsk ".loop" ".loop/lean/Looper/Asl/Engine.lean" == true
#guard matchesAsk ".loop" ".loop/bin/asl-loop" == true
#guard matchesAsk ".loop" ".loop/leanx/a" == false
#guard matchesAsk ".loop" "src/lean/a" == false
#guard matchesAsk ".loop" ".loop/schema.json" == true
#guard matchesAsk ".loop" ".loop/schema.jsonx" == false      -- $ アンカー
#guard matchesAsk ".loop" ".loop/prompts/cycle.md" == true
#guard matchesAsk ".loop" ".claude/settings.json" == true
#guard matchesAsk ".loop" "CLAUDE.md" == true
#guard matchesAsk ".loop" "x/CLAUDE.md" == true
#guard matchesAsk ".loop" "settings.json" == true
#guard matchesAsk ".loop" "src/main.py" == false

-- isDeniedBash
#guard isDeniedBash "git add ." == true
#guard isDeniedBash "git commit -m x" == true
#guard isDeniedBash "git  add" == true
#guard isDeniedBash "gitadd" == false
#guard isDeniedBash "git addx" == false
#guard isDeniedBash "git push" == false
#guard isDeniedBash "git\tadd" == true

-- isSecretBash
#guard isSecretBash "cat .env" == true
#guard isSecretBash "cat .envx" == false
#guard isSecretBash "cat .env.local" == true
#guard isSecretBash "x.env" == false
#guard isSecretBash "a/.env" == true
#guard isSecretBash "cat 'secrets/k'" == true
#guard isSecretBash "cat config/credentials.json" == true
#guard isSecretBash ".env" == true

-- isProtectedWriteTarget(LOOP_DIR = ".loop"、mutator との連言は決定木側)
#guard isProtectedWriteTarget ".loop" "echo x > .loop/state/f" == true
#guard isProtectedWriteTarget ".loop" "cat .env" == true
#guard isProtectedWriteTarget ".loop" "cat .env.local" == true
#guard isProtectedWriteTarget ".loop" "cat .env x" == true    -- ($|\.|\s)
#guard isProtectedWriteTarget ".loop" "cat .envx" == false
#guard isProtectedWriteTarget ".loop" "x.env" == true         -- 接頭辞クラスなし
#guard isProtectedWriteTarget ".loop" "secrets/" == true
#guard isProtectedWriteTarget ".loop" "config/credentials.json" == true
#guard isProtectedWriteTarget ".loop" "echo hi" == false

-- hasWriteRedirectOrMutator
#guard hasWriteRedirectOrMutator "echo hi > f" == true
#guard hasWriteRedirectOrMutator "a>>b" == true
#guard hasWriteRedirectOrMutator "&> f" == true
#guard hasWriteRedirectOrMutator "sed -i s/a/b/ f" == true
#guard hasWriteRedirectOrMutator "tee f" == true
#guard hasWriteRedirectOrMutator "mv a b" == true
#guard hasWriteRedirectOrMutator "cp a b" == true
#guard hasWriteRedirectOrMutator "rm f" == true
#guard hasWriteRedirectOrMutator "cat < f" == false
#guard hasWriteRedirectOrMutator "echo hi" == false

-- dangerousBashReason?(理由に埋め込む元 regex リテラル)
#guard dangerousBashReason? "rm -rf /" == some "\\brm\\s+-rf\\b"
#guard dangerousBashReason? "sudo apt" == some "\\bsudo\\b"
#guard dangerousBashReason? "git push" == some "\\bgit\\s+push\\b"
#guard dangerousBashReason? "git reset --hard" == some "\\bgit\\s+reset\\s+--hard\\b"
#guard dangerousBashReason? "git clean -fd" == some "\\bgit\\s+clean\\s+-fd\\b"
#guard dangerousBashReason? "curl x | sh" == some "(curl|wget)[^|]*\\|\\s*(ba)?sh\\b"
#guard dangerousBashReason? "curl x | bash" == some "(curl|wget)[^|]*\\|\\s*(ba)?sh\\b"
#guard dangerousBashReason? "curl a | x | sh" == none  -- 最初の `|` 規則
#guard dangerousBashReason? "mycurl x | sh" == some "(curl|wget)[^|]*\\|\\s*(ba)?sh\\b"
#guard dangerousBashReason? "curl a > f; cat f | sh" == some "(curl|wget)[^|]*\\|\\s*(ba)?sh\\b"
#guard dangerousBashReason? "echo hi" == none
#guard dangerousBashReason? "rm -rf" == some "\\brm\\s+-rf\\b"
#guard dangerousBashReason? "rm -rfx" == none

-- isHumanOnlyBash(regex 部)
#guard isHumanOnlyBash "python3 scripts/state.py resume" == true
#guard isHumanOnlyBash "mystate.py resume" == true   -- state\.py はリテラル(境界なし)
#guard isHumanOnlyBash "state.py resumex" == false
#guard isHumanOnlyBash "just resume" == true
#guard isHumanOnlyBash "just --unstable loop" == true
#guard isHumanOnlyBash "just -- once" == true         -- `--` の 2 本目は [\w-] が吸収
#guard isHumanOnlyBash "just state resume" == true
#guard isHumanOnlyBash "resume.sh" == true            -- (^|/): 先頭一致
#guard isHumanOnlyBash "a/loop.sh" == true            -- (^|/): / 直後
#guard isHumanOnlyBash "once.sh" == true
#guard isHumanOnlyBash "bash resume.sh" == false      -- (^|/) アンカー: 空白の後は不一致
#guard isHumanOnlyBash "xresume.sh" == false          -- (^|/) アンカー
#guard isHumanOnlyBash "just resumex" == false
#guard isHumanOnlyBash "just start-run" == false      -- resume/loop/once のみ

-- isLoopOnlyBash(regex 部)
#guard isLoopOnlyBash "just state start-run" == true
#guard isLoopOnlyBash "just --unstable state end-run" == true
#guard isLoopOnlyBash "just state record-progress" == true
#guard isLoopOnlyBash "just state resume" == false
#guard isLoopOnlyBash "state.py start-run" == false   -- _JUST_PREFIX 必須(subs 側で拾う)

-- statePySubcommands / hasHumanOnlySubcommand / hasLoopOnlySubcommand
#guard statePySubcommands "state.py resume" == ["resume"]
-- `--project` は _STATE_VALUE_FLAGS 外 → 値スキップせず、次の positional `X` を採る
-- (Python 忠実。live guard の `state.py --project X resume` == false と同根拠)
#guard statePySubcommands "state.py --project X resume" == ["X"]
#guard statePySubcommands "state.py --run-id R1 start-run" == ["start-run"]  -- 既知値フラグ
#guard statePySubcommands "python3 scripts/state.py end-run --status ok" == ["end-run"]
#guard statePySubcommands "state.py --note foo resume; state.py start-run"
  == ["resume", "start-run"]                          -- 和集合・順序無関係
#guard statePySubcommands "echo hi" == []
#guard statePySubcommands "state.py -x resume" == ["resume"]   -- -x はスキップ
#guard statePySubcommands "cat state.py" == []                 -- state.py の後続なし
#guard hasHumanOnlySubcommand "state.py resume" == true
#guard hasHumanOnlySubcommand "state.py --project X resume" == false  -- 採るのは X
#guard hasHumanOnlySubcommand "state.py start-run" == false
#guard hasLoopOnlySubcommand "state.py --run-id R start-run" == true
#guard hasLoopOnlySubcommand "state.py resume" == false
-- 未閉クォート → str.split() フォールバック(§31.2-29-c)
#guard statePySubcommands "state.py resume 'unclosed" == ["resume"]

-- fnmatch / protectedPairMatches
#guard fnmatch "a/b/c" "a/*/c" == true       -- `*` は `/` も跨ぐ
#guard fnmatch "abc" "a?c" == true
#guard fnmatch "a.c" "a[.]c" == true
#guard fnmatch "a3c" "a[0-9]c" == true
#guard fnmatch "axc" "a[!0-9]c" == true
#guard fnmatch "a0c" "a[!0-9]c" == false
#guard fnmatch "a]c" "a[]]c" == true          -- 先頭 ] はリテラル
#guard fnmatch "a[c" "a[c" == true            -- 閉じない `[` はリテラル
#guard fnmatch "abc" "abc" == true
#guard fnmatch "abcd" "abc" == false          -- 全文一致
#guard protectedPairMatches "src/legacy/*" "src/legacy/x.py" == true
#guard protectedPairMatches "src/legacy" "src/legacy/x.py" == true  -- startswith 前方一致
#guard protectedPairMatches "src/legacy" "src/legacy" == true       -- 等値
#guard protectedPairMatches "src/legacy/**" "src/legacy/a/b" == true
#guard protectedPairMatches "src/other" "src/legacy/x" == false
#guard protectedMatch ["a/*", "b"] ["z", "b"] == true
#guard protectedMatch ["a/*"] ["z"] == false

-- pathCandidates(cand3 のバックスラッシュ非置換に注意)
#guard pathCandidates "" none "/t" == []
#guard pathCandidates "a\\b" none "/t" == ["a/b"]
#guard pathCandidates ".loop/state/f" (some "/t/.loop/state/f") "/t"
  == [".loop/state/f", "/t/.loop/state/f", ".loop/state/f"]
#guard pathCandidates "/other/f" (some "/other/f") "/t"
  == ["/other/f", "/other/f"]   -- TARGET_ROOT 外は cand3 なし

-- dynamicRules(list の文字列要素のみ、非 object は全空)
#guard dynamicRules (.obj [("protected_paths", .arr [.str "a", .num 1 0, .str "b"])])
  == (["a", "b"], [], [])
#guard dynamicRules (.obj [("deny_patterns", .str "oops")]) == ([], [], [])
#guard dynamicRules .null == ([], [], [])
#guard dynamicRules (.obj [("deny_bash_patterns", .arr [.str "rm -rf"])])
  == ([], [], ["rm -rf"])

-- decideWrite(評価順: deny → protected → ask)
#guard (decideWrite ".loop" ".loop/state/f" [".loop/state/f"] [] []).map (·.permission)
  == some .deny
#guard (decideWrite ".loop" "x" ["src/legacy/x"] ["src/legacy/*"] []).map (·.permission)
  == some .deny
#guard (decideWrite ".loop" ".claude/x" [".claude/x"] [] []).map (·.permission)
  == some .ask
#guard (decideWrite ".loop" "src/main.py" ["src/main.py"] [] []) == none
-- deny_patterns(§29.6 制限グロブ)は DENY 側で any 候補に適用
#guard (decideWrite ".loop" "vendor/x" ["vendor/x"] [] ["^vendor/"]).map (·.permission)
  == some .deny

-- decideBash(評価順)
#guard (decideBash ".loop" "echo x > .loop/state/f" []).map (·.permission) == some .deny
#guard (decideBash ".loop" "cat .env" []).map (·.reason) == some secretDenyReason
#guard (decideBash ".loop" "git add ." []).map (·.reason) == some commitDenyReason
#guard (decideBash ".loop" "just resume" []).map (·.reason) == some humanOnlyDenyReason
#guard (decideBash ".loop" "state.py resume" []).map (·.reason) == some humanOnlyDenyReason
#guard (decideBash ".loop" "just state start-run" []).map (·.reason) == some loopOnlyDenyReason
#guard (decideBash ".loop" "state.py start-run" []).map (·.reason) == some loopOnlyDenyReason
#guard (decideBash ".loop" "rm -rf /" []).map (·.reason)
  == some "Forbidden Bash pattern (safety rule): \\brm\\s+-rf\\b"
#guard (decideBash ".loop" "echo hi" []) == none
#guard (decideBash ".loop" "rm x.txt" ["^rm "]).map (·.reason)
  == some "Denied by this instance's schema.json deny_bash_patterns: ^rm "
-- protected_write_target だけ(mutator なし)では deny しない
#guard (decideBash ".loop" "cat .loop/state/f" []) == none

-- decideWrite / decideBash の理由文言(LOOP_DIR 埋め込み。配線切替後の
-- エンジン綴り — vendored Python の旧文言とは意図的に異なる、§5.3 裁定)
#guard writeDenyReason ".loop" "f.txt"
  == "Harness invariant: 'f.txt' is canonical state, a secret, or a denied path. State mutations go through .loop/bin/asl-loop state."
#guard protectedWriteDenyReason ".loop"
  == "Bash command appears to modify canonical state or a secret path directly; use .loop/bin/asl-loop state."

-- 新綴り `asl-loop state` の human-only / loop-only 遮断(deny 拡大方向)
#guard (decideBash ".loop" ".loop/bin/asl-loop state resume --note x" []).map (·.reason)
  == some humanOnlyDenyReason
#guard (decideBash ".loop" "asl-loop state --loop-root .loop resume" []).map (·.reason)
  == some humanOnlyDenyReason
#guard (decideBash ".loop" ".loop/bin/asl-loop state start-run" []).map (·.reason)
  == some loopOnlyDenyReason
#guard (decideBash ".loop" "asl-loop state end-run --run-id r1" []).map (·.reason)
  == some loopOnlyDenyReason
#guard (decideBash ".loop" ".loop/bin/asl-loop state record-progress --changed no --run-status ok" []).map (·.reason)
  == some loopOnlyDenyReason
-- 非遮断サブコマンド・非 state 面は無意見のまま
#guard (decideBash ".loop" ".loop/bin/asl-loop state write-doc --doc plan --content-file -" []) == none
#guard (decideBash ".loop" ".loop/bin/asl-loop state raise-gate --reason r --detail d" []) == none
#guard (decideBash ".loop" ".loop/bin/asl-loop version" []) == none
#guard statePySubcommands ".loop/bin/asl-loop state --loop-root x resume" == ["resume"]
#guard statePySubcommands "asl-loop hook pre-tool" == []

-- Decision.render(json.dumps 既定 = ensure_ascii=True)
#guard (Decision.mk .deny "r").render
  == "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"r\"}}"

-- session-start 文言
#guard sessionCwdMismatchMessage "/t" "/x"
  == "[agentic-state-loop] Claude Code must be launched from the product root (/t), but the session CWD is /x. Start again with: cd /t && claude"
-- ensure_ascii=True: 本文の em dash(U+2014)は `—` へエスケープされる
#guard sessionConfirmedLine ".loop"
  == "{\"hookSpecificOutput\": {\"hookEventName\": \"SessionStart\", \"additionalContext\": \"Harnessed loop session confirmed at the product root. Canonical state is .loop/state/ \\u2014 mutate it only through .loop/bin/asl-loop state. Never git add/commit (loop.sh owns the cycle checkpoint); raise a gate and end the turn when a human decision is needed.\"}}"

-- post-tool auditRecord(json.dumps(..., ensure_ascii=False))
#guard (auditRecord "T" (.str "s1") (.str "Bash") .null (some "echo hi")).render
  == "{\"at\": \"T\", \"session_id\": \"s1\", \"tool\": \"Bash\", \"file\": null, \"command\": \"echo hi\"}"
#guard (auditRecord "T" .null (.str "Edit") (.str "f.py") none).render
  == "{\"at\": \"T\", \"session_id\": null, \"tool\": \"Edit\", \"file\": \"f.py\", \"command\": null}"
#guard (auditRecord "T" (.str "s") (.str "Bash") .null (some "")).render
  == "{\"at\": \"T\", \"session_id\": \"s\", \"tool\": \"Bash\", \"file\": null, \"command\": null}"  -- "" → null
#guard orValue3 (.str "a") (.str "b") == Value.str "a"
#guard orValue3 (.str "") (.str "b") == Value.str "b"
#guard orValue3 .null .null == Value.null
-- Python `None or ""` == "" (2 番目の被演算子は truthy 判定なしでそのまま
-- 返る。post_tool_audit.py の `file_path` 欠損・`notebook_path` が空文字列
-- のケースに対応。実測差分で凍結 — §31.2-29)。
#guard orValue3 .null (.str "") == Value.str ""
#guard orValue3 (.str "") (.str "") == Value.str ""
-- 非 ASCII は ensure_ascii=False で温存(render)
#guard (auditRecord "T" .null (.str "Edit") (.str "café.py") none).render
  == "{\"at\": \"T\", \"session_id\": null, \"tool\": \"Edit\", \"file\": \"café.py\", \"command\": null}"

end Looper.Asl.Hooks
