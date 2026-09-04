import Looper.Core.Json
import Looper.Core.Prim
import Looper.Core.Text
import Looper.Core.Doc
import Looper.Core.Time
import Looper.State.Model
import Looper.State.Predicates

/-!
`Looper.State.Watch` — `<tool> state watch-render`(META.md §15.3)の純粋核。

`state status` と同じ役割分担: IO シェル(`Cli/Watch`)が観測を読み、本モジュール
が 1 フレームを組み立てる。gate 評価は `Predicates.shouldStopPayload` /
`completionPayload` を should-stop と同一の観測(`StopInputs`)で呼ぶ(I-017 —
watch は述語の別実装にならない)。観測の収集自体が失敗した場合も `stop = .error`
として届き、EVAL ERROR フレームに落ちる — 「runnable」と描かないだけでなく、
state が壊れているときこそ人間の窓を開けたままにする(§19.1-3)。

フレーム不変量: 出力はちょうど `rows` 行、全行の表示幅がちょうど `cols`
(超過は `Text.truncateDisplay`、不足は空白パディング)。全行の等幅上書きが
前フレームの残骸を消すので、行末消去やカーソル制御のエスケープは持たない —
画面制御は driver(watch スクリプト)の責務。SGR(色)だけを `color` の
とき埋め、`--no-color` では ESC バイトゼロ(W-013)。彩色は固定パレット
(D7、割当の単一定義点はこのファイル): 状態語 — STOP=赤 / COMPLETE=緑 /
runnable=緑 / RUNNING=緑 / NOT RUNNING=グレー / drain=黄 / EVAL ERROR=
赤反転 / Validation は ok=緑・warning=黄・error=赤・他=グレー / History の
run status は ok=緑・非 ok=黄 — と構造面 — ラベル・セクション罫=シアン /
`claude:`=マゼンタ / 脇役情報=グレー / ヘッダ左=太字。色は SGR 挿入だけの
差であり、剥がすと no-color とバイト一致する(W-013)。
-/

namespace Looper.State.Watch

open Looper.Core
open Looper.Core.Doc
open Looper.State.Model

/-! ## スタイル付きスパン — 幅計算・切り詰めはテキストへ、SGR は描画時のみ -/

inductive Style
  | red
  | green
  | yellow
  | redReverse
  | cyan
  | magenta
  | gray
  | bold
  deriving BEq

def Style.sgr : Style → String
  | .red => "\x1b[31m"
  | .green => "\x1b[32m"
  | .yellow => "\x1b[33m"
  | .redReverse => "\x1b[31;7m"
  | .cyan => "\x1b[36m"
  | .magenta => "\x1b[35m"
  | .gray => "\x1b[90m"
  | .bold => "\x1b[1m"

def sgrReset : String := "\x1b[0m"

structure Span where
  style : Option Style := none
  text : String
  deriving BEq

abbrev Line := List Span

def plain (s : String) : Span := { text := s }
def styled (st : Style) (s : String) : Span := { style := some st, text := s }

/-- 表示文字列の無害化: 制御文字(C0・DEL)を空白へ。JSON 由来の値(コマンド
文字列・title 等)は改行・タブを含み得るため、行へ載せる前に必ず通す。 -/
def sanitizeDisplay (s : String) : String :=
  String.ofList (s.toList.map fun c =>
    if c.toNat < 0x20 || c.toNat == 0x7F then ' ' else c)

private def spaces (n : Nat) : String := "".pushn ' ' n

private def padSpan (n : Nat) : Line :=
  if n == 0 then [] else [plain (spaces n)]

/-- 行を表示幅ちょうど `cols` へ: 超過分は後方から落とし(境界スパンは
`truncateDisplay`)、不足は空白パディング — フレーム不変量の実体。空へ切り
詰めたスパンは捨てる(styled 空スパンを残すと color モードの行に幅 0 の
SGR 残骸が乗る)。 -/
def fitLine (cols : Nat) : Line → Line
  | [] => padSpan cols
  | sp :: rest =>
    let w := Text.displayWidth sp.text
    if w ≤ cols then sp :: fitLine (cols - w) rest
    else
      let t := Text.truncateDisplay cols sp.text
      (if t.isEmpty then [] else [{ sp with text := t }])
        ++ padSpan (cols - Text.displayWidth t)

/-- スタイルを落とした素のテキスト(不変量検査と no-color 描画の実体)。 -/
def lineText (l : Line) : String :=
  l.foldl (fun acc sp => acc ++ sp.text) ""

