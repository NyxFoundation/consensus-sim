import Looper.Core.Essence
import Looper.Domain

/-!
`Looper.Core.Classify.Profile` — ESSENCE.md の第 3 の機械可読 directive
`profile:`(META.md §11.5)の純粋核。

`deps:`(`Classify/Install.lean`)/ `recipe:`(`Core/Text.lean`)と同型:
`semanticLines` 経由で HTML comment / fenced code block の外にある active line
だけが発効し、位置非依存。値は閉集合 3 段(standard / auto-approve /
unsandboxed)で、それ以外の綴り・相異なる複数宣言は standard へ縮退する —
緩和方向の機能は不確実性があれば発効しない(§11.5)。

settings 派生(`deriveProfileTemplate`)もここに置く: base settings
(§16.1)は 1 枚の `settings.json.tmpl` が正本で、profile はその
`_<snake>_profile` 行の値としてだけ焼き込まれる — relaxed の実効
(ask 3 面除去・sandbox 解除)は起動毎の overlay 生成
(`Core.Settings.boundSession`)が担う。派生は**レンダ前**のテンプレ
テキストに適用するため、パターンは機械非依存の固定文字列で済む。
project 側 ask 3 面の定義(`projectAskSurfaces`)は overlay 生成と
`Core.SettingsDoctor` の対称検査が共有する単一定義点である。
-/

namespace Looper.Core.Classify

open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (pyStrip)
open Looper.Core.Essence (semanticLines)

/-- 実行 profile の閉集合 3 段(§11.5、単調包含)。 -/
inductive Profile where
  | standard
  | autoApprove
  | unsandboxed
deriving BEq, DecidableEq, Repr

/-- ESSENCE / CLI の正準綴り。 -/
def Profile.tag : Profile → String
  | .standard => "standard"
  | .autoApprove => "auto-approve"
  | .unsandboxed => "unsandboxed"

/-- 閉集合の完全一致パース。前後空白は呼び出し側で strip 済み前提であり、
ここでは一切の正規化(小文字化・同義語)を行わない — 発効する綴りは
`Profile.tag` の 3 つだけである(§11.5)。 -/
def Profile.parse? : String → Option Profile
  | "standard" => some .standard
  | "auto-approve" => some .autoApprove
  | "unsandboxed" => some .unsandboxed
  | _ => none

/-- `profile:` 1 行分の payload: `^[ \t>*-]*profile:[ \t]*(.+)$`(`deps:` の
`depsLinePayload?` と同じ接頭辞クラス。クラスは `p` を含まないため貪欲
dropWhile が唯一の分割)。payload は strip 済みで返す(単一値 directive
なので行末空白も剥ぐ)。 -/
private def profileLinePayload? (line : String) : Option String :=
  let rest := line.toList.dropWhile fun c =>
    c == ' ' || c == '\t' || c == '>' || c == '*' || c == '-'
  match dropLit? rest "profile:".toList with
  | none => none
  | some r =>
    let payload := pyStrip (String.ofList r)
    if payload.isEmpty then none else some payload

/-- ESSENCE テキストの semantic 行(comment / fence 外)に現れる `profile:`
宣言 payload の列(出現順)。directive parser の共通安全境界
(`semanticLines`)を必ず通す(§2.1.1)。 -/
def profileLinePayloads (text : String) : List String :=
  (semanticLines text).filterMap profileLinePayload?

/-- 宣言走査の結果。`declared` 以外はすべて standard へ縮退する(§11.5)。 -/
inductive ProfileScan where
  | absent
  | declared (p : Profile)
  | invalid (raw : String)
  | conflict
deriving BEq, Repr

/-- payload 列の走査: 不正 payload が 1 つでもあれば invalid(最初の不正値を
保持 — valid 宣言が併存しても発効させない安全側)、相異なる valid 値が並べば
conflict、全宣言が同一 valid 値なら declared(同値の重複宣言は矛盾ではない)。
invalid が conflict に優先するのは報告の質の問題にすぎない — effective は
どちらも standard である。 -/
def scanProfilePayloads (payloads : List String) : ProfileScan :=
  match payloads.find? (fun s => (Profile.parse? s).isNone) with
  | some bad => .invalid bad
  | none =>
    match payloads.filterMap Profile.parse? with
    | [] => .absent
    | v :: rest => if rest.all (· == v) then .declared v else .conflict

/-- 1 テキスト分の走査(複数 ESSENCE の合成は payload 列の連結で行う —
`Cli/Hook` の IO シェルが登録ルートを fold する)。 -/
def scanProfile (text : String) : ProfileScan :=
  scanProfilePayloads (profileLinePayloads text)

/-- 発効値: 明示の無矛盾な宣言だけが standard 以外になれる(§11.5)。 -/
def ProfileScan.effective : ProfileScan → Profile
  | .declared p => p
  | _ => .standard

/-! ## settings 派生(§16.1 — base は 1 テンプレ + profile 行の焼き込みが正本) -/

/-- project 側 ask 3 面(overlay の ask 配列、§16.1)のサフィックス。
単一定義点 — `Core.Settings.boundSession`(standard での ask 常設)と
`Core.SettingsDoctor`(overlay の対称 3 分岐検査)が共有する。relaxed 2 態で
この 3 面を overlay から除去するのは、settings の ask が hook の allow に
常に勝つためである(§11.2、§11.5)。 -/
def projectAskSurfaces : List String :=
  ["CLAUDE.md", ".claude/**", ".mcp.json"]

/-- base settings の profile 記録行の正確な綴り(2 スペースインデント +
末尾カンマ + 改行)。`settings.json.tmpl` の該当行・`deriveProfileTemplate`
の置換・`Core.Settings.baseProfile?` の読み手が共有する単一定義点。 -/
def profileTemplateLine (d : Domain) (p : Profile) : String :=
  let profileKey := "_" ++ d.snake ++ "_profile"
  "  \"" ++ profileKey ++ "\": \"" ++ p.tag ++ "\",\n"

