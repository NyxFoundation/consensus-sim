import Looper.Core.Prim

/-!
`Looper.Core.Time` — 表示用タイムスタンプの純粋コア(META.md §8.4)。

ゼロ依存の Lean 実行層は tzdata を持たない(LEAN_MIGRATION_PLAN.md §4.4)ため、
時刻は「Unix epoch 秒 + 固定オフセット」で扱う。epoch 秒の取得だけが IO
(`Looper.Io.Clock`)で、暦変換(proleptic Gregorian)と ISO 8601 整形は
本モジュールの純粋関数が行う。タイムスタンプは表示専用であり判定には使われない。

表示タイムゾーン ENV はオフセット方言(`+HH:MM` / `-HH:MM` / `Z` / `UTC`)を受理する
(META.md §8.4-2 の仕様変更)。旧 IANA 名(`Asia/Tokyo` 等)は解釈できず、
不正な名前の場合の Python 版と同じく既定の +09:00 へフォールバックする。
-/

namespace Looper.Core.Time

/-- 既定の表示オフセット: JST(+09:00)= 540 分(META.md §8.4-1)。 -/
def defaultOffsetMinutes : Int := 540

private def digit? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat) else none

/-- 表示タイムゾーン ENV のオフセット方言: `+HH:MM` / `-HH:MM`(HH ≤ 23、MM ≤ 59)、
`Z` / `UTC`(= +00:00)。それ以外(旧 IANA 名・空文字列含む)は none。 -/
def parseTzOffset? (raw : String) : Option Int := do
  let s := raw.trimAscii.toString
  if s == "Z" || s == "UTC" then
    some 0
  else
    match s.toList with
    | [sign, h1, h2, ':', m1, m2] =>
      let sgn : Int ← match sign with
        | '+' => some 1
        | '-' => some (-1)
        | _ => none
      let hh := (← digit? h1) * 10 + (← digit? h2)
      let mm := (← digit? m1) * 10 + (← digit? m2)
      if hh ≤ 23 && mm ≤ 59 then some (sgn * Int.ofNat (hh * 60 + mm)) else none
    | _ => none

/-- Unix epoch からの日数 → (年, 月, 日)。proleptic Gregorian
(Howard Hinnant の civil_from_days)。 -/
def civilFromDays (days : Int) : Int × Nat × Nat :=
  let z := days + 719468
  let era := z.ediv 146097
  let doe := (z.emod 146097).toNat
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  (Int.ofNat yoe + era * 400 + (if m ≤ 2 then 1 else 0), m, d)

private def pad2 (n : Nat) : String := Prim.padLeftZeros (toString n) 2

/-- epoch 秒 + 表示オフセット(分)→ ISO 8601(秒精度・オフセット付き)。
Python の `datetime.now(tz).isoformat(timespec="seconds")` に対応する。 -/
def isoTimestamp (epochSeconds : Int) (offsetMinutes : Int) : String :=
  let localSecs := epochSeconds + offsetMinutes * 60
  let (y, m, d) := civilFromDays (localSecs.ediv 86400)
  let sod := (localSecs.emod 86400).toNat
  let sign := if offsetMinutes < 0 then "-" else "+"
  s!"{Prim.padLeftZeros (toString y) 4}-{pad2 m}-{pad2 d}T{pad2 (sod / 3600)}:{pad2 (sod / 60 % 60)}:{pad2 (sod % 60)}{sign}{pad2 (offsetMinutes.natAbs / 60)}:{pad2 (offsetMinutes.natAbs % 60)}"

/-- (年, 月, 日)→ Unix epoch からの日数。`civilFromDays` の逆
(Howard Hinnant の days_from_civil)。前提: `m`/`d` は 1 始まりの暦値
(`parseIsoLocal?` が検証して渡す。`d = 0` は Nat 減算で 1 日ずれる)。 -/
def daysFromCivil (y : Int) (m d : Nat) : Int :=
  let y := if m ≤ 2 then y - 1 else y
  let era := y.ediv 400
  let yoe := (y - era * 400).toNat
  let doy := (153 * (if m > 2 then m - 3 else m + 9) + 2) / 5 + d - 1
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + Int.ofNat doe - 719468

