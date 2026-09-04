import Looper.Core.Json
import Looper.Core.Text
import Looper.Core.PathAlg
import Looper.Core.Classify
import Looper.Core.Classify.Bash
import Looper.Domain

/-!
`Looper.Hook.PostTool` — PostToolUse hook(`<tool> hook post-tool`)の
純粋決定核(META.md §20.4、§12.1)。

移行元: `.claude/hooks/post_tool_audit.py`(移行完了まで凍結)。判定を持たない
fail-open の監査 hook で、(1) 観測した全ツール呼び出しの `tool_audit.jsonl`
追記と、(2) High-Risk Zone / 制御プレーン面への書き込みの after-hash 記録
(pre hook が stage した before-hash との対合、§20.4-3)を行う。

分類判定は共有定義(`Core.Classify.isHighRiskPath` /
`isControlPlaneHighRisk` / `Core.Classify.Bash` の mutator 判定群)をそのまま
使う — D-002(post ⊂ pre)は同一定義の共有で構成的に成立する。

**Python の例外パスの型化**: 移行元は全体を `try` で包み、どの失敗も
「stderr 1 行 + 該当レコードを書かない」に落とす(best-effort、§31.5)。
ここでは Python が実行時例外(AttributeError / TypeError)に到達する入力
— truthy 非 object の `tool_input`、truthy 非文字列の `command` / `cwd` /
パス、pending の非 object JSON 行 — を `Except String` の `.error` として
明示的に返し、IO シェルが stderr へ写す。文言は Python の例外文字列と
一致しない(人間向け文言のみの差、§5.3)。

CPython との裁定済み許容差(いずれも audit 系 best-effort の記録有無のみに
影響し、guard 判定には波及しない。シャドー生成の等価領域外):
- NUL 込みパス: Python は `resolve()` / `is_dir()` の ValueError で例外パス
  (レコードなし)、Lean は字句解決で続行(記録が増える方向)
- pending ファイルが不正 UTF-8: Python は UnicodeDecodeError で例外パス、
  Lean は読取不能 = `UNKNOWN` として記録する(記録が増える方向)
- `session_id` の一致判定は JSON 値の構造等値(`BEq`)であり、Python の
  数値横断等値(`5 == 5.0`、`True == 1`)とは異なる(実運用の session_id は
  文字列か null)
-/

namespace Looper.Hook.PostTool

open Looper.Core.Json (Value)
open Looper.Core.Text (splitLinesPy)
open Looper.Core.Classify (isControlPlaneHighRisk isHighRiskPath
  hasWriteRedirectOrMutator mutatesLiteralTarget bashPathishTokens)

/-! ## PurePosixPath の表記正規化

`str(Path(p))` / `Path.parents` / `Path.relative_to` の純字句部分。
`posixpath.normpath`(`Core.Path`)と違い `..` を縮約**しない**。 -/

/-- `PurePosixPath(p)` の (anchor, 成分列) 分解。anchor は `""` / `"/"` /
`"//"`(POSIX 特例: 先頭ちょうど 2 本のスラッシュのみ保持)。空成分と `.` は
除去、`..` は保持する。 -/
def pathParts (p : String) : String × List String :=
  let anchor :=
    if p.startsWith "/" then
      if p.startsWith "//" && !p.startsWith "///" then "//" else "/"
    else ""
  (anchor, (p.splitOn "/").filter fun c => c ≠ "" && c ≠ ".")

/-- (anchor, 成分列) → `str(PurePosixPath(...))`。成分なしの相対は `"."`。 -/
def joinParts : String × List String → String
  | ("", []) => "."
  | (anchor, comps) => anchor ++ String.intercalate "/" comps

/-- `str(PurePosixPath(p))` 等価の表記正規化(連続スラッシュ・`.` 成分・
末尾スラッシュの除去。`..` と大文字小文字は保持)。 -/
def pyPathStr (p : String) : String :=
  joinParts (pathParts p)

-- `parent / rel` の str(Python `Path.__truediv__`)。単一定義は
-- `Core.PathAlg.childPath`(レシピ側 `Cli/AslHook` とも共有、R-8)。
export Looper.Core.PathAlg (childPath)

/-- `[p] + list(p.parents)` の各 str(`find_project_state_root` の探索順)。 -/
def selfAndParents (p : String) : List String :=
  let (anchor, comps) := pathParts p
  (List.range (comps.length + 1)).map fun i =>
    joinParts (anchor, comps.take (comps.length - i))

