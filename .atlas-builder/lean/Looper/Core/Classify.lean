import Looper.Core.Text
import Looper.Core.ShellLex
import Looper.Domain

/-!
`Looper.Core.Classify` — guard の分類カタログ・第 1 部: パス分類 4 群と
コマンド構造判定 2 種。旧 Python guard との等価性は差分ファザーで検証済み
(§31.2-14)。

凍結した意味論(旧 pre_tool_guard.py 由来):

1. `DENY_PATTERNS` / `ASK_PATTERNS` / `CONTROL_PLANE_HIGH_RISK` /
   `HIGH_RISK_PATTERNS` の 4 パターン群 × `re.search`(1 候補文字列に対する
   判定)。`isDenyPath` / `isAskPath` / `isControlPlaneHighRisk` /
   `isHighRiskPath` が対応。候補列への any は呼び出し側の `List.any`。
2. `state_py_subcommands(command)` — `[;&|]+` セグメント分割 → shlex
   (失敗時 `str.split()` 退避)→ `state.py` / `just [flags] state` の直後から
   値付きフラグを跨いで positional を 1 つ取る小パーサ。resume / loop-only
   遮断(I-011、§19.1)の基盤なので重点テスト対象。`statePySubcommands` が対応
   (Python は set を返すが呼び出し側は所属判定のみ。こちらは先頭出現順の
   重複なしリスト)。
3. `command_launches_claude(command)` — クォート除去・`bash -c` ネスト再帰で
   素の `claude` 実行を検出する走査。`commandLaunchesClaude` が対応。

CPython `re` 意味論の写し(実測で固定):
- `$`(MULTILINE なし)は「文字列末尾、または末尾がちょうど 1 個の `\n` の
  ときはその直前」でも成立する(`"ESSENCE.md\n"` はマッチ、`"...\n\n"` は
  しない)。
- `(^|/)` の `^` は文字列先頭のみ。判定は「先頭 + 各 `/` 直後」の接尾辞列
  (`boundarySuffixes`)への一致で行う。

裁定済み方言差(§31 参照):
- `\w`(unicode)は ASCII `[A-Za-z0-9_]` + 「非 ASCII は `isPySpace` 以外
  すべて語構成文字」で実装する(`isWordChar`)。Python の `\w` は Unicode
  カテゴリ準拠なので、非 ASCII の記号・句読点(例 `§` `。`)では Lean 側だけ
  がマッチする。使用箇所は `ASK_PATTERNS` の `requirements[\w.-]*\.txt$` のみで、
  差分は ask 拡大方向(自動採用、R-6)。
- shlex 失敗時の `str.split()` 退避は Python 実装の実挙動として写す
  (「字句解析不能は厳しい側に倒す」は guard 決定木(`Guard/Decide`)の責務。
  本モジュールは Python と同じ値を返すことが契約)。
-/

namespace Looper.Core.Classify

open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (isPySpace pySplitWs containsSub runsOf dedup)

/-! ## re 互換プリミティブ -/

/-- `re.search(r"^name$", s)` 等価(`$` は末尾 or 末尾 1 個の `\n` の直前)。 -/
def eqToEol (name s : String) : Bool :=
  s == name || s == name ++ "\n"

private def boundarySuffixesAux : List Char → List (List Char)
  | [] => []
  | '/' :: rest => rest :: boundarySuffixesAux rest
  | _ :: rest => boundarySuffixesAux rest

/-- `(^|/)` が成立する各位置(先頭 + 各 `/` の直後)から末尾までの接尾辞列。 -/
def boundarySuffixes (s : String) : List (List Char) :=
  s.toList :: boundarySuffixesAux s.toList

/-- `re.search(r"(^|/)name$", s)` 等価。 -/
def atBoundaryEnd (name s : String) : Bool :=
  let n := name.toList
  let n' := (name ++ "\n").toList
  (boundarySuffixes s).any fun sfx => sfx == n || sfx == n'

/-- `re.search(r"(^|/)pfx", s)` 等価(pfx の後は任意)。 -/
def atBoundary (pfx s : String) : Bool :=
  let p := pfx.toList
  (boundarySuffixes s).any (p.isPrefixOf ·)

/-! ## 大小文字を区別しないファイルシステム上の照合(§28.5-9)

macOS 既定の APFS では `Scripts/x.sh` と `scripts/x.sh`、`META.MD` と
`META.md` は**同じファイル**である。一方でパス解決(`Io.Fs.resolveNonStrict`)
は CPython `pathlib.resolve()` 等価性のため symlink でない成分の綴りを保存
するので、綴り = オブジェクト同一性という分類器の前提が崩れ、綴りを変える
だけで分類を外せた。

**適用範囲は人間所有入力(`isDenyPath`)と enforcement 面
(`isControlPlaneHighRisk`)に限る。** どちらも名前の集合がフレームワーク側で
固定されており、利用者のファイルが大小文字違いで正当に衝突することがないので、
case-insensitive 化は「同じファイルを同じに分類する」以上の意味を持たない。

