import Looper.Core.Doc
import Looper.Io.Proc
import Looper.Io.Clock
import Looper.Io.Rand
import Looper.Domain

/-!
`Looper.Io.Lock` — I-018 の単一実行スロット(canonical write window)。

置換元は state.py `canonical_mutation_slot()`(mkdir ロック + pid/token
記録 + 祖先継承 + stale 再取得)。`_lib.sh` の mkdir ロックと同じ
`CONTROL_ROOT/.agent/tmp/loop.lock` を取得または祖先から継承する。

移行に伴う裁定済みの仕様差(META.md §31.2):
- 補助だった `project_lock`(fcntl.flock)段は廃止し、mkdir ロックへ
  一本化する(LEAN_MIGRATION_PLAN.md §4.4。fcntl は Lean コアに無く、
  META.md が I-018 の実体として規定するのは mkdir ロックのみ)。
- Python は取得時に `<PREFIX>_LOCK_TOKEN` を os.environ へ輸出するが、
  Lean 版の ensure / validate は mutating transition を子プロセスとして
  起動しないため輸出しない(継承側 = 環境変数とロックファイルの照合は
  同一挙動)。
-/

namespace Looper.Io.Lock

open Looper.Core.Doc (pyIntOfString?)

private def lockDirOf (controlRoot : System.FilePath) : System.FilePath :=
  controlRoot / ".agent" / "tmp" / "loop.lock"

private def readIntFile? (path : System.FilePath) : IO (Option Int) := do
  try
    pure (pyIntOfString? (← IO.FS.readFile path))
  catch _ =>
    pure none

private def readTokenFile (path : System.FilePath) : IO String := do
  try
    pure (← IO.FS.readFile path).trimAscii.toString
  catch _ =>
    pure ""

