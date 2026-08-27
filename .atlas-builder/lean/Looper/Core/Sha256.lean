import Looper.Core.Prim

/-!
`Looper.Core.Sha256` — 純 Lean の SHA-256(FIPS 180-4。LEAN_MIGRATION_PLAN.md §4.4)。

ゼロ依存の実行層が SHA-256 を必要とする箇所(recipe source hash、High-Risk
before/after hash、progress signature)の共通基盤。`Id.run do` + 範囲 for の
全域実装で、性能が問題になった場合のみ lake の C ソース同梱へフォールバック
する方針(LEAN_MIGRATION_PLAN.md §4.4)。

検証は FIPS 180-4 / NIST の標準ベクタとパディング境界(55/56/63/64/65 バイト)
を `#guard` でコンパイル時検査する(LEAN_MIGRATION_PLAN.md §4.6 B-T1 の土台)。
-/

namespace Looper.Core.Sha256

/-- FIPS 180-4 §4.2.2 の定数 K(素数の立方根の小数部)。 -/
private def kTable : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

/-- FIPS 180-4 §5.3.3 の初期ハッシュ値(素数の平方根の小数部)。 -/
private def initState : Array UInt32 :=
  #[0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

/-- 右ローテート。呼び出しは全て `0 < n < 32` の定数なのでシフト量は常に有効。 -/
@[inline] private def rotr (n : Nat) (x : UInt32) : UInt32 :=
  (x >>> UInt32.ofNat n) ||| (x <<< UInt32.ofNat (32 - n))

/-- FIPS 180-4 §5.1.1 のパディング: `0x80`・ゼロ詰め・メッセージ長
(ビット、64 ビット big-endian)で全長を 64 バイトの倍数にする。 -/
private def pad (msg : ByteArray) : ByteArray := Id.run do
  let bitLen := msg.size * 8
  -- size + 1 + zeros + 8 ≡ 0 (mod 64) を満たす最小の zeros
  let zeros := (119 - msg.size % 64) % 64
  let mut out := msg.push 0x80 ++ ByteArray.mk (Array.replicate zeros 0)
  for i in [0:8] do
    out := out.push (UInt8.ofNat ((bitLen >>> ((7 - i) * 8)) % 256))
  return out

/-- 1 ブロック(64 バイト、`data` の `off` から)の圧縮関数(FIPS 180-4 §6.2.2)。 -/
private def compress (state : Array UInt32) (data : ByteArray) (off : Nat) :
    Array UInt32 := Id.run do
  let mut w : Array UInt32 := Array.replicate 64 0
  for t in [0:16] do
    let p := off + t * 4
    w := w.set! t <|
      (UInt32.ofNat data[p]!.toNat) <<< 24 |||
      (UInt32.ofNat data[p + 1]!.toNat) <<< 16 |||
      (UInt32.ofNat data[p + 2]!.toNat) <<< 8 |||
      (UInt32.ofNat data[p + 3]!.toNat)
  for t in [16:64] do
    let s0 := rotr 7 w[t - 15]! ^^^ rotr 18 w[t - 15]! ^^^ (w[t - 15]! >>> 3)
    let s1 := rotr 17 w[t - 2]! ^^^ rotr 19 w[t - 2]! ^^^ (w[t - 2]! >>> 10)
    w := w.set! t (w[t - 16]! + s0 + w[t - 7]! + s1)
  let mut a := state[0]!
  let mut b := state[1]!
  let mut c := state[2]!
  let mut d := state[3]!
  let mut e := state[4]!
  let mut f := state[5]!
  let mut g := state[6]!
  let mut h := state[7]!
  for t in [0:64] do
    let s1 := rotr 6 e ^^^ rotr 11 e ^^^ rotr 25 e
    let ch := (e &&& f) ^^^ (~~~e &&& g)
    let temp1 := h + s1 + ch + kTable[t]! + w[t]!
    let s0 := rotr 2 a ^^^ rotr 13 a ^^^ rotr 22 a
    let maj := (a &&& b) ^^^ (a &&& c) ^^^ (b &&& c)
    let temp2 := s0 + maj
    h := g
    g := f
    f := e
    e := d + temp1
    d := c
    c := b
    b := a
    a := temp1 + temp2
  return #[state[0]! + a, state[1]! + b, state[2]! + c, state[3]! + d,
           state[4]! + e, state[5]! + f, state[6]! + g, state[7]! + h]

/-- SHA-256 ダイジェスト(32 バイト)。 -/
def digest (msg : ByteArray) : ByteArray := Id.run do
  let padded := pad msg
  let mut state := initState
  for i in [0:padded.size / 64] do
    state := compress state padded (i * 64)
  let mut out := ByteArray.empty
  for h in state do
    out := out.push (UInt8.ofNat (h >>> 24).toNat)
    out := out.push (UInt8.ofNat ((h >>> 16) &&& 0xff).toNat)
    out := out.push (UInt8.ofNat ((h >>> 8) &&& 0xff).toNat)
    out := out.push (UInt8.ofNat (h &&& 0xff).toNat)
  return out

/-- 16 進(小文字)ダイジェスト。Python `hashlib.sha256(...).hexdigest()` に対応。 -/
def hexDigest (msg : ByteArray) : String :=
  (digest msg).foldl
    (fun acc byte =>
      (acc.push (Prim.hexDigit (byte.toNat / 16))).push (Prim.hexDigit (byte.toNat % 16)))
    ""

/-! ## コンパイル時テスト(FIPS 180-4 / NIST 標準ベクタとパディング境界) -/

#guard hexDigest (String.toUTF8 "")
    == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
#guard hexDigest (String.toUTF8 "abc")
    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
#guard hexDigest (String.toUTF8 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
#guard hexDigest (String.toUTF8
      "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
    == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
-- パディング境界: 55(長さ 8 バイトがちょうど収まる)/ 56(ブロック繰越)/
-- 63 / 64 / 65(ブロック境界前後)
#guard hexDigest (ByteArray.mk (Array.replicate 55 0x61))
    == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
#guard hexDigest (ByteArray.mk (Array.replicate 56 0x61))
    == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
#guard hexDigest (ByteArray.mk (Array.replicate 63 0x61))
    == "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"
#guard hexDigest (ByteArray.mk (Array.replicate 64 0x61))
    == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
#guard hexDigest (ByteArray.mk (Array.replicate 65 0x61))
    == "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"
-- 非 UTF-8 バイト列(LEAN_MIGRATION_PLAN.md §4.4 ByteArray 規約: ハッシュ対象はバイナリ安全)
#guard hexDigest (ByteArray.mk #[0, 1, 2, 255, 254, 128])
    == "3398f34271a12bcc61b468edfbf7b6e482b348b35d831bc8432ebbb0c922b711"

end Looper.Core.Sha256
