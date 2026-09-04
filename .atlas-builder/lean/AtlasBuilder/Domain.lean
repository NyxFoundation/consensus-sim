import Looper.State.Predicates
import Looper.State.Validate

/-!
`AtlasBuilder.Domain` — Atlas Builder のドメインパック(抽出計画 §4.2)。

Looper 本体(`lean/Looper/**`)は製品トークンを持たない共有実装であり、製品ごとに
違う軸だけをこのファイルが与える。ここが**製品所有**の面である。
-/

namespace AtlasBuilder

/-- Atlas Builder が Looper へ注入するドメイン軸。 -/
def domain : Looper.Domain := {
  -- D-10: 綴りはこの 1 語幹から機械的に導く(表示名 `Atlas Builder`・ENV 接頭辞
  -- `ATLAS_BUILDER`・制御ルート名 `.atlas-builder`・commit trailer)。導出点を
  -- 増やさないために、綴りのフィールドを足す方向へは進めない。
  tool := "atlas-builder"
  -- 共通 4 面(spec / todo / recommendations / blockers)だけを持つ。
  extraLedgers := []
  -- 実装ドメインに固有の停止理由は無い(§13.1 の 13 語彙がすべて
  -- ドメイン非依存である)。
  domainStopReasons := []
  -- 実装への投影が主語なので、対象実装は Agent の作業面そのもの
  -- である(§11.1)。read-only 段は決定木に在るが常に通過する —
  -- 「段が無い」のではない(K-1)。
  writePolicy := .implementation
  -- ESSENCE.md の正準 H2 列(§2.1.1' の 9 節。この綴り・この順序)。
  essenceHeadings := ["モチベーション", "思想", "前提事項", "成功条件",
    "必須対応事項", "任意対応事項", "非対応事項", "遂行順序", "用語"]
  -- §2.1.2: 人間がスコープの柵を宣言する節。
  essenceWontHeading := "非対応事項"
  -- 実装ドメインは ESSENCE の節を特別扱いしない(検証ドメインの
  -- 「証明せず信頼するもの」に相当する錨が無い)。
  essenceTrustHeading? := none
  -- §16.1: 制御面 `.agent/state` は**全面**塞ぐ。`loop.drain` /
  -- `loop.status.json` の偽造不能性がここに乗っており、面を開けると
  -- ループの停止・排他の観測が Agent から書ける事実に化ける(D-18)。
  controlStateDenyWrite := [".agent/state"]
  controlStateDenyEdit := [".agent/state/**"]
  -- §11.2: Reservoir の定番以外に既定で信頼する Lake パッケージは無い。
  trustedLeanExtra := []
  -- ドメイン台帳を持たないので、検証 hook はどれも無作用である。
  -- **段は Looper 側に常設**であり、ここで空を返すのは「このドメインには
  -- 検査すべきドメイン台帳が無い」という事実の表明であって、段の削除ではない。
  gateLedgers := []
  evidenceLedgerTypes := []
  -- resume が次 cycle 限りで立てる承認マーカーを持たない(§13.4-7)。
  cycleAuthorizations := []
  ledgerShapeErrors := fun _ => []
  ledgerMeaningIssues := fun _ => {}
  observePaths := fun _ => []
  projectionRefusal := fun _ _ => none
  -- 停止・完了・表示・人間裁定のドメイン段も同じ理由で無作用である。段は
  -- Looper 側に常設で、ここが空を返すのは「実装ドメインにはファイル事実型の
  -- 追加 gate も、人間しか動かせない台帳 entry も無い」という事実の表明である。
  stopGates := fun _ => {}
  completionGates := fun _ => {}
  statusLines := fun _ => []
  -- §13.3: 人間裁定の専有フラグを持たない。`none` は「このドメインには人間しか
  -- 動かせない台帳 entry が無い」という事実の表明であり、CLI もフラグを綴らず
  -- 遷移核も裁定を受理しない。
  resumeAdjudication? := none
  -- §26.1: bootstrap が対象 root へ配る面。実装への投影は「人間が読む入口」
  -- (Essence と README)と、制御 state 面を履歴から外す ignore を配る。
  -- 対象の実装・CLAUDE.md / .claude/** には触れない(§5.0 / §17)。
  -- 散文の 2 面だけが PROJECT_TITLE 置換を通る。
  bootstrapSeeds :=
    [{ path := "ESSENCE.md", verbatim := false },
     { path := "README.md", verbatim := false },
     { path := ".gitignore", verbatim := true }]
}

-- 停止 payload のドメイン面は共通面のキーを名乗らない(名乗ると `get?` と `jq` が
-- 別の値を読む)。キーの集合は入力に依らないので probe 1 本で凍結できる。
private def gateProbe : Looper.GateInputs :=
  { ledgers := []
    specItems := []
    context := Looper.Core.Json.Value.obj []
    observations := [] }
private def stopGateProbe : Looper.StopGateInputs :=
  { toGateInputs := gateProbe, resumeHint := "" }
#guard (Looper.State.Predicates.stopPayloadCollisions
  (domain.stopGates stopGateProbe).payload).isEmpty
-- 承認マーカーも裁定チャネルも持たない。段は Looper 側に常設で、ここが空/none を
-- 返すのは「実装ドメインにはそれが無い」という事実の表明である。§31.1 R-13 の
-- 衝突検査は空の軸でも同じ形で置く — 軸を足した瞬間に効く。
#guard domain.cycleAuthorizations.isEmpty
#guard (Looper.State.Validate.cycleAuthorizationCollisions domain).isEmpty
#guard domain.resumeAdjudication?.isNone
-- 見出し列の包含と seed の床(fixture 側 #guard の鏡像)。Wont 節が列から落ちる
-- とスコープの柵(§2.1.2)が、成功条件節が落ちると受け入れ基準の抽出(§20.2-6)が、
-- 黙って空になる。bootstrap は最低限 ESSENCE.md を配る(§26.1)。
#guard domain.essenceHeadings.contains domain.essenceWontHeading
#guard domain.essenceHeadings.contains Looper.Core.Essence.essenceSuccessHeading
#guard domain.bootstrapSeeds.any (·.path == "ESSENCE.md")

end AtlasBuilder