def renderLine (color : Bool) (l : Line) : String :=
  l.foldl (init := "") fun acc sp =>
    match sp.style, color with
    | some st, true => acc ++ st.sgr ++ sp.text ++ sgrReset
    | _, _ => acc ++ sp.text

/-- 表示幅ちょうど `w` へ(切り詰め + 右パディング)。列揃え用。 -/
def padDisplay (w : Nat) (s : String) : String :=
  let t := Text.truncateDisplay w s
  t ++ spaces (w - Text.displayWidth t)

/-- 表示幅 `w` ごとの貪欲な行分割。幅 `w` を超える 1 文字でも必ず 1 文字進む
(fuel = 文字数 + 1 で全域)。 -/
private def wrapAux (w : Nat) : Nat → List Char → List String
  | 0, _ => []
  | _, [] => []
  | fuel + 1, cs =>
    let taken := Text.takeDisplayPrefix w cs
    let taken := if taken.isEmpty then cs.take 1 else taken
    String.ofList taken :: wrapAux w fuel (cs.drop taken.length)

def wrapDisplay (w : Nat) (s : String) : List String :=
  wrapAux w (s.length + 1) s.toList

/-- `wrapDisplay` + 行数上限: 超えるときは最終表示行へ `…` を付ける。 -/
def cappedWrap (w cap : Nat) (s : String) : List String :=
  let all := wrapDisplay w s
  if all.length ≤ cap then all
  else
    match (all.take cap).reverse with
    | last :: rest => ((last ++ "…") :: rest).reverse
    | [] => []

/-- 秒 → 人間可読(`42s` / `4m02s` / `1h02m`)。負は `—`(時計逆行の異常値)。 -/
def fmtDuration (secs : Int) : String :=
  if secs < 0 then "—"
  else
    let s := secs.toNat
    if s < 60 then s!"{s}s"
    else if s < 3600 then s!"{s / 60}m{Prim.padLeftZeros (toString (s % 60)) 2}s"
    else s!"{s / 3600}h{Prim.padLeftZeros (toString (s / 60 % 60)) 2}m"

/-! ## heartbeat(§19.1-9 の読み手側 — 全欄寛容) -/

structure HeartbeatView where
  cycle : Option Int := none
  maxCycles : Option Int := none
  runId : Option String := none
  sessionMode : Option String := none
  startedAt : Option String := none
  startedAtEpoch : Option Int := none
  /-- 書き手の loop の pid。lock の pid との一致が「この heartbeat は現在の
  lock 保持者のものか」の判定材料になる(§19.1-9-e — heartbeat は loop 終了時に
  削除されないため、lock の生存だけでは前回呼び出しの残存と区別できない)。 -/
  loopPid : Option Int := none
  deriving BEq

inductive HeartbeatRead
  | absent
  | corrupt
  | ok (h : HeartbeatView)
  deriving BEq

private def asInt? : Json.Value → Option Int
  | .num m 0 => some m
  | _ => none

/-- heartbeat の寛容パース: 不在は `.absent`、パース不能・非 object は
`.corrupt`(Cycle 行の診断へ、W-007)。欄は個別に寛容 — 型の合わない欄だけが
`—` になる。canonical でない入力に fail-closed は要らない(§19.1-9-a)。 -/
def readHeartbeat : Option String → HeartbeatRead
  | none => .absent
  | some contents =>
    match Json.parse contents with
    | .ok (.obj entries) =>
      let v : Json.Value := .obj entries
      .ok { cycle := (v.get? "cycle").bind asInt?
            maxCycles := (v.get? "max_cycles").bind asInt?
            runId := (v.get? "run_id").bind (·.asStr?)
            sessionMode := (v.get? "session_mode").bind (·.asStr?)
            startedAt := (v.get? "started_at").bind (·.asStr?)
            startedAtEpoch := (v.get? "started_at_epoch").bind asInt?
            loopPid := (v.get? "loop_pid").bind asInt? }
    | _ => .corrupt

/-! ## runs.jsonl — 履歴と統計 -/

structure RunEntry where
  runId : String
  status : String
  duration? : Option Int
  deriving BEq

private def recStr? (r : Json.Value) (k : String) : Option String :=
  (r.get? k).bind (·.asStr?)

