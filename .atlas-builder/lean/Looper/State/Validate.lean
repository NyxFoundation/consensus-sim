import Looper.Domain
import Looper.State.Model
import Looper.State.Predicates
import Looper.State.Status
import Looper.Core.StaticConfig
import Looper.Core.Doc
import Looper.Core.Essence
import Looper.Core.Classify.Profile
import Looper.Core.GlobHier

/-!
`Looper.State.Validate` — `cmd_validate` / `cmd_ensure` /
`enforce_bound_project` の純粋決定核。

置換元は state.py の検証層(L202–295 のフィールドバリデータ、L734–757
`bound_project_from_index`、L872–946 `cmd_ensure`、L954–1099 の
binding / recipe 警告、L1102–1402 `cmd_validate`、L3188–3239
`enforce_bound_project`)と、won't 警告の正規表現群(L518–614)。

エラー・警告の文言と蓄積順は Python と同一に写経する(§20.5 の
validation.json 温存比較が文言に依存するため、文言差はそのまま挙動差に
なる)。Python の f-string 補間(str() / repr())は `State.Status` の
`pyStr` / `pyRepr` を共有する。

I-021 の写像(§31.5): canonical JSON/JSONL の「存在するのに読めない」
(OSError)と ESSENCE.md の不正 UTF-8 は Python の未捕捉例外(exit 2)に
対応する `throw`(呼び出し枠がハードエラーへ倒す)。ensure の
gate-holding 欠損は die 文言を返す明示的な拒否側コンストラクタで表現し、
「読めない canonical file から Default を作る関数」は提供しない。
-/

namespace Looper.State.Validate

open Looper.Core
open Looper.Core.Doc
open Looper.State.Model
open Looper.State.Status (pyStr pyRepr pyReprStr acceptanceEvidenceMap successConditions)

/-! ## 定数(state.py L63–130) -/

/-- state スキーマの版。唯一の定義点は `Core.StaticConfig.schemaVersion`
(D-009 の単一定義への収斂)であり、ここは全 State 消費点のための再輸出。 -/
def schemaVersion : String := StaticConfig.schemaVersion

/-- canonical JSON の面と**その順序**。共通 4 面の間にドメイン台帳
(`extraLedgers`)が挿さる位置は `Domain.projectionFiles` が 1 箇所で決めて
おり、ここはそれを canonical state の前後で挟むだけである。 -/
def canonicalJson (d : Domain) : List String :=
  ["state_index.json", "project.json"] ++ d.projectionFiles
    ++ ["context.json", "validation.json"]

/-- §14.3: `lessons.jsonl` は cycle 横断で再利用する知見の恒久台帳。gate 保持面
ではない(停止条件を持たない)ので `gateStateFiles` には入らず、欠落は ensure が
補充する — 知見の欠落で loop を止めるのは、可視性ではなく単なる作業妨害である。 -/
def canonicalJsonl : List String :=
  ["reflection.jsonl", "runs.jsonl", "high_risk_changes.jsonl", "lessons.jsonl"]

/-- gate 保持面(§13.5、I-021)。ensure の再構築拒否と should-stop の
state_unreadable が同じ集合を見る。ドメイン台帳のうち gate を持つ面
(`Domain.gateLedgers`)が末尾に加わる — 台帳のすべてが gate 面とは限らない。 -/
def gateStateFiles (d : Domain) : List String :=
  ["blockers.json", "recommendations.json", "context.json", "project.json",
   "reflection.jsonl", "runs.jsonl"] ++ d.gateLedgers.map (· ++ ".json")

private def specStatuses : List String :=
  ["pending", "active", "done", "blocked", "superseded"]
private def todoStatuses : List String :=
  ["pending", "in_progress", "done", "blocked", "canceled"]
private def recStatuses : List String :=
  ["proposed", "accepted", "rejected", "resolved", "superseded"]
private def blockerStatuses : List String := ["active", "resolved", "superseded"]
private def blockerTypes : List String :=
  ["essence_blocking", "technical", "dependency", "external"]
def priorities : List String := ["must", "should"]
/-- §9.1 の executor 語彙。自律実行の担い手は製品自身なので、閉集合の第 1 要素は
`Domain.tool` から導出する。 -/
private def executorModes (d : Domain) : List String := [d.tool, "human", "blocked"]

/-- Python f-string の `{sorted(SET)}` 面(list の repr)。集合は固定なので
実測値をリテラルで凍結する。 -/
private def specStatusesRepr : String :=
  "['active', 'blocked', 'done', 'pending', 'superseded']"
private def todoStatusesRepr : String :=
  "['blocked', 'canceled', 'done', 'in_progress', 'pending']"
private def recStatusesRepr : String :=
  "['accepted', 'proposed', 'rejected', 'resolved', 'superseded']"
private def blockerStatusesRepr : String := "['active', 'resolved', 'superseded']"
private def blockerTypesRepr : String :=
  "['dependency', 'essence_blocking', 'external', 'technical']"
private def prioritiesRepr : String := "['must', 'should']"

/-! ## Python `==`(数値横断・object は順序非依存) -/

private def pyEqFuel : Nat → Json.Value → Json.Value → Bool
  | 0, _, _ => false
  | fuel + 1, a, b =>
    match a, b with
    | .null, .null => true
    | .bool b1, .bool b2 => b1 == b2
    | .bool b1, .num m2 e2 => numEq (if b1 then 1 else 0) 0 m2 e2
    | .num m1 e1, .bool b2 => numEq m1 e1 (if b2 then 1 else 0) 0
    | .num m1 e1, .num m2 e2 => numEq m1 e1 m2 e2
    | .str s1, .str s2 => s1 == s2
    | .arr l1, .arr l2 =>
      l1.length == l2.length
        && (l1.zip l2).all fun (x, y) => pyEqFuel fuel x y
    | .obj e1, .obj e2 =>
      -- パーサ・本モジュールの構成はキー一意を保つ(Python dict と同型)
      e1.length == e2.length
        && e1.all fun (k, v) =>
          match (Json.Value.obj e2).get? k with
          | some w => pyEqFuel fuel v w
          | none => false
    | _, _ => false

/-- Python `a == b`(JSON 値)。fuel は深さの上界として直列化長を渡す
(1 段のネストは最低 2 文字を消費するため、深さ < 直列化長)。 -/
def pyEq (a b : Json.Value) : Bool := pyEqFuel (a.render.length + 1) a b

private def pyContains (l : List Json.Value) (v : Json.Value) : Bool :=
  l.any (pyEq · v)

/-- Python set 的 dedup(挿入順・`==` 同値は合流)。 -/
def pyDedup (l : List Json.Value) : List Json.Value :=
  l.foldl (fun acc v => if pyContains acc v then acc else acc ++ [v]) []

private def withIdx (l : List α) : List (Nat × α) :=
  (l.foldl (fun (acc : Nat × List (Nat × α)) a =>
    (acc.1 + 1, (acc.1, a) :: acc.2)) (0, [])).2.reverse

/-- Python `isinstance(x, int)`(bool は int の部分型。指数付き 10 進 =
float 由来は非 int)。 -/
private def isPyInt : Json.Value → Bool
  | .bool _ => true
  | .num _ 0 => true
  | _ => false

/-- `d.get(key, default)`。 -/
def getOr (v : Json.Value) (key : String) (dflt : Json.Value) : Json.Value :=
  (v.get? key).getD dflt

/-- `d.get(key)`(欠落は None)。 -/
def getN (v : Json.Value) (key : String) : Json.Value :=
  getOr v key .null

def isObj : Json.Value → Bool
  | .obj _ => true
  | _ => false

/-- Python の hashable 判定(dict キー・set 要素に使える値)。 -/
private def isHashable : Json.Value → Bool
  | .arr _ => false
  | .obj _ => false
  | _ => true

private def strTake (s : String) (n : Nat) : String :=
  String.ofList (s.toList.take n)

private def strDropChars (s : String) (n : Nat) : String :=
  String.ofList (s.toList.drop n)

