import Looper.Core.Json
import Looper.Core.Sha256

/-!
`Looper.Io.Fs` — ファイル読み取りの薄い IO シェル(信頼境界)。

「読めない」を `none` へ写像するのは best-effort(fail-open)な読み取り専用。
gate 判定に使う canonical state の読み取り失敗を停止側へ倒す fail-closed 系
(I-021)は、対応フェーズで別の明示的なコンストラクタとして導入する(§31.5)。
-/

namespace Looper.Io.Fs

/-- 読めなければ `none`(不存在・権限・不正 UTF-8 のいずれも)。
stop_check.py の `read_json` の読み取り側に対応する。 -/
def readFile? (path : System.FilePath) : IO (Option String) := do
  try
    let contents ← IO.FS.readFile path
    pure (some contents)
  catch _ =>
    pure none

/-- JSON として読めなければ `none`。stop_check.py の `read_json` に対応する。 -/
def readJson? (path : System.FilePath) : IO (Option Looper.Core.Json.Value) := do
  pure ((← readFile? path).bind fun s => (Looper.Core.Json.parse s).toOption)

/-- `IO.FS.realPath` の失敗(不存在・権限等)を `none` へ(LEAN_MIGRATION_PLAN.md §4.3)。
Python の `Path.resolve(strict=False)` と違い不存在パスは解決できないので、
呼び出し側が none を厳格側(違反・不一致)へ倒す。 -/
def realPath? (path : System.FilePath) : IO (Option System.FilePath) := do
  try
    let resolved ← IO.FS.realPath path
    pure (some resolved)
  catch _ =>
    pure none

/-- 読み取り失敗の理由を保持する版(I-021 の unreadable 理由表示用)。 -/
def readFileResult (path : System.FilePath) : IO (Except String String) := do
  try
    let contents ← IO.FS.readFile path
    pure (.ok contents)
  catch e =>
    pure (.error (toString e))

/-- canonical state のアトミック書き込み(META.md §13.5): 同一ディレクトリの
一時ファイル(`<name>.<pid>.tmp`)へ書いてから rename で置き換える。
書き込み途中のクラッシュが切り詰められたファイルを残さないようにする。 -/
def writeFileAtomic (path : System.FilePath) (contents : String) : IO Unit := do
  let pid ← IO.Process.getPID
  let tmp := path.withFileName s!"{path.fileName.getD "file"}.{pid}.tmp"
  IO.FS.writeFile tmp contents
  IO.FS.rename tmp path

/-- 親ディレクトリを掘り、`json.dumps(..., indent=2, ensure_ascii=False)` + 改行を
`writeFileAtomic` で置く(state.py `write_json` / vendored state.py
`write_json_atomic` の共通形)。 -/
def writeJsonPretty (path : System.FilePath) (payload : Looper.Core.Json.Value) :
    IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  writeFileAtomic path (payload.renderPretty ++ "\n")

/-- `writeFileAtomic` のタグ付き版: 一時ファイル名を `<name>.<tag>.<pid>.tmp`
にする。init の render(`.render.`)と seed(`.seed.`)はこの形が契約 —
`_lib.sh` の forbidden-path パターン(`*.render.*.tmp` / `*.seed.*.tmp`)が
クラッシュ残骸をチェックポイントから排除する根拠になっている。 -/
def writeFileAtomicTagged (path : System.FilePath) (tag : String)
    (contents : String) : IO Unit := do
  let pid ← IO.Process.getPID
  let tmp := path.withFileName s!"{path.fileName.getD "file"}.{tag}.{pid}.tmp"
  IO.FS.writeFile tmp contents
  IO.FS.rename tmp path

/-- `writeFileAtomic` のパーミッション指定版: rename で本置換する前に
一時ファイルへ `mode` を適用する(置換後のファイルに露出の隙間を作らない)。 -/
def writeFileAtomicWithMode (path : System.FilePath) (contents : String)
    (mode : IO.FileRight) : IO Unit := do
  let pid ← IO.Process.getPID
  let tmp := path.withFileName s!"{path.fileName.getD "file"}.{pid}.tmp"
  IO.FS.writeFile tmp contents
  IO.setAccessRights tmp mode
  IO.FS.rename tmp path

/-- 解決済み成分リスト(逆順)を絶対パス文字列へ。空 = root `/`。 -/
private def renderRevComps (rev : List String) : String :=
  if rev.isEmpty then "/" else "/" ++ String.intercalate "/" rev.reverse

/-- Python `Path.resolve()`(strict=False)対応(LEAN_MIGRATION_PLAN.md §4.3)。CPython 3.12
`posixpath._joinrealpath` の逐成分解決を写す: 成分ごとに lstat で symlink
判定し、非 symlink・不存在成分は**入力の綴りのまま**継ぎ足し、`..` は解決済み
プレフィクス(symlink を含まない)の字句 pop(root 床)、symlink 成分だけを
実体解決する。case-insensitive FS(macOS 既定)で `IO.FS.realPath`(C
realpath)が実在パス全体を on-disk 綴りへ正規化してしまうのに対し、CPython は
symlink でない成分の大小文字を保持する — guard の判定面(read-only 3 allow
面・control-surface 分類等)はこの綴り差に感応するため、成分単位の忠実な
写しが等価性の要件になる(差分ファザーで検出された解決意味論差の
解消)。