/-- end レコードを直近の start と突合して履歴化(古→新順)。`at` の欠損・
逆パース不能は duration なし(W-008)、start の無い end も項目化する。 -/
def runHistory (records : List Json.Value) : List RunEntry := Id.run do
  let mut starts : List (String × Option Int) := []
  let mut out : List RunEntry := []
  for r in records do
    match recStr? r "run_id", recStr? r "event" with
    | some rid, some "start" =>
      starts := (rid, (recStr? r "at").bind Time.parseIsoLocal?) :: starts
    | some rid, some "end" =>
      let startAt := (((starts.find? (·.1 == rid)).map (·.2)).getD none)
      let endAt := (recStr? r "at").bind Time.parseIsoLocal?
      let duration? := match startAt, endAt with
        | some a, some b => if b ≥ a then some (b - a) else none
        | _, _ => none
      out := out ++ [{ runId := rid,
                       status := (recStr? r "status").getD "unknown", duration? }]
      starts := starts.filter (·.1 != rid)
    | _, _ => pure ()
  return out

/-- this-invocation の run_id 集合(新→旧順): runs 末尾から `heartbeat.cycle`
本の start。I-018 lock 保持中は他遷移が interleave しないため、この末尾が
現在の loop 呼び出しの開始列そのものになる(§15.3 の決定的定義)。 -/
def thisLoopRunIds (records : List Json.Value) (cycle : Nat) : List String :=
  (records.filterMap fun r =>
    if recStr? r "event" == some "start" then recStr? r "run_id" else none
  ).reverse.take cycle

/-- `n/m ok · avg …` の統計素片(m = end レコード数)。 -/
def fmtStats (entries : List RunEntry) : String :=
  let ok := (entries.filter (·.status == "ok")).length
  let durs := entries.filterMap (·.duration?)
  let base := s!"{ok}/{entries.length} ok"
  if durs.isEmpty then base
  else base ++ s!" · avg {fmtDuration ((durs.foldl (· + ·) 0) / Int.ofNat durs.length)}"

/-! ## transcript(D6 — best-effort、劣化が受け入れ条件) -/

/-- `tail -c` 断片のデコード: まず全体を UTF-8 として試し、失敗したら先頭の
切断行(最初の LF まで)を捨てて再試行する — バイト境界の切断は断片の先頭に
しか現れない。 -/
def decodeTail? (bytes : ByteArray) : Option String :=
  match String.fromUTF8? bytes with
  | some s => some s
  | none =>
    match bytes.toList.dropWhile (· != 10) with
    | _ :: rest => String.fromUTF8? (ByteArray.mk rest.toArray)
    | [] => none

/-- 断片から assistant テキストの履歴を抽出(古→新順): 行ごとの lenient JSON
パースで `type == "assistant"` の `message.content[].text` を連結。不読行・
未知形は黙殺(実フォーマットとの一致は仕様として主張しない — §15.3)。 -/
def assistantTexts (contents : String) : List String :=
  (Text.splitLinesPy contents).filterMap fun line =>
    match Json.parse line with
    | .error _ => none
    | .ok record =>
      if record.get? "type" != some (.str "assistant") then none
      else
        match ((record.get? "message").getD .null).get? "content" with
        | some (.arr items) =>
          let frags := items.filterMap fun item =>
            (item.get? "text").bind (·.asStr?)
          if frags.isEmpty then none else some (String.intercalate " " frags)
        | _ => none

/-! ## gate 評価(I-017 — 同一観測・単一導出点の消費) -/

inductive Gate
  | runnable
  | stop (reasons : List String) (message : String)
  | complete (scope : String)
  | evalError (detail : String)

/-- should-stop / should-complete を同一観測で呼ぶ。停止が完了に先行するのは
loop / status と同じ順(§13.4)。payload は Phase 行の素材として返す。 -/
def evalGate : Except String Predicates.StopInputs →
    Gate × Option Json.Value × Option Json.Value
  | .error e => (.evalError e, none, none)
  | .ok stop =>
    match Predicates.shouldStopPayload stop,
        Predicates.completionPayload
          { domain := stop.domain, todo := stop.todo, spec := stop.spec,
            context := stop.context, essence := stop.essence,
            ledgers := stop.ledgers, observations := stop.observations } with
    | .ok sv, .ok cv =>
      let gate :=
        if sv.stop then
          let reasons := match sv.payload.get? "reasons" with
            | some (.arr l) => l.filterMap (·.asStr?)
            | _ => []
          -- message は §13.4-2 の単一導出点を逐語で消費する(W-002)
          .stop reasons (((sv.payload.get? "message").bind (·.asStr?)).getD "")
        else if cv.complete then
          .complete (((cv.payload.get? "completion_scope").bind (·.asStr?)).getD "?")
        else
          .runnable
      (gate, some sv.payload, some cv.payload)
    | .error e, _ | _, .error e => (.evalError e, none, none)

