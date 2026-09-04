import Looper.Guard.Types
import Looper.Guard.Rules
import Looper.Core.Classify
import Looper.Core.Classify.Bash
import Looper.Core.Classify.Install
import Looper.Core.Classify.ReadOnly
import Looper.Core.GlobHier
import Looper.Hook.PostTool

/-!
`Looper.Guard.Decide` — PreToolUse guard の純粋決定核(META.md §16・§23、
§31.2-19)。

移行元: `.claude/hooks/pre_tool_guard.py` の `main()` と、そこからしか呼ばれ
ない判定補助(`path_candidates` / `bash_high_risk_targets` / `cd_targets` /
`cd_leaves_allowed_roots` / `install_allow_reason` の cd フェンス /
`read_only_session_bash_allow` の解決依存部)。分類プリミティブは
`Core.Classify` 4 部の単一定義をそのまま使う。

**決定木の順序が安全性の核**(G-T1 の対象): deny 群(保護パス書き込み →
secret → git stage/commit → human-only → loop-only → DANGEROUS_BASH →
Claude ネスト起動 → 制御プレーン面)が全 ask/allow に先行し、ask 化への
降格が起きない。この順序は Python `main()` の逐次 `decision()` と 1:1 で、
変更はシャドー検証の裁定事項。

**PostTool との共有定義**: パス表記代数(`pyPathStr` / `childPath` /
`relativeTo?`)と Bash 変異ターゲット抽出(`bashCandidateTokens`)は
`Hook.PostTool` 純粋核から import する。post の分類が pre の部分集合で
あること(D-002、将来の `theorem post_subset_pre`)は同一定義の共有で構成的に
成立する。`Hook.PostTool` は純粋名前空間であり、この import は IO への依存
ではない(純度ゲート対象内)。

**IO シェルの契約**(3 手、§31.4-3): (1) stdin JSON と環境・プロジェクト
インデックス・ESSENCE を読み、`familyARequests` / `familyBRequests` のキーを
解決して `GuardEnv` を組む → (2) `decide` を呼ぶ → (3) `highRiskPre` を
`record_high_risk_pre` 相当で stage し(best-effort、失敗は stderr)、
`decision?` を stdout へ出して exit 0。
-/

namespace Looper.Guard

open Looper.Core.Classify
open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (isPySpace pyStrip)
open Looper.Hook.PostTool (pyPathStr childPath relativeTo? bashCandidateTokens)
open Rules

/-! ## 解決表の適用(`resolve_target` / read-only 結合規約の純粋側) -/

/-- `resolve_target(raw, cwd)` の純粋側: 絶対・相対どちらも family A の解決
結果(`.resolve()`)を使う。絶対綴りだけを未解決のまま通すと `..` 成分が残り、
`insideOf` の成分 prefix 判定が `/root/x/../..` を「root の内側」と読む —
それが cd フェンス(§11.2)と control-plane 分類(§11.3)を綴り 1 つで抜ける
fail-open になっていた。解決不能(cwd 不明・NUL)のときだけ従来どおり表記
正規化へ落ちる(候補を減らさないための fail-safe)。 -/
def GuardEnv.resolveTarget? (env : GuardEnv) (raw : String) : Option String :=
  if raw.startsWith "/" then some ((env.resolved? raw).getD (pyPathStr raw))
  else env.resolved? raw

/-- read-only 面の結合キー: `Path(raw)` が絶対ならそのまま、相対なら
`base / raw`(family B は絶対キーも**解決する** — `resolve_target` との差)。 -/
def GuardEnv.handoffKey (env : GuardEnv) (raw : String) : String :=
  if raw.startsWith "/" then raw else childPath env.base raw

/-- `_inside(path, root)` 等価(両辺とも表記正規化済み前提の成分比較)。 -/
def insideOf (root path : String) : Bool :=
  (relativeTo? root path).isSome

/-! ## path_candidates(pre 版 — 登録プロジェクトルート列を使う) -/

/-- `path_candidates(raw, cwd)` 等価。判定(`any`)にのみ使うため set の
順序・重複除去は再現しない。解決失敗(try/except)は生表記の候補のみ。 -/
def pathCandidates (env : GuardEnv) (raw : String) : List String :=
  if raw.isEmpty then []
  else
    ((pyPathStr raw).replace "\\" "/")
      :: match env.resolveTarget? raw with
         | none => []
         | some resolved =>
           (resolved.replace "\\" "/")
             :: (env.projectRoots.filterMap fun root => relativeTo? root resolved)
             ++ (relativeTo? env.controlRoot resolved).toList

/-- §11.6(I-007)の read-only 対象判定: 解決済みターゲットが登録 project
root の内側にあり、その相対パスがドメインの既定許可面
(`Domain.allowsWriteRel` — §11.1。canonical state の規律は別レイヤが担う)
にも `writable:` 許可集合にも入らないとき true。project 外・解決不能は対象外
(false — 他ルールに委ねる)。

**この段はどのドメインでも決定木に存在する**(K-1)。対象実装が Agent の
作業面であるドメイン(`WritePolicy.implementation`)では
`Domain.allowsWriteRel` が常に真になり、段は通過するだけになる — 「段が
無い」のではなく「発火しない」のである。 -/
def isReadOnlyTargetRel (env : GuardEnv) (rel : String) : Bool :=
  !(env.domain.allowsWriteRel rel
    || Core.GlobHier.grantAccepts env.writablePatterns rel)

/-- WRITE_TOOLS 面の read-only 判定(解決済みパスで判定 — §11.6-4)。 -/
def isReadOnlyTargetWrite (env : GuardEnv) (targetRaw : String) : Bool :=
  match env.resolveTarget? targetRaw with
  | none => false
  | some resolved =>
    match env.projectRoots.firstM (fun root => relativeTo? root resolved) with
    | some rel => isReadOnlyTargetRel env rel
    | none => false

/-- Bash mutator 面の read-only 対象抽出: mutator 後方の pathish トークン
(`bashCandidateTokens` — zone staging と同じ保守的近似)のうち、登録
project root 内側の read-only 対象へ解決されるものの解決済みパス列。 -/
def bashReadOnlyTargets (env : GuardEnv) (command : String) : List String :=
  (bashCandidateTokens command).filterMap fun tok =>
    (env.resolveTarget? tok).bind fun resolved =>
      match env.projectRoots.firstM (fun root => relativeTo? root resolved) with
      | some rel => if isReadOnlyTargetRel env rel then some resolved else none
      | none => none

/-- 解決済みターゲットの制御プレーン面判定(CONTROL_ROOT 相対のみ、§11.3)。 -/
def isControlPlaneTarget (env : GuardEnv) (resolved : String) : Bool :=
  match relativeTo? env.controlRoot resolved with
  | some rel => isControlPlaneHighRisk rel
  | none => false

/-! ## bash_high_risk_targets(§20.4-3 の staging 対象抽出) -/

/-- `bash_high_risk_targets(command, cwd)` 等価: mutator の後方にリテラル出現
する pathish トークン(`bashCandidateTokens` — post と共有)を解決し、制御
プレーン面(§11.3)か High-Risk Zone(§12)に載る解決済みパスの列。解決不能
トークンはスキップ(ask ゲート自体はこの抽出に依存しない)。 -/
def bashHighRiskTargets (env : GuardEnv) (command : String) : List String :=
  (bashCandidateTokens command).filterMap fun tok =>
    match env.resolveTarget? tok with
    | none => none
    | some resolved =>
      if isControlPlaneTarget env resolved
          || (pathCandidates env tok).any isHighRiskPath then
        some resolved
      else none

/-! ## cd_targets / cd_leaves_allowed_roots(§11.2 の cd フェンス) -/

private def isCdSep (c : Char) : Bool :=
  c == ';' || c == '&' || c == '|' || c == '\n'

