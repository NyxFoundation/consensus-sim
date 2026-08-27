import Looper.Core.Json
import Looper.Core.Doc
import Looper.State.Model
import Looper.State.Validate

/-!
`Looper.State.Append` — エージェントが書ける append-only 台帳
(`reflection.jsonl` / `lessons.jsonl`)の追記受理の純粋核(§8.2、§14.3)。

**なぜコマンドが要るのか。** 実走行 2026-08-12 まで、reflection.jsonl への
追記手段は Edit ツールによる手書きだけだった(`bin/<tool> state` の側に追記
コマンドが無く、追記は loop / human 専用の record-progress / end-run /
resume の副作用にしか存在しなかった)。結果として同一走行で 3 種の実害が
出ている:

1. **順序事故** — 「当時の最終行」への Edit アンカーを誤り、cycle 3 と 4 の
   エントリが物理順序で逆転したままコミットされた。append-only 原則により
   恒久化する。
2. **スキーマの揺れ** — あるエントリだけ `"kind": "cycle_reflection"` ではなく
   `"type": "cycle"` で、`open_questions` / `conflicts` キーが欠落した。
3. **転写ミス** — run_id のサフィックスが転写漏れした。

3 つとも「人間可読テキストを手で末尾へ足す」ことに内在する事故であり、
追記点を 1 つの遷移に閉じ込めれば同時に消える: 追記位置は常にファイル末尾
(1)、形は受理時に検査され(2)、事実フィールド(`at` / `cycle` / `run_id`)は
呼び出し側が書かず engine が canonical state から刻む(3)。

**engine が刻むフィールドは呼び出し側が指定できない。** 指定を黙って上書き
するのではなく拒否する — 「刻印は事実であって主張ではない」という区別が
消えると、転写ミスが再び「エージェントの申告」として台帳に入る。
-/

namespace Looper.State.Append

open Looper.Core
open Looper.Core.Doc
open Looper.State.Model

/-- 追記先の台帳。 -/
inductive Ledger where
  | reflection
  | lessons
  deriving Repr, BEq

def Ledger.fileName : Ledger → String
  | .reflection => "reflection.jsonl"
  | .lessons => "lessons.jsonl"

/-- engine が予約するフィールド(呼び出し側が指定したら拒否)。`recorded_by`
も含む: 誰が書いたかは遷移の性質であって申告事項ではない。`id` は lessons
でだけ実際に刻まれる(`record` の head 参照)が、reflection でも**予約**して
拒否する — 台帳間でキーの意味を揃え、自称 id が機械読者に「engine の刻印」と
誤読される形を作らないため(AP-004)。 -/
def stampedKeys : List String :=
  ["at", "cycle", "run_id", "recorded_by", "id"]

/-- reflection.jsonl の `type` のうち **framework が予約**するもの。loop /
resume の遷移だけが書く型で、エージェントが偽造すると「人間が resume した」
「loop が gate を上げた」という記録が捏造できてしまう(§13.1-10 の
attestation 台帳が agent-unwritable なのと同じ理由)。 -/
def reservedReflectionTypes : List String :=
  ["loop_gate", "context_reset", "human_resume"]

/-- エージェントが書ける reflection の `type` 語彙(§19.2-12)。閉じた集合に
するのは、走行間で台帳を機械的に読めるようにするため — 実走行で観測された
`kind: "cycle_reflection"` / `type: "cycle"` の揺れは、語彙が決まっていな
かったことの帰結である。 -/
def agentReflectionTypes : List String :=
  ["cycle", "decision", "conflict", "note"]

private def isNonEmptyStr (v : Json.Value) : Bool :=
  match v with
  | .str s => !(Text.pyStrip s).isEmpty
  | _ => false

/-- 省略可能な文字列リスト面の検査(存在するなら string list であること)。 -/
private def optionalStringList (entry : Json.Value) (key : String) :
    List String :=
  match entry.get? key with
  | none | some .null => []
  | some (.arr items) =>
    if items.all isNonEmptyStr then []
    else [s!"{key} must be a list of non-empty strings."]
  | some _ => [s!"{key} must be a list of non-empty strings."]

/-- 台帳ごとの必須・語彙検査。返り値は診断列(空 = 受理)。 -/
def entryErrors (ledger : Ledger) (entry : Json.Value) : List String :=
  match entry with
  | .obj entries =>
    let v := Json.Value.obj entries
    let stamped := stampedKeys.filter fun k => (v.get? k).isSome
    let stampErrs :=
      if stamped.isEmpty then []
      else [s!"the entry must not set engine-stamped field(s): "
        ++ String.intercalate ", " stamped
        ++ " — they are recorded from canonical state (id: stamped on lessons, "
        ++ "reserved on reflection), not declared."]
    match ledger with
    | .reflection =>
      let typeErrs :=
        match v.get? "type" with
        | some (.str t) =>
          if reservedReflectionTypes.contains t then
            [s!"type {t} is reserved for framework transitions "
              ++ "(loop_gate / context_reset / human_resume); an agent entry "
              ++ "cannot claim one."]
          else if agentReflectionTypes.contains t then []
          else [s!"type must be one of "
            ++ String.intercalate " / " agentReflectionTypes ++ s!"; got {t}."]
        | _ => ["type is required and must be one of "
            ++ String.intercalate " / " agentReflectionTypes ++ "."]
      let summaryErrs :=
        if isNonEmptyStr ((v.get? "summary").getD .null) then []
        else ["summary is required and must be a non-empty string."]
      stampErrs ++ typeErrs ++ summaryErrs
        ++ optionalStringList v "open_questions"
        ++ optionalStringList v "conflicts"
        ++ optionalStringList v "next_actions"
    | .lessons =>
      let topicErrs :=
        if isNonEmptyStr ((v.get? "topic").getD .null) then []
        else ["topic is required and must be a non-empty string."]
      let lessonErrs :=
        if isNonEmptyStr ((v.get? "lesson").getD .null) then []
        else ["lesson is required and must be a non-empty string."]
      stampErrs ++ topicErrs ++ lessonErrs
        ++ optionalStringList v "tags"
        ++ optionalStringList v "evidence"
  | _ => ["the entry must be a JSON object."]

