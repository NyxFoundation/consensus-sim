import Looper.Core.Text
import Looper.Domain

/-!
`Looper.Core.Essence` — 人間が書く唯一の正本 `ESSENCE.md` の解析核(純粋)。

Over-Project ループだけが持つ層である: In-Project ループ(ASL)の正本は
`schema.json` が宣言する任意の JSON 文書群であり、見出し契約も資産言及も
持たない。

置換元は state.py の ESSENCE 系ヘルパー群。凍結した意味論は次の 4 つ。

1. 正準見出し契約(§2.1.1'・§13.1-15)とその構造検査。見出し集合が閉じた
   強制契約になったため、節の特定は「レベル 2・タイトル厳密一致」である —
   旧 Python の別名リストと部分一致ヒューリスティックは全廃した。
2. 節の項目抽出(`sectionItems`)と、機械可読 directive の安全境界
   (`semanticLines` — fenced code block / HTML comment の外)。
3. `essences/` 資産言及の双方向整合(§2.1.5)。
4. `_match_tokens` / `_texts_relate` — ASCII トークン + CJK トライグラムの
   言語中立な重なり判定(§20.2-6 の advisory な対応付け)。
5. `RECIPE_POINTER_RE`(`^\s*recipe:\s*([a-z][a-z0-9-]*)@(\d+)\s*$`、
   MULTILINE)の全走査(§29)。

十進数字は ASCII `0-9` のみ受理する(`Core.Text` 頭注の裁定)。
-/

namespace Looper.Core.Essence

open Looper (Domain)
open Looper.Core.Prim (dropLit? digitsToNat)
open Looper.Core.Text (isPySpace pyStrip containsSub splitLinesPy dedup runsOf
  lowerStr normalizeWs)

/-! ## ESSENCE.md 見出し契約(§2.1.1'・§13.1-15)

ESSENCE.md の見出し骨格は「推奨テンプレート」ではなく**人間が指定した閉じた
集合の強制**である。H1 は `# ESSENCE — <題名>` として先頭に一度だけ、H2 は
`Domain.essenceHeadings` の綴り・順序で全節が必要(H3 以下は各節の内側で
自由)。集合を閉じたことで節の特定は厳密一致に単純化され、曖昧さの温床だった
別名リストと部分一致のヒューリスティックは全廃した。

**正準列そのものはドメインの語彙である**(`Domain.essenceHeadings`)。ここにあるのは
「閉じた集合を強制する」機構と、全ドメインで綴りが一致する 1 節だけである。 -/

/-- H1 タイトルの正準接頭辞(`—` は em dash U+2014)。残部が題名であり、
strip 後に非空でなければならない。 -/
def essenceH1Prefix : String := "ESSENCE — "

/-- §20.2-6: 人間が観測可能な受け入れ基準を書く節。**全ドメインで綴りが
一致する唯一の節**なので Looper が持つ(`Domain.essenceHeadings` はこれを
必ず含む — 落ちると成功条件の抽出が黙って空になる)。 -/
def essenceSuccessHeading : String := "成功条件"

/-! ## ESSENCE.md セクション項目抽出 -/

/-- `^(#{1,6})\s+(.*)$` 等価: `(level, group(2).strip())`。`#` の極大 run が
1〜6 本で直後に空白 1 文字以上(バックトラックしても短い run の直後は `#` で
`\s` に一致しないため、極大 run 判定と等価)。 -/
def mdHeading? (line : String) : Option (Nat × String) :=
  let cs := line.toList
  let k := (cs.takeWhile (· == '#')).length
  if 1 ≤ k && k ≤ 6 then
    match cs.drop k with
    | c :: rest => if isPySpace c then some (k, pyStrip (String.ofList (c :: rest))) else none
    | [] => none
  else none

/-- `^\s*(?:[-*+]|\d+[.)])\s+(?P<body>\S.*)$` 等価: `group("body").strip()`。
数字 run は極大でよい(短い run の直後は数字で `[.)]` に一致しないため
バックトラック等価)。数字は ASCII のみ(頭注の裁定)。 -/
def itemBody? (raw : String) : Option String :=
  let cs := raw.toList.dropWhile isPySpace
  let afterMarker? : Option (List Char) :=
    match cs with
    | c :: rest =>
      if c == '-' || c == '*' || c == '+' then some rest
      else
        let digits := cs.takeWhile (·.isDigit)
        if digits.isEmpty then none
        else
          match cs.drop digits.length with
          | p :: rest' => if p == '.' || p == ')' then some rest' else none
          | [] => none
    | [] => none
  match afterMarker? with
  | none => none
  | some after =>
    match after with
    | c :: _ =>
      if isPySpace c then
        let body := after.dropWhile isPySpace
        if body.isEmpty then none else some (pyStrip (String.ofList body))
      else none
    | [] => none

