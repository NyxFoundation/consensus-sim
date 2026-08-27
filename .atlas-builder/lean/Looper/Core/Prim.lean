/-!
`Looper.Core.Prim` — モジュール横断で共有する言語プリミティブ級の小関数。

Python 原本の写しではなく Lean 側の実装都合で生じる文字・数値プリミティブの
単一定義点。従来は各モジュールが同一定義を private に重複させていた
(`dropLit?` は 7 箇所)。ここに置くのはドメイン知識を含まない自明な
全域関数に限り、各モジュールは選択 open(`open Looper.Core.Prim (...)`)で
借用する。
-/

namespace Looper.Core.Prim

/-- 入力接尾辞の先頭からリテラルを消費し、一致すれば残りを返す
(re リテラル断片マッチの共通核)。 -/
def dropLit? : List Char → List Char → Option (List Char)
  | cs, [] => some cs
  | [], _ :: _ => none
  | c :: cs, l :: ls => if c == l then dropLit? cs ls else none

/-- 検証済み十進数字列 → Nat。 -/
def digitsToNat (ds : List Char) : Nat :=
  ds.foldl (fun n c => n * 10 + (c.toNat - '0'.toNat)) 0

/-- 左ゼロ詰め(`len` 桁未満のとき)。 -/
def padLeftZeros (s : String) (len : Nat) : String :=
  String.ofList (List.replicate (len - s.length) '0') ++ s

/-- 16 進 1 桁(小文字)。 -/
def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat ('0'.toNat + n) else Char.ofNat ('a'.toNat + (n - 10))

/-- 16 進 2 桁(小文字)。Python repr の `\xHH` に対応する。 -/
def hex2 (n : Nat) : String :=
  String.ofList [hexDigit (n / 16 % 16), hexDigit (n % 16)]

/-- `--key=value` を `--key value` の 2 要素へ展開する(argparse の両記法)。 -/
def expandEquals (arg : String) : List String :=
  if arg.startsWith "--" then
    match arg.splitOn "=" with
    | key :: tail@(_ :: _) => [key, String.intercalate "=" tail]
    | _ => [arg]
  else [arg]

#guard dropLit? "abc".toList "ab".toList == some ['c']
#guard dropLit? "abc".toList "ax".toList == none
#guard digitsToNat "407".toList == 407
#guard padLeftZeros "7" 3 == "007"
#guard hex2 0x1b == "1b"
#guard expandEquals "--key=a=b" == ["--key", "a=b"]
#guard expandEquals "value" == ["value"]

end Looper.Core.Prim