/-- `secrets.compare_digest` 相当の定時間比較。 -/
private def constEq (a b : String) : Bool :=
  let ab := a.toUTF8
  let bb := b.toUTF8
  let byteAt := fun (bs : ByteArray) (i : Nat) =>
    if h : i < bs.size then (bs[i]'h).toNat else 0
  let n := max ab.size bb.size
  let diff := (List.range n).foldl
    (init := if ab.size == bb.size then 0 else 1)
    fun acc i => acc ||| (byteAt ab i ^^^ byteAt bb i)
  diff == 0

/-- `secrets.token_hex` / `uuid.uuid4().hex` の代替(`Io.Rand` の単一定義)。 -/
private def randomHex (n : Nat) : IO String := Looper.Io.Rand.randomHex n

private def removeTree (path : System.FilePath) : IO Unit := do
  try
    IO.FS.removeDirAll path
  catch _ =>
    pure ()

private def selfPid : IO Int := do
  pure (Int.ofNat (← IO.Process.getPID).toNat)

/-- Python `_loop_lock_ancestor_holder` の祖先歩行部。 -/
private partial def walkAncestry (owner pid : Int) (seen : List Int) :
    IO (Option Int) := do
  if pid ≤ 1 || seen.contains pid then
    return none
  if pid == owner then
    return some owner
  match ← Proc.parentPid? pid with
  | some parent => walkAncestry owner parent (pid :: seen)
  | none => return none

/-- Python `_loop_lock_ancestor_holder`: 生存している保持者が自分自身または
祖先なら some。死んだ保持者・読めない pid・無関係の保持者は none。 -/
private def ancestorHolder? (lockDir : System.FilePath) : IO (Option Int) := do
  let some owner ← readIntFile? (lockDir / "pid")
    | return none
  if !(← Proc.pidAlive owner) then
    return none
  walkAncestry owner (← selfPid) []

private def heldMessage (d : Domain) (owner : Int) : String :=
  s!"another {d.displayName} mutating transition holds the single-flight lock (pid {owner}); state mutation refused."

/-- 取得試行ループ(Python の `for _ in range(3)`)。`.ok true` = 取得
(release 必要)。 -/
private def tryAcquire (d : Domain) (lockDir : System.FilePath) :
    Nat → IO (Except String Bool)
  | 0 => pure (.error s!"could not acquire state-mutation single-flight lock: {lockDir}")
  | n + 1 => do
    let createErr? ← try
        IO.FS.createDir lockDir
        pure none
      catch e =>
        pure (some e)
    match createErr? with
    | none =>
      -- 取得成功: pid / token を記録(失敗はロックを畳んで die)
      let token ← randomHex 32
      let recordErr? ← try
          IO.FS.writeFile (lockDir / "pid") s!"{← selfPid}\n"
          IO.FS.writeFile (lockDir / "token") (token ++ "\n")
          pure none
        catch e =>
          pure (some e)
      match recordErr? with
      | none => pure (.ok true)
      | some e =>
        removeTree lockDir
        pure (.error s!"cannot record state-mutation lock owner in {lockDir}: {e}")
    | some e =>
      if !(← lockDir.pathExists) then
        -- FileExistsError 以外の OSError(Python の except OSError 分岐)
        return .error s!"cannot acquire state-mutation single-flight lock {lockDir}: {e}"
      match ← readIntFile? (lockDir / "pid") with
      | some owner =>
        if ← Proc.pidAlive owner then
          -- 生存(他ユーザー所有の PermissionError も同じ die)
          return .error (heldMessage d owner)
        -- 死亡 → stale 再取得へ
      | none =>
        -- pid 未記録: 取得途中かもしれない新鮮なロックは拒否、古い残骸のみ回収
        let age? ← try
            let md ← lockDir.metadata
            pure (some ((← Clock.epochSeconds) - md.modified.sec))
          catch _ =>
            pure none
        match age? with
        | none => return ← tryAcquire d lockDir n
        | some age =>
          if age ≤ 10 then
            return .error (s!"another {d.displayName} mutating transition is acquiring "
              ++ "the single-flight lock; state mutation refused.")
      -- 原子的 stale 再取得: rename してから消す(rename 競合は次の試行へ)
      let reclaim := lockDir.withFileName
        s!"loop.lock.reclaim.{← selfPid}.{← randomHex 16}"
      let renamed ← try
          IO.FS.rename lockDir reclaim
          pure true
        catch _ =>
          pure false
      if renamed then
        removeTree reclaim
      tryAcquire d lockDir n

/-- `canonical_mutation_slot` の取得側: `.ok false` = 祖先/トークン継承
(release 不要)、`.ok true` = 自プロセスで取得、`.error` = die 文言。 -/
def acquire (d : Domain) (controlRoot : System.FilePath) : IO (Except String Bool) := do
  let lockDir := lockDirOf controlRoot
  IO.FS.createDirAll (controlRoot / ".agent" / "tmp")
  let supplied := (← IO.getEnv (d.envPrefix ++ "_LOCK_TOKEN")).getD ""
  let recorded ← readTokenFile (lockDir / "token")
  if !supplied.isEmpty && !recorded.isEmpty && constEq supplied recorded then
    return .ok false
  if (← ancestorHolder? lockDir).isSome then
    return .ok false
  tryAcquire d lockDir 3

/-- 解放(Python の finally 節): 保持者が自分のときだけロックを畳む。 -/
def release (controlRoot : System.FilePath) : IO Unit := do
  let lockDir := lockDirOf controlRoot
  if (← readIntFile? (lockDir / "pid")) == some (← selfPid) then
    removeTree lockDir

/-- I-018 スロット下で `act` を実行する。取得失敗は `onErr`(die)。 -/
def withSlot (d : Domain) (controlRoot : System.FilePath) (onErr : String → IO UInt32)
    (act : IO UInt32) : IO UInt32 := do
  match ← acquire d controlRoot with
  | .error msg => onErr msg
  | .ok false => act
  | .ok true =>
    try
      act
    finally
      release controlRoot

end Looper.Io.Lock