対照的に zone(`isHighRiskPath`)と依存マニフェスト(`isAskPath`)は**対象
プロジェクトのファイル**を分類する。case-sensitive な FS では `Hooks/` と
`hooks/` は別物であり、そこで過剰一致させると headless セッションでは ask が
自動 deny になって正当な実装作業が止まる。ゆえにこの 2 群は綴り厳密のままと
し、残る限界は §28.5-9 に明記する。 -/

private def lower (s : String) : String :=
  String.ofList (s.toList.map Char.toLower)

/-- `atBoundaryEnd` の大小文字非依存版。 -/
def atBoundaryEndCI (name s : String) : Bool :=
  atBoundaryEnd (lower name) (lower s)

/-- `atBoundary` の大小文字非依存版。 -/
def atBoundaryCI (pfx s : String) : Bool :=
  atBoundary (lower pfx) (lower s)

/-- Python `\w`(unicode)の方言実装: ASCII は `[A-Za-z0-9_]`、非 ASCII は
空白以外すべて語構成文字(ask 拡大方向の裁定。モジュール頭注)。 -/
def isWordChar (c : Char) : Bool :=
  if c.val < 0x80 then
    ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '_'
  else
    !isPySpace c

/-! ## DENY_PATTERNS(人間専用・秘匿・attestation 錨、META.md §16・§13.1-10) -/

/-- `DENY_PATTERNS` × `re.search`(1 候補)。パターン原文:
`(^|/)ESSENCE\.md$` / `(^|/)essences/` / `(^|/)\.env($|\.)` / `(^|/)secrets/` /
`(^|/)config/credentials\.json$` / `(^|/)essence_attestations\.jsonl$` /
`(^|/)\.<tool>/state/project\.json$`。`essences/` は ESSENCE.md と同格の
human-only 資産面(§2.1.5)— ESSENCE.md と同じく入れ子出現も deny する
(保守的な過剰遮断は意図。§11.3)。

apply-projection の投影台帳(`Domain.projectionFiles` — 共通 4 面
spec / todo / recommendations / blockers に、ドメインの追加面を `todo` の
直後で挿したもの、§8.2)も WRITE_TOOLS 経路で deny する(§20.2-8、
rules/state.md「in-place 編集禁止」の機械強制): これらは
`bin/<tool> state apply-projection` の事前検証を通してのみ書かれるべきで、
Edit ツールでの直接上書きは検証を迂回して不正な投影を書ける。Bash mutator
経路(`isProtectedWriteTarget` が `.<tool>/state/` を覆う)は既に deny 済み
であり、Edit 経路もこれで揃う(2026-07-27 の非対称是正)。context.json /
*.jsonl(reflection / high_risk_changes)は agent が直接書くため対象外。
バイナリ自身の書込みは WRITE_TOOLS ではないので影響しない。

製品綴りもドメイン軸なので**呼び出し側が `Domain` を渡す**(抽出計画
6b / 6e)。guard は `env.domain` を渡し、`#guard` は fixture で駆動する — この
モジュールは製品綴りを 1 つも持たない。 -/
def isDenyPath (d : Domain) (cand : String) : Bool :=
  atBoundaryEndCI "ESSENCE.md" cand
    || atBoundaryCI "essences/" cand
    || atBoundaryEndCI ".env" cand || atBoundaryCI ".env." cand
    || atBoundaryCI "secrets/" cand
    || atBoundaryEndCI "config/credentials.json" cand
    || atBoundaryEndCI "essence_attestations.jsonl" cand
    || atBoundaryEndCI s!"{d.controlDirName}/state/project.json" cand
    || d.projectionFiles.any fun name =>
         atBoundaryEndCI s!"{d.controlDirName}/state/{name}" cand

/-! ## ASK_PATTERNS(依存解決入力、META.md §11.2) -/

/-- `[\w.-]`(`requirements[\w.-]*\.txt$` の中間文字クラス)。 -/
def isReqChar (c : Char) : Bool :=
  isWordChar c || c == '.' || c == '-'

/-- `(^|/)requirements[\w.-]*\.txt$` の接尾辞 1 本分。`$` の末尾 `\n` 許容は
「`\n` は `[\w.-]` に入らない」ため接尾辞末尾の 1 個を剥いでから判定する。 -/
private def reqTxtSuffix (sfx : List Char) : Bool :=
  match dropLit? sfx "requirements".toList with
  | none => false
  | some rest =>
    let rest := match rest.reverse with
      | '\n' :: rs => rs.reverse
      | _ => rest
    rest.all isReqChar && (String.ofList rest).endsWith ".txt"