/-- validation.json の status の寛容読み(表示専用)。 -/
def validationStatus : Option String → String
  | none => "unknown"
  | some contents =>
    match Json.parse contents with
    | .ok v => ((v.get? "status").bind (·.asStr?)).getD "unknown"
    | .error _ => "unknown"

/-! ## 入力とフレーム組み立て -/

structure WatchInputs where
  /-- 製品識別子の 1 語幹(ヘッダ行の綴り。抽出計画 6e)。 -/
  tool : String
  projectTitle : String
  nowEpoch : Int
  nowLocal : String
  cols : Nat
  rows : Nat
  color : Bool
  lockPid : Option String := none
  lockAlive : Bool := false
  drainPending : Bool := false
  /-- loop.status.json の生テキスト(不在・不読は none)。 -/
  heartbeat : Option String := none
  /-- should-stop と同一の観測(I-017)。IO シェルでの収集自体の失敗も
  `.error` としてここに届き、EVAL ERROR フレームに落ちる(§19.1-3)。 -/
  stop : Except String Predicates.StopInputs
  validation : Option String := none
  transcriptTail : Option ByteArray := none

private def labelSpan (name : String) : Span :=
  styled .cyan (name ++ spaces (8 - name.length) ++ ": ")

private def sectionRule (cols : Nat) (title : String) : Line :=
  let head := s!"── {title} "
  [styled .cyan (head ++ "".pushn '─' (cols - Text.displayWidth head))]

private def headerLine (i : WatchInputs) : Line :=
  let right := i.nowLocal
  let rw := Text.displayWidth right
  let left := s!"{i.tool} watch — {sanitizeDisplay i.projectTitle}"
  if i.cols ≥ rw + 12 then
    let left := Text.truncateDisplay (i.cols - rw - 2) left
    [styled .bold left, plain (spaces (i.cols - Text.displayWidth left - rw)),
     styled .gray right]
  else
    [styled .bold left]

private def loopLine (i : WatchInputs) : Line :=
  let base : List Span :=
    if i.lockAlive then
      match i.lockPid with
      | some pid => [styled .green "RUNNING", plain s!" (pid {sanitizeDisplay pid})"]
      | none => [styled .green "RUNNING"]
    else [styled .gray "NOT RUNNING"]
  [labelSpan "Loop"] ++ base
    ++ (if i.drainPending then [plain " · ", styled .yellow "drain pending"] else [])

private def optInt (v : Option Int) : String := (v.map toString).getD "?"

private def cycleLine (i : WatchInputs) (hb : HeartbeatRead) : Line :=
  match hb with
  | .absent => [labelSpan "Cycle", plain "—"]
  | .corrupt => [labelSpan "Cycle", plain "— (heartbeat unreadable)"]
  | .ok h =>
    -- heartbeat は loop 終了時に削除されない(§19.1-9-e)ため、lock の生存
    -- だけでは「前回呼び出しの残存」と区別できない。書き手の loop_pid と
    -- lock の pid が両方読めて食い違うときだけ live 扱いを降ろす(W-005)。
    let pidMismatch := match h.loopPid, i.lockPid with
      | some hp, some lp => toString hp != lp
      | _, _ => false
    let base := s!"{optInt h.cycle}/{optInt h.maxCycles}"
      ++ s!" · {h.runId.getD "?"} · session {h.sessionMode.getD "?"}"
    let tail : List Span :=
      if i.lockAlive && !pidMismatch then
        match h.startedAtEpoch with
        | some e => [plain s!" · elapsed {fmtDuration (max 0 (i.nowEpoch - e))}"]
        | none => []
      else
        -- last-known(stale)表示: elapsed は当該 loop の終了後に意味を失う
        -- ので開始時刻の実測へ切り替える。
        match h.startedAt with
        | some t => [styled .gray s!" · last known (started {sanitizeDisplay t})"]
        | none => [styled .gray " · last known"]
    [labelSpan "Cycle", plain (sanitizeDisplay base)] ++ tail