/-- `target.relative_to(base)` + `.as_posix()`。不成立(anchor 不一致・
成分プレフィクスでない)は `none`、一致は `"."`(Python `Path(".")`)。 -/
def relativeTo? (base target : String) : Option String :=
  let (ba, bc) := pathParts base
  let (ta, tc) := pathParts target
  if ba == ta && bc.isPrefixOf tc then
    let rest := tc.drop bc.length
    some (if rest.isEmpty then "." else String.intercalate "/" rest)
  else
    none

/-! ## 分類(main() / bash_high_risk_targets 共通の判定部) -/

/-- `path_candidates(raw, target)`。判定(`any`)にのみ使うため Python の
set の順序・重複除去は再現しない。`projectRoot?` は `find_project_state_root`
の結果(親ディレクトリの実在判定は IO の責務)。 -/
def pathCandidates (raw targetStr : String) (projectRoot? : Option String)
    (controlRoot : String) : List String :=
  [raw.replace "\\" "/", targetStr.replace "\\" "/"]
    ++ (projectRoot?.bind fun root => relativeTo? root targetStr).toList
    ++ (relativeTo? controlRoot targetStr).toList

/-- 書き込み先 1 個の high-risk 判定: CONTROL_ROOT 相対パスの制御プレーン面
(§11.3)、または候補表記のいずれかが High-Risk Zone(§12)に載る。 -/
def isHighRiskTarget (raw targetStr : String) (projectRoot? : Option String)
    (controlRoot : String) : Bool :=
  (match relativeTo? controlRoot targetStr with
   | some rel => isControlPlaneHighRisk rel
   | none => false)
  || (pathCandidates raw targetStr projectRoot? controlRoot).any isHighRiskPath

/-- `find_project_state_root` の候補列 `(projectRoot, stateDir)`(target 自身
→ 各親の順、CONTROL_ROOT 自身は除外)。IO シェルが先頭から最初に `stateDir`
がディレクトリとして実在するものを採る。 -/
def stateRootCandidates (d : Domain) (targetStr controlRoot : String) :
    List (String × String) :=
  let controlRootStr := pyPathStr controlRoot
  (selfAndParents targetStr).filterMap fun parent =>
    if parent == controlRootStr then none
    else some (parent, childPath parent (d.controlDirName ++ "/state"))

/-- `bash_high_risk_targets` のトークン選別(resolve 前の純粋部): pathish
トークン(ソート済み・重複なし)のうち、`/` か `.` を含み、かつ同一パイプ
ライン区間で mutator の後方にリテラル出現するもの。 -/
def bashCandidateTokens (command : String) : List String :=
  (bashPathishTokens command).filter fun tok =>
    (tok.toList.contains '/' || tok.toList.contains '.')
      && mutatesLiteralTarget tok command

/-! ## 入力の抽出(Python の `or` 連鎖と例外パスの型化) -/

/-- `payload.get("tool_input", {}) or {}`。truthy 非 object は Python の
`.get` AttributeError = `.error`。 -/
def toolInput? (payload : Value) : Except String (List (String × Value)) :=
  match (payload.get? "tool_input").getD (.obj []) with
  | .obj entries => .ok entries
  | v => if v.truthy then .error "tool_input is not an object" else .ok []

/-- `a or b or null`(JSON 値の truthiness 連鎖)。 -/
private def orValue (a b : Value) : Value :=
  if a.truthy then a else b

/-- `(tool_input.get("command") or "")[:500] or None`。truthy 値のうち
文字列と配列は Python の `[:500]` がスライスとして成功する(配列は先頭
500 **要素**のまま記録される)。それ以外の truthy(数値・true・object)は
スライス TypeError = `.error`。 -/
def auditCommand? (toolInput : List (String × Value)) : Except String Value :=
  match (Value.obj toolInput).get? "command" with
  | some (.str s) => .ok (if s.isEmpty then .null else .str (s.take 500).toString)
  | some (.arr items) =>
    .ok (if items.isEmpty then .null else .arr (items.take 500))
  | some v => if v.truthy then .error "command is not sliceable" else .ok .null
  | none => .ok .null

/-- `tool = payload.get("tool_name", "")`(JSON 値のまま。記録にも分岐にも
この値を使う)。 -/
def toolValue (payload : Value) : Value :=
  (payload.get? "tool_name").getD (.str "")

