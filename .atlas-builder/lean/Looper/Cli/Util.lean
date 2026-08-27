import Looper.Core.Json
import Looper.Core.StaticConfig
import Looper.Core.Stop
import Looper.Core.Settings
import Looper.Core.SettingsDoctor
import Looper.Core.Path
import Looper.Core.Render
import Looper.Core.ProjectIndex
import Looper.Core.Runs
import Looper.Core.Classify.Profile
import Looper.Core.Time
import Looper.State.Model
import Looper.Io.Fs
import Looper.Io.Clock
import Looper.Domain

/-!
`Looper.Cli.Util` — シェルスクリプトが依存する小さな判定・抽出サブコマンド群
(R-7: シェル内に判定ロジックを書かず `bin/<tool> util <subcmd>` へ収容する)。

- `json-get <keypath> [--file <p>] [--default <s>] [--join <sep>] [--lenient]`
  JSON(stdin または `--file`)からドット区切りキーパスの値を 1 行で出力。
  欠落・null は `--default`(既定は空文字)。`--lenient` は読取不能・パース
  失敗・型不整合もすべて default へ倒す(fail-open。旧 `read_validation_status`
  の except-全捕捉に対応)。無指定時のエラーは stderr + exit 2(fail-closed)。
  Python の `dict.get(k, default)` は「キーはあるが null」を default に
  倒さないが、本実装は null も default に写す(state.py 出力に「null の
  status/message」は現れないため実挙動は同一。厳密には意図差として凍結)。
- `stop-status`  stdin の should-stop payload から Run-Status を 1 行出力
  (旧 `stop_run_status_from_json`。優先順の定義は `Core.Stop` の一箇所のみ
  = D-005 の複製消滅)。
- `token`  `/dev/urandom` の 32 バイトを 64 桁 hex で出力
  (旧 `secrets.token_hex(32)`)。
- `file-age-exceeds <path> <seconds>`  mtime からの経過が `<seconds>` を超えて
  いれば exit 0、さもなくば exit 1。stat 失敗(消滅)も exit 0(= stale 扱い、
  旧 `loop_lock_is_stale_by_age` の OSError 分岐)。比較は秒精度(旧実装は
  float 秒。用途はレース緩和ヒューリスティックで 1 秒未満の差は無害)。
- `read-only-settings <project> <control> <handoff> [essence-new]`  3 パスを
  実体解決して I-022/I-027 のセッション設定 JSON を 1 行出力(構築は
  `Core.Settings`)。第 4 引数 `essence-new` は new-Essence インタビューの
  variant(対象一括 Edit deny の代わりに ESSENCE.md を ask、§2.1.4)。
  旧 Python の `Path.resolve()`(strict=False)と違い不存在パスは解決できず
  exit 2 に倒す(厳格側)— 呼び出し元は 3 パスとも直前に存在を保証している。
- `bound-settings <project> <control>`  2 パスを実体解決し、base
  (`{control}/.claude/settings.json`)の `_<snake>_profile` を読んで
  loop / supervise の bound overlay JSON を 1 行出力する(構築は
  `Core.Settings.boundSession`、§16.1)。base が読めない・パース不能・
  `_<snake>_profile` が欠落/不正(= unbound か旧形式)は stderr に
  `just init` 教示 + exit 2(fail-closed — profile は init 経由でのみ発効
  する、の読み手側)。launcher は lock 取得後に invocation につき 1 回
  呼ぶ(I-018: lock 後ならどの framework 遷移も invocation 中に base を
  書き換えられない)。
