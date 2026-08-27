/-!
`Looper.State.Model` — Over-Project ループの状態語彙(純粋・依存なし)。

人間所有正本(`ESSENCE.md` / `essences/`)の観測結果型、state.py 由来の
既定値と閉集合、そして canonical id の形状検査を持つ。文書デコードの中立
プリミティブは `Looper.Core.Doc` にある — 本モジュールは In-Project ループ
(ASL)には現れない Over-Project 固有の語彙だけを集める。
-/

namespace Looper.State.Model

/-- ESSENCE.md の読み取り結果。sha256 はバイト列に対して計算するため
(Python `sha256_file` = `read_bytes`)、`String` ではなく `ByteArray` を
保持する。placeholder 判定(Python `read_text(encoding="utf-8")`)は
純粋側で UTF-8 化を試み、失敗は Python の UnicodeDecodeError と同じく
ハードエラーに写す。 -/
inductive EssenceRead where
  | absent
  | file (bytes : ByteArray)
  | ioError (msg : String)

/-- `PROJECT_ROOT/essences/` の観測(META.md §2.1.5)。ESSENCE.md と同格の
human-only 資産ディレクトリ(マークダウン外フォーマット・画像等)。IO シェルが
再帰的に(`Essence.maxAssetDepth` = 3 階層まで)観測し、パス昇順・dot 始まり
エントリ(`.DS_Store` 等)除外済みで渡す。
`files` の各要素は `(essences/ からの相対パス, 内容読み取り)` — SHA-256
マニフェスト(§13.1-10 の attestation 拡張)と整合検査が読む。`dirs` は観測
されたサブディレクトリの相対パス(祖先言及による orphan 充足と dangling 判定に
使う)。`tooDeep` は深さ上限を超えたエントリの相対パス(§2.1.5 の階層違反
検出用 — 内容は読まない)。`notDir` は essences が実在するがディレクトリでない
形状違反。 -/
inductive EssencesRead where
  | absent
  | notDir
  | dir (files : List (String × EssenceRead)) (dirs : List String)
      (tooDeep : List String)
  | ioError (msg : String)

/-- `[A-Za-z0-9_+-]`(id 本体の文字クラス。ASCII のみ — Python 側と同一)。 -/
def isIdChar (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')
    || c == '_' || c == '+' || c == '-'

/-- `re.fullmatch(f"{prefix}-[A-Za-z0-9_+-]+", value)` 等価(prefix は
リテラル解釈。実引数 S/T/R/B は正規表現メタ文字を含まない)。
`+` が合法なのは id が UTC オフセット付きローカル時刻を埋め込むため
(`R-LG-20260707T120000+0900-a1b2`、META.md §8.4-4・§21.5)。 -/
def validIdShape (pfx value : String) : Bool :=
  let pre := pfx ++ "-"
  value.startsWith pre &&
    (let rest := (value.drop pre.length).toString
     !rest.isEmpty && rest.toList.all isIdChar)


/-! ## 定数(state.py L132–198) -/

def defaultStopAfterIdleCycles : Int := 3
def defaultStopAfterInfraFails : Int := 2

/-- §13.1-12' の利用上限しきい値。infra(到達不能 = 環境が壊れている疑い)より
**寛容**にする: プラン利用上限は時間が解決する既知の一過性であり、loop 側の
指数バックオフ(§19.1-8)が待つ間の再試行回数がこの値になる。3 回の待機
(5 分 → 10 分 → 20 分)を経ても解けないとき初めて人間へ渡す。 -/
def defaultStopAfterUsageLimited : Int := 4
def defaultPhase : String := "must"
def phaseExtendedApproved : String := "extended_approved"
def phaseClosedAtMust : String := "closed_at_must"

/-- state.py `HUMAN_REVIEW_ACTIONS`。 -/
def humanReviewActions : List String := [
  "stop_until_human_review",
  "human_input_required",
  "requires_human_approval",
  "wait_for_human",
  "ask_human"
]

/-- state.py `FILL_MARKER`(§13.1-8)。対になる `PLACEHOLDER_MARKER` は製品綴りを
持つので `Looper.Domain.placeholderMarker` が語幹から導出する(抽出計画 D-10)—
本モジュールは製品を知らない語彙だけを持つ。 -/
def fillMarker : String := "<!-- FILL:"

/-! ## コンパイル時テスト -/

#guard validIdShape "S" "S-1" == true
#guard validIdShape "S" "S-" == false
#guard validIdShape "T" "T-a_b+c-d" == true
#guard validIdShape "R" "R-LG-20260707T120000+0900-a1b2" == true
#guard validIdShape "S" "S-あ" == false
#guard validIdShape "S" "s-1" == false
#guard validIdShape "S" "S-1 " == false
#guard validIdShape "S" "SX-1" == false

end Looper.State.Model
