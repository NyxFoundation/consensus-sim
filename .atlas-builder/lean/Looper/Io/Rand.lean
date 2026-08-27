/-!
`Looper.Io.Rand` — `/dev/urandom` ベースの乱数 hex(IO シェル)。

Python の `secrets.token_hex(n)` / `uuid.uuid4().hex[:2n]` に対応する。
消費側(run_id・loop-gate id・ロック token)はいずれも不透明文字列として
扱うため、形式(hex 長)だけを踏襲する(LEAN_MIGRATION_PLAN.md §4.4)。
-/

namespace Looper.Io.Rand

def hexOfBytes (bytes : ByteArray) : String :=
  let digit := fun (n : Nat) =>
    if n < 10 then Char.ofNat ('0'.toNat + n) else Char.ofNat ('a'.toNat + (n - 10))
  String.ofList (bytes.toList.foldr
    (fun b acc => digit (b.toNat / 16) :: digit (b.toNat % 16) :: acc) [])

/-- `/dev/urandom` から n バイト読んで hex 化(2n 文字)。読めない場合は
例外(呼び出し元のハードエラー枠へ — トークン無しで先へ進めない)。 -/
def randomHex (n : Nat) : IO String := do
  let handle ← IO.FS.Handle.mk "/dev/urandom" .read
  let bytes ← handle.read (USize.ofNat n)
  if bytes.size != n then
    throw (IO.userError s!"short read from /dev/urandom ({bytes.size} bytes)")
  pure (hexOfBytes bytes)

end Looper.Io.Rand