/-- 刻印値の観測(canonical state 由来)。 -/
structure Stamps where
  /-- `now_local()`。 -/
  now : String
  /-- `project.json.cycle_seq`(§19.1-10 の正式なサイクル連番。0 = 未走行)。 -/
  cycle : Int
  /-- `project.json.last_run_id`(null は未走行)。 -/
  runId : Json.Value
  /-- lessons の `id` 用サフィックス付き識別子(reflection では未使用)。 -/
  lessonId : String

/-- 受理されたエントリ 1 行。刻印を先頭に置き、呼び出し側のキーは指定順を
保存する — 台帳を目で追うとき「いつ・どの cycle の・誰の記録か」が常に
行頭に来る。 -/
def record (ledger : Ledger) (s : Stamps) (entry : Json.Value) : Json.Value :=
  let rest := match entry with | .obj entries => entries | _ => []
  let head : List (String × Json.Value) :=
    match ledger with
    | .reflection =>
      [("at", .str s.now), ("cycle", .num s.cycle 0), ("run_id", s.runId),
       ("recorded_by", .str "agent")]
    | .lessons =>
      [("at", .str s.now), ("id", .str s.lessonId), ("cycle", .num s.cycle 0),
       ("run_id", s.runId), ("recorded_by", .str "agent")]
  .obj (head ++ rest)

/-- CLI が出す受理ペイロード。 -/
def payload (ledger : Ledger) (rec : Json.Value) : Json.Value :=
  .obj [
    ("appended", .str ledger.fileName),
    ("entry", rec)]

/-- die 文言(`.error` チャネル)。 -/
def rejection (ledger : Ledger) (errs : List String) : String :=
  s!"{ledger.fileName} entry rejected: " ++ String.intercalate " " errs

/-- `project.json` から刻印用の cycle 連番と run id を読む。gate 保持面の
破損はここでは診断せず(呼び出し前に I-021 の検査が走る)、欠落は 0 / null
という「未走行」の素直な読みへ倒す。 -/
def stampsFromProject (project : Json.Value) : Int × Json.Value :=
  let cycle := match (project.get? "cycle_seq").bind pyInt? with
    | some n => n
    | none => 0
  (cycle, (project.get? "last_run_id").getD .null)

/-! ## コンパイル時テスト -/

-- reflection: 受理形
#guard entryErrors .reflection
    (.obj [("type", .str "cycle"), ("summary", .str "did the thing")]) == []
#guard entryErrors .reflection
    (.obj [("type", .str "cycle"), ("summary", .str "s"),
           ("open_questions", .arr [.str "q"]), ("conflicts", .arr [])]) == []
-- reflection: 語彙・必須・engine 刻印の拒否
#guard entryErrors .reflection (.obj [("summary", .str "s")]) != []
#guard entryErrors .reflection
    (.obj [("type", .str "cycle_reflection"), ("summary", .str "s")]) != []
#guard entryErrors .reflection
    (.obj [("type", .str "human_resume"), ("summary", .str "s")]) != []
#guard entryErrors .reflection
    (.obj [("type", .str "cycle"), ("summary", .str "  ")]) != []
#guard entryErrors .reflection
    (.obj [("at", .str "T"), ("type", .str "cycle"), ("summary", .str "s")])
  != []
#guard entryErrors .reflection
    (.obj [("type", .str "cycle"), ("summary", .str "s"),
           ("open_questions", .str "q")]) != []
#guard entryErrors .reflection (.arr []) != []

-- lessons: 受理形と必須
#guard entryErrors .lessons
    (.obj [("topic", .str "lean-tactics"), ("lesson", .str "use simp only")])
  == []
#guard entryErrors .lessons (.obj [("topic", .str "t")]) != []
#guard entryErrors .lessons
    (.obj [("topic", .str "t"), ("lesson", .str "l"), ("tags", .arr [.num 1 0])])
  != []

-- record: 刻印が先頭・呼び出し側キーの順序保存
#guard (record .reflection ⟨"T", 7, .str "R-1", "L-x"⟩
    (.obj [("type", .str "cycle"), ("summary", .str "s")])).render
  == "{\"at\": \"T\", \"cycle\": 7, \"run_id\": \"R-1\", "
    ++ "\"recorded_by\": \"agent\", \"type\": \"cycle\", \"summary\": \"s\"}"
#guard (record .lessons ⟨"T", 0, .null, "L-abc"⟩
    (.obj [("topic", .str "t"), ("lesson", .str "l")])).render
  == "{\"at\": \"T\", \"id\": \"L-abc\", \"cycle\": 0, \"run_id\": null, "
    ++ "\"recorded_by\": \"agent\", \"topic\": \"t\", \"lesson\": \"l\"}"

-- stampsFromProject
#guard stampsFromProject
    (.obj [("cycle_seq", .num 12 0), ("last_run_id", .str "R-9")])
  == (12, .str "R-9")
#guard stampsFromProject (.obj []) == (0, .null)

end Looper.State.Append