CPython との既知差は symlink・NUL の隅のみで、いずれもシャドー生成の等価
領域外(フィクスチャは symlink を作らない)に置く: (1) dangling symlink は
CPython が readlink 内容の文字列で継続するのに対し、こちらはリンク名の綴りの
まま字句継続する、(2) symlink ループは CPython `pathlib.resolve` が事後
`stat()` の ELOOP を RuntimeError に写す(guard の `_resolve_lenient` は
OSError/ValueError しか捕捉しないため fail-open クラッシュ = 判定なし)のに
対し、こちらはリンク名のまま字句継続して通常評価する(裁定済みの「未捕捉
例外の型による明示化」系と同型)、(3) symlink 成分の展開は readlink 逐次で
なく C realpath なので、経路上に symlink があり、かつ先行成分の入力綴り・
リンク内容の綴りが on-disk 綴りと大小文字で異なるときだけ綴りが変わりうる、
(4) NUL 込みパス等で CPython が ValueError を上げる場合(こちらは字句解決を
返す = 呼び出し元の例外パスに入らない。guard 面は `resolveLenient?` が入力の
NUL を先に `none` へ写すので不感)。 -/
def resolveNonStrict (path : System.FilePath) : IO System.FilePath := do
  let s := path.toString
  let abs ← if s.startsWith "/" then pure s
    else do
      let cwd := (← IO.currentDir).toString
      pure ((if cwd == "/" then "" else cwd) ++ "/" ++ s)
  let mut rev : List String := []
  for name in (abs.splitOn "/").filter (fun c => c ≠ "" && c ≠ ".") do
    if name == ".." then
      -- CPython `path, _ = split(path)`: プレフィクスは symlink 解決済みなので
      -- 字句 pop が物理 pop と一致する(root では据え置き)
      rev := rev.tailD []
    else
      let candidate := (if rev.isEmpty then "" else renderRevComps rev) ++ "/" ++ name
      let isLink ← try
          pure ((← System.FilePath.symlinkMetadata ⟨candidate⟩).type == .symlink)
        catch _ =>
          pure false  -- 不存在・非ディレクトリ祖先・権限 = CPython の except OSError
      if !isLink then
        rev := name :: rev
      else
        match ← realPath? ⟨candidate⟩ with
        | some r => rev := ((r.toString.splitOn "/").filter (· ≠ "")).reverse
        | none => rev := name :: rev  -- dangling/ループ: 既知差 (1)/(2) の字句継続
  pure ⟨renderRevComps rev⟩

/-- Python `_resolve_lenient`(pre_tool_guard.py): 解決不能を `none` へ写す。
埋め込み NUL は CPython の ValueError に対応して `none`、それ以外は
`resolveNonStrict`(LEAN_MIGRATION_PLAN.md §4.3 の既知差はそちらの頭注のとおり許容領域)。guard の
呼び出し側は `none` を「どのルールにもマッチしない」に写す(§31.5 —
deny 側は生文字列判定の併走があるため解決不能が素通りにならない)。 -/
def resolveLenient? (path : String) : IO (Option String) := do
  if path.toList.contains (Char.ofNat 0) then
    return none
  try
    pure (some (← resolveNonStrict ⟨path⟩).toString)
  catch _ =>
    pure none

/-- JSONL 追記(Python `append_jsonl`): 親ディレクトリを掘ってから 1 行
追記する。失敗理由は `.error`(audit の fail-open 経路が stderr へ落とす)。 -/
def appendJsonl (path : System.FilePath) (record : Looper.Core.Json.Value) :
    IO (Except String Unit) := do
  try
    if let some parent := path.parent then
      IO.FS.createDirAll parent
    IO.FS.withFile path .append fun h =>
      h.putStr (record.render ++ "\n")
    pure (.ok ())
  catch e =>
    pure (.error (toString e))

/-- Python `sha256_or_absent`: 通常ファイル(symlink は追跡)なら内容の
SHA-256 hex、それ以外(不存在・ディレクトリ)は `"ABSENT"`。存在するのに
読めない場合は `.error`(Python の OSError = 呼び出し元の例外パス)。 -/
def sha256OrAbsent (path : System.FilePath) : IO (Except String String) := do
  let isFile ← try
      pure ((← path.metadata).type == .file)
    catch _ =>
      pure false
  if !isFile then
    return .ok "ABSENT"
  try
    pure (.ok (Looper.Core.Sha256.hexDigest (← IO.FS.readBinFile path)))
  catch e =>
    pure (.error (toString e))

/-- Python `sha256_file`(呼び出し側が `is_file()` を確認済みの経路):
内容バイト列の SHA-256 hex。読めない場合は IO 例外(Python の uncaught
OSError = 呼び出し元のハードエラー枠)。 -/
def sha256File (path : System.FilePath) : IO String := do
  pure (Looper.Core.Sha256.hexDigest (← IO.FS.readBinFile path))

end Looper.Io.Fs
