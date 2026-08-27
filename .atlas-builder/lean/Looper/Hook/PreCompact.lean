import Looper.Core.Json
import Looper.Core.StaticConfig
import Looper.Domain

/-!
`Looper.Hook.PreCompact` — PreCompact hook(`<tool> hook pre-compact`)の
純粋決定核(META.md §14.1)。

移行元: `.claude/hooks/pre_compact_snapshot.py`(移行完了まで凍結)。
コンパクション直前に、post-compact セッションがディスクだけから復帰できるよう
`control_context.json` へ最小限の breadcrumb を追記する。

**I-021 の型設計(§31.4-5 の初出)**: 既存 canonical file の読み取り結果を
`CanonicalRead` として型で区別し、`unreadable` から既定値を構成する経路を
提供しない。初期スキーマの出発点になれるのは `absent`(ファイル不存在)だけで、
読めない・形状が壊れているファイルは skip(書き込みなし)に確定する。

Python 版との対応で意図した差(いずれも registry が壊れているか、実際の
Claude Code からは来ない入力の場合にだけ観測される):
- `compactions` が配列でない場合、Python は traceback(exit 1、書き込みなし)で
  落ちるが、Lean は I-021 の skip(exit 0、stderr 1 行、書き込みなし)にする
- 既存ファイルが不正 UTF-8 の場合、Python は traceback で落ちるが、Lean は
  unreadable(skip)にする
- stdin の JSON が object でない場合、Python は traceback で落ちるが、Lean は
  `{}` と同じ扱い(session_id / trigger は null)にする
- unreadable の stderr に含まれる理由文字列はパーサ実装依存であり、Python の
  例外文言とは一致しない(人間向け文言のみの差、§5.3)
-/

namespace Looper.Hook.PreCompact

open Looper.Core.Json (Value)

/-- 既存 canonical file の読み取り結果(I-021 の型設計)。
`unreadable` を受け取ってファイル内容を生成する関数は存在しない。 -/
inductive CanonicalRead where
  /-- ファイルが存在しない。初期スキーマから開始してよい唯一のケース。 -/
  | absent
  /-- 読めて JSON として妥当。 -/
  | readable (value : Value)
  /-- 存在するのに読めない/パースできない。触ってはならない(I-021)。 -/
  | unreadable (reason : String)

/-- 今回のコンパクションの breadcrumb。`sessionId` / `trigger` は hook stdin の
同名フィールドをそのまま写す(欠損は null)。 -/
structure Breadcrumb where
  /-- ISO 8601 タイムスタンプ(JSON キーは `at`)。`at` は Lean の予約語のため
  フィールド名だけ変える。 -/
  atTime : String
  sessionId : Value
  trigger : Value

/-- hook の帰結: アトミック書き込みすべき新しいファイル内容か、
I-021 によるスキップ(stderr 1 行、書き込みなし)か。 -/
inductive Action where
  | write (contents : String)
  | skip (stderrLine : String)

/-- compaction 後の復帰教示。対象側 state ルートの綴りは制御ルート名
(`.<tool>`)と同名なので、ドメイン軸から導出する(抽出計画 D-10)。 -/
def noteText (d : Domain) : String :=
  "Context compacted. Recover from disk: read project_index.json, then the active project's "
    ++ d.controlDirName ++ "/state/context.json and validation.json."

private def entryOf (d : Domain) (b : Breadcrumb) : Value :=
  .obj [("at", .str b.atTime), ("session_id", b.sessionId), ("trigger", b.trigger),
        ("note", .str (noteText d))]

/-- 直近 n 件だけ残す(Python の `[-n:]`)。 -/
private def lastN (n : Nat) (xs : List Value) : List Value :=
  xs.drop (xs.length - n)

/-- ファイル不存在時の初期スキーマ。`absent` からのみ到達する(I-021)。
schema_version は `Core.StaticConfig.schemaVersion`(D-009)。配布シード
(`notes` キーを持つ)との形状差は意図的凍結 — 裁定待ち(STATIC_CONFIG_LEAN_PROMOTION.md §8-1)。 -/
private def freshBase : Value :=
  .obj [("schema_version", .str Core.StaticConfig.schemaVersion),
        ("compactions", .arr [])]