/-- `isoTimestamp` の逆パース: `YYYY-MM-DDTHH:MM:SS±HH:MM` → epoch 秒。
`isoTimestamp` が出力するちょうどこの 1 形式のみ受理する(桁・区切り固定、
フィールド範囲検査つき)。watch の履歴 duration 計算(§15.3)が runs.jsonl の
`at` を読むために使い、往復律は下の `#guard` が凍結する。 -/
def parseIsoLocal? (s : String) : Option Int := do
  match s.toList with
  | [y1, y2, y3, y4, '-', mo1, mo2, '-', d1, d2, 'T',
     h1, h2, ':', mi1, mi2, ':', s1, s2, sign, oh1, oh2, ':', om1, om2] =>
    let y := (← digit? y1) * 1000 + (← digit? y2) * 100
      + (← digit? y3) * 10 + (← digit? y4)
    let mo := (← digit? mo1) * 10 + (← digit? mo2)
    let d := (← digit? d1) * 10 + (← digit? d2)
    let hh := (← digit? h1) * 10 + (← digit? h2)
    let mi := (← digit? mi1) * 10 + (← digit? mi2)
    let ss := (← digit? s1) * 10 + (← digit? s2)
    let sgn : Int ← match sign with
      | '+' => some 1
      | '-' => some (-1)
      | _ => none
    let oh := (← digit? oh1) * 10 + (← digit? oh2)
    let om := (← digit? om1) * 10 + (← digit? om2)
    if 1 ≤ mo && mo ≤ 12 && 1 ≤ d && d ≤ 31 && hh ≤ 23 && mi ≤ 59 && ss ≤ 59
        && oh ≤ 23 && om ≤ 59 then
      some (daysFromCivil (Int.ofNat y) mo d * 86400
        + Int.ofNat (hh * 3600 + mi * 60 + ss)
        - sgn * Int.ofNat (oh * 60 + om) * 60)
    else
      none
  | _ => none

/-- Python `datetime.now(tz).strftime("%Y%m%dT%H%M%S%z")`: 区切りなしの
コンパクト形(`%z` はコロンなしオフセット)。run_id / loop-gate id の
スタンプが使う(META.md §8.4-4)。 -/
def compactTimestamp (epochSeconds : Int) (offsetMinutes : Int) : String :=
  let localSecs := epochSeconds + offsetMinutes * 60
  let (y, m, d) := civilFromDays (localSecs.ediv 86400)
  let sod := (localSecs.emod 86400).toNat
  let sign := if offsetMinutes < 0 then "-" else "+"
  s!"{Prim.padLeftZeros (toString y) 4}{pad2 m}{pad2 d}T{pad2 (sod / 3600)}{pad2 (sod / 60 % 60)}{pad2 (sod % 60)}{sign}{pad2 (offsetMinutes.natAbs / 60)}{pad2 (offsetMinutes.natAbs % 60)}"

/-! ## コンパイル時テスト -/

#guard compactTimestamp 0 540 == "19700101T090000+0900"
#guard compactTimestamp 1767225600 0 == "20260101T000000+0000"
#guard compactTimestamp 0 (-330) == "19691231T183000-0530"

#guard isoTimestamp 0 0 == "1970-01-01T00:00:00+00:00"
#guard isoTimestamp 0 540 == "1970-01-01T09:00:00+09:00"
#guard isoTimestamp 86399 0 == "1970-01-01T23:59:59+00:00"
-- 2024-02-29(閏年)と 2026-01-01(平年跨ぎ)の既知 epoch
#guard isoTimestamp 1709164800 0 == "2024-02-29T00:00:00+00:00"
#guard isoTimestamp 1767225600 0 == "2026-01-01T00:00:00+00:00"
-- 負オフセットは日付を跨いで戻る
#guard isoTimestamp 1767225600 (-330) == "2025-12-31T18:30:00-05:30"
#guard parseTzOffset? "+09:00" == some 540
#guard parseTzOffset? "-05:30" == some (-330)
#guard parseTzOffset? "Z" == some 0
#guard parseTzOffset? " UTC " == some 0
#guard parseTzOffset? "+00:15" == some 15
#guard parseTzOffset? "Asia/Tokyo" == none
#guard parseTzOffset? "+24:00" == none
#guard parseTzOffset? "+9:00" == none
#guard parseTzOffset? "" == none

-- parseIsoLocal? は isoTimestamp の逆(往復律 — epoch × オフセットの格子で凍結。
-- 閏年 2 月末・年跨ぎ・負オフセットの日付戻りを含む)
#guard ([0, 1, 86399, 86400, 951867299, 1709164800, 1767225599, 1767225600] : List Int).all
  fun e => ([-720, -330, 0, 540, 845] : List Int).all
    fun off => parseIsoLocal? (isoTimestamp e off) == some e
#guard parseIsoLocal? "1970-01-01T00:00:00+00:00" == some 0
#guard parseIsoLocal? "1970-01-01T09:00:00+09:00" == some 0
#guard parseIsoLocal? "2025-12-31T18:30:00-05:30" == some 1767225600
-- isoTimestamp が出力しない形は受理しない(厳密に 1 形式)
#guard parseIsoLocal? "" == none
#guard parseIsoLocal? "2026-08-12T13:00:00Z" == none
#guard parseIsoLocal? "2026-08-12 13:00:00+09:00" == none
#guard parseIsoLocal? "2026-13-01T00:00:00+00:00" == none
#guard parseIsoLocal? "2026-00-01T00:00:00+00:00" == none
#guard parseIsoLocal? "2026-08-12T24:00:00+00:00" == none
#guard parseIsoLocal? "2026-08-12T23:00:00+24:00" == none

end Looper.Core.Time