private structure ScanState where
  inSection : Bool := false
  inComment : Bool := false
  inFence : Bool := false
  /-- 収集済み項目(逆順)。 -/
  ritems : List String := []

/-- 分岐順序は `scanSemanticLine` と同じ「コメントがフェンスに先行」:
コメント本文の ``` は表示物であってフェンスを反転しない(かつては逆順で、
複数行コメントに ``` を書くと以降の節項目が全部フェンス内として消えた —
§2.1.1 の共有安全境界が sectionItems 側だけ割れていた)。見出しの照合は
厳密: 節の開始は「レベル 2・タイトル厳密一致」、終端は「レベル ≤ 2 の
次見出し」(H3 以下は節の内側)。 -/
private def scanLine (heading : String) (st : ScanState) (raw : String) : ScanState :=
  let stripped := pyStrip raw
  if st.inComment then
    if containsSub raw "-->" then { st with inComment := false } else st
  else if stripped.startsWith "```" || stripped.startsWith "~~~" then
    { st with inFence := !st.inFence }
  else if st.inFence then st
  else if stripped.startsWith "<!--" && !containsSub stripped "-->" then
    { st with inComment := true }
  else
    match mdHeading? raw with
    | some (level, title) =>
      if level == 2 && title == heading then
        { st with inSection := true }
      else if st.inSection && level ≤ 2 then
        { st with inSection := false }
      else st
    | none =>
      if !st.inSection then st
      else if stripped.isEmpty then st
      else if stripped.startsWith "<!--" || stripped.startsWith "-->" then st
      else
        match itemBody? raw with
        | some body => { st with ritems := body :: st.ritems }
        | none => { st with ritems := stripped :: st.ritems }

/-- 正準 H2 節 `heading` 以下(レベル ≤ 2 の次見出しで終端、H3 以下の小見出しは
内側)の非空内容行。リスト項目は本文のみ、散文行はそのまま。見出しの照合は
厳密一致であり、旧別名(`成功の定義` / `Won't` / `やらないこと` …)は節として
成立しない — 旧綴りのままの Essence は `essenceStructureIssues` が停止させる
ので、silent な取りこぼしにはならない(fail-closed、§13.1-15)。 -/
def sectionItems (heading : String) (text : String) : List String :=
  ((splitLinesPy text).foldl (scanLine heading) {}).ritems.reverse

/-- `essence_success_conditions` の純粋核(§20.2-6)。 -/
def essenceSuccessItems (text : String) : List String :=
  sectionItems essenceSuccessHeading text

/-- `essence_wont_items` の純粋核(§2.1.2)。柵の節名はドメイン軸。 -/
def essenceWontItems (d : Domain) (text : String) : List String :=
  sectionItems d.essenceWontHeading text

/-- ドメインが特別扱いする節(`Domain.essenceTrustHeading?`)の内容行。
その節を持たないドメインでは空 — **機構は全ドメインに在り、値がそれを
発火させるかを決める**(抽出計画 K-1 と同じ形)。 -/
def essenceTrustItems (d : Domain) (text : String) : List String :=
  match d.essenceTrustHeading? with
  | some heading => sectionItems heading text
  | none => []

/-! ## Markdown の意味行

`deps:` / `recipe:` のような機械可読 directive は、説明用コメントやコード例を
認可として解釈してはならない。以下は Markdown の fenced code block と HTML
comment の外にある行だけを返す共通の安全境界である。 -/

private structure SemanticScanState where
  inComment : Bool := false
  inFence : Bool := false
  /-- 収集済み行(逆順)。 -/
  rlines : List String := []

private def stripHtmlCommentsAux : Nat → List Char → Bool → List Char → Bool × List Char
  | 0, _, inComment, out => (inComment, out.reverse)
  | _ + 1, [], inComment, out => (inComment, out.reverse)
  | fuel + 1, cs@(c :: rest), inComment, out =>
    if inComment then
      match dropLit? cs "-->".toList with
      | some after => stripHtmlCommentsAux fuel after false out
      | none => stripHtmlCommentsAux fuel rest true out
    else
      match dropLit? cs "<!--".toList with
      | some after => stripHtmlCommentsAux fuel after true out
      | none => stripHtmlCommentsAux fuel rest false (c :: out)

/-- 1 行から HTML comment 部分だけを除去し、次行へ持ち越す comment 状態を返す。
行頭限定にしない: `説明 <!--` の次行にある directive も comment 内である。 -/
private def stripHtmlComments (raw : String) (inComment : Bool) : Bool × String :=
  let result := stripHtmlCommentsAux (raw.length + 1) raw.toList inComment []
  (result.1, String.ofList result.2)

