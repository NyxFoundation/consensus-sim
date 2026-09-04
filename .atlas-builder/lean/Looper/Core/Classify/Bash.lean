import Looper.Core.Classify
import Looper.Core.Frag
import Looper.Core.Path
import Looper.Domain

/-!
`Looper.Core.Classify.Bash` — guard の分類カタログ・第 2 部: Bash コマンド
生テキストへの分類群。旧 Python guard との等価性は差分ファザーで検証済み
(§31.2-15)。

凍結した意味論(旧 pre_tool_guard.py 由来。× `re.search(pat, command)`):

1. `DENIED_BASH`(git add/commit)/ `HUMAN_ONLY_BASH`(resume・loop・once・init・
   doctor・trust・triage・supervise・essence 系 + `_JUST_PREFIX` フラグ跨ぎ)/
   `LOOP_ONLY_BASH` / `ASK_BASH` / `DANGEROUS_BASH` / `SECRET_BASH` —
   `isDeniedBash` / `isHumanOnlyBash` / `isLoopOnlyBash` / `isAskBash` /
   `isDangerousBash` / `isSecretBash` が対応(リスト × any を関数 1 本に畳む)。
2. `WRITE_REDIRECT_OR_MUTATOR` 単体(`hasWriteRedirectOrMutator`)と、その複合
   `DEPENDENCY_INPUT_BASH_MUTATION` / `CONTROL_SURFACE_BASH_MUTATION` /
   `ZONE_BASH_MUTATION`(`WRITE... [^;&|]* パス群` = 「同一パイプラインセグメント内で
   mutator の後にパスが現れる」)、および `bash_high_risk_targets` の動的複合
   `WRITE... [^;&|]* re.escape(token)`(`mutatesLiteralTarget`)。
3. main() ローカルの `protected_write_target`(`isProtectedWriteTarget`。mutator との
   連言は呼び出し側 = `Guard/Decide` の決定木)。
4. `re.findall(r"[-\w@.~/]+", command)` の `sorted(set(...))`(`bashPathishTokens`。
   `bash_high_risk_targets` のトークン抽出部)。

実装原理: 正規表現エンジンは書かず、各パターンを「断片マッチャ `Frag`(接尾辞を
消費して残りを返す)+ 全開始位置の走査」に直訳する。本カタログの全パターンは
以下の理由でバックトラック消去が受理同値になる(実装中の各所に個別注記):
- `\s+`・`\S*`・文字クラス反復の直後は常に排反な文字集合が続く(貪欲一致が唯一)。
- `_JUST_PREFIX` の star 反復はフラグ(`-` 開始)、後続 tail は英字開始で排反。
- 任意分割が要る箇所(`requirements[\w.-]*\.txt`、zone の `scripts/[^…]*(agent|…)`、
  複合の `[^;&|]*`)は分割点の存在判定として明示走査する。

CPython `re` 意味論の写し(実測で固定):
- `(curl|wget)[^|]*\|` の `[^|]*` は `|` を跨げないため、各 curl/wget 出現につき
  「直後の最初の `|`」だけが検査される(`curl a | x | sh` は不一致)。一方 `[^|]` は
  `;` や改行を含むため セグメントは跨ぐ(`curl a > f; cat f | sh` は一致)。
- `--?[\w-]+` は言語として `-[\w-]+` と同値(2 本目の `-` は文字クラスが吸収)。
  ゆえに `just -- resume` は human-only に一致する(実測)。
- `trust(?:-check)?\b` は `just trust-checkx` にも一致する(`-check` を放棄して
  `trust` + `\b`(`-` は非語)で成立。alternation を両綴りの試行として写す)。

裁定済み方言差(§31 参照。いずれも一致側が増える = deny/ask 拡大方向、R-6 自動採用):
- `\b`(語境界)の語クラスは ASCII `[A-Za-z0-9_]` のみとし、非 ASCII は常に
  非語構成文字 = 境界成立とする(`isAsciiWord`)。Python の `\w` は Unicode 準拠
  なので、非 ASCII の字母・数字がキーワードへ直接隣接する綴り(`égit add`・
  `git addé`)では Lean 側だけがマッチする。非 ASCII の記号・句読点・空白では
  両者一致。全使用箇所が deny/ask 側の分類のため拡大方向。
- `[\w-]`(just フラグ名)・`[\w.-]`(requirements 可変部)・`[-\w@.~/]`(pathish
  トークン)の `\w` は第 1 部の `isWordChar` 方言(非 ASCII は空白以外すべて語構成
  文字)。`just --flag§ resume` は Python 不一致・Lean 一致(deny 拡大)。
-/

namespace Looper.Core.Classify

open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (isPySpace runsOf dedup containsSub lowerStr)
open Looper.Core.Path (normpath)
open Looper.Core.Frag

/-! ## `_JUST_PREFIX` — `\bjust\s+(?:--?[\w-]+(?:=\S*)?\s+)*` -/

/-- `[\w-]`(フラグ名の文字クラス。`isWordChar` 方言 — 頭注)。 -/
private def isFlagChar (c : Char) : Bool := isWordChar c || c == '-'

/-- フラグ 1 反復 `-[\w-]+(?:=\S*)?\s+`(`--?[\w-]+` の同値形 — 頭注)。
`=\S*` の貪欲消費は直後の `\s+` と排反で唯一の分割。 -/
private def flagOnce : Frag
  | '-' :: rest =>
    let (name, rest) := rest.span isFlagChar
    if name.isEmpty then none
    else
      ws1 (match rest with
        | '=' :: r => r.dropWhile (fun c => !isPySpace c)
        | _ => rest)
  | _ => none

/-- star 反復 + tail。tail の全代替は英字開始・フラグは `-` 開始で排反のため、
各位置で tail を先に試す決定的評価が CPython のバックトラックと受理一致する。
フラグ 1 反復は 3 文字以上消費するので fuel = 入力長で十分。 -/
private def flagsStar (tail : Frag) : Nat → Frag
  | 0 => tail
  | fuel + 1 => fun cs => tail cs <|> (flagOnce cs).bind (flagsStar tail fuel)

/-- `re.search(_JUST_PREFIX ++ tail, s)`。 -/
private def searchJustPrefix (tail : Frag) (s : String) : Bool :=
  searchAtBoundary
    (fun cs => ((lit "just" >=> ws1) cs).bind fun rest =>
      flagsStar tail (rest.length + 1) rest)
    s

/-! ## DENIED_BASH(I-015: agent は stage / commit しない) -/

/-- `git` トークンの後、グローバルオプションを飛ばして最初の positional
(サブコマンド)を返す。`-C <dir>` / `-c <name=val>` は値を取るので次トークンも
飛ばす。`--git-dir=…` 等の `=` 同梱形・その他の `-`/`--` フラグは 1 トークン飛ばす。
構造的再帰(純度ゲート: partial 不可)。 -/
private def gitSubAfterOpts : List String → Option String
  | [] => none
  | tok :: rest =>
    if tok == "-C" || tok == "-c" then
      match rest with
      | _ :: r => gitSubAfterOpts r
      | [] => none
    else if tok.startsWith "-" then gitSubAfterOpts rest
    else some tok

/-- コマンドセグメント中の `git <sub>` を、グローバルオプション挟みに関わらず
検出する(`git -C x add` / `git -c k=v commit` も捉える。§28.5-4「綴りではなく
正規化 argv で判定」の git 版)。セグメント分割は `;`/`&`/`|` 境界。 -/
def commandHasGitSubcommand (command : String) (subs : List String) : Bool :=
  (commandSegments command).any fun seg =>
    match (normalizeCommandArgv (tokensLenient seg)).dropWhile
        (fun t => lastComponent t != "git") with
    | _git :: rest =>
      match gitSubAfterOpts rest with
      | some sub => subs.contains sub
      | none => false
    | [] => false

/-- コマンドセグメント中に `rm` の再帰(`-r`/`-R`/`--recursive`)と強制
(`-f`/`--force`)が**両方**立つ形があるか(`-rf` / `-fr` / `-r -f` /
`--recursive --force`、順不同)。plain `rm` / `rm -f` は対象外。 -/
def commandHasRecursiveForceRm (command : String) : Bool :=
  (commandSegments command).any fun seg =>
    match normalizeCommandArgv (tokensLenient seg) with
    | tok :: rest =>
      lastComponent tok == "rm" &&
        (let opts := rest.filter (·.startsWith "-")
         let shortFlag (o : String) (c : Char) : Bool :=
           o.startsWith "-" && !o.startsWith "--" && o.toList.contains c
         let hasR := opts.any fun o => o == "--recursive" || shortFlag o 'r' || shortFlag o 'R'
         let hasF := opts.any fun o => o == "--force" || shortFlag o 'f'
         hasR && hasF)
    | [] => false

/-- `DENIED_BASH` = `git add` / `git commit`(グローバルオプション挟みも含む、
I-015)。 -/
def isDeniedBash (command : String) : Bool :=
  searchAtBoundary (lit "git" >=> ws1 >=> lit "add" >=> wordEnd) command
    || searchAtBoundary (lit "git" >=> ws1 >=> lit "commit" >=> wordEnd) command
    || commandHasGitSubcommand command ["add", "commit"]