/-- `ASK_PATTERNS` × `re.search`(1 候補)。固定名は `(^|/)name$` 形
(`bun\.lockb?` / `\.yarnrc(?:\.yml)?` は選択肢を展開)、可変部は
`requirements[\w.-]*\.txt$` のみ。post-M3 追加(§31.2-45): bunfig.toml /
Pipfile / .cargo/config* / Lake 系 4 種(lakefile.lean / lakefile.toml /
lake-manifest.json / lean-toolchain — elan が toolchain 取得の入力に使う)。 -/
def isAskPath (cand : String) : Bool :=
  [ "package.json", "package-lock.json", "npm-shrinkwrap.json",
    "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "bunfig.toml",
    ".npmrc", ".yarnrc", ".yarnrc.yml", ".pnpmfile.cjs",
    "pyproject.toml", "uv.lock", "poetry.lock", "Pipfile", "Pipfile.lock",
    "pip.conf",
    "Cargo.toml", "Cargo.lock", ".cargo/config", ".cargo/config.toml",
    "go.mod", "go.sum",
    "lakefile.lean", "lakefile.toml", "lake-manifest.json", "lean-toolchain"
  ].any (atBoundaryEnd · cand)
    || (boundarySuffixes cand).any reqTxtSuffix

/-! ## CONTROL_PLANE_HIGH_RISK(不変の制御プレーン面、META.md §11.3)

CONTROL_ROOT 相対パス**のみ**に対して照合される(対象プロジェクト自身の
scripts/ 等に波及させないため)。全パターンが `^` アンカー付き。 -/

/-- `CONTROL_PLANE_HIGH_RISK` × `re.search`(CONTROL_ROOT 相対パス 1 本)。

`bin/` と `lean/` は **enforcement の実体そのもの**である(hook / guard / state
エンジンのバイナリと、その Lean ソース)。§11.3 の Always-Denied は
`CONTROL_ROOT/**` 全体であり、settings deny(§16.1 の絶対綴り
`Edit(//<control>/bin/**)` / `Edit(//<control>/lean/**)`)と OS sandbox の
`denyWrite` は既に両方を覆っている。hook 側
だけがこの 2 面に無意見だと、**settings が陳腐化している配備**(§28.5-3 が
read-only セッションの修復面として明示的に想定する状態)で、判定を実行している
当のバイナリとソースについて hook が何も言わない層になる。deny 拡大方向なので
R-6 により自動採用。 -/
def isControlPlaneHighRisk (rel : String) : Bool :=
  let rel := String.ofList (rel.toList.map Char.toLower)
  [ "claude.md", "justfile", "meta.md", "readme.md",
    ".agent/state/workspace.json", ".agent/state/project_index.json"
  ].any (eqToEol · rel)
    || [ ".claude/", "scripts/", "templates/", "recipes/", ".agent/prompts/",
         "bin/", "lean/"
       ].any (rel.startsWith ·)

/-! ## HIGH_RISK_PATTERNS(Agent Runtime High-Risk Zone、META.md §12) -/

/-- `(^|/)scripts/[^/]*(agent|claude|loop|autonomous)[^/]*$` の接尾辞 1 本分。
`[^/]` は `\n` を含むため `$` の末尾 `\n` 特例は吸収され、追加処理は不要。 -/
private def scriptsHighRiskSuffix (sfx : List Char) : Bool :=
  match dropLit? sfx "scripts/".toList with
  | none => false
  | some rest =>
    !rest.contains '/' &&
      (let s := String.ofList rest
       containsSub s "agent" || containsSub s "claude"
         || containsSub s "loop" || containsSub s "autonomous")

/-- `HIGH_RISK_PATTERNS` × `re.search`(1 候補)。 -/
def isHighRiskPath (cand : String) : Bool :=
  [ "CLAUDE.md", ".mcp.json", "AGENTS.md", "settings.json"
  ].any (atBoundaryEnd · cand)
    || [ ".claude/", ".cursor/", ".github/workflows/", "agent-runtime/",
         "agents/", "prompts/", "skills/", "hooks/"
       ].any (atBoundary · cand)
    || (boundarySuffixes cand).any scriptsHighRiskSuffix

/-! ## state_py_subcommands(pre_tool_guard.py、I-011 / §19.1 の基盤) -/

/-- `_STATE_VALUE_FLAGS`(値を 1 個取る state.py フラグ)。この集合は
`Cli.State` の実引数パーサが値を 1 個取るフラグと**厳密に一致**しなければ
ならない: ここに載らない値付きフラグがあると、`firstPositional` がその**値**
を positional(= サブコマンド)と誤読し、後続の真のサブコマンドを取り逃す。
`--todo` / `--recommendation`(supervise-check の値付きフラグ)が漏れると、
`<tool> state --todo T-1 resume` のような flag-first 綴りが resume /
loop-only 遮断(I-011・§19.1)を素通りしていた(2026-07-27)。**ドメインの
resume 裁定フラグ(`Domain.resumeAdjudication?.flag` — 同じく値を 1 個取る、
§31.1 R-13)も同じ理由でここに合流する** — 漏れると裁定を持つドメインで
`<tool> state <flag> X-1=yes resume` が同じ形の素通りになる。 -/
def stateValueFlags (d : Domain) : List String :=
  ["--project", "--run-id", "--status", "--note", "--run-status", "--resolve",
   "--retract-approval", "--file", "--todo", "--recommendation"]
    ++ (d.resumeAdjudication?.map (·.flag)).toList

/-- `re.split(r"[;&|]+", command)` の非空セグメント(空セグメントはトークンを
生まないため部分コマンド集合として同値)。 -/
def commandSegments (command : String) : List String :=
  (runsOf (fun c => c != ';' && c != '&' && c != '|') command).map String.ofList

