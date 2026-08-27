import Looper.Cli.Main
import AtlasBuilder.Domain

/-!
マルチコールバイナリ `atlas-builder` のエントリポイント。

ディスパッチ本体は `Looper.Cli.Main.run`(製品を知らない共有実装)にあり、
ここは**製品のドメインパックを渡すだけ**の 1 行である(抽出計画 §4.2)。
Prover 側のように製品固有サブコマンドを持つ製品は、ここで自分の match を
先に置いて残りを `Looper.Cli.Main.run` へ委譲する — Looper に「他方では
死んでいるコード」を持ち込まないための形である。
-/

def main (args : List String) : IO UInt32 :=
  Looper.Cli.Main.run AtlasBuilder.domain args