/-- state.py `SHA_OR_MARKER_RE`: `^[0-9a-f]{64}$|^(ABSENT|UNKNOWN)$`。 -/
def shaOrMarker (s : String) : Bool :=
  s == "ABSENT" || s == "UNKNOWN"
    || (s.length == 64
        && s.toList.all fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f'))

/-! ## フィールドバリデータ(state.py L202–295) -/

/-- `require_list`: 非 list はエラー 1 件。 -/
def requireListErr (v : Json.Value) (label : String) : List String :=
  match v with
  | .arr _ => []
  | _ => [s!"{label} must be a list."]

/-- `require_string_list` の走査核(構造的再帰 — S-T5 の帰納対象)。`ok` は
一度 false になると回復しない(Python の `ok = False` 代入と同値)。エラーの
出現順は走査順そのもの。 -/
def rslGo (label : String) : List Json.Value → Nat → Bool → Bool × List String
  | [], _, ok => (ok, [])
  | item :: rest, i, ok =>
    if isNonEmptyString item then rslGo label rest (i + 1) ok
    else
      let (ok', errs) := rslGo label rest (i + 1) false
      (ok', s!"{label}[{i}] must be a non-empty string." :: errs)

/-- `require_string_list`: (ok, errors)。ok=false は呼び出し側の
`continue` / リセットに対応する。 -/
def requireStringList (v : Json.Value) (label : String)
    (allowEmpty : Bool := true) : Bool × List String :=
  match v with
  | .arr items =>
    if !allowEmpty && items.isEmpty then
      (false, [s!"{label} must not be empty."])
    else rslGo label items 0 true
  | _ => (false, [s!"{label} must be a list."])

/-- `validate_id`: 非空文字列かつ `{prefix}-[A-Za-z0-9_+-]+` の全量一致。 -/
def validateId (v : Json.Value) (pfx label : String) : Bool × List String :=
  let ok := match v with
    | .str s => isNonEmptyString (.str s) && Model.validIdShape pfx s
    | _ => false
  if ok then (true, [])
  else (false, [s!"{label} id must match {pfx}-[A-Za-z0-9_+-]+."])

/-- `validate_unique_ids` の走査核(構造的再帰 — S-T5 の帰納対象)。`seen` は
Python の既出 id 集合に対応する(dup でも fresh でも `s :: seen` を積む挙動
まで fold 版と同一)。 -/
def uidGo (pfx label : String) :
    List Json.Value → Nat → List String → List String
  | [], _, _ => []
  | item :: rest, i, seen =>
    if isObj item then
      let itemId := getN item "id"
      let (ok, idErrs) := validateId itemId pfx s!"{label}.items[{i}]"
      if ok then
        match itemId with
        | .str s =>
          if seen.contains s then
            s!"{label} contains duplicate id: {s}."
              :: uidGo pfx label rest (i + 1) (s :: seen)
          else uidGo pfx label rest (i + 1) (s :: seen)
        | _ => uidGo pfx label rest (i + 1) seen
      else idErrs ++ uidGo pfx label rest (i + 1) seen
    else s!"{label}.items[{i}] must be an object."
      :: uidGo pfx label rest (i + 1) seen

/-- `validate_unique_ids`。 -/
def validateUniqueIds (items : List Json.Value) (pfx label : String) :
    List String :=
  uidGo pfx label items 0 []

/-- `validate_evidence`。 -/
private def validateEvidence (d : Domain) (v : Json.Value) (label : String)
    (allowEmpty : Bool := false) (requireSuccess : Bool := false) : List String :=
  match v with
  | .arr items =>
    let emptyErr := if !allowEmpty && items.isEmpty then
      [s!"{label} must not be empty."] else []
    emptyErr ++ (withIdx items).foldl (init := []) fun errs (i, ev) =>
      if isObj ev then
        let errs := if isNonEmptyString (getN ev "type") then errs
          else errs ++ [s!"{label}[{i}].type must be a non-empty string."]
        if getN ev "type" == .str "command" then
          let errs := if isNonEmptyString (getN ev "command") then errs
            else errs ++ [s!"{label}[{i}].command must be a non-empty string."]
          if !isPyInt (getN ev "exit_code") then
            errs ++ [s!"{label}[{i}].exit_code must be an integer."]
          else if requireSuccess && !pyEq (getN ev "exit_code") (.num 0 0) then
            errs ++ [s!"{label}[{i}].exit_code must be 0 for completed work evidence."]
          else errs
        else match d.evidenceLedgerTypes.find? (getN ev "type" == .str ·) with
          | some ty =>
            if isNonEmptyString (getN ev "ledger") then errs
            else errs ++ [s!"{label}[{i}].ledger must name a {ty}-ledger entry "
              ++ "(§22)."]
          | none => errs
      else errs ++ [s!"{label}[{i}] must be an object."]
  | _ => [s!"{label} must be a list."]

/-! ## project_index.json(§8.1 registry、state.py L734–757 / L3188–3239) -/

/-- Python `bound_project_from_index`: 単一 `project` オブジェクト、または
未バインド(None)。複数登録形(複数形 `projects` キー)と非 object の
`project` は ValueError = `.error`(呼び出し側が fail-closed に die へ写す)。 -/
def boundProjectFromIndex (index : Json.Value) : Except String (Option Json.Value) :=
  if (index.get? "projects").isSome then
    .error ("project_index.json carries a plural 'projects' key; the registry "
      ++ "is a single 'project' object (§8.1)")
  else
    match index.get? "project" with
    | none | some .null => .ok none
    | some (.obj entries) => .ok (some (.obj entries))
    | some _ => .error "project_index.json 'project' is not an object"

/-- Python `binding_integrity_warnings`(§5.2、§8.1)。`index` は
project_index.json の読み取り結果(`.absent` = is_file() 偽 → 警告なし)。 -/
def bindingIntegrityWarnings (index : RawFile) (title : String) : List String :=
  match index with
  | .absent => []
  | _ =>
    let (idx, diag) := readJsonOrEmpty "project_index.json" index
    if diag.isSome then
      ["project_index.json is unreadable; 1:1 binding cannot be verified (§8.1)."]
    else
      match boundProjectFromIndex idx with
      | .error e =>
        [s!"project_index.json violates 1 control plane = 1 project ({e}); repair it (§8.1)."]
      | .ok none => []
      | .ok (some project) =>
        let boundTitle := getN project "title"
        if boundTitle.truthy && !pyEq boundTitle (.str title) then
          [s!"project_index.json is bound to {pyRepr boundTitle}, not "
            ++ s!"the validated project {pyReprStr title} (one control "
            ++ "plane, one project — §5.2)."]
        else []

/-- Python `enforce_bound_project` の決定核(I-018、§18.1)。`.error` は
die 文言、`.ok none` = バインドなし(続行)、`.ok (some rel)` = 呼び出し側が
`CONTROL_ROOT / rel` を解決して `--project` と照合する。 -/
def enforceBoundDecision (index : RawFile) : Except String (Option String) := do
  let isFile := index != .absent
  let (idx, diag) := readJsonOrEmpty "project_index.json" index
  match diag with
  | some d =>
    if isFile then
      -- I-021: 読めない registry は mutating transition を止める
      throw s!"project_index.json is unreadable ({d}); repair it (git restore) before mutating state."
  | none => pure ()
  match boundProjectFromIndex idx with
  | .error e =>
    if isFile then
      throw s!"{e}; repair it (git restore) before mutating state."
    else
      pure none
  | .ok none => pure none
  | .ok (some project) =>
    match project.get? "project_root" with
    | some (.str rel) =>
      if (Text.pyStrip rel).isEmpty then
        throw ("project_index.json 'project' lacks project_root; repair it "
          ++ "(git restore) before mutating state.")
      else pure (some rel)
    | _ =>
      throw ("project_index.json 'project' lacks project_root; repair it "
        ++ "(git restore) before mutating state.")

/-- `enforce_bound_project` の不一致 die 文言(パス解決後)。 -/
def boundMismatchMessage (projectRoot boundRoot : String) : String :=
  s!"--project resolves to {projectRoot}, but this control plane is bound to "
    ++ s!"{boundRoot} (one control plane, one project). Re-bind with "
    ++ "`just init <path> --force` (human-only) before mutating another "
    ++ "project's state."

/-! ## ensure(state.py L765–946) -/

/-- I-021: 初期化済み state ディレクトリの gate-holding 欠損は再構築せず
die。`missing` は `gateStateFiles` の順に IO シェルが観測した欠損。 -/
def ensureRefusalMessage (missing : List String) : String :=
  "gate-holding state file(s) missing from the initialized state "
    ++ s!"directory: {String.intercalate ", " missing}. Rebuilding them from "
    ++ "defaults would erase latched stop gates (I-021); restore them "
    ++ "from the last checkpoint (git restore), then `just resume` "
    ++ "(META.md §13.5)."

private def optStr : Option String → Json.Value
  | some s => .str s
  | none => .null

/-- Python `initial_state`(キー順・既定値まで同一)。`essenceSha` は
`sha256_file(ctx.essence)`(不在は none = null)。`essencesManifest` は
bootstrap 時の essences/ マニフェスト anchor(§13.1-10 拡張 — ledger 不在時の
baseline。essences/ 不在は空)。 -/
def initialState (d : Domain) (now title : String) (essenceSha : Option String)
    (essencesManifest : List (String × String) := []) :
    List (String × Json.Value) := [
  ("state_index.json", .obj [
    ("schema_version", .str schemaVersion),
    -- 投影台帳の面と順序は軸(`Domain.projectionLedgers`)が 1 箇所で決める
    ("canonical", .obj (
      [("essence", Json.Value.str "../../ESSENCE.md"),
       ("project", .str "project.json")]
      ++ d.projectionLedgers.map (fun n => (n, Json.Value.str (n ++ ".json")))
      ++ [("context", .str "context.json"),
          ("validation", .str "validation.json"),
          ("reflection", .str "reflection.jsonl"),
          ("runs", .str "runs.jsonl"),
          ("high_risk_changes", .str "high_risk_changes.jsonl"),
          ("lessons", .str "lessons.jsonl")])),
    ("priority_order", .arr [
      .str "ESSENCE.md",
      .str (d.controlDirName ++ "/state/spec.json"),
      .str (d.controlDirName ++ "/state/todo.json"),
      .str "implementation"])]),
  ("project.json", .obj [
    ("schema_version", .str schemaVersion),
    ("id", .str "P-001"),
    ("title", .str title),
    ("status", .str "active"),
    ("created_at", .str now),
    ("essence_sha256", optStr essenceSha),
    ("essences_manifest", Predicates.assetsManifestJson essencesManifest),
    ("last_run_id", .null),
    -- §19.1-10: 正式なサイクル連番。start-run だけが進め、agent は project.json を
    -- 書けない(§8.2)ので、reflection の cycle 刻印は自己申告ではなく事実になる。
    ("cycle_seq", .num 0 0)]),
  ("spec.json", .obj [
    ("schema_version", .str schemaVersion),
    ("projected_from_essence_sha256", optStr essenceSha),
    ("projected_at", .null),
    ("items", .arr [])]),
  ("todo.json", .obj [
    ("schema_version", .str schemaVersion),
    ("batch_policy", .obj [
      ("default_batch_size", .num 3 0),
      ("max_batch_size", .num 5 0),
      ("max_context_cost_per_batch", .num 8 0),
      ("prefer_same_batch_group", .bool true),
      ("avoid_mixing_high_risk_items", .bool true),
      ("avoid_mixing_executors", .bool true)]),
    ("active_batch", .arr []),
    ("items", .arr [])]),
  ("recommendations.json", .obj [
    ("schema_version", .str schemaVersion), ("items", .arr [])]),
  ("blockers.json", .obj [
    ("schema_version", .str schemaVersion), ("items", .arr [])]),
  ("context.json", .obj [
    ("schema_version", .str schemaVersion),
    -- §14.1 / §19.3: completion phase。既定 "must"、human resume のみが
    -- "extended_approved" へ進める(state.py の同名コメントの写し)
    ("phase", .str defaultPhase),
    ("stop_policy", .obj [
      ("stop_after_idle_cycles", .num defaultStopAfterIdleCycles 0),
      ("stop_after_infra_fails", .num defaultStopAfterInfraFails 0)]),
    ("progress", .obj [
      ("last_signature", .null),
      ("idle_cycles_since_progress", .num 0 0),
      ("infra_fails_since_ok", .num 0 0),
      ("last_progress_at", .null),
      ("last_checked_at", .null)]),
    ("reset_policy", .obj [
      ("hard_threshold_context_usage", .num 8 1),
      ("reset_after_failed_attempts", .num 3 0),
      ("reset_after_changed_files", .num 25 0),
      ("reset_after_completed_todos", .num 5 0),
      ("reset_after_decisions", .num 5 0)]),
    ("counters", .obj [
      ("context_usage_estimate", .num 0 1),
      ("failed_attempts_since_reset", .num 0 0),
      ("changed_files_since_reset", .num 0 0),
      ("completed_todos_since_reset", .num 0 0),
      ("important_decisions_since_reset", .num 0 0),
      ("major_spec_rewrite_since_reset", .bool false),
      ("high_risk_change_completed", .bool false)]),
    ("handoff", .obj [
      ("written_at", .null),
      ("summary", .null),
      ("next_actions", .arr []),
      ("open_questions", .arr [])])]),
  ("validation.json", .obj [
    ("schema_version", .str schemaVersion),
    ("last_validated_at", .null),
    ("status", .str "unknown"),
    ("errors", .arr []),
    ("warnings", .arr [])])]
  -- ドメイン台帳の雛形。**列の末尾に置く**のは、この列が `lookup` にしか
  -- 使われない(書く順序は `canonicalJson` が決める)ため — 共通面が必ず先に
  -- 勝つので、ドメインが共通面と同名の台帳を宣言しても seed を乗っ取れない。
  ++ d.extraLedgers.map (fun n => (n ++ ".json", Json.Value.obj [
    ("schema_version", .str schemaVersion), ("items", .arr [])]))

/-! ## context.json の framework 面とドメイン軸の衝突(§14.1 / §31.1 R-13) -/

/-- framework が意味を与える `context.json` の**最上位キー**。列挙を複製せず、
ensure が書く canonical な初期 context そのものから導くので、framework が面を
足したときにこの集合が腐らない(`stopPayloadCollisions` と同じ規律)。 -/
def contextFrameworkKeys (d : Domain) : List String :=
  match (initialState d "" "" none).lookup "context.json" with
  | some (.obj entries) => entries.map Prod.fst
  | _ => []

/-- ドメインの cycle 承認マーカー(§14.1)が名乗ってしまった framework 面。

空でなければならない。マーカーは resume が**立て**、成功 cycle の終端が
**下ろす**ので、交わりがあると framework の面がマーカーの上げ下げで書き換わる —
`phase` なら must 境界の判断が消え、`progress` ならカウンタが丸ごと消える。
どちらも「軸を 1 本足しただけ」で静かに起きる。各製品の `Domain` が交わりの
無さを `#guard` で凍結する。 -/
def cycleAuthorizationCollisions (d : Domain) : List String :=
  d.cycleAuthorizationFlags.filter (contextFrameworkKeys d).contains

-- 参照ドメイン(軸なし)と fixtureRich(全軸あり)の凍結。各製品も自分の
-- Domain に同じ #guard を置く(S-T4 / S-T6 の保存定理はこの不等式が前提)。
#guard cycleAuthorizationCollisions Looper.Domain.fixture == []
#guard cycleAuthorizationCollisions Looper.Domain.fixtureRich == []
/-- `cmd_ensure` の registry 更新核(§8.1)。`index` は project_index.json の
読み取り結果(Python は診断なしの `read_json_or_empty` — 読めなければ空)。
返り値: 書き込むべき index(`none` = 変更なしで書かない)。`.error` は
die 文言(enforce_bound_project の背後では到達しないが fail-closed を保つ)。 -/
def ensureIndexUpdate (index : RawFile) (alreadyRegistered : Bool)
    (title projectRootRel stateRootRel now : String) :
    Except String (Option Json.Value) := do
  let (idx, _) := readJsonOrEmpty "project_index.json" index
  let idx := if (idx.get? "schema_version").isSome then idx
    else idx.set "schema_version" (.str schemaVersion)
  let existing? ← (boundProjectFromIndex idx).mapError
    fun e => s!"{e}; repair it (git restore) before registering the project."
  let project := match existing? with
    | some p => p
    | none => Json.Value.obj []
  let before := project
  let project := if (project.get? "id").isSome then project
    else project.set "id" (.str "P-001")
  let project := if (project.get? "created_at").isSome then project
    else project.set "created_at" (.str now)
  let project := ((project.set "title" (.str title)).set
    "project_root" (.str projectRootRel)
    |>.set "project_state_root" (.str stateRootRel)).set "status" (.str "active")
  let idx := idx.set "project" project
  if !pyEq project before || !alreadyRegistered then
    pure (some idx)
  else
    pure none

/-- `cmd_ensure` の stdout payload。 -/
def ensurePayload (created : List String) : Json.Value :=
  .obj [("ensured", .bool true), ("created", .arr (created.map .str))]

/-! ## won't 警告(state.py L518–614、§2.1.2-3 / §20.2-5) -/

/-- `_WONT_DEPENDENCY_RE`(IGNORECASE は ASCII 小文字化で対応)。 -/
private def wontDependencyRelated (lower : String) : Bool :=
  ["依存", "dependenc", "パッケージ", "package"].any (Text.containsSub lower ·)

/-- `_WONT_DEPENDENCY_NEG_RE`。`do(n't| not) add` は 2 展開で写す。 -/
private def wontDependencyNegated (lower : String) : Bool :=
  ["増やさない", "追加しない", "禁止", "don't add", "do not add",
   "no new", "not add", "never add"].any (Text.containsSub lower ·)

/-- `_DEPENDENCY_MANIFEST_RE`(`(^|/)name$` = basename 全量一致)。post-M3
追加(§31.2-45): Pipfile / Lake 系 3 種(リゾルバ設定・toolchain pin は
guard 側のみ — SyncPairs D-006 の凍結差集合)。 -/
def isDependencyManifest (path : String) : Bool :=
  let base := (path.splitOn "/").getLastD ""
  ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
   "pyproject.toml", "uv.lock", "poetry.lock", "Pipfile", "Cargo.toml",
   "Cargo.lock", "go.mod", "go.sum", "Gemfile", "Gemfile.lock",
   "composer.json", "composer.lock",
   "lakefile.lean", "lakefile.toml", "lake-manifest.json"].contains base
    || (base.startsWith "requirements" && base.endsWith ".txt"
        && base.length ≥ "requirements".length + ".txt".length)

/-- `\w`(Python Unicode word 文字)の裁定済み近似: ASCII 英数 + `_` +
CJK/かな(`Essence.isCjkChar`)。それ以外の非 ASCII word 文字(アクセント付き
ラテン等)は認識しない(META.md §31.2 凍結 — 警告ヒューリスティクスの
引用パス開始文字にのみ影響)。 -/
private def isWordChar (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')
    || c == '_' || Essence.isCjkChar c

private def isQuoteOpen (c : Char) : Bool :=
  c == '`' || c == '「' || c == '\'' || c == '"'

private def isQuoteClose (c : Char) : Bool :=
  c == '`' || c == '」' || c == '\'' || c == '"'

private def isPathBodyChar (c : Char) : Bool :=
  isWordChar c || c == '.' || c == '/' || c == '-'

/-- 開き引用符直後からの 1 マッチ試行: word 文字 1 個 + パス本体文字
(word・ドット・スラッシュ・ハイフン)の最大連 + 末尾スラッシュ + 閉じ
引用符。本体クラスの最大取りで一意に決まる(閉じ引用符はクラス外なので
バックトラックは発生しない)。成功時は (捕捉, 閉じ引用符の後続)。 -/
private def tryQuotedPath : List Char → Option (String × List Char)
  | [] => none
  | w :: rest =>
    if !isWordChar w then none
    else
      let run := rest.takeWhile isPathBodyChar
      match rest.drop run.length with
      | c :: remaining =>
        if isQuoteClose c && run.getLast? == some '/' then
          some (String.ofList (w :: run), remaining)
        else none
      | [] => none

private def quotedPathScan : Nat → List Char → List String
  | 0, _ => []
  | _ + 1, [] => []
  | fuel + 1, c :: rest =>
    if isQuoteOpen c then
      match tryQuotedPath rest with
      | some (capture, remaining) => capture :: quotedPathScan fuel remaining
      | none => quotedPathScan fuel rest
    else quotedPathScan fuel rest

/-- `_WONT_QUOTED_PATH_RE.findall(text)`: won't 文中の引用パス
(`` `legacy/` `` / 「src/」等)の捕捉列。 -/
def wontQuotedPaths (text : String) : List String :=
  quotedPathScan (text.length + 1) text.toList

/-- Python `wont_violation_warnings`(fail-soft)。`changes?` は
`project_worktree_changes` の結果(none = git 不可 = 何も検査しない)。 -/
def wontViolationWarnings (d : Domain) (wontItems : List String)
    (changes? : Option (List String)) : List String :=
  if wontItems.isEmpty then []
  else
    match changes? with
    | none => []
    | some [] => []
    | some allChanges =>
      let changes := allChanges.filter
        (fun p => !p.startsWith (d.controlDirName ++ "/"))
      wontItems.foldl (init := []) fun out text =>
        let lower := Text.lowerStr text
        let depHits :=
          if wontDependencyRelated lower && wontDependencyNegated lower then
            changes.filter isDependencyManifest
          else []
        let hits := (wontQuotedPaths text).foldl (init := depHits)
          fun hits quoted =>
            let pfx := String.ofList
              (quoted.toList.dropWhile fun c => c == '.' || c == '/')
            hits ++ changes.filter fun p =>
              (p.startsWith pfx || Text.containsSub ("/" ++ p) ("/" ++ pfx))
                && !hits.contains p
        if hits.isEmpty then out
        else
          let shown := String.intercalate ", " (hits.take 5)
            ++ (if hits.length > 5 then "…" else "")
          out ++ ["possible won't violation (§2.1.2, §20.2-5): ESSENCE.md won't "
            ++ s!"“{strTake (Text.normalizeWs text) 80}” vs uncommitted change(s) "
            ++ s!"{shown}. Surface this to the human — the deterministic deny "
            ++ "fence itself is a human-approved High-risk Recommendation "
            ++ "(§2.1.2-1), never something to add silently."]

/-- Python `project_worktree_changes` のパース側: `git status --porcelain
--untracked-files=all -- .` の stdout から PROJECT_ROOT 相対のパス集合を
作る(3 文字のステータス列を剥ぎ、strip → 両端の `"` を剥ぎ、git root と
PROJECT_ROOT の字句差分を prefix として除去、ソート済み一意)。 -/
def parseWorktreeChanges (gitRoot projectRoot porcelain : String) : List String :=
  let gp := (gitRoot.splitOn "/").filter (· ≠ "")
  let pp := (projectRoot.splitOn "/").filter (· ≠ "")
  let pfx :=
    if gp == pp then ""
    else if gp.isPrefixOf pp then String.intercalate "/" (pp.drop gp.length) ++ "/"
    else ""
  let stripQuotes (s : String) : String :=
    String.ofList (((s.toList.dropWhile (· == '"')).reverse.dropWhile
      (· == '"')).reverse)
  let paths := (Text.splitLinesPy porcelain).foldl (init := []) fun acc line =>
    if line.length ≤ 3 then acc
    else
      let path := stripQuotes (Text.pyStrip (strDropChars line 3))
      let path := if !pfx.isEmpty && path.startsWith pfx then
        strDropChars path pfx.length else path
      if acc.contains path then acc else path :: acc
  paths.mergeSort (· ≤ ·)

/-! ## recipe ポインタ ↔ インスタンス整合(state.py L994–1099、§29.4) -/

/-- PROJECT_ROOT 直下の 1 インスタンス(`<dir>/recipe.lock.json`)の観測。
`lock` は dict にパースできた場合のみ some(Python の
`lock if isinstance(lock, dict) else None`)。 -/
structure RecipeLockObs where
  rel : String
  lock : Option Json.Value

/-- ESSENCE.md の 1 ポインタ名に対する CONTROL_ROOT/recipes の観測。
`sourceHash` は IO シェルが「dir が実在し、かつ同名インスタンスがある」
名前についてだけ計算する(Python の遅延評価に対応)。 -/
structure RecipeDirObs where
  name : String
  isDir : Bool
  sourceHash : Option String

/-- `essence_recipe_pointers`(OSError → [])。不正 UTF-8 は validate では
placeholder 判定が先にハードエラーになるため [] で構わない。 -/
def essencePointersOf : EssenceRead → List (String × Nat)
  | .file bytes =>
    match String.fromUTF8? bytes with
    | some text => Essence.recipePointers text
    | none => []
  | _ => []

/-- `essence_wont_items`(OSError → [])。柵の節名はドメイン軸。 -/
def essenceWontItemsOf (d : Domain) : EssenceRead → List String
  | .file bytes =>
    match String.fromUTF8? bytes with
    | some text => Essence.essenceWontItems d text
    | none => []
  | _ => []

/-- ドメインが特別扱いする節(`Domain.essenceTrustHeading?`)の active 内容行
(正規化済み)。節を持たないドメインでは空 — **機構は全ドメインに在り、軸の値が
発火を決める**。 -/
def essenceTrustItemsOf (d : Domain) : EssenceRead → List String
  | .file bytes =>
    match String.fromUTF8? bytes with
    | some text => (Essence.essenceTrustItems d text).map Text.normalizeWs
    | none => []
  | _ => []

/-- Essence → Spec の機械的 trace source。比較は空白正規化した section item
の完全一致で行い、短い部分文字列による見かけ上の trace を許さない。見出し、
空行、機械 directive は source ではない。見出し構成自体は強制しない。 -/
def essenceTraceItems (text : String) : List String :=
  Text.dedup ((Essence.semanticLines text).filterMap fun raw =>
    let stripped := Text.pyStrip raw
    if stripped.isEmpty || (Essence.mdHeading? raw).isSome then none
    else
      let item := (Essence.itemBody? raw).getD stripped
      let normalized := Text.normalizeWs item
      if normalized.startsWith "deps:" || normalized.startsWith "recipe:"
          || normalized.startsWith "profile:" then none
      else some normalized)

def essenceTraceItemsOf : EssenceRead → List String
  | .file bytes =>
    match String.fromUTF8? bytes with
    | some text => essenceTraceItems text
    | none => []
  | _ => []

/-- §11.5 の profile 宣言検査(警告のみ 2 種 — §29.4 の recipe 前例に倣い
停止ゲートは追加しない。正値の宣言は人間の意図そのものなので informational
warning も置かない)。invalid / conflict はどちらも standard へ縮退して発効
しない(`ProfileScan.effective`)ため、この warning は「宣言したつもりが
効いていない」を人間へ可視化する唯一の面である。不正 UTF-8 は placeholder
判定が先にハードエラーになるため [] で構わない(`essencePointersOf` と同じ
裁定)。 -/
def profileWarnings : EssenceRead → List String
  | .file bytes =>
    match String.fromUTF8? bytes with
    | some text =>
      match Classify.scanProfile text with
      | .invalid raw =>
        [s!"ESSENCE.md declares an invalid profile value {pyReprStr raw}; "
          ++ "the closed set is standard / auto-approve / unsandboxed, and "
          ++ "the deployment runs as standard until the human fixes the "
          ++ "line (§11.5)."]
      | .conflict =>
        ["ESSENCE.md declares conflicting profile values; declare exactly "
          ++ "one, and the deployment runs as standard until the human "
          ++ "fixes the lines (§11.5)."]
      | _ => []
    | none => []
  | _ => []

/-- §11.6-1 の `writable:` 宣言検査(警告のみ — profile と同じ裁定)。
パース不能なパターンは発効しない(安全側)ため、この warning は「許可した
つもりが効いていない」を人間へ可視化する唯一の面である。

**既定 read-only のドメインでだけ発火する。** 対象実装が Agent の作業面その
ものであるドメイン(`writePolicy = .implementation`)では `writable:` に解除
すべき既定が無く、警告は人間へのノイズにしかならない — 段は常設で、軸の値が
発火を決める。 -/
def writableWarnings (d : Domain) : EssenceRead → List String
  | .file bytes =>
    match d.writePolicy with
    | .implementation => []
    | .readOnlyExcept _ =>
      match String.fromUTF8? bytes with
      | some text =>
        (Core.GlobHier.writablePatterns text).filterMap fun raw =>
          if (Core.GlobHier.parsePattern? raw).isSome then none
          else some (s!"ESSENCE.md declares an unparseable writable: pattern "
            ++ s!"{pyReprStr raw}; the dialect is /-separated segments with "
            ++ "*, ?, and a whole-segment ** only (no character classes, no "
            ++ "escapes, no empty segments), and the pattern grants nothing "
            ++ "until the human fixes it (§11.6-1).")
      | none => []
  | _ => []

/-- 有効な lock が名乗る recipe 名(IO シェルが hash 計算の要否判定に使う)。 -/
def recipeLockNames (locks : List RecipeLockObs) : List String :=
  locks.filterMap fun l => do
    let lk ← l.lock
    match lk.get? "recipe" with
    | some (.str s) => if (Text.pyStrip s).isEmpty then none else some s
    | _ => none

private def groupLookup (name : String)
    (groups : List (String × List (String × Json.Value))) :
    List (String × Json.Value) :=
  ((groups.find? (·.1 == name)).map (·.2)).getD []

private def groupAppend (name : String) (entry : String × Json.Value)
    (groups : List (String × List (String × Json.Value))) :
    List (String × List (String × Json.Value)) :=
  if groups.any (·.1 == name) then
    groups.map fun (n, es) => if n == name then (n, es ++ [entry]) else (n, es)
  else groups ++ [(name, [entry])]

private def badLockWarning (rel : String) : String :=
  s!"{rel} is unreadable or lacks a `recipe` name; the instance's "
    ++ "provenance cannot be verified (§29.4)."

/-- Python `recipe_pointer_warnings`(§29.4、警告のみ)。 -/
def recipePointerWarnings (pointers : List (String × Nat))
    (locks : List RecipeLockObs) (dirs : List RecipeDirObs) : List String :=
  -- lock の走査: 不正 lock の警告と名前ごとのグルーピング(挿入順)
  let (lockWarnings, lockByName) := locks.foldl
    (init := (([] : List String),
      ([] : List (String × List (String × Json.Value)))))
    fun (out, groups) l =>
      match l.lock with
      | some lk =>
        (match lk.get? "recipe" with
         | some (.str s) =>
           if (Text.pyStrip s).isEmpty then (out ++ [badLockWarning l.rel], groups)
           else (out, groupAppend s (l.rel, lk) groups)
         | _ => (out ++ [badLockWarning l.rel], groups))
      | none => (out ++ [badLockWarning l.rel], groups)
  -- ポインタの走査
  let pointerWarnings := pointers.foldl (init := []) fun out (name, major) =>
    let dirObs := dirs.find? (·.name == name)
    if !((dirObs.map (·.isDir)).getD false) then
      out ++ [s!"ESSENCE.md points at unknown recipe {pyReprStr name}@{major} "
        ++ s!"(no CONTROL_ROOT/recipes/{name}/); fix the pointer or add "
        ++ "the recipe original (§29.2)."]
    else
      let entries := groupLookup name lockByName
      if entries.isEmpty then
        out ++ [s!"recipe {name}@{major} is specified in ESSENCE.md but no "
          ++ "instance is installed (no recipe.lock.json under "
          ++ "PROJECT_ROOT); instantiation is a pending High-Risk Todo "
          ++ "(§29.3)."]
      else
        let currentHash := (dirObs.bind (·.sourceHash)).getD ""
        entries.foldl (init := out) fun out (rel, lk) =>
          let versionV := getN lk "version"
          let version := if versionV.truthy then pyStr versionV else ""
          let out :=
            if ((version.splitOn ".").headD "") != toString major then
              out ++ [s!"recipe instance {rel} was installed from "
                ++ s!"{name}@{if version.isEmpty then "?" else version} but "
                ++ s!"ESSENCE.md points at @{major}; align the pointer or "
                ++ "re-instantiate (§29.4)."]
            else out
          match lk.get? "source_sha256" with
          | some (.str recorded) =>
            if !(Text.pyStrip recorded).isEmpty && recorded != currentHash then
              out ++ [s!"recipe original {name} changed since instance {rel} was "
                ++ "installed (source hash drift); the vendored instance "
                ++ "never auto-follows — review whether a re-instantiation "
                ++ "is wanted (§29.4)."]
            else out
          | _ => out
  -- ポインタなしインスタンス
  let pointed := pointers.map (·.1)
  let orphanWarnings := lockByName.foldl (init := []) fun out (name, entries) =>
    if pointed.contains name then out
    else entries.foldl (init := out) fun out (rel, _) =>
      out ++ [s!"recipe instance {rel} ({name}) has no matching "
        ++ "`recipe:` pointer in ESSENCE.md; record the adoption in "
        ++ "the Essence or remove the instance (§29.4)."]
  lockWarnings ++ pointerWarnings ++ orphanWarnings

/-! ## cmd_validate 本体(state.py L1102–1402) -/

/-- validate の入力(すべて IO シェルが観測して注入する)。 -/
structure Inputs where
  /-- 製品(ドメインパック)が注入する軸(抽出計画 D-9)。executor 語彙・
  制御ルート名・診断文言の綴りはここから導出する。**既定値を置かない**。 -/
  domain : Domain
  title : String
  /-- `ctx.state_dir.is_dir()`(validation.json 温存判定に使う)。 -/
  stateInitialized : Bool
  essence : EssenceRead
  /-- `PROJECT_ROOT/essences/` の観測(§2.1.5)。`StopInputs.essencesDir` と
  同じ理由で既定値を持たない — 注入忘れが「essences/ 不在」として静かに
  成立してはならない。 -/
  essences : EssencesRead
  stateIndex : RawFile
  project : RawFile
  spec : RawFile
  todo : RawFile
  /-- ドメイン台帳(`Domain.extraLedgers` の各面、キーは `<面>.json`)の生
  読み取り。共通台帳と同じく apply-projection の prospective 差し替えを受ける。
  順序は消費点(`canonicalJsonInputs`)が軸から引き直すので、ここは集合として
  持てばよい — 欠落面は `.absent` として現れ、共通の構造検査が報告する。 -/
  ledgers : List (String × RawFile)
  recommendations : RawFile
  blockers : RawFile
  context : RawFile
  validation : RawFile
  reflection : RawFile
  runs : RawFile
  highRisk : RawFile
  /-- §14.3 の知見台帳(構造検証のみ — 内容は人間とエージェントの読み物)。 -/
  lessons : RawFile
  /-- 制御プレーンの `control_runs.jsonl`(§8.1)。二重 run 台帳の分岐検出用。 -/
  controlRuns : RawFile
  /-- CONTROL_ROOT/.agent/state/project_index.json。 -/
  projectIndex : RawFile
  /-- won't 検査用の未コミット変更(none = git 不可、または won't なしで未取得)。 -/
  worktree : Option (List String)
  /-- `Domain.observePaths` が要求した作業ツリー観測(対象 root 相対パス →
  生バイト列の `sha256:<hex>`、不在は none)。`essences` と同じ理由で既定値を
  持たない — 注入忘れが「観測できなかった」として静かに成立してはならない。 -/
  observations : List (String × Option String)
  recipeLocks : List RecipeLockObs
  recipeDirs : List RecipeDirObs
  now : String

structure Outcome where
  /-- stdout に出す validation payload(§20.5 温存時は既存ファイルの内容)。 -/
  payload : Json.Value
  /-- validation.json を書き直すか(§20.5: 意味不変なら書かない)。 -/
  write : Bool
  /-- exit 1(エラーあり)か exit 0 か。温存時も現在の判定に従う。 -/
  hasErrors : Bool
  /-- §20.5-3 の**鮮度マーカー**。`PROJECT_STATE_ROOT/tmp/`(gitignore 済み)
  へ毎回書かれる、「validate が最後に走った時刻」の記録。 -/
  checkStamp : Json.Value

/-- §20.5-3: `last_validated_at` は「診断が最後に**変わった**時刻」であって
「コマンドが最後に走った時刻」ではない(§20.5-1 の温存判定がそう定義して
いる)。ところが `just status` はその温存された時刻を素の "Validation" 行に
出しており、人間にもエージェントにも「検証が古い」と読めた — 実走行では、
エージェントが「apply-projection の bundle 受理こそが検証パスの証拠だ」と
いう経験則を handoff で伝承するところまで行った。

正しい表示には「最後に走った時刻」が要るが、それを validation.json に書くと
§20.5-1 の冪等性(同一診断の再検査で worktree を汚さない = I-014)が壊れる。
そこで **gitignore 済みの `PROJECT_STATE_ROOT/tmp/`** に別ファイルとして置く:
git 追跡外なので毎回書いても worktree は clean のまま、status はそこから
「いつ検査したか」を読む。 -/
def checkStamp (now : String) (payload : Json.Value) : Json.Value :=
  .obj [
    ("last_checked_at", .str now),
    ("status", getOr payload "status" (.str "unknown")),
    ("last_validated_at", getN payload "last_validated_at")]

/-- 鮮度マーカーのファイル名(`PROJECT_STATE_ROOT/tmp/` 相対)。 -/
def checkStampFile : String := "validation_check.json"

def statusNotIn (v : Json.Value) (allowed : List String) : Bool :=
  match v with
  | .str s => !allowed.contains s
  | _ => true

/-- canonical JSON 1 ファイルの構造検証(欠落・パース不能・非 object・
schema_version)。返り値は (パース済み dict?, エラー列)。「存在するのに
読めない」(OSError)と不正 UTF-8 は Python の未捕捉例外 = `.error`。 -/
private def structuralJson (name : String) (raw : RawFile) :
    Except String (Option Json.Value × List String) :=
  match raw with
  | .absent => .ok (none, [s!"Missing canonical state file: {name}"])
  | .ioError e => .error s!"{name}: {e}"
  | .text contents =>
    match Json.parse contents with
    | .error e => .ok (none, [s!"Invalid JSON in {name}: {e}"])
    | .ok v =>
      if isObj v then
        let sv := getN v "schema_version"
        if !pyEq sv (.str schemaVersion) then
          .ok (some v,
            [s!"{name}: schema_version {pyRepr sv} != {pyReprStr schemaVersion}"])
        else .ok (some v, [])
      else .ok (none, [s!"{name}: top-level value must be an object."])

private def structuralJsonl (name : String) (raw : RawFile) :
    Except String (List String) :=
  match raw with
  | .absent => .ok [s!"Missing canonical log file: {name}"]
  | .ioError e => .error s!"{name}: {e}"
  | .text contents =>
    match parseJsonl contents with
    | .ok _ => .ok []
    | .error e => .ok [s!"Invalid JSONL in {name}: {e}"]

/-- `{item.get("id"): item for item in items if isinstance(item, dict)}`
(位置は初出、値は最後の代入)。キーの hashable 検査は呼び出し側で済ませる。 -/
def indexById (items : List Json.Value) :
    List (Json.Value × Json.Value) :=
  items.foldl (init := []) fun acc s =>
    if isObj s then
      let id := getN s "id"
      if acc.any (pyEq ·.1 id) then
        acc.map fun (k, v) => if pyEq k id then (k, s) else (k, v)
      else acc ++ [(id, s)]
    else acc

/-! ### 証明可能化された区画関数(S-T5)

以下は旧 `validateCore` の forIn ループ群を名前付き純粋関数へ分離したもの
(§31.2-34 の `stopAssemble` 分離と同型の挙動保存リファクタ)。エラー・警告の
文言と蓄積順、throw の発生順は分離前と同一であり、`validateCore` はこれらの
連接に縮む。共有前段の再計算は参照透過性により無害。 -/

/-- essences/ ⇄ ESSENCE.md の双方向整合(§2.1.5)。読取不能な essences/ は
ハードエラー(I-021 の exit-code 規律 — `essencesManifest` と同じ向き)。 -/
def essenceAssetErrors (d : Domain) (essence : EssenceRead) (assets : EssencesRead) :
    Except String (List String) :=
  match assets with
  | .ioError e => .error s!"essences/ is unreadable ({e})"
  | assets => .ok (Predicates.essenceAssetIssues d essence assets)

/-- ESSENCE.md 見出し契約(§2.1.1'・§13.1-15)。should-stop と**同一の純粋
関数**(`Predicates.essenceStructureIssues`)を流用する — validate 側で判定を
書き直すと、停止するのに validate が通る(あるいはその逆の)不一致が生まれる。
missing / placeholder の間は保留(それぞれ独立のエラーが先に立つ)。 -/
def essenceStructureErrors (d : Domain) (essence : EssenceRead) : List String :=
  Predicates.essenceStructureIssues d essence

/-- 構造検証(§20.1): ESSENCE.md(不在エラー / placeholder エラー)。 -/
def essenceErrors (d : Domain) (essence : EssenceRead) :
    Except String (List String) := do
  match essence with
  | .absent => pure ["ESSENCE.md does not exist in PROJECT_ROOT."]
  | _ =>
    if ← Predicates.essenceIsPlaceholder d essence then
      pure ["ESSENCE.md is still the " ++ d.displayName ++ " placeholder "
        ++ "(empty, the guide block, or an unfilled FILL section marker "
        ++ "remains); a human must write the real Essence before the loop "
        ++ "runs (§13.1-8)."]
    else pure []

/-- canonical JSON の観測列。順序は `canonicalJson` と同一 — ドメイン台帳の
位置は軸(`Domain.extraLedgers`)が決め、`Inputs.ledgers` の並びには依存
しない(欠落面は `.absent` として共通の構造検査へ落ちる)。 -/
def canonicalJsonInputs (i : Inputs) : List (String × RawFile) :=
  [("state_index.json", i.stateIndex), ("project.json", i.project),
   ("spec.json", i.spec), ("todo.json", i.todo)]
  ++ i.domain.extraLedgers.map (fun n =>
      let name := n ++ ".json"
      (name, (i.ledgers.lookup name).getD .absent))
  ++ [("recommendations.json", i.recommendations),
      ("blockers.json", i.blockers),
      ("context.json", i.context), ("validation.json", i.validation)]

/-- canonical JSONL 4 本の観測列。 -/
def canonicalJsonlInputs (i : Inputs) : List (String × RawFile) := [
  ("reflection.jsonl", i.reflection), ("runs.jsonl", i.runs),
  ("high_risk_changes.jsonl", i.highRisk), ("lessons.jsonl", i.lessons)]

/-- canonical JSON 列の構造検証(data には dict 化できたものだけ挿入順で
載る)。「存在するのに読めない」は先頭のものが `.error` になる(走査順 =
throw 順)。 -/
def structuralJsonAll : List (String × RawFile) →
    Except String (List (String × Json.Value) × List String)
  | [] => .ok ([], [])
  | (name, raw) :: rest => do
    let (parsed?, errs) ← structuralJson name raw
    let (data, restErrs) ← structuralJsonAll rest
    match parsed? with
    | some payload => pure ((name, payload) :: data, errs ++ restErrs)
    | none => pure (data, errs ++ restErrs)

/-- canonical JSONL 列の構造検証。 -/
def structuralJsonlAll : List (String × RawFile) → Except String (List String)
  | [] => .ok []
  | (name, raw) :: rest => do
    let errs ← structuralJsonl name raw
    let restErrs ← structuralJsonlAll rest
    pure (errs ++ restErrs)

/-- 構造検証済み data からの取り出し(欠落は空 dict)。 -/
def dataGet (data : List (String × Json.Value)) (name : String) : Json.Value :=
  ((data.find? (·.1 == name)).map (·.2)).getD (.obj [])

/-- `payload.get("items", [])` の list 化(非 list は空 — エラーは
各区画関数が `requireListErr` で報告する)。 -/
def itemsListOf (v : Json.Value) : List Json.Value :=
  match getOr v "items" (.arr []) with
  | .arr items => items
  | _ => []

/-- ドメイン検証 hook へ渡す観測(形状層 / 意味層)。
**消費点と証明が同じ式を名指せるように、組み立てを 1 箇所へ切り出してある** —
`validateCore` の内側に `let` で埋めると、定理は巨大な匿名式を書き下ろす羽目に
なり、hook の入力が変わるたびに証明の言明が壊れる。 -/
def ledgerInputsOf (i : Inputs) (data : List (String × Json.Value))
    (drift : Bool) : LedgerInputs := {
  ledgers := i.domain.extraLedgers.map fun n =>
    (n ++ ".json", dataGet data (n ++ ".json"))
  specItems := itemsListOf (dataGet data "spec.json")
  todoItems := itemsListOf (dataGet data "todo.json")
  essenceTrustItems := essenceTrustItemsOf i.domain i.essence
  drift
  observations := i.observations }

/-- spec.json 1 件分のフィールド検証。 -/
def specFieldErrors (s : Json.Value) : List String :=
  if isObj s then
    let sid := pyStr (getOr s "id" (.str "?"))
    (if !isNonEmptyString (getN s "title") then
      [s!"Spec {sid} title must be a non-empty string."] else [])
    ++ (if statusNotIn (getN s "status") specStatuses then
      [s!"Spec {sid} status must be one of {specStatusesRepr}."] else [])
    ++ (if statusNotIn (getN s "priority") priorities then
      [s!"Spec {sid} priority must be one of {prioritiesRepr}."] else [])
  else []

/-- spec.json.items 区画(id 一意性 → フィールド検証)。 -/
def specSectionErrors (spec : Json.Value) : List String :=
  match getOr spec "items" (.arr []) with
  | .arr items =>
    validateUniqueIds items "S" "Spec" ++ items.flatMap specFieldErrors
  | other => requireListErr other "spec.json.items"

/-- §8.1 / §13.5: 二重 run 台帳の分岐検出。run lifecycle は project 側
`runs.jsonl` と control 側 `control_runs.jsonl` の**両方**へ同じレコードを
書くが、書き込みの間に中断が入ると片側にしか残らない。実走行 2026-08-12 では
`interrupted` で終わった run が control 側にだけ残り、project 側には start
イベントすら無かった — 人間は runs.jsonl の実行時間を読んで停滞を切り分けて
おり、片側にしか無い run はその読みを静かに誤らせる。

エラーではなく **warning** にする理由: 分岐は「記録の欠け」であって不整合な
判断の材料ではなく、これで loop を止めると中断の後始末が checkpoint すら
作れなくなる(I-021 の向きと逆)。可視化すれば人間が `just resume --force`
で閉じられる。読めない台帳はここでは黙る(JSONL 構造検査が別に報告する)。

**検査するのは control → project の一方向だけであり、しかも control 側は
この project へ帰属する記録に絞る。** 理由は 2 つの非対称である:
(a) `control_runs.jsonl` は制御プレーン全体のログで、束縛を跨いで蓄積する —
    レコードの `project` で絞らないと、別 project(あるいは再束縛前の同一
    プレーン)の run を「欠落」と報告してしまう。
(b) `control_runs.jsonl` は gitignore 対象、`runs.jsonl` は commit 対象である —
    workspace を fresh clone すると control 側だけが空になるので、
    「project にあって control に無い」は正常状態であり報告しても雑音にしかならない。
観測された欠陥(2026-08-12)はちょうど反対の向き — control にだけ残った run —
であり、それが人間の run-duration triage を静かに誤らせる側でもある。 -/
def runLedgerDivergenceWarnings (title : String)
    (projectRuns controlRuns : RawFile) : List String :=
  let idsOf (name : String) (raw : RawFile) (ownProjectOnly : Bool) :
      Option (List String) :=
    let (records, diag) := readJsonlOrEmpty name raw
    if diag.isSome then none
    else some (Text.dedup (records.filterMap fun r =>
      let mine := !ownProjectOnly || r.get? "project" == some (.str title)
      match r.get? "run_id" with
      | some (.str s) => if s.isEmpty || !mine then none else some s
      | _ => none))
  match idsOf "runs.jsonl" projectRuns false,
      idsOf "control_runs.jsonl" controlRuns true with
  | some projectIds, some controlIds =>
    let onlyControl := controlIds.filter (!projectIds.contains ·)
    if onlyControl.isEmpty then [] else
      [s!"run ledger divergence: {String.intercalate ", " onlyControl} "
        ++ "recorded in the control plane (control_runs.jsonl) for this project "
        ++ "but absent from the project runs.jsonl — a cycle was interrupted "
        ++ "between the two appends; run-duration triage on runs.jsonl will "
        ++ "under-report (§8.1, §13.5)."]
  | _, _ => []

/-- Spec item 1 件の `essence_refs` のうち、現在の ESSENCE.md の対象
セクション項目と(空白差を除いて)一致しない ref の原文一覧。非文字列要素は
`requireStringList` の管轄なのでここでは数えない。 -/
def staleEssenceRefsOf (sourceItems : List String) (s : Json.Value) :
    List String :=
  match getN s "essence_refs" with
  | .arr refs => refs.filterMap fun ref =>
    match ref with
    | .str text =>
      if sourceItems.contains (Text.normalizeWs text) then none else some text
    | _ => none
  | _ => []

/-- Essence → Spec の権威トレース。各 Spec は `essence_refs` に、現在の
ESSENCE.md の対象セクション項目を 1 件以上、空白差を除いて完全一致で持つ。
`drift = true`(spec.json の投影 hash が現 ESSENCE.md と乖離 — 人間が
Essence を編集し、まだ再投影されていない設計上の一時状態)の間は、ref の
不一致は構造的必然であり per-Spec error にしない: 集約は validateCore の
drift warning が担い、stale 投影を**書く**経路は apply-projection の stamp
一致要求(§20.2-8)が塞ぐ。形状違反(欠落・空・非 string list)は drift 中も
error である(§20.2-7)。 -/
def specEssenceTraceErrors (drift : Bool) (sourceItems : List String)
    (specItems : List Json.Value) : List String :=
  specItems.flatMap fun s =>
    if !isObj s then []
    else
      let sid := pyStr (getOr s "id" (.str "?"))
      let (ok, errs) := requireStringList (getN s "essence_refs")
        s!"Spec {sid}.essence_refs" (allowEmpty := false)
      if !ok then errs
      else if drift then []
      else (staleEssenceRefsOf sourceItems s).map fun text =>
        s!"Spec {sid}.essence_refs contains no exact current "
          ++ s!"ESSENCE.md item: {pyReprStr text}."

/-- drift warning の集約表示用: 現 ESSENCE.md と一致しない ref を 1 件以上
持つ Spec の id 一覧(§20.2-7)。 -/
def driftStaleSpecIds (sourceItems : List String)
    (specItems : List Json.Value) : List String :=
  specItems.filterMap fun s =>
    if isObj s && !(staleEssenceRefsOf sourceItems s).isEmpty then
      some (pyStr (getOr s "id" (.str "?")))
    else none

/-- todo.json.items 区画(id 一意性のみ先行 — フィールド検証は §20.2 の
`todoTraceChecks`)。 -/
def todoUniqueErrors (todo : Json.Value) : List String :=
  match getOr todo "items" (.arr []) with
  | .arr items => validateUniqueIds items "T" "Todo"
  | other => requireListErr other "todo.json.items"

/-- recommendations.json 1 件分の検証(errors, warnings)。 -/
def recItemChecks (r : Json.Value) : List String × List String :=
  if isObj r then
    let rid := pyStr (getOr r "id" (.str "?"))
    let errs := if statusNotIn (getN r "status") recStatuses then
      [s!"Recommendation {rid} status must be one of {recStatusesRepr}."]
    else []
    let gateWarns := if Predicates.recommendationGatesLoop r
        && !isNonEmptyString (getN r "reason") then
      [s!"Recommendation {rid} gates the loop on human "
        ++ "input but has no reason; the human cannot see why from the "
        ++ "status output (§13.4)."]
    else []
    let keyWarns :=
      ["requires_human_approval", "human_input_required"].flatMap fun key =>
        match r.get? key with
        | some (.bool _) | none => []
        | some v =>
          [s!"Recommendation {rid}.{key} is "
            ++ s!"{pyRepr v}, not a boolean; only boolean true "
            ++ "gates the loop (§21.4), so this record silently "
            ++ "fails open — fix the type."]
    (errs, gateWarns ++ keyWarns)
  else ([], [])

/-- recommendations.json.items 区画(errors, warnings)。 -/
def recSection (recommendations : Json.Value) : List String × List String :=
  match getOr recommendations "items" (.arr []) with
  | .arr items =>
    (validateUniqueIds items "R" "Recommendation"
        ++ items.flatMap fun r => (recItemChecks r).1,
      items.flatMap fun r => (recItemChecks r).2)
  | other => (requireListErr other "recommendations.json.items", [])

/-- blockers.json 1 件分の検証(errors, warnings)。 -/
def blockerItemChecks (b : Json.Value) : List String × List String :=
  if isObj b then
    let bid := pyStr (getOr b "id" (.str "?"))
    let errs := if statusNotIn (getN b "status") blockerStatuses then
      [s!"Blocker {bid} status must be one of {blockerStatusesRepr}."]
    else []
    let warns := if statusNotIn (getN b "type") blockerTypes then
      [s!"Blocker {bid} has unknown type "
        ++ s!"{pyRepr (getN b "type")} (known: {blockerTypesRepr}; "
        ++ "only essence_blocking stops the loop, §21.6)."]
    else []
    (errs, warns)
  else ([], [])

/-- blockers.json.items 区画(errors, warnings)。 -/
def blockerSection (blockers : Json.Value) : List String × List String :=
  match getOr blockers "items" (.arr []) with
  | .arr items =>
    (validateUniqueIds items "B" "Blocker"
        ++ items.flatMap fun b => (blockerItemChecks b).1,
      items.flatMap fun b => (blockerItemChecks b).2)
  | other => (requireListErr other "blockers.json.items", [])

/-- 非 hashable id の検査(Python: dict キー / set 要素の TypeError =
exit 2)。走査は先頭からで文言は一定のため `any` と等価。 -/
def unhashableIdCheck (items : List Json.Value) (message : String) :
    Except String Unit :=
  if items.any (fun s => isObj s && !isHashable (getN s "id")) then
    throw message
  else pure ()

/-- Todo が参照する Spec から解決できた valid priority 列(§20.1-12 の
期待値の母集合)。S-T5 (5) の証明対象単位。 -/
def todoRefPriorities (specIndex : List (Json.Value × Json.Value))
    (t : Json.Value) : List String :=
  (match getOr t "spec" (.arr []) with
    | .arr l => l
    | _ => []).filterMap fun sidV =>
    (specIndex.find? (fun (e : Json.Value × Json.Value) => pyEq e.1 sidV)).bind
      fun (_, specItem) =>
      match getN specItem "priority" with
      | .str p => if priorities.contains p then some p else none
      | _ => none

/-- 権威検証(§20.2)の Todo 1 件分: Todo → Spec トレース・evidence・
executor。返り値は (errors, warnings)。非 object の Todo は素通し
(object 違反は `validateUniqueIds` 側が報告する)。 -/
def todoTraceChecks (d : Domain) (specIndex : List (Json.Value × Json.Value))
    (t : Json.Value) : List String × List String :=
  if !isObj t then ([], [])
  else
    let tid := pyStr (getOr t "id" (.str "?"))
    let fieldErrs :=
      (if !isNonEmptyString (getN t "title") then
        [s!"Todo {tid} title must be a non-empty string."] else [])
      ++ (if statusNotIn (getN t "status") todoStatuses then
        [s!"Todo {tid} status must be one of {todoStatusesRepr}."] else [])
      ++ (if statusNotIn (getN t "priority") priorities then
        [s!"Todo {tid} priority must be one of {prioritiesRepr}."] else [])
      ++ (if getN t "risk_level" == .str "high"
            && !isNonEmptyString (getN t "target") then
        [s!"High-Risk Todo {tid} must have a non-empty target for supervised scope."]
        else [])
    let (specOk, specErrs) :=
      requireStringList (getN t "spec") s!"Todo {tid}.spec" (allowEmpty := false)
    if !specOk then (fieldErrs ++ specErrs, [])
    else
      let specIds := match getOr t "spec" (.arr []) with
        | .arr l => l
        | _ => []
      let traceErrs := specIds.flatMap fun sidV =>
        match specIndex.find? (pyEq ·.1 sidV) with
        | none => [s!"Todo {tid} references missing Spec {pyStr sidV}."]
        | some (_, specItem) =>
          if getN specItem "status" == .str "blocked"
              && (getN t "status" == .str "pending"
                || getN t "status" == .str "in_progress") then
            [s!"Active Todo {tid} references blocked Spec {pyStr sidV}."]
          else []
      -- §20.1-12: Todo priority = 参照 Spec の最強 priority(must 判定の単一
      -- 定義点は Spec.priority)。解決できた valid priority の Spec だけから
      -- 期待値を導き、Todo 側 priority の形状違反は fieldErrs に任せる
      let refPriorities := todoRefPriorities specIndex t
      let priorityLinkErrs :=
        if refPriorities.isEmpty || statusNotIn (getN t "priority") priorities
        then []
        else
          let expected := if refPriorities.contains "must" then "must"
            else "should"
          if getN t "priority" == .str expected then []
          else [s!"Todo {tid} priority must be '{expected}' — the strongest "
            ++ "priority of its referenced Specs (§20.1-12)."]
      let traceErrs := traceErrs ++ priorityLinkErrs
      let evErrs :=
        if getN t "status" == .str "done" then
          validateEvidence d (getN t "evidence") s!"Todo {tid}.evidence"
            (requireSuccess := true)
        else if (t.get? "evidence").isSome then
          validateEvidence d (getN t "evidence") s!"Todo {tid}.evidence"
            (allowEmpty := true)
        else []
      -- Python `t.get("executor") is None` はキー欠落と明示 null を
      -- 区別しない — どちらも「must declare executor」
      match getN t "executor" with
      | .null =>
        (fieldErrs ++ specErrs ++ traceErrs ++ evErrs
          ++ [s!"Todo {tid} must declare executor."], [])
      | executor =>
        if !isObj executor then
          (fieldErrs ++ specErrs ++ traceErrs ++ evErrs
            ++ [s!"Todo {tid}.executor must be an object."], [])
        else
          let mode := getN executor "mode"
          let modeErrs := if statusNotIn mode (executorModes d) then
            [s!"Todo {tid} has unknown executor.mode {pyRepr mode}."]
          else []
          let doneErrs := if getN t "status" == .str "done"
              && !(getN t "evidence").truthy then
            [s!"Todo {tid} is done without evidence (I-010)."]
          else []
          let canceledErrs := if getN t "status" == .str "canceled" then
            (if getN t "canceled_by" != .str "human"
                && getN t "canceled_by" != .str "essence_projection" then
              [s!"Canceled Todo {tid}.canceled_by must be 'human' or "
                ++ "'essence_projection'."] else [])
            ++ (if !isNonEmptyString (getN t "canceled_reason") then
              [s!"Canceled Todo {tid} must have a non-empty canceled_reason."] else [])
          else []
          let blockedWarns := if getN t "status" == .str "blocked"
              && !isNonEmptyString (getN t "blocked_reason") then
            [s!"Todo {tid} is blocked without blocked_reason; "
              ++ "the loop-gate diagnosis (§13.4) cannot explain this Todo "
              ++ "to the human."]
          else []
          (fieldErrs ++ specErrs ++ traceErrs ++ evErrs ++ modeErrs ++ doneErrs
              ++ canceledErrs,
            blockedWarns)

/-- §20.2 区画の errors 連接。 -/
def todoTraceErrors (d : Domain) (specIndex : List (Json.Value × Json.Value))
    (todoItems : List Json.Value) : List String :=
  todoItems.flatMap fun t => (todoTraceChecks d specIndex t).1

/-- §20.2 区画の warnings 連接。 -/
def todoTraceWarnings (d : Domain) (specIndex : List (Json.Value × Json.Value))
    (todoItems : List Json.Value) : List String :=
  todoItems.flatMap fun t => (todoTraceChecks d specIndex t).2

/-- todo.json.active_batch の list 形検証エラー(§9.3)。 -/
def activeBatchListErrors (todo : Json.Value) : List String :=
  (requireStringList (getOr todo "active_batch" (.arr []))
    "todo.json.active_batch").2

/-- 検証を通った active_batch(通らなければ空 = 以降の検査対象なし)。 -/
def activeBatchOf (todo : Json.Value) : List Json.Value :=
  if (requireStringList (getOr todo "active_batch" (.arr []))
      "todo.json.active_batch").1 then
    match getOr todo "active_batch" (.arr []) with
    | .arr l => l
    | _ => []
  else []

/-- active_batch → 実在しない Todo 参照のエラー。 -/
def batchMissingErrors (todoIndex : List (Json.Value × Json.Value))
    (activeBatch : List Json.Value) : List String :=
  activeBatch.flatMap fun itemId =>
    if !todoIndex.any (pyEq ·.1 itemId) then
      [s!"Active batch references missing Todo {pyStr itemId}."]
    else []

/-- active_batch が指す truthy な Todo 実体列。 -/
def batchTodosOf (todoIndex : List (Json.Value × Json.Value))
    (activeBatch : List Json.Value) : List Json.Value :=
  activeBatch.filterMap fun itemId =>
    (todoIndex.find? (pyEq ·.1 itemId)).bind fun (_, t) =>
      if t.truthy then some t else none

/-- バッチの risk_level 二値の dedup(§9.3 — 長さ > 1 = 混在)。 -/
def batchRiskDedup (batch : List Json.Value) : List Json.Value :=
  pyDedup (batch.map fun t =>
    Json.Value.bool (getN t "risk_level" == .str "high"))

/-- バッチの executor mode 列(Python: 非 dict executor は AttributeError、
非 hashable mode は TypeError — いずれも先頭の違反が exit 2)。 -/
def modesOf (d : Domain) : List Json.Value → Except String (List Json.Value)
  | [] => .ok []
  | t :: rest => do
    let mode ← match t.get? "executor" with
      | none => pure (Json.Value.str d.tool)
      | some executor =>
        if !isObj executor then
          -- Python: 非 dict executor への .get は AttributeError(exit 2)
          throw "active batch executor is not an object (AttributeError)"
        else
          let mode := getOr executor "mode" (.str d.tool)
          if !isHashable mode then
            -- Python: set への非 hashable 追加は TypeError(exit 2)
            throw "unhashable active batch executor mode (TypeError)"
          else pure mode
    let modes ← modesOf d rest
    pure (mode :: modes)

/-- バッチ排他律(§9.3): high-risk 混在と executor 混在。空バッチは検査
なし。risk エラーの push と modes の throw の順序は observable には非干渉
(throw 時は errors ごと破棄され exit 2)。 -/
def batchExclusivityErrors (d : Domain) (batch : List Json.Value) :
    Except String (List String) :=
  if batch.isEmpty then pure []
  else do
    let riskErrs := if (batchRiskDedup batch).length > 1 then
      ["Active batch mixes high-risk and normal Todos (§9.3)."]
    else []
    let modes ← modesOf d batch
    let modeErrs := if (pyDedup modes).length > 1 then
      ["Active batch mixes executors (§9.3)."]
    else []
    pure (riskErrs ++ modeErrs)

/-- High-risk 検証(§20.4)の 1 レコード分。 -/
def highRiskEntryErrors (idx : Nat) (rec : Json.Value) : List String :=
  if isObj rec then
    let path := pyStr (getOr rec "path" (.str "?"))
    (if !isNonEmptyString (getN rec "path") then
      [s!"high_risk_changes entry {idx} lacks path."] else [])
    ++ (["before_sha256", "after_sha256"].flatMap fun key =>
      let value := getN rec key
      let valid := match value with
        | .str s => shaOrMarker s
        | _ => false
      if !valid then
        [s!"high_risk_changes entry for {path} has invalid {key}: {pyRepr value}."]
      else [])
    ++ (if !isNonEmptyString (getN rec "risk_reason") then
      [s!"high_risk_changes entry for {path} lacks risk_reason."] else [])
  else [s!"high_risk_changes entry {idx} must be an object."]

/-- High-risk 検証(§20.4)— 読めないログは空として扱う(fail-open)。 -/
def highRiskErrors (records : List Json.Value) : List String :=
  (withIdx records).flatMap fun (idx, rec) => highRiskEntryErrors idx rec

/-- 成功条件 ↔ acceptance evidence の警告(§20.2-6、must 境界でのみ)。
`successConditions` / `acceptanceEvidenceMap` の Except 効果はこの関数の
内側で分離前と同順に発生する。 -/
def successWarnings (essence : EssenceRead)
    (specItems todoItems : List Json.Value) (driftNow : Bool) :
    Except String (List String) := do
  let mustPhaseComplete :=
    Predicates.mustPhaseCompleteFrom (todoItems.filter isObj) driftNow []
  let successConds ← successConditions essence
  if !successConds.isEmpty && mustPhaseComplete then
    let mapping ← acceptanceEvidenceMap successConds todoItems (.arr specItems)
    let unmapped := (mapping.filter fun m => !m.mapped).map
      fun m => Text.normalizeWs m.condition
    if !unmapped.isEmpty then
      let preview := String.intercalate "; "
        ((unmapped.take 3).map (strTake · 60))
      let more := if unmapped.length > 3 then "…" else ""
      pure [s!"{unmapped.length} of {successConds.length} ESSENCE.md "
        ++ "成功条件 map to no acceptance-check command evidence on a "
        ++ s!"done must-priority Todo ({preview}{more}); the must "
        ++ "completion is unverified against those stated 成功条件 "
        ++ "(§20.2-6, §22). Review the 成功条件 ↔ evidence mapping shown "
        ++ "by `just status` before approving the should phase "
        ++ "(§13.1-13)."]
    else pure []
  else pure []

/-- `cmd_validate` の純粋決定核。区画関数の連接であり、errors / warnings の
蓄積順・throw の発生順は分離前(= state.py)と同一。S-T5(§31.3)の証明
対象。 -/
def validateCore (i : Inputs) : Except String Outcome := do
  let essenceErrs ← essenceErrors i.domain i.essence
  let assetErrs ← essenceAssetErrors i.domain i.essence i.essences
  let structured ← structuralJsonAll (canonicalJsonInputs i)
  let data := structured.1
  let structErrs := structured.2
  let jsonlErrs ← structuralJsonlAll (canonicalJsonlInputs i)
  let spec := dataGet data "spec.json"
  let todo := dataGet data "todo.json"
  let recommendations := dataGet data "recommendations.json"
  let blockers := dataGet data "blockers.json"
  let specItems := itemsListOf spec
  let todoItems := itemsListOf todo
  let essenceTraceSources := essenceTraceItemsOf i.essence
  -- 権威検証(§20.2): Todo → Spec トレースと evidence / executor
  unhashableIdCheck specItems "unhashable spec id (TypeError)"
  let specIndex := indexById specItems
  let mustWarns := if !todoItems.isEmpty
      && !(todoItems.any fun t => isObj t && getN t "priority" == .str "must") then
    ["todo.json has items but no must-priority Todo; "
      ++ "completion (§19.3) is undecidable until priorities are graded."]
  else []
  -- Essence drift(投影ハッシュと現ファイルの照合)
  let currentEssence? ← Predicates.essenceSha256 i.essence
  let recorded := getN spec "projected_from_essence_sha256"
  let driftNow := match currentEssence? with
    | some cur => recorded.truthy && !pyEq (.str cur) recorded
    | none => false
  -- ドメイン台帳の検査(形状層 / 意味層)。読み取りと JSON 解釈は
  -- Looper 側で済ませ、hook には解釈済みの観測だけを渡す — 読み方が 2 系統に
  -- 割れると、片方だけが fail-safe を持つ事故になる。
  let ledgerInputs := ledgerInputsOf i data driftNow
  let ledgerShapeErrs := i.domain.ledgerShapeErrors ledgerInputs
  let ledgerMeaning := i.domain.ledgerMeaningIssues ledgerInputs
  let driftWarns := if driftNow then
    let staleIds := driftStaleSpecIds essenceTraceSources specItems
    let staleNote := if staleIds.isEmpty then "" else
      let preview := String.intercalate ", " (staleIds.take 3)
      let more := if staleIds.length > 3 then "…" else ""
      s!" {staleIds.length} Spec(s) ({preview}{more}) hold essence_refs that "
        ++ "no longer match the edited ESSENCE.md; they are reported here in "
        ++ "aggregate, not as per-Spec errors, until Spec is re-projected "
        ++ "(§20.2-7)."
    ["ESSENCE.md changed since the last Spec projection; "
      ++ "re-project Spec once the change is human-attested (the loop gates an "
      ++ "unreviewed change as essence_unreviewed_change, §13.1-10)."
      ++ staleNote ++ ledgerMeaning.driftNote]
  else []
  -- won't 検査(§2.1.2-3 / §20.2-5)
  let wontWarns := wontViolationWarnings i.domain
    (essenceWontItemsOf i.domain i.essence) i.worktree
  -- 成功条件 ↔ acceptance evidence(§20.2-6、must 境界でのみ警告)
  let successWarns ← successWarnings i.essence specItems todoItems driftNow
  -- バッチ排他律(§9.3)
  unhashableIdCheck todoItems "unhashable todo id (TypeError)"
  let todoIndex := indexById todoItems
  let batchErrs ← batchExclusivityErrors i.domain
    (batchTodosOf todoIndex (activeBatchOf todo))
  -- High-risk 検証(§20.4)
  let highRiskErrs :=
    highRiskErrors (readJsonlOrEmpty "high_risk_changes.jsonl" i.highRisk).1
  -- 1:1 binding(§5.2、§8.1)と recipe 整合(§29.4)— 警告のみ
  let bindingWarns := bindingIntegrityWarnings i.projectIndex i.title
  let recipeWarns := recipePointerWarnings (essencePointersOf i.essence)
    i.recipeLocks i.recipeDirs
  -- profile 宣言の可視化(§11.5 — invalid / conflict は standard へ縮退)
  let profileWarns := profileWarnings i.essence
  -- writable: 宣言の可視化(§11.6-1 — パース不能パターンは不発効)
  let writableWarns := writableWarnings i.domain i.essence
  -- 二重 run 台帳の分岐(§8.1、§13.5)— 中断で片側にしか残らなかった run
  let runLedgerWarns := runLedgerDivergenceWarnings i.title i.runs i.controlRuns
  let errors := essenceErrs ++ essenceStructureErrors i.domain i.essence ++ assetErrs
    ++ structErrs ++ jsonlErrs
    ++ specSectionErrors spec ++ todoUniqueErrors todo
    ++ ledgerShapeErrs
    ++ specEssenceTraceErrors driftNow essenceTraceSources specItems
    ++ (recSection recommendations).1 ++ (blockerSection blockers).1
    ++ todoTraceErrors i.domain specIndex todoItems
    ++ activeBatchListErrors todo
    ++ batchMissingErrors todoIndex (activeBatchOf todo)
    ++ batchErrs ++ highRiskErrs ++ ledgerMeaning.errors
  let warnings := (recSection recommendations).2 ++ (blockerSection blockers).2
    ++ todoTraceWarnings i.domain specIndex todoItems ++ mustWarns
    ++ driftWarns ++ wontWarns ++ successWarns ++ bindingWarns ++ recipeWarns
    ++ profileWarns ++ writableWarns ++ ledgerMeaning.warnings ++ runLedgerWarns
  -- payload 組み立てと §20.5 温存判定
  let status := if !errors.isEmpty then "error"
    else if !warnings.isEmpty then "warning" else "ok"
  let validation : Json.Value := .obj [
    ("schema_version", .str schemaVersion),
    ("last_validated_at", .str i.now),
    ("status", .str status),
    ("errors", .arr (errors.map .str)),
    ("warnings", .arr (warnings.map .str))]
  let hasErrors := !errors.isEmpty
  -- 温存判定は (payload, write) の対の選択に畳む(hasErrors は分岐に依存
  -- しない — S-T5 の glue が単一の return を分解できる形)
  let outPair :=
    if i.stateInitialized then
      let previous := (readJsonOrEmpty "validation.json" i.validation).1
      let dropTs := fun (v : Json.Value) =>
        match v with
        | .obj entries =>
          Json.Value.obj (entries.filter (·.1 != "last_validated_at"))
        | other => other
      if isNonEmptyString (getN previous "last_validated_at")
          && pyEq (dropTs previous) (dropTs validation) then
        (previous, false)
      else (validation, true)
    else (validation, false)
  return { payload := outPair.1, write := outPair.2, hasErrors,
           checkStamp := checkStamp i.now outPair.1 }

/-! ## コンパイル時テスト -/

-- pyEq: 数値横断・object の順序非依存・入れ子
#guard pyEq (.num 1 0) (.bool true)
#guard pyEq (.num 10 1) (.num 1 0)
#guard !pyEq (.str "1") (.num 1 0)
#guard pyEq (.obj [("a", .num 1 0), ("b", .null)]) (.obj [("b", .null), ("a", .bool true)])
#guard !pyEq (.obj [("a", .num 1 0)]) (.obj [("a", .num 1 0), ("b", .null)])
#guard pyEq (.arr [.obj [("x", .num 0 1)]]) (.arr [.obj [("x", .num 0 0)]])
#guard !pyEq (.arr [.num 1 0]) (.arr [.num 1 0, .num 2 0])

-- shaOrMarker
#guard shaOrMarker "ABSENT" && shaOrMarker "UNKNOWN"
#guard shaOrMarker (String.ofList (List.replicate 64 'a'))
#guard !shaOrMarker (String.ofList (List.replicate 64 'A'))
#guard !shaOrMarker (String.ofList (List.replicate 63 'a'))

-- validateId / validateUniqueIds
#guard (validateId (.str "S-001") "S" "Spec.items[0]").1
#guard (validateId (.str "R-LG-20260707T120000+0900-a1b2") "R" "x").1
#guard (validateId (.str "S-") "S" "Spec.items[0]").2
    == ["Spec.items[0] id must match S-[A-Za-z0-9_+-]+."]
#guard (validateId (.str "T-00 1") "T" "x").2 == ["x id must match T-[A-Za-z0-9_+-]+."]
#guard validateUniqueIds [.obj [("id", .str "S-1")], .obj [("id", .str "S-1")]] "S" "Spec"
    == ["Spec contains duplicate id: S-1."]
#guard validateUniqueIds [.str "x"] "S" "Spec" == ["Spec.items[0] must be an object."]

-- requireStringList
#guard (requireStringList (.arr []) "Todo T-1.spec" (allowEmpty := false)).2
    == ["Todo T-1.spec must not be empty."]
#guard (requireStringList (.arr [.str "S-1", .num 1 0]) "l").2
    == ["l[1] must be a non-empty string."]
#guard (requireStringList .null "todo.json.active_batch")
    == (false, ["todo.json.active_batch must be a list."])

-- validateEvidence: exit_code の isinstance(int)(bool は int、float は非 int)
#guard validateEvidence Domain.fixture (.arr [.obj [("type", .str "command"),
    ("command", .str "make test"), ("exit_code", .num 0 0)]]) "e"
    (requireSuccess := true) == []