/-- tool_audit.jsonl の 1 レコード(キーは挿入順)。`.error` は audit append
失敗として stderr のみ(fail-open)。 -/
def auditRecord (now : String) (payload : Value) : Except String Value := do
  let toolInput ← toolInput? payload
  let command ← auditCommand? toolInput
  let ti := Value.obj toolInput
  return .obj
    [ ("at", .str now),
      ("session_id", (payload.get? "session_id").getD .null),
      ("tool", toolValue payload),
      ("file", orValue ((ti.get? "file_path").getD .null)
                 ((ti.get? "notebook_path").getD .null)),
      ("command", command) ]

/-- WRITE_TOOLS 経路の生ターゲット
`tool_input.get("file_path") or tool_input.get("notebook_path") or ""`。
`.ok none` = falsy(何も記録しない)、truthy 非文字列は Python の `Path(raw)`
TypeError = `.error`。 -/
def writeTarget? (payload : Value) : Except String (Option String) := do
  let toolInput ← toolInput? payload
  let ti := Value.obj toolInput
  match orValue ((ti.get? "file_path").getD .null)
      ((ti.get? "notebook_path").getD .null) with
  | .str s => return (if s.isEmpty then none else some s)
  | v => if v.truthy then .error "target path is not a string" else return none

/-- Bash 経路のコマンド `tool_input.get("command") or ""`。truthy 非文字列は
Python の `re.search` TypeError = `.error`。 -/
def bashCommand? (payload : Value) : Except String String := do
  let toolInput ← toolInput? payload
  match (Value.obj toolInput).get? "command" with
  | some (.str s) => return s
  | some v => if v.truthy then .error "command is not a string" else return ""
  | none => return ""

/-- `payload.get("cwd") or "."`。truthy 非文字列は Python の `Path(cwd)`
TypeError = `.error`(相対パスの解決時にのみ評価される)。 -/
def cwd? (payload : Value) : Except String String :=
  match (payload.get? "cwd").getD .null with
  | .str s => .ok (if s.isEmpty then "." else s)
  | v => if v.truthy then .error "cwd is not a string" else .ok "."

/-! ## before-hash の対合(§20.4-3) -/

private def pendingBeforeAux (targetStr : String) (sessionId : Value) :
    List String → Except String Value
  | [] => .ok (.str "UNKNOWN")
  | line :: rest =>
    match Looper.Core.Json.parse line with
    | .error _ => pendingBeforeAux targetStr sessionId rest
    | .ok rec@(.obj _) =>
      if rec.get? "path" == some (.str targetStr)
          && (rec.get? "session_id").getD .null == sessionId then
        .ok (orValue ((rec.get? "before_sha256").getD .null) (.str "UNKNOWN"))
      else
        pendingBeforeAux targetStr sessionId rest
    | .ok _ => .error "pending high-risk line is not an object"

/-- `read_pending_before` 等価: pending JSONL を末尾から走査し、`path` と
`session_id` の両方が一致する最初の行の `before_sha256`(falsy は
`"UNKNOWN"`)。`pendingText?` の `none` は読取不能(OSError)= `"UNKNOWN"`。
パースできない行はスキップ、object でない有効 JSON 行は Python の
AttributeError = `.error`(レコード全体の例外パス)。 -/
def pendingBefore (pendingText? : Option String) (targetStr : String)
    (sessionId : Value) : Except String Value :=
  match pendingText? with
  | none => .ok (.str "UNKNOWN")
  | some text => pendingBeforeAux targetStr sessionId (splitLinesPy text).reverse

/-! ## high_risk_changes.jsonl のレコード -/

/-- `record_high_risk` のレコード(キーは挿入順)。`command?` は Bash 経路のみ
`some`(Python の `if command:` — 空文字列も落とす)。 -/
def highRiskRecord (now : String) (tool : Value) (targetStr : String)
    (before after : Value) (command? : Option String) : Value :=
  .obj <|
    [ ("recorded_at", .str now),
      ("recorded_by", .str "post_tool_audit hook"),
      ("type", .str "high_risk_change"),
      ("path", .str targetStr),
      ("tool", tool),
      ("before_sha256", before),
      ("after_sha256", after),
      ("reviewed_by", .null),
      ("risk_reason", .str "Write into Agent Runtime High-Risk Zone detected by hook.") ]
    ++ (match command? with
        | some c => if c.isEmpty then [] else [("command", .str (c.take 200).toString)]
        | none => [])