/-- `needle`(非空)の出現回数。 -/
private def countOccurrences (hay needle : String) : Nat :=
  (hay.splitOn needle).length - 1

/-- ちょうど 1 回出現する部分文字列の置換。0 回・2 回以上は none —
テンプレが期待の形から動いたら派生ごと拒否する(fail-closed)。 -/
private def replaceExactlyOnce (hay needle replacement : String) :
    Option String :=
  if countOccurrences hay needle == 1 then
    some (hay.replace needle replacement)
  else none

/-- profile に応じたテンプレ派生(§11.5、§16.1)。**レンダ前**の
`settings.json.tmpl` テキストへ適用する。base はマシン非依存で、profile の
発効実体(ask 3 面除去・sandbox 解除)は起動毎の overlay 生成が担うため、
派生は `_<snake>_profile` 行の exactly-once 置換 1 本に縮小されている。
standard も行の存在検証を経た恒等置換 — 非対称な fail-open を作らない。
「ちょうど 1 回」一致しなければ none であり、呼び出し側
(`util render --profile`)は描画自体を拒否する。 -/
def deriveProfileTemplate (d : Domain) (p : Profile) (template : String) :
    Option String :=
  replaceExactlyOnce template (profileTemplateLine d .standard)
    (profileTemplateLine d p)

/-! ## コンパイル時検査(§11.5 の凍結) -/

-- 閉集合の完全一致パース(正規化なし)
#guard Profile.parse? "standard" == some .standard
#guard Profile.parse? "auto-approve" == some .autoApprove
#guard Profile.parse? "unsandboxed" == some .unsandboxed
#guard Profile.parse? "Standard" == none
#guard Profile.parse? "auto approve" == none
#guard Profile.parse? "poc" == none
#guard Profile.parse? "" == none
#guard [Profile.standard, .autoApprove, .unsandboxed].all
  (fun p => Profile.parse? p.tag == some p)

-- 行 payload: deps: と同じ接頭辞クラス・strip・空 payload 不成立
#guard profileLinePayloads "profile: auto-approve" == ["auto-approve"]
#guard profileLinePayloads "- profile: unsandboxed " == ["unsandboxed"]
#guard profileLinePayloads "> * - profile:\tstandard" == ["standard"]
#guard profileLinePayloads "profile:" == []
#guard profileLinePayloads "  profile:   " == []
#guard profileLinePayloads "xprofile: standard" == []
#guard profileLinePayloads "prose then profile: standard" == []
-- comment / fence 内は発効しない(directive parser の共通安全境界)
#guard profileLinePayloads "<!-- profile: auto-approve -->" == []
#guard profileLinePayloads "<!--\nprofile: auto-approve\n-->" == []
#guard profileLinePayloads "```\nprofile: auto-approve\n```" == []
#guard profileLinePayloads "## 前提事項\nprofile: auto-approve\n- x" ==
  ["auto-approve"]

-- 走査の 4 態と standard 縮退
#guard scanProfile "" == .absent
#guard scanProfile "## 前提事項\n- x" == .absent
#guard scanProfile "profile: auto-approve" == .declared .autoApprove
#guard scanProfile "profile: auto-approve\nprofile: auto-approve"
  == .declared .autoApprove
#guard scanProfile "profile: auto-approve\nprofile: unsandboxed" == .conflict
#guard scanProfile "profile: poc" == .invalid "poc"
#guard scanProfile "profile: auto-approve\nprofile: poc" == .invalid "poc"
#guard scanProfile "<!-- profile: unsandboxed -->" == .absent
#guard (ProfileScan.absent).effective == .standard
#guard (ProfileScan.declared .unsandboxed).effective == .unsandboxed
#guard (ProfileScan.invalid "poc").effective == .standard
#guard (ProfileScan.conflict).effective == .standard

-- derive: 実テンプレ断片での 3 態(profile 行は model 直後・2 スペース
-- インデント・末尾カンマ)
private def sampleTemplateFragment : String :=
  "  \"model\": \"best\",\n"
    ++ "  \"_looper_profile\": \"standard\",\n"
    ++ "  \"permissions\": {\n"

#guard deriveProfileTemplate Domain.fixture .standard sampleTemplateFragment
  == some sampleTemplateFragment
#guard deriveProfileTemplate Domain.fixture .autoApprove sampleTemplateFragment
  == some ("  \"model\": \"best\",\n"
    ++ "  \"_looper_profile\": \"auto-approve\",\n"
    ++ "  \"permissions\": {\n")
#guard deriveProfileTemplate Domain.fixture .unsandboxed sampleTemplateFragment
  == some ("  \"model\": \"best\",\n"
    ++ "  \"_looper_profile\": \"unsandboxed\",\n"
    ++ "  \"permissions\": {\n")
-- fail-closed: profile 行が欠けた・重複したテンプレは standard 含む全派生を
-- 拒否する(存在検証は 3 態で対称)
#guard deriveProfileTemplate Domain.fixture .standard "no profile line here" == none
#guard deriveProfileTemplate Domain.fixture .autoApprove "no profile line here" == none
#guard deriveProfileTemplate Domain.fixture .unsandboxed
    (sampleTemplateFragment ++ sampleTemplateFragment) == none
-- インデントや引用の崩れた行は一致しない(綴りは profileTemplateLine d の
-- 1 定義点)
#guard deriveProfileTemplate Domain.fixture .autoApprove
    "\"_looper_profile\": \"standard\",\n" == none

end Looper.Core.Classify