/-- `shlex.split(segment)`、`ValueError` 時は `segment.split()` 退避
(Python 実装の実挙動。頭注の裁定参照)。 -/
def tokensLenient (segment : String) : List String :=
  match ShellLex.split segment with
  | .ok toks => toks
  | .error _ => pySplitWs segment

/-- Python `tok.rsplit("/", 1)[-1]`(最後の `/` より後。`/` がなければ全体)。 -/
def lastComponent (tok : String) : String :=
  ((tok.splitOn "/").getLast?).getD tok

/-- `env` の前置代入 `NAME=VALUE`(先頭は英字か `_`、以降は英数字か `_`)。 -/
private def isEnvAssignment (tok : String) : Bool :=
  match tok.toList.span (· != '=') with
  | (name, _ :: _) =>
    match name with
    | c :: rest =>
      (c.isAlpha || c == '_') && rest.all fun c => c.isAlphanum || c == '_'
    | [] => false
  | _ => false

/-- **実行ファイルの綴りを判定に持ち込まない正規化**(依存ゲート §11.2 と
human-only / loop-only 遮断 I-011・§19.1 の共有前処理)。argv 先頭を basename
へ落とし(`/usr/local/bin/npm` → `npm`)、`env [NAME=VALUE...]` と `command`
の前置ラッパを剥がす。`env` の flag 形(`-i` / `-u`)は剥がさない — 剥がし
損ねても従来どおり判定不成立に落ちるだけで、緩む側には倒れない。 -/
def normalizeCommandArgv : List String → List String
  | [] => []
  | tok :: rest =>
    match lastComponent tok with
    | "env" =>
      match rest.dropWhile isEnvAssignment with
      | [] => []
      | inner :: tail => lastComponent inner :: tail
    | "command" =>
      match rest with
      | [] => []
      | inner :: tail => lastComponent inner :: tail
    | name => name :: rest

/-- `-c` の引数(`bash -c '<cmd>'` / 結合フラグ `bash -lc '<cmd>'`)。
positional が先に来たら `-c` 形ではない(`bash script.sh` は none)。 -/
private def dashCArg? : List String → Option String
  | [] => none
  | tok :: rest =>
    if !tok.startsWith "-" then none
    else if tok == "-c" || (!tok.startsWith "--" && tok.toList.contains 'c') then
      rest.head?
    else dashCArg? rest

/-- shell 起動の名前(`-c` 引数が**実行される文字列**になるもの)。保護パス
直書き deny のセグメント絞り込み(`Classify.Bash.crossSegmentPathFlow`)も
この綴り集合で fail-closed 側へ倒す。 -/
def shellEntryNames : List String := ["bash", "sh", "zsh", "dash", "ksh"]

/-- セグメントが shell 起動なら、その `-c` 引数 = 実行される文字列。
`echo '...'` や heredoc の本文のような**実行されない**文字列は対象にしない —
全トークンを再帰展開すると、手順や文書を文字列として書くだけの正当な操作
(`echo 'just state resume'`、手順を綴る heredoc)まで deny になり、安全を
足さずに実害だけを生む。 -/
private def shellDashCPayload? (toks : List String) : Option String :=
  match toks with
  | [] => none
  | tok :: rest =>
    if shellEntryNames.contains (lastComponent tok) then dashCArg? rest
    -- `eval word...` はクォート除去後の残りを空白連結して**再実行**する。
    -- `-c` 形と同じく実行される文字列なので同じ遮断に載せる(I-011: `eval 'bin/<tool>
    -- state re"sume"'` のような綴りで resume / loop-only 遷移が素通りしないための核)。
    else if lastComponent tok == "eval" then some (String.intercalate " " rest)
    else none

/-- `state.py` 直後、`<tool> state` 直後(agent 向け配線面。`state` が
直後トークンでなければ entry ではない)、
または `just [--flags...] state` 直後のトークン列。`just` のフラグ走査が
`state` に届かなければ(値が別トークンのフラグ等)Python 同様その次の
トークンから走査を続ける。 -/
private def afterStateEntry (d : Domain) : List String → Option (List String)
  | [] => none
  | tok :: rest =>
    if lastComponent tok == "state.py" then some rest
    else if lastComponent tok == d.tool then
      match rest with
      | "state" :: tail => some tail
      | _ => afterStateEntry d rest
    else if lastComponent tok == "just" then
      match rest.dropWhile (·.startsWith "-") with
      | "state" :: tail => some tail
      | _ => afterStateEntry d rest
    else afterStateEntry d rest

/-- 値付きフラグ(直後の 1 トークンを無条件に消費)とその他の `-` 開始
トークンを跨いで、最初の positional を取る。 -/
private def firstPositional (d : Domain) : List String → Option String
  | [] => none
  | tok :: rest =>
    if tok.startsWith "--" then
      if (stateValueFlags d).contains tok then
        match rest with
        | _ :: rest' => firstPositional d rest'
        | [] => none
      else firstPositional d rest
    else if tok.startsWith "-" then firstPositional d rest
    else some tok