#guard validateEvidence Domain.fixture (.arr [.obj [("type", .str "command"),
    ("command", .str "x"), ("exit_code", .num 0 1)]]) "e"
    == ["e[0].exit_code must be an integer."]
#guard validateEvidence Domain.fixture (.arr [.obj [("type", .str "command"),
    ("command", .str "x"), ("exit_code", .bool false)]]) "e"
    (requireSuccess := true) == []
#guard validateEvidence Domain.fixture (.arr [.obj [("type", .str "command"),
    ("command", .str "x"), ("exit_code", .bool true)]]) "e"
    (requireSuccess := true)
    == ["e[0].exit_code must be 0 for completed work evidence."]
#guard validateEvidence Domain.fixture (.arr []) "e" == ["e must not be empty."]

-- boundProjectFromIndex
#guard boundProjectFromIndex (.obj [("projects", .arr [])]) matches .error _
#guard boundProjectFromIndex (.obj [("project", .null)]) matches .ok none
#guard boundProjectFromIndex (.obj []) matches .ok none
#guard boundProjectFromIndex (.obj [("project", .str "x")]) matches .error _

-- enforceBoundDecision: 欠落 index は素通り、不正形は die 側
#guard enforceBoundDecision .absent matches .ok none
#guard enforceBoundDecision (.text "{broken") matches .error _
#guard enforceBoundDecision (.text "{\"project\": {\"project_root\": \"../p\"}}")
    matches .ok (some "../p")