private def scanSemanticLine (st : SemanticScanState) (raw : String) :
    SemanticScanState :=
  let stripped := pyStrip raw
  if st.inFence then
    if stripped.startsWith "```" || stripped.startsWith "~~~" then
      { st with inFence := false }
    else st
  else
    let (inComment, semantic) := stripHtmlComments raw st.inComment
    let semanticStripped := pyStrip semantic
    if !inComment && (semanticStripped.startsWith "```"
        || semanticStripped.startsWith "~~~") then
      { st with inComment, inFence := true }
    else if semanticStripped.isEmpty then
      { st with inComment }
    else
      { st with inComment, rlines := semantic :: st.rlines }

/-- Markdown の fenced code block と HTML comment の外にある行だけを、入力順で
返す。directive parser は必ずこの関数を通す。 -/
def semanticLines (text : String) : List String :=
  ((text.splitOn "\n").foldl scanSemanticLine {}).rlines.reverse

/-! ## ESSENCE.md 見出し構造の検査(§2.1.1'・§13.1-15)

見出し骨格は閉じた集合の強制であり、逸脱は fail-closed の停止ゲートになる。
安全境界は directive parser と同一(`semanticLines` — fenced code block /
HTML comment の外)なので、ガイドコメント内やコード例に書かれた見出し行は
構造として数えない。 -/

/-- ESSENCE.md の見出し骨格: 意味行に現れる `(level, strip 済みタイトル)` の
出現順列(`mdHeading?` と同一の見出し規約)。 -/
def essenceHeadingOutline (text : String) : List (Nat × String) :=
  (semanticLines text).filterMap mdHeading?

/-- 正準見出し契約との差分を人間可読の英語で列挙する(空リスト = 適合)。

検査するのは以下だけであり、H3 以下は各節の内側で自由:
1. 最初の見出しが H1 で、タイトルが `essenceH1Prefix` で始まり残部が非空
   (見出しが 1 つも無い場合も H1 欠如として違反)
2. H1 は文書全体で 1 個
3. H2 列(出現順)が `d.essenceHeadings` と完全一致 — 欠落・集合外・重複・
   順序違反をそれぞれ独立に報告する

呼び出し側は「ESSENCE.md が実体を持つとき」だけ本関数を通す(missing /
placeholder の間は保留 — より高優先の停止理由が先に立つ)。 -/
def essenceStructureIssues (d : Domain) (text : String) : List String :=
  let headings := d.essenceHeadings
  let outline := essenceHeadingOutline text
  let h1Ok :=
    match outline with
    | (1, title) :: _ =>
      match dropLit? title.toList essenceH1Prefix.toList with
      | some rest => !(pyStrip (String.ofList rest)).isEmpty
      | none => false
    | _ => false
  let h1Issues :=
    if h1Ok then [] else ["first heading must be `# " ++ essenceH1Prefix ++ "<title>`"]
  let multiH1 :=
    if (outline.filter (·.1 == 1)).length > 1 then ["multiple H1 headings"] else []
  let sections := (outline.filter (·.1 == 2)).map (·.2)
  let missing := (headings.filter (fun h => !sections.contains h)).map
    fun h => "missing required section: ## " ++ h
  let unknown := ((dedup sections).filter (fun h => !headings.contains h)).map
    fun h => "unknown section: ## " ++ h
  let duplicate := (headings.filter
      (fun h => (sections.filter (· == h)).length > 1)).map
    fun h => "duplicate section: ## " ++ h
  -- 順序は「現に在る正準節どうしの相対順」で見る(欠落・集合外は上で個別に
  -- 報告済みなので、ここで二重に鳴らさない)
  let present := dedup (sections.filter headings.contains)
  let expected := headings.filter present.contains
  let render (l : List String) : String :=
    String.intercalate ", " (l.map ("## " ++ ·))
  let outOfOrder :=
    if present == expected then []
    else ["sections out of order: expected " ++ render expected
      ++ "; found " ++ render present]
  h1Issues ++ multiH1 ++ missing ++ unknown ++ duplicate ++ outOfOrder

/-! ## essences/ 資産言及(META.md §2.1.5)

`PROJECT_ROOT/essences/` の各資産は ESSENCE.md 本文で言及されなければ
ならず、実体のない言及も許されない(双方向整合)。言及は directive と同じ
安全境界(`semanticLines` — fenced code block / HTML comment の外)で判定する。
資産は `essences/` からの相対パスで識別し、最大 `maxAssetDepth` 階層まで
入れ子にできる(§2.1.5)。 -/