private def statePySubcommandsAux (d : Domain) : Nat → String → List String
  | 0, _ => []
  | fuel + 1, command =>
    (commandSegments command).flatMap fun seg =>
      let toks := normalizeCommandArgv (tokensLenient seg)
      ((afterStateEntry d toks).bind (firstPositional d)).toList
        ++ (match shellDashCPayload? toks with
            | some inner => statePySubcommandsAux d fuel inner
            | none => [])

/-- `state_py_subcommands(command)` 等価(先頭出現順・重複なし。Python の
set に対しファザーはソート比較)。フラグがどの位置にあっても positional の
サブコマンドを取り逃さない — resume / loop-only 遮断(I-011、§19.1)が
`state.py --project X resume` のようなフラグ先行綴りで素通りしないための核。
実行ファイルの綴り(絶対パス・`env` / `command` 前置)と、shell の `-c` 引数
(`bash -c 'bin/<tool> state ... resume'` — **実行される**文字列)も同じ
遮断に載せる。実行されない文字列(`echo '...'`・heredoc 本文)は対象外で、
その境界は `shellDashCPayload?` の頭注が持つ。 -/
def statePySubcommands (d : Domain) (command : String) : List String :=
  dedup (statePySubcommandsAux d (command.length + 1) command)

/-! ## command_launches_claude(pre_tool_guard.py、META.md §10) -/

/-- 先頭の `$` を剥ぐ(ANSI-C quoting `$'claude'` が token `$claude` を残す綴りへの
保守的正規化。基底名が `$` 付きで `claude` を指す obfuscation を塞ぐ)。 -/
private def stripLeadingDollar (s : String) : String :=
  String.ofList (s.toList.dropWhile (· == '$'))

private def launchesClaudeAux : Nat → String → Bool
  | 0, _ => false
  | fuel + 1, fragment =>
    (tokensLenient fragment).any fun tok =>
      stripLeadingDollar (lastComponent tok) == "claude"
        || (tok != fragment && launchesClaudeAux fuel tok)

/-- `command_launches_claude(command)` 等価: クォート除去後の各トークンの
basename(先頭 `$` 除去後)が `claude` か、各トークンを再帰的に再字句解析して
検出する(I-003 のネスト起動遮断)。空白を含むトークンだけを再帰していた旧実装は
`bash -c 'cla"ude"'`(単一引用が二重引用を literal 化した空白なしトークン)を
取り逃していた。tok が fragment と異なる限り再帰し、fuel(入力長 + 1)で全域化する
(自身との一致で停止、Python の `seen` 枝刈りと同値)。 -/
def commandLaunchesClaude (command : String) : Bool :=
  launchesClaudeAux (command.length + 1) command

/-! ## コンパイル時検査(期待値は pre_tool_guard.py の実関数・実パターンの
CPython 3.14 実測。方言差 1 点のみ注記) -/

-- isDenyPath
#guard isDenyPath Domain.fixture "ESSENCE.md" == true
#guard isDenyPath Domain.fixture "a/ESSENCE.md" == true
#guard isDenyPath Domain.fixture "ESSENCE.md/x" == false
#guard isDenyPath Domain.fixture "xESSENCE.md" == false
#guard isDenyPath Domain.fixture "ESSENCE.md\n" == true
#guard isDenyPath Domain.fixture "ESSENCE.md\n\n" == false
#guard isDenyPath Domain.fixture "b/ESSENCE.md\n" == true
#guard isDenyPath Domain.fixture "essences/logo.png" == true
#guard isDenyPath Domain.fixture "a/essences/x.pdf" == true
#guard isDenyPath Domain.fixture "essences/" == true
#guard isDenyPath Domain.fixture "essences" == false
#guard isDenyPath Domain.fixture "myessences/x" == false
#guard isDenyPath Domain.fixture "essencesx/y" == false
#guard isDenyPath Domain.fixture ".env" == true
#guard isDenyPath Domain.fixture ".envx" == false
#guard isDenyPath Domain.fixture ".env.local" == true
#guard isDenyPath Domain.fixture "a/.env" == true
#guard isDenyPath Domain.fixture "x/.env.prod/y" == true
#guard isDenyPath Domain.fixture "secrets/k" == true
#guard isDenyPath Domain.fixture "x/secrets/" == true
#guard isDenyPath Domain.fixture "mysecrets/x" == false
#guard isDenyPath Domain.fixture "secrets" == false
#guard isDenyPath Domain.fixture "config/credentials.json" == true
#guard isDenyPath Domain.fixture "a/config/credentials.json" == true
#guard isDenyPath Domain.fixture "credentials.json" == false
#guard isDenyPath Domain.fixture "essence_attestations.jsonl" == true
#guard isDenyPath Domain.fixture ".looper/state/project.json" == true
#guard isDenyPath Domain.fixture "p/.looper/state/project.json" == true
#guard isDenyPath Domain.fixture ".looper/state/project.jsonx" == false
-- 投影台帳の Edit 経路 deny(§20.2-8 機械強制)。集合は Domain 軸なので
-- fixture で駆動する: 共通 4 面は全ドメインに、追加面は持つドメインにだけ
-- 効き、持たないドメインでは deny しない(パラメータ化が効いている証拠)。
#guard isDenyPath Domain.fixture ".looper/state/spec.json" == true
#guard isDenyPath Domain.fixture ".looper/state/todo.json" == true
#guard isDenyPath Domain.fixture
    ".looper/state/recommendations.json" == true