#guard enforceBoundDecision (.text "{\"project\": {\"project_root\": \" \"}}")
    matches .error _
#guard enforceBoundDecision (.text "{\"project\": {\"title\": \"x\"}}")
    matches .error _

-- ensureIndexUpdate: 新規登録・変更なし・破損形
#guard ((ensureIndexUpdate .absent false "demo" "../demo" "../demo/.looper"
    "2026-01-01T00:00:00+09:00").toOption.bind (·.map (·.render)))
    == some ("{\"schema_version\": \"1.0.0\", \"project\": {\"id\": \"P-001\", "
      ++ "\"created_at\": \"2026-01-01T00:00:00+09:00\", \"title\": \"demo\", "
      ++ "\"project_root\": \"../demo\", \"project_state_root\": \"../demo/.looper\", "
      ++ "\"status\": \"active\"}}")
#guard (ensureIndexUpdate (.text ("{\"schema_version\": \"1.0.0\", \"project\": "
    ++ "{\"id\": \"P-001\", \"created_at\": \"t\", \"title\": \"demo\", "
    ++ "\"project_root\": \"../demo\", \"project_state_root\": \"../demo/.looper\", "
    ++ "\"status\": \"active\"}}")) true "demo" "../demo" "../demo/.looper" "now")
    matches .ok none