/-- essences/ パスセグメントの許容文字(ASCII 英数と `.` `_` `-`)。言及トークンの
抽出文字クラス(これに `/` を加えたもの)と同一 — この一致が双方向整合検査
(orphan/dangling)を決定的にする。 -/
def isAssetNameChar (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')
    || c == '.' || c == '_' || c == '-'

/-- 言及トークンの構成文字: セグメント文字 + 区切り `/`。 -/
def isAssetPathChar (c : Char) : Bool := isAssetNameChar c || c == '/'

/-- essences/ 配下で許される最大階層数(`essences/<a>/<b>/<c>` = 3、§2.1.5)。 -/
def maxAssetDepth : Nat := 3

/-- essences/ パスセグメントの形状: 非空・全文字 `isAssetNameChar`・先頭 `.` 禁止
(dotfile は IO シェルが無視するため到達しないが、形状としても拒否)・
末尾 `.` 禁止(言及トークンの文末句点剥ぎと衝突するため)。 -/
def validAssetName (name : String) : Bool :=
  !name.isEmpty && name.toList.all isAssetNameChar
    && !name.startsWith "." && !name.endsWith "."

/-- `essences/` からの相対パスのセグメント列(`/` 分割)。 -/
def assetPathSegments (path : String) : List String := path.splitOn "/"

/-- essences/ 相対パスの形状(§2.1.5): 1..`maxAssetDepth` セグメントで、
各セグメントが `validAssetName`。空パス・空セグメント(`a//b`・先頭/末尾 `/`)・
深すぎるパスはすべて不成立。 -/
def validAssetPath (path : String) : Bool :=
  let segs := assetPathSegments path
  !segs.isEmpty && segs.length ≤ maxAssetDepth && segs.all validAssetName

/-- 相対パスの真の祖先ディレクトリ列(`a/b/c` → `["a", "a/b"]`)。orphan 判定で
「祖先ディレクトリの言及は配下の資産を覆う」を機械化する。 -/
def assetPathAncestors (path : String) : List String :=
  let segs := assetPathSegments path
  (List.range (segs.length - 1)).map fun i =>
    String.intercalate "/" (segs.take (i + 1))

/-- 1 マッチ試行の後続走査。`prev?` は直前に消費した文字(境界判定用):
`essences/` の直前が path 構成文字(`isAssetPathChar`)なら別パス
(`src/essences/…` 等)であり言及と数えない。トークンは `essences/` 直後の
`isAssetPathChar` 極大 run から末尾の `.` 連(文末句点)と `/` 連
(`essences/input/` のようなディレクトリ言及)を剥いだもの。 -/
private def assetMentionScan : Nat → Option Char → List Char → List String
  | 0, _, _ => []
  | _ + 1, _, [] => []
  | fuel + 1, prev?, cs@(c :: rest) =>
    let boundary := match prev? with
      | none => true
      | some p => !isAssetPathChar p
    match (if boundary then dropLit? cs "essences/".toList else none) with
    | some after =>
      let run := after.takeWhile isAssetPathChar
      let name := (run.reverse.dropWhile (fun c => c == '.' || c == '/')).reverse
      let remaining := after.drop run.length
      let lastConsumed := (run.getLast?).getD '/'
      if name.isEmpty then assetMentionScan fuel (some lastConsumed) remaining
      else String.ofList name :: assetMentionScan fuel (some lastConsumed) remaining
    | none => assetMentionScan fuel (some c) rest

/-- ESSENCE.md 本文(semantic 行)に現れる `essences/<path>` 言及トークン列
(先頭出現順・重複なし)。トークンは `essences/` からの相対パスであり、
ファイル(`ui.xlsx`)にもディレクトリ(`input`)にもなり得る。HTML comment /
code fence 内の綴りは言及ではない(directive parser と同じ安全境界)。 -/
def essenceAssetMentions (text : String) : List String :=
  let cs := (String.intercalate "\n" (semanticLines text)).toList
  dedup (assetMentionScan (cs.length + 1) none cs)

/-! ## トークン重なり判定(state.py `_match_tokens` / `_texts_relate`) -/

/-- ASCII トークンの文字クラス(英数字と `_` `.` `/` `-`)。 -/
def isAsciiTokenChar (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')
    || c == '_' || c == '.' || c == '/' || c == '-'

/-- `[぀-ヿ㐀-䶿一-鿿豈-﫿]`(かな U+3040–30FF・CJK 拡張 A U+3400–4DBF・
CJK 統合漢字 U+4E00–9FFF・互換漢字 U+F900–FAFF)。 -/
def isCjkChar (c : Char) : Bool :=
  (0x3040 ≤ c.val && c.val ≤ 0x30FF) || (0x3400 ≤ c.val && c.val ≤ 0x4DBF)
    || (0x4E00 ≤ c.val && c.val ≤ 0x9FFF) || (0xF900 ≤ c.val && c.val ≤ 0xFAFF)

/-- `_ASCII_TOKEN_RE`(`{4,}` + finditer = 長さ 4 以上の極大 run)の小文字化
集合。順序は先頭出現順(集合演算にのみ使う)。 -/
def asciiTokens (s : String) : List String :=
  dedup (((runsOf isAsciiTokenChar s).filter (·.length ≥ 4)).map
    fun r => lowerStr (String.ofList r))

private def windows3 : List Char → List String
  | a :: b :: c :: rest => String.ofList [a, b, c] :: windows3 (b :: c :: rest)
  | _ => []

/-- `_CJK_RUN_RE`(長さ 3 以上の極大 CJK run)の全 3-gram 集合。 -/
def cjkTrigrams (s : String) : List String :=
  dedup ((((runsOf isCjkChar s).filter (·.length ≥ 3)).map windows3).flatten)

/-- `_texts_relate(cond, candidate)` 等価(§20.2-6 の「この証拠はこの条件を
語っている」heuristic): 空白正規化 + 小文字化の上で、相互包含/ASCII トークンの
prefix 許容共有(`test` は `tests` に合う)/CJK トライグラム 2 個以上の共有。 -/
def textsRelate (cond candidate : String) : Bool :=
  let condN := lowerStr (normalizeWs cond)
  let candN := lowerStr (normalizeWs candidate)
  if condN.isEmpty || candN.isEmpty then false
  else if containsSub candN condN || containsSub condN candN then true
  else
    let condA := asciiTokens condN
    let candA := asciiTokens candN
    if condA.any (fun a => candA.any fun b => a.startsWith b || b.startsWith a) then
      true
    else
      ((cjkTrigrams condN).filter (cjkTrigrams candN).contains).length ≥ 2

/-! ## recipe ポインタ走査(state.py `RECIPE_POINTER_RE`、META.md §29) -/

/-- `[a-z0-9-]`(ポインタ名の 2 文字目以降)。 -/
def isNameChar (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || c == '-'

/-- `\s*$`(MULTILINE)— 空白を進めながら最初の行末(`\n` 直前または入力
末尾)で止まり、残りを返す。greedy + バックトラックとは停止位置が run 内で
ずれ得るが、間は空白のみで次マッチの `^\s*` が吸収するため捕捉列は一致する
(ファザーで検証)。 -/
private def eolAfterWs : List Char → Option (List Char)
  | [] => some []
  | c :: cs =>
    if c == '\n' then some (c :: cs)
    else if isPySpace c then eolAfterWs cs
    else none

/-- 行頭位置からの 1 マッチ試行。`\s*` は `\n` を跨げる(MULTILINE でも `\s` の
意味は変わらない — `"recipe:\na@1"` は Python でもマッチする、実測)。成功時は
`(name, major, 残り)`。 -/
private def tryPointerMatch (cs : List Char) : Option (String × Nat × List Char) := do
  -- 接頭辞クラスは `deps:` / `profile:` と同じ `[ \t>*-]*`(§2.1.1 の 3 directive
  -- 共通文法)。クラスは `r` を含まないため貪欲 dropWhile が唯一の分割。
  let rest ← dropLit?
    (cs.dropWhile fun c => isPySpace c || c == '>' || c == '*' || c == '-')
    "recipe:".toList
  let rest := rest.dropWhile isPySpace
  match rest with
  | c :: _ =>
    if 'a' ≤ c && c ≤ 'z' then
      let name := rest.takeWhile isNameChar
      match rest.drop name.length with
      | '@' :: ds =>
        let digits := ds.takeWhile (·.isDigit)
        if digits.isEmpty then none
        else do
          let remaining ← eolAfterWs (ds.drop digits.length)
          pure (String.ofList name, digitsToNat digits, remaining)
      | _ => none
    else none
  | [] => none

/-- finditer 等価の左→右・非重複走査。マッチ開始は `^` 位置(先頭または `\n`
直後)のみ。fuel は 1 歩ごとに 1 文字以上消費するため入力長 + 1 で全域。 -/
private def scanPointersAux : Nat → Bool → List Char → List (String × Nat)
  | 0, _, _ => []
  | _ + 1, _, [] => []
  | fuel + 1, atStart, c :: rest =>
    match (if atStart then tryPointerMatch (c :: rest) else none) with
    | some (name, major, remaining) =>
      (name, major) :: scanPointersAux fuel false remaining
    | none => scanPointersAux fuel (c == '\n') rest

/-- `RECIPE_POINTER_RE.finditer(text)` 等価: `(name, major)` の出現順リスト。
major の数字は ASCII のみ(頭注の裁定)。 -/
def recipePointers (text : String) : List (String × Nat) :=
  let cs := (String.intercalate "\n" (semanticLines text)).toList
  scanPointersAux (cs.length + 1) true cs

/-! ## コンパイル時検査(期待値はすべて CPython 3.14 実測) -/

#guard mdHeading? "# t" == some (1, "t")
#guard mdHeading? "####### t" == none
#guard mdHeading? "###" == none
#guard mdHeading? "### " == some (3, "")
#guard mdHeading? "## title" == some (2, "title")
#guard mdHeading? "## #x" == some (2, "#x")
#guard mdHeading? " # x" == none
#guard itemBody? "- x" == some "x"
#guard itemBody? "-x" == none
#guard itemBody? "12. z" == some "z"
#guard itemBody? "3) w" == some "w"
#guard itemBody? "1.x" == none
#guard itemBody? "12.5 x" == none
#guard itemBody? "- " == none
#guard itemBody? "+ b" == some "b"
#guard itemBody? "  * y " == some "y"
#guard itemBody? "1)  a  b " == some "a  b"

-- sectionItems(見出し・フェンス・コメント・散文 fallback の統合挙動)。
-- 軸は fixture 駆動で検査する — **製品の実見出し集合の凍結は黒箱
-- conformance が担う**(K-7: tests/Harness が契約書の綴りを独立に書き下ろし、
-- 実バイナリの構造検査へ食わせている)。
#guard Domain.fixture.essenceHeadings.contains essenceSuccessHeading
#guard Domain.fixtureRich.essenceHeadings.contains essenceSuccessHeading
#guard essenceSuccessItems
  "# Title\n## 成功条件\n- a1\n1. a2\n\nprose line\n<!-- fill -->\n<!-- multi\nline -->\n```\n- fenced\n```\n### 品質ゲート\n- nested b1\n## Next\n- not collected\n"
  == ["a1", "a2", "prose line", "nested b1"]
#guard essenceSuccessItems "## 成功条件\n- s1\n~~~\n- f\n~~~\n- s2\n# top\n- no"
  == ["s1", "s2"]
#guard essenceWontItems Domain.fixture
    "## 成功条件\n- w1\n##対象外\n- w2\n## 対象外\n- w3"
  == ["w3"]
#guard essenceWontItems Domain.fixture
  "## 対象外\n- v1 -->\n--> close\ntext <!-- c --> tail\n<!-- open\nhidden\nclose --> after\n- v2"
  == ["v1 -->", "text <!-- c --> tail", "v2"]
#guard essenceSuccessItems "## 成功条件\n-x\n12. z\n3) w\n1.x\n12.5 x\n- \n+ b\n1)  a  b "
  == ["-x", "z", "w", "1.x", "12.5 x", "-", "b", "a  b"]
-- コメントがフェンスに先行(semanticLines と同一の安全境界): コメント内の
-- ``` はフェンスを開かず、コメント閉鎖後の項目は収集される
#guard essenceSuccessItems "## 成功条件\n<!-- open\n```\nstill hidden? -->\n- q1\n```\n- q2"
  == ["q1"]
-- 厳密化(§13.1-15): 節を開くのは「レベル 2・タイトル厳密一致」だけ。旧別名・
-- 部分一致・小文字化・見出しレベル違いはすべて不成立(取りこぼしは構造ゲートが
-- 停止させるので silent にならない)
#guard essenceSuccessItems "### 成功条件\n- d1\n## shallower\n- d2" == []
#guard essenceSuccessItems "# 成功条件\n- d1" == []
#guard essenceSuccessItems "## 成功条件 - u1 ## end" == []
#guard essenceSuccessItems "## 本成功条件シリーズ\n- t1" == []
#guard essenceSuccessItems "## SUCCESS Condition\n- s1" == []
#guard essenceSuccessItems "## 成功の定義\n- s1" == []
#guard essenceWontItems Domain.fixture "## Won't\n- v1" == []
#guard essenceWontItems Domain.fixture "## やらないこと\n- v1" == []
-- 特別扱い見出し(`essenceTrustHeading?`)は軸の値が発火を決める —
-- 機構は全ドメインに在り、持たないドメインでは空を返す
#guard essenceTrustItems Domain.fixture "## 信頼面\n- t1" == []
#guard essenceTrustItems Domain.fixtureRich "## 信頼面\n- t1\n## 対象外\n- w"
  == ["t1"]

-- essenceHeadingOutline / essenceStructureIssues(§2.1.1'・§13.1-15)
private def headingDoc (h1 : String) (sections : List String) : String :=
  "# " ++ h1 ++ "\n"
    ++ String.intercalate "" (sections.map fun s => "## " ++ s ++ "\n- x\n")
-- 以下は軸(fixture の正準列)に対する検査。製品の実列の凍結は黒箱側(K-7)。
private def fh : List String := Domain.fixture.essenceHeadings
private def structIssues (text : String) : List String :=
  essenceStructureIssues Domain.fixture text
#guard essenceHeadingOutline (headingDoc "ESSENCE — デモ" ["モチベーション"])
  == [(1, "ESSENCE — デモ"), (2, "モチベーション")]
-- 適合(fixture 軸の綴り・この順序)
#guard structIssues (headingDoc "ESSENCE — デモ" fh) == []
-- H3 以下は各節の内側で自由
#guard structIssues
    (headingDoc "ESSENCE — デモ" fh ++ "### 小見出し\n#### さらに\n") == []
-- 欠落 / 集合外 / 重複 / 順序違反
#guard structIssues
    (headingDoc "ESSENCE — デモ" (fh.filter (· != "対象外")))
  == ["missing required section: ## 対象外"]
#guard structIssues
    (headingDoc "ESSENCE — デモ" (fh ++ ["Foo"]))
  == ["unknown section: ## Foo"]
#guard structIssues
    (headingDoc "ESSENCE — デモ" (fh ++ ["対象外"]))
  == ["duplicate section: ## 対象外"]
#guard match structIssues (headingDoc "ESSENCE — デモ"
    (["思想", "モチベーション"] ++ fh.drop 2)) with
  | [msg] => msg.startsWith "sections out of order: expected ## モチベーション, ## 思想"
  | _ => false
-- H1 の形式(接頭辞・非空の題名・先頭・単一)
#guard structIssues (headingDoc "デモ" fh)
  == ["first heading must be `# ESSENCE — <title>`"]
#guard structIssues (headingDoc "ESSENCE —" fh)
  == ["first heading must be `# ESSENCE — <title>`"]
#guard structIssues
    ("## モチベーション\n" ++ headingDoc "ESSENCE — デモ" fh)
  == ["first heading must be `# ESSENCE — <title>`",
      "duplicate section: ## モチベーション"]
#guard structIssues
    (headingDoc "ESSENCE — デモ" fh ++ "# ESSENCE — 別題\n")
  == ["multiple H1 headings"]
#guard structIssues ""
  == "first heading must be `# ESSENCE — <title>`"
    :: fh.map (fun h => "missing required section: ## " ++ h)
-- HTML comment / code fence の内側の見出しは構造として数えない
#guard structIssues (headingDoc "ESSENCE — デモ" fh
    ++ "<!-- ## Foo -->\n```\n## Bar\n# ESSENCE — 別題\n```\n") == []
-- 旧別名は不受理 — 欠落 + 集合外の 2 件として現れる(移行圧は fail-closed)
#guard structIssues (headingDoc "ESSENCE — デモ"
    ((fh.filter (· != "対象外")) ++ ["Won't"]))
  == ["missing required section: ## 対象外", "unknown section: ## Won't"]
#guard structIssues (headingDoc "ESSENCE — デモ"
    ((fh.filter (· != "対象外")) ++ ["やらないこと"]))
  == ["missing required section: ## 対象外", "unknown section: ## やらないこと"]