private def unreadableSkip (reason : String) : String :=
  s!"[pre_compact_snapshot] control_context.json is unreadable ({reason}); skipping the snapshot instead of rebuilding it (I-021)."

private def notObjectSkip : String :=
  "[pre_compact_snapshot] control_context.json is not a JSON object; skipping the snapshot instead of rebuilding it (I-021)."

private def corruptCompactionsSkip : String :=
  "[pre_compact_snapshot] control_context.json has a non-array compactions field; skipping the snapshot instead of rebuilding it (I-021)."

/-- breadcrumb を追記し、直近 50 件に切り詰めた新しいファイル内容。
`compactions` キーは Python の `setdefault` と同じ規則(欠損は末尾に追加、
既存は位置保持)で更新する。配列でない `compactions` は形状破損として skip。 -/
private def appended (d : Domain) (data : Value) (b : Breadcrumb) : Action :=
  let render (v : Value) : Action := .write (v.renderPretty ++ "\n")
  match data.get? "compactions" with
  | some (.arr existing) =>
    render (data.set "compactions" (.arr (lastN 50 (existing ++ [entryOf d b]))))
  | none => render (data.set "compactions" (.arr [entryOf d b]))
  | some _ => .skip corruptCompactionsSkip

/-- 判定本体。書き込み内容が生成されるのは `absent`(初期スキーマ)と
`readable` な object だけ。それ以外はすべて skip(I-021)。 -/
def decide (d : Domain) (read : CanonicalRead) (b : Breadcrumb) : Action :=
  match read with
  | .unreadable reason => .skip (unreadableSkip reason)
  | .absent => appended d freshBase b
  | .readable (.obj entries) => appended d (.obj entries) b
  | .readable _ => .skip notObjectSkip

/-! ## コンパイル時テスト -/

private def testCrumb : Breadcrumb :=
  { atTime := "2026-07-16T02:30:00+09:00", sessionId := .str "s-1", trigger := .str "auto" }

private def actionText : Action → String
  | .write contents => "write:" ++ contents
  | .skip line => "skip:" ++ line

#guard actionText (decide Domain.fixture .absent testCrumb)
  == "write:{\n  \"schema_version\": \"1.0.0\",\n  \"compactions\": [\n    {\n      \"at\": \"2026-07-16T02:30:00+09:00\",\n      \"session_id\": \"s-1\",\n      \"trigger\": \"auto\",\n      \"note\": \"" ++ noteText Domain.fixture ++ "\"\n    }\n  ]\n}\n"
#guard actionText (decide Domain.fixture (.unreadable "boom") testCrumb)
  == "skip:[pre_compact_snapshot] control_context.json is unreadable (boom); skipping the snapshot instead of rebuilding it (I-021)."
#guard actionText (decide Domain.fixture (.readable (.arr [])) testCrumb)
  == "skip:[pre_compact_snapshot] control_context.json is not a JSON object; skipping the snapshot instead of rebuilding it (I-021)."
#guard actionText (decide Domain.fixture (.readable (.obj [("compactions", .str "x")])) testCrumb)
  == "skip:[pre_compact_snapshot] control_context.json has a non-array compactions field; skipping the snapshot instead of rebuilding it (I-021)."
-- compactions 欠損の object には setdefault と同じく末尾へ追加
#guard actionText (decide Domain.fixture (.readable
    (.obj [("schema_version", .str Core.StaticConfig.schemaVersion)])) testCrumb)
  == "write:{\n  \"schema_version\": \"1.0.0\",\n  \"compactions\": [\n    {\n      \"at\": \"2026-07-16T02:30:00+09:00\",\n      \"session_id\": \"s-1\",\n      \"trigger\": \"auto\",\n      \"note\": \"" ++ noteText Domain.fixture ++ "\"\n    }\n  ]\n}\n"
-- 50 件超は先頭から捨てる(直近 50 件)
#guard (Value.arr (lastN 2 [.num 1 0, .num 2 0, .num 3 0])).render == "[2, 3]"
#guard (Value.arr (lastN 5 [.num 1 0])).render == "[1]"

end Looper.Hook.PreCompact