#guard (ensureIndexUpdate (.text "{\"projects\": []}") true "d" "r" "s" "n")
    matches .error _

-- wont: 引用パスと依存マニフェスト
#guard wontQuotedPaths "do not touch `legacy/` here" == ["legacy/"]
#guard wontQuotedPaths "「src/utils/」は対象外" == ["src/utils/"]
#guard wontQuotedPaths "no `x` and no 'docs/'" == ["docs/"]
#guard wontQuotedPaths "`.hidden/`" == []      -- 先頭は word 文字が必要
#guard isDependencyManifest "package.json" && isDependencyManifest "a/b/uv.lock"
#guard isDependencyManifest "requirements-dev.txt"
#guard !isDependencyManifest "requirements.txt.bak"
#guard !isDependencyManifest "mypackage.json"
#guard wontViolationWarnings Domain.fixture ["依存を増やさない"]
    (some ["package.json", ".looper/state/todo.json"])
    == ["possible won't violation (§2.1.2, §20.2-5): ESSENCE.md won't "
      ++ "“依存を増やさない” vs uncommitted change(s) package.json. Surface this "
      ++ "to the human — the deterministic deny fence itself is a human-approved "
      ++ "High-risk Recommendation (§2.1.2-1), never something to add silently."]
#guard wontViolationWarnings Domain.fixture ["`legacy/` は触らない"]
    (some [".looper/state/x.json"]) == []