#guard isDenyPath Domain.fixture
    ".looper/state/blockers.json" == true
#guard isDenyPath Domain.fixture
    "p/.looper/state/todo.json" == true
#guard isDenyPath Domain.fixtureRich
    ".looper/state/extra.json" == true
#guard isDenyPath Domain.fixture
    ".looper/state/extra.json" == false
-- agent が直接書く面は deny しない(context / reflection / high_risk_changes)
#guard isDenyPath Domain.fixture
    ".looper/state/context.json" == false
#guard isDenyPath Domain.fixture
    ".looper/state/reflection.jsonl" == false
#guard isDenyPath Domain.fixture
    ".looper/state/high_risk_changes.jsonl" == false
#guard isDenyPath Domain.fixture
    ".looper/state/validation.json" == false

-- isAskPath
#guard isAskPath "package.json" == true
#guard isAskPath "sub/package.json" == true
#guard isAskPath "package.jsonx" == false
#guard isAskPath "requirements.txt" == true
#guard isAskPath "requirements-dev.txt" == true
#guard isAskPath "requirements..txt" == true
#guard isAskPath "requirementsX_1.txt" == true
#guard isAskPath "requirements.txt.txt" == true
#guard isAskPath "requirements/x.txt" == false
#guard isAskPath "requirementsé.txt" == true
#guard isAskPath "requirements .txt" == false
#guard isAskPath "requirements-dev.txt\n" == true
#guard isAskPath "a/requirements.txt" == true
#guard isAskPath "xrequirements.txt" == false
-- 方言差(頭注): Python は false(`§` は `\w` 外)、Lean は ask 拡大側で true
#guard isAskPath "requirements§.txt" == true
#guard isAskPath "bun.lock" == true
#guard isAskPath "bun.lockb" == true
#guard isAskPath "bun.lockbb" == false
#guard isAskPath ".yarnrc" == true
#guard isAskPath ".yarnrc.yml" == true
#guard isAskPath ".yarnrc.yml2" == false
#guard isAskPath ".npmrc" == true
#guard isAskPath "go.mod" == true
#guard isAskPath "Pipfile" == true
#guard isAskPath "bunfig.toml" == true
#guard isAskPath "lakefile.lean" == true
#guard isAskPath "sub/lakefile.toml" == true
#guard isAskPath "lake-manifest.json" == true
#guard isAskPath "lean-toolchain" == true
#guard isAskPath ".cargo/config.toml" == true
#guard isAskPath "x/.cargo/config" == true
#guard isAskPath "xlakefile.lean" == false
#guard isAskPath "lakefile.leanx" == false
#guard isAskPath "go.sum" == true
#guard isAskPath "go.modx" == false
#guard isAskPath "Cargo.toml" == true
#guard isAskPath "uv.lock" == true
#guard isAskPath "pip.conf" == true
#guard isAskPath "Pipfile.lock" == true
#guard isAskPath "pnpm-lock.yaml" == true
#guard isAskPath ".pnpmfile.cjs" == true

-- isControlPlaneHighRisk(CONTROL_ROOT 相対パスへの ^ アンカー照合)
#guard isControlPlaneHighRisk "CLAUDE.md" == true
#guard isControlPlaneHighRisk "x/CLAUDE.md" == false
#guard isControlPlaneHighRisk "CLAUDE.md\n" == true
#guard isControlPlaneHighRisk ".claude/settings.json" == true
#guard isControlPlaneHighRisk "scripts/foo" == true
#guard isControlPlaneHighRisk "xscripts/foo" == false
#guard isControlPlaneHighRisk "templates/control/a.tmpl" == true
#guard isControlPlaneHighRisk "recipes/x" == true
#guard isControlPlaneHighRisk "justfile" == true
#guard isControlPlaneHighRisk "justfile\n" == true
#guard isControlPlaneHighRisk "justfilex" == false
#guard isControlPlaneHighRisk "META.md" == true
#guard isControlPlaneHighRisk "README.md" == true
#guard isControlPlaneHighRisk ".agent/prompts/p.md" == true
#guard isControlPlaneHighRisk ".agent/state/workspace.json" == true
#guard isControlPlaneHighRisk ".agent/state/project_index.json" == true
#guard isControlPlaneHighRisk ".agent/state/workspace.jsonx" == false
-- enforcement の実体(hook バイナリとその Lean ソース)も制御面である
#guard isControlPlaneHighRisk "bin/looper" == true
#guard isControlPlaneHighRisk "lean/Looper/Guard/Decide.lean" == true
#guard isControlPlaneHighRisk "lean/lakefile.lean" == true
#guard isControlPlaneHighRisk "xbin/looper" == false
#guard isControlPlaneHighRisk "src/lean/x" == false
-- 大小文字を区別しない FS(macOS 既定)では綴り違いは同じファイルなので
-- 同じに分類する。適用範囲は人間所有入力と enforcement 面だけ(§28.5-9)。
#guard isControlPlaneHighRisk "Scripts/x.sh" == true
#guard isControlPlaneHighRisk "META.MD" == true
#guard isControlPlaneHighRisk "JustFile" == true
#guard isControlPlaneHighRisk "Bin/looper" == true
#guard isDenyPath Domain.fixture "../p/essence.md" == true
#guard isDenyPath Domain.fixture "../p/Essences/logo.png" == true
#guard isDenyPath Domain.fixture "../p/.ENV" == true
#guard isDenyPath Domain.fixture
    "../p/.looper/State/Todo.json" == true