private def gateLines (i : WatchInputs) (gate : Gate) : List Line :=
  match gate with
  | .runnable => [[labelSpan "Gate", styled .green "none (runnable)"]]
  | .stop reasons message =>
    [labelSpan "Gate", styled .red "STOP",
      plain s!" ({String.intercalate ", " reasons})"]
      :: (cappedWrap (i.cols - 2) 6 (sanitizeDisplay message)).map fun chunk =>
        [plain "  ", plain chunk]
  | .complete scope =>
    [[labelSpan "Gate", styled .green "COMPLETE", plain s!" ({scope} scope, §19.3)"]]
  | .evalError detail =>
    [labelSpan "Gate", styled .redReverse "EVAL ERROR"]
      :: (cappedWrap (i.cols - 2) 2 (sanitizeDisplay detail)).map fun chunk =>
        [plain "  ", plain chunk]

private def fieldStr (p : Json.Value) (k : String) : String :=
  match p.get? k with
  | some (.str s) => s
  | some (.num m 0) => toString m
  | some (.bool b) => if b then "true" else "false"
  | _ => "?"

private def fieldNat? (p : Json.Value) (k : String) : Option Nat :=
  match p.get? k with
  | some (.num m 0) => if m < 0 then none else some m.toNat
  | _ => none

-- 語彙は `Validate` の status 導出(ok / warning / error)と揃える
private def validationSpan (status : String) : Span :=
  match status with
  | "ok" => styled .green status
  | "warning" => styled .yellow status
  | "error" => styled .red status
  | s => styled .gray (sanitizeDisplay s)

private def phaseLine (i : WatchInputs) (sv cv : Option Json.Value) : Line :=
  match sv, cv with
  | some sv, some cv =>
    [labelSpan "Phase", plain (sanitizeDisplay (fieldStr cv "phase")),
     plain (s!" · Idle {fieldStr sv "idle_cycles_since_progress"}"
       ++ s!"/{fieldStr sv "stop_after_idle_cycles"} · Validation "),
     validationSpan (validationStatus i.validation)]
  | _, _ => [labelSpan "Phase", plain "—"]

/-- MUST 進捗バー(W-009): 幅 `w` を `⌊w·done/total⌋` で塗り分ける。ただし
`done > 0` は最低 1 マス(進捗があるのに空に見せない)— floor なので
`done < total` が満杯になることはない。`total = 0` は全枠を空で描く(0/0 —
分母なしでもバーの幅は揺らさない)。 -/
def progressBar (w done total : Nat) : Line :=
  let filled :=
    if total == 0 || done == 0 then 0
    else max 1 (min w (w * done / total))
  (if filled == 0 then [] else [styled .green ("".pushn '█' filled)])
    ++ (if filled == w then [] else [styled .gray ("".pushn '░' (w - filled))])

private def mustLine (i : WatchInputs) (sv cv : Option Json.Value) : Line :=
  match sv, cv with
  | some _, some cv =>
    match fieldNat? cv "must_done", fieldNat? cv "must_total" with
    | some done, some total =>
      let barWidth := min 24 (i.cols - 16)
      [labelSpan "Must"] ++ progressBar barWidth done total
        ++ [plain s!" {done}/{total}"]
    | _, _ => [labelSpan "Must", plain "—"]
  | _, _ => [labelSpan "Must", plain "—"]

private def statusStyle (status : String) : Style :=
  if status == "ok" then .green else .yellow

private def historyEntryLine (e : RunEntry) : Line :=
  [plain "  ", plain (padDisplay 28 (sanitizeDisplay e.runId)),
   styled (statusStyle e.status) (padDisplay 15 (sanitizeDisplay e.status)),
   styled .gray ((e.duration?.map fmtDuration).getD "—")]

private def statsLine (hb : HeartbeatRead) (entries : List RunEntry)
    (records : List Json.Value) : Line :=
  let thisLoop := match hb with
    | .ok h =>
      match h.cycle with
      | some c =>
        let ids := thisLoopRunIds records c.toNat
        fmtStats (entries.filter (ids.contains ·.runId))
      | none => "—"
    | _ => "—"
  [labelSpan "Stats", plain s!"this loop {thisLoop} | lifetime {fmtStats entries}"]