-- semanticLines: 説明コメント・コード例は directive の入力にならない
#guard semanticLines
  "before\n<!-- deps: npm:commented\nrecipe: hidden@1 -->\nafter\n```\ndeps: npm:fenced\n```\ndeps: npm:live"
  == ["before", "after", "deps: npm:live"]
#guard semanticLines "<!-- recipe: one-line@1 -->\nrecipe: live@2"
  == ["recipe: live@2"]
#guard semanticLines
  "explanation <!--\ndeps: npm:hidden\n--> deps: npm:live\ntext <!-- hidden --> tail"
  == ["explanation ", " deps: npm:live", "text  tail"]

-- asciiTokens / cjkTrigrams
#guard asciiTokens "run pytest-xdist ./a/b.py 日本語のテキスト abc"
  == ["pytest-xdist", "./a/b.py"]
#guard cjkTrigrams "日本語のテキスト カタカナ abc"
  == ["日本語", "本語の", "語のテ", "のテキ", "テキス", "キスト", "カタカ", "タカナ"]
#guard cjkTrigrams "漢字列" == ["漢字列"]
#guard asciiTokens "abc ABC" == []

-- textsRelate
#guard textsRelate "test" "tests pass" == true
#guard textsRelate "abc" "abcd" == true
#guard textsRelate "" "x" == false
#guard textsRelate "  " "x" == false
#guard textsRelate "ログイン機能を実装" "ログイン機能のテスト" == true
#guard textsRelate "ログ" "ログ" == true
#guard textsRelate "ふが ほげ" "ほげふが" == false
#guard textsRelate "ビルドが通る" "コンパイル成功" == false
#guard textsRelate "pytest 全緑" "run pytest -q OK" == true
#guard textsRelate "Tests" "TESTS" == true
#guard textsRelate "Épreuve" "épreuve du code" == true
#guard textsRelate "ПРОВЕРКА кода" "проверка" == true
#guard textsRelate "a b  c" "a\tb c" == true
#guard textsRelate "走行距離計" "距離計テスト" == false
#guard textsRelate "勾配降下法だ" "の勾配降下いく" == true

