import Looper.Core.Json
import Looper.Core.Doc
import Looper.Core.Essence
import Looper.Core.Sha256
import Looper.Domain
import Looper.State.Model

/-!
`Looper.State.Predicates` — state エンジンの read-only 判定核(純粋層)。

置換元(state.py、キー順・診断順・文言まで写す):
- `should_stop_payload`(L1714–1985)+ 依存述語群(`stop_after_idle_cycles` /
  `stop_after_infra_fails` / `recommendation_requires_human` /
  `essence_review_baseline` / `essence_is_placeholder`)
- `completion_state`(L2103–2162)+ `context_phase` / `todo_is_runnable` /
  `must_phase_complete_from` / `essence_projection_drift`
- `cmd_should_reset`(L2431–2459)

fail-open / fail-closed の対応(§31.5、I-021):
- should-stop / should-complete は gate 判定 — 読めない gate 保持ファイルは
  `state_unreadable` 診断へ写し停止側に倒す(`gateFile` / `gateJsonl`)。
- should-reset は fail-open — 破損 context は空として評価し reset しない。
  ただし `counters` / `reset_policy` の形状崩れと比較不能な型の組は Python の
  uncaught TypeError(exit 2)に対応する `.error`(ハードエラー)であり、
  「no」とは決して読まない(I-021 の exit-code 規律)。
- ESSENCE.md が「存在するのに読めない/不正 UTF-8」も Python の uncaught
  OSError / UnicodeDecodeError に対応する `.error`。

証明層の S-T1〜S-T3(gate-holding unreadable ⇒ stop、mustPhaseComplete の
整合)は本モジュールの `shouldStopPayload` / `completionPayload` を対象に
証明する。
-/

namespace Looper.State.Predicates

open Looper.Core
open Looper.Core.Doc
open Looper.State.Model

/-! ## 共有述語(state.py L1602–1711) -/

/-- completion phase。`extended_approved` と、人間が should 予算を明示的に
辞退した `closed_at_must` だけを認識し、その他(欠落・非文字列・未知値)は
安全側の `must` に倒す。 -/
def contextPhase (context : Json.Value) : String :=
  if context.get? "phase" == some (.str phaseExtendedApproved) then
    phaseExtendedApproved
  else if context.get? "phase" == some (.str phaseClosedAtMust) then
    phaseClosedAtMust
  else
    defaultPhase

/-- Python `todo_is_runnable`(§19.3): status ∈ {pending, in_progress} かつ
executor.mode == `d.tool`(§9.1 の executor 語彙)かつ(承認済み phase または
must)。executor が object でない・mode 欠落は runnable でない(fail closed —
既定値で補わない)。 -/
def todoIsRunnable (d : Domain) (t : Json.Value)
    (phase : String := defaultPhase) : Bool :=
  let status := t.get? "status"
  (status == some (.str "pending") || status == some (.str "in_progress"))
    && ((t.get? "executor").bind (·.get? "mode")) == some (.str d.tool)
    && (phase == phaseExtendedApproved || t.get? "priority" == some (.str "must"))

/-- `full_complete` が認める Todo の解決済み状態。

`done` は evidence 検査を validate が担う。`canceled` は単なる非 runnable 状態を
完了へ読み替えないため、誰が・なぜ取り消したかを必須にする。人間の明示判断、
または人間確認済み Essence の再投影だけが正当な取消由来である。 -/
def todoIsResolved (t : Json.Value) : Bool :=
  if t.get? "status" == some (.str "done") then
    true
  else if t.get? "status" == some (.str "canceled") then
    let byOk := t.get? "canceled_by" == some (.str "human")
      || t.get? "canceled_by" == some (.str "essence_projection")
    let reasonOk := match t.get? "canceled_reason" with
      | some (.str s) => !(Text.pyStrip s).isEmpty
      | _ => false
    byOk && reasonOk
  else
    false

/-- Python `must_phase_complete_from`(§19.3 の単一定義): items が存在し、
must が 1 件以上あり、drift も unreadable もなく、全 must が done。 -/
def mustPhaseCompleteFrom (items : List Json.Value) (drift : Bool)
    (unreadable : List String) : Bool :=
  let musts := items.filter (·.get? "priority" == some (.str "must"))
  unreadable.isEmpty && !drift && !items.isEmpty && !musts.isEmpty
    && musts.all (·.get? "status" == some (.str "done"))

/-- Python `recommendation_requires_human`(§21.1): proposed のみ gate。
`is True` は bool の true のみ(truthy な 1 等は含まない)。`agent_action` は
文字列で `HUMAN_REVIEW_ACTIONS` に含まれるときだけ真。 -/
def recommendationRequiresHuman (rec : Json.Value) : Bool :=
  rec.get? "status" == some (.str "proposed")
    && (rec.get? "requires_human_approval" == some (.bool true)
      || rec.get? "human_input_required" == some (.bool true)
      || (match rec.get? "agent_action" with
          | some (.str a) => humanReviewActions.contains a
          | _ => false)
      || rec.get? "type" == some (.str "Human-input Recommendation"))

/-- supervise authorizing gate(§12.1・§21.3)の**単一定義**: この
Recommendation を `--recommendation` に渡した `just supervise` が preflight
(`Supervise.preflight`)を**現に通る**とき、その対象 Todo id を返す。
受理集合の一致は Supervise 側の #guard が凍結する — ここで条件を 1 つでも
複製し損ねると、「resume が守る gate」と「supervise が使える gate」がずれ、
どちらかの側に 2026-08-04 の実障害(承認時 resolve で binding が自壊し、
`just supervise --todo T-001 --recommendation R-001` が
『not an open human approval gate』で恒久に拒否される)が再発する。

用途は 2 つで、必ず同じ述語を見る(§13.3-4''):
1. `Resume.selectionError?` — この gate の「答え」は resolve ではなく
   supervise の実行なので、素の resume を強制拒否させる集合から除外し、
   `--resolve` は拒否(明示の `--retract-approval` だけが閉じられる)。
2. 停止 message(`stopAssemble`)— `--resolve` ではなく
   `just supervise --todo <T> --recommendation <R>` を案内する。 -/
def superviseAuthorizedTodo? (d : Domain) (rec : Json.Value)
    (todoItems : List Json.Value) : Option String :=
  -- preflight の各拒否条件を Option の失敗に写す(control 文字検査まで含めて
  -- 同値 — preflight が拒否する組は「使える binding」ではないので守らない)。
  let nonEmpty? (v : Option Json.Value) : Option String :=
    match v with
    | some (.str s) =>
      let s := Text.pyStrip s
      if s.isEmpty then none else some s
    | _ => none
  let target? (item : Json.Value) : Option String := do
    let t ← nonEmpty? (item.get? "target")
    if t.toList.any (fun c => c.toNat < 32 || c.toNat == 127) then none
    else some t
  if !recommendationRequiresHuman rec then none
  else do
    let recTarget ← target? rec
    let sources ← match rec.get? "source" with
      | some (.arr vs) => vs.mapM fun v => nonEmpty? (some v)
      | _ => none
    sources.find? fun todoId =>
      match todoItems.filter (·.get? "id" == some (.str todoId)) with
      | [todo@(.obj _)] =>
        todo.get? "risk_level" == some (.str "high")
          && (nonEmpty? (todo.get? "risk_reason")).isSome
          && target? todo == some recTarget
          && (match nonEmpty? (todo.get? "status") with
              | some s => ["pending", "in_progress", "blocked"].contains s
              | none => false)
          && ((todo.get? "executor").bind (·.get? "mode"))
              == some (.str d.tool)
      | _ => false

/-- `superviseAuthorizedTodo?` の (rec id, todo id) 対を open な gate 群から
集める(resume の受理集合と停止 message が共有する形)。 -/
def superviseAuthorizations (d : Domain) (openRecs todoItems : List Json.Value) :
    List (String × String) :=
  openRecs.filterMap fun r => do
    let id ← match r.get? "id" with
      | some (.str id) => some id
      | _ => none
    let todoId ← superviseAuthorizedTodo? d r todoItems
    pure (id, todoId)

