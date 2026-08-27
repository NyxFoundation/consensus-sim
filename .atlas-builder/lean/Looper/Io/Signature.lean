import Looper.Io.Fs

/-!
`Looper.Io.Signature` — ツリー内容から指紋を取る 2 つの IO シェル。

どちらも「ディレクトリを決定的順序で走査し、内容の SHA-256 から署名を作る」
形をしており、Over-Project ループだけが使う:

- `progressFileEntries` — cycle の progress signature(§8.4)が読む
  `(相対パス, SHA-256)` 列。
- `recipeSourceHash` — canonical recipe-original hash(§29.4、D-004 の
  単一定義)。`Looper recipe hash` と `state validate` の drift 検査が共有する。

読み取りそのものの薄い層は `Io.Fs`、ハッシュ計算は純粋核 `Core.Sha256`。
-/

namespace Looper.Io.Signature

open Looper.Io.Fs (sha256File)

/-- `dir` 配下の全ファイルを再帰列挙する(Python `Path.rglob("*")` +
`is_file()` フィルタに対応)。判定は `IO.FS.metadata`(= stat、シンボリック
リンクを辿る)なので、リンク先がファイルなら収集・ディレクトリなら潜る。
順序は不定 — 呼び出し側が必要な順序に整列する。 -/
partial def listFilesRec (dir : System.FilePath) : IO (Array System.FilePath) := do
  let mut out := #[]
  for entry in ← dir.readDir do
    match (← entry.path.metadata).type with
    | .dir => out := out ++ (← listFilesRec entry.path)
    | .file => out := out.push entry.path
    | _ => pure ()
  return out

/-- Python `progress_file_entries`: root 不在は空、単一ファイルは
`[(name, sha)]`、ディレクトリは `os.walk` 忠実順 — 各ディレクトリで
ファイル名ソート順に収集してから、除外名を除いたサブディレクトリへ
ソート順に潜る(DFS 先行順。全体ソートではない — root 直下のファイルが
サブディレクトリ内より先に並ぶ)。読めないディレクトリは Python
`os.walk(onerror=None)` と同じく黙ってスキップする。

裁定済みの意図差(META.md §31.2): Python の os.walk は
「ディレクトリへの symlink」を辿らず収集もしないが、本実装は stat
(リンク追跡)で分類するため辿る。progress signature は自プロジェクトの
ツリーに対する決定的な指紋であり、両実装とも同一ツリーへ決定的なので
シャドー比較は同一フィクスチャで一致する(通常のプロジェクトツリーに
ディレクトリ symlink は現れない)。 -/
partial def progressFileEntries (root : System.FilePath) (excluded : List String) :
    IO (List (String × String)) := do
  let meta? ← try pure (some (← root.metadata)) catch _ => pure none
  match meta? with
  | none => pure []
  | some m =>
    if m.type == .file then
      pure [(root.fileName.getD "", ← sha256File root)]
    else if m.type != .dir then
      pure []
    else
      walk root ""
where
  walk (dir : System.FilePath) (relPrefix : String) : IO (List (String × String)) := do
    let entries ← try dir.readDir catch _ => pure #[]
    let mut files : List String := []
    let mut dirs : List String := []
    for e in entries do
      let t ← try pure (some (← (dir / e.fileName).metadata).type)
        catch _ => pure none
      match t with
      | some .dir => dirs := dirs ++ [e.fileName]
      | some .file => files := files ++ [e.fileName]
      | _ => pure ()  -- 壊れた symlink 等は is_file() False でスキップ
    let mut out : List (String × String) := []
    for name in files.mergeSort (· ≤ ·) do
      let rel := if relPrefix.isEmpty then name else s!"{relPrefix}/{name}"
      out := out ++ [(rel, ← sha256File (dir / name))]
    for name in (dirs.filter (fun d => !excluded.contains d)).mergeSort (· ≤ ·) do
      let rel := if relPrefix.isEmpty then name else s!"{relPrefix}/{name}"
      out := out ++ (← walk (dir / name) rel)
    pure out

/-- canonical recipe-original hash(META.md §29.4、D-004 の単一定義)。
recipe ディレクトリ配下の全ファイルをパスセグメント列の辞書式順に並べ、
`相対パス<TAB>ファイル SHA-256` 行を LF 連結した UTF-8 バイト列の SHA-256。
`Cli/Recipe`(`<bin> recipe hash`)と `<bin> state validate` の
source hash drift 検査が共有する。読めないファイルは例外(呼び出し元の
ハードエラー枠へ)。 -/
def recipeSourceHash (recipeDir : System.FilePath) : IO String := do
  let files ← listFilesRec recipeDir
  let prefixLen := recipeDir.toString.length + 1
  let rels := files.map (fun f => (f.toString.drop prefixLen).toString)
  let sorted := rels.qsort (fun a b => a.splitOn "/" < b.splitOn "/")
  let mut lines : Array String := #[]
  for rel in sorted do
    let contents ← IO.FS.readBinFile (recipeDir / rel)
    lines := lines.push s!"{rel}\t{Looper.Core.Sha256.hexDigest contents}"
  pure (Looper.Core.Sha256.hexDigest
    (String.toUTF8 (String.intercalate "\n" lines.toList)))

end Looper.Io.Signature