/-- 1 メッセージの表示行(`claude:` 前置 + 続き行はインデント、1 件あたり
3 行 cap)。 -/
private def claudeMessageLines (cols : Nat) (text : String) : List Line :=
  match cappedWrap (cols - 8) 3 (Text.normalizeWs (sanitizeDisplay text)) with
  | first :: rest =>
    [styled .magenta "claude: ", plain first]
      :: rest.map fun chunk => [plain (spaces 8), plain chunk]
  | [] => [[styled .magenta "claude: "]]

/-- 新→旧順のメッセージ行ブロックを、`slots` に収まる限り新しい側から
**丸ごと**積む(古→新順で返す)。境界のメッセージは行単位で切らない —
切ると続き行が `claude:` 見出しなしで画面に残る。入り切らないブロックで
打ち切る(それより古いブロックも出さない — 履歴の連続性を保つ)。 -/
private def packNewestBlocks : Nat → List (List Line) → List Line
  | _, [] => []
  | slots, newest :: older =>
    if newest.length ≤ slots then
      packNewestBlocks (slots - newest.length) older ++ newest
    else []

/-- Claude セクション本体: transcript tail の assistant 履歴(古→新)を流し、
`slots` に収まる末尾のメッセージ群を採る — 最新のメッセージが常に画面へ残る
log 表示。最新 1 件だけで `slots` を超えるときはその先頭 `slots` 行
(`claude:` 見出しから)を出す — セクションを空にしない。tail 不在・
デコード不能・assistant ゼロは 1 行の劣化表示(D6)。 -/
private def claudeLines (i : WatchInputs) (slots : Nat) : List Line :=
  let msgs := ((i.transcriptTail.bind decodeTail?).map assistantTexts).getD []
  let body :=
    if msgs.isEmpty then [[styled .gray "transcript: unavailable"]]
    else
      let blocks := (msgs.map (claudeMessageLines i.cols)).reverse
      let packed := packNewestBlocks slots blocks
      if packed.isEmpty then (blocks.headD []).take slots else packed
  let body := body.take slots
  body ++ List.replicate (slots - body.length) []

/-- 極小端末の決定的フレーム(W-012)。`take` は `rows = 0` でも不変量
「ちょうど rows 行」を全域に保つ。 -/
private def tooSmallFrame (i : WatchInputs) : List Line :=
  ([plain s!"terminal too small ({i.cols}x{i.rows}; minimum 40x12)"]
    :: List.replicate (i.rows - 1) []).take i.rows

/-- フレーム(未 fit の行リスト、ちょうど `rows` 行)。行予算の単一定義点
(D7): ヘッダ / Loop / Cycle / Gate(+ 詳細行)/ Phase / Must → History
(見出し + min(6, 残り/3) 項目)→ Stats → Claude(見出し + 残り全行)→
footer。予算超過(小さい rows × 長い STOP message)でも footer は必ず最終行に
立つ。 -/
private def frameLines (i : WatchInputs) : List Line :=
  if i.cols < 40 || i.rows < 12 then tooSmallFrame i
  else
    let hb := readHeartbeat i.heartbeat
    let (gate, sv, cv) := evalGate i.stop
    let records := match i.stop with
      | .ok s => (readJsonlOrEmpty "runs.jsonl" s.runs).1
      | .error _ => []
    let entries := runHistory records
    let top := [headerLine i, loopLine i, cycleLine i hb]
      ++ gateLines i gate ++ [phaseLine i sv cv, mustLine i sv cv]
    let avail := i.rows - top.length - 2   -- Stats と footer の 2 行を先取り
    let histEntries := min 6 (avail / 3)
    let history :=
      if histEntries == 0 then []
      else
        let shown := (entries.reverse.take histEntries).map historyEntryLine
        let shown := if shown.isEmpty then [[styled .gray "  (none)"]] else shown
        sectionRule i.cols "History"
          :: shown ++ List.replicate (histEntries - shown.length) []
    let actTotal := avail - history.length
    let claude :=
      -- 1 行では見出しの下に本体が置けない — 見出しだけの空セクションは出さない
      if actTotal ≤ 1 then []
      else sectionRule i.cols "Claude" :: claudeLines i (actTotal - 1)
    let body := top ++ history ++ [statsLine hb entries records] ++ claude
    let body := body.take (i.rows - 1)
    let body := body ++ List.replicate (i.rows - 1 - body.length) []
    body ++ [[styled .gray "q quit · 1s refresh · read-only"]]

/-- 1 フレーム: ちょうど `rows` 行、各行の表示幅ちょうど `cols`。 -/
def render (i : WatchInputs) : List String :=
  (frameLines i).map fun l => renderLine i.color (fitLine i.cols l)