/-- `WRITE_TOOLS = {"Edit", "Write", "NotebookEdit"}`。 -/
def isWriteTool (tool : Value) : Bool :=
  tool == .str "Edit" || tool == .str "Write" || tool == .str "NotebookEdit"

/-! ## コンパイル時検査(期待値は CPython 3.14 の `PurePosixPath` /
post_tool_audit.py 実関数の実測。端到端の等価性は差分ファザーで検証済み — §31.2-18) -/

-- pyPathStr(str(Path(p)) の表記正規化: `.`・連続/末尾スラッシュ除去、`..` 保持)
#guard pyPathStr "a//b/./c/" == "a/b/c"
#guard pyPathStr "//x" == "//x"
#guard pyPathStr "///x" == "/x"
#guard pyPathStr "." == "."
#guard pyPathStr "" == "."
#guard pyPathStr "./x" == "x"
#guard pyPathStr "sub/../hooks/h.py" == "sub/../hooks/h.py"
#guard pyPathStr "/a/b/" == "/a/b"

-- selfAndParents([p] + p.parents)
#guard selfAndParents "/a/b" == ["/a/b", "/a", "/"]
#guard selfAndParents "a/b" == ["a/b", "a", "."]
#guard selfAndParents "/" == ["/"]
#guard selfAndParents "." == ["."]
#guard selfAndParents "//a" == ["//a", "//"]

-- relativeTo?(relative_to + as_posix、anchor 不一致・非プレフィクスは none)
#guard relativeTo? "/a" "/a/b/c" == some "b/c"
#guard relativeTo? "/a/b" "/a/b" == some "."
#guard relativeTo? "/a" "//a/b" == none
#guard relativeTo? "a" "a/b" == some "b"
#guard relativeTo? "/a/b" "/a/bc" == none
#guard relativeTo? "." "a" == some "a"

-- stateRootCandidates(CONTROL_ROOT 自身の除外と探索順)
#guard stateRootCandidates Domain.fixture "/ws/proj/hooks/h.py" "/ws/.looper"
  == [("/ws/proj/hooks/h.py", "/ws/proj/hooks/h.py/.looper/state"),
      ("/ws/proj/hooks", "/ws/proj/hooks/.looper/state"),
      ("/ws/proj", "/ws/proj/.looper/state"),
      ("/ws", "/ws/.looper/state"),
      ("/", "/.looper/state")]
#guard stateRootCandidates Domain.fixture "/cr/scripts/x" "/cr"
  == [("/cr/scripts/x", "/cr/scripts/x/.looper/state"),
      ("/cr/scripts", "/cr/scripts/.looper/state"),
      ("/", "/.looper/state")]

-- isHighRiskTarget(制御プレーン面は CONTROL_ROOT 相対のみ、High-Risk Zone は全候補)
#guard isHighRiskTarget "hooks/h.py" "/p/hooks/h.py" (some "/p") "/cr" == true
#guard isHighRiskTarget "src/a.txt" "/p/src/a.txt" (some "/p") "/cr" == false
#guard isHighRiskTarget "/cr/scripts/state.py" "/cr/scripts/state.py" none "/cr" == true
#guard isHighRiskTarget "/p/scripts/state.py" "/p/scripts/state.py" (some "/p") "/cr" == false
#guard isHighRiskTarget "x" "/p/CLAUDE.md" (some "/p") "/cr" == true
#guard isHighRiskTarget "settings.json" "/tmp/settings.json" none "/cr" == true

-- 入力抽出(or 連鎖・falsy・スライス可能性)
#guard toolInput? (.obj [("tool_input", .str "oops")]) matches .error _
#guard toolInput? (.obj [("tool_input", .null)]) matches .ok []
#guard toolInput? (.obj []) matches .ok []
#guard auditCommand? [("command", .str "")] matches .ok .null
#guard auditCommand? [("command", .arr [.str "x"])] matches .ok (.arr [.str "x"])
#guard auditCommand? [("command", .num 7 0)] matches .error _
#guard auditCommand? [("command", .bool false)] matches .ok .null
#guard writeTarget? (.obj [("tool_input", .obj [("file_path", .str ""),
  ("notebook_path", .str "n.ipynb")])]) matches .ok (some "n.ipynb")
#guard writeTarget? (.obj [("tool_input", .obj [("file_path", .num 5 0)])])
  matches .error _
#guard writeTarget? (.obj [("tool_input", .obj [("file_path", .bool false)])])
  matches .ok none
