import Std.Time
import Looper.Core.Time

/-!
`Looper.Io.Clock` — 現在時刻取得の薄い IO シェル。

暦変換と整形は `Looper.Core.Time` の純粋関数が行い、ここは epoch 秒の
取得と env 注入だけを持つ(§31.4-2 の注入原則)。`Std.Time` は Lean
toolchain 同梱であり、ゼロ依存(R-9)を破らない。
-/

namespace Looper.Io.Clock

/-- 現在時刻の Unix epoch 秒。 -/
def epochSeconds : IO Int := do
  let ts ← Std.Time.Timestamp.now
  pure ts.toSecondsSinceUnixEpoch.val

/-- ローカル ISO タイムスタンプ。TZ オフセットは `envVar`(UTC 固定
オフセット方言、`Core.Time.parseTzOffset?`)から読み、不正・不在は
既定オフセットに倒す。 -/
def nowLocal (envVar : String) : IO String := do
  let offsetMinutes := (((← IO.getEnv envVar).getD "")
    |> Looper.Core.Time.parseTzOffset?).getD
      Looper.Core.Time.defaultOffsetMinutes
  pure (Looper.Core.Time.isoTimestamp (← epochSeconds) offsetMinutes)

end Looper.Io.Clock