-- essenceAssetMentions / validAssetName / validAssetPath
#guard essenceAssetMentions "see essences/logo.png here" == ["logo.png"]
#guard essenceAssetMentions "![img](essences/arch.png)" == ["arch.png"]
#guard essenceAssetMentions "essences/brand-guide.pdf に従う" == ["brand-guide.pdf"]
#guard essenceAssetMentions "essences/a.png と essences/a.png" == ["a.png"]
#guard essenceAssetMentions "src/essences/x.png" == []          -- 別パスは言及でない
#guard essenceAssetMentions "myessences/x.png" == []
#guard essenceAssetMentions "essences/foo.png." == ["foo.png"]  -- 文末句点を剥ぐ
#guard essenceAssetMentions "essences/ のみ" == []              -- 名前なし
#guard essenceAssetMentions "essences/a.png、essences/b.txt" == ["a.png", "b.txt"]
#guard essenceAssetMentions "<!-- essences/hidden.png -->\nessences/live.png"
  == ["live.png"]
#guard essenceAssetMentions "```\nessences/fenced.png\n```\nessences/live.png"
  == ["live.png"]
#guard essenceAssetMentions "『essences/quoted.pdf』を参照" == ["quoted.pdf"]
#guard essenceAssetMentions "essences/日本語.png" == []          -- 非 ASCII 名は不成立
#guard validAssetName "brand-guide.pdf" == true
#guard validAssetName "a_b-c.1.png" == true
#guard validAssetName "" == false
#guard validAssetName ".DS_Store" == false
#guard validAssetName "foo." == false
#guard validAssetName "日本語.png" == false
#guard validAssetName "a b.png" == false
#guard validAssetName "sub/x.png" == false
-- 入れ子言及(§2.1.5、最大 3 階層)
#guard essenceAssetMentions "see essences/input/main.csv" == ["input/main.csv"]
#guard essenceAssetMentions "essences/input/ の生データ" == ["input"]
#guard essenceAssetMentions "essences/a/b/c.png と essences/a/b/"
  == ["a/b/c.png", "a/b"]