#guard wontViolationWarnings Domain.fixture [] (some ["package.json"]) == []
#guard wontViolationWarnings Domain.fixture ["依存を追加しない"] none == []
-- 除外面は制御ルート名の軸から来る(両向きの凍結): 自分の制御面は won't 検査の
-- 対象外だが、別語幹のドメインから見れば同じパスはただの対象変更である
#guard wontViolationWarnings Domain.fixture ["依存を増やさない"]
    (some [".looper/package.json"]) == []
#guard (wontViolationWarnings { Domain.fixture with tool := "sample-tool" }
    ["依存を増やさない"] (some [".looper/package.json"])).length == 1

-- parseWorktreeChanges: prefix 剥ぎ・引用剥ぎ・ソート一意
#guard parseWorktreeChanges "/w" "/w/proj" " M proj/src/a.py\n?? \"proj/b c\"\n"
    == ["b c", "src/a.py"]
#guard parseWorktreeChanges "/w/proj" "/w/proj" "?? x.txt\n M x.txt\n" == ["x.txt"]
#guard parseWorktreeChanges "/other" "/w/proj" "?? y\n" == ["y"]

-- binding warnings
#guard bindingIntegrityWarnings .absent "demo" == []
#guard bindingIntegrityWarnings (.text "{broken") "demo"
    == ["project_index.json is unreadable; 1:1 binding cannot be verified (§8.1)."]