/-! ## HUMAN_ONLY_BASH(I-011、META.md §13.3・§18.2) -/

/-- `(?:loop|stop|once|init|doctor|trust(?:-check)?|triage|supervise|new-essence|update-essence)`
の展開(`trust(?:-check)?` は両綴りの代替として写す — 頭注)。`stop` は
graceful drain(§19.1-7)— loop のライフサイクル操作なので loop/once と同じ
human-only 面に載る(§18.2)。`should-stop` は別綴り(`stop` が語頭に来ない)
なので、この代替が state 述語の読み取り面(G-008/G-032)を侵食することはない
(下の #guard で凍結)。`watch` は常駐 TUI(§15.3)— cycle 内で起動すると
戻らないプロセスとして cycle が wedge するため deny(§18.4)。単発描画の
`state watch-render` は別綴り(`just` 直後に `watch` が来ない)で非侵食
(同じく #guard 凍結)。 -/
private def humanOnlyJustRecipes : List String :=
  ["loop", "stop", "once", "init", "doctor", "trust-check", "trust", "triage",
   "supervise", "new-essence", "update-essence", "watch"]

/-- `/+`(1 つ以上のスラッシュ)。`scripts//resume.sh` のような冗長な区切りで
照合を外せないようにする — パス解決は同じ 1 つのファイルへ届く。 -/
private def slashes : Frag := fun cs =>
  let (run, rest) := cs.span (· == '/')
  if run.isEmpty then none else some rest

/-- 運用スクリプトの照合形 `scripts/+<stem>.sh`(`Looper.scriptPath` の
正規表現側)。**素の basename では照合しない** — 理由は `scriptPath` の頭注。 -/
private def scriptPathFrag (stem : String) : Frag :=
  lit "scripts" >=> slashes >=> lit (stem ++ ".sh")

/-- クォート除去後のトークン列を空白 1 個で再連結した綴り。`just 'resume'` /
`bash scripts/lo"op".sh` のようなクォート分断で human-only / loop-only / ask の
テキスト照合を外せないようにする(`isSecretBash` / `isProtectedWriteTarget` の
トークン側照合と同じ規律)。字句解析不能なら `tokensLenient` が空白分割へ
退避するため、緩む側には倒れない。 -/
private def tokenJoined (command : String) : String :=
  String.intercalate " " (tokensLenient command)

/-- `HUMAN_ONLY_BASH` × `re.search`。`state\.py\s+resume` は綴りが隣接する形のみ
(フラグ先行綴りの遮断は `statePySubcommands` の責務 — 第 1 部)。 -/
private def isHumanOnlyBashText (d : Domain) (command : String) : Bool :=
  search (lit "state.py" >=> ws1 >=> lit "resume" >=> wordEnd) command
    -- Lean マルチコール綴り(agent 向け配線面。trust ensure
    -- と同じく、バイナリ直接呼び出しがゲートを迂回できない形で deny)
    || searchAtBoundary
        (lit d.tool >=> ws1 >=> lit "state" >=> ws1 >=> lit "resume" >=> wordEnd) command
    || search (scriptPathFrag "resume") command
    || searchJustPrefix (lit "resume" >=> wordEnd) command
    || searchJustPrefix (lit "state" >=> ws1 >=> lit "resume" >=> wordEnd) command
    || ["loop", "stop", "once", "init", "doctor", "triage", "essence",
        "supervise", "watch"].any (fun stem => search (scriptPathFrag stem) command)
    || searchJustPrefix (alts (humanOnlyJustRecipes.map fun w => lit w >=> wordEnd)) command
    || containsSub command "claude-trust.sh"
    || search (lit "claude_trust.py" >=> ws1 >=> lit "ensure" >=> wordEnd) command
    -- `trust status` も `~/.claude.json` を読む(I-024、§18.2 の trust-check と
    -- 同じ面)ので、subcommand を限定せず `<tool> trust` の両綴りを deny する。
    || searchAtBoundary
        (lit d.tool >=> ws1 >=> lit "trust" >=> wordEnd) command

/-- `isHumanOnlyBashText` を生テキストとトークン再連結の両方に適用する。 -/
def isHumanOnlyBash (d : Domain) (command : String) : Bool :=
  isHumanOnlyBashText d command || isHumanOnlyBashText d (tokenJoined command)

/-! ## LOOP_ONLY_BASH(META.md §19.1) -/

/-- `LOOP_ONLY_STATE_SUBCOMMANDS`(`state_py_subcommands` との積にも使う集合)。 -/
def loopOnlyStateSubcommands : List String :=
  ["start-run", "end-run", "record-progress", "reset-context", "raise-loop-gates"]

private def loopOnlySubTail : Frag :=
  alts (loopOnlyStateSubcommands.map fun w => lit w >=> wordEnd)

/-- `LOOP_ONLY_BASH` × `re.search`。 -/
private def isLoopOnlyBashText (d : Domain) (command : String) : Bool :=
  search (lit "state.py" >=> ws1 >=> loopOnlySubTail) command
    || searchAtBoundary
        (lit d.tool >=> ws1 >=> lit "state" >=> ws1 >=> loopOnlySubTail) command
    || searchJustPrefix (lit "state" >=> ws1 >=> loopOnlySubTail) command

/-- `isLoopOnlyBashText` を生テキストとトークン再連結の両方に適用する
(クォート分断対策 — `tokenJoined` の頭注)。 -/
def isLoopOnlyBash (d : Domain) (command : String) : Bool :=
  isLoopOnlyBashText d command || isLoopOnlyBashText d (tokenJoined command)

/-! ## ASK_BASH(bootstrap / build は明示承認) -/

/-- `ASK_BASH` × `re.search`(クォート分断対策に生テキストとトークン再連結の
両方 — `tokenJoined` の頭注)。 -/
def isAskBash (_d : Domain) (command : String) : Bool :=
  [command, tokenJoined command].any fun text =>
    search (scriptPathFrag "bootstrap") text
      || searchJustPrefix (lit "bootstrap" >=> wordEnd) text
      || searchJustPrefix (lit "build" >=> wordEnd) text

/-! ## DANGEROUS_BASH(安全ルールの絶対 deny) -/

/-- `[^|]*\|\s*(ba)?sh\b` の断片: 直後の最初の `|` まで進み(`[^|]` は `|` を
跨げない — 頭注)、`\s*` を剥いで `bash\b` / `sh\b` を試す。 -/
private def pipeShTail : Frag := fun cs =>
  match cs.dropWhile (· != '|') with
  | '|' :: rest =>
    alts [lit "bash" >=> wordEnd, lit "sh" >=> wordEnd] (rest.dropWhile isPySpace)
  | _ => none

/-- `DANGEROUS_BASH` × `re.search` の最初に一致したパターン(Python の
リスト順・正規表現リテラルそのまま)。guard の deny 文言
`f"Forbidden Bash pattern (safety rule): {pat}"` がパターン文字列を含む
ため、判定と文言の単一定義としてここに置く(`curl`/`wget` に `\b` はない —
`mycurl x | sh` も一致する。Python の実挙動)。 -/
def dangerousBashReason? (command : String) : Option String :=
  if searchAtBoundary (lit "rm" >=> ws1 >=> lit "-rf" >=> wordEnd) command
      || commandHasRecursiveForceRm command then
    some "\\brm\\s+-rf\\b"
  else if searchAtBoundary (lit "sudo" >=> wordEnd) command then
    some "\\bsudo\\b"
  else if searchAtBoundary (lit "git" >=> ws1 >=> lit "push" >=> wordEnd) command
      || commandHasGitSubcommand command ["push"] then
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

/-- `DANGEROUS_BASH` のいずれかに一致(`dangerousBashReason?` の Bool 面)。 -/
def isDangerousBash (command : String) : Bool :=
  (dangerousBashReason? command).isSome

/-! ## SECRET_BASH(META.md §11.4) -/

/-- `[\s\"'=/]`(相対パス参照が空白・クォート・`=` の後に座る前提の接頭辞クラス)。 -/
private def secretCls (c : Char) : Bool :=
  isPySpace c || c == '"' || c == '\'' || c == '=' || c == '/'

/-- I-024 の列挙済み home credential stores(§11.4)。command が `~/` / `$HOME/`
/ `${HOME}/` 前置でこれらを名指しした READ を deny する。`.claude` は `.claude/` と
`.claude.json` の両方を覆う。text は呼び出し側で小文字化済み。 -/
private def homeCredentialStore (text : String) : Bool :=
  let stores := [".ssh", ".aws", ".config/gcloud", ".kube", ".docker/config.json",
                 ".npmrc", ".pypirc", ".netrc", ".claude"]
  let prefixes := ["~/", "$home/", "${home}/"]
  prefixes.any fun pre => stores.any fun s => containsSub text (pre ++ s)

/-- `SECRET_BASH` の 1 テキスト分の照合(text は正規化済み: 小文字化、
トークン経路では normpath 済み)。 -/
private def secretBashText (text : String) : Bool :=
  searchPrefixed secretCls (lit ".env" >=> wordEnd) text
    || searchPrefixed secretCls (lit "secrets/") text
    || searchPrefixed secretCls (lit "config/credentials.json" >=> wordEnd) text
    || homeCredentialStore text

/-- `SECRET_BASH` × `re.search`。生テキスト(小文字化)に加え、**字句解析後の
トークンを normpath+小文字化して**照合する — 大小文字違い(`.ENV`、
case-insensitive FS で同一)・クォート分断(`.en''v`)・冗長スラッシュ
(`config//credentials.json`)で secret read の deny 床(I-024)を外せた綴り替えを
まとめて塞ぐ(§28.5-9 の「人間所有・enforcement 面は大小文字非依存」を Bash 面
にも及ぼす。Edit 面 `isDenyPath` と同じ規律)。生テキストへの normpath は
引数付きコマンド全体を壊すためトークンにだけ適用する(緩む側に倒れない)。 -/
def isSecretBash (command : String) : Bool :=
  secretBashText (lowerStr command)
    || (tokensLenient command).any fun t => secretBashText (lowerStr (normpath t))

/-! ## WRITE_REDIRECT_OR_MUTATOR と複合 mutation 群 -/

/-- `>>?`。1 個消費か 2 個消費かは後続の `[^;&|]*` が吸収するため受理に無関係。 -/
private def gt1or2 : Frag
  | '>' :: '>' :: rest => some rest
  | '>' :: rest => some rest
  | _ => none

/-- `\b(?:sed\s+-i|tee|mv|cp|rm)\b` の語部(先頭 `\b` は呼び出し側)。 -/
private def wordMutator : Frag :=
  alts [lit "sed" >=> ws1 >=> lit "-i", lit "tee", lit "mv", lit "cp", lit "rm"]
    >=> wordEnd

/-- `WRITE_REDIRECT_OR_MUTATOR` の 1 開始位置分
(`[0-9]?>>?` / `&>>?` / 語 mutator)。 -/
private def mutatorAt (prev : Option Char) : Frag := fun cs =>
  (match cs with
    | '&' :: rest => gt1or2 rest
    | c :: rest => if c.isDigit then gt1or2 rest else gt1or2 cs
    | [] => none)
  <|> (if boundaryBefore prev then wordMutator cs else none)

/-- `re.search(WRITE_REDIRECT_OR_MUTATOR, command)` 等価。 -/
def hasWriteRedirectOrMutator (command : String) : Bool :=
  (positions command).any fun (prev, sfx) => (mutatorAt prev sfx).isSome

/-- 保護パス直書き deny(§11.3)**専用**に足す「書き得るコマンド」。
`WRITE_REDIRECT_OR_MUTATOR` の 5 種だけでは `perl -i` / `truncate` /
`install` / `ln -sf` / 汎用インタプリタのインラインプログラム
(`python3 -c "open(...,'w')"`)といったごく普通の書込み手段を取り逃す。

**この集合を共有 `wordMutator` には足さない。** 共有側は control-surface /
zone / manifest の判定にも使われ、そこでは mutator が対象パスの**前**に
出現するかを見るため、インタプリタを足すと `python3 scripts/x.py validate`
のような読取まで deny になる(凍結検査 `isControlSurfaceBashMutation ... ==
false` が実際にこれを捕捉した)。保護パス側は「コマンドが保護パスを名指し
している」ことを既に連言で要求しているので、広げても影響はその内側に閉じる。
汎用インタプリタは静的に読取専用と示せないので、保護パスを名指しした時点で
deny 側へ倒す(fail-closed)。 -/
private def extraProtectedWriter : Frag :=
  alts [lit "truncate", lit "install", lit "ln", lit "dd", lit "patch",
        lit "perl", lit "python3", lit "python", lit "ruby", lit "node"]
    >=> wordEnd

/-- 保護パス直書き判定の mutator 面(`hasWriteRedirectOrMutator` ∪ 上記)。 -/
def hasProtectedPathWriter (command : String) : Bool :=
  hasWriteRedirectOrMutator command
    || (positions command).any fun (prev, sfx) =>
         boundaryBefore prev && (extraProtectedWriter sfx).isSome

/-- mutator 直後から `[^;&|]*` で届く各位置(セパレータ手前まで)で tail を試す。
tail は打ち切られていない実残余に適用するため、`\b` の先読みも Python と一致する。 -/
private def mutatedFrom (tail : Frag) : List Char → Bool
  | [] => (tail []).isSome
  | c :: rest =>
    (tail (c :: rest)).isSome
      || ((c != ';' && c != '&' && c != '|') && mutatedFrom tail rest)

/-- `re.search(WRITE_REDIRECT_OR_MUTATOR ++ "[^;&|]*" ++ tail, command)` 等価。 -/
private def searchMutated (tail : Frag) (command : String) : Bool :=
  (positions command).any fun (prev, sfx) =>
    match mutatorAt prev sfx with
    | some rest => mutatedFrom tail rest
    | none => false

/-- `bash_high_risk_targets` の動的複合
`WRITE_REDIRECT_OR_MUTATOR + [^;&|]* + re.escape(target)` 等価。 -/
def mutatesLiteralTarget (target command : String) : Bool :=
  searchMutated (lit target) command

/-! ### _DEPENDENCY_INPUT_PATH(ASK_PATTERNS の Bash 側補完、META.md §11.2) -/

/-- `requirements[\w.-]*\.txt\b` の可変部走査: 各位置で `.txt\b` を試し、失敗なら
`[\w.-]` を 1 文字進める(任意分割の存在判定)。 -/
private def reqTxtScan : List Char → Option (List Char)
  | [] => none
  | c :: rest =>
    (lit ".txt" >=> wordEnd) (c :: rest)
      <|> (if isReqChar c then reqTxtScan rest else none)

/-- 依存解決入力の固定名(`bun\.lockb?`・`\.yarnrc(?:\.yml)?` は選択肢を展開。
Edit 経路 `isAskPath` と対で保守する — SyncPairs D-006)。 -/
private def depLiterals : List String :=
  ["package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml",
   "yarn.lock", "bun.lockb", "bun.lock", "bunfig.toml",
   ".npmrc", ".yarnrc.yml", ".yarnrc",
   ".pnpmfile.cjs", "pyproject.toml", "uv.lock", "poetry.lock", "Pipfile.lock",
   "Pipfile", "pip.conf",
   "Cargo.toml", "Cargo.lock", ".cargo/config.toml", ".cargo/config",
   "go.mod", "go.sum",
   "lakefile.lean", "lakefile.toml", "lake-manifest.json", "lean-toolchain"]

private def dependencyInputTail : Frag :=
  alts ((depLiterals.map fun w => lit w >=> wordEnd)
    ++ [lit "requirements" >=> fun cs => reqTxtScan cs])

/-- `re.search(DEPENDENCY_INPUT_BASH_MUTATION, command)` 等価(接頭辞アンカーは
なく、`> mypackage.json` も一致する — Python の実挙動)。 -/
def isDependencyInputBashMutation (command : String) : Bool :=
  searchMutated dependencyInputTail command

/-! ### _CONTROL_SURFACE_PATH(CONTROL_PLANE_HIGH_RISK の Bash 側補完、META.md §11.3) -/

/-- `[\s\"'=]`(`/` を含まない — zone との差)。 -/
private def ctlCls (c : Char) : Bool :=
  isPySpace c || c == '"' || c == '\'' || c == '='

/-- `(\./)?`。後続(`scripts/` / `README.md`)は `.` で始まらないため決定的。 -/
private def optDotSlash : Frag := fun cs =>
  match dropLit? cs "./".toList with
  | some rest => some rest
  | none => some cs

/-- `[^\s\"';&|]`。 -/
private def isBashWordChar (c : Char) : Bool :=
  !isPySpace c && c != '"' && c != '\'' && c != ';' && c != '&' && c != '|'

/-- `[^\s\"';&|]+`。 -/
private def some1BashWord : Frag := fun cs =>
  let (run, rest) := cs.span isBashWordChar
  if run.isEmpty then none else some rest

/-- `[^\s\"';&|]*\.sh`(`scripts/` 直下の配布スクリプト 1 語)。中立名化
(抽出計画 D-12)で製品接頭辞が消えたので、旧形の `<tool>-[A-Za-z-]+\.sh` に
代えて「`.sh` を含む 1 語」を受ける。**語の外へは出ない** — 走査は bash の語を
構成しない文字で止まるので、`/x/scripts/foo` のような framework 外の綴りが
制御面と誤認されることはない(この 1 語制限が旧形と共有する要点である)。 -/
private def shWordFrag : Frag := go
where
  go : List Char → Option (List Char)
    | [] => none
    | c :: rest =>
      match dropLit? (c :: rest) ".sh".toList with
      | some r => some r
      | none => if isBashWordChar c then go rest else none

/-- `claude[-_]trust\.(py|sh)`。`.py` 綴り(Lean 移行前の面)は `shWordFrag`
が受けないので、独立の分岐として残す。 -/
private def claudeTrustFrag : Frag :=
  lit "claude" >=> cls (fun c => c == '-' || c == '_') >=> lit "trust."
    >=> alts [lit "py", lit "sh"]

/-- `_CONTROL_SURFACE_PATH` の代替(複合内では `^` 分岐は発火し得ない —
mutator が 1 文字以上消費するため。tail は接頭辞クラス消費形のみで写す)。 -/
private def controlSurfaceTail (_d : Domain) : Frag :=
  alts
    [ lit "scripts/"
        >=> alts [lit "state.py", shWordFrag, claudeTrustFrag],
      cls ctlCls >=> optDotSlash >=> lit "scripts/" >=> some1BashWord,
      lit "templates/control/", lit "templates/project/", lit "templates/workspace/",
      lit "recipes/",
      lit ".agent/prompts/",
      lit "META.md",
      cls ctlCls >=> optDotSlash >=> lit "README.md" >=> wordEnd,
      lit "justfile" >=> wordEnd ]

/-- `re.search(CONTROL_SURFACE_BASH_MUTATION, command)` 等価。 -/
def isControlSurfaceBashMutation (d : Domain) (command : String) : Bool :=
  searchMutated (controlSurfaceTail d) command

/-! ### _ZONE_BASH_PATH(HIGH_RISK_PATTERNS の Bash 側補完、META.md §12) -/

/-- `scripts/[^\s\"';&|]*(agent|claude|loop|autonomous)` の可変部走査
(`[^/]*` ではないため `scripts/sub/agent` も一致する — パス分類版との差)。 -/
private def zoneScriptsScan : List Char → Option (List Char)
  | [] => none
  | c :: rest =>
    alts [lit "agent", lit "claude", lit "loop", lit "autonomous"] (c :: rest)
      <|> (if isBashWordChar c then zoneScriptsScan rest else none)

private def zoneDotCls (c : Char) : Bool := secretCls c || c == '.'

/-- `_ZONE_BASH_PATH` の代替(`^` 分岐は複合内で発火し得ない)。接頭辞クラスは
`[\s\"'=/]`(= `secretCls`)、ドットファイルのみ `.` を加えた `[\s\"'=/.]`。 -/
private def zoneTail : Frag :=
  alts
    [ cls secretCls >=> lit "CLAUDE.md" >=> wordEnd,
      cls zoneDotCls >=> lit ".claude/",
      cls secretCls >=> lit ".mcp.json" >=> wordEnd,
      cls zoneDotCls >=> lit ".cursor/",
      cls secretCls >=> lit "AGENTS.md" >=> wordEnd,
      lit ".github/workflows/",
      cls secretCls >=> lit "agent-runtime/",
      cls secretCls >=> lit "agents/",
      cls secretCls >=> lit "prompts/",
      cls secretCls >=> lit "skills/",
      cls secretCls >=> lit "hooks/",
      lit "scripts/" >=> fun cs => zoneScriptsScan cs,
      cls secretCls >=> lit "settings.json" >=> wordEnd ]

/-- `re.search(ZONE_BASH_MUTATION, command)` 等価。 -/
def isZoneBashMutation (command : String) : Bool :=
  searchMutated zoneTail command

/-! ## protected_write_target(main() ローカル、canonical/secret 直接書換の deny) -/

/-- `ESSENCE\.md|essences/|\.<tool>/state/|\.env($|\.|\s)|secrets/|config/credentials\.json|essence_attestations\.jsonl|\.agent/state/`
× `re.search`(接頭辞クラスなしの生部分一致 — `x.env` も一致する。mutator との
連言は呼び出し側)。`essences/` は ESSENCE.md と同格の human-only 資産面
(§2.1.5)。`$` の「末尾 1 個の `\n` 直前」特例は `\s` の `\n` が吸収する
ため、真の末尾のみで写す。 -/
private def protectedTargetText (d : Domain) (text : String) : Bool :=
  containsSub text "essence.md"
    || containsSub text "essences/"
    || containsSub text s!"{d.controlDirName}/state/"
    || search
        (lit ".env"
          >=> alts [fun cs => if cs.isEmpty then some [] else none,
                    cls fun c => c == '.' || isPySpace c])
        text
    || containsSub text "secrets/"
    || containsSub text "config/credentials.json"
    || containsSub text "essence_attestations.jsonl"
    || containsSub text ".agent/state/"

/-- 生テキストに加えて**字句解析後のトークン**でも照合する。生の部分一致だけ
だと、shell が同じ 1 パスとして解決する綴りをクォートで分断するだけで判定を
外せた(`cp a ../p/'ESSENCE'.md`、`echo x > ../p/.<tool>/'state'/todo.json`)。
トークン側はクォート除去後の実パスなので、この一族の綴り替えをまとめて塞ぐ。
`protectedTargetText` は小文字化済みテキスト前提(大小文字違いを塞ぐ §28.5-9 —
Edit 面 `isDenyPath` と同一規律)、トークンには normpath も適用して冗長スラッシュ
(`.<tool>//state/`)を潰す。字句解析不能な入力では `tokensLenient` が空白分割へ
退避するため、生テキスト判定だけが残る(緩む側には倒れない)。

保護面の**ディレクトリ自身**を名指すトークン(`rm -r essences` /
`mv .<tool>/state /tmp` — 末尾スラッシュの無い綴り)。prefix 形(`essences/`)
は中身への書込みを塞ぎ、この等値形は面そのものの削除・改名・上書きを塞ぐ
(§2.1.5「write, move, rename, or delete」)。トークンは normpath 済みなので
`essences/`(末尾スラッシュ)もここへ正規化される。 -/
private def protectedBareDirTok (d : Domain) (t : String) : Bool :=
  ["essences", "secrets", s!"{d.controlDirName}/state", ".agent/state"].any
    fun n => t == n || t.endsWith ("/" ++ n)

def isProtectedWriteTarget (d : Domain) (command : String) : Bool :=
  protectedTargetText d (lowerStr command)
    || (tokensLenient command).any fun t =>
         let tok := lowerStr (normpath t)
         protectedTargetText d tok || protectedBareDirTok d tok

/-! ## 保護パス直書き deny の**セグメント単位**判定(§11.3、2026-08-12 改訂)

旧判定は `isProtectedWriteTarget command && hasProtectedPathWriter command` —
**コマンド全文の無順序連言**だった。「保護パス文字列がどこかにある」かつ
「writer トークンがどこかにある」だけで deny なので、次の 2 形が誤拒否される:

```
cat .<tool>/state/todo.json | python3 -m json.tool   # python3 は別セグメント
grep install .<tool>/state/todo.json                 # install は grep の引数
```

実走行では、この誤拒否経験が「.<tool>/state は grep/tail でも hook 拒否」と
いう**過剰一般化された学習**として handoff に伝承されていた(素の grep/tail は
実際には通っており、tool_audit.jsonl にも通過記録がある)。原因はガード側にある。

改訂後の判定は 2 点で絞る:

1. **セグメント**(`[;&|]` 区切り — 複合パターンの `[^;&|]*` と同じ粒度)の
   内側で保護パスと writer が共起することを要求する。
2. writer の語形(`rm` / `cp` / `python3` / `install` …)は、そのセグメントの
   **コマンド位置**(先頭語。`env`/`command` ラッパと `VAR=v` 前置は剥がす)に
   あるときだけ writer として数える。リダイレクト(`>` / `>>` / `&>`)は
   セグメント内のどこでも writer である。

**fail-closed の逃げ道**: パスがセグメント間を渡る構文(`xargs` / `find -exec` /
コマンド置換 / `eval`)が現れたら、絞り込みをやめて旧来の全文連言へ落とす。
`ls .<tool>/state/ | xargs rm` のような形で deny 床が薄くならないための担保で
あり、投影 7 面が OS sandbox の `denyWrite` に裏打ちされない唯一の保護面で
ある以上(G-047)、ここは厳しい側に倒す。 -/

/-- セグメント間をパスが渡り得る構文。ここに触れたら全文連言へフォールバック
する(fail-closed)。 -/
private def crossSegmentPathFlow (command : String) : Bool :=
  let lowered := lowerStr command
  containsSub lowered "$(" || containsSub lowered "`"
    || containsSub lowered "-exec" || containsSub lowered "-delete"
    || ((tokensLenient command).any fun t =>
      let base := lastComponent t
      base == "xargs" || base == "eval" || base == "parallel"
        -- `sh -c '<cmd>'` の本文は別の字句空間で実行される(セグメント分割も
        -- コマンド位置判定もその内側には届かない)ため、shell 起動を含む形は
        -- 全文連言へ落とす(`bash -c 'cp x ESSENCE.md'` の素通り封止)。
        || shellEntryNames.contains base
        -- ループ変数がパスをセグメント間で運ぶ(`for f in ESSENCE.md; do rm $f`)
        || base == "for" || base == "while" || base == "until")

/-- コマンド位置の前置ラッパ(剥がしても実行されるコマンドは変わらない)。
`sudo` は別途 dangerous で deny されるが、剥がしておくことに害はない。 -/
private def commandPositionWrappers : List String :=
  ["sudo", "nohup", "time", "nice", "stdbuf", "setsid", "exec", "builtin",
   "command", "doas", "ionice", "timeout",
   -- shell キーワード: 剥がしても後続コマンドが実行される事実は変わらない
   -- (`if true; then rm ESSENCE.md; fi` の `then` セグメント)
   "if", "then", "elif", "else", "do", "{", "(", "!"]

/-- `VAR=value` 前置(`normalizeCommandArgv` の `env` 前置代入と同じ形)。 -/
private def isEnvAssignmentTok (t : String) : Bool :=
  match t.toList.span (· != '=') with
  | (name, _ :: _) =>
    match name with
    | c :: rest =>
      (c.isAlpha || c == '_') && rest.all fun c => c.isAlphanum || c == '_'
    | [] => false
  | _ => false

/-- 数値開始トークン(`timeout 5` / `nice -n 5` の持続時間・優先度引数)。
ラッパの直後でだけ読み飛ばす — コマンド位置に数値が立つことはなく、
読み飛ばしは deny 側(検出強化)にしか倒れない。 -/
private def isDigitInitial (t : String) : Bool :=
  match t.toList with
  | c :: _ => c.isDigit
  | [] => false

/-- `env` の引数(代入 `NAME=VALUE`・flag。値付き `-u` / `-C` / `-S` は
1 トークン道連れ)。剥がし過ぎは deny 側にしか倒れない(この関数の消費点は
保護パス deny の writer 判定だけである)。 -/
private def stripEnvArgs : List String → List String
  | [] => []
  | t :: rest =>
    if isEnvAssignmentTok t then stripEnvArgs rest
    else if t == "-u" || t == "-C" || t == "-S" then
      match rest with
      | [] => []
      | _ :: rest' => stripEnvArgs rest'
    else if t.startsWith "-" then stripEnvArgs rest
    else t :: rest

/-- ラッパを剥がしながらコマンド位置トークンを探す。fuel はトークン数
(1 反復につき最低 1 トークン消費するので上界として十分)— 純粋核レイヤは
`partial` を禁じている(§31.1 R-3、purity-gate が機械検査)。コマンド位置の
`-flag`(`env -i` の残骸等)は読み飛ばす — flag はコマンドになれない。 -/
private def commandPositionAux : Nat → List String → Option String
  | 0, _ => none
  | fuel + 1, toks =>
    match toks.dropWhile isEnvAssignmentTok with
    | [] => none
    | tok :: rest =>
      if tok.startsWith "-" then commandPositionAux fuel rest
      else
        let base := lastComponent tok
        if base == "env" then commandPositionAux fuel (stripEnvArgs rest)
        else if commandPositionWrappers.contains base then
          commandPositionAux fuel (rest.dropWhile fun t =>
            t.startsWith "-" || isEnvAssignmentTok t || isDigitInitial t)
        else some base

/-- セグメントのコマンド位置トークン(basename)。`VAR=v` 前置・`env` /
`command` ラッパ(`normalizeCommandArgv`)・上記ラッパ語を剥がす。 -/
def commandPositionToken? (segment : String) : Option String :=
  let toks := tokensLenient segment
  commandPositionAux (toks.length + 1) toks

/-- コマンド位置に立ったとき書込み手段になる語(`wordMutator` の 5 種 ∪
`extraProtectedWriter` の 10 種)。位置を問う判定なので語形の照合で足りる。 -/
private def protectedWriterCommands : List String :=
  ["sed", "tee", "mv", "cp", "rm",
   "truncate", "install", "ln", "dd", "patch",
   "perl", "python3", "python", "ruby", "node"]

/-- リダイレクト(`[0-9]?>>?` / `&>>?`)だけの検出 — 語 mutator を含まない。
セグメント内のどこにあっても writer である(`cat x > y` の `>` は位置自由)。 -/
private def hasWriteRedirect (command : String) : Bool :=
  (positions command).any fun (_, sfx) =>
    (match sfx with
      | '&' :: rest => gt1or2 rest
      | c :: rest => if c.isDigit then gt1or2 rest else gt1or2 sfx
      | [] => none).isSome

/-- 1 セグメントの writer 判定(リダイレクト ∪ コマンド位置の書込み語)。 -/
def segmentHasProtectedWriter (segment : String) : Bool :=
  hasWriteRedirect segment
    || ((commandPositionToken? segment).map protectedWriterCommands.contains
        |>.getD false)

/-- 保護パス直書き deny の最終判定(`Guard/Decide` の唯一の消費点)。 -/
def protectedPathWriteDeny (d : Domain) (command : String) : Bool :=
  if crossSegmentPathFlow command then
    -- fail-closed: パスがセグメント間を渡り得る形は絞り込まない。
    -- `find <保護パス> -delete` だけは writer 語をまったく含まないので、
    -- ここで明示的に writer として数える(`-exec rm` や `| xargs rm` は
    -- `rm` が語として現れるため既存の集合が捉えている)。
    isProtectedWriteTarget d command
      && (hasProtectedPathWriter command
        || containsSub (lowerStr command) "-delete")
  else
    (commandSegments command).any fun seg =>
      isProtectedWriteTarget d seg && segmentHasProtectedWriter seg

/-! ## bash_high_risk_targets のトークン抽出部 -/

/-- `[-\w@.~/]`(`\w` は `isWordChar` 方言 — 頭注)。 -/
private def isPathishChar (c : Char) : Bool :=
  isWordChar c || c == '@' || c == '.' || c == '~' || c == '/' || c == '-'

/-- `sorted(set(re.findall(r"[-\w@.~/]+", command)))` 等価(コードポイント昇順)。 -/
def bashPathishTokens (command : String) : List String :=
  (dedup ((runsOf isPathishChar command).map String.ofList)).mergeSort
    fun a b => decide (a < b) || a == b

/-! ## コンパイル時検査(期待値は pre_tool_guard.py の実パターンの CPython 3.14
実測。方言差はその旨を注記) -/

-- isSecretBash
#guard isSecretBash ".env" == true
#guard isSecretBash "cat .env" == true
#guard isSecretBash "cat .envx" == false
#guard isSecretBash "cat .env.local" == true
#guard isSecretBash "x.env" == false
#guard isSecretBash "a/.env" == true
#guard isSecretBash "FOO=.env" == true
#guard isSecretBash "cat 'secrets/k'" == true
#guard isSecretBash "mysecrets/x" == false
#guard isSecretBash "cat config/credentials.json" == true
#guard isSecretBash "config/credentials.json" == true
#guard isSecretBash "xconfig/credentials.json" == false
#guard isSecretBash "cat .env\n" == true
#guard isSecretBash "cat .env2" == false
#guard isSecretBash "cat .env-x" == true
#guard isSecretBash "echo \".env\"" == true
#guard isSecretBash "secrets/" == true
#guard isSecretBash "cat\tsecrets/k" == true
-- 綴り替えバイパスの封鎖(§28.5-9 / I-024): 大小文字 / 冗長スラッシュ /
-- クォート分断 / home credential stores(§11.4)
#guard isSecretBash "cat .ENV" == true
#guard isSecretBash "cat .Env.local" == true
#guard isSecretBash "cat config//credentials.json" == true
#guard isSecretBash "cat Secrets/k" == true
#guard isSecretBash "cat ~/.ssh/id_rsa" == true
#guard isSecretBash "cat $HOME/.aws/credentials" == true
#guard isSecretBash "cat ${HOME}/.config/gcloud/x" == true
#guard isSecretBash "cat ~/.claude.json" == true
#guard isSecretBash "cat ~/.netrc" == true
#guard isSecretBash "cat ~/.kube/config" == true
-- 過剰一致しないこと(境界は保つ)
#guard isSecretBash "cat .envx" == false
#guard isSecretBash "mysecrets/x" == false
#guard isSecretBash "npm test" == false
#guard isSecretBash "cat .claude/settings.json" == false

-- isDeniedBash
#guard isDeniedBash "git add ." == true
#guard isDeniedBash "git commit -m x" == true
#guard isDeniedBash "git  add" == true
#guard isDeniedBash "gitadd" == false
#guard isDeniedBash "mygit add" == false
#guard isDeniedBash "git\tadd" == true
#guard isDeniedBash "git addx" == false
#guard isDeniedBash "git add;" == true
#guard isDeniedBash "git push" == false
#guard isDeniedBash "git status" == false
#guard isDeniedBash "x && git commit" == true
#guard isDeniedBash "git\ncommit" == true
-- C1-7 / I-015: グローバルオプション挟み(`git -C <dir> add`)も deny する
-- (旧実装は permissions 側が受ける前提で false だったが、prefix パターンは
-- `git -C x add` に一致せず床が存在しなかった)。status / diff は over-deny しない。
#guard isDeniedBash "git -C x add" == true
#guard isDeniedBash "git -C /tmp/p commit -m y" == true
#guard isDeniedBash "git -c user.name=x add ." == true
#guard isDeniedBash "git --git-dir=/p/.git add ." == true
#guard isDeniedBash "foo && git -C x add" == true
#guard isDeniedBash "git -C x status" == false
#guard isDeniedBash "git -C x diff" == false
#guard isDeniedBash "git -C x log" == false
-- 方言差(頭注): Python は false(é は \w)、Lean は境界 ASCII 方言で true(deny 拡大)
#guard isDeniedBash "égit add" == true
#guard isDeniedBash "git addé" == true
-- 非 ASCII でも記号・空白は両実装一致
#guard isDeniedBash "git add§" == true

-- isHumanOnlyBash
#guard isHumanOnlyBash Domain.fixture "python3 scripts/state.py resume" == true
#guard isHumanOnlyBash Domain.fixture "state.py --project X resume" == false
#guard isHumanOnlyBash Domain.fixture "just resume" == true
#guard isHumanOnlyBash Domain.fixture "just --unstable resume" == true
#guard isHumanOnlyBash Domain.fixture "just -f X resume" == false
#guard isHumanOnlyBash Domain.fixture "just -- resume" == true
#guard isHumanOnlyBash Domain.fixture "just - resume" == false
#guard isHumanOnlyBash Domain.fixture "just state resume" == true
#guard isHumanOnlyBash Domain.fixture "just --flag=v state resume" == true
#guard isHumanOnlyBash Domain.fixture "justx resume" == false
#guard isHumanOnlyBash Domain.fixture "xjust resume" == false
#guard isHumanOnlyBash Domain.fixture "just  resume" == true
#guard isHumanOnlyBash Domain.fixture "just resumex" == false
#guard isHumanOnlyBash Domain.fixture "just triage" == true
#guard isHumanOnlyBash Domain.fixture "just trust" == true
#guard isHumanOnlyBash Domain.fixture "just trust-check" == true
#guard isHumanOnlyBash Domain.fixture "just trust-checkx" == true
#guard isHumanOnlyBash Domain.fixture "just trustx" == false
#guard isHumanOnlyBash Domain.fixture "just new-essence" == true
#guard isHumanOnlyBash Domain.fixture "just update-essence" == true
-- 中立名化(D-12)後の照合面は `scripts/<stem>.sh` のパス形である。素の
-- basename で照合しないのは、対象プロジェクトのありふれた `init.sh` /
-- `status.sh` を human-only として拒否しないため(`Looper.scriptPath` 頭注)。
-- 実際に動く呼び出し形はすべて `scripts/` を通る(`assert_control_root`)。
#guard isHumanOnlyBash Domain.fixture "scripts/loop.sh" == true
#guard isHumanOnlyBash Domain.fixture "bash scripts/loop.sh" == true
#guard isHumanOnlyBash Domain.fixture "bash ../.looper/scripts/loop.sh" == true
#guard isHumanOnlyBash Domain.fixture "bash scripts//loop.sh" == true
#guard isHumanOnlyBash Domain.fixture "bash loop.sh" == false
#guard isHumanOnlyBash Domain.fixture "bash ../myproj/init.sh" == false
#guard isHumanOnlyBash Domain.fixture "scripts/loopx.sh" == false
#guard isHumanOnlyBash Domain.fixture "claude_trust.py ensure" == true
#guard isHumanOnlyBash Domain.fixture "claude_trust.py status" == false
#guard isHumanOnlyBash Domain.fixture "looper trust ensure" == true
#guard isHumanOnlyBash Domain.fixture "bin/looper trust ensure" == true
#guard isHumanOnlyBash Domain.fixture "xlooper trust ensure" == false
#guard isHumanOnlyBash Domain.fixture "looper trust status" == true
#guard isHumanOnlyBash Domain.fixture "just doctor" == true
#guard isHumanOnlyBash Domain.fixture "scripts/doctor.sh" == true
#guard isHumanOnlyBash Domain.fixture "just supervise" == true
#guard isHumanOnlyBash Domain.fixture "just loop" == true
#guard isHumanOnlyBash Domain.fixture "just once" == true
#guard isHumanOnlyBash Domain.fixture "just init" == true
-- graceful drain(§19.1-7)は loop ライフサイクル面: `just stop` と
-- `<tool>-stop.sh` は human-only。ただし state 述語の読み取り
-- (`should-stop`、G-008 の triage allow 面を含む)は侵食しない —
-- `stop` の代替は `\bjust\s+…stop\b` の位置でしか照合せず、
-- `<tool>-stop.sh` は基底名の部分文字列照合だからである。
#guard isHumanOnlyBash Domain.fixture "just stop" == true
#guard isHumanOnlyBash Domain.fixture "just --unstable stop" == true
#guard isHumanOnlyBash Domain.fixture "just stop --cancel" == true
#guard isHumanOnlyBash Domain.fixture "just stopx" == false
#guard isHumanOnlyBash Domain.fixture "scripts/stop.sh" == true
#guard isHumanOnlyBash Domain.fixture "bash scripts/stop.sh --project ../x --cancel" == true
#guard isHumanOnlyBash Domain.fixture "bin/looper state should-stop --project ../x" == false
#guard isHumanOnlyBash Domain.fixture "just state should-stop" == false
#guard isHumanOnlyBash Domain.fixture "scripts/status.sh" == false
-- 常駐監視 TUI(§15.3)は human-only: `just watch` / `scripts/watch.sh` は
-- deny。単発描画の読み取り面 `state watch-render` は非侵食(D1)。
#guard isHumanOnlyBash Domain.fixture "just watch" == true
#guard isHumanOnlyBash Domain.fixture "just --unstable watch" == true
#guard isHumanOnlyBash Domain.fixture "just watchx" == false
#guard isHumanOnlyBash Domain.fixture "scripts/watch.sh" == true
#guard isHumanOnlyBash Domain.fixture "bash scripts/watch.sh --project ../x" == true
#guard isHumanOnlyBash Domain.fixture "scripts/watchx.sh" == false
#guard isHumanOnlyBash Domain.fixture "bin/looper state watch-render --project ../x" == false
#guard isHumanOnlyBash Domain.fixture "just state watch-render" == false
#guard isHumanOnlyBash Domain.fixture "claude-trust.sh" == true
#guard isHumanOnlyBash Domain.fixture "state.py resume" == true
#guard isHumanOnlyBash Domain.fixture "state.py resumex" == false
#guard isHumanOnlyBash Domain.fixture "looper state resume" == true
#guard isHumanOnlyBash Domain.fixture "bin/looper state resume" == true
#guard isHumanOnlyBash Domain.fixture "./bin/looper state resume --project ../p" == true
#guard isHumanOnlyBash Domain.fixture "xlooper state resume" == false
#guard isHumanOnlyBash Domain.fixture "looper state resumex" == false
#guard isHumanOnlyBash Domain.fixture "looper state validate" == false
#guard isHumanOnlyBash Domain.fixture "just --flag= resume" == true
#guard isHumanOnlyBash Domain.fixture "just ---x resume" == true
#guard isHumanOnlyBash Domain.fixture "state.py\tresume" == true
-- 方言差(頭注): Python は false(§ は \w 外でフラグ反復が壊れる)、Lean は true(deny 拡大)
#guard isHumanOnlyBash Domain.fixture "just --flag§ resume" == true

-- isLoopOnlyBash
#guard isLoopOnlyBash Domain.fixture "state.py start-run" == true
#guard isLoopOnlyBash Domain.fixture "state.py start-runx" == false
#guard isLoopOnlyBash Domain.fixture "just state end-run" == true
#guard isLoopOnlyBash Domain.fixture "just --unstable state record-progress" == true
#guard isLoopOnlyBash Domain.fixture "state.py resume" == false
#guard isLoopOnlyBash Domain.fixture "scripts/state.py raise-loop-gates --project x" == true
#guard isLoopOnlyBash Domain.fixture "state.py  reset-context" == true
#guard isLoopOnlyBash Domain.fixture "just state start-run" == true
#guard isLoopOnlyBash Domain.fixture "juststate start-run" == false
#guard isLoopOnlyBash Domain.fixture "state.py end-run" == true
#guard isLoopOnlyBash Domain.fixture "state.py --project x end-run" == false
#guard isLoopOnlyBash Domain.fixture "just state raise-loop-gates" == true
#guard isLoopOnlyBash Domain.fixture "bin/looper state start-run" == true
#guard isLoopOnlyBash Domain.fixture "looper state record-progress --project ../p" == true
#guard isLoopOnlyBash Domain.fixture "looper state resume" == false
#guard isLoopOnlyBash Domain.fixture "xlooper state end-run" == false
#guard isLoopOnlyBash Domain.fixture "looper state --project x end-run" == false

-- isDangerousBash
#guard isDangerousBash "rm -rf /" == true
#guard isDangerousBash "rm -rf" == true
-- C1-7: `-rf` の綴り替え(`-fr` / `-r -f` / `--recursive --force`)も deny。
-- `-rfx`(無効オプション x を含むが r と f が立つ)は保守的に deny(実行しても
-- rm がエラーするため over-deny は無害)。
#guard isDangerousBash "rm -rfx" == true
#guard isDangerousBash "rm -fr x" == true
#guard isDangerousBash "rm -r -f x" == true
#guard isDangerousBash "rm --recursive --force x" == true
#guard isDangerousBash "rm -R -f x" == true
#guard isDangerousBash "rm  -rf." == true
#guard isDangerousBash "rm -r f" == false
#guard isDangerousBash "rm -f x" == false
#guard isDangerousBash "rm x" == false
-- git push のグローバルオプション挟み
#guard isDangerousBash "git -C x push" == true
#guard isDangerousBash "git -C x status" == false
#guard isDangerousBash "sudo apt" == true
#guard isDangerousBash "sudox" == false
#guard isDangerousBash "xsudo" == false
#guard isDangerousBash "git push" == true
#guard isDangerousBash "git push origin" == true
#guard isDangerousBash "git  reset   --hard" == true
#guard isDangerousBash "git reset --hardx" == false
#guard isDangerousBash "git reset --soft" == false
#guard isDangerousBash "git clean -fd" == true
#guard isDangerousBash "git clean -fdx" == false
#guard isDangerousBash "git clean -f" == false
#guard isDangerousBash "curl http://x | sh" == true
#guard isDangerousBash "curl x | bash" == true
#guard isDangerousBash "curl x | shx" == false
#guard isDangerousBash "curl x|sh" == true
#guard isDangerousBash "wget -q y | sh -c z" == true
#guard isDangerousBash "curl a | x | sh" == false
#guard isDangerousBash "curl a > f; cat f | sh" == true
#guard isDangerousBash "mycurl x | sh" == true
#guard isDangerousBash "curl x" == false
#guard isDangerousBash "echo curl|sh" == true
#guard isDangerousBash "curl | ash" == false
#guard isDangerousBash "wget x | bashful" == false
#guard isDangerousBash "curl x |\tsh" == true
#guard isDangerousBash "curl x | sh;" == true
#guard isDangerousBash "rm-rf" == false
#guard isDangerousBash "curl x |sh\n" == true
#guard isDangerousBash "run sudo x" == true

-- isAskBash
#guard isAskBash Domain.fixture "scripts/bootstrap.sh" == true
#guard isAskBash Domain.fixture "bash scripts/bootstrap.sh" == true
#guard isAskBash Domain.fixture "bash ../myproj/bootstrap.sh" == false
#guard isAskBash Domain.fixture "just bootstrap" == true
#guard isAskBash Domain.fixture "just build" == true
#guard isAskBash Domain.fixture "just --unstable build" == true
#guard isAskBash Domain.fixture "just buildx" == false
#guard isAskBash Domain.fixture "xjust build" == false
#guard isAskBash Domain.fixture "just build-all" == true
#guard isAskBash Domain.fixture "just rebuild" == false
#guard isAskBash Domain.fixture "bootstrap" == false

-- hasWriteRedirectOrMutator
#guard hasWriteRedirectOrMutator "echo hi > f" == true
#guard hasWriteRedirectOrMutator "echo" == false
#guard hasWriteRedirectOrMutator "a>>b" == true
#guard hasWriteRedirectOrMutator "2> e" == true
#guard hasWriteRedirectOrMutator "&> f" == true
#guard hasWriteRedirectOrMutator "x &>> f" == true
#guard hasWriteRedirectOrMutator "sed -i s/a/b/ f" == true
#guard hasWriteRedirectOrMutator "sed -in" == false
#guard hasWriteRedirectOrMutator "sed -i.bak" == true
#guard hasWriteRedirectOrMutator "sed -i''" == true
#guard hasWriteRedirectOrMutator "tee f" == true
#guard hasWriteRedirectOrMutator "steep f" == false
#guard hasWriteRedirectOrMutator "mv a b" == true
#guard hasWriteRedirectOrMutator "cp a b" == true
#guard hasWriteRedirectOrMutator "rm f" == true
#guard hasWriteRedirectOrMutator "arm f" == false
#guard hasWriteRedirectOrMutator "rm" == true
#guard hasWriteRedirectOrMutator "rmx" == false
#guard hasWriteRedirectOrMutator "form" == false
#guard hasWriteRedirectOrMutator "9>>" == true
#guard hasWriteRedirectOrMutator "a > b" == true
#guard hasWriteRedirectOrMutator "->" == true
#guard hasWriteRedirectOrMutator "cat < f" == false
#guard hasWriteRedirectOrMutator "a 12> b" == true
#guard hasWriteRedirectOrMutator "sed  -i x" == true

-- isProtectedWriteTarget
#guard isProtectedWriteTarget Domain.fixture "echo x > ESSENCE.md" == true
#guard isProtectedWriteTarget Domain.fixture "cat ESSENCE.md" == true
#guard isProtectedWriteTarget Domain.fixture "cp new.png essences/logo.png" == true
#guard isProtectedWriteTarget Domain.fixture "cat essences/logo.png" == true
#guard isProtectedWriteTarget Domain.fixture "essencesx" == false
#guard isProtectedWriteTarget Domain.fixture "ESSENCE.mdx" == true
#guard isProtectedWriteTarget Domain.fixture ".looper/state/x" == true
#guard isProtectedWriteTarget Domain.fixture "cat .env" == true
#guard isProtectedWriteTarget Domain.fixture "cat .envx" == false
#guard isProtectedWriteTarget Domain.fixture ".env.local" == true
#guard isProtectedWriteTarget Domain.fixture ".env" == true
#guard isProtectedWriteTarget Domain.fixture "x.env" == true

-- protectedPathWriteDeny(§11.3 のセグメント単位判定、2026-08-12)
-- (a) 同一セグメントの直書きは従来どおり deny
#guard protectedPathWriteDeny Domain.fixture "echo x > .looper/state/todo.json" == true
#guard protectedPathWriteDeny Domain.fixture "sed -i s/a/b/ .looper/state/todo.json" == true
#guard protectedPathWriteDeny Domain.fixture "cp new.md ESSENCE.md" == true
#guard protectedPathWriteDeny Domain.fixture "python3 -c \"open('.looper/state/todo.json','w')\""
  == true
#guard protectedPathWriteDeny Domain.fixture "cat x >> ../p/.looper/'state'/todo.json" == true
#guard protectedPathWriteDeny Domain.fixture "truncate -s 0 essences/logo.png" == true
-- (b) 誤拒否だった 2 形が通る(実走行 2026-08-12 の摩擦の実体)
#guard protectedPathWriteDeny Domain.fixture "cat .looper/state/todo.json | python3 -m json.tool"
  == false
#guard protectedPathWriteDeny Domain.fixture "grep install .looper/state/todo.json" == false
#guard protectedPathWriteDeny Domain.fixture "grep -n 'cp ' .looper/state/todo.json" == false
#guard protectedPathWriteDeny Domain.fixture "tail -n 5 .looper/state/reflection.jsonl" == false
#guard protectedPathWriteDeny Domain.fixture "jq . .looper/state/todo.json | head" == false
-- (c) セグメント跨ぎでもパスと writer が同居すれば deny のまま
#guard protectedPathWriteDeny Domain.fixture "ls; rm .looper/state/todo.json" == true
#guard protectedPathWriteDeny Domain.fixture "cat a | tee .looper/state/todo.json" == true
-- (d) fail-closed の逃げ道: パスがセグメント間を渡り得る形は全文連言へ戻る
#guard protectedPathWriteDeny Domain.fixture "ls .looper/state/ | xargs rm" == true
#guard protectedPathWriteDeny Domain.fixture "find .looper/state/ -name '*.json' -exec rm {} ;"
  == true
-- `-delete` は writer 語を 1 つも含まないので、逃げ道の側で明示的に数える
#guard protectedPathWriteDeny Domain.fixture "find .looper/state/ -name '*.json' -delete" == true
#guard protectedPathWriteDeny Domain.fixture "find build/ -name '*.json' -delete" == false
#guard protectedPathWriteDeny Domain.fixture "rm $(ls .looper/state/)" == true
#guard protectedPathWriteDeny Domain.fixture "eval \"rm .looper/state/todo.json\"" == true
-- (e) 保護パスを名指ししない writer は無関係
#guard protectedPathWriteDeny Domain.fixture "rm build/out.js" == false
#guard protectedPathWriteDeny Domain.fixture "echo hi" == false

-- segmentHasProtectedWriter: 位置の効き方
#guard segmentHasProtectedWriter "rm x" == true
#guard segmentHasProtectedWriter "env FOO=1 rm x" == true
#guard segmentHasProtectedWriter "sudo rm x" == true
#guard segmentHasProtectedWriter "/bin/rm x" == true
#guard segmentHasProtectedWriter "grep rm x" == false
#guard segmentHasProtectedWriter "cat x > y" == true
#guard segmentHasProtectedWriter "cat x" == false
-- 綴り替えバイパスの封鎖(§28.5-9): 大小文字 / 冗長スラッシュ(トークン normpath)
#guard isProtectedWriteTarget Domain.fixture "echo x > ESSENCE.MD" == true
#guard isProtectedWriteTarget Domain.fixture "cp a essence.md" == true
#guard isProtectedWriteTarget Domain.fixture "echo x > .looper//state/todo.json" == true
#guard isProtectedWriteTarget Domain.fixture "echo x > .looper/./state/todo.json" == true
#guard isProtectedWriteTarget Domain.fixture "cp x Essences/logo.png" == true
#guard isProtectedWriteTarget Domain.fixture "essencesx" == false
#guard isProtectedWriteTarget Domain.fixture "secrets/" == true
#guard isProtectedWriteTarget Domain.fixture "essence_attestations.jsonl" == true
#guard isProtectedWriteTarget Domain.fixture ".agent/state/" == true
#guard isProtectedWriteTarget Domain.fixture ".agent/statex" == false
#guard isProtectedWriteTarget Domain.fixture "cat .env\n" == true
#guard isProtectedWriteTarget Domain.fixture "echo .env | x" == true
#guard isProtectedWriteTarget Domain.fixture "ESSENCE_md" == false

-- isDependencyInputBashMutation
#guard isDependencyInputBashMutation "echo x > package.json" == true
#guard isDependencyInputBashMutation "cat package.json" == false
#guard isDependencyInputBashMutation "echo > mypackage.json" == true
#guard isDependencyInputBashMutation "rm go.sum" == true
#guard isDependencyInputBashMutation "rm go.sumx" == false
#guard isDependencyInputBashMutation "echo a > x; echo b > package.json" == true
#guard isDependencyInputBashMutation "echo package.json > log" == false
#guard isDependencyInputBashMutation "mv requirements-dev.txt bak" == true
#guard isDependencyInputBashMutation "echo x > lakefile.lean" == true
#guard isDependencyInputBashMutation "sed -i s/a/b/ lakefile.toml" == true
#guard isDependencyInputBashMutation "echo x > lake-manifest.json" == true
#guard isDependencyInputBashMutation "echo leanprover/lean4:v4.15.0 > lean-toolchain" == true
#guard isDependencyInputBashMutation "echo x > Pipfile" == true
#guard isDependencyInputBashMutation "echo x > bunfig.toml" == true
#guard isDependencyInputBashMutation "tee .cargo/config.toml" == true
#guard isDependencyInputBashMutation "cat lakefile.lean" == false
#guard isDependencyInputBashMutation "lake build" == false
#guard isDependencyInputBashMutation "tee uv.lock" == true
#guard isDependencyInputBashMutation "cp a bun.lockb" == true
#guard isDependencyInputBashMutation "cp a bun.lock" == true
#guard isDependencyInputBashMutation "cp a bun.lockbb" == false
#guard isDependencyInputBashMutation "sed -i x pyproject.toml" == true
#guard isDependencyInputBashMutation "echo > f.txt" == false
#guard isDependencyInputBashMutation "rm x; echo package.json" == false
#guard isDependencyInputBashMutation "echo x | tee .npmrc" == true
#guard isDependencyInputBashMutation "> yarn.lock" == true
#guard isDependencyInputBashMutation "echo hi > a && rm Cargo.toml" == true
#guard isDependencyInputBashMutation "rm x; echo b > requirements.txt" == true
#guard isDependencyInputBashMutation "tee .yarnrc.yml" == true
#guard isDependencyInputBashMutation "tee .yarnrc" == true
#guard isDependencyInputBashMutation "rm requirements..txt" == true
#guard isDependencyInputBashMutation "rm requirementsX.txt2" == false
#guard isDependencyInputBashMutation "rm Pipfile.lock" == true
#guard isDependencyInputBashMutation "echo >> .pnpmfile.cjs" == true
#guard isDependencyInputBashMutation "rm go.mod" == true

-- isControlSurfaceBashMutation
#guard isControlSurfaceBashMutation Domain.fixture "echo x > scripts/state.py" == true
#guard isControlSurfaceBashMutation Domain.fixture "rm scripts/foo" == true
#guard isControlSurfaceBashMutation Domain.fixture "python3 scripts/state.py validate > /dev/null" == false
#guard isControlSurfaceBashMutation Domain.fixture "echo > ./scripts/new.sh" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo > /x/scripts/foo" == false
#guard isControlSurfaceBashMutation Domain.fixture "mv templates/control/a b" == true
#guard isControlSurfaceBashMutation Domain.fixture "mv templates/other/a b" == false
#guard isControlSurfaceBashMutation Domain.fixture "rm recipes/x" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo > .agent/prompts/p" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo x >> META.md" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo >> META.mdx" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo > README.md" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo > README.mdx" == false
#guard isControlSurfaceBashMutation Domain.fixture "echo > ./README.md" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo > x/README.md" == false
#guard isControlSurfaceBashMutation Domain.fixture "echo > justfile" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo > justfilex" == false
#guard isControlSurfaceBashMutation Domain.fixture "echo > myjustfile" == true
#guard isControlSurfaceBashMutation Domain.fixture "rm scripts/looper-foo.sh" == true
#guard isControlSurfaceBashMutation Domain.fixture "rm scripts/looper-foo2.sh" == true
#guard isControlSurfaceBashMutation Domain.fixture "rm scripts/claude-trust.py" == true
#guard isControlSurfaceBashMutation Domain.fixture "rm scripts/claude_trust.sh" == true
#guard isControlSurfaceBashMutation Domain.fixture "cat scripts/state.py" == false
#guard isControlSurfaceBashMutation Domain.fixture "cat scripts/state.py > /tmp/x" == false
#guard isControlSurfaceBashMutation Domain.fixture "rm x; echo > scripts/a" == true
#guard isControlSurfaceBashMutation Domain.fixture "echo > \"scripts/x\"" == true
#guard isControlSurfaceBashMutation Domain.fixture "tee scripts/_lib.sh" == true
#guard isControlSurfaceBashMutation Domain.fixture "rm 'recipes/y'" == true

-- isZoneBashMutation
#guard isZoneBashMutation "echo x > CLAUDE.md" == true
#guard isZoneBashMutation "echo x >CLAUDE.md" == false
#guard isZoneBashMutation "cat CLAUDE.md" == false
#guard isZoneBashMutation "echo > .claude/settings.json" == true
#guard isZoneBashMutation "rm -r x/.claude/y" == true
#guard isZoneBashMutation "echo > prompts/p" == true
#guard isZoneBashMutation "echo > myprompts/p" == false
#guard isZoneBashMutation "mv a agents/b" == true
#guard isZoneBashMutation "rm hooks/h" == true
#guard isZoneBashMutation "echo >> .github/workflows/ci.yml" == true
#guard isZoneBashMutation "echo > x.github/workflows/" == true
#guard isZoneBashMutation "rm scripts/myagent.sh" == true
#guard isZoneBashMutation "rm scripts/sub/agent" == true
#guard isZoneBashMutation "echo > settings.json" == true
#guard isZoneBashMutation "rm x/settings.json" == true
#guard isZoneBashMutation "rm xsettings.json" == false
#guard isZoneBashMutation "sed -i s/x/y/ AGENTS.md" == true
#guard isZoneBashMutation "tee .mcp.json" == true
#guard isZoneBashMutation "> agent-runtime/x" == true
#guard isZoneBashMutation "rm x/.cursor/rules" == true
#guard isZoneBashMutation "echo > skills/s" == true
#guard isZoneBashMutation "echo > CLAUDE.mdx" == false
#guard isZoneBashMutation "rm scripts/autonomous-x" == true
#guard isZoneBashMutation "rm scripts/x" == false
#guard isZoneBashMutation "echo hi > 'CLAUDE.md'" == true
#guard isZoneBashMutation "echo hi >= CLAUDE.md" == true

-- mutatesLiteralTarget
#guard mutatesLiteralTarget "CLAUDE.md" "echo hi > CLAUDE.md" == true
#guard mutatesLiteralTarget "CLAUDE.md" "cat CLAUDE.md" == false
#guard mutatesLiteralTarget "a.b" "rm x; echo a.b" == false
#guard mutatesLiteralTarget "a.b" "rm a.b" == true
#guard mutatesLiteralTarget "x" "echo > yxz" == true
#guard mutatesLiteralTarget "f" "tee f" == true
#guard mutatesLiteralTarget "f" "f > g" == false

-- bashPathishTokens
#guard bashPathishTokens "echo hi > .claude/settings.json 2>err"
  == [".claude/settings.json", "2", "echo", "err", "hi"]
#guard bashPathishTokens "mv a~b @scope/pkg" == ["@scope/pkg", "a~b", "mv"]
#guard bashPathishTokens "rm a a" == ["a", "rm"]
#guard bashPathishTokens "x; y | z" == ["x", "y", "z"]
#guard bashPathishTokens "curl -o f.tgz http://e.com/p"
  == ["-o", "//e.com/p", "curl", "f.tgz", "http"]

end Looper.Core.Classify