#guard essenceAssetMentions "essences/out/ref.xlsx。" == ["out/ref.xlsx"]
#guard essenceAssetMentions "src/essences/a/b.png" == []
#guard validAssetPath "ui.xlsx" == true
#guard validAssetPath "input/main.csv" == true
#guard validAssetPath "a/b/c.png" == true
#guard validAssetPath "a/b/c/d.png" == false   -- 4 階層は不成立
#guard validAssetPath "a//b.png" == false      -- 空セグメント
#guard validAssetPath "input/" == false
#guard validAssetPath "/input" == false
#guard validAssetPath "" == false
#guard validAssetPath "a/.hidden/b.png" == false
#guard assetPathAncestors "a/b/c.png" == ["a", "a/b"]
#guard assetPathAncestors "ui.xlsx" == []

-- recipePointers
#guard recipePointers "recipe: a@1" == [("a", 1)]
#guard recipePointers "recipe:\na@1" == [("a", 1)]
#guard recipePointers "  recipe: asl@2  " == [("asl", 2)]
#guard recipePointers "recipe: a@1\nrecipe: b@2" == [("a", 1), ("b", 2)]
#guard recipePointers "recipe: a@1 \n\nrecipe: b@2" == [("a", 1), ("b", 2)]
#guard recipePointers "x recipe: a@1" == []
-- リスト項目の接頭辞は deps:/profile: と同じクラスで剥がれる(§2.1.1)
#guard recipePointers "- recipe: a@1" == [("a", 1)]
#guard recipePointers "> recipe: a@1" == [("a", 1)]
#guard recipePointers "recipe: a@1 x" == []
#guard recipePointers "recipe: A@1" == []
#guard recipePointers "recipe: a@01" == [("a", 1)]
#guard recipePointers "recipe: a@1\r" == [("a", 1)]
#guard recipePointers "recipe: a@1\rrecipe: b@2" == []
#guard recipePointers "\n\n  recipe: c@3" == [("c", 3)]
#guard recipePointers "recipe:d@4" == [("d", 4)]
#guard recipePointers "recipe: e@" == []
#guard recipePointers "recipe: -f@1" == []
#guard recipePointers "recipe: a@1 recipe: b@2" == []
#guard recipePointers "recipe: a@1 recipe: b@2" == []
#guard recipePointers "<!-- recipe: hidden@1 -->\nrecipe: live@2" == [("live", 2)]
#guard recipePointers "```\nrecipe: hidden@1\n```\nrecipe: live@2" == [("live", 2)]
#guard recipePointers
  "explanation <!--\nrecipe: hidden@1\n-->\nrecipe: live@2" == [("live", 2)]

end Looper.Core.Essence