-- 対象プロジェクトのファイルを分類する 2 群は綴り厳密のまま(case-sensitive
-- な FS で別物を過剰一致させると headless の自動 deny が正当な作業を止める)
#guard isHighRiskPath "Hooks/Foo.cs" == false
#guard isHighRiskPath "hooks/foo.py" == true
#guard isAskPath "Package.json" == false
#guard isAskPath "package.json" == true

-- isHighRiskPath
#guard isHighRiskPath "CLAUDE.md" == true
#guard isHighRiskPath "x/CLAUDE.md" == true
#guard isHighRiskPath ".claude/settings.json" == true
#guard isHighRiskPath "a/.claude/x" == true
#guard isHighRiskPath ".mcp.json" == true
#guard isHighRiskPath "b/.mcp.json" == true
#guard isHighRiskPath ".cursor/rules" == true
#guard isHighRiskPath "AGENTS.md" == true
#guard isHighRiskPath ".github/workflows/ci.yml" == true
#guard isHighRiskPath "p/.github/workflows/ci.yml" == true
#guard isHighRiskPath "agent-runtime/x" == true
#guard isHighRiskPath "agents/a.md" == true
#guard isHighRiskPath "prompts/p.md" == true
#guard isHighRiskPath "x/prompts/p.md" == true
#guard isHighRiskPath "skills/s" == true
#guard isHighRiskPath "hooks/h.py" == true
#guard isHighRiskPath "a/hooks/h.py" == true
#guard isHighRiskPath "scripts/myagent.sh" == true
#guard isHighRiskPath "x/scripts/run-loop" == true
#guard isHighRiskPath "scripts/sub/agent" == false
#guard isHighRiskPath "scripts/x" == false
#guard isHighRiskPath "scripts/autonomous" == true
#guard isHighRiskPath "scripts/claudius" == false
#guard isHighRiskPath "scripts/my-loop.sh\n" == true
#guard isHighRiskPath "settings.json" == true
#guard isHighRiskPath "x/settings.json" == true
#guard isHighRiskPath "settings.jsonx" == false
#guard isHighRiskPath "loop-scripts/x" == false

-- statePySubcommands(重点: フラグ位置・just 綴り・セグメント分割・退避)
#guard statePySubcommands Domain.fixture "python3 scripts/state.py resume --project x" == ["resume"]
#guard statePySubcommands Domain.fixture "state.py --project X resume" == ["resume"]
#guard statePySubcommands Domain.fixture "just --unstable state resume" == ["resume"]
#guard statePySubcommands Domain.fixture "just state --project=x validate" == ["validate"]
#guard statePySubcommands Domain.fixture "state.py --project" == []
#guard statePySubcommands Domain.fixture "a; state.py status | just state should-stop"
  == ["status", "should-stop"]
#guard statePySubcommands Domain.fixture "just -f X loop" == []
#guard statePySubcommands Domain.fixture "echo 'state.py resume'" == []
-- C1-5 / I-011: `eval <word...>` は再実行される文字列なので同じ遮断に載せる
-- (クォート分断 `re"sume"` も再字句解析で捉える)。`echo` は非実行なので不変(上行)。
#guard statePySubcommands Domain.fixture "eval 'state.py resume'" == ["resume"]
#guard statePySubcommands Domain.fixture "eval 'bin/looper state re\"sume\"'" == ["resume"]
#guard statePySubcommands Domain.fixture "eval 'bin/looper state record-progress'" == ["record-progress"]
#guard statePySubcommands Domain.fixture "state.py 'resume" == ["'resume"]
#guard statePySubcommands Domain.fixture "/usr/bin/state.py should-stop" == ["should-stop"]
#guard statePySubcommands Domain.fixture ";;state.py status" == ["status"]
#guard statePySubcommands Domain.fixture "just state -- resume" == ["resume"]
#guard statePySubcommands Domain.fixture "state.py --note -- resume" == ["resume"]
-- §13.3-4'' の新値付きフラグも先行綴りで subcommand を取り逃さない(G-019)
#guard statePySubcommands Domain.fixture "state.py --retract-approval R-1 resume" == ["resume"]
#guard statePySubcommands Domain.fixture "state.py -x resume" == ["resume"]
#guard statePySubcommands Domain.fixture "just --flag=v state ensure" == ["ensure"]
#guard statePySubcommands Domain.fixture "state.py '' validate" == [""]
#guard statePySubcommands Domain.fixture "state.py --run-id abc end-run" == ["end-run"]
#guard statePySubcommands Domain.fixture "just foo state.py resume" == ["resume"]
#guard statePySubcommands Domain.fixture "state.py & state.py validate" == ["validate"]
#guard statePySubcommands Domain.fixture "state.py\tstatus" == ["status"]
#guard statePySubcommands Domain.fixture "state.py status; state.py status" == ["status"]
-- <tool> state 綴り(agent 向け配線面)
#guard statePySubcommands Domain.fixture "bin/looper state resume --project x" == ["resume"]
#guard statePySubcommands Domain.fixture "bin/looper state --project X resume" == ["resume"]
#guard statePySubcommands Domain.fixture "/cr/bin/looper state start-run" == ["start-run"]
#guard statePySubcommands Domain.fixture "looper state status" == ["status"]
#guard statePySubcommands Domain.fixture "bin/looper trust ensure" == []
#guard statePySubcommands Domain.fixture "looper util token state resume" == []
-- shell の `-c` 引数(= 実行される文字列)は同じ遮断に載る。実行されない
-- 文字列(`echo '...'`・heredoc 本文)は対象外という境界も同時に凍結する。
#guard statePySubcommands Domain.fixture "bash -c 'bin/looper state --project x resume'"
  == ["resume"]