#guard bindingIntegrityWarnings
    (.text "{\"project\": {\"title\": \"other\"}}") "demo"
    == ["project_index.json is bound to 'other', not the validated project "
      ++ "'demo' (one control plane, one project — §5.2)."]
#guard bindingIntegrityWarnings
    (.text "{\"project\": {\"title\": \"demo\"}}") "demo" == []

-- recipe warnings: 不明レシピ・未インストール・version / hash drift・孤児
#guard recipePointerWarnings [("asl", 1)] [] [⟨"asl", false, none⟩]
    == ["ESSENCE.md points at unknown recipe 'asl'@1 (no CONTROL_ROOT/recipes/asl/); "
      ++ "fix the pointer or add the recipe original (§29.2)."]
#guard recipePointerWarnings [("asl", 1)] [] [⟨"asl", true, none⟩]
    == ["recipe asl@1 is specified in ESSENCE.md but no instance is installed "
      ++ "(no recipe.lock.json under PROJECT_ROOT); instantiation is a pending "
      ++ "High-Risk Todo (§29.3)."]
#guard recipePointerWarnings [("asl", 1)]
    [⟨"inst/recipe.lock.json", some (.obj [("recipe", .str "asl"),
      ("version", .str "1.0"), ("source_sha256", .str "h")])⟩]
    [⟨"asl", true, some "h"⟩] == []