/-- framework が実体化した must 境界 gate Recommendation の形(§21.5-1)。
**単一定義**である: resume の選択側(`Resume.isPhaseGateRec`)と、停止 message
が案内する受理形の算出(§13.4-2)が同じ 1 つの述語を見る — 案内側だけが独自に
判定すると「`--resolve` で解除できない gate を `--resolve` で案内する」ずれが
生まれる(素の `--resolve` は §13.3-4' で拒否される)。
なお本述語は「open か」を含まない(呼び出し側が open 判定と連言する)。 -/
def isPhaseGateRecommendation (d : Domain) (rec : Json.Value) : Bool :=
  rec.get? "gate" == some (.str "must_complete_awaiting_phase_approval")
    && rec.get? "raised_by" == some (.str d.loopActor)

/-- Python `recommendation_gates_loop`(§21.1)。 -/
def recommendationGatesLoop (rec : Json.Value) : Bool :=
  (rec.get? "type" == some (.str "Blocking Recommendation")
      && rec.get? "status" == some (.str "proposed"))
    || recommendationRequiresHuman rec

/-- Python `stop_after_idle_cycles` / `stop_after_infra_fails` の共通形。
形状破損は診断に落として既定値へフォールバックする(gate は corruption が
state_unreadable として表面化する間も働き続ける、I-021)。`stop_policy` の
非 object 診断は idle 側だけが出す(infra 側は同一破損の重複報告を避ける)。
**非正の値は未設定として既定値**(Python `value or DEFAULT` の `0` に加えて
負値も含む): カウンタは 0 未満になれないので、負の閾値は resume が
カウンタを 0 に戻しても(S-T6)決して下回れない — どの resume 形でも解除
できない停止、つまり「停止は必ず再開手順とともに可視」(I-017)の破れになる。 -/
def stopThreshold (context : Json.Value) (key : String) (dflt : Int)
    (reportPolicyShape : Bool) : Int × List String :=
  let (policy, policyDiags) :=
    match context.get? "stop_policy" with
    | none | some .null => (Json.Value.obj [], [])
    | some (.obj entries) => (Json.Value.obj entries, [])
    | some _ =>
      (Json.Value.obj [],
        if reportPolicyShape then ["context.json: stop_policy is not an object"]
        else [])
  let (value, valueDiags) :=
    match policy.get? key with
    | none | some .null => ((0 : Int), [])
    | some v =>
      match pyInt? v with
      | some n => (n, [])
      | none => (0, [s!"context.json: stop_policy.{key} is not an integer"])
  (if value ≤ 0 then dflt else value, policyDiags ++ valueDiags)

/-! ## gate ファイル読み(should_stop_payload 内部関数、I-021 fail-closed) -/

/-- Python `gate_file`: 初期化済み state dir からの欠落は unparseable と同じ
corruption class(診断 + unreadable)、bootstrap 前の欠落は正常な空。
返り値は (payload, readable, 診断)。 -/
def gateFile (initialized : Bool) (name : String) (raw : RawFile) :
    Json.Value × Bool × List String :=
  match raw with
  | .absent =>
    if initialized then
      (.obj [], false, [s!"{name}: missing from the initialized state directory"])
    else
      (.obj [], false, [])
  | raw =>
    match readJsonOrEmpty name raw with
    | (_, some diag) => (.obj [], false, [diag])
    | (payload, none) => (payload, true, [])

/-- JSONL の gate 検査(reflection.jsonl / runs.jsonl): 読めるかだけを確認し、
内容は使わない。欠落・破損の扱いは `gateFile` と同じ(I-021)。 -/
def gateJsonl (initialized : Bool) (name : String) (raw : RawFile) : List String :=
  match raw with
  | .absent =>
    if initialized then [s!"{name}: missing from the initialized state directory"]
    else []
  | raw =>
    match readJsonlOrEmpty name raw with
    | (_, some diag) => [diag]
    | (_, none) => []

/-- Python `gate_items`(I-021 shape hardening): 読めたのに `items` が list
でない(bare `{}` 含む)のは corruption であり「no gates」ではない。 -/
def gateItems (payload : Json.Value) (name : String) (readable : Bool) :
    List Json.Value × List String :=
  if !readable then ([], [])
  else
    match payload.get? "items" with
    | some (.arr items) => (objectItems (.arr items), [])
    | _ => ([], [s!"{name}: items is missing or not a list"])

/-- Python `progress.get(...)` + `int(...)` の fail-closed カウンタ読み:
欠落・null は 0、非整数は診断(state_unreadable として停止)+ 0。 -/
def progressCounter (progress : Json.Value) (key : String) : Int × List String :=
  match progress.get? key with
  | none | some .null => (0, [])
  | some v =>
    match pyInt? v with
    | some n => (n, [])
    | none => (0, [s!"context.json: progress.{key} is not an integer"])

/-! ## ESSENCE.md(state.py L316–337) -/

/-- Python `sha256_file(ctx.essence)`: 不在は `none`、読めた内容のバイト列の
SHA-256 hex。「存在するのに読めない」は uncaught OSError(exit 2)に対応する
ハードエラー。 -/
def essenceSha256 : EssenceRead → Except String (Option String)
  | .absent => .ok none
  | .file bytes => .ok (some (Sha256.hexDigest bytes))
  | .ioError e => .error s!"ESSENCE.md is unreadable ({e})"

/-- §13.1-8 の placeholder 判定本体(空・空白のみ・placeholder マーカー・
未消化 FILL マーカー)。`essenceIsPlaceholder`(停止理由)と `essenceRealText?`
(実体を持つときだけ走る検査の門)が**同一の条件**を共有するための単一定義。 -/
def isPlaceholderText (d : Domain) (text : String) : Bool :=
  Text.containsSub text d.placeholderMarker
    || (Text.pyStrip text).isEmpty
    || Text.containsSub text fillMarker

/-- Python `essence_is_placeholder`(§13.1-8): ガイドブロック残存・空白のみ・
未消化 FILL マーカーのいずれか。OSError(不在・読めない)は False。
不正 UTF-8 は Python の uncaught UnicodeDecodeError(exit 2)に対応する
ハードエラー。 -/
def essenceIsPlaceholder (d : Domain) : EssenceRead → Except String Bool
  | .absent => .ok false
  | .ioError _ => .ok false
  | .file bytes =>
    match String.fromUTF8? bytes with
    | none => .error "ESSENCE.md is not valid UTF-8"
    | some text => .ok (isPlaceholderText d text)

/-- human-review baseline(§13.1-10): ESSENCE.md の SHA-256 と、essences/
資産マニフェスト(相対パス → SHA-256、パス昇順)。同一の attestation レコード
(または project.json anchor)から採る — 別レコードの sha と manifest を
混ぜない。 -/
structure EssenceBaseline where
  sha? : Option String
  assets : List (String × String)
  deriving BEq

/-- attestation レコード / project.json の `essences` / `essences_manifest`
object を manifest(名前昇順)へ。非 object・非文字列値は無視(後方互換:
キー不在の旧レコードは「essences なしで attest」= 空マニフェスト)。 -/
def assetsManifestOfJson : Json.Value → List (String × String)
  | .obj entries =>
    (entries.filterMap fun (k, v) =>
      match v with
      | .str s => some (k, s)
      | _ => none).mergeSort (fun a b => a.1 ≤ b.1)
  | _ => []

/-- manifest の JSON 表現(payload / attestation レコード用)。 -/
def assetsManifestJson (m : List (String × String)) : Json.Value :=
  .obj (m.map fun (k, v) => (k, .str v))

/-- Python `essence_review_baseline`(§13.1-10): attestation ledger の
最後の一致(`project` が一致し `essence_sha256` が非空文字列)、なければ
project.json の ensure 時 anchor。agent-writable な reflection.jsonl は
信頼しない。essences マニフェストは同じレコードの `essences`(anchor 側は
`essences_manifest`)から採る。診断(ledger / project.json の読取失敗)は
呼び出し側の unreadable に合流する。 -/
def essenceReviewBaseline (attestations project : RawFile) (title : String) :
    EssenceBaseline × List String :=
  let (records, ledgerDiag) :=
    readJsonlOrEmpty "essence_attestations.jsonl" attestations
  let hit := records.foldl (init := (none : Option Json.Value)) fun acc r =>
    match r.get? "essence_sha256" with
    | some (.str s) =>
      if r.get? "project" == some (.str title) && !(Text.pyStrip s).isEmpty then
        some r
      else acc
    | _ => acc
  match hit with
  | some r =>
    let sha? := match r.get? "essence_sha256" with
      | some (.str s) => some s
      | _ => none
    ({ sha?, assets := assetsManifestOfJson ((r.get? "essences").getD .null) },
      ledgerDiag.toList)
  | none =>
    let (projectJson, projDiag) := readJsonOrEmpty "project.json" project
    let anchor :=
      match projectJson.get? "essence_sha256" with
      | some (.str s) => if (Text.pyStrip s).isEmpty then none else some s
      | _ => none
    ({ sha? := anchor,
       assets := assetsManifestOfJson
         ((projectJson.get? "essences_manifest").getD .null) },
      ledgerDiag.toList ++ projDiag.toList)

/-- 「実体を持つ ESSENCE.md の本文」。不在・読取不能・不正 UTF-8・placeholder
(§13.1-8)はすべて `none`。placeholder の条件は `essenceIsPlaceholder` と同一で
あり、この関数は「Essence が実体を持つときだけ走らせる検査」— §2.1.5 の言及
検査と §13.1-15 の見出し構造検査 — の共通の門になる。空ファイルやテンプレート
に対する診断はノイズにしかならず、そこはより高優先の停止理由が既にゲート
している。 -/
def essenceRealText? (d : Domain) : EssenceRead → Option String
  | .file bytes =>
    match String.fromUTF8? bytes with
    | some text => if isPlaceholderText d text then none else some text
    | none => none
  | _ => none

/-! ## ESSENCE.md 見出し構造(§2.1.1'・§13.1-15) -/

/-- ESSENCE.md の見出し骨格が正準見出し契約に反する点の列挙(空リスト = 適合)。
判定そのものは `Essence.essenceStructureIssues` の 1 箇所にあり、should-stop
(`stopAssemble`)と validate(`Validate.essenceStructureErrors`)はこの同じ
関数を共有する — 判定ロジックを複製すると `just status` と述語が食い違った
2026-08-02 と同型の不一致バグを招く(Status.lean の由来コメント参照)。
missing / placeholder の間は検査を保留する(`essenceRealText?`)。 -/
def essenceStructureIssues (d : Domain) (essence : EssenceRead) : List String :=
  match essenceRealText? d essence with
  | some text => Essence.essenceStructureIssues d text
  | none => []

/-! ## essences/(§2.1.5・§13.1-14・§13.1-10 拡張) -/

/-- essences/ の現況マニフェスト(`essences/` からの相対パス → SHA-256、
パス昇順)。ファイル・ディレクトリの読取不能は fail-closed のハードエラー
(exit 2、I-021 の exit-code 規律 — 読めない資産を「変更なし」とは決して
読まない)。`notDir` は構造違反として `essenceAssetIssues` が報告するため、
マニフェストは空。深さ上限超過エントリ(`tooDeep`)も構造違反側で報告され、
内容は読まないためマニフェストに現れない。 -/
def essencesManifest : EssencesRead → Except String (List (String × String))
  | .absent => .ok []
  | .notDir => .ok []
  | .ioError e => .error s!"essences/ is unreadable ({e})"
  | .dir files _ _ => do
    let entries ← files.mapM fun entry =>
      match entry with
      | (name, EssenceRead.file bytes) =>
        Except.ok (name, Sha256.hexDigest bytes)
      | (name, EssenceRead.ioError e) =>
        Except.error s!"essences/{name} is unreadable ({e})"
      | (name, EssenceRead.absent) =>
        Except.error s!"essences/{name} is unreadable (vanished mid-scan)"
    pure (entries.mergeSort (fun a b => a.1 ≤ b.1))

/-- ESSENCE.md ⇄ essences/ の双方向整合(§2.1.5): 形状違反(非ディレクトリ・
階層上限超過・不正パス)、orphan(実在するのに ESSENCE.md が言及しない
ファイル)、dangling(言及されるのに実在しないパス)。
資産は `essences/` からの相対パスで識別し、`Essence.maxAssetDepth`(3)階層まで
入れ子にできる。orphan 判定では**祖先ディレクトリの言及が配下の資産を覆う**
(`essences/input/` の 1 行で `input/` 配下すべてが充足)。dangling 判定では
言及トークンがファイルでもディレクトリでも実在すればよい。
ESSENCE.md 本文が読めない(不在・読取不能・不正 UTF-8)か placeholder のまま
(§13.1-8 — テンプレートは言及を持たず、orphan の偽陽性になる)の間は言及
検査を保留する(essence_missing / essence_placeholder / ハードエラーが先に
立つ)— 形状違反は常に検査する。 -/
def essenceAssetIssues (d : Domain) (essence : EssenceRead)
    (assets : EssencesRead) : List String :=
  let mentions? : Option (List String) :=
    (essenceRealText? d essence).map Essence.essenceAssetMentions
  let (structureIssues, entries?) :
      List String × Option (List String × List String) :=
    match assets with
    | .absent => ([], some ([], []))
    | .ioError _ => ([], none)   -- 読取不能はハードエラー側(essencesManifest)
    | .notDir =>
      (["essences exists in PROJECT_ROOT but is not a directory; "
          ++ "PROJECT_ROOT/essences/ is the human-owned asset directory "
          ++ "(§2.1.5)."], some ([], []))
    | .dir files dirs tooDeep =>
      let depthIssues := tooDeep.map fun p =>
        s!"essences/{p} is nested deeper than the {Essence.maxAssetDepth}-level "
          ++ s!"limit; a path under essences/ may have at most "
          ++ s!"{Essence.maxAssetDepth} segments (§2.1.5)."
      let names : List String := files.map (·.1)
      let pathIssues := (names ++ dirs).filterMap fun p =>
        if Essence.validAssetPath p then none
        else some (s!"essences/{p} has an unsupported path; essences/ path "
          ++ "segments use [A-Za-z0-9._-] and must not start or end with '.' "
          ++ "(§2.1.5).")
      (depthIssues ++ pathIssues,
        some (names.mergeSort (· ≤ ·), dirs.mergeSort (· ≤ ·)))
  let mentionIssues :=
    match mentions?, entries? with
    | some mentions, some (filePaths, dirPaths) =>
      let orphans := filePaths.filterMap fun path =>
        if Essence.validAssetPath path
            && !(path :: Essence.assetPathAncestors path).any mentions.contains then
          some (s!"essences/{path} is not mentioned in ESSENCE.md; every "
            ++ s!"essences/ asset must be referenced by its exact "
            ++ s!"'essences/{path}' path, or by one of its parent directories "
            ++ "(§2.1.5).")
        else none
      let danglings := mentions.filterMap fun tok =>
        if filePaths.contains tok || dirPaths.contains tok then none
        else some (s!"ESSENCE.md mentions essences/{tok} but no such file or "
          ++ "directory exists in essences/ (§2.1.5).")
      orphans ++ danglings
    | _, _ => []
  structureIssues ++ mentionIssues

/-! ## ドメイン台帳の読みと hook 入力の組み立て

**ドメインは canonical state を再パースしない**(抽出計画 D-22): 読み取りと
JSON 解釈は Looper が済ませ、hook には解釈済みの観測だけを渡す。読み方が
2 系統に割れると、片方だけが fail-safe を持つ事故になる。 -/

/-- ドメイン台帳の生読み取りの引き当て(名簿に無い面は `.absent` — 欠落面の
扱いは共通面と同じく `gateFile` / `readJsonOrEmpty` が決める)。 -/
def ledgerRawOf (ledgers : List (String × RawFile)) (name : String) : RawFile :=
  ((ledgers.find? (·.1 == name)).map (·.2)).getD .absent

/-- ドメイン台帳(`Domain.extraLedgers` の全面)の parse 済み文書。順序は軸から
引き直すので、生読み取りの列は集合として持てばよい。 -/
def ledgerDocsOf (d : Domain) (ledgers : List (String × RawFile)) :
    List (String × Json.Value) :=
  d.extraLedgers.map fun n =>
    (n ++ ".json", (readJsonOrEmpty (n ++ ".json") (ledgerRawOf ledgers (n ++ ".json"))).1)

/-- gate 保持面に加わるドメイン台帳(`Domain.gateLedgers`)の読取診断
(`gateFile` 系 — 初期化済み state からの欠落も corruption、I-021)。
**面の集合だけがドメイン軸で決まり、扱いは共通面と同一**である。 -/
def gateLedgerDiagnostics (d : Domain) (initialized : Bool)
    (ledgers : List (String × RawFile)) : List String :=
  d.gateLedgers.flatMap fun n =>
    (gateFile initialized (n ++ ".json") (ledgerRawOf ledgers (n ++ ".json"))).2.2

/-- 同じ面の `readJsonOrEmpty` 系診断(欠落は診断にしない — completion 側は
`ctx.state_dir` の初期化を観測していないので、共通面と同じ読み方に揃える)。 -/
def gateLedgerReadDiagnostics (d : Domain) (ledgers : List (String × RawFile)) :
    List String :=
  d.gateLedgers.filterMap fun n =>
    (readJsonOrEmpty (n ++ ".json") (ledgerRawOf ledgers (n ++ ".json"))).2

/-! ## should-complete(state.py `completion_state` L2103–2162) -/

structure CompletionInputs where
  /-- 製品(ドメインパック)が注入する軸(抽出計画 D-9)。`todoIsRunnable` の
  executor 語彙がここから決まる。**既定値を置かない**(`StopInputs.domain`
  と同じ理由)。 -/
  domain : Domain
  todo : RawFile
  spec : RawFile
  context : RawFile
  essence : EssenceRead
  /-- ドメイン台帳(`Domain.extraLedgers` の各面、キーは `<面>.json`)の生
  読み取り。gate 保持面(`Domain.gateLedgers`)の読めなさは共通面と同じく
  `state_unreadable` へ写り、完了を証明しない側に倒れる(I-021)。 -/
  ledgers : List (String × RawFile)
  /-- `Domain.observePaths` が要求した作業ツリー観測(対象 root 相対パス →
  生バイト列の `sha256:<hex>`、不在は none)。`StopInputs.essencesDir` と
  同じ理由で既定値を持たない — 注入忘れが「観測できなかった」として静かに
  成立してはならない。 -/
  observations : List (String × Option String)

structure CompletionVerdict where
  payload : Json.Value
  complete : Bool
  awaitingPhaseApproval : Bool

private def intVal (n : Int) : Json.Value := .num n 0
private def natVal (n : Nat) : Json.Value := .num (Int.ofNat n) 0

/-- ドメイン hook へ渡す観測の組み立て。**消費点の内側に `let` で埋めない** —
定理が巨大な匿名式を書き下ろす羽目になり、hook の入力が変わるたびに言明が
壊れる(7b の `Validate.ledgerInputsOf` と同じ理由)。 -/
def gateInputsOf (d : Domain) (ledgers : List (String × RawFile)) (spec : RawFile)
    (context : Json.Value) (observations : List (String × Option String)) :
    GateInputs :=
  { ledgers := ledgerDocsOf d ledgers
    specItems := objectItems
      (((readJsonOrEmpty "spec.json" spec).1.get? "items").getD (.arr []))
    context, observations }

/-- `completionPayload` が評価するドメインの完了寄与(§19.3)。 -/
def domainCompletionGates (i : CompletionInputs) : CompletionGates :=
  i.domain.completionGates (gateInputsOf i.domain i.ledgers i.spec
    (readJsonOrEmpty "context.json" i.context).1 i.observations)

/-- 二段階の完了セマンティクス(§19.3)。must_phase_complete は phase gate。
人間は (a) should phase を承認して全 should を明示解決する、または
(b) should 予算を辞退して must scope で閉じる、のどちらかを選ぶ。
「runnable が無い」だけでは blocked / human-executor を COMPLETE にしない。破損した
spec/todo は診断(`state_unreadable`)へ集約され、決して完了を証明しない
(I-021)。診断の蓄積順は Python と同一: todo → context → spec。

**resume note 未消費ガード(§19.3)**: gate release resume は handoff に
`pending_cycle` を立て、その note を消費する cycle(record-progress の
`--run-status ok`)だけが下ろす。立っている間 `full_complete` は成立しない —
「全 Todo done + gate 解除済み」が resume note の指示(次 cycle での再投影
など)を 1 cycle も走らせずに COMPLETE へ素通りする deadlock を封じる。
判定は truthy(bool true 以外の残骸も完了を証明しない側に倒す — I-021 と
同じ向き)。

**ドメインの寄与(`Domain.completionGates`)は 2 口**である: must フェーズ完了の
追加条件(台帳結線のような「must Spec が被覆されている」)と、完了そのものの
封止(承認済みの再検証が 1 cycle も走らないまま COMPLETE へ素通りしない)。
前者は `mustPhaseComplete` の論理積に、後者は `full_complete` の論理積に入る —
**同じ口に畳まない**: 前者は phase 境界(`awaiting_phase_approval`)にも効くが、
後者は境界を出させたうえで完了だけを止めるからである。 -/
def completionPayload (i : CompletionInputs) : Except String CompletionVerdict := do
  let (todo, todoDiag) := readJsonOrEmpty "todo.json" i.todo
  let (context, contextDiag) := readJsonOrEmpty "context.json" i.context
  -- essence_projection_drift(L1623–1628): spec の記録 hash と現在 hash の比較
  let (spec, specDiag) := readJsonOrEmpty "spec.json" i.spec
  let currentEssence ← essenceSha256 i.essence
  let recorded := spec.get? "projected_from_essence_sha256"
  let drift :=
    match currentEssence, recorded with
    | some current, some rec => rec.truthy && rec != .str current
    | _, _ => false
  let diagnostics := todoDiag.toList ++ contextDiag.toList ++ specDiag.toList
    ++ gateLedgerReadDiagnostics i.domain i.ledgers
  let items := objectItems ((todo.get? "items").getD (.arr []))
  let musts := items.filter (·.get? "priority" == some (.str "must"))
  let shoulds := items.filter (·.get? "priority" == some (.str "should"))
  let phase := contextPhase context
  let gates := domainCompletionGates i
  let mustPhaseComplete := mustPhaseCompleteFrom items drift diagnostics
    && gates.mustPhaseComplete
  let runnableShoulds := items.filter fun t =>
    t.get? "priority" == some (.str "should") && todoIsRunnable i.domain t phase
  let resolvedShoulds := shoulds.filter todoIsResolved
  -- 「must でない未解決 Todo」全体を数える(should に限らない): priority を
  -- 欠く/集合外の Todo は apply-projection では書けないが(validate error)、
  -- 外因破損で紛れ込んだ場合に「should でないから」と完了計算から消えると、
  -- runnable な Todo を残したまま full_complete が立つ — §19.3 の双対性
  -- (「実行可能な Todo が尽きたときの終端は 3 択」)と I-021 の向き(壊れた
  -- state は完了を証明しない)の両方に反する。
  let unresolvedShoulds := items.filter fun t =>
    t.get? "priority" != some (.str "must") && !todoIsResolved t
  let phaseApproved := phase == phaseExtendedApproved
  let closedAtMust := phase == phaseClosedAtMust
  let resumePending :=
    (((context.get? "handoff").getD .null).get? "pending_cycle"
      |>.map (·.truthy)).getD false
  let extendedComplete := mustPhaseComplete && phaseApproved && unresolvedShoulds.isEmpty
  let mustScopeComplete := mustPhaseComplete && closedAtMust
  let fullComplete := (extendedComplete || mustScopeComplete) && !resumePending
    && !gates.sealsCompletion
  let awaiting := mustPhaseComplete && phase == defaultPhase
  let completionScope := if !fullComplete then "none"
    else if mustScopeComplete then "must" else "extended"
  let payload : Json.Value := .obj ([
    ("should_complete", .bool fullComplete),
    ("must_phase_complete", .bool mustPhaseComplete),
    ("full_complete", .bool fullComplete),
    ("completion_scope", .str completionScope),
    ("phase", .str phase),
    ("awaiting_phase_approval", .bool awaiting),
    ("resume_pending_cycle", .bool resumePending)
  ] ++ gates.payload ++ [
    ("must_total", natVal musts.length),
    ("must_done", natVal (musts.filter (·.get? "status" == some (.str "done"))).length),
    ("runnable_should_total", natVal runnableShoulds.length),
    ("should_total", natVal shoulds.length),
    ("resolved_should_total", natVal resolvedShoulds.length),
    ("unresolved_should_total", natVal unresolvedShoulds.length),
    ("todo_total", natVal items.length),
    ("essence_projection_drift", .bool drift),
    ("current_essence_sha256", (currentEssence.map Json.Value.str).getD .null),
    ("projected_from_essence_sha256", recorded.getD .null),
    ("state_unreadable", .arr (diagnostics.map .str))
  ])
  pure { payload, complete := fullComplete, awaitingPhaseApproval := awaiting }

/-! ## should-stop(state.py `should_stop_payload` L1714–1985) -/

structure StopInputs where
  /-- 製品(ドメインパック)が注入する軸(抽出計画 D-9)。executor 語彙・
  診断文言・gate の名乗りの綴りはすべてここから導出する。**既定値を置かない**
  — 既定は注入し忘れを黙って通す穴である。 -/
  domain : Domain
  /-- `ctx.state_dir.is_dir()`(bootstrap 済みか)。 -/
  stateInitialized : Bool
  blockers : RawFile
  recommendations : RawFile
  context : RawFile
  project : RawFile
  reflection : RawFile
  runs : RawFile
  /-- ドメイン台帳(`Domain.extraLedgers` の各面、キーは `<面>.json`)の生
  読み取り。うち gate 保持面(`Domain.gateLedgers`)は共通 7 面と同じ I-021 の
  扱いを受け、読めなさは `state_unreadable` へ写る。 -/
  ledgers : List (String × RawFile)
  /-- `Domain.observePaths` が要求した作業ツリー観測(対象 root 相対パス →
  生バイト列の `sha256:<hex>`、不在は none)。既定値を持たない — 注入忘れの
  構築点はコンパイルで落ちる(`essencesDir` と同じ規律)。 -/
  observations : List (String × Option String)
  /-- CONTROL_ROOT 側 attestation ledger(`essence_attestations.jsonl`)。 -/
  attestations : RawFile
  spec : RawFile
  todo : RawFile
  essence : EssenceRead
  /-- `PROJECT_ROOT/essences/` の観測(§2.1.5)。既定値は持たない — gate が
  依存する human-owned 面の観測に既定値を与えると、注入を忘れた構築点が
  「型は通るが essences/ を不在として評価する」形で成立してしまう(実際に
  status 表示がその形で全資産 removed / 全言及 dangling を報告した)。
  必須フィールドにしておけば、観測を渡さない構築点はコンパイルで落ちる。 -/
  essencesDir : EssencesRead
  /-- `ctx.title`(ledger レコードの `project` 照合)。 -/
  projectTitle : String

structure StopVerdict where
  payload : Json.Value
  stop : Bool

/-- message 用の Recommendation/Blocker id: 欠落は `"?"`。非文字列 id は
Python の `", ".join(...)` が投げる uncaught TypeError(exit 2)に対応する
ハードエラー。 -/
private def idForMessage (item : Json.Value) : Except String String :=
  match item.get? "id" with
  | none => .ok "?"
  | some (.str s) => .ok s
  | some _ => .error "sequence item in id join: expected str instance"

/-- payload 用の id 列: 欠落は null、値は生のまま(Python `r.get("id")`)。 -/
private def idsForPayload (items : List Json.Value) : Json.Value :=
  .arr (items.map fun item => (item.get? "id").getD .null)

/-- 反復可能な `--resolve <ID>` の綴り(§13.3-4 が受理する exact 形)。停止
message はこの 1 箇所からしか案内形を作らない(§13.4-2)。 -/
private def resolveFlags (ids : List String) : String :=
  String.intercalate " " (ids.map fun id => s!"--resolve {id}")

/-! `should_stop_payload` の純粋核は、S-T1 の証明対象形(§31.3)として
「読取・診断合流・組み立て」を名前付き関数に分離して構成する。分離は挙動を
一切変えない(合流順・reasons/message/payload の構成は Python と同一のまま)。
共有前段(gateFile / progressOf)の再計算は純粋関数の参照透過性により
無害で、対象ファイルは小さくコストは無視できる。 -/

/-- progress object の取り出し(readable な context に progress object が
無いのは gate の喪失 — I-021 shape hardening)。 -/
def progressOf (contextJson : Json.Value) (readable : Bool) :
    Json.Value × List String :=
  if !readable then (.obj [], [])
  else
    match contextJson.get? "progress" with
    | some (.obj entries) => (.obj entries, [])
    | _ => (.obj [], ["context.json: progress is missing or not an object"])

/-- gate 保持面の全診断の合流列(dedup 前)。蓄積順は Python の評価順そのもの
(dedup が出現順を保つため、順序は挙動の一部)。射影スタイル(match 塔なし)で
書く — S-T1 が「gate 読取面のいずれかの診断 ⇒ 非空」を成分単位で示せる形。
面の集合は共通 7 面 + ドメインの `gateLedgers` である。 -/
def unreadableDiagnostics (i : StopInputs) : List String :=
  let blockers := gateFile i.stateInitialized "blockers.json" i.blockers
  let recs := gateFile i.stateInitialized "recommendations.json" i.recommendations
  let context := gateFile i.stateInitialized "context.json" i.context
  let progress := progressOf context.1 context.2.1
  blockers.2.2 ++ recs.2.2 ++ context.2.2
    ++ gateJsonl i.stateInitialized "reflection.jsonl" i.reflection
    ++ gateJsonl i.stateInitialized "runs.jsonl" i.runs
    ++ (gateFile i.stateInitialized "project.json" i.project).2.2
    ++ gateLedgerDiagnostics i.domain i.stateInitialized i.ledgers
    ++ (gateItems blockers.1 "blockers.json" blockers.2.1).2
    ++ (gateItems recs.1 "recommendations.json" recs.2.1).2
    ++ progress.2
    ++ (progressCounter progress.1 "idle_cycles_since_progress").2
    ++ (stopThreshold context.1 "stop_after_idle_cycles"
        defaultStopAfterIdleCycles true).2
    ++ (progressCounter progress.1 "infra_fails_since_ok").2
    ++ (stopThreshold context.1 "stop_after_infra_fails"
        defaultStopAfterInfraFails false).2
    ++ (progressCounter progress.1 "usage_limited_since_ok").2
    ++ (stopThreshold context.1 "stop_after_usage_limited"
        defaultStopAfterUsageLimited false).2
    ++ (essenceReviewBaseline i.attestations i.project i.projectTitle).2

/-- blockers.json の item 列(値面。I-021 shape hardening は `gateItems`)。 -/
def stopBlockerItems (i : StopInputs) : List Json.Value :=
  let blockers := gateFile i.stateInitialized "blockers.json" i.blockers
  (gateItems blockers.1 "blockers.json" blockers.2.1).1

/-- recommendations.json の item 列(値面)。 -/
def stopRecItems (i : StopInputs) : List Json.Value :=
  let recs := gateFile i.stateInitialized "recommendations.json" i.recommendations
  (gateItems recs.1 "recommendations.json" recs.2.1).1

/-- active な essence_blocking blocker(§13.1)。 -/
def stopEssenceBlockers (i : StopInputs) : List Json.Value :=
  (stopBlockerItems i).filter fun b =>
    b.get? "status" == some (.str "active")
      && b.get? "type" == some (.str "essence_blocking")

/-- proposed な Blocking Recommendation(§21.1)。 -/
def isBlockingRec (r : Json.Value) : Bool :=
  r.get? "type" == some (.str "Blocking Recommendation")
    && r.get? "status" == some (.str "proposed")

def stopBlockingRecs (i : StopInputs) : List Json.Value :=
  (stopRecItems i).filter isBlockingRec

/-- human gate の Recommendation。Python の `r not in blocking_recs` は内容
等値による除外だが、blocking の判定条件は内容だけの関数なので「blocking
条件を満たさない」と同値。 -/
def stopHumanRequests (i : StopInputs) : List Json.Value :=
  (stopRecItems i).filter fun r =>
    recommendationRequiresHuman r && !isBlockingRec r

/-- `stopAssemble` が評価するドメイン停止 gate(§13.1)。`resumeHint` は
message の締めにしか効かないので、**理由の集合は hint に依らない** — 定理は
その独立性を使ってヒント文言を量化できる。 -/
def domainStopGates (i : StopInputs) (resumeHint : String) : StopGates :=
  i.domain.stopGates
    { toGateInputs := gateInputsOf i.domain i.ledgers i.spec
        (gateFile i.stateInitialized "context.json" i.context).1 i.observations
      resumeHint }

/-- should-stop payload の純粋組み立て。binds の結果(completion 述語・
placeholder・essence sha・message 用 id 列)を受け取り、診断の蓄積順・
reasons の正準順(D-005 — `Core.Stop.reasonPriority` と同一。両者の一致は
test_sync_pairs が凍結する)・message の組み立て順と文言・payload のキー順
まで Python と一致させる。 -/
def stopAssemble (i : StopInputs) (phaseApprovalStop placeholderEssence : Bool)
    (currentEssence : Option String)
    (humanIds blockingIds blockerIds : List String)
    (currentAssets : List (String × String))
    (assetIssues : List String)
    (structureIssues : List String) : StopVerdict :=
  let essenceBlockers := stopEssenceBlockers i
  let blockingRecs := stopBlockingRecs i
  let humanRequests := stopHumanRequests i
  -- supervise authorizing gate(§13.3-4''): この gate の「答え」は `--resolve`
  -- ではなく supervise の実行なので、案内の分岐と payload の機械可読リスト
  -- (triage wrapper が resolve 候補から機械的に落とす)に使う。
  let todoItems := objectItems
    (((readJsonOrEmpty "todo.json" i.todo).1.get? "items").getD (.arr []))
  let authorizations := superviseAuthorizations i.domain
    (humanRequests ++ blockingRecs) todoItems
  let authorizedIds := authorizations.map (·.1)
  let context := gateFile i.stateInitialized "context.json" i.context
  let progress := (progressOf context.1 context.2.1).1
  let idleCycles := (progressCounter progress "idle_cycles_since_progress").1
  let idleThreshold := (stopThreshold context.1 "stop_after_idle_cycles"
    defaultStopAfterIdleCycles true).1
  let idleStop := idleCycles ≥ idleThreshold
  let infraFails := (progressCounter progress "infra_fails_since_ok").1
  let infraThreshold := (stopThreshold context.1 "stop_after_infra_fails"
    defaultStopAfterInfraFails false).1
  let infraStop := infraFails ≥ infraThreshold
  -- §13.1-12': プラン/モデル利用上限は infra の**特定された**下位種別。別
  -- カウンタ・別しきい値・別 reason を持つのは、総称の「到達不能」として
  -- 提示すると人間が API 到達性・認証を調べに行ってしまうからである(§28.6)。
  let usageLimited := (progressCounter progress "usage_limited_since_ok").1
  let usageThreshold := (stopThreshold context.1 "stop_after_usage_limited"
    defaultStopAfterUsageLimited false).1
  let usageStop := usageLimited ≥ usageThreshold
  let essenceMissing := match i.essence with | .absent => true | _ => false
  let baseline :=
    (essenceReviewBaseline i.attestations i.project i.projectTitle).1
  let reviewBaseline := baseline.sha?
  let essenceShaUnreviewed :=
    match currentEssence with
    | some current => !placeholderEssence && some current != reviewBaseline
    | none => false
  -- essences/ マニフェストの不一致(§13.1-10 拡張): ESSENCE.md 本体と同じ
  -- attestation レコードのマニフェストと比較する。missing/placeholder が
  -- 立っている間は本体側の停止が先(比較は保留)。
  let assetsUnreviewed :=
    currentEssence.isSome && !placeholderEssence
      && currentAssets != baseline.assets
  let essenceUnreviewed := essenceShaUnreviewed || assetsUnreviewed
  let structureStop := !structureIssues.isEmpty
  let assetIntegrityStop := !assetIssues.isEmpty
  -- 診断の一意化(Python `dict.fromkeys` — 順序保持)
  let unreadable := Text.dedup (unreadableDiagnostics i)
  -- §13.4-2 / §13.3-4': open gate が 1 件でもあると素の `just resume` は必ず
  -- 拒否される。gate 系の part は自分の exact 形(`--resolve <ID>` / phase の
  -- 二択)を名指しするので、それ以外の reason の締めは「上で名指しした形」を
  -- 指す — ここで固定文言の `just resume` を出すと、同じ message の中で
  -- 受理される形と拒否される形が同居し、人間はどちらを写しても良いと読む。
  let openGatesPresent := !humanRequests.isEmpty || !blockingRecs.isEmpty
    || !essenceBlockers.isEmpty
  let resumeHint : String :=
    if openGatesPresent then
      "the exact `just resume …` form named above, followed by `just loop`"
    else "`just resume` and `just loop`"
  -- §13.3-4''': 人間所有入力の編集**だけ**を記録する遷移(steering)は、gate の
  -- 有無によらず存在しなければならない — §19.3 が指示する「要求を足して続行」の
  -- 手順は must 境界から入るため、open gate の下でこそ必要になる。open gate が
  -- あるときの素の resume は拒否される(§13.3-4')ので、その状態で綴るべき受理形は
  -- `--steer-only` である。gate はどれも閉じないので、各 gate の決定は上で
  -- 名指しした形が引き続き引き受ける。
  let recordHint : String :=
    if openGatesPresent then
      "`just resume --steer-only --note \"...\"`, which records the edit and "
        ++ "leaves every gate above open for its own decision"
    else resumeHint
  -- ドメイン固有の停止 gate(§13.1)。判定と文言はドメインが持ち、Looper は
  -- 挿入位置だけを固定する — reasons は `human_input_required` の直後
  -- (§13.4 の優先順)、message part は supervise authorization part の直後、
  -- payload は `supervise_authorizations` の直後である。**gate は理由と
  -- message を対で返す**ので、理由だけが立って人間に次手が示されない状態が
  -- 構造的に作れない(§13.4-2)。
  let domainGates := domainStopGates i resumeHint
  let reasons : List String := List.flatten [
    if !unreadable.isEmpty then ["state_unreadable"] else [],
    if essenceMissing then ["essence_missing"] else [],
    if placeholderEssence then ["essence_placeholder"] else [],
    if structureStop then ["essence_structure"] else [],
    if assetIntegrityStop then ["essence_asset_integrity"] else [],
    if essenceUnreviewed then ["essence_unreviewed_change"] else [],
    if !essenceBlockers.isEmpty then ["essence_blocking"] else [],
    if !blockingRecs.isEmpty then ["blocking_recommendation"] else [],
    if !humanRequests.isEmpty then ["human_input_required"] else [],
    domainGates.gates.map (·.reason),
    if phaseApprovalStop then ["must_complete_awaiting_phase_approval"] else [],
    if idleStop then ["idle_cycles"] else [],
    if usageStop then ["usage_limited"] else [],
    if infraStop then ["infra_unreachable"] else []
  ]
  -- message(parts の順序は reasons と異なる — Python L1887–1964 の記述順)
  --
  -- **綴りの規律(SS-037 が機械検査する)**: message 中でバッククォートに包まれた
  -- `just resume …` は「その state で engine が受理する形」だけである。message は
  -- reason ごとの独立な部品の連結なので、1 つでも拒否される形を入れると人間は
  -- どちらを写しても良いと読む(実障害 2026-07-27 の直接原因)。したがって
  --   - 受理されない形を例示するときはバッククォートに包まない
  --     (例: 「a bare resume with no flags … does not clear this gate」)
  --   - 唯一の例外は省略記号 `…` を含む指示子(`just resume …` — コマンドでは
  --     なく「上で名指しした形」への参照であることが字面で分かる)
  -- という 2 点を守る。
  let parts : List String := List.flatten [
    if !unreadable.isEmpty then
      ["canonical state is unreadable (" ++ String.intercalate "; " unreadable
        ++ "); repair the file (restore it from the last checkpoint "
        ++ "commit with `git restore`, or fix the truncated line), then "
        ++ "run `just resume` and `just loop`"]
    else [],
    if essenceMissing then
      ["ESSENCE.md does not exist; a human must write it "
        ++ "(directly, or via the interactive `just new-essence` "
        ++ "interview, §2.1.4)"]
    else [],
    if placeholderEssence then
      ["ESSENCE.md is still the " ++ i.domain.displayName
        ++ " placeholder (empty, the "
        ++ "guide block, or an unfilled FILL section marker remains, "
        ++ "§13.1-8); a human must replace it — directly, or via the "
        ++ "interactive `just new-essence` interview (§2.1.4)"]
    else [],
    if structureStop then
      ["ESSENCE.md heading structure violates the canonical section contract ("
        ++ String.intercalate "; " structureIssues
        ++ "); a human must restructure ESSENCE.md to the canonical sections, "
        ++ "then run " ++ resumeHint ++ " (§13.1-15)"]
    else [],
    if assetIntegrityStop then
      ["ESSENCE.md and essences/ are out of sync ("
        ++ String.intercalate "; " assetIssues
        ++ "); a human must align them — edit ESSENCE.md or the essences/ "
        ++ "files — then run " ++ resumeHint ++ " (§13.1-14)"]
    else [],
    if essenceUnreviewed then
      if essenceShaUnreviewed then
        match reviewBaseline with
        | some baseline =>
          ["ESSENCE.md changed without a recorded human review "
            ++ s!"(current {(currentEssence.getD "").take 12}…, last human-reviewed "
            ++ s!"{baseline.take 12}…); if this edit is yours, record it by "
            ++ "running " ++ recordHint ++ " — otherwise inspect the diff for "
            ++ "an agent-made change (§13.1-5)"]
        | none =>
          ["ESSENCE.md has no human-reviewed baseline (no attestation "
            ++ "and no bootstrap anchor); a human must record the current "
            ++ "Essence by running " ++ recordHint ++ " before the loop runs "
            ++ "(§13.1-10)"]
      else
        let baseNames := baseline.assets.map (·.1)
        let curNames := currentAssets.map (·.1)
        let added := curNames.filter (fun n => !baseNames.contains n)
        let removed := baseNames.filter (fun n => !curNames.contains n)
        let changed := currentAssets.filterMap fun (n, s) =>
          match baseline.assets.find? (·.1 == n) with
          | some (_, s0) => if s0 != s then some n else none
          | none => none
        let fmt (label : String) (names : List String) : List String :=
          if names.isEmpty then []
          else [label ++ " " ++ String.intercalate ", " names]
        ["essences/ changed without a recorded human review ("
          ++ String.intercalate "; "
            (fmt "added" added ++ fmt "removed" removed ++ fmt "changed" changed)
          ++ "); if these are your edits, record them by running "
          ++ recordHint
          ++ " — otherwise inspect the diff for an agent-made change (§13.1-10)"]
    else [],
    if !humanRequests.isEmpty then
      -- §13.4-2: 通常 gate は**受理される exact 形**を案内する。素の
      -- `just resume` は open gate があると拒否される(§13.3-4')ので、
      -- `--resolve <ID>` を綴った形を出す。must 境界 gate は、境界が**現に
      -- 立っている間だけ** `--resolve` で解除できない(§13.3-4')ので、その
      -- ときだけ案内から外して phase 部の二択に委ねる。境界が消えた後に残る
      -- 陳腐化 gate は `--resolve` が受理される側なので案内に載せる —
      -- 受理集合(`Resume.selectionError?`)と同じ条件
      -- (`phaseApprovalStop` = payload の `must_complete_awaiting_phase_approval`
      --  = `hasFrameworkPhaseGate` が読む当の値)で切ることが要点である。
      -- supervise authorizing gate も `--resolve` 案内から外す(§13.3-4'':
      -- この状態では拒否される形なので、案内すれば SS-037 の無矛盾性が破れる)
      let resolvable := (humanIds.zip humanRequests).filterMap fun (id, rec) =>
        if (phaseApprovalStop && isPhaseGateRecommendation i.domain rec)
            || authorizedIds.contains id then none else some id
      ["human input required for recommendations: "
        ++ String.intercalate ", " humanIds
        ++ " (read recommendations.json, decide, then run "
        ++ (if resolvable.isEmpty then
              (if phaseApprovalStop then "the must-boundary decision below"
               else "the supervise authorization step below")
            else
              "`just resume " ++ resolveFlags resolvable ++ " --note \"...\"`")
        ++ " followed by `just loop`; `just triage` can assist — §13.6)"]
    else [],
    -- §13.3-4'' / §12.1: authorizing gate の「答え」は supervise の実行。
    -- `--resolve <ID>` はこの状態では拒否されるので決して案内せず(§13.4-2 の
    -- 綴り規律)、受理される 2 形 — supervise 本体と、承認を意図的に撤回する
    -- `--retract-approval` — だけを exact に示す。gate は supervise 完了・
    -- diff レビュー後の `--resolve`(そのとき Todo は unfinished でなくなり
    -- 通常 gate に戻る)で閉じる。
    authorizations.map fun (recId, todoId) =>
      s!"supervise authorization {recId} approves High-Risk Todo {todoId}: "
        ++ s!"run `just supervise --todo {todoId} --recommendation {recId}` "
        ++ s!"and resolve {recId} only after the supervised diff is reviewed "
        ++ "(§12.1, §21.3); to withdraw the approval instead, run "
        ++ s!"`just resume --retract-approval {recId} --note \"...\"`",
    -- ドメイン固有 gate の案内(理由と対で返る — 上の `domainGates`)。
    domainGates.gates.map (·.message),
    -- §13.4-2: フェーズ境界停止では `--approve-should` と `--close-at-must` の
    -- **二択を明示する**。この案内が message(= should-stop と `just status` が
    -- 共有する単一導出点)にあることが要件である — 表示側の別分岐に置くと、
    -- S-T3(mustPhaseComplete ∧ phase=must ⇒ 停止)により STOP 表示が常に
    -- 優先されてその分岐が到達不能になり、案内が human に届かない。
    -- 素の `just resume` はこの状態では拒否される(§13.3-4')ので、案内は
    -- 必ず受理される exact 形でなければならない。
    if phaseApprovalStop then
      ["all must-priority Todos are done: the designed phase boundary "
        ++ "(§13.1-13, §19.3), not an error. Review the checkpoint, then run "
        ++ "exactly one of `just resume --approve-should --note \"...\"` "
        ++ "(give the should phase its autonomous budget) or "
        ++ "`just resume --close-at-must --note \"...\"` (adopt the Must scope "
        ++ "as the final result); a bare resume with no flags, or `--resolve` "
        ++ "alone, does not clear this gate"]
    else [],
    if !blockingRecs.isEmpty then
      -- Blocking Recommendation が同時に authorizing gate でもある病的な形でも
      -- 拒否される `--resolve` は案内しない(authorizing part が上で案内済み)
      let blockingResolvable := blockingIds.filter (!authorizedIds.contains ·)
      ["blocking recommendations: " ++ String.intercalate ", " blockingIds
        ++ " (review the Essence issue, fix ESSENCE.md if needed, then run "
        ++ (if blockingResolvable.isEmpty then
              "the supervise authorization step above"
            else
              "`just resume " ++ resolveFlags blockingResolvable
                ++ " --note \"...\"`")
        ++ " followed by `just loop`)"]
    else [],
    if !essenceBlockers.isEmpty then
      ["essence blockers: " ++ String.intercalate ", " blockerIds
        ++ " (review the Essence issue, fix ESSENCE.md if needed, then run "
        ++ "`just resume " ++ resolveFlags blockerIds ++ " --note \"...\"` "
        ++ "followed by `just loop`)"]
    else [],
    if idleStop then
      [s!"no progress for {idleCycles} consecutive cycles "
        ++ s!"(threshold {idleThreshold}); inspect recent reflection.jsonl"
        ++ " / runs.jsonl entries, then run " ++ resumeHint]
    else [],
    if usageStop then
      [s!"claude could not run for {usageLimited} consecutive cycles because "
        ++ "the plan / model USAGE LIMIT was reached (threshold "
        ++ s!"{usageThreshold}; the loop already backed off exponentially "
        ++ "between attempts, §19.1-8). This is not the agent being stuck and not "
        ++ "an unreachable API: wait for the limit to reset, or re-run with "
        ++ "`" ++ i.domain.envPrefix ++ "_MODEL=<tier>` to continue on another model (§16.1), "
        ++ "then run " ++ resumeHint]
    else [],
    if infraStop then
      [s!"claude failed to run for {infraFails} consecutive cycles due "
        ++ "to an infra problem (API connection / auth / Claude-side error; "
        ++ s!"threshold {infraThreshold}). Check API "
        ++ "reachability and authentication (`claude auth status`), then run "
        ++ resumeHint]
    else []
  ]
  let message :=
    if reasons.isEmpty then "No stop condition."
    else String.intercalate "; " parts
  let payload : Json.Value := .obj ([
    ("should_stop", .bool !reasons.isEmpty),
    ("reasons", .arr (reasons.map .str)),
    ("message", .str message),
    ("state_unreadable", .arr (unreadable.map .str)),
    ("essence_missing", .bool essenceMissing),
    ("essence_placeholder", .bool placeholderEssence),
    ("essence_structure", .arr (structureIssues.map .str)),
    ("essence_unreviewed_change", .bool essenceUnreviewed),
    ("essence_sha256", (currentEssence.map Json.Value.str).getD .null),
    ("essence_review_baseline", (reviewBaseline.map Json.Value.str).getD .null),
    ("essence_asset_integrity", .arr (assetIssues.map .str)),
    ("essences_manifest", assetsManifestJson currentAssets),
    ("essences_review_baseline", assetsManifestJson baseline.assets),
    ("essence_blockers", idsForPayload essenceBlockers),
    ("blocking_recommendations", idsForPayload blockingRecs),
    ("human_requests", idsForPayload humanRequests),
    -- §13.3-4'': `--resolve` では閉じられない authorizing gate の機械可読
    -- リスト(triage wrapper の reduction-only 除外と、案内検証の対象)
    ("supervise_authorizations", .arr (authorizedIds.map .str))
  ] ++ domainGates.payload ++ [
    ("must_complete_awaiting_phase_approval", .bool phaseApprovalStop),
    ("idle_cycles_since_progress", intVal idleCycles),
    ("stop_after_idle_cycles", intVal idleThreshold),
    ("infra_fails_since_ok", intVal infraFails),
    ("stop_after_infra_fails", intVal infraThreshold),
    ("usage_limited_since_ok", intVal usageLimited),
    ("stop_after_usage_limited", intVal usageThreshold)
  ])
  { payload, stop := !reasons.isEmpty }

/-- 共通面のキー列を取り出すための最小 `StopInputs`。payload の**キーの集合**は
入力に依らないので、値は何でもよい。

**ここで `Domain.fixture` を使うのは短縮記法ではなく要件である**(D-9 の系の
例外)。ドメイン面を持たないドメインで組み立てて初めて「共通面の全量」が得られ、
実ドメインで組み立てると自分のキーまで共通面に数えられて検査が空虚になる。
この定義は実行経路から到達しない — 消費点は各製品の `#guard` だけである。 -/
private def stopKeyProbe : StopInputs :=
  { domain := Domain.fixture, stateInitialized := false,
    blockers := .absent, recommendations := .absent, context := .absent,
    project := .absent, reflection := .absent, runs := .absent,
    ledgers := [], observations := [], attestations := .absent,
    spec := .absent, todo := .absent, essence := .absent,
    essencesDir := .absent, projectTitle := "" }

/-- ドメインの stop payload が名乗ってしまった**共通面のキー**。

空でなければならない。名乗ると同名キーが 1 つの object に 2 度現れ、
`Json.Value.get?`(先勝ち)と `jq`(後勝ち)が**別の値を読む** — 機械読者ごとに
違う真実が生まれる。共通面の列は `stopAssemble` の組み立てそのものから導くので、
共通面が増減しても追従する(列挙を複製しない)。各製品の `Domain` が交わりの
無さを `#guard` で凍結する。 -/
def stopPayloadCollisions (payload : List (String × Json.Value)) : List String :=
  let common : List String :=
    match (stopAssemble stopKeyProbe false false none [] [] [] [] [] []).payload with
    | .obj entries => entries.map Prod.fst
    | _ => []
  (payload.map Prod.fst).filter common.contains

/-- Python `should_stop_payload` の純粋核。gate 保持ファイルの欠落・破損・
形状崩れは `state_unreadable` へ(I-021 fail-closed)。`.error` は Python の
uncaught 例外(exit 2)経路で、発生順は Python と同一(completion →
placeholder → essence sha → message 用 id 列 3 本)。 -/
def shouldStopPayload (i : StopInputs) : Except String StopVerdict := do
  -- §13.1-13 の直接述語(raise-loop-gates 前のクラッシュへの fail-closed 予備)。
  -- completion の診断は completion 側 payload にのみ現れる(Python と同じ分離)。
  let completion ← completionPayload
    { domain := i.domain, todo := i.todo, spec := i.spec, context := i.context,
      essence := i.essence, ledgers := i.ledgers, observations := i.observations }
  let placeholderEssence ← essenceIsPlaceholder i.domain i.essence
  let currentEssence ← essenceSha256 i.essence
  let currentAssets ← essencesManifest i.essencesDir
  let assetIssues := essenceAssetIssues i.domain i.essence i.essencesDir
  let structureIssues := essenceStructureIssues i.domain i.essence
  let humanIds ← (stopHumanRequests i).mapM idForMessage
  let blockingIds ← (stopBlockingRecs i).mapM idForMessage
  let blockerIds ← (stopEssenceBlockers i).mapM idForMessage
  pure (stopAssemble i completion.awaitingPhaseApproval placeholderEssence
    currentEssence humanIds blockingIds blockerIds currentAssets assetIssues
    structureIssues)

/-! ## should-reset(state.py `cmd_should_reset` L2431–2459) -/

/-- Python `cmd_should_reset`: gate 系と対照的に fail-open — 破損・不在の
context は空として評価し reset しない(SR-010 が凍結する設計上の非対称)。
ただし `counters` / `reset_policy` が object でない(null 含む)、または
counters の値と policy の閾値が比較できない型の組は、Python の uncaught
AttributeError / TypeError(exit 2)に対応するハードエラー。 -/
def shouldResetPayload (contextRaw : RawFile) : Except String (Json.Value × Bool) := do
  let (context, _) := readJsonOrEmpty "context.json" contextRaw
  let getObj (key : String) : Except String Json.Value :=
    match context.get? key with
    | none => .ok (.obj [])
    | some (.obj entries) => .ok (.obj entries)
    | some _ => .error s!"context.json: {key} is not an object"
  let counters ← getObj "counters"
  let policy ← getObj "reset_policy"
  let exceeds (counterKey policyKey : String) (dfltMantissa : Int)
      (dfltExponent : Nat) : Except String Bool :=
    let counter := (counters.get? counterKey).getD (.num 0 0)
    let threshold := (policy.get? policyKey).getD (.num dfltMantissa dfltExponent)
    match pyGE? counter threshold with
    | some b => .ok b
    | none =>
      .error s!"'>=' not supported between counters.{counterKey} and reset_policy.{policyKey}"
  let truthyCounter (key : String) : Bool :=
    ((counters.get? key).getD .null).truthy
  let mut reasons : List String := []
  if ← exceeds "context_usage_estimate" "hard_threshold_context_usage" 8 1 then
    reasons := reasons ++ ["context_usage_estimate"]
  if ← exceeds "failed_attempts_since_reset" "reset_after_failed_attempts" 3 0 then
    reasons := reasons ++ ["failed_attempts_since_reset"]
  if ← exceeds "changed_files_since_reset" "reset_after_changed_files" 25 0 then
    reasons := reasons ++ ["changed_files_since_reset"]
  if ← exceeds "completed_todos_since_reset" "reset_after_completed_todos" 5 0 then
    reasons := reasons ++ ["completed_todos_since_reset"]
  if ← exceeds "important_decisions_since_reset" "reset_after_decisions" 5 0 then
    reasons := reasons ++ ["important_decisions_since_reset"]
  if truthyCounter "major_spec_rewrite_since_reset" then
    reasons := reasons ++ ["major_spec_rewrite_since_reset"]
  if truthyCounter "high_risk_change_completed" then
    reasons := reasons ++ ["high_risk_change_completed"]
  let payload : Json.Value := .obj [
    ("should_reset", .bool !reasons.isEmpty),
    ("reasons", .arr (reasons.map .str))
  ]
  pure (payload, !reasons.isEmpty)

/-! ## コンパイル時テスト -/

-- 述語単体
#guard contextPhase (.obj [("phase", .str "extended_approved")]) == "extended_approved"
#guard contextPhase (.obj [("phase", .str "weird")]) == "must"
#guard contextPhase (.obj []) == "must"
#guard contextPhase (.obj [("phase", .num 1 0)]) == "must"

-- executor 語彙は `Domain.tool`(fixture では `"looper"`)。製品綴りの凍結は
-- 各製品の黒箱 conformance が実バイナリに対して担う(抽出計画 K-7)。
private def runnableMust : Json.Value := .obj [
  ("status", .str "pending"), ("priority", .str "must"),
  ("executor", .obj [("mode", .str "looper")])
]
private def doneMust : Json.Value := .obj [
  ("status", .str "done"), ("priority", .str "must"),
  ("executor", .obj [("mode", .str "looper")])
]
private def runnableShould : Json.Value := .obj [
  ("status", .str "pending"), ("priority", .str "should"),
  ("executor", .obj [("mode", .str "looper")])
]

#guard todoIsRunnable Domain.fixture runnableMust == true
#guard todoIsRunnable Domain.fixture runnableShould == false -- must phase では should は不可
#guard todoIsRunnable Domain.fixture runnableShould "extended_approved" == true
#guard todoIsRunnable Domain.fixture (runnableMust.set "executor" (.str "looper")) == false
#guard todoIsRunnable Domain.fixture (runnableMust.set "status" (.str "done")) == false
#guard todoIsRunnable Domain.fixture
  (runnableMust.set "executor" (.obj [("mode", .str "human")])) == false
-- 別語幹のドメインでは同じ todo が runnable でない(軸が効いていることの凍結)
#guard todoIsRunnable { Domain.fixture with tool := "sample-tool" } runnableMust == false

#guard mustPhaseCompleteFrom [doneMust] false [] == true
#guard mustPhaseCompleteFrom [doneMust] true [] == false     -- drift は完了を否定
#guard mustPhaseCompleteFrom [doneMust] false ["x"] == false -- unreadable も否定
#guard mustPhaseCompleteFrom [] false [] == false            -- items 空
#guard mustPhaseCompleteFrom [runnableShould] false [] == false -- must 不在
#guard mustPhaseCompleteFrom [doneMust, runnableMust] false [] == false

#guard recommendationRequiresHuman (.obj [("status", .str "proposed"),
    ("type", .str "Human-input Recommendation")]) == true
#guard recommendationRequiresHuman (.obj [("status", .str "resolved"),
    ("type", .str "Human-input Recommendation")]) == false
#guard recommendationRequiresHuman (.obj [("status", .str "proposed"),
    ("requires_human_approval", .bool true)]) == true
#guard recommendationRequiresHuman (.obj [("status", .str "proposed"),
    ("requires_human_approval", .num 1 0)]) == false   -- `is True` は bool のみ
#guard recommendationRequiresHuman (.obj [("status", .str "proposed"),
    ("agent_action", .str "ask_human")]) == true
#guard recommendationRequiresHuman (.obj [("status", .str "proposed"),
    ("type", .str "Non-blocking Recommendation")]) == false
#guard recommendationGatesLoop (.obj [("status", .str "proposed"),
    ("type", .str "Blocking Recommendation")]) == true

-- 閾値の fail-open フォールバック(診断付き)と `value or DEFAULT`
#guard stopThreshold (.obj []) "stop_after_idle_cycles" 3 true == (3, [])
#guard stopThreshold (.obj [("stop_policy", .str "broken")])
    "stop_after_idle_cycles" 3 true
    == (3, ["context.json: stop_policy is not an object"])
#guard stopThreshold (.obj [("stop_policy", .str "broken")])
    "stop_after_infra_fails" 2 false == (2, [])   -- infra 側は重複診断を出さない
#guard stopThreshold (.obj [("stop_policy", .obj [("stop_after_idle_cycles", .num 5 0)])])
    "stop_after_idle_cycles" 3 true == (5, [])
#guard stopThreshold (.obj [("stop_policy", .obj [("stop_after_idle_cycles", .num 0 0)])])
    "stop_after_idle_cycles" 3 true == (3, [])    -- 0 は未設定 → 既定値
#guard stopThreshold (.obj [("stop_policy", .obj [("stop_after_idle_cycles", .str "many")])])
    "stop_after_idle_cycles" 3 true
    == (3, ["context.json: stop_policy.stop_after_idle_cycles is not an integer"])

-- gateFile: bootstrap 前不在は空、初期化済み不在・破損・非 object は診断
#guard gateFile false "blockers.json" .absent == (.obj [], false, [])
#guard gateFile true "blockers.json" .absent
    == (.obj [], false, ["blockers.json: missing from the initialized state directory"])
#guard (gateFile true "blockers.json" (.text "{broken")).2.1 == false
#guard gateFile true "blockers.json" (.text "[1]")
    == (.obj [], false, ["blockers.json: top-level value is not an object"])
#guard gateFile true "blockers.json" (.text "{\"items\": []}")
    == (.obj [("items", .arr [])], true, [])

-- gateItems: items 非 list(bare {} 含む)は shape corruption
#guard gateItems (.obj []) "blockers.json" true
    == ([], ["blockers.json: items is missing or not a list"])
#guard gateItems (.obj [("items", .null)]) "blockers.json" true
    == ([], ["blockers.json: items is missing or not a list"])
#guard gateItems (.obj [("items", .arr [.obj [], .num 1 0])]) "blockers.json" true
    == ([.obj []], [])
#guard gateItems (.obj []) "blockers.json" false == ([], [])

-- progressCounter: 欠落/null は 0、非整数は fail-closed 診断
#guard progressCounter (.obj []) "idle_cycles_since_progress" == (0, [])
#guard progressCounter (.obj [("idle_cycles_since_progress", .num 4 0)])
    "idle_cycles_since_progress" == (4, [])
#guard progressCounter (.obj [("idle_cycles_since_progress", .str "three")])
    "idle_cycles_since_progress"
    == (0, ["context.json: progress.idle_cycles_since_progress is not an integer"])

-- essenceReviewBaseline: ledger の最後の一致 > project.json anchor > none
#guard (essenceReviewBaseline
    (.text "{\"project\": \"p\", \"essence_sha256\": \"aaa\"}\n{\"project\": \"p\", \"essence_sha256\": \"bbb\"}\n")
    .absent "p").1.sha? == some "bbb"
#guard (essenceReviewBaseline
    (.text "{\"project\": \"other\", \"essence_sha256\": \"aaa\"}\n")
    (.text "{\"essence_sha256\": \"anchor\"}") "p").1.sha? == some "anchor"
#guard (essenceReviewBaseline .absent .absent "p").1.sha? == none
#guard (essenceReviewBaseline (.text "{broken\n") .absent "p").2
    == ["essence_attestations.jsonl: unreadable JSONL (expected key string or '}' in object)"]
-- essences マニフェストの baseline: 同一レコードの `essences`(旧レコードの
-- キー不在は空マニフェスト)。anchor 側は `essences_manifest`
#guard (essenceReviewBaseline
    (.text "{\"project\": \"p\", \"essence_sha256\": \"aaa\", \"essences\": {\"b.png\": \"h2\", \"a.png\": \"h1\"}}\n")
    .absent "p").1.assets == [("a.png", "h1"), ("b.png", "h2")]
#guard (essenceReviewBaseline
    (.text "{\"project\": \"p\", \"essence_sha256\": \"aaa\"}\n")
    .absent "p").1.assets == []
#guard (essenceReviewBaseline .absent
    (.text "{\"essence_sha256\": \"anchor\", \"essences_manifest\": {\"x.pdf\": \"h\"}}")
    "p").1.assets == [("x.pdf", "h")]

-- essencesManifest / essenceAssetIssues
private def realAssetEssence : EssenceRead :=
  .file (String.toUTF8 "# Why\nSee essences/logo.png and essences/guide.pdf.\n")
private def nestedAssetEssence : EssenceRead :=
  .file (String.toUTF8 "# Why\nSee essences/input/ and essences/a/b/c.png.\n")
#guard (essencesManifest .absent).toOption == some []
#guard (essencesManifest (.dir [("b.png", .file (String.toUTF8 "x")),
    ("a.png", .file (String.toUTF8 "x"))] [] [])).toOption.map (·.map (·.1))
    == some ["a.png", "b.png"]
#guard (essencesManifest (.dir [("a.png", .ioError "boom")] [] [])).isOk == false
#guard (essencesManifest (.ioError "boom")).isOk == false
#guard essenceAssetIssues Domain.fixture realAssetEssence
    (.dir [("logo.png", .file (String.toUTF8 "x")),
           ("guide.pdf", .file (String.toUTF8 "y"))] [] []) == []
#guard essenceAssetIssues Domain.fixture realAssetEssence
    (.dir [("logo.png", .file (String.toUTF8 "x"))] [] [])
    == ["ESSENCE.md mentions essences/guide.pdf but no such file or directory exists in essences/ (§2.1.5)."]
#guard essenceAssetIssues Domain.fixture realAssetEssence
    (.dir [("logo.png", .file (String.toUTF8 "x")),
           ("guide.pdf", .file (String.toUTF8 "y")),
           ("orphan.txt", .file (String.toUTF8 "z"))] [] [])
    == ["essences/orphan.txt is not mentioned in ESSENCE.md; every essences/ "
      ++ "asset must be referenced by its exact 'essences/orphan.txt' path, or "
      ++ "by one of its parent directories (§2.1.5)."]
#guard (essenceAssetIssues Domain.fixture realAssetEssence .notDir).length == 3  -- notDir + dangling×2
#guard essenceAssetIssues Domain.fixture realAssetEssence .absent
    == ["ESSENCE.md mentions essences/logo.png but no such file or directory exists in essences/ (§2.1.5).",
        "ESSENCE.md mentions essences/guide.pdf but no such file or directory exists in essences/ (§2.1.5)."]
#guard essenceAssetIssues Domain.fixture .absent
    (.dir [("orphan.txt", .file (String.toUTF8 "z"))] [] []) == []  -- 言及検査は保留
#guard (essenceAssetIssues Domain.fixture realAssetEssence
    (.dir [("logo.png", .file (String.toUTF8 "x")),
           ("guide.pdf", .file (String.toUTF8 "y")),
           ("bad name.txt", .file (String.toUTF8 "z"))] [] [])).length == 1  -- 不正名のみ
-- 入れ子(§2.1.5、最大 3 階層): 祖先ディレクトリ言及が配下の資産を覆う
#guard essenceAssetIssues Domain.fixture nestedAssetEssence
    (.dir [("a/b/c.png", .file (String.toUTF8 "x")),
           ("input/main.csv", .file (String.toUTF8 "y")),
           ("input/sub.csv", .file (String.toUTF8 "z"))]
          ["a", "a/b", "input"] []) == []
-- 深さ上限超過は構造違反
#guard (essenceAssetIssues Domain.fixture nestedAssetEssence
    (.dir [("a/b/c.png", .file (String.toUTF8 "x")),
           ("input/main.csv", .file (String.toUTF8 "y"))]
          ["a", "a/b", "input"] ["a/b/deep/x.png"])).length == 1
#guard essenceAssetIssues Domain.fixture nestedAssetEssence
    (.dir [("a/b/c.png", .file (String.toUTF8 "x")),
           ("input/main.csv", .file (String.toUTF8 "y"))]
          ["a", "a/b", "input"] ["a/b/deep/x.png"])
    == ["essences/a/b/deep/x.png is nested deeper than the 3-level limit; "
      ++ "a path under essences/ may have at most 3 segments (§2.1.5)."]
-- ディレクトリ言及だけあって実体が無ければ dangling
#guard essenceAssetIssues Domain.fixture nestedAssetEssence
    (.dir [("a/b/c.png", .file (String.toUTF8 "x"))] ["a", "a/b"] [])
    == ["ESSENCE.md mentions essences/input but no such file or directory "
      ++ "exists in essences/ (§2.1.5)."]

-- shouldResetPayload: fail-open(破損は reset しない)と閾値既定値
#guard (shouldResetPayload (.text "{broken")).toOption.map (·.2) == some false
#guard (shouldResetPayload .absent).toOption.map (·.2) == some false
#guard (shouldResetPayload
    (.text "{\"counters\": {\"context_usage_estimate\": 0.9}}")).toOption.map (·.2)
    == some true
#guard (shouldResetPayload
    (.text "{\"counters\": {\"context_usage_estimate\": 0.7}}")).toOption.map (·.2)
    == some false
#guard (shouldResetPayload
    (.text "{\"counters\": {\"failed_attempts_since_reset\": 3}}")).toOption.map (·.2)
    == some true
#guard (shouldResetPayload
    (.text "{\"counters\": {\"high_risk_change_completed\": true}}")).toOption.map
    (fun r => r.1.render)
    == some "{\"should_reset\": true, \"reasons\": [\"high_risk_change_completed\"]}"
#guard (shouldResetPayload (.text "{\"counters\": null}")).isOk == false  -- AttributeError 相当
#guard (shouldResetPayload
    (.text "{\"counters\": {\"context_usage_estimate\": \"high\"}}")).isOk == false

-- completionPayload: 破損 todo は決して完了を証明しない(I-021)
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{broken", spec := .absent, context := .absent,
      essence := .absent, ledgers := [], observations := [] }).toOption.map (·.complete) == some false
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}]}",
      spec := .absent, context := .text "{\"phase\": \"extended_approved\"}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map
    (fun v => (v.complete, v.awaitingPhaseApproval)) == some (true, false)
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}]}",
      spec := .absent, context := .absent, essence := .absent,
      ledgers := [], observations := [] }).toOption.map
    (fun v => (v.complete, v.awaitingPhaseApproval)) == some (false, true)
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}, {\"status\": \"blocked\", \"priority\": \"should\", \"executor\": {\"mode\": \"looper\"}}]}",
      spec := .absent, context := .text "{\"phase\": \"extended_approved\"}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (·.complete) == some false
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}, {\"status\": \"pending\", \"priority\": \"should\", \"executor\": {\"mode\": \"human\"}}]}",
      spec := .absent, context := .text "{\"phase\": \"extended_approved\"}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (·.complete) == some false
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}, {\"status\": \"canceled\", \"priority\": \"should\", \"canceled_by\": \"human\", \"canceled_reason\": \"scope declined\"}]}",
      spec := .absent, context := .text "{\"phase\": \"extended_approved\"}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (·.complete) == some true
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}, {\"status\": \"pending\", \"priority\": \"should\"}]}",
      spec := .absent, context := .text "{\"phase\": \"closed_at_must\"}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (fun v =>
        (v.complete, v.payload.get? "completion_scope")) == some (true, some (.str "must"))

-- resume note 未消費ガード: handoff.pending_cycle が truthy の間は完了しない
-- (scope も none に落とす)。false / 欠落 / 非 object handoff は妨げない
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}]}",
      spec := .absent,
      context := .text "{\"phase\": \"extended_approved\", \"handoff\": {\"pending_cycle\": true}}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (fun v =>
        (v.complete, v.payload.get? "resume_pending_cycle",
          v.payload.get? "completion_scope"))
    == some (false, some (.bool true), some (.str "none"))
#guard (completionPayload
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}]}",
      spec := .absent,
      context := .text "{\"phase\": \"extended_approved\", \"handoff\": {\"pending_cycle\": false}}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (·.complete) == some true
#guard (completionPayload  -- truthy な残骸(1)も完了を証明しない側に倒す
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}]}",
      spec := .absent,
      context := .text "{\"phase\": \"closed_at_must\", \"handoff\": {\"pending_cycle\": 1}}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (·.complete) == some false
#guard (completionPayload  -- 非 object handoff は pending を主張できない
    { domain := Domain.fixture,
      todo := .text "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}]}",
      spec := .absent,
      context := .text "{\"phase\": \"extended_approved\", \"handoff\": \"x\"}",
      essence := .absent, ledgers := [], observations := [] }).toOption.map (·.complete) == some true

-- ドメインの完了寄与は 2 口(`Domain.completionGates`)。**同じ口に畳まない**:
-- `mustPhaseComplete` は phase 境界そのものを立てず、`sealsCompletion` は境界を
-- 出させたうえで完了だけを止める。軸を持たないドメインではどちらも無作用。
private def domainDoneTodo : String :=
  "{\"items\": [{\"status\": \"done\", \"priority\": \"must\"}]}"
private def domainCompletion (context : String) : CompletionInputs :=
  { domain := Domain.fixtureRich, todo := .text domainDoneTodo, spec := .absent,
    context := .text context, essence := .absent, ledgers := [], observations := [] }
#guard (completionPayload (domainCompletion "{\"phase\": \"closed_at_must\"}")).toOption.map
    (·.complete) == some true
#guard (completionPayload (domainCompletion
    "{\"phase\": \"closed_at_must\", \"domain_authorized\": true}")).toOption.map
    (fun v => (v.complete, v.payload.get? "must_phase_complete"))
  == some (false, some (.bool true))
#guard (completionPayload (domainCompletion
    "{\"phase\": \"closed_at_must\", \"domain_incomplete\": true}")).toOption.map
    (fun v => (v.complete, v.payload.get? "must_phase_complete"))
  == some (false, some (.bool false))
-- ドメイン payload の挿入位置は `resume_pending_cycle` の直後で固定
#guard (completionPayload (domainCompletion "{}")).toOption.map
    (fun v => match v.payload with
      | .obj entries =>
        ((entries.map (·.1)).dropWhile (· != "resume_pending_cycle")).take 3
      | _ => [])
  == some ["resume_pending_cycle", "domain_specs", "must_total"]

-- shouldStopPayload: クリーンな初期化済み state(attested essence)は停止しない
private def cleanStop : StopInputs := {
  domain := Domain.fixture
  stateInitialized := true
  blockers := .text "{\"items\": []}"
  recommendations := .text "{\"items\": []}"
  context := .text "{\"progress\": {}, \"stop_policy\": {}}"
  project := .text "{\"essence_sha256\": \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"}"
  reflection := .text ""
  runs := .text ""
  ledgers := []
  observations := []
  attestations := .absent
  spec := .absent
  todo := .absent
  essence := .file (String.toUTF8 "")
  essencesDir := .absent
  projectTitle := "p"
}

-- 空 ESSENCE.md は placeholder(sha は空バイト列の SHA-256 = project anchor と一致)。
-- 見出し構造の検査は placeholder の間は保留される(§13.1-15 の 6)
#guard (shouldStopPayload cleanStop).toOption.map (·.stop) == some true
#guard (shouldStopPayload cleanStop).toOption.map
    (fun v => (v.payload.get? "reasons")) == some (some (.arr [.str "essence_placeholder"]))
#guard (shouldStopPayload cleanStop).toOption.map
    (fun v => v.payload.get? "essence_structure") == some (some (.arr []))

-- ドメイン停止 gate の配管(`Domain.stopGates`)。挿入位置は 3 面とも固定:
-- reasons は `human_input_required` の直後、message part は supervise
-- authorization part の直後、payload は `supervise_authorizations` の直後。
-- **軸を持たないドメインでは 1 バイトも増えない**(最後の 2 件)。
private def domainGateStop : StopInputs := { cleanStop with
  domain := Domain.fixtureRich
  context := .text "{\"progress\": {}, \"stop_policy\": {}, \"domain_gate\": true}"
  ledgers := [("extra.json", .text "{\"items\": []}")]
  observations := [("target/file", none)]
}
#guard (shouldStopPayload domainGateStop).toOption.map
    (fun v => v.payload.get? "reasons")
  == some (some (.arr [.str "essence_placeholder", .str "domain_stop"]))
#guard (shouldStopPayload domainGateStop).toOption.map
    (fun v => match v.payload with
      | .obj entries =>
        ((entries.map (·.1)).dropWhile (· != "supervise_authorizations")).take 3
      | _ => [])
  == some ["supervise_authorizations", "domain_gate_ledgers",
      "must_complete_awaiting_phase_approval"]
#guard (shouldStopPayload domainGateStop).toOption.map
    (fun v => match v.payload.get? "message" with
      | some (.str m) => m.endsWith
        ("domain gate (1 ledger(s), 1 observation(s)); run `just resume` "
          ++ "and `just loop`")
      | _ => false) == some true
-- gate 保持面に加わったドメイン台帳は共通 7 面と同じ I-021 の扱いを受ける
#guard (shouldStopPayload { domainGateStop with
    ledgers := [("extra.json", .text "{broken")] }).toOption.map
    (fun v => match v.payload.get? "state_unreadable" with
      | some (.arr l) => l.length | _ => 0) == some 1
#guard (shouldStopPayload { domainGateStop with domain := Domain.fixture }).toOption.map
    (fun v => v.payload.get? "reasons")
  == some (some (.arr [.str "essence_placeholder"]))
-- 軸を持たないドメインでは、台帳と観測を渡しても payload は 1 バイトも動かない
#guard (shouldStopPayload { domainGateStop with domain := Domain.fixture }).toOption.map
    (·.payload) == (shouldStopPayload cleanStop).toOption.map (·.payload)

-- 実質内容のある essence + 一致する anchor → 停止なし。ESSENCE.md は正準
-- 見出し契約(§13.1-15)を満たしていなければならない — 満たさない形は
-- `structStop` 以下で別途凍結する
private def canonicalEssence (d : Domain) (title motivation : String) : String :=
  "# ESSENCE — " ++ title ++ "\n"
    ++ String.intercalate "" (d.essenceHeadings.mapIdx fun i h =>
      "## " ++ h ++ "\n- "
        ++ (if i == 0 then motivation else "Determinism over cleverness.")
        ++ "\n")
private def realEssence : String :=
  canonicalEssence Domain.fixture "Deterministic Test"
    "A deterministic test project."
private def cleanStopAttested : StopInputs := { cleanStop with
  essence := .file (String.toUTF8 realEssence)
  project := .text ("{\"essence_sha256\": \""
    ++ Looper.Core.Sha256.hexDigest (String.toUTF8 realEssence) ++ "\"}")
}
#guard (shouldStopPayload cleanStopAttested).toOption.map (·.stop) == some false
#guard (shouldStopPayload cleanStopAttested).toOption.map
    (fun v => v.payload.get? "message") == some (some (.str "No stop condition."))

-- essence_structure(§13.1-15): 見出し契約に反する実体 Essence は停止する。
-- D-005 の位置は essence_placeholder の直後・essence_asset_integrity の直前
private def malformedEssence : String := "# Why\nA deterministic test project.\n"
private def structStop : StopInputs := { cleanStop with
  essence := .file (String.toUTF8 malformedEssence)
  project := .text ("{\"essence_sha256\": \""
    ++ Looper.Core.Sha256.hexDigest (String.toUTF8 malformedEssence) ++ "\"}")
}
#guard (shouldStopPayload structStop).toOption.map
    (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"essence_structure\"]")
#guard (shouldStopPayload structStop).toOption.map
    (fun v => ((v.payload.get? "essence_structure").map Json.Value.render))
    == some (some ("[\"first heading must be `# ESSENCE — <title>`\", "
      ++ String.intercalate ", " (Domain.fixture.essenceHeadings.map fun h =>
          "\"missing required section: ## " ++ h ++ "\"") ++ "]"))
#guard (shouldStopPayload structStop).toOption.map
    (fun v => ((v.payload.get? "message").bind Json.Value.asStr?).map
      (fun m => Text.containsSub m
        ("ESSENCE.md heading structure violates the canonical section contract "
          ++ "(first heading must be `# ESSENCE — <title>`; ")
        && Text.containsSub m
          ("a human must restructure ESSENCE.md to the canonical sections, then "
            ++ "run `just resume` and `just loop` (§13.1-15)")))
    == some (some true)
-- 構造違反と資産不整合が同時に立つと、正準順は structure → asset_integrity
#guard (shouldStopPayload { structStop with
    essencesDir := .dir [("orphan.txt", .file (String.toUTF8 "z"))] [] []
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some ("[\"essence_structure\", \"essence_asset_integrity\", "
      ++ "\"essence_unreviewed_change\"]"))
-- 正準構造なら essence_structure は立たない(適合の側の凍結)
#guard (shouldStopPayload cleanStopAttested).toOption.map
    (fun v => v.payload.get? "essence_structure") == some (some (.arr []))

-- gate ファイル欠落(初期化済み)→ state_unreadable が最優先で立つ
#guard (shouldStopPayload { cleanStopAttested with blockers := .absent }).toOption.map
    (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"state_unreadable\"]")

-- idle 閾値: 3/3 で停止、2/3 では停止しない
#guard (shouldStopPayload { cleanStopAttested with
    context := .text "{\"progress\": {\"idle_cycles_since_progress\": 3}, \"stop_policy\": {}}"
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"idle_cycles\"]")
#guard (shouldStopPayload { cleanStopAttested with
    context := .text "{\"progress\": {\"idle_cycles_since_progress\": 2}, \"stop_policy\": {}}"
  }).toOption.map (·.stop) == some false

-- infra 閾値は 2(idle より早い)
#guard (shouldStopPayload { cleanStopAttested with
    context := .text "{\"progress\": {\"infra_fails_since_ok\": 2}, \"stop_policy\": {}}"
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"infra_unreachable\"]")

-- usage 閾値は 4(infra より寛容 — 時間が解く一過性、§13.1-12')
#guard (shouldStopPayload { cleanStopAttested with
    context := .text "{\"progress\": {\"usage_limited_since_ok\": 4}, \"stop_policy\": {}}"
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"usage_limited\"]")
#guard (shouldStopPayload { cleanStopAttested with
    context := .text "{\"progress\": {\"usage_limited_since_ok\": 3}, \"stop_policy\": {}}"
  }).toOption.map (·.stop) == some false

-- 未 attested の変更は essence_unreviewed_change(baseline なし文言)
#guard (shouldStopPayload { cleanStopAttested with project := .text "{}" }).toOption.map
    (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"essence_unreviewed_change\"]")
#guard (shouldStopPayload { cleanStopAttested with project := .text "{}" }).toOption.map
    (fun v => ((v.payload.get? "message").bind Json.Value.asStr?).map
      (Text.containsSub · "no human-reviewed baseline")) == some (some true)

-- 複数理由の正準順(D-005): blocking_recommendation < human_input_required の順序
#guard (shouldStopPayload { cleanStopAttested with
    recommendations := .text ("{\"items\": ["
      ++ "{\"id\": \"R-001\", \"type\": \"Blocking Recommendation\", \"status\": \"proposed\"},"
      ++ "{\"id\": \"R-002\", \"type\": \"Human-input Recommendation\", \"status\": \"proposed\"}]}")
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"blocking_recommendation\", \"human_input_required\"]")

-- essences/(§2.1.5・§13.1-10 拡張・§13.1-14)
private def assetEssenceText : String :=
  canonicalEssence Domain.fixture "Asset Test" "Use essences/logo.png here."
private def assetStop : StopInputs := { cleanStop with
  essence := .file (String.toUTF8 assetEssenceText)
  project := .text ("{\"essence_sha256\": \""
    ++ Looper.Core.Sha256.hexDigest (String.toUTF8 assetEssenceText)
    ++ "\", \"essences_manifest\": {\"logo.png\": \""
    ++ Looper.Core.Sha256.hexDigest (String.toUTF8 "IMG") ++ "\"}}")
  essencesDir := .dir [("logo.png", .file (String.toUTF8 "IMG"))] [] []
}
-- attest 済みマニフェスト一致 + 言及整合 → 停止なし
#guard (shouldStopPayload assetStop).toOption.map (·.stop) == some false
-- 内容変更(hash 不一致)→ essence_unreviewed_change
#guard (shouldStopPayload { assetStop with
    essencesDir := .dir [("logo.png", .file (String.toUTF8 "IMG2"))] [] []
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"essence_unreviewed_change\"]")
#guard (shouldStopPayload { assetStop with
    essencesDir := .dir [("logo.png", .file (String.toUTF8 "IMG2"))] [] []
  }).toOption.map (fun v => ((v.payload.get? "message").bind Json.Value.asStr?).map
      (Text.containsSub · "changed logo.png")) == some (some true)
-- 未言及ファイル追加 → integrity と unreviewed の両方(正準順)
#guard (shouldStopPayload { assetStop with
    essencesDir := .dir [("logo.png", .file (String.toUTF8 "IMG")),
                         ("orphan.txt", .file (String.toUTF8 "z"))] [] []
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"essence_asset_integrity\", \"essence_unreviewed_change\"]")
-- 深さ上限超過 → essence_asset_integrity(マニフェストはファイルのみで一致)
#guard (shouldStopPayload { assetStop with
    essencesDir := .dir [("logo.png", .file (String.toUTF8 "IMG"))]
      ["a", "a/b", "a/b/c"] ["a/b/c/deep.png"]
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"essence_asset_integrity\"]")
-- essences/ 読取不能はハードエラー(I-021 の exit-code 規律)
#guard (shouldStopPayload { assetStop with essencesDir := .ioError "boom" }).isOk
    == false
-- placeholder の間はマニフェスト比較を保留(placeholder が先)
#guard (shouldStopPayload { cleanStop with
    essencesDir := .dir [("x.png", .file (String.toUTF8 "a"))] [] []
  }).toOption.map (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"essence_placeholder\"]")

-- ESSENCE.md 不在: essence_missing のみ(placeholder は False、sha は null)
#guard (shouldStopPayload { cleanStopAttested with essence := .absent }).toOption.map
    (fun v => (v.payload.get? "reasons").map Json.Value.render)
    == some (some "[\"essence_missing\"]")
#guard (shouldStopPayload { cleanStopAttested with essence := .absent }).toOption.map
    (fun v => v.payload.get? "essence_sha256") == some (some .null)

end Looper.State.Predicates