/-! ## コンパイル時テスト -/

-- sanitize / fit / pad / wrap(フレーム不変量の部品)
#guard sanitizeDisplay "a\tb\nc" == "a b c"
#guard lineText (fitLine 10 [plain "abc"]) == "abc       "
#guard lineText (fitLine 4 [plain "abcdef"]) == "abc…"
#guard lineText (fitLine 5 [plain "日本語"]) == "日本…"      -- 全角境界 + パディングなし(幅 5)
#guard Text.displayWidth (lineText (fitLine 4 [plain "日本語"])) == 4
#guard lineText (fitLine 8 ([] : Line)) == spaces 8       -- 空行は全空白へ
-- 空へ切り詰めたスパンは捨てる(styled 空スパンの SGR 残骸を出さない)
#guard fitLine 4 [plain "abcd", styled .red "x"] == [plain "abcd"]
#guard renderLine false [styled .red "STOP", plain " x"] == "STOP x"
#guard renderLine true [styled .red "STOP"] == "\x1b[31mSTOP\x1b[0m"
#guard wrapDisplay 4 "abcdefgh" == ["abcd", "efgh"]
#guard wrapDisplay 4 "日本語です" == ["日本", "語で", "す"]
#guard wrapDisplay 1 "日本" == ["日", "本"]                 -- 幅超過文字でも前進
#guard cappedWrap 4 2 "abcdefghijkl" == ["abcd", "efgh…"]
#guard padDisplay 6 "日本語" == "日本語"
#guard padDisplay 5 "日本語" == "日本…"                    -- 幅 5 ちょうど(2+2+1)
#guard padDisplay 4 "日本語" == "日… "                     -- 全角境界: 幅 3 + パディング 1

-- fmtDuration
#guard fmtDuration 0 == "0s"
#guard fmtDuration 59 == "59s"
#guard fmtDuration 62 == "1m02s"
#guard fmtDuration 3723 == "1h02m"
#guard fmtDuration (-1) == "—"

-- heartbeat の寛容パース
#guard readHeartbeat none == .absent
#guard readHeartbeat (some "{broken") == .corrupt
#guard readHeartbeat (some "[1]") == .corrupt
#guard readHeartbeat (some "{\"cycle\": 3, \"max_cycles\": 25, \"run_id\": \"R-1\", \"session_mode\": \"fresh\", \"started_at\": \"T\", \"started_at_epoch\": 100}")
    == .ok { cycle := some 3, maxCycles := some 25, runId := some "R-1",
             sessionMode := some "fresh", startedAt := some "T",
             startedAtEpoch := some 100 }
#guard readHeartbeat (some "{\"cycle\": \"three\"}") == .ok { cycle := none }

-- runs 履歴・統計(W-008 の参照挙動)
private def runLine (rid event : String) (extra : String := "") : String :=
  "{\"at\": \"1970-01-01T00:0" ++ extra ++ ":00+00:00\", \"run_id\": \"" ++ rid
    ++ "\", \"event\": \"" ++ event ++ "\""
    ++ (if event == "end" then ", \"status\": \"ok\"" else "") ++ "}"
private def runsFixture : List Json.Value :=
  [runLine "R-1" "start" "0", runLine "R-1" "end" "1",
   runLine "R-2" "start" "2",
   "{\"run_id\": \"R-3\", \"event\": \"end\", \"status\": \"interrupted\"}"
  ].filterMap fun l => (Json.parse l).toOption
#guard runHistory runsFixture ==
  [{ runId := "R-1", status := "ok", duration? := some 60 },
   { runId := "R-3", status := "interrupted", duration? := none }]
#guard thisLoopRunIds runsFixture 1 == ["R-2"]
#guard thisLoopRunIds runsFixture 5 == ["R-2", "R-1"]
#guard fmtStats (runHistory runsFixture) == "1/2 ok · avg 1m00s"
#guard fmtStats [] == "0/0 ok"

-- transcript(D6 の劣化契約)
#guard decodeTail? (String.toUTF8 "{\"a\":1}\nline2") == some "{\"a\":1}\nline2"
#guard decodeTail? (((String.toUTF8 "日本語\nrest").toList.drop 1).toArray
    |> ByteArray.mk) == some "rest"                        -- 先頭切断行を捨てて回復