- `loop-heartbeat <path> --project T --cycle N --max-cycles N --run-id R
  --session-mode {fresh|continue} --loop-pid P --loop-started-at-epoch E`
  §19.1-9 の表示専用 heartbeat(スキーマ v1)を atomic に書く(tmp→rename —
  watch の 1s ポーリングに破れた読みを見せない)。`started_at`(+`_epoch`)は
  書き込み時点の現在時刻で、ISO 整形は `<PREFIX>_TZ` のオフセット方言
  (§8.4-2)。JSON 組み立てをここに収容するのは R-7 — project title は `"` や
  `\` を含み得るため bash printf の直組みでは壊れる。ここ自体は通常の
  fail-closed(引数不正・不明 session-mode・書込不能は stderr + exit 2)で、
  display-only の握り潰しは呼び出し元 `write_loop_heartbeat` の `|| warn` が
  担う(§19.1-9 の best-effort)。

init / bootstrap / doctor 向け:

- `relpath <path> <start>`  `os.path.relpath(path, start)` 互換。両引数を
  cwd 基準で `abspath`(字句正規化のみ・symlink 非解決)してから相対化。
- `render <src> <dst> <mode> --title T --rel R`
  init のバインドテンプレート描画(トークンは TITLE / PATH の 2 種、§16.1)。
  検証は書き込み前、置換はアトミック(`.render.<pid>.tmp` → rename)。
  json モードは描画結果の JSON 妥当性を検証してから置く。エラーは exit 2
  (旧 SystemExit の exit 1 と同じ die 側)。
- `seed <src> <dst> [--replace TOKEN=VALUE]...`  逐次トークン置換シード
  (bootstrap の seed / init の workspace README)。--replace なしは verbatim
  コピー。アトミック(`.seed.<pid>.tmp` → rename)。
- `project-index other|prune <index> <target> <control>`  §8.1 registry の
  1:1 ガード(`other` は target 以外の登録を `title:root` で出力、`prune` は
  それを明示 null に落として書き戻す)。index が読めない・パース不能は
  旧実装同様 no-op の exit 0(呼び出し元 ensure が上書き再構築する前段の
  ガードであり fail-open が仕様)。`project_root` が truthy 非文字列の
  壊れ形は exit 2(旧実装は TypeError で init ごと die。同じ停止側)。
  存在しない登録先パスは実体解決の代わりに字句解決へフォールバック
  (旧 `resolve(strict=False)` との差は「不一致 = other 扱い」の厳格側)。
- `json-check <file>`  JSON として読めれば exit 0、さもなくば exit 1
  (述語。doctor の parse 診断)。
- `dangling-run <runs.jsonl>`  未終了 run の走査(`Core.Runs`)。
  `__UNREADABLE__` / 最後に開いた run_id / 空行のいずれかを出力し exit 0。

doctor の settings 検査:

- `settings-doctor <settings.json> <project> <control> [<profile>]`  doctor の
  settings 安全配線検査(検査本体は `Core.SettingsDoctor`)。base/overlay
  分割(§16.1)に対応した 2 面: base ファイルを `checkBase`(B 項目 +
  `_<snake>_profile` の存在・ESSENCE 宣言との突合 + 旧形式検出)にかけ、
  base の記録 profile から bound overlay を内部生成して `checkOverlay`
  (M 項目)にかける。base の profile が読めないときは overlay 検査を
  省略する(launcher は fail-closed に起動を拒否するため次回起動の overlay
  は存在しない — 欠落自体は checkBase の issue)。第 4 引数は ESSENCE 宣言の
  実行 profile(§11.5。省略 = standard、閉集合外の値は usage + exit 2)で、
  base との突合専用 — overlay 生成には base の記録値を使う(launcher の
  実使用値)。issue を 1 行ずつ stdout に出力し常に exit 0(空出力 =
  検査全通過。doctor.sh の `report_issues` が集約する)。パース不能・
  読取不能も「is not valid JSON」の issue 1 行(置換元インライン Python の
  except 分岐と同じ扱い)。
- `essence-profile <essence-path>`  ESSENCE.md の `profile:` 宣言(§11.5)を
  読み、発効値(standard / auto-approve / unsandboxed)を 1 行出力する。
  不在・読取不能・不正 UTF-8・placeholder(§13.1-8 と同一判定)は
  `standard` + exit 0(最厳格への縮退)。invalid 値・conflict は stderr +
  exit 2 — init はこの拒否で緩和方向の誤発効を止める(§26)。

静的設定の Lean 昇格(META.md §8.1、D-008):

- `static-config {workspace|project-index-seed}`  静的設定 SSOT
  (`Core.StaticConfig`)の rendered バイト列を stdout へ出力するだけの
  純 render 面(`util render` / `util seed` の隣)。maintainer の
  `just render-static` と doctor の drift 検査が消費する。未知の名前は
  usage + exit 2。

運用スクリプトへのドメイン軸の受け渡し(抽出計画 D-11):

- `domain-spec`  `scripts/**` が必要とするドメイン軸(bootstrap の seed 面と
  resume の人間裁定チャネル)を行指向で出力する。`scripts/**` は製品間で
  バイト同一なので、シェルは面を列挙せず**軸を読む**。書式・不変条件は
  `domainSpecLines` の頭注を参照。
-/

namespace Looper.Cli.Util

open Looper

/-- `util` の全サブコマンド(宣言順 = usage の表示順)。**この 1 本が
`util` の usage とトップレベル usage の両方を駆動する**。直下の `run` の
match 腕と対で保つ — 腕を足してここへ載せ忘れると、実装済みだが誰にも
案内されないサブコマンドになる(8 で足した `domain-spec` が実際にそうなった)。 -/
def commands : List String :=
  ["json-get", "stop-status", "token", "file-age-exceeds", "read-only-settings",
   "bound-settings", "loop-heartbeat", "relpath", "render", "seed",
   "project-index", "json-check", "dangling-run", "settings-doctor",
   "essence-profile", "static-config", "domain-spec"]

private def usage (d : Domain) : String :=
  "usage: " ++ d.binCommand ++ " util {" ++ String.intercalate "|" commands ++ "} ..."

/-! ## json-get -/

private structure JsonGetArgs where
  keypath : List String
  file? : Option String := none
  dflt : String := ""
  join? : Option String := none
  lenient : Bool := false

private def parseJsonGetArgs (args : List String) : Option JsonGetArgs :=
  go args none {keypath := []}
where
  go : List String → Option String → JsonGetArgs → Option JsonGetArgs
    | [], some keypath, acc => some { acc with keypath := keypath.splitOn "." }
    | [], none, _ => none
    | "--file" :: v :: rest, kp, acc => go rest kp { acc with file? := some v }
    | "--default" :: v :: rest, kp, acc => go rest kp { acc with dflt := v }
    | "--join" :: v :: rest, kp, acc => go rest kp { acc with join? := some v }
    | "--lenient" :: rest, kp, acc => go rest kp { acc with lenient := true }
    | positional :: rest, none, acc =>
      if positional.startsWith "--" then none else go rest (some positional) acc
    | _ :: _, some _, _ => none

/-- キーパスの値の 1 行文字列化(純粋核)。欠落・null → default、配列は
`--join` があるときだけ連結(要素は文字列のみ)、object は常にエラー。 -/
def jsonGetOutput (root : Core.Json.Value) (keypath : List String)
    (dflt : String) (join? : Option String) : Except String String :=
  match root.getPath? keypath with
  | none | some .null => .ok dflt
  | some (.str s) => .ok s
  | some (.bool b) => .ok (if b then "true" else "false")
  | some (.num m e) => .ok (Core.Json.Value.num m e).render
  | some (.arr items) =>
    match join? with
    | none => .error "value is an array; pass --join <sep>"
    | some sep => do
      let strs ← items.mapM fun v =>
        match v.asStr? with
        | some s => Except.ok s
        | none => Except.error "array contains a non-string element"
      pure (String.intercalate sep strs)
  | some (.obj _) => .error "value is an object, not a scalar"

#guard (jsonGetOutput (.obj [("mode", .str "steering")]) ["mode"] "" none).toOption
    == some "steering"
#guard (jsonGetOutput (.obj [("mode", .null)]) ["mode"] "" none).toOption == some ""
#guard (jsonGetOutput (.obj []) ["status"] "unknown" none).toOption == some "unknown"
#guard (jsonGetOutput (.obj [("a", .obj [("b", .bool true)])])
    ["a", "b"] "" none).toOption == some "true"
#guard (jsonGetOutput (.obj [("runs", .arr [.str "R-1", .str "R-2"])])
    ["runs"] "" (some ",")).toOption == some "R-1,R-2"
#guard (jsonGetOutput (.obj [("runs", .arr [])]) ["runs"] "" (some ",")).toOption
    == some ""
#guard (jsonGetOutput (.obj []) ["runs"] "" (some ",")).toOption == some ""
#guard (jsonGetOutput (.obj [("a", .arr [.num 1 0])]) ["a"] "" (some ",")).isOk
    == false
#guard (jsonGetOutput (.obj [("a", .obj [])]) ["a"] "" none).isOk == false

private def runJsonGet (d : Domain) (args : List String) : IO UInt32 := do
  let some parsed := parseJsonGetArgs args
    | do
      IO.eprintln ("usage: " ++ d.binCommand ++ " util json-get <keypath> [--file <path>] [--default <value>] [--join <sep>] [--lenient]")
      pure 2
  let text? : Option String ← match parsed.file? with
    | some f => Io.Fs.readFile? f
    | none =>
      try
        pure (some (← (← IO.getStdin).readToEnd))
      catch _ =>
        pure none
  let result : Except String String := do
    let some text := text?
      | .error (match parsed.file? with
          | some f => s!"cannot read {f}"
          | none => "cannot read stdin")
    let root ← Core.Json.parse text
    jsonGetOutput root parsed.keypath parsed.dflt parsed.join?
  match result with
  | .ok s =>
    IO.println s
    pure 0
  | .error e =>
    if parsed.lenient then
      IO.println parsed.dflt
      pure 0
    else
      IO.eprintln s!"{d.tool}: json-get: {e}"
      pure 2

/-! ## stop-status -/

private def runStopStatus (d : Domain) : IO UInt32 := do
  let text ←
    try
      (← IO.getStdin).readToEnd
    catch _ =>
      IO.eprintln s!"{d.tool}: stop-status: cannot read stdin"
      return 2
  match Core.Json.parse text
      |>.bind (Core.Stop.runStatusFromJson d.domainStopReasons) with
  | .ok status =>
    IO.println status
    pure 0
  | .error e =>
    IO.eprintln s!"{d.tool}: stop-status: {e}"
    pure 2

/-! ## token -/

private def bytesToHex (bs : ByteArray) : String :=
  bs.foldl (init := "") fun acc b =>
    (acc.push (Core.Prim.hexDigit (b.toNat / 16))).push (Core.Prim.hexDigit (b.toNat % 16))

private def runToken (d : Domain) : IO UInt32 := do
  let bytes ←
    try
      let handle ← IO.FS.Handle.mk "/dev/urandom" .read
      handle.read 32
    catch e =>
      IO.eprintln s!"{d.tool}: token: cannot read /dev/urandom: {e}"
      return 2
  if bytes.size != 32 then
    IO.eprintln s!"{d.tool}: token: short read from /dev/urandom ({bytes.size} bytes)"
    return 2
  IO.println (bytesToHex bytes)
  pure 0

/-! ## file-age-exceeds -/

private def runFileAgeExceeds (d : Domain) (path maxAgeStr : String) : IO UInt32 := do
  let some maxAge := maxAgeStr.toNat?
    | do
      IO.eprintln ("usage: " ++ d.binCommand ++ " util file-age-exceeds <path> <seconds>")
      pure 2
  let mtime? : Option Int ←
    try
      pure (some (← System.FilePath.metadata path).modified.sec)
    catch _ =>
      pure none
  match mtime? with
  | none => pure 0  -- 消滅・stat 失敗は stale 扱い(次の mkdir が決める)
  | some mtime =>
    let now ← Io.Clock.epochSeconds
    pure (if now - mtime > Int.ofNat maxAge then 0 else 1)

/-! ## read-only-settings -/

private def runReadOnlySettings (d : Domain) (project control handoff : String)
    (essenceNew : Bool) : IO UInt32 := do
  let resolve (label p : String) : IO (Option String) := do
    match ← Io.Fs.realPath? p with
    | some rp => pure (some rp.toString)
    | none => do
      IO.eprintln s!"{d.tool}: read-only-settings: cannot resolve {label}: {p}"
      pure none
  let some projectR ← resolve "project root" project | pure 2
  let some controlR ← resolve "control root" control | pure 2
  let some handoffR ← resolve "handoff root" handoff | pure 2
  IO.println (Core.Settings.readOnlySession d projectR controlR handoffR
    essenceNew).renderCompactAscii
  pure 0

/-! ## bound-settings -/

private def runBoundSettings (d : Domain) (project control : String) : IO UInt32 := do
  let resolve (label p : String) : IO (Option String) := do
    match ← Io.Fs.realPath? p with
    | some rp => pure (some rp.toString)
    | none => do
      IO.eprintln s!"{d.tool}: bound-settings: cannot resolve {label}: {p}"
      pure none
  let some projectR ← resolve "project root" project | pure 2
  let some controlR ← resolve "control root" control | pure 2
  let settingsPath := controlR ++ "/.claude/settings.json"
  -- §16.1 / §11.5: profile は init が base に焼いた `_<snake>_profile` だけ
  -- から発効する。unbound(キー不在が構造保証)・旧形式・破損はここで
  -- fail-closed に止め、`just init` へ誘導する。
  let initHint := "run `just init ../<project>` to (re)bind this control plane (META.md §16.1)"
  let some text ← Io.Fs.readFile? settingsPath
    | do
      IO.eprintln s!"{d.tool}: bound-settings: cannot read {settingsPath}; {initHint}"
      pure 2
  match Core.Json.parse text with
  | .error e =>
    IO.eprintln s!"{d.tool}: bound-settings: {settingsPath} is not valid JSON: {e}"
    pure 2
  | .ok settings =>
    match Core.Settings.baseProfile? d settings with
    | none =>
      IO.eprintln <|
        s!"{d.tool}: bound-settings: {settingsPath} records no valid " ++
        s!"_{d.snake}_profile (unbound or pre-split legacy base); {initHint}"
      pure 2
    | some profile =>
      IO.println (Core.Settings.boundSession d projectR controlR profile).renderCompactAscii
      pure 0

/-! ## relpath -/

private def runRelpath (path start : String) : IO UInt32 := do
  let cwd := (← IO.currentDir).toString
  IO.println (Core.Path.relpath (Core.Path.abspath cwd start) (Core.Path.abspath cwd path))
  pure 0

/-! ## render -/

private structure RenderArgs where
  title : Option String := none
  rel : Option String := none
  profile : Option String := none

private def parseRenderFlags : List String → RenderArgs →
    Option (Core.Render.Binding × Option String)
  | [], acc => do
    pure ({ title := ← acc.title, rel := ← acc.rel }, acc.profile)
  | "--title" :: v :: rest, acc => parseRenderFlags rest { acc with title := some v }
  | "--rel" :: v :: rest, acc => parseRenderFlags rest { acc with rel := some v }
  | "--profile" :: v :: rest, acc =>
    parseRenderFlags rest { acc with profile := some v }
  | _, _ => none

private def renderUsage (d : Domain) : String :=
  "usage: " ++ d.binCommand ++ " util render <src> <dst> {json|just|raw} --title <t> --rel <r> [--profile standard|auto-approve|unsandboxed]"

private def runRender (d : Domain) (src dst mode : String) (flags : List String) : IO UInt32 := do
  let some mode := Core.Render.Mode.parse? mode
    | do IO.eprintln (renderUsage d); pure 2
  let some (binding, profileStr?) := parseRenderFlags flags {}
    | do IO.eprintln (renderUsage d); pure 2
  -- `--profile` は settings.json.tmpl(json モード)専用(§11.5、§16.1)。
  -- 他モードのテンプレは profile 行を持たないため、指定自体を配線ミスとして
  -- 拒否し、無指定なら派生を適用しない。
  let profile? ← match profileStr? with
    | none => pure none
    | some s =>
      match Core.Classify.Profile.parse? s with
      | some p =>
        if mode != .json then
          IO.eprintln
            s!"{d.tool}: render: --profile applies only to the json mode (settings.json.tmpl, §16.1)"
          return 2
        pure (some p)
      | none => do
        IO.eprintln s!"{d.tool}: render: unknown profile '{s}' (standard|auto-approve|unsandboxed)"
        return 2
  let some text ← Io.Fs.readFile? src
    | do IO.eprintln s!"{d.tool}: render: cannot read {src}"; pure 2
  -- §11.5: profile 派生(`_<snake>_profile` 行の exactly-once 置換)は
  -- レンダ(トークン置換)前のテンプレテキストへ適用する。standard 含め
  -- 行が「ちょうど 1 回」でなければテンプレが期待の形から動いた、なので
  -- 描画自体を拒否する(fail-closed — 壊れた live settings を作らない)。
  let text ← match profile? with
    | none => pure text
    | some profile =>
      match Core.Classify.deriveProfileTemplate d profile text with
      | some t => pure t
      | none => do
        IO.eprintln <|
          s!"{d.tool}: render: template does not match the profile derivation " ++
          s!"patterns (profile '{profile.tag}', §11.5); refusing to render"
        return 2
  match Core.Render.renderBind d mode binding text with
  | .error e =>
    IO.eprintln s!"{d.tool}: render: {e}"
    pure 2
  | .ok out =>
    try
      Io.Fs.writeFileAtomicTagged dst "render" out
      pure 0
    catch e =>
      IO.eprintln s!"{d.tool}: render: cannot write {dst}: {e}"
      pure 2

/-! ## seed -/

private def parseSeedReplacements : List String → List (String × String) →
    Option (List (String × String))
  | [], acc => some acc.reverse
  | "--replace" :: v :: rest, acc =>
    match v.splitOn "=" with
    | token :: valueParts =>
      if token.isEmpty || valueParts.isEmpty then none
      else parseSeedReplacements rest ((token, String.intercalate "=" valueParts) :: acc)
    | [] => none
  | _, _ => none

private def runSeed (d : Domain) (src dst : String) (flags : List String) : IO UInt32 := do
  let some replacements := parseSeedReplacements flags []
    | do
      IO.eprintln ("usage: " ++ d.binCommand ++ " util seed <src> <dst> [--replace TOKEN=VALUE]...")
      pure 2
  let some text ← Io.Fs.readFile? src
    | do IO.eprintln s!"{d.tool}: seed: cannot read {src}"; pure 2
  try
    Io.Fs.writeFileAtomicTagged dst "seed" (Core.Render.substitute text replacements)
    pure 0
  catch e =>
    IO.eprintln s!"{d.tool}: seed: cannot write {dst}: {e}"
    pure 2

/-! ## project-index -/

/-- 登録 rel を照合用の絶対パスへ解決する。実体解決(realPath)を優先し、
不存在なら字句解決(`abspath`)へフォールバック — 旧 `resolve(strict=False)`
との差は docstring のとおり厳格側(不一致 = other)に倒れる。 -/
private def resolveRegisteredRoot (controlResolved rel : String) : IO String := do
  let candidate := Core.Path.abspath controlResolved rel
  match ← Io.Fs.realPath? candidate with
  | some r => pure r.toString
  | none => pure candidate

private def runProjectIndex (d : Domain) (action index target control : String) : IO UInt32 := do
  -- target / control は呼び出し元(resolve_project / assert_control_root)が
  -- 実在を保証している。解決不能はここでは想定外のハード失敗。
  let some targetR ← Io.Fs.realPath? target
    | do IO.eprintln s!"{d.tool}: project-index: cannot resolve target: {target}"; pure 2
  let some controlR ← Io.Fs.realPath? control
    | do IO.eprintln s!"{d.tool}: project-index: cannot resolve control root: {control}"; pure 2
  -- 読めない・パース不能な index は旧実装同様 no-op(exit 0、fail-open)。
  let some idx ← Io.Fs.readJson? index
    | pure 0
  match Core.ProjectIndex.shape idx with
  | .absent => pure 0
  | .malformed =>
    IO.eprintln s!"{d.tool}: project-index: project.project_root has a non-string shape; repair project_index.json (§8.1)"
    pure 2
  | .registered title rel? =>
    let pointsAtTarget ← match rel? with
      | none => pure false
      | some rel => do
        let root ← resolveRegisteredRoot controlR.toString rel
        pure (root == targetR.toString)
    if pointsAtTarget then
      pure 0
    else
      match action with
      | "other" =>
        match rel? with
        | none => pure 0  -- 照合するパスなし = other なし(truthiness の写し)
        | some rel =>
          IO.println s!"{title}:{← resolveRegisteredRoot controlR.toString rel}"
          pure 0
      | _ => do  -- prune
        Io.Fs.writeFileAtomic index ((Core.ProjectIndex.pruned idx).renderPretty ++ "\n")
        IO.eprintln s!"[{d.tool}] pruned stale project_index entries: {title}"
        pure 0

/-! ## json-check -/

private def runJsonCheck (d : Domain) (path : String) : IO UInt32 := do
  let some text ← Io.Fs.readFile? path
    | do IO.eprintln s!"{d.tool}: json-check: cannot read {path}"; pure 1
  match Core.Json.parse text with
  | .ok _ => pure 0
  | .error e =>
    IO.eprintln s!"{d.tool}: json-check: {path}: {e}"
    pure 1

/-! ## dangling-run -/

private def runDanglingRun (path : String) : IO UInt32 := do
  let scanned := match ← Io.Fs.readFile? path with
    | none => Core.Runs.Scan.unreadable  -- OSError → unreadable(旧実装と同一)
    | some text => Core.Runs.scan text
  match scanned with
  | .unreadable => IO.println "__UNREADABLE__"
  | .dangling rid => IO.println rid
  | .clean => IO.println ""
  pure 0

/-! ## settings-doctor -/

private def runSettingsDoctor (d : Domain) (path project control profileStr : String) :
    IO UInt32 := do
  -- 第 4 引数は `util essence-profile` の出力(閉集合の正値)を渡す契約。
  -- 閉集合外は配線ミスなので usage 側の exit 2 で大きく落とす(fail-closed)。
  let some essenceProfile := Core.Classify.Profile.parse? profileStr
    | do
      IO.eprintln s!"{d.tool}: settings-doctor: unknown profile '{profileStr}' (standard|auto-approve|unsandboxed)"
      pure 2
  let some text ← Io.Fs.readFile? path
    | do IO.println s!".claude/settings.json is not valid JSON: cannot read {path}"; pure 0
  match Core.Json.parse text with
  | .error e =>
    IO.println s!".claude/settings.json is not valid JSON: {e}"
    pure 0
  | .ok settings =>
    for issue in Core.SettingsDoctor.checkBase d settings essenceProfile do
      IO.println issue
    -- overlay 検査(M 項目)は launcher と同じ生成を内部でなぞる: base の
    -- 記録 profile(実使用値)で boundSession を生成し、独立列挙の
    -- checkOverlay にかける。base の profile が読めなければ launcher は
    -- fail-closed に起動を拒否する(= 次回起動の overlay は存在しない)ので
    -- 省略する — 欠落自体は checkBase が issue 化済み。
    match Core.Settings.baseProfile? d settings with
    | none => pure 0
    | some profile =>
      let cwd := (← IO.currentDir).toString
      for issue in Core.SettingsDoctor.checkOverlay d
          (Core.Settings.boundSession d project control profile)
          project control cwd profile do
        IO.println issue
      pure 0

/-! ### checkOverlay × boundSession の突合凍結

overlay は launcher と同じ binary が生成するため、checkOverlay の M 項目
診断は settings-doctor CLI からは到達不能である(生成物は常に列挙と一致
するか、両方が同時に漂流する)。自己承認を遮断する tripwire として、
生成(`Core.Settings.boundSession`)× 独立列挙(`Core.SettingsDoctor.
checkOverlay`)の一致を build ごとにここで凍結する — どちらか一方だけが
動けばビルドが落ちる。対称 3 分岐の mismatch 文言も、宣言と実態の
クロスで凍結する(黒箱スイートの残り 2 点は U-020 の逐語参照実装と
Core/Settings の #guard バイト凍結)。 -/

#guard [Core.Classify.Profile.standard, .autoApprove, .unsandboxed].all fun p =>
  Core.SettingsDoctor.checkOverlay Domain.fixture
    (Core.Settings.boundSession Domain.fixture "/w/proj" "/w/.looper" p)
    "/w/proj" "/w/.looper" "/w/.looper" p == []

-- standard overlay を relaxed 宣言で検査: ask 3 面の残存だけが issue
#guard Core.SettingsDoctor.checkOverlay Domain.fixture
    (Core.Settings.boundSession Domain.fixture "/w/proj" "/w/.looper" .standard)
    "/w/proj" "/w/.looper" "/w/.looper" .autoApprove
  == [
    "permissions.ask must not contain 'Edit(//w/proj/CLAUDE.md)' (recorded profile 'auto-approve' removes the project ask surfaces — a settings ask outranks the hook's allow, §11.5)",
    "permissions.ask must not contain 'Edit(//w/proj/.claude/**)' (recorded profile 'auto-approve' removes the project ask surfaces — a settings ask outranks the hook's allow, §11.5)",
    "permissions.ask must not contain 'Edit(//w/proj/.mcp.json)' (recorded profile 'auto-approve' removes the project ask surfaces — a settings ask outranks the hook's allow, §11.5)"]

-- auto-approve overlay を unsandboxed 宣言で検査: sandbox だけが issue
#guard Core.SettingsDoctor.checkOverlay Domain.fixture
    (Core.Settings.boundSession Domain.fixture "/w/proj" "/w/.looper" .autoApprove)
    "/w/proj" "/w/.looper" "/w/.looper" .unsandboxed
  == ["sandbox.enabled must be false (recorded profile 'unsandboxed', §11.5)"]

-- unsandboxed overlay を standard 宣言で検査: ask 3 面の欠落 + sandbox
#guard Core.SettingsDoctor.checkOverlay Domain.fixture
    (Core.Settings.boundSession Domain.fixture "/w/proj" "/w/.looper" .unsandboxed)
    "/w/proj" "/w/.looper" "/w/.looper" .standard
  == [
    "permissions.ask must contain 'Edit(//w/proj/CLAUDE.md)' (project agent-runtime ask floor, §16.1; recorded profile 'standard')",
    "permissions.ask must contain 'Edit(//w/proj/.claude/**)' (project agent-runtime ask floor, §16.1; recorded profile 'standard')",
    "permissions.ask must contain 'Edit(//w/proj/.mcp.json)' (project agent-runtime ask floor, §16.1; recorded profile 'standard')",
    "sandbox.enabled must be true"]

-- 負の凍結: 空 overlay に対する checkOverlay の issue 全列(文言・順序)。
-- 上の `== []` は列挙の**存在**を守らない(検査を消しても真のまま)ため、
-- M 項目の各床が 1 つでも列挙から落ちればここで build が落ちる。
#guard Core.SettingsDoctor.checkOverlay Domain.fixture (.obj [])
    "/w/proj" "/w/.looper" "/w/.looper" .standard
  == [
    "permissions.deny must contain 'Edit(//w/.looper/CLAUDE.md)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/.claude/agents/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/.claude/commands/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/.claude/rules/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/.claude/skills/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/scripts/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/templates/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/recipes/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/META.md)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/README.md)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/justfile)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/.agent/prompts/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/.agent/state/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/bin/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.deny must contain 'Edit(//w/.looper/lean/**)' (immutable CONTROL_ROOT, §11.3)",
    "permissions.ask must contain 'Edit(//w/.looper/.claude/settings.json)' (human-approved live-settings repair surface for read-only sessions, §28.5-3)",
    "permissions.ask must contain 'Edit(//w/proj/CLAUDE.md)' (project agent-runtime ask floor, §16.1; recorded profile 'standard')",
    "permissions.ask must contain 'Edit(//w/proj/.claude/**)' (project agent-runtime ask floor, §16.1; recorded profile 'standard')",
    "permissions.ask must contain 'Edit(//w/proj/.mcp.json)' (project agent-runtime ask floor, §16.1; recorded profile 'standard')",
    "permissions.allow must grant project access via the absolute `//<abs>` spelling containing '//w/proj'; a relative `Edit(../PROJECT/**)` grants nothing (§19.1-5, §28.5)",
    "sandbox.enabled must be true",
    "sandbox.failIfUnavailable must be true (never degrade to unsandboxed Bash)",
    "sandbox.autoAllowBashIfSandboxed must be false",
    "sandbox.allowUnsandboxedCommands must be false",
    "sandbox.network.allowedDomains must include github.com",
    "sandbox.network.allowedDomains must include api.github.com",
    "sandbox.network.allowedDomains must include raw.githubusercontent.com",
    "sandbox.network.allowedDomains must include objects.githubusercontent.com",
    "sandbox.network.allowedDomains must include registry.npmjs.org",
    "sandbox.network.allowedDomains must include pypi.org",
    "sandbox.network.allowedDomains must include files.pythonhosted.org",
    "sandbox.network.allowedDomains must include crates.io",
    "sandbox.network.allowedDomains must include static.crates.io",
    "sandbox.network.allowedDomains must include index.crates.io",
    "sandbox.network.allowedDomains must include proxy.golang.org",
    "sandbox.network.allowedDomains must include sum.golang.org",
    "sandbox.network.allowedDomains must include releases.lean-lang.org",
    "sandbox.network.allowedDomains must include lakecache.blob.core.windows.net",
    "sandbox.filesystem.allowWrite must permit CONTROL_ROOT/.agent/tmp (/w/.looper/.agent/tmp) for state and single-flight locks",
    "sandbox.filesystem.denyRead must protect PROJECT_ROOT/.env",
    "sandbox.filesystem.denyRead must protect ~/.ssh",
    "sandbox.filesystem.denyRead must protect ~/.aws",
    "sandbox.filesystem.denyRead must protect ~/.config/gcloud",
    "sandbox.filesystem.denyRead must protect ~/.kube",
    "sandbox.filesystem.denyRead must protect ~/.claude",
    "sandbox.filesystem.denyRead must protect ~/.claude.json",
    "sandbox.filesystem.denyWrite must protect PROJECT_ROOT/ESSENCE.md",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/CLAUDE.md",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/.claude",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/scripts",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/templates",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/recipes",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/META.md",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/.agent/state",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/bin",
    "sandbox.filesystem.denyWrite must protect CONTROL_ROOT/lean",
    "additionalDirectories must be exactly [PROJECT_ROOT] (/w/proj); got []"]

/-! ## essence-profile -/

private def runEssenceProfile (d : Domain) (path : String) : IO UInt32 := do
  match ← Io.Fs.readFile? path with
  | none =>
    -- 不在・読取不能・不正 UTF-8 は standard(§11.5 — 最厳格への縮退)。
    -- 欠損 Essence 自体の停止は bootstrap 後の validate / loop が担う。
    IO.println Core.Classify.Profile.standard.tag
    pure 0
  | some text =>
    -- placeholder(§13.1-8 と同一判定: ガイドブロック残存・空白のみ・未消化
    -- FILL マーカー)は standard — テンプレ由来のテキストから profile を
    -- 発効させない。
    if Core.Text.containsSub text d.placeholderMarker
        || (Core.Text.pyStrip text).isEmpty
        || Core.Text.containsSub text State.Model.fillMarker then
      IO.println Core.Classify.Profile.standard.tag
      pure 0
    else
      match Core.Classify.scanProfile text with
      | .invalid raw =>
        IO.eprintln <|
          s!"{d.tool}: essence-profile: invalid profile value '{raw}' — " ++
          "the closed set is standard | auto-approve | unsandboxed (§11.5)"
        pure 2
      | .conflict =>
        IO.eprintln <|
          s!"{d.tool}: essence-profile: conflicting profile declarations — " ++
          "declare exactly one (§11.5)"
        pure 2
      | scan =>
        IO.println scan.effective.tag
        pure 0

/-! ## static-config -/

private def runStaticConfig (d : Domain) (name : String) : IO UInt32 := do
  match Core.StaticConfig.rendered? d name with
  | some rendered =>
    -- rendered は末尾 LF 込みの正確な配布バイト列(println は使わない)
    IO.print rendered
    pure 0
  | none =>
    IO.eprintln ("usage: " ++ d.binCommand ++ " util static-config {workspace|project-index-seed}")
    pure 2

/-! ## domain-spec — 運用スクリプトが読むドメイン軸(抽出計画 D-11 / Phase 8)

`scripts/**` は製品間でバイト同一である。ところが bootstrap の seed 面も
resume の人間裁定チャネルも**ドメインの宣言**であり、シェルがそれを列挙すると
その 1 点でツリーが割れる。そこで軸は `Looper.Domain` に一本化し、シェルは
この行指向の出力を読むだけにする — 綴りの正本は Lean 側の 1 箇所である。

書式は `<key> <value>`(value は行の残り全部)。**未知の key をシェルは黙って
無視する**ので、軸を足しても古いスクリプトは壊れない。逆に、シェルが必要と
する key が消えると当該機能が静かに無効化されるため、消す側は必ず消費点を
同時に直すこと。 -/

/-- `util domain-spec` の出力行(純粋)。 -/
def domainSpecLines (d : Domain) : List String :=
  (d.bootstrapSeeds.map fun s =>
    "seed " ++ (if s.verbatim then "verbatim" else "render") ++ " " ++ s.path)
  ++ (match d.resumeAdjudication? with
      | none => []
      | some a =>
        ["adjudication-flag " ++ a.flag,
         "adjudication-id-prefix " ++ a.idPrefix,
         "adjudication-arg-form " ++ a.argForm,
         "adjudication-target-noun " ++ a.targetNoun,
         "adjudication-stop-payload-key " ++ a.stopPayloadKey]
        ++ a.verdicts.map ("adjudication-verdict " ++ ·))

/-- 行指向の書式が成立する条件: どの値も改行を含まない。**軸が改行を含むと
シェル側の 1 行 1 レコードが崩れ、後続の key が値として食われる** ため、
出力する前に fail closed する。 -/
def domainSpecEmittable (d : Domain) : Bool :=
  (domainSpecLines d).all fun l => !(l.toList.contains '\n')

#guard domainSpecEmittable Domain.fixture
#guard domainSpecEmittable Domain.fixtureRich
#guard domainSpecLines Domain.fixture ==
  ["seed render ESSENCE.md", "seed verbatim .looper/.gitignore"]
#guard domainSpecLines Domain.fixtureRich ==
  ["seed render ESSENCE.md", "seed render extra/README.md",
   "seed verbatim .looper/.gitignore",
   "adjudication-flag --resolve-extra", "adjudication-id-prefix X",
   "adjudication-arg-form <X-id>=<verdict>",
   "adjudication-target-noun open extra entries",
   "adjudication-stop-payload-key domain_gate_ledgers",
   "adjudication-verdict yes", "adjudication-verdict no"]

private def runDomainSpec (d : Domain) : IO UInt32 := do
  if !domainSpecEmittable d then
    IO.eprintln s!"{d.tool}: domain-spec: an axis value contains a newline; refusing to emit a line-oriented spec"
    return 2
  for line in domainSpecLines d do
    IO.println line
  pure 0

/-! ## loop-heartbeat -/

private def heartbeatUsage (d : Domain) : String :=
  "usage: " ++ d.binCommand ++ " util loop-heartbeat <path> --project <title> --cycle <n> --max-cycles <n> --run-id <id> --session-mode {fresh|continue} --loop-pid <pid> --loop-started-at-epoch <epoch>"

/-- §19.1-9 の heartbeat の確定引数(全欄必須)。 -/
structure Heartbeat where
  project : String
  cycle : Nat
  maxCycles : Nat
  runId : String
  sessionMode : String
  loopPid : Nat
  loopStartedAtEpoch : Nat

private structure HeartbeatAcc where
  project : Option String := none
  cycle : Option Nat := none
  maxCycles : Option Nat := none
  runId : Option String := none
  sessionMode : Option String := none
  loopPid : Option Nat := none
  loopStartedAtEpoch : Option Nat := none

/-- `<tool>-loop.sh` の SESSION_MODE の閉集合(§19.1)。 -/
private def sessionModes : List String := ["fresh", "continue"]

/-- strict パース: 未知フラグ・値欠落・非数値・閉集合外の session-mode は
none(= usage)。欠落フィールドの検査は最後の `Heartbeat` 構築が担う。 -/
private def parseHeartbeatFlags : List String → HeartbeatAcc → Option Heartbeat
  | [], acc => do
    pure { project := ← acc.project, cycle := ← acc.cycle,
           maxCycles := ← acc.maxCycles, runId := ← acc.runId,
           sessionMode := ← acc.sessionMode, loopPid := ← acc.loopPid,
           loopStartedAtEpoch := ← acc.loopStartedAtEpoch }
  | "--project" :: v :: rest, acc =>
    parseHeartbeatFlags rest { acc with project := some v }
  | "--cycle" :: v :: rest, acc =>
    (v.toNat?).bind fun n => parseHeartbeatFlags rest { acc with cycle := some n }
  | "--max-cycles" :: v :: rest, acc =>
    (v.toNat?).bind fun n => parseHeartbeatFlags rest { acc with maxCycles := some n }
  | "--run-id" :: v :: rest, acc =>
    parseHeartbeatFlags rest { acc with runId := some v }
  | "--session-mode" :: v :: rest, acc =>
    if sessionModes.contains v then
      parseHeartbeatFlags rest { acc with sessionMode := some v }
    else none
  | "--loop-pid" :: v :: rest, acc =>
    (v.toNat?).bind fun n => parseHeartbeatFlags rest { acc with loopPid := some n }
  | "--loop-started-at-epoch" :: v :: rest, acc =>
    (v.toNat?).bind fun n =>
      parseHeartbeatFlags rest { acc with loopStartedAtEpoch := some n }
  | _, _ => none

/-- heartbeat payload の純粋構築(スキーマ v1、§19.1-9 のキー順)。epoch 併記は
読み手(watch)の経過時間計算を TZ 逆パース非依存の整数減算にするため。 -/
def heartbeatPayload (h : Heartbeat) (nowEpoch offsetMinutes : Int) :
    Core.Json.Value :=
  .obj [
    ("schema_version", .num 1 0),
    ("project", .str h.project),
    ("cycle", .num (Int.ofNat h.cycle) 0),
    ("max_cycles", .num (Int.ofNat h.maxCycles) 0),
    ("run_id", .str h.runId),
    ("session_mode", .str h.sessionMode),
    ("started_at", .str (Core.Time.isoTimestamp nowEpoch offsetMinutes)),
    ("started_at_epoch", .num nowEpoch 0),
    ("loop_pid", .num (Int.ofNat h.loopPid) 0),
    ("loop_started_at",
      .str (Core.Time.isoTimestamp (Int.ofNat h.loopStartedAtEpoch) offsetMinutes)),
    ("loop_started_at_epoch", .num (Int.ofNat h.loopStartedAtEpoch) 0)
  ]

-- `"` / `\` 入り title でも valid JSON として往復する(bash printf 直組みを
-- 禁じた理由の検収点。黒箱側は U-019)
#guard
  (let payload := heartbeatPayload
    { project := "sa\"mp\\le", cycle := 3, maxCycles := 25, runId := "R-1",
      sessionMode := "continue", loopPid := 42, loopStartedAtEpoch := 1755000000 }
    1755000120 540
   (Core.Json.parse payload.render).toOption == some payload)

private def runLoopHeartbeat (d : Domain) (path : String) (flags : List String) : IO UInt32 := do
  let usageErr : IO UInt32 := do
    IO.eprintln (heartbeatUsage d)
    pure 2
  let some hb := parseHeartbeatFlags flags {} | return ← usageErr
  let offsetMinutes := (((← IO.getEnv (d.envPrefix ++ "_TZ")).getD "")
    |> Core.Time.parseTzOffset?).getD Core.Time.defaultOffsetMinutes
  let payload := heartbeatPayload hb (← Io.Clock.epochSeconds) offsetMinutes
  try
    Io.Fs.writeJsonPretty ⟨path⟩ payload
    pure 0
  catch e =>
    IO.eprintln s!"{d.tool}: loop-heartbeat: cannot write {path}: {e}"
    pure 2

/-! ## ディスパッチ -/

def run (d : Domain) : List String → IO UInt32
  | "json-get" :: rest => runJsonGet d rest
  | ["stop-status"] => runStopStatus d
  | ["token"] => runToken d
  | ["file-age-exceeds", path, maxAge] => runFileAgeExceeds d path maxAge
  | ["read-only-settings", project, control, handoff] =>
    runReadOnlySettings d project control handoff false
  | ["read-only-settings", project, control, handoff, "essence-new"] =>
    runReadOnlySettings d project control handoff true
  | ["bound-settings", project, control] =>
    runBoundSettings d project control
  | "loop-heartbeat" :: path :: flags => runLoopHeartbeat d path flags
  | ["loop-heartbeat"] => do
    IO.eprintln (heartbeatUsage d)
    pure 2
  | ["relpath", path, start] => runRelpath path start
  | "render" :: src :: dst :: mode :: flags => runRender d src dst mode flags
  | "seed" :: src :: dst :: flags => runSeed d src dst flags
  | ["project-index", action, index, target, control] =>
    if action == "other" || action == "prune" then
      runProjectIndex d action index target control
    else do
      IO.eprintln (usage d)
      pure 2
  | ["json-check", path] => runJsonCheck d path
  | ["dangling-run", path] => runDanglingRun path
  | ["settings-doctor", path, project, control] =>
    runSettingsDoctor d path project control "standard"
  | ["settings-doctor", path, project, control, profile] =>
    runSettingsDoctor d path project control profile
  | ["essence-profile", path] => runEssenceProfile d path
  | ["static-config", name] => runStaticConfig d name
  | ["domain-spec"] => runDomainSpec d
  | _ => do
    IO.eprintln (usage d)
    pure 2

end Looper.Cli.Util