#guard recipePointerWarnings [("asl", 2)]
    [⟨"inst/recipe.lock.json", some (.obj [("recipe", .str "asl"),
      ("version", .str "1.0"), ("source_sha256", .str "h2")])⟩]
    [⟨"asl", true, some "h"⟩]
    == ["recipe instance inst/recipe.lock.json was installed from asl@1.0 but "
      ++ "ESSENCE.md points at @2; align the pointer or re-instantiate (§29.4).",
      "recipe original asl changed since instance inst/recipe.lock.json was "
      ++ "installed (source hash drift); the vendored instance never "
      ++ "auto-follows — review whether a re-instantiation is wanted (§29.4)."]
#guard recipePointerWarnings []
    [⟨"inst/recipe.lock.json", some (.obj [("recipe", .str "asl")])⟩] []
    == ["recipe instance inst/recipe.lock.json (asl) has no matching `recipe:` "
      ++ "pointer in ESSENCE.md; record the adoption in the Essence or remove "
      ++ "the instance (§29.4)."]
#guard recipePointerWarnings [] [⟨"inst/recipe.lock.json", none⟩] []
    == ["inst/recipe.lock.json is unreadable or lacks a `recipe` name; the "
      ++ "instance's provenance cannot be verified (§29.4)."]

-- 区画関数(S-T5 分離)の文言・順序凍結
#guard (essenceErrors Domain.fixture .absent).toOption
    == some ["ESSENCE.md does not exist in PROJECT_ROOT."]
-- 見出し契約(§13.1-15)は should-stop と同一関数。missing / placeholder は保留
#guard essenceStructureErrors Domain.fixture .absent == []
#guard essenceStructureErrors Domain.fixture (.file "<!-- FILL: 目的 -->".toUTF8) == []
#guard essenceStructureErrors Domain.fixture (.file "# Why\nreal\n".toUTF8)
    == Predicates.essenceStructureIssues Domain.fixture (.file "# Why\nreal\n".toUTF8)
#guard (essenceStructureErrors Domain.fixture (.file "# Why\nreal\n".toUTF8)).head?
    == some "first heading must be `# ESSENCE — <title>`"
#guard (structuralJsonAll [("spec.json", .absent), ("todo.json", .text "{bad")])
    matches .ok ([], ["Missing canonical state file: spec.json",
      _])
#guard (structuralJsonAll [("spec.json", .ioError "boom")]) matches .error _
#guard specSectionErrors (.obj [("items", .str "x")])
    == ["spec.json.items must be a list."]
#guard specSectionErrors (.obj [("items", .arr [.obj [("id", .str "S-1"),
      ("title", .str "t"), ("status", .str "bad"), ("priority", .str "must")]])])
    == ["Spec S-1 status must be one of ['active', 'blocked', 'done', "
      ++ "'pending', 'superseded']."]
#guard (recSection (.obj [("items", .arr [.obj [("id", .str "R-1"),
      ("status", .str "proposed"), ("requires_human_approval", .str "yes")]])])).2
    == ["Recommendation R-1.requires_human_approval is 'yes', not a boolean; "
      ++ "only boolean true gates the loop (§21.4), so this record silently "
      ++ "fails open — fix the type."]
#guard (todoTraceChecks Domain.fixture [] (.obj [("id", .str "T-1"), ("title", .str "t"),
      ("status", .str "pending"), ("priority", .str "must"),
      ("spec", .arr [.str "S-1"]),
      ("executor", .obj [("mode", .str "looper")])])).1
    == ["Todo T-1 references missing Spec S-1."]
#guard (todoTraceChecks Domain.fixture [(.str "S-1", .obj [("status", .str "blocked")])]
      (.obj [("id", .str "T-1"), ("title", .str "t"),
        ("status", .str "pending"), ("priority", .str "must"),
        ("spec", .arr [.str "S-1"]),
        ("executor", .obj [("mode", .str "looper")])])).1
    == ["Active Todo T-1 references blocked Spec S-1."]
#guard (todoTraceChecks Domain.fixture [] (.obj [("id", .str "T-1"), ("title", .str "t"),
      ("status", .str "pending"), ("priority", .str "must"),
      ("spec", .arr [.str "S-1"])])).1
    == ["Todo T-1 references missing Spec S-1.", "Todo T-1 must declare executor."]
#guard (todoTraceChecks Domain.fixture [] (.obj [("id", .str "T-1")])).1
    == ["Todo T-1 title must be a non-empty string.",
      "Todo T-1 status must be one of ['blocked', 'canceled', 'done', "
        ++ "'in_progress', 'pending'].",
      "Todo T-1 priority must be one of ['must', 'should'].",
      "Todo T-1.spec must be a list."]
#guard (todoTraceChecks Domain.fixture [(.str "S-1", .obj [])] (.obj [("id", .str "T-1"),
      ("title", .str "t"), ("status", .str "blocked"), ("priority", .str "must"),
      ("spec", .arr [.str "S-1"]),
      ("executor", .obj [("mode", .str "looper")])])).2
    == ["Todo T-1 is blocked without blocked_reason; the loop-gate diagnosis "
      ++ "(§13.4) cannot explain this Todo to the human."]
#guard (batchExclusivityErrors Domain.fixture []).toOption == some []
#guard (batchExclusivityErrors Domain.fixture [.obj [("risk_level", .str "high")],
      .obj [("risk_level", .str "low")]]).toOption
    == some ["Active batch mixes high-risk and normal Todos (§9.3)."]
#guard (batchExclusivityErrors Domain.fixture [.obj [("executor", .obj [("mode", .str "human")])],
      .obj []]).toOption
    == some ["Active batch mixes executors (§9.3)."]
#guard (batchExclusivityErrors Domain.fixture [.obj [("executor", .str "x")]]) matches .error _
#guard (modesOf Domain.fixture [.obj [("executor", .obj [("mode", .arr [])])]])
  matches .error _
#guard highRiskErrors [.str "x"]
    == ["high_risk_changes entry 0 must be an object."]
#guard highRiskErrors [.obj [("path", .str "a.py"),
      ("before_sha256", .str "ABSENT"), ("after_sha256", .num 1 0),
      ("risk_reason", .str "r")]]
    == ["high_risk_changes entry for a.py has invalid after_sha256: 1."]
#guard batchMissingErrors [] [.str "T-9"]
    == ["Active batch references missing Todo T-9."]
#guard activeBatchOf (.obj [("active_batch", .arr [.str "T-1"])]) == [.str "T-1"]
#guard activeBatchOf (.obj [("active_batch", .arr [.num 1 0])]) == []
#guard activeBatchListErrors (.obj [("active_batch", .arr [.num 1 0])])
    == ["todo.json.active_batch[0] must be a non-empty string."]

-- essenceTraceItems: directive 行(deps: / recipe: / profile:)は trace source
-- にならない(§20.2-7)
#guard essenceTraceItems
    "# T\n- real item\ndeps: npm:x\nrecipe: asl@2\nprofile: auto-approve\n- another"
  == ["real item", "another"]
#guard essenceTraceItems "- profile: auto-approve" == []

-- profileWarnings(§11.5): invalid / conflict のみ警告、正値・不在は沈黙
#guard profileWarnings (.file "profile: auto-approve".toUTF8) == []
#guard profileWarnings (.file "## 前提事項\n- x".toUTF8) == []
#guard profileWarnings (.file "profile: poc".toUTF8)
  == ["ESSENCE.md declares an invalid profile value 'poc'; the closed set is "
    ++ "standard / auto-approve / unsandboxed, and the deployment runs as "
    ++ "standard until the human fixes the line (§11.5)."]
#guard profileWarnings
    (.file "profile: standard\nprofile: unsandboxed".toUTF8)
  == ["ESSENCE.md declares conflicting profile values; declare exactly one, "
    ++ "and the deployment runs as standard until the human fixes the lines "
    ++ "(§11.5)."]
#guard profileWarnings .absent == []

private def absentInputs (d : Domain) : Inputs := {
  domain := d,
  title := "demo", stateInitialized := false, essence := .absent,
  essences := .absent,
  stateIndex := .absent, project := .absent, spec := .absent, todo := .absent,
  ledgers := [],
  recommendations := .absent, blockers := .absent, context := .absent,
  validation := .absent, reflection := .absent, runs := .absent,
  highRisk := .absent, lessons := .absent, controlRuns := .absent,
  projectIndex := .absent, worktree := none, observations := [],
  recipeLocks := [], recipeDirs := [], now := "2026-01-01T00:00:00+09:00" }

private def errorsOf (o : Except String Outcome) : List String :=
  match o with
  | .ok out => match out.payload.get? "errors" with
    | some (.arr l) => l.filterMap Json.Value.asStr?
    | _ => []
  | .error _ => []

private def warningsOf (o : Except String Outcome) : List String :=
  match o with
  | .ok out => match out.payload.get? "warnings" with
    | some (.arr l) => l.filterMap Json.Value.asStr?
    | _ => []
  | .error _ => []

-- validateCore 全体(全 absent 入力): essence 1 + JSON 8 + JSONL 4 = 13 エラー
#guard match validateCore (absentInputs Domain.fixture) with
  | .ok o => o.hasErrors && !o.write
      && o.payload.get? "status" == some (.str "error")
      && (match o.payload.get? "errors" with
          | some (.arr l) => l.length == 13
          | _ => false)
  | .error _ => false
-- 軸を持つドメイン: 台帳面が canonical JSON に 1 本増え(13 → 14)、形状層と
-- 意味層の hook 出力がそれぞれ errors の**別の位置**へ届く(順序は errors 配列
-- の順序そのものなので、消費点が入れ替わると凍結が割れる)
#guard (errorsOf (validateCore (absentInputs Domain.fixtureRich))).length == 16
#guard (errorsOf (validateCore (absentInputs Domain.fixtureRich))).contains
  "shape:extra.json"
#guard (errorsOf (validateCore (absentInputs Domain.fixtureRich))).getLast?
  == some "meaning:0"
#guard (warningsOf (validateCore (absentInputs Domain.fixtureRich))).contains
  "trust:0"

-- 二重 run 台帳の分岐(§8.1、§13.5)
#guard runLedgerDivergenceWarnings "p" .absent .absent == []
#guard runLedgerDivergenceWarnings "p"
    (.text "{\"run_id\": \"R-1\", \"event\": \"start\"}\n")
    (.text "{\"run_id\": \"R-1\", \"project\": \"p\", \"event\": \"start\"}\n") == []
-- control にだけ残った run(観測された欠陥の向き)
#guard (runLedgerDivergenceWarnings "p" (.text "")
    (.text "{\"run_id\": \"R-1\", \"project\": \"p\", \"event\": \"start\"}\n")).length == 1
-- 別 project の control 記録は無関係(制御プレーンのログは束縛を跨いで蓄積する)
#guard runLedgerDivergenceWarnings "p" (.text "")
    (.text "{\"run_id\": \"R-1\", \"project\": \"other\", \"event\": \"start\"}\n") == []
-- project にだけある run は fresh clone の正常状態(control 側は gitignore)
#guard runLedgerDivergenceWarnings "p"
    (.text "{\"run_id\": \"R-2\", \"event\": \"start\"}\n") (.text "") == []
-- 読めない台帳は黙る(JSONL 構造検査が別に報告する)
#guard runLedgerDivergenceWarnings "p" (.text "not json\n")
    (.text "{\"run_id\": \"R-1\", \"project\": \"p\", \"event\": \"start\"}\n") == []

-- §20.5-3: 鮮度マーカー
#guard (checkStamp "T" (.obj [("status", .str "ok"),
    ("last_validated_at", .str "V")])).render
  == "{\"last_checked_at\": \"T\", \"status\": \"ok\", "
    ++ "\"last_validated_at\": \"V\"}"

end Looper.State.Validate