#guard bashCommand? (.obj [("tool_input", .obj [("command", .arr [.str "x"])])])
  matches .error _
#guard cwd? (.obj [("cwd", .str "")]) matches .ok "."
#guard cwd? (.obj [("cwd", .num 5 0)]) matches .error _
#guard cwd? (.obj []) matches .ok "."

-- pendingBefore(末尾から走査・両キー一致・falsy → UNKNOWN・非 object 行 = 例外)
#guard pendingBefore none "/t" .null matches .ok (.str "UNKNOWN")
#guard pendingBefore (some "{\"path\": \"/t\", \"session_id\": \"s\", \"before_sha256\": \"a1\"}\n{\"path\": \"/t\", \"session_id\": \"s\", \"before_sha256\": \"b2\"}")
  "/t" (.str "s") matches .ok (.str "b2")
#guard pendingBefore (some "{\"path\": \"/t\", \"before_sha256\": \"a1\"}")
  "/t" (.str "s") matches .ok (.str "UNKNOWN")
#guard pendingBefore (some "{\"path\": \"/t\", \"session_id\": \"s\", \"before_sha256\": null}")
  "/t" (.str "s") matches .ok (.str "UNKNOWN")
#guard pendingBefore (some "not json\n{\"path\": \"/t\", \"session_id\": \"s\", \"before_sha256\": \"a1\"}")
  "/t" (.str "s") matches .ok (.str "a1")
#guard pendingBefore (some "5\n{\"path\": \"/t\", \"session_id\": \"s\", \"before_sha256\": \"a1\"}")
  "/t" (.str "s") matches .ok (.str "a1")  -- 一致行が先(逆順走査)
#guard pendingBefore (some "{\"path\": \"/t\", \"session_id\": \"s\", \"before_sha256\": \"a1\"}\n5")
  "/t" (.str "s") matches .error _   -- 非 object 行が先
#guard pendingBefore (some "{\"path\": \"/t\", \"before_sha256\": \"a1\"}")
  "/t" .null matches .ok (.str "a1")      -- 欠損 session_id と null payload は一致

-- レコード直列化(json.dumps(..., ensure_ascii=False) と突合した実測値)
#guard (Looper.Core.Json.Value.render <$> auditRecord "T"
    (.obj [("tool_name", .str "Edit"), ("session_id", .str "s1"),
           ("tool_input", .obj [("file_path", .str "hooks/h.py")])]))
  matches .ok "{\"at\": \"T\", \"session_id\": \"s1\", \"tool\": \"Edit\", \"file\": \"hooks/h.py\", \"command\": null}"
#guard (highRiskRecord "T" (.str "Bash") "/t" (.str "UNKNOWN") (.str "ABSENT")
    (some "tee /t")).render
  == "{\"recorded_at\": \"T\", \"recorded_by\": \"post_tool_audit hook\", \"type\": \"high_risk_change\", \"path\": \"/t\", \"tool\": \"Bash\", \"before_sha256\": \"UNKNOWN\", \"after_sha256\": \"ABSENT\", \"reviewed_by\": null, \"risk_reason\": \"Write into Agent Runtime High-Risk Zone detected by hook.\", \"command\": \"tee /t\"}"
#guard (highRiskRecord "T" (.str "Edit") "/t" (.str "b") (.str "a") none).render
  == "{\"recorded_at\": \"T\", \"recorded_by\": \"post_tool_audit hook\", \"type\": \"high_risk_change\", \"path\": \"/t\", \"tool\": \"Edit\", \"before_sha256\": \"b\", \"after_sha256\": \"a\", \"reviewed_by\": null, \"risk_reason\": \"Write into Agent Runtime High-Risk Zone detected by hook.\"}"

-- bashCandidateTokens(pathish 抽出 → `/`・`.` フィルタ → mutator 後方一致)
#guard bashCandidateTokens "tee scripts/state.py" == ["scripts/state.py"]
#guard bashCandidateTokens "grep foo hooks/x.py > /tmp/out"
  == ["/tmp/out"]  -- 読み取り言及は mutator の後方でない
#guard bashCandidateTokens "echo hi" == []
#guard bashCandidateTokens "mv a.txt b.txt; cat c.txt"
  == ["a.txt", "b.txt"]  -- セグメント跨ぎの c.txt は対象外
#guard bashCandidateTokens "rm -rf x" == []  -- `/` も `.` も含まないトークン

end Looper.Hook.PostTool