#guard statePySubcommands Domain.fixture "sh -c 'just state resume'" == ["resume"]
#guard statePySubcommands Domain.fixture "bash -lc 'looper state start-run'" == ["start-run"]
#guard statePySubcommands Domain.fixture "env bash -c 'looper state resume'" == ["resume"]
#guard statePySubcommands Domain.fixture "echo 'state.py resume'" == []
#guard statePySubcommands Domain.fixture "bash script.sh" == []
#guard statePySubcommands Domain.fixture "bash -c 'echo hi'" == []
-- ラッパ前置の basename 正規化(依存ゲートと共有する `normalizeCommandArgv`)
#guard statePySubcommands Domain.fixture "env /cr/bin/looper state resume" == ["resume"]
#guard statePySubcommands Domain.fixture "command looper state validate" == ["validate"]
#guard statePySubcommands Domain.fixture "echo looper; state.py validate" == ["validate"]
#guard statePySubcommands Domain.fixture "looper; looper state validate" == ["validate"]
-- flag-first with the supervise-check value flags (--todo / --recommendation):
-- their VALUE must not be misread as the subcommand, or resume / loop-only
-- would slip through the guard (2026-07-27 regression).
#guard statePySubcommands Domain.fixture "bin/looper state --todo T-001 resume --project x"
  == ["resume"]
#guard statePySubcommands Domain.fixture "bin/looper state --recommendation R-001 resume"
  == ["resume"]
#guard statePySubcommands Domain.fixture "looper state --todo T-1 start-run" == ["start-run"]
#guard statePySubcommands Domain.fixture "looper state --todo T-1 raise-loop-gates"
  == ["raise-loop-gates"]
#guard statePySubcommands Domain.fixture "env looper state resume" == ["resume"]
#guard statePySubcommands Domain.fixture "bin/looper state" == []

-- commandLaunchesClaude
#guard commandLaunchesClaude "claude" == true
#guard commandLaunchesClaude "claude -p hi" == true
#guard commandLaunchesClaude "bash -c 'claude -p hi'" == true
#guard commandLaunchesClaude "cl\"\"aude" == true
#guard commandLaunchesClaude "/usr/local/bin/claude --help" == true
#guard commandLaunchesClaude "echo claude-code" == false
#guard commandLaunchesClaude "xclaude" == false
#guard commandLaunchesClaude "claude/" == false
#guard commandLaunchesClaude "bash -c \"sh -c 'claude'\"" == true
#guard commandLaunchesClaude "echo 'a b' claude" == true
#guard commandLaunchesClaude "c\\laude" == true
#guard commandLaunchesClaude "echo 'claude" == false
#guard commandLaunchesClaude "echo \"run claude now\"" == true
#guard commandLaunchesClaude "CLAUDE" == false
#guard commandLaunchesClaude "./claude" == true
#guard commandLaunchesClaude "env X='a b' true" == false
#guard commandLaunchesClaude "bash -c 'echo \"claude\"'" == true
-- I-003: 単一引用が二重引用を literal 化した空白なしトークンも再帰再字句解析で捕捉
#guard commandLaunchesClaude "bash -c 'cla\"ude\"'" == true
#guard commandLaunchesClaude "bash -c 'cl\"\"aude -p x'" == true
-- 先頭 `$` 剥ぎ(obfuscated basename)
#guard commandLaunchesClaude "$claude" == true
#guard commandLaunchesClaude "bash -c '$claude -p hi'" == true
-- 過剰一致しないこと
#guard commandLaunchesClaude "xclaude" == false
#guard commandLaunchesClaude "echo claude-code" == false

end Looper.Core.Classify