/-- セグメント頭での `cd\s+([^;&|\n]+)` 照合。成功時は (捕獲生文字列, 残り)。 -/
private def cdAt? (cs : List Char) : Option (String × List Char) := do
  let r ← dropLit? cs "cd".toList
  let r' := r.dropWhile isPySpace
  if r.length == r'.length then none  -- `\s+` は 1 文字以上
  else
    let content := r'.takeWhile fun c => !isCdSep c
    if content.isEmpty then none
    else some (String.ofList content, r'.drop content.length)

/-- `[;&|\n]\s*` 先行の代替を左から走査(finditer の非重複再開位置 = 捕獲
直後)。fuel は毎歩 1 文字以上進むため入力長で足りる。 -/
private def cdScan : Nat → List Char → List String
  | 0, _ => []
  | _, [] => []
  | fuel + 1, c :: rest =>
    if isCdSep c then
      match cdAt? (rest.dropWhile isPySpace) with
      | some (raw, after) => raw :: cdScan fuel after
      | none => cdScan fuel rest
    else cdScan fuel rest

/-- `re.finditer(r"(^|[;&|\n]\s*)cd\s+([^;&|\n]+)", command)` の捕獲列。
`^` 代替は位置 0 の `cd` 直置きのみ(MULTILINE なし・`\s*` なし — 行頭の
`\n` は separator クラスが受ける)。 -/
def cdRawCaptures (command : String) : List String :=
  let cs := command.toList
  match cdAt? cs with
  | some (raw, after) => raw :: cdScan (cs.length + 1) after
  | none => cdScan (cs.length + 1) cs

/-- 各捕獲の strip → shlex → 先頭トークン(`ValueError` / 空 argv はスキップ)。
family A の解決要求キーでもある。 -/
def cdFirstTokens (command : String) : List String :=
  (cdRawCaptures command).filterMap fun rawCap =>
    match Looper.Core.ShellLex.split (pyStrip rawCap) with
    | .ok (first :: _) => some first
    | _ => none

/-- `cd_targets(command, cwd)` 等価: 綴りによらず解決結果を使う(失敗時は生
綴りを保持 — 許可ルートに一致せず ask 側へ落ちる fail-safe)。**`~` 始まりと
shell 展開(`$`)を含む綴りは解決結果を使わない**: 解決表は字句解決
(cwd 相対)であり、shell が実際に向かう home / 変数先とは別の場所を指す —
`cd ~ && …` が「cwd/~ は許可ルート内」としてフェンスを素通りしていた。生綴り
のまま残せば許可ルートに一致せず ask 側へ落ちる(同じ fail-safe)。 -/
def cdTargets (env : GuardEnv) (command : String) : List String :=
  (cdFirstTokens command).map fun first =>
    if first.startsWith "~" || (first.toList.contains '$') then pyPathStr first
    else (env.resolved? first).getD (pyPathStr first)

/-- `cd_leaves_allowed_roots(command, cwd)` 等価: 許可ルート(CONTROL_ROOT ∪
登録 PROJECT_ROOT)の外へ出る最初の cd 先。 -/
def cdLeavesAllowedRoots? (env : GuardEnv) (command : String) : Option String :=
  let roots := env.controlRoot :: env.projectRoots
  (cdTargets env command).find? fun target =>
    !(roots.any fun root => insideOf root target)

/-! ## install_allow_reason(§11.2 依存ゲートの allow 面) -/

/-- `install_allow_reason(command, cwd)` 等価: 形状判定と 1 セグメント判定は
`Core.Classify.Install`、`cd <dir> &&` 前置の許可ルート照合(綴りによらず解決
必須 — この allow が hook の唯一の自動許可面なので、解決できない cd 先は
許可ルート内と認めない)のみここで行う。 -/
def installAllowReason? (env : GuardEnv) (command : String) : Option String :=
  match installGateShape command with
  | .notGate => none
  | .bare seg => installAllowSegReason? env.domain env.declared seg
  | .withCd cdRaw seg =>
    -- `~` / `$` 綴りの cd 先は字句解決が実際の行き先を表さない(`cdTargets` の
    -- 頭注)。唯一の自動許可面なので、解決を信用できない綴りは許可しない。
    if cdRaw.startsWith "~" || cdRaw.toList.contains '$' then none else
    match env.resolved? cdRaw with
    | none => none
    | some p =>
      if (env.controlRoot :: env.projectRoots).any fun root => insideOf root p then
        installAllowSegReason? env.domain env.declared seg
      else none

/-! ## read_only_session_bash_allow(I-022/I-027) -/

/-- `resolves_into_handoff(raw, strict_inside)` 等価。 -/
def resolvesIntoHandoff (env : GuardEnv) (raw : String)
    (strictInside : Bool) : Bool :=
  match env.resolved? (env.handoffKey raw) with
  | none => false
  | some resolved =>
    if strictInside && resolved == env.handoffRoot then false
    else insideOf env.handoffRoot resolved

/-- read-only セッションの live settings 修復 ask 面(§28.5-3): 書き込み先が
`CONTROL_ROOT/.claude/settings.json` の解決済みパスへ一致するか。 -/
def resolvesToLiveSettings (env : GuardEnv) (raw : String) : Bool :=
  env.settingsFile != ""
    && env.resolved? (env.handoffKey raw) == some env.settingsFile

/-- essence(new)セッションの ESSENCE.md 直接設置 fallback(I-027 第二経路)の
照合先: `expectedProject?/ESSENCE.md`。new モード以外・対象未解決は none。 -/
def essenceInstallTarget? (env : GuardEnv) : Option String :=
  if env.sessionMode == "essence" && env.essenceMode == "new" then
    env.expectedProject?.map (childPath · "ESSENCE.md")
  else none

/-- 書き込み先が essence-new の ESSENCE.md fallback 面へ解決されるか。 -/
def resolvesToEssenceInstall (env : GuardEnv) (raw : String) : Bool :=
  match essenceInstallTarget? env with
  | some target => env.resolved? (env.handoffKey raw) == some target
  | none => false

/-- essence(new)セッションの essences/ 資産設置面(I-027 第二経路の §2.1.5
面)の照合ルート: `expectedProject?/essences`。new モード以外・対象未解決は
none。 -/
def essenceAssetInstallRoot? (env : GuardEnv) : Option String :=
  if env.sessionMode == "essence" && env.essenceMode == "new" then
    env.expectedProject?.map (childPath · "essences")
  else none

/-- 書き込み先が essence-new の essences/ 資産面へ解決されるか。root からの
相対パスが `Essence.validAssetPath`(1..3 セグメント・各セグメントが許容名)を
満たすときのみ成立 — root 自身(`"."`)・上限より深いパス・不正名は不成立
であり、§2.1.5 の階層制約を設置面でも守る。 -/
def resolvesToEssenceAssetInstall (env : GuardEnv) (raw : String) : Bool :=
  match essenceAssetInstallRoot? env with
  | some root =>
    match env.resolved? (env.handoffKey raw) with
    | some resolved =>
      match relativeTo? root resolved with
      | some rel => Looper.Core.Essence.validAssetPath rel
      | none => false
    | none => false
  | none => false

/-- `read_only_session_bash_allow(command, mode, cwd)` 等価(mode は
`env.sessionMode`)。heredoc → (シェルメタなしの)mkdir -p → triage 限定の
state 読み取り、の順で allow 理由を探す。 -/
def readOnlySessionBashAllow? (env : GuardEnv) (command : String) :
    Option String :=
  let heredoc? :=
    match heredocForm? command with
    | some form =>
      if (form.mkdirRaw.all fun r => resolvesIntoHandoff env r false)
          && resolvesIntoHandoff env form.targetRaw true then
        some (handoffWriteReason env.sessionMode)
      else none
    | none => none
  heredoc? <|>
    if hasReadOnlyShellMeta command then none
    else match strictArgv? command with
    | none => none
    | some argv =>
      let mkdir? :=
        match mkdirHandoffArg? argv with
        | some p =>
          if resolvesIntoHandoff env p false then
            some (handoffMkdirReason env.sessionMode)
          else none
        | none => none
      mkdir? <|>
        if env.sessionMode != "triage" then none
        else match env.expectedProject?, triageStateShape? argv with
        | some expected, some (scriptRaw, projRaw) =>
          if env.resolved? (env.handoffKey scriptRaw) == some env.stateScript
              && env.resolved? (env.handoffKey projRaw) == some expected
              && triageStateSubcommandsOk env.domain command then
            some (stateInspectionReason env.sessionMode)
          else none
        | _, _ => none

/-! ## 解決要求の列挙(IO シェルが GuardEnv.resolved を組むための純粋仕様) -/

/-- family A(`(cwd or ".") / key` 結合): write ターゲット(空文字列含む —
Python は `(cwd/"").resolve()` を計算する)、Bash 変異ターゲット候補、cd 先頭
トークン、install cd 前置。絶対キーも列挙する — 結合は絶対側を優先するので
`.resolve()` そのものになり、`..` 成分が畳まれた位置で判定できる。重複キーは
IO 側で自然に単一化してよい(lookup は先頭一致)。 -/
def familyARequests : ToolCall → List String
  | .write targetRaw => [targetRaw]
  | .bash command =>
    bashCandidateTokens command
      ++ cdFirstTokens command
      ++ match installGateShape command with
         | .withCd cdRaw _ => [cdRaw]
         | _ => []
  | .other => []

/-- family B(read-only セッション面の結合済みキー — 絶対キーも解決する)。
`base` / `sessionMode` は `GuardEnv` と同じ値を渡す。WRITE_TOOLS は read-only
セッションのときだけ handoff 内包判定用にターゲットの結合キーを要求する
(§13.6-3 の Write 面)。 -/
def familyBRequests (base sessionMode : String) : ToolCall → List String
  | .bash command =>
    if sessionMode == "triage" || sessionMode == "essence" then
      let key (raw : String) : String :=
        if raw.startsWith "/" then raw else childPath base raw
      (match heredocForm? command with
       | some form => (form.mkdirRaw.toList ++ [form.targetRaw]).map key
       | none => [])
        ++ if hasReadOnlyShellMeta command then []
           else match strictArgv? command with
           | none => []
           | some argv =>
             (match mkdirHandoffArg? argv with
              | some p => [key p]
              | none => [])
               ++ if sessionMode == "triage" then
                    match triageStateShape? argv with
                    | some (scriptRaw, projRaw) => [key scriptRaw, key projRaw]
                    | none => []
                  else []
    else []
  | .write targetRaw =>
    if sessionMode == "triage" || sessionMode == "essence" then
      [if targetRaw.startsWith "/" then targetRaw else childPath base targetRaw]
    else []
  | .other => []

/-! ## 決定木 -/

private def decided (staged : List String) (p : Permission) (reason : String) :
    GuardOutput :=
  ⟨staged, some ⟨p, reason⟩⟩

/-- relaxed profile(§11.5)による ask 緩和 6 葉の共通形: standard は従来
どおり ask、relaxed(auto-approve / unsandboxed — guard は両者を区別しない、
§11.5)は監査可能な理由文言で allow。葉ごとに条件を書き分けるとバグ混入
クラス(片葉だけ条件が逆・staging が落ちる等)が生まれるため、置換はこの
1 関数に集約する。staging(`staged`)は profile によらず同一に渡る
(§20.4-3 の before-hash 対合は profile 不変 — G-T6)。decision? が定義的に
`some` になる形(profile 分岐を Decision 側に置く)なので、G-T4/G-T5 の
isSome 証明は分岐追加なしに閉じる。G-T6(`profile_only_relaxes`)が展開する
ため private にしない。 -/
def askUnlessRelaxed (staged : List String) (profile : Profile)
    (askReason surface : String) : GuardOutput :=
  ⟨staged,
   some (if profile == .standard then ⟨.ask, askReason⟩
         else ⟨.allow, profileAllowReason surface⟩)⟩

/-- WRITE_TOOLS 経路。read-only セッション(I-022/I-027)は Bash 面
(`decideBash`)と対称に**最上段**で分岐し、handoff root の内側へ解決される
書き込みだけを allow、ask 面 3 種 — live settings 修復
(`resolvesToLiveSettings`、§28.5-3)、essence-new の ESSENCE.md 直接設置
fallback(`resolvesToEssenceInstall`、I-027 第二経路)、essence-new の
essences/ 資産設置(`resolvesToEssenceAssetInstall`、同経路の §2.1.5 面)—
を ask、それ以外は
教示付き deny にする(限定許可 + 既定拒否。§13.6-3/§2.1.4-2 — Write ツールが
handoff の第一の出口。ask 面の完全列挙は G-T2 write 面)。staging なし:
handoff は wrapper が消す一時領域で High-Risk 記録対象でなく、post 側の
監査 hook も read-only セッションでは無条件に無作用(§20.4)。

通常セッションは deny(DENY_PATTERNS)→ high-risk 分類と staging →
deny(制御プレーン面)→ ask(マニフェスト)→ ask(High-Risk Zone)。
high-risk 分類が ask 群に**先行**するのは、ask 理由が別ルール由来でも
before-hash を stage するため(§20.4-3。Python の実順序)。

制御プレーン面の deny がマニフェスト ask に**先行**するのは §11.3 の
「bound Agent session では常時 deny」を Edit 経路でも保つためである。両者は
実際に重なる — 配布物の `recipes/agentic-state-loop/files/loop/lean/`
(`lakefile.lean` / `lean-toolchain` / `lake-manifest.json`)がその実例であり、
旧順序ではレシピ原本(§29.2 の immutable surface)への Edit が ask へ降格し、
同じ対象を Bash mutator で触ったときの deny(`decideBash` は controlSurface が
先)と食い違っていた。deny 群が ask 群に先行するという決定木の順序不変量
(頭注・G-T1)を Bash 面と揃える。ask→deny は R-6 の「deny 拡大方向」。

profile は `decideWrite` が `env.profile` を渡す明示引数である(`decideBashWith`
と同じ構図): 決定木本体が env の profile フィールドを参照しない形に
しておくと、「profile だけを入れ替えた 2 つの判定」の比較(G-T6)が同一 env
上の純粋な引数差になり、証明が決定木の場合分けだけで閉じる。 -/
def decideWriteWith (profile : Profile) (env : GuardEnv)
    (targetRaw : String) : GuardOutput :=
  if env.sessionMode == "triage" || env.sessionMode == "essence" then
    if resolvesIntoHandoff env targetRaw true then
      decided [] .allow (handoffWriteReason env.sessionMode)
    else if resolvesToLiveSettings env targetRaw then
      decided [] .ask (liveSettingsAskReason env.sessionMode)
    else if resolvesToEssenceInstall env targetRaw then
      decided [] .ask essenceDirectInstallAskReason
    else if resolvesToEssenceAssetInstall env targetRaw then
      decided [] .ask essenceAssetInstallAskReason
    else
      let handoffDir := childPath env.controlRoot (".agent/tmp/" ++ env.sessionMode)
      decided [] .deny (readOnlyWriteDenyReason env.sessionMode handoffDir
        (env.sessionMode == "essence" && env.essenceMode == "new"))
  else
    let candidates := pathCandidates env targetRaw
    if candidates.any (isDenyPath env.domain) then
      decided [] .deny (writeDenyReason env.domain env.domain.projectionLedgers targetRaw)
    else
      -- match でなく Option 演算で書く: matcher 補助定義を挟まない形は
      -- 証明側(G-T5/G-T6)が Bool 式そのものの場合分けで扱える。
      let controlHighRisk :=
        ((env.resolveTarget? targetRaw).map (isControlPlaneTarget env)).getD false
      let zoneHighRisk := candidates.any isHighRiskPath
      let staged := if zoneHighRisk && !controlHighRisk then [targetRaw] else []
      if controlHighRisk then
        decided staged .deny (controlPlaneDenyReason env.domain targetRaw)
      -- §11.6(I-007): 対象実装は既定 read-only。既定許可面(proofs/** と
      -- .looper/** — §11.1)にも writable: 許可集合にも入らない対象パスは、
      -- ask 群(マニフェスト / zone)へ降りる前に教示つき deny — 許可の無い
      -- 対象では依存決定も High-Risk 適用もそもそも起こらない(§11.6-3 の
      -- 直交は writable 許可範囲の内側でだけ意味を持つ)
      else if isReadOnlyTargetWrite env targetRaw then
        decided staged .deny (readOnlyTargetDenyReason targetRaw)
      else if candidates.any isAskPath then
        askUnlessRelaxed staged profile (manifestAskReason targetRaw)
          "dependency-manifest edit (§11.2)"
      else if zoneHighRisk then
        askUnlessRelaxed staged profile (zoneAskReason targetRaw)
          "High-Risk Zone edit (§12)"
      else
        -- Write 無意見葉は relaxed でも緩めない(§11.5): sandbox は Edit/Write
        -- ツールを縛らないため、ここを allow にすると additionalDirectories 外
        -- (`~/.zshrc` 等)への Edit が promptless になり「sandbox 維持」の宣言
        -- と矛盾する。project 内 write は settings の allow が既に promptless。
        ⟨staged, none⟩

/-- WRITE_TOOLS 経路(`decideWriteWith` 頭注参照)。 -/
def decideWrite (env : GuardEnv) (targetRaw : String) : GuardOutput :=
  decideWriteWith env.profile env targetRaw

/-- Bash 経路の決定木(頭注の順序不変量)。

control surface 段のテキスト検査(`isControlSurfaceBashMutation`)は
CONTROL_ROOT-cwd の相対綴り(素の `README.md` / `./scripts/...`)を写した
保守的過剰近似であり、cwd が登録 PROJECT_ROOT 配下のセッションでは同じ綴りが
agent 所有の通常実装ファイル(§11.1)を指す。そのため cwd(`env.base`)が
登録 project 配下に**ある**ときはテキスト検査を適用せず、解決済みパス判定
(`bashHighRiskTargets` → `isControlPlaneTarget`)だけに委ねる — project cwd
から CONTROL_ROOT へ届く綴り(`../<control>/README.md` / 絶対パス)はそちらが
deny する。cwd 不明・許可ルート外は従来どおりテキスト検査が生きる
(fail-closed)。project cwd の `cp .tmp-readme.md README.md` が control-plane
README 変異として deny された 2026-07-31 の過剰遮断(R-006)の是正。

§11.3(2026-08-12): 非 read-only 分岐の照合対象は生コマンドではなく
`heredocExecutedText command` — quoted heredoc の**本文**は `cat` の標準入力へ
渡るデータであって実行されないので、照合対象から外す。文法上ヘッダ以外に
実行される文字列が存在しないことは `heredocForm?` の受理条件(早すぎる
デリミタ・末尾コマンドの不受理)が保証する。リダイレクト先パスはヘッダに
載っているので保護パス・zone・control-surface の判定は不変である。
read-only 分岐(I-022/I-027)は自前の heredoc 許可面を持つので触らない。

profile は `decideBash` が `env.profile` を渡す明示引数である(`decideWriteWith`
と同じ構図 — G-T6 の証明形)。 -/
def decideBashNormal (profile : Profile) (env : GuardEnv)
    (command : String) : GuardOutput :=
  if protectedPathWriteDeny env.domain command then
    decided [] .deny protectedWriteDenyReason
  else if isSecretBash command then
    decided [] .deny secretDenyReason
  else if isDeniedBash command then
    decided [] .deny (commitDenyReason env.domain)
  else
    let stateSubs := statePySubcommands env.domain command
    if isHumanOnlyBash env.domain command || stateSubs.contains "resume" then
      decided [] .deny (humanOnlyDenyReason env.domain)
    else if isLoopOnlyBash env.domain command
        || stateSubs.any (loopOnlyStateSubcommands.contains ·) then
      decided [] .deny (loopOnlyDenyReason env.domain)
    else match dangerousBashReason? command with
    | some pat => decided [] .deny (dangerousDenyReason pat)
    | none =>
      if commandLaunchesClaude command then
        decided [] .deny claudeLaunchDenyReason
      else if isAskBash env.domain command then
        decided [] .ask (bootstrapAskReason env.domain)
      else
        let highRiskTargets := bashHighRiskTargets env command
        let projectCwd := env.projectRoots.any (insideOf · env.base)
        let controlSurface := (!projectCwd && isControlSurfaceBashMutation env.domain command)
          || highRiskTargets.any (isControlPlaneTarget env)
        -- §28.5-4「保護は綴りではなく解決済み位置で書く」を zone 面にも適用
        -- する。テキスト検査 `isZoneBashMutation` は `>` と対象の間に区切り
        -- 文字を要求する正規表現由来なので `>CLAUDE.md`(空白なし)を取り逃す。
        -- control-plane 面は解決済みパス(`isControlPlaneTarget`)で二重化
        -- されているのに zone 面だけ裏打ちが無く、取り逃すと §12 の ask と
        -- §20.4-3 の before-hash staging が**同時に**落ちて、post が記録する
        -- after-hash と対にならない(G-T5 の対合が実入力で崩れる)。
        let zone := isZoneBashMutation command || !highRiskTargets.isEmpty
        let staged := if zone && !controlSurface then highRiskTargets else []
        let readOnlyTargets := bashReadOnlyTargets env command
        if controlSurface then
          decided staged .deny (controlSurfaceBashDenyReason env.domain)
        -- §11.6(I-007)の Bash mutator 面: mutator 後方の対象パスが既定
        -- 許可面にも writable: にも入らなければ deny(WRITE_TOOLS 面と対称)
        else if !readOnlyTargets.isEmpty then
          decided staged .deny (readOnlyTargetBashDenyReason readOnlyTargets)
        else if zone then
          askUnlessRelaxed staged profile zoneBashAskReason
            "High-Risk Zone Bash mutation (§12)"
        else if isDependencyInputBashMutation command then
          askUnlessRelaxed staged profile dependencyInputAskReason
            "dependency-resolution-input Bash mutation (§11.2)"
        else match cdLeavesAllowedRoots? env command with
        | some target =>
          askUnlessRelaxed staged profile (unsafeCdAskReason target)
            "cd outside the allowed roots (§11.2)"
        | none =>
          match installAllowReason? env command with
          | some reason => decided staged .allow reason
          | none =>
            if commandInstallsDependencies command then
              askUnlessRelaxed staged profile installAskReason
                "unlisted dependency install (§11.2)"
            else if profile == .standard then
              ⟨staged, none⟩
            else
              -- Bash 最終無意見葉のみ fallback allow(§11.5): settings の
              -- allow リスト外のコマンドが headless の自動 deny に落ちない。
              -- settings の deny / hook の deny 群はこの葉より先に確定して
              -- おり(I-030)、Write 無意見葉は対称に緩めない。
              decided staged .allow
                (profileAllowReason "Bash command no other rule covers")

/-- Bash 経路(`decideBashNormal` 頭注参照)。read-only 分岐を最上段に置き、
その下は**実行される文字列**(`heredocExecutedText`)に対する判定である。
分岐と本体を別定義にしているのは証明の都合でもある: 本体を独立の関数にすると、
非 read-only の定理は `heredocExecutedText rawCommand` を 1 つの変数へ
一般化してから決定木を場合分けできる(展開すると `whnf` が heredoc 文法まで
評価しに行き、証明が heartbeat 上限に当たる)。 -/
def decideBashWith (profile : Profile) (env : GuardEnv)
    (rawCommand : String) : GuardOutput :=
  if env.sessionMode == "triage" || env.sessionMode == "essence" then
    match readOnlySessionBashAllow? env rawCommand with
    | some reason => decided [] .allow reason
    | none =>
      let handoffDir := childPath env.controlRoot (".agent/tmp/" ++ env.sessionMode)
      decided [] .deny (readOnlyDenyReason env.domain env.sessionMode handoffDir)
  else
    decideBashNormal profile env (heredocExecutedText rawCommand)

/-- Bash 経路(`decideBashWith` 頭注参照)。 -/
def decideBash (env : GuardEnv) (command : String) : GuardOutput :=
  decideBashWith env.profile env command

/-- `main()` 等価の純粋決定核(§31.4-2 の `GuardEnv → 入力 → 判定`)。 -/
def decide (env : GuardEnv) : ToolCall → GuardOutput
  | .write targetRaw => decideWrite env targetRaw
  | .bash command => decideBash env command
  | .other => ⟨[], none⟩

/-! ## コンパイル時検査(期待値は pre_tool_guard.py の実関数を CPython 3.14
実測。端到端の等価性は差分ファザー + 併走検証で担保済み — §31.2-19) -/

private def env0 : GuardEnv :=
  { controlRoot := "/ws/.looper"
    projectRoots := ["/ws/proj"]
    sessionMode := ""
    base := "/ws/.looper"
    handoffRoot := "/ws/.looper/.agent/tmp/triage"
    expectedProject? := some "/ws/proj"
    stateScript := "/ws/.looper/bin/looper"
    declared := {}
    domain := Domain.fixture
    resolved :=
      [ ("", some "/ws/proj"),
        ("src/app.ts", some "/ws/proj/src/app.ts"),
        ("ESSENCE.md", some "/ws/proj/ESSENCE.md"),
        ("package.json", some "/ws/proj/package.json"),
        ("prompts/x.md", some "/ws/proj/prompts/x.md"),
        ("scripts/state.py", some "/ws/.looper/scripts/state.py"),
        ("recipes/asl/files/loop/lean/lakefile.lean",
         some "/ws/.looper/recipes/asl/files/loop/lean/lakefile.lean"),
        ("templates/project/package.json",
         some "/ws/.looper/templates/project/package.json"),
        ("../proj", some "/ws/proj"),
        ("open/thing.txt", some "/ws/proj/open/thing.txt"),
        ("sub", some "/opt/elsewhere/sub") ] }

/-- 対象実装が既定 read-only なドメインの env(§11.6 / I-007)。**書込み面
ポリシー軸だけ**を差し替える — 台帳や停止理由まで動かすと、この節の他の
期待値が同時に動いて何を凍結しているのか読めなくなる。`env0` 側は
`WritePolicy.implementation` であり、同じ決定木で read-only 段が**在るが
発火しない**ことを凍結する(抽出計画 K-1)。 -/
private def readOnlyEnv : GuardEnv :=
  { env0 with domain :=
      { Domain.fixture with writePolicy := .readOnlyExcept ["open"] } }

/-- read-only ドメイン × `writable: src/**`(§11.6 の解除面)。 -/
private def writableEnv : GuardEnv :=
  { readOnlyEnv with writablePatterns := ["src/**"] }

/-- read-only ドメイン × `writable: **`(全面解除 — deny 床の単調性の検査用)。 -/
private def writableAllEnv : GuardEnv :=
  { readOnlyEnv with writablePatterns := ["**"] }

private def projectCwdEnv : GuardEnv :=
  { env0 with
    base := "/ws/proj"
    resolved := env0.resolved ++
      [ ("README.md", some "/ws/proj/README.md"),
        (".tmp-readme.md", some "/ws/proj/.tmp-readme.md"),
        ("note.md", some "/ws/proj/note.md"),
        ("../.looper/README.md", some "/ws/.looper/README.md") ] }

private def triageEnv : GuardEnv :=
  { env0 with
    sessionMode := "triage"
    settingsFile := "/ws/.looper/.claude/settings.json"
    resolved := env0.resolved ++
      [ ("/ws/.looper/.agent/tmp/triage/resume_note.txt",
         some "/ws/.looper/.agent/tmp/triage/resume_note.txt"),
        ("/ws/.looper/.agent/tmp/triage",
         some "/ws/.looper/.agent/tmp/triage"),
        ("/ws/.looper/bin/looper",
         some "/ws/.looper/bin/looper"),
        ("/ws/.looper/.claude/settings.json",
         some "/ws/.looper/.claude/settings.json"),
        ("/ws/.looper/../proj", some "/ws/proj") ] }

private def essenceNewEnv : GuardEnv :=
  { env0 with
    sessionMode := "essence"
    essenceMode := "new"
    settingsFile := "/ws/.looper/.claude/settings.json"
    handoffRoot := "/ws/.looper/.agent/tmp/essence"
    resolved := env0.resolved ++
      [ ("/ws/.looper/.agent/tmp/essence/ESSENCE.draft.md",
         some "/ws/.looper/.agent/tmp/essence/ESSENCE.draft.md"),
        ("/ws/.looper/.claude/settings.json",
         some "/ws/.looper/.claude/settings.json"),
        ("/ws/proj/ESSENCE.md", some "/ws/proj/ESSENCE.md"),
        ("/ws/proj/essences/brand-guide.pdf",
         some "/ws/proj/essences/brand-guide.pdf"),
        ("/ws/proj/essences", some "/ws/proj/essences"),
        ("/ws/proj/essences/sub/logo.png",
         some "/ws/proj/essences/sub/logo.png"),
        ("/ws/proj/essences/a/b/c/deep.png",
         some "/ws/proj/essences/a/b/c/deep.png") ] }

-- Decision.render(json.dumps 既定セパレータ・ensure_ascii=True と突合)
#guard (Decision.mk .deny "x").render
  == "{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"x\"}}"

-- WRITE_TOOLS: deny → deny(control plane)→ deny(read-only 対象、I-007)→
-- ask(manifest)→ ask(zone)→ 無意見
#guard decide env0 (.write "ESSENCE.md")
  == ⟨[], some ⟨.deny, writeDenyReason Domain.fixture Domain.fixture.projectionLedgers "ESSENCE.md"⟩⟩
#guard decide env0 (.write "essences/logo.png")
  == ⟨[], some ⟨.deny, writeDenyReason Domain.fixture Domain.fixture.projectionLedgers
      "essences/logo.png"⟩⟩
#guard decide env0 (.bash "cp x.png essences/x.png")
  == ⟨[], some ⟨.deny, protectedWriteDenyReason⟩⟩
-- 対象実装が作業面のドメインでは read-only 段を通過して依存ゲートへ届く
#guard decide env0 (.write "package.json")
  == ⟨[], some ⟨.ask, manifestAskReason "package.json"⟩⟩
-- I-007 反転: read-only ドメインでは writable 許可の無い対象マニフェストは
-- ask に届く前に deny
#guard decide readOnlyEnv (.write "package.json")
  == ⟨[], some ⟨.deny, readOnlyTargetDenyReason "package.json"⟩⟩
-- writable が対象マニフェストを含む場合、依存ゲートの ask は不変(§11.6-3)
#guard decide writableAllEnv (.write "package.json")
  == ⟨[], some ⟨.ask, manifestAskReason "package.json"⟩⟩
#guard decide env0 (.write "scripts/state.py")   -- 解決先が CONTROL_ROOT 配下
  == ⟨[], some ⟨.deny, controlPlaneDenyReason Domain.fixture "scripts/state.py"⟩⟩
-- 制御プレーン面 ∩ 依存マニフェスト名: deny が ask に**先行**する(§11.3 /
-- §29.2 — レシピ原本の `lakefile.lean` は配布物に実在する重なりであり、
-- 旧順序では Edit だけが ask へ降格して Bash 面の deny と食い違っていた)
#guard decide env0 (.write "recipes/asl/files/loop/lean/lakefile.lean")
  == ⟨[], some ⟨.deny,
    controlPlaneDenyReason Domain.fixture "recipes/asl/files/loop/lean/lakefile.lean"⟩⟩
#guard decide env0 (.write "templates/project/package.json")
  == ⟨[], some ⟨.deny, controlPlaneDenyReason Domain.fixture "templates/project/package.json"⟩⟩
#guard decide env0 (.write "prompts/x.md")       -- zone は staging + ask
  == ⟨["prompts/x.md"], some ⟨.ask, zoneAskReason "prompts/x.md"⟩⟩
-- I-007 反転: read-only ドメインでは writable 許可の無い zone パスも deny
-- (staging は不変 — §20.4-3)
#guard decide readOnlyEnv (.write "prompts/x.md")
  == ⟨["prompts/x.md"], some ⟨.deny, readOnlyTargetDenyReason "prompts/x.md"⟩⟩
-- writable が zone を含む場合、High-Risk の ask + staging は不変(§11.6-3)
#guard decide writableAllEnv (.write "prompts/x.md")
  == ⟨["prompts/x.md"], some ⟨.ask, zoneAskReason "prompts/x.md"⟩⟩
-- 対象実装ファイル: 作業面ドメインでは無意見、read-only ドメインでは既定
-- deny で `writable:` が解除する
#guard decide env0 (.write "src/app.ts") == ⟨[], none⟩
#guard decide readOnlyEnv (.write "src/app.ts")
  == ⟨[], some ⟨.deny, readOnlyTargetDenyReason "src/app.ts"⟩⟩
#guard decide writableEnv (.write "src/app.ts") == ⟨[], none⟩
-- ドメインの既定許可面(`WritePolicy.readOnlyExcept`)は無宣言でも無意見
#guard decide readOnlyEnv (.write "open/thing.txt") == ⟨[], none⟩
-- deny 床の単調性(§11.6-2): writable: ** でも human-only 面は不変
#guard decide writableAllEnv (.write "ESSENCE.md")
  == ⟨[], some ⟨.deny, writeDenyReason Domain.fixture Domain.fixture.projectionLedgers "ESSENCE.md"⟩⟩
#guard decide writableAllEnv (.write "essences/logo.png")
  == ⟨[], some ⟨.deny, writeDenyReason Domain.fixture Domain.fixture.projectionLedgers
      "essences/logo.png"⟩⟩
#guard decide env0 .other == ⟨[], none⟩

-- Bash deny 群の順序(G-T1: dangerous は zone ask に降格しない)
#guard decide env0 (.bash "rm -rf prompts/")
  == ⟨[], some ⟨.deny, dangerousDenyReason "\\brm\\s+-rf\\b"⟩⟩
#guard decide env0 (.bash "echo x > .looper/state/todo.json")
  == ⟨[], some ⟨.deny, protectedWriteDenyReason⟩⟩
#guard decide env0 (.bash "cat .env")
  == ⟨[], some ⟨.deny, secretDenyReason⟩⟩
#guard decide env0 (.bash "git add .")
  == ⟨[], some ⟨.deny, commitDenyReason Domain.fixture⟩⟩
-- G-T3: フラグ先行綴りの resume / loop-only も deny(旧 python3 綴りの
-- 遮断も継続する — 緩和しない)
#guard decide env0 (.bash "python3 scripts/state.py --project ../proj resume")
  == ⟨[], some ⟨.deny, humanOnlyDenyReason Domain.fixture⟩⟩
#guard decide env0 (.bash "bin/looper state --project ../proj resume")
  == ⟨[], some ⟨.deny, humanOnlyDenyReason Domain.fixture⟩⟩
#guard decide env0 (.bash "bin/looper state resume --project ../proj")
  == ⟨[], some ⟨.deny, humanOnlyDenyReason Domain.fixture⟩⟩
#guard decide env0 (.bash "just state --project x record-progress")
  == ⟨[], some ⟨.deny, loopOnlyDenyReason Domain.fixture⟩⟩
#guard decide env0 (.bash "bin/looper state --project x record-progress")
  == ⟨[], some ⟨.deny, loopOnlyDenyReason Domain.fixture⟩⟩
#guard decide env0 (.bash "bash -c 'claude -p hi'")
  == ⟨[], some ⟨.deny, claudeLaunchDenyReason⟩⟩
#guard decide env0 (.bash "just bootstrap")
  == ⟨[], some ⟨.ask, bootstrapAskReason Domain.fixture⟩⟩

-- Bash 変異の分類: 制御プレーン面は deny(staging なし)、zone は staging + ask
#guard decide env0 (.bash "tee scripts/state.py")
  == ⟨[], some ⟨.deny, controlSurfaceBashDenyReason Domain.fixture⟩⟩
-- cwd = CONTROL_ROOT(env0.base)では素の README.md 綴りはテキスト検査が deny
#guard decide env0 (.bash "cp note.md README.md")
  == ⟨[], some ⟨.deny, controlSurfaceBashDenyReason Domain.fixture⟩⟩
#guard decide env0 (.bash "tee prompts/x.md")
  == ⟨["/ws/proj/prompts/x.md"], some ⟨.ask, zoneBashAskReason⟩⟩
#guard decide env0 (.bash "echo x > package.json")
  == ⟨[], some ⟨.ask, dependencyInputAskReason⟩⟩
-- I-007 反転(Bash 面): read-only ドメインでは writable 許可の無い対象 zone /
-- マニフェストへの mutator は deny(staging 不変)。writable 下では従来の
-- ask が生きる
#guard decide readOnlyEnv (.bash "tee prompts/x.md")
  == ⟨["/ws/proj/prompts/x.md"],
      some ⟨.deny, readOnlyTargetBashDenyReason ["/ws/proj/prompts/x.md"]⟩⟩
#guard decide writableAllEnv (.bash "tee prompts/x.md")
  == ⟨["/ws/proj/prompts/x.md"], some ⟨.ask, zoneBashAskReason⟩⟩
#guard decide readOnlyEnv (.bash "echo x > package.json")
  == ⟨[], some ⟨.deny, readOnlyTargetBashDenyReason ["/ws/proj/package.json"]⟩⟩
#guard decide writableAllEnv (.bash "echo x > package.json")
  == ⟨[], some ⟨.ask, dependencyInputAskReason⟩⟩
-- 対象の読取は自由(§11.6): mutator を伴わない対象パスは素通り
#guard decide readOnlyEnv (.bash "cat src/app.ts") == ⟨[], none⟩
-- ドメインの既定許可面への Bash 書込みは read-only 面に掛からない
#guard decide readOnlyEnv (.bash "tee open/thing.txt") == ⟨[], none⟩

-- cwd = PROJECT_ROOT では同じ相対綴りが対象側の同名ファイルを指すため、
-- control-plane テキスト検査は適用されない(2026-07-31 の R-006 過剰遮断の
-- 是正)。対象ファイル自体の書込み可否は §11.6 の read-only/writable: 判定が
-- 別途決める — 無許可なら read-only deny、writable 許可下では素通り
#guard decide projectCwdEnv (.bash "cp .tmp-readme.md README.md") == ⟨[], none⟩
#guard decide { projectCwdEnv with domain := readOnlyEnv.domain }
    (.bash "cp .tmp-readme.md README.md")
  == ⟨[], some ⟨.deny, readOnlyTargetBashDenyReason
      ["/ws/proj/.tmp-readme.md", "/ws/proj/README.md"]⟩⟩
#guard decide
    { projectCwdEnv with
      domain := readOnlyEnv.domain, writablePatterns := ["**"] }
    (.bash "cp .tmp-readme.md README.md") == ⟨[], none⟩
#guard decide projectCwdEnv (.bash "cp note.md ../.looper/README.md")
  == ⟨[], some ⟨.deny, controlSurfaceBashDenyReason Domain.fixture⟩⟩

-- cd フェンス(§11.2): 許可ルート外は ask、絶対 cd 先は未解決比較
#guard decide env0 (.bash "cd /opt && ls")
  == ⟨[], some ⟨.ask, unsafeCdAskReason "/opt"⟩⟩
#guard decide env0 (.bash "cd sub && ls")
  == ⟨[], some ⟨.ask, unsafeCdAskReason "/opt/elsewhere/sub"⟩⟩
#guard decide env0 (.bash "cd ../proj && ls") == ⟨[], none⟩

-- 依存ゲート(§11.2): materialization / 信頼済み install は allow、残りは ask
#guard (decide env0 (.bash "cd ../proj && pnpm install --frozen-lockfile")).decision?
  == some ⟨.allow, "Materialization (META.md §11.2): installs the manifest/lockfile already in the repository, naming no package of its own. The dependency set it expands was already gated when the manifest was written (manifest edits ask)."⟩
#guard (decide env0 (.bash "npm install typescript")).decision?
  == some ⟨.allow, "Trusted dependency install (META.md §11.2): typescript (npm) are all on the curated list or declared in the project's ESSENCE.md; anything else still requires the human."⟩
#guard decide env0 (.bash "npm install left-pad")
  == ⟨[], some ⟨.ask, installAskReason⟩⟩
#guard decide env0 (.bash "ls -la") == ⟨[], none⟩

-- read-only セッション(I-022/I-027): 許可 3 面と deny 文言
#guard decide triageEnv
    (.bash "cat > '/ws/.looper/.agent/tmp/triage/resume_note.txt' <<'EOF'\nhi\nEOF")
  == ⟨[], some ⟨.allow, "triage read-only handoff write (I-022/I-027)"⟩⟩
#guard decide triageEnv (.bash "mkdir -p .agent/tmp/triage")
  == ⟨[], some ⟨.allow, "triage handoff directory creation (I-022/I-027)"⟩⟩
#guard decide triageEnv
    (.bash "bin/looper state status --project ../proj")
  == ⟨[], some ⟨.allow, "triage read-only state inspection (I-022/I-027)"⟩⟩
#guard decide triageEnv (.bash "ls")
  == ⟨[], some ⟨.deny, readOnlyDenyReason Domain.fixture "triage" "/ws/.looper/.agent/tmp/triage"⟩⟩
#guard (readOnlyDenyReason Domain.fixture "triage" "/cr/.agent/tmp/triage")
  == "triage is a read-only human session (I-022/I-027). Bash is limited to exact state inspection (bin/looper state status|should-stop --project <bound-project>) and one single-command quoted heredoc into the wrapper-owned handoff directory — nothing chained before or after it (an optional `mkdir -p /cr/.agent/tmp/triage && ` prefix is the sole exception). To write the handoff, use the Write tool on /cr/.agent/tmp/triage/resume_note.txt, or run exactly:\ncat > '/cr/.agent/tmp/triage/resume_note.txt' <<'LOOPER_HANDOFF'\n<content>\nLOOPER_HANDOFF"

-- read-only セッションの WRITE_TOOLS 面(§13.6-3): handoff 内のみ allow、
-- それ以外(project・deny-pattern 該当を含む)は教示付き deny が deny 群に先行
#guard decide triageEnv
    (.write "/ws/.looper/.agent/tmp/triage/resume_note.txt")
  == ⟨[], some ⟨.allow, "triage read-only handoff write (I-022/I-027)"⟩⟩
#guard decide triageEnv (.write "src/app.ts")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "triage" "/ws/.looper/.agent/tmp/triage"⟩⟩
#guard decide triageEnv (.write "ESSENCE.md")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "triage" "/ws/.looper/.agent/tmp/triage"⟩⟩
#guard decide triageEnv (.write "/ws/.looper/.agent/tmp/triage")  -- root 自身は不可
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "triage" "/ws/.looper/.agent/tmp/triage"⟩⟩
#guard (readOnlyWriteDenyReason "triage" "/cr/.agent/tmp/triage")
  == "triage is a read-only human session (I-022/I-027): the only freely writable path is the wrapper-owned handoff directory /cr/.agent/tmp/triage/. Write the handoff with the Write tool to /cr/.agent/tmp/triage/resume_note.txt (supporting drafts may use other names inside the same directory). Beyond the handoff, the only human-approvable (ask) write surface is the live settings file .claude/settings.json (deployment repair, META.md §28.5-3); everything else is denied."
#guard (readOnlyWriteDenyReason "essence" "/cr/.agent/tmp/essence" true)
  == "essence is a read-only human session (I-022/I-027): the only freely writable path is the wrapper-owned handoff directory /cr/.agent/tmp/essence/. Write the handoff with the Write tool to /cr/.agent/tmp/essence/ESSENCE.draft.md (supporting drafts may use other names inside the same directory). Beyond the handoff, the only human-approvable (ask) write surfaces are the live settings file .claude/settings.json (deployment repair, META.md §28.5-3), PROJECT_ROOT/ESSENCE.md (interview fallback install, I-027 second path), and files under PROJECT_ROOT/essences/ up to 3 path segments deep (asset fallback install, same path — §2.1.5); everything else is denied."

-- read-only セッションの ask 面(§28.5-3 / I-027 第二経路): live settings は
-- 両モード ask、ESSENCE.md 直接設置は essence-new のみ ask。handoff allow が
-- ask 面に先行する。
#guard decide triageEnv (.write "/ws/.looper/.claude/settings.json")
  == ⟨[], some ⟨.ask, liveSettingsAskReason "triage"⟩⟩
#guard decide essenceNewEnv (.write "/ws/.looper/.claude/settings.json")
  == ⟨[], some ⟨.ask, liveSettingsAskReason "essence"⟩⟩
#guard decide essenceNewEnv (.write "/ws/proj/ESSENCE.md")
  == ⟨[], some ⟨.ask, essenceDirectInstallAskReason⟩⟩
#guard decide essenceNewEnv
    (.write "/ws/.looper/.agent/tmp/essence/ESSENCE.draft.md")
  == ⟨[], some ⟨.allow, "essence read-only handoff write (I-022/I-027)"⟩⟩
-- essences/ 資産設置面(I-027 第二経路の §2.1.5 面): essence-new のみ、
-- 最大 3 階層までのファイルが ask。root 自身・上限超過・update/triage は
-- 教示付き deny
#guard decide essenceNewEnv (.write "/ws/proj/essences/brand-guide.pdf")
  == ⟨[], some ⟨.ask, essenceAssetInstallAskReason⟩⟩
#guard decide essenceNewEnv (.write "/ws/proj/essences/sub/logo.png")
  == ⟨[], some ⟨.ask, essenceAssetInstallAskReason⟩⟩
#guard decide essenceNewEnv (.write "/ws/proj/essences")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "essence" "/ws/.looper/.agent/tmp/essence" true⟩⟩
#guard decide essenceNewEnv (.write "/ws/proj/essences/a/b/c/deep.png")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "essence" "/ws/.looper/.agent/tmp/essence" true⟩⟩
#guard decide { essenceNewEnv with essenceMode := "update" }
    (.write "/ws/proj/essences/brand-guide.pdf")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "essence" "/ws/.looper/.agent/tmp/essence"⟩⟩
-- update モード(essenceMode ≠ "new")では ESSENCE.md 直接設置 fallback は
-- 立たず、教示付き deny(ask 面の列挙は settings のみ)。
#guard decide { essenceNewEnv with essenceMode := "update" }
    (.write "/ws/proj/ESSENCE.md")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "essence" "/ws/.looper/.agent/tmp/essence"⟩⟩
-- triage では ESSENCE.md は従来どおり deny(fallback は essence-new 限定)。
#guard decide triageEnv (.write "/ws/proj/ESSENCE.md")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "triage" "/ws/.looper/.agent/tmp/triage"⟩⟩
-- settingsFile 未設定(旧 shadow 互換の GuardEnv)では settings ask 面は
-- 立たない(空文字列ガード)。
#guard decide { triageEnv with settingsFile := "" }
    (.write "/ws/.looper/.claude/settings.json")
  == ⟨[], some ⟨.deny,
    readOnlyWriteDenyReason "triage" "/ws/.looper/.agent/tmp/triage"⟩⟩
-- resume は read-only の state 読み取り面をすり抜けない
#guard (decide triageEnv
    (.bash "bin/looper state resume --project ../proj")).decision?
  == some ⟨.deny, readOnlyDenyReason Domain.fixture "triage" "/ws/.looper/.agent/tmp/triage"⟩
-- 旧 python3 綴りは triage の受理形に含まれない(deny 側)
#guard (decide triageEnv
    (.bash "python3 scripts/state.py status --project ../proj")).decision?
  == some ⟨.deny, readOnlyDenyReason Domain.fixture "triage" "/ws/.looper/.agent/tmp/triage"⟩

-- cd_targets の finditer 意味論(^ 直置きのみ・separator 再開・shlex 先頭)
#guard cdRawCaptures "cd /opt && ls" == ["/opt "]
#guard cdRawCaptures " cd /opt" == []        -- ^ 代替に \s* はない
#guard cdRawCaptures "ls; cd a; cd 'b c'" == ["a", "'b c'"]
#guard cdFirstTokens "ls; cd a; cd 'b c'" == ["a", "b c"]
#guard cdRawCaptures "echo cd x" == []       -- セグメント頭でない cd
#guard cdRawCaptures "ls\ncd sub" == ["sub"]

-- 解決要求の列挙(IO シェルの契約面)
#guard familyARequests (.write "src/app.ts") == ["src/app.ts"]
-- 絶対キーも解決要求に載る(`..` を畳んだ位置で containment を判定するため)
#guard familyARequests (.write "/abs/p.md") == ["/abs/p.md"]
#guard familyARequests (.bash "cd /abs/../.. && npm ci") == ["/abs/../..", "/abs/../.."]
#guard familyARequests (.bash "tee prompts/x.md; cd sub")
  == ["prompts/x.md", "sub"]
#guard familyARequests (.bash "cd ../proj && npm install typescript")
  == ["../proj", "../proj"]
#guard familyBRequests "/cr" "" (.bash "cat > x <<'EOF'\nhi\nEOF") == []
#guard familyBRequests "/cr" "essence" (.bash "cat > x <<'EOF'\nhi\nEOF")
  == ["/cr/x"]
#guard familyBRequests "/cr" "triage"
    (.bash "bin/looper state status --project ../proj")
  == ["/cr/bin/looper", "/cr/../proj"]
#guard familyBRequests "/cr" "triage"
    (.bash "python3 scripts/state.py status --project ../proj") == []
#guard familyBRequests "/cr" "triage" (.write "note.txt") == ["/cr/note.txt"]
#guard familyBRequests "/cr" "essence" (.write "/abs/x.md") == ["/abs/x.md"]
#guard familyBRequests "/cr" "" (.write "note.txt") == []

/-! ## relaxed profile(§11.5)のコンパイル時検査 -/

private def relaxedEnv : GuardEnv := { env0 with profile := .autoApprove }
private def unsandboxedEnv : GuardEnv := { env0 with profile := .unsandboxed }
/-- relaxed × read-only ドメイン(§11.5 × §11.6): ask 緩和は writable 許可
範囲の内側でだけ観測できる — read-only deny は profile 非依存(I-030 と同型)。 -/
private def relaxedReadOnlyEnv : GuardEnv :=
  { readOnlyEnv with profile := .autoApprove }
private def relaxedWritableEnv : GuardEnv :=
  { readOnlyEnv with profile := .autoApprove, writablePatterns := ["**"] }

-- read-only deny は relaxed でも不変(deny は緩まない — I-030)
#guard decide relaxedReadOnlyEnv (.write "package.json")
  == ⟨[], some ⟨.deny, readOnlyTargetDenyReason "package.json"⟩⟩
-- 緩和 6 葉: ask → 監査可能な理由文言つき allow(staging 不変。対象側の
-- ask 面は writable 許可下でだけ到達する)
#guard decide relaxedEnv (.write "package.json")
  == ⟨[], some ⟨.allow, profileAllowReason "dependency-manifest edit (§11.2)"⟩⟩
#guard decide relaxedWritableEnv (.write "package.json")
  == ⟨[], some ⟨.allow, profileAllowReason "dependency-manifest edit (§11.2)"⟩⟩
#guard decide relaxedWritableEnv (.write "prompts/x.md")
  == ⟨["prompts/x.md"],
    some ⟨.allow, profileAllowReason "High-Risk Zone edit (§12)"⟩⟩
#guard decide relaxedWritableEnv (.bash "tee prompts/x.md")
  == ⟨["/ws/proj/prompts/x.md"],
    some ⟨.allow, profileAllowReason "High-Risk Zone Bash mutation (§12)"⟩⟩
#guard decide relaxedWritableEnv (.bash "echo x > package.json")
  == ⟨[], some ⟨.allow,
    profileAllowReason "dependency-resolution-input Bash mutation (§11.2)"⟩⟩
#guard decide relaxedEnv (.bash "cd /opt && ls")
  == ⟨[], some ⟨.allow,
    profileAllowReason "cd outside the allowed roots (§11.2)"⟩⟩
#guard decide relaxedEnv (.bash "npm install left-pad")
  == ⟨[], some ⟨.allow,
    profileAllowReason "unlisted dependency install (§11.2)"⟩⟩
-- Bash 最終無意見葉は fallback allow、Write 無意見葉は不変(§11.5)
#guard decide relaxedEnv (.bash "ls -la")
  == ⟨[], some ⟨.allow,
    profileAllowReason "Bash command no other rule covers"⟩⟩
#guard decide relaxedWritableEnv (.write "src/app.ts") == ⟨[], none⟩
#guard decide relaxedEnv .other == ⟨[], none⟩
-- guard は auto-approve と unsandboxed を区別しない(§11.5)
#guard decide unsandboxedEnv (.bash "ls -la")
  == decide relaxedEnv (.bash "ls -la")
#guard decide unsandboxedEnv (.write "package.json")
  == decide relaxedEnv (.write "package.json")
#guard decide unsandboxedEnv (.bash "npm install left-pad")
  == decide relaxedEnv (.bash "npm install left-pad")
-- bootstrap / build の ask は維持(§11.5 の意図的除外)
#guard decide relaxedEnv (.bash "just bootstrap")
  == ⟨[], some ⟨.ask, bootstrapAskReason Domain.fixture⟩⟩
-- 既存の allow 面(curated install / materialization)は理由文言ごと不変
#guard (decide relaxedEnv (.bash "npm install typescript")).decision?
  == (decide env0 (.bash "npm install typescript")).decision?
-- deny 床は理由文言ごと不変(I-030)
#guard decide relaxedEnv (.write "ESSENCE.md")
  == ⟨[], some ⟨.deny, writeDenyReason Domain.fixture Domain.fixture.projectionLedgers "ESSENCE.md"⟩⟩
#guard decide relaxedEnv (.write "essences/logo.png")
  == ⟨[], some ⟨.deny, writeDenyReason Domain.fixture Domain.fixture.projectionLedgers
      "essences/logo.png"⟩⟩
#guard decide relaxedEnv (.bash "cat .env")
  == ⟨[], some ⟨.deny, secretDenyReason⟩⟩
#guard decide relaxedEnv (.bash "git add .")
  == ⟨[], some ⟨.deny, commitDenyReason Domain.fixture⟩⟩
#guard decide relaxedEnv (.bash "rm -rf prompts/")
  == ⟨[], some ⟨.deny, dangerousDenyReason "\\brm\\s+-rf\\b"⟩⟩
#guard decide relaxedEnv (.write "scripts/state.py")
  == ⟨[], some ⟨.deny, controlPlaneDenyReason Domain.fixture "scripts/state.py"⟩⟩
#guard decide relaxedEnv (.bash "tee scripts/state.py")
  == ⟨[], some ⟨.deny, controlSurfaceBashDenyReason Domain.fixture⟩⟩
#guard decide relaxedEnv (.bash "bash -c 'claude -p hi'")
  == ⟨[], some ⟨.deny, claudeLaunchDenyReason⟩⟩
#guard decide relaxedEnv
    (.bash "bin/looper state resume --project ../proj")
  == ⟨[], some ⟨.deny, humanOnlyDenyReason Domain.fixture⟩⟩
#guard decide relaxedEnv (.bash "just state --project x record-progress")
  == ⟨[], some ⟨.deny, loopOnlyDenyReason Domain.fixture⟩⟩
-- read-only セッションは profile を無視する(構造的に profile 葉に到達
-- しない、I-022/I-027 — §11.5)
#guard decide { triageEnv with profile := .autoApprove } (.bash "ls")
  == decide triageEnv (.bash "ls")
#guard decide { triageEnv with profile := .unsandboxed } (.write "src/app.ts")
  == decide triageEnv (.write "src/app.ts")
#guard decide { essenceNewEnv with profile := .unsandboxed }
    (.write "/ws/proj/ESSENCE.md")
  == decide essenceNewEnv (.write "/ws/proj/ESSENCE.md")

end Looper.Guard