#guard decodeTail? (ByteArray.mk #[0xFF, 0xFE]) == none
#guard assistantTexts
    ("{\"type\": \"user\", \"message\": {\"content\": [{\"type\": \"text\", \"text\": \"hi\"}]}}\n"
      ++ "{\"type\": \"assistant\", \"message\": {\"content\": [{\"type\": \"text\", \"text\": \"reading\"}]}}\n"
      ++ "{\"type\": \"assistant\", \"message\": {\"content\": [{\"type\": \"text\", \"text\": \"working\"}, {\"type\": \"tool_use\"}]}}\n"
      ++ "broken json\n")
    == ["reading", "working"]
#guard assistantTexts "not json\n[]\n" == []

-- MUST 進捗バー(枠幅一定・0 分母・満杯の各境界)
#guard lineText (progressBar 10 0 0) == "".pushn '░' 10
#guard lineText (progressBar 10 5 10) == "".pushn '█' 5 ++ "".pushn '░' 5
#guard lineText (progressBar 10 10 10) == "".pushn '█' 10
#guard lineText (progressBar 10 1 3) == "".pushn '█' 3 ++ "".pushn '░' 7
#guard lineText (progressBar 10 1 100) == "█" ++ "".pushn '░' 9   -- 最低 1 マス
#guard lineText (progressBar 10 99 100) == "".pushn '█' 9 ++ "░"  -- 未完は満杯にしない
#guard (progressBar 10 10 10).all (·.style == some .green)
#guard (progressBar 10 0 0).all (·.style == some .gray)

-- claude 履歴の詰め込み: メッセージ境界で丸ごと(行単位で切らない)
private def linesOf (n : Nat) : List Line := List.replicate n [plain "x"]
#guard (packNewestBlocks 5 [linesOf 2, linesOf 2, linesOf 2]).length == 4  -- 新 2 件のみ
#guard (packNewestBlocks 6 [linesOf 2, linesOf 2, linesOf 2]).length == 6
#guard packNewestBlocks 1 [linesOf 2, linesOf 1] == []  -- 最新が入らねば打ち切り

-- フレーム不変量: EVAL ERROR(観測不能)と STOP(essence_missing)の両経路で
-- ちょうど rows 行 × 全行幅 cols、footer が最終行、no-color は ESC ゼロ
private def stopFixture : Predicates.StopInputs := {
  domain := Domain.fixture
  projectTitle := "sample"
  stateInitialized := true
  blockers := .text "{\"items\": []}"
  recommendations := .text "{\"items\": []}"
  context := .text "{\"progress\": {}, \"stop_policy\": {}}"
  project := .text "{}"
  reflection := .text ""
  runs := .text ""
  ledgers := []
  observations := []
  attestations := .absent
  spec := .text "{\"items\": []}"
  todo := .text "{\"items\": []}"
  essence := .absent
  essencesDir := .absent
}
private def guardInputs (stop : Except String Predicates.StopInputs) : WatchInputs := {
  tool := "looper", projectTitle := "sample", nowEpoch := 0,
  nowLocal := "1970-01-01T00:00:00+00:00",
  cols := 60, rows := 14, color := false, stop
}
private def frameInvariant (i : WatchInputs) (footer : Bool := true) : Bool :=
  let frame := render i
  frame.length == i.rows
    && frame.all (fun l => Text.displayWidth l == i.cols)
    && frame.all (fun l => !l.toList.contains (Char.ofNat 0x1b))
    && (!footer || (frame.getLast?.map (·.startsWith "q quit")).getD false)
#guard frameInvariant (guardInputs (.error "boom"))
#guard (render (guardInputs (.error "boom"))).any (Text.containsSub · "EVAL ERROR")
#guard frameInvariant (guardInputs (.ok stopFixture))
#guard (render (guardInputs (.ok stopFixture))).any (Text.containsSub · "STOP (essence_missing")
#guard frameInvariant { guardInputs (.ok stopFixture) with cols := 20, rows := 5 }
    (footer := false)                                      -- 極小画面に footer は無い
#guard (render { guardInputs (.ok stopFixture) with cols := 0, rows := 0 }) == []
#guard frameInvariant { guardInputs (.ok stopFixture) with cols := 5, rows := 1 }
    (footer := false)                                      -- 不変量は全域(rows=1)
#guard (render { guardInputs (.ok stopFixture) with cols := 20, rows := 5 }).head?
    == some "terminal too small …"

end Looper.State.Watch
