<!-- 生成物。`bash ci/looper-meta.sh --write` が `meta/base.md`(Looper が配る共通章)
     と `meta/domain.md`(本製品所有のドメイン章)から合成する。直接編集しない。 -->


# Atlas Builder: Human-Essence-Driven Agentic Coding Framework 設計書

## 0. Executive Summary

Atlas Builder は、任意のソフトウェア開発に対して Claude Code 専用の自律的エージェンティックコーディングループを継続実行するためのフレームワークである。

キャッチフレーズは次である。

```text
人間が書き込むのは1ファイルのみである。
```

ここでいう「1ファイル」とは、人間の意思決定と要求の正本が 1 つの人間入力ファイルに一本化される、という意味である。本仕様ではそのファイルを `ESSENCE.md` と呼ぶ。初期 trust、初期 commit、停止後の `just resume --note`、必要時の `CLAUDE.md` レビューなどの運用行為は残る。`resume` note やレビュー行為は介入記録・監査行為であり、Atlas Builder が投影するプロジェクト要求の正本ではない。Atlas Builder が自律的に読み取り、投影し、実装し、検証し、停止判断の根拠にする人間意図の正本は、この 1 ファイルだけである。

この約束は**束縛済みプロジェクトを運用する人間の書き込み面**について文字どおりである: **人間が書き込む対象ファイルは `ESSENCE.md` の 1 つだけである。** 意思決定が触れる層は 2 つある — **地形**(`ESSENCE.md`: **何を**作るか)と、**投影の調律**(`CONTROL_ROOT/CLAUDE.md` / `CONTROL_ROOT/.claude/rules/**`: **どう読ませ、どう動かすか**)— が、後者は対象運用中の書き込み面ではない。調律は Atlas Builder の配布原本で保守し、更新版を再配布する。束縛済み control plane を動かす Agent は、自分の enforcement を対話 supervise を含めて変更できない(§11.3、I-028)。フレームワーク開発は repo root の maintainer plane で行うため、この原則は Atlas Builder 自身のソース保守まで「人間は編集禁止」と言うものではない。投影の読み違いの修正先が調律側なら、対象の Essence を防御的詳細で太らせず、フレームワーク側の issue/変更として切り出す(§2.1.3)。(なお、ここでの調律層は Over-Project Agent 自身を統べる CONTROL_ROOT 側の設定を指す。対象がエージェントを内包する場合の `PROJECT_ROOT/CLAUDE.md` / `.claude/**` はこれとは別物であり、対象プロダクトの内容物であって Atlas Builder の調律層ではない — §5.0, §6.2。)

Atlas Builder は `ESSENCE.md` を直接実装手順として扱わない。人間の本質的意図を、検証可能な Spec、実行可能な Todo、証拠付きの実装、検証ログへ段階的に投影する。投影された成果物は地図であり、地形そのものではない。したがって Atlas Builder は、歪みを隠さず、出典を追跡し、実装の完了を evidence でのみ認める。

v1.0 の仕様版では、この中核価値を維持したまま、長時間の自律ループ、停止ゲートの可視化、resume による人間介入の記録、single-flight、checkpoint commit、high-risk 変更の追跡、Claude Code trust/permissions/hooks による機械的境界を標準化する。

標準的な正本の流れは次である。

```text
ESSENCE.md
  -> spec.json
  -> todo.json
  -> implementation files
  -> evidence / validation / reflection
```

正本は `ESSENCE.md` と `.atlas-builder/state/*.json` / `.jsonl` に置かれる。人間向けの読みやすい状態表示は `just status` とループの終了メッセージがこの正本から都度計算する(§15)— 編集・信頼の対象になる生成ファイルは存在しない。

Atlas Builder が目指す運用状態は、人間が `ESSENCE.md` に本質を記述し、Claude Code がそれを継続的に投影・実装・検証し、判断が人間に戻るべき瞬間だけを明示的な停止ゲートとして可視化することである。

---

## 1. Name and Concept

### 1.1 Name

本フレームワーク名は **Atlas Builder** とする。

### 1.2 Meaning

**Atlas Builder** は 2 語の合成である。

第一に、**地図帳(atlas)**である。このフレームワークにおいて、人間の `ESSENCE.md` は「地形」であり、`spec.json`, `todo.json`, 実装、テスト、検証ログは「地図」である。個々の投影は地形の一面を写し取った 1 枚のチャートであり、Spec / Todo / 実装 / 検証がそろって初めて 1 冊の地図帳になる。地図帳は 1 枚の地図より正直である — どの要求をどのチャートが覆い(投影済み)、どの完了がどの evidence に裏打ちされ(§22)、どの領域が白地図のまま(未着手・非対応)かが、綴じ目から読み取れる。

第二に、**編み上げる者(builder)**である。地図帳は観察の産物ではなく作業の産物であり、本フレームワークの職務は地形を読み、チャートを描き、実装として建てることである。同じ地形観を共有する姉妹フレームワーク Atlas Prover が**証明**を綴じるのに対し、Atlas Builder は**開発**を綴じる(§1.3)。

地図は地形そのものではない。抽象化・投影・変形を含む。したがって Atlas Builder は、次の原則を持つ。

```text
Map the Essence.
Expose the distortion.
Trace every projection.
Never overwrite the terrain.
```

日本語では次のように定義する。

> Atlas Builder は、人間が書き込む唯一の意思決定正本(`ESSENCE.md`)を、検証可能な Spec、実行可能な Todo、証拠付きの実装、停止可能な自律ループへ投影するための Claude Code 専用エージェンティックコーディングフレームワークである。

### 1.3 Lineage

Atlas Builder v1.0 は、前身 **Mercator v2.0**(地図投影法 Mercator に名を借りた同一設計のフレームワーク)の**改称版**である。制御プレーン、状態モデル、停止/再開モデル、検証モデル、safety invariants、Lean 実行層はそのまま引き継ぎ、名前と版数だけを刷新した。版数は Atlas 系として **1.0.0** から始め、Mercator の版体系(2.x)は継承しない。

同じ地形観を共有する姉妹フレームワークとして、**ソフトウェア仕様証明**を主語とする **Atlas Prover** がある(こちらも Mercator を元実装とする独立の分岐であり、対象コードを既定 read-only として証明層だけを書込み面にする)。両者は独立したリポジトリ・独立した設計正本を持ち、**製品識別子の空間は分離している** — 本フレームワークの制御ルートは `.atlas-builder/`、配布バイナリは `bin/atlas-builder`、環境変数は `ATLAS_BUILDER_*`、commit trailer は `Atlas-Builder-*` であり、Atlas Prover の `.atlas-prover/` 系(`bin/atlas-prover` / `ATLAS_PROVER_*` / `Atlas-Prover-*`)とはどの面でも衝突しない。したがって同一ワークスペースに両者を置いても互いの正本 state を踏まない。**Lean の名前空間だけは意図的に共通である**: 制御プレーンに立って対象を回すOver-Project ループ本体は両者で同一の実装であり、`Looper.*` という 1 つの綴りを共有する(§31.1 R-12)。両者は別パッケージとして別々にビルドされ同一プロセスに同居しないので、綴りの一致は衝突を生まない — 生むのは、安全境界の修正が一度で両方に効くという単一正本性である。Atlas Builder 固有のドメインパックは `AtlasBuilder.*` に残る。設計正本は分かれたままであり、本 META.md が Atlas Builder の唯一の設計正本である。

---

## 2. Core Promise

### 2.1 Human-owned Canon

Atlas Builder の人間向け約束は次である。

```text
Humans write one file. Atlas Builder manages the projections.
```

人間は `PROJECT_ROOT/ESSENCE.md` に次を書く。

1. プロジェクトが存在する理由(モチベーション)
2. 貫く思想と衝突時の判断基準(思想)
3. 技術・運用・組織上の前提と背景(前提事項)
4. 成功の観測条件(成功条件)
5. 絶対に守るべき必須対応事項
6. 交渉可能な任意対応事項
7. 明確な非対応事項
8. 遂行してほしい順序(遂行順序)
9. ドメイン用語の定義(用語)

Atlas Builder はそこから Spec / Todo / 実装 / 検証 / Reflection / Recommendation を作る。人間が生成物を読むことはあるが、生成物を手で正本化しない。生成物に違和感があれば、原則として `ESSENCE.md` を直し、`just resume` で「何を確認・修正・決定したか」を記録して再投影させる。

#### 2.1.1 Canonical `ESSENCE.md` Heading Set (Enforced, §13.1-15)

`ESSENCE.md` は全投影の源泉であり、その Heading2 は**閉じた集合として強制される**。集合そのものは**ドメイン軸**であり(`Domain.essenceHeadings`、§31.1 R-13)、Atlas Builder のドメインパックは次の 9 節を宣言する(`templates/project/` が seed する)。

```markdown
# ESSENCE — PROJECT_TITLE
## モチベーション   <!-- FILL: このプロジェクトが存在する理由 -->
## 思想             <!-- FILL: 貫く哲学と衝突時の判断基準 -->
## 前提事項         <!-- FILL: 技術・運用・組織上の制約、背景・現状 -->
## 成功条件         <!-- FILL: 成功をどう観測するか(検証可能な形で) -->
## 必須対応事項     <!-- FILL: 絶対に守るべき要求 -->
## 任意対応事項     <!-- FILL: 交渉可能な要求 -->
## 非対応事項       <!-- FILL: 明確にやらないこと -->
## 遂行順序         <!-- FILL: 作業をどの順で進めてほしいか -->
## 用語             <!-- FILL: ドメイン用語の定義(無ければ「なし」) -->
```

**H1(`# ESSENCE — <題名>`)+ この 9 見出しの H2 は、綴り・順序ともに固定の閉じた集合として強制される。** 見出しタイトルは正準綴りと完全一致でなければならず、欠落・重複・順序違反・集合外の H2 の出現・複数の H1 はすべて `essence_structure` として validate error(§20.1)かつ停止ゲート(§13.1-15)になる — 人間が構造を正して `just resume` するまでループは 1 cycle も開始しない。H3 以下の小見出しは各節の内部で完全に自由であり検査対象外である。`templates/project/ESSENCE.md` が実際に seed するのは同じ構造に書き方ガイドを添えた展開版であり(FILL マーカーは 9 節すべての冒頭部に置く)、テンプレの見出しそのものが既に正準集合であるため、人間はこの見出しを削除・改名・並べ替えできない。判定に効くのはファイル内に未消化の `<!-- FILL:` マーカーが残っているかだけ(位置には依存しない)なので、§13.1-8 の placeholder 判定は構造検査より先に働き、placeholder の間は構造検査を保留する(空ファイルへ構造エラーを重ねてもノイズになるだけであるため)。

`deps:` / `recipe:` / `profile:` は**通常の本文行として実在するときだけ**機械可読 directive になる。HTML comment 内と fenced code block 内は説明・例示であって発効しない。この directive 行は見出しとは独立に**位置非依存**であり、コメント・フェンス外の 1 行プレーンテキストであれば `ESSENCE.md` のどの節にあっても等しく有効である — 専用の隔離節は存在しない。推奨の置き場は「前提事項」節であり、テンプレの例は comment 内に置くため、人間が必要な行だけを comment の外へコピーするまで権限や recipe 採用や profile 緩和を広げない。この active-line 規則は依存 gate、recipe pointer、実行 profile、Essence→Spec trace のすべてで共有する(§11.2、§11.5、§20.2、§29.1)。

**Atlas Builder の優先度体系は、MoSCoW から Could を意図的に除いた Must / Should / Won't である。** テンプレの `必須対応事項`(Must 相当)/ `任意対応事項`(Should 相当)は、投影された Todo の priority 2 段(must / should、§9.1)にそのまま対応し、`非対応事項`(Won't 相当)は要求外の宣言であり、Todo にはならず §2.1.2 の機械化 triage を受ける。Could を持たないのは、それが人間の書くどの場所にも対応せず、「Essence に根拠を持たない要求を作らない」(§2.2-1)への裏口になるためである(詳細は §19.3)。非対応事項には**自由記述の慣習**として「延期 Won't」— 理想には含まれるが現段階では実施しないと人間が決めた項目 — を置いてよい: 「〜(現段階では実施しない。<観測可能なトリガー>が観測されたら update-essence で 必須対応事項 / 任意対応事項 への昇格を検討)」の形で昇格トリガーを添える。これは将来の update-essence(§2.1.4)への申し送りであって機械可読区分ではない — 投影上はどちらの非対応事項も等しく Todo にならず、ループがトリガーを評価して自動昇格させることはない(Could 排除の根拠はここでも保たれる: 昇格は常に人間の Essence 改稿を通る)。

**`成功条件` は受け入れ基準(acceptance check)として書く。** `成功条件` は散文の願望ではなく、**検証可能な受け入れ基準**として書く — 「何を実行(観測)し、何が観測されたら成功か」が判定可能な形が望ましい。Atlas Builder は各成功条件を Spec へ acceptance check として trace 付きで引き継ぎ、must フェーズ完了の evidence に、その check を直接検証した結果を含めることを投影規律とする(§22)。見出し自体は §13.1-15 で強制されるが、節の中身の書き方までは機械強制されない — 判定不能な成功条件は「成功条件 ↔ evidence」対応の可視化(§20.2-6、§22)で未対応(unmapped)として現れ、must 完了ゲート(§13.1-13)の人間レビューに委ねられる。

**placeholder 判定の穴を塞ぐ(番人)。** §13.1-8 の placeholder 判定は元来「空・空白のみ」しか placeholder と見なさない。テンプレを seed すると「見出しだけで中身ゼロ」の骨組みが生まれ、これが誤って「充填済み」と判定されて空の Essence から投影が始まりうる。そこで各セクションに**未記入マーカー** `<!-- FILL: ... -->` を置き、`essence_placeholder` の判定を「**空、空白のみ、または未消化の `<!-- FILL:` マーカーが 1 つでも残存**」へ拡張する(§13.1-8)。人間が全 FILL マーカーを実内容へ置き換えるまで、ループは 1 cycle も開始しない。

#### 2.1.2 `won't` Is Triaged and Never Silently Dropped

自然言語の `won't` すべてを permission deny へ安全に自動変換できる、とは主張しない。誤変換された deny は正当な作業を塞ぎ、bound Agent が CONTROL_ROOT の hook/settings を自己編集して deny を足す設計は §11.3 の enforcement immutability に反する。**原則は「強制できないものを強制済みと偽らず、黙って捨てない」**である。投影時、Atlas Builder は各 won't を次へ triage する。

1. **既存の決定論的な柵へ写像できる won't。** 「依存を増やさない」は既存の dependency-manifest/install gate(§11.2)へ写像する。このように配布済み enforcement が意味を正確に表す場合だけ、その柵を機械強制として数える。bound control plane を書き換えない。
2. **対象自身の検査で機械化できる won't。** 禁止 import/path/API 等は、対象プロジェクトの test/lint/architecture check として実装し、command evidence に含める。対象の agent-runtime/CI 設定を触る必要があれば通常どおり target High-Risk(§12)として Recommendation → `just supervise` を通す。
3. **安全な既存写像が無い won't。** Spec の**常設制約**に反映し、projection/validation warning と must フェーズ境界の人間レビューへ残す。将来の一般 enforcement が必要なら source repository の maintainer task として切り出す。bound session の High-risk Recommendation を CONTROL_ROOT 自己変更の入口にはしない。
4. **validate の軽い違反フラグ。** 現実装は「依存を増やさない」と dependency manifest の変更、および won't 中で引用された path と worktree 変更の衝突を warning する(§20.2)。これはヒューリスティックな可視化であり deny ではない。

#### 2.1.3 Keep `ESSENCE.md` Essential (Anti-bloat Norm)

**こだわりの how は本質である。** 本質かどうかの判定基準は「why / what か how か」という抽象レイヤーではなく、**それが人間の本当に望むことか**である。実装方法へのこだわり — 技術選定、設計方針、書き方の流儀など — は、こだわりである限り人間の意図そのものであり、`ESSENCE.md` へどんどん書いてよい。こだわりが多いことは Essence の汚れではなく、本質的に指定したいことがそれだけ多いという地形の実態である。書く場所は、こだわりの強さに応じて 必須対応事項(交渉不可)/ 任意対応事項(交渉可能な好み)/ 前提事項(作り方への条件)へ置き分ける(§2.1.1)。地形/地図メタファ(§2)はこれで毀損しない: 地形は「人間の意図の全体」であり、人間がこだわって書いた how はその瞬間に地形の一部である。地図(Spec / Todo / 実装)は、地形が what しか言わなければ how を設計で埋め、地形が how まで言えばそれに忠実に投影する。

その上で、投影が誤っても直すのは `ESSENCE.md` のみ(純度死守、§0・I-004)という原則の副作用に備え、次の 2 つを匂いとする規範を残す。

> 1. **防御的加筆** — 本心ではこだわっていないのに、Agent の読み違いを防ぐため**だけ**に詳細を足したくなったら、それは匂いである。まず投影プロンプトや rules 側を疑う。こだわりでない加筆を続けると、§13.1-10 の attestation 台帳に**本質でない文が本質として記録**され、投影の歪みが地形の内側へ侵食する。
> 2. **手順書化** — こだわりの表現を越えて実装手順の網羅を目指し始め、Spec / Todo の投影に設計の余地が残らないほど `ESSENCE.md` が太ったら、それは匂いである。こだわりのない詳細まで埋め尽くさず、意図の無い部分は投影に委ねる。これは量の節度であって、こだわりのある how を削れという意味では決してない。

読み違いの修正先は、多くの場合 Essence ではなく投影の仕組み(投影プロンプト、rules、Spec の常設制約)である。Essence を防御的詳細で膨らませる前に、そちらを直せないかを問う。Spec の常設制約は現在の投影で直し、フレームワーク共通の prompt/rule 修正は source repository の maintainer task としてレビュー・テストし再配布する。bound Agent が live CONTROL_ROOT を自己変更することはない(§11.3)。人間の対象ファイル書き込み面はあくまで `ESSENCE.md` のみである(§0)。

#### 2.1.4 Essence Interview — 対話起草(human-only)

§2.1 は「人間は 1 ファイルを書く」と約束するが、良い `ESSENCE.md` をゼロから書くのは実は難しい: 観測可能な成功条件、無矛盾な must、won't の柵、anti-bloat(§2.1.1〜§2.1.3)という**書式規律の知識は Atlas Builder 側**にあり、**地形の知識は人間の頭の中**にしかない。この非対称を、書式規律を知る側が質問することで埋める人間専用の対話セッション **Essence interview** を用意する。入口は 2 つある: 新規起草の `new-essence` と、既存の人間確認済み Essence を**変更意図から**対話改稿する `update-essence`(§13.3 の mid-course update の対話版)。

```bash
just new-essence ../{project-title}      # 新規起草 = bash scripts/essence.sh --project ../{project-title} --mode new
just update-essence ../{project-title}   # 既存 Essence の対話改稿(変更意図から始まる)= 同 --mode update
                                         # 束縛後は `just new-essence` / `just update-essence`(対象が焼き込み済み)
```

`essence.sh` は CONTROL_ROOT から対話モードの Claude セッション(slash command `/essence`、実体は `CONTROL_ROOT/.claude/commands/essence.md`)を起動する。new モードのセッションは、テンプレの書式規律と対象リポジトリ(存在すれば)を読んだ上で、まず**理想発掘(枷外し)フェーズ**を走らせる: 人間が最初に語るプロジェクト像は、本人の時間・技術・予算・既存資産による自己検閲で既に縮んでいるのが通例であり、それをそのまま書き起こすと**枷ごと転写した地形**になる。そこで本編の前に、一度に一問 + 具体的な叩き台(strawman)提示 + 回答間の矛盾の深掘りという drill 式テンポで、制約の一時停止(「制約が全部なかったら何が理想か」)・手段の遡行・スケール反転・逆プレモーテム・枷の名指し(検証済みの制約か自己検閲か)といった問いを投げ、人間承認済みの**本質的理想**(モチベーション の骨格・成功条件/必須対応事項 の物差し)と、**理想と今回スコープの差分**(現段階では実施しないと決めた部分 — それぞれ観測可能な昇格トリガー付きの延期 Won't として §2.1.1 の慣習で記録)を確定させる。このフェーズは**短縮可・省略不可**: 最低 1 巡は必ず実施し、以降は人間の明示宣言(「これ以上は不要」)で打ち切れる。続いて人間へ**クリティカルな決定から順に**質問する — 回答の欠如・曖昧さが Blocking 停止(§13.1)に直結する順、すなわち モチベーション(理想の発掘)→ 必須対応事項(交渉不可能の確定・矛盾の即時解消)→ 成功条件(must 成果ごとの観測可能な受け入れ基準)→ 前提事項(技術スタック・実行環境・背景・現状)→ 思想(ありうる衝突の事前裁定・人間に委ねる判断)→ 遂行順序(順序のこだわり。無ければ Atlas Builder の裁量に任せると明記)→ 非対応事項(恒久/延期の区別と延期分のトリガー聴取)→ 任意対応事項 → 用語(対話中に出た用語の定義を確定)→ 実装のこだわり(how の能動的聴取)。最後の「実装のこだわり」は専用節ではなく取りこぼし防止の総ざらいであり、技術選定・設計方針・流儀のこだわりを明示的に尋ね、回答を強度に応じて 必須対応事項 / 任意対応事項 / 前提事項 へ振り分けて載せる(こだわりの how は本質であり歓迎される — §2.1.3。ただし人間がこだわっていない how を釣り出して書かせてはならない)。質問テンポは場面で使い分ける: 発掘と矛盾・枷の深掘りは drill 式(一問ずつ + 叩き台)、事実確認的な聴取(前提事項、技術スタック、how の総ざらい)は 1 テーマ最大 3 問のバッチ。「成功 / 完成」を問う質問は**どちらの層の話か質問文自身で名指しする**。この設計は 2 つの状態を意図的に分けている — 発掘した本質的理想の実現(モチベーション の骨格。延期 非対応事項 を含みうる)と、今回スコープの完了(全 必須対応事項 が 成功条件 を満たす = §19.3 の must 境界)であり、無アンカーの「完成したとき」は両方に読める。モチベーション 系の問いは理想層に、成功条件 系の問いはスコープ層にアンカーし、回答がどちらにも読めるときは記録前にどちらかを確認する。曖昧な回答は検証可能な文面へ言い換えて読み戻し、承認を得てからドラフトに載せる。インタビューの終了は二重の収束条件で判定する: (1) セッション側の残存曖昧さ検査(観測可能な文面か・must 矛盾がないか・重要文に未検証の枷が残っていないか・人間が確認していない暗黙前提を持ち込んでいないか・延期 Won't にトリガーが揃っているか)が空になり、かつ (2) 理解の要約(本質的理想 → 今回スコープ → 必須対応事項 → 非対応事項)を読み戻して人間が「認識が揃った」と明示宣言する。人間はいつでも深掘りを打ち切れるが、その場合セッションは未解消項目を要約に明示して人間の了承を得る(黙って落とさない)。完成した完全準拠ドラフトは handoff dir(`.agent/tmp/essence/ESSENCE.draft.md`)に書かれ、wrapper が**全文**(既存の実 Essence を置換する場合は diff も)を端末に表示し、明示確認(y)を得た場合に**限り** `PROJECT_ROOT/ESSENCE.md` へ原子的に設置する。

モードは 2 つあり、前提は wrapper が起動前に強制する(「実体のある Essence」の判定 — 非 placeholder・非空 — は §13.1-8 と同一): **new**(`just new-essence`)は前段の全節クリティカル順インタビューを行い、実体のある Essence が既に存在すれば **exit 2 で拒否**する — 確定済み正典の改稿は update の仕事であり、ゼロから聞き直すインタビューを既存正典の上に走らせない。**update**(`just update-essence`)は実体のある Essence が無ければ **exit 2 で拒否**し(先に `just new-essence`)、セッションは現行 `ESSENCE.md` の全文を人間の既往発言として読んだ上で、**最初に変更意図を質問**する(何を・なぜ変えたいか)。変更意図の直後に**軽量の枷外し**を 1 巡だけ行う: その変更の背後にある理想は何か・変更は理想への根治か対症療法か(叩き台付きの一問。枷が表面化したら名指しの追撃を一問)、および既存の延期 Won't のうち記録済み昇格トリガーが満たされたと読めるものを列挙して今回昇格するかを確認する — いずれも人間の「このままでよい」で即座に閉じる。以降のインタビューは意図が触れる決定だけに絞り(その中では同じクリティカル順・同じ洗練規則、延期 Won't にはトリガー)、改稿が繰り越し文と矛盾しないか(must 間の矛盾、成功条件の孤立、won't の柵越え)を検査し、意図の外の文は一字一句そのまま繰り越す。ドラフトは常に全文であり、wrapper の diff 表示が変更意図との照合になる。

**I-004 との整合。** セッション自身は `ESSENCE.md` を書けない(hook が Bash の全 spelling を deny し、書き込みツールは handoff 内へ封じ込め)。設置は人間専用 wrapper の、人間の全文確認後の行為である。ドラフトの実質的内容はすべて人間の回答または明示承認に由来し(セッションの規律: 人間が言っていない意図を書かない)、人間は「タイピングする者」から「口述し、全文を確認して署名する者」になるだけで、Essence の著者であることは変わらない。これは §13.6-5 の確認付き resume と同型であり、確認の keystroke が人間の記入行為にあたる。

規則:

1. **人間専用・対話専用。** `essence.sh` は stdin/stdout が端末でなければ拒否する(exit 2)。`atlas-builder hook pre-tool` は resume / loop / once / init / trust / triage と同様に `essence.sh` / `just new-essence` / `just update-essence` をエージェントに deny する(§18.2)。エージェントがインタビューを再帰起動したり、それを踏み台に Essence を著作したりする経路はない。
2. **read-only(I-027)。** 書けるのは handoff 用の `CONTROL_ROOT/.agent/tmp/essence/` のみ(gitignore 済み・checkpoint 対象外)。Edit / NotebookEdit は起動時に無効化され(`--disallowedTools`)、Write は有効のまま hook が handoff 内へ封じ込める(§13.6-3 の triage と同一の write 面、機械証明済み(§31.3 G-T2)— draft の第一の出口。Bash の quoted heredoc は受理される代替形)。対話 permission mode は installed CLI が choices に公開する ask-before-edits 値(`manual`、または `default`)を起動時に選び、どちらも無ければ拒否する(§28.5)。境界を強制するのは hooks なので、wrapper は起動前に Claude Code trust を要求する(未 trust なら拒否)。未束縛の制御プレーンでも動くよう、対象読み取りは `--add-dir` で与え、同時に `--settings` の target-bound layer で対象全体を sandbox `denyWrite`、対象 secrets を `denyRead` にする。したがって project-agnostic な unbound settings に対象 path がまだ無くても I-024/I-029 は弱まらない。read-only の限定許可には人間承認(ask)面が加わる(§31.3 G-T2 の ask 面列挙): (1) live settings 修復面 — `CONTROL_ROOT/.claude/settings.json` への Write は hook が ask を返し、人間が permission prompt で承認したときだけ通る(§13.6-3 と同一の面、§28.5-3 の配備欠陥回復)。(2) new モード限定の ESSENCE.md 直接設置 fallback(I-027 第二経路)— new モードの `--settings` overlay は対象一括 `Edit({project}/**)` deny の代わりに `Edit({project}/ESSENCE.md)` と `Edit({project}/essences/**)` を ask に載せ(deny は hook の ask に常に勝つため一括 deny とは両立しない。これら以外の対象書込みは hook の明示 deny と sandbox denyWrite が塞いだまま)、hook は `PROJECT_ROOT/ESSENCE.md` へ解決される Write だけに ask を返す(wrapper が `ATLAS_BUILDER_SESSION_ESSENCE_MODE=new` で識別)。(3) new モード限定の essences/ 資産設置(同じ I-027 第二経路の §2.1.5 面)— インタビューがテキスト系の指示資料を人間承認のもとに置けるよう、new モードに限り `PROJECT_ROOT/essences/` 配下の **3 階層以内の 1 ファイル**への Write に hook が ask を返す(root 自身・深さ上限を超えるパス・update モード・triage は deny のまま)。主経路は従来どおり handoff → wrapper の全文レビュー + y 設置であり、fallback は handoff 面が settings 修復後も欠陥のままの場合に、人間が画面で全文レビュー済みのドラフトに限って使う — permission prompt の明示承認が設置確認となり、I-004 の内容由来(人間の回答と承認)は保たれる。update モードの ESSENCE.md deny は不変。base/overlay 分割(§16.1)後は bound base がパス deny を持たないため、束縛済みプレーンでも第二経路は settings 層に遮られず到達可能である — I-027/I-004 の条件(hook の ask + 人間の permission prompt 承認 + 画面での全文レビュー)は束縛の有無で変わらず、標準フローの new-essence は依然として init 前 = unbound である(§2.1.4-5)。handoff 書込みが deny される配備欠陥時の手順は §13.6-3 の denied-write protocol と同一である(settings 修復 ask の提案が唯一のセッション内回復経路。却下時・修復自体が deny される時は拒否の逐語報告 + ドラフト全文の画面提示 + `just doctor` への誘導。人間への `!` コマンド実行依頼は禁止 — ユーザー入力も同一の deny/hook/sandbox を通る)。**読取の補完(wrapper 前処理)**: read-only はセッションの**書込み**制約であって読取制約ではないが、バイナリの Excel ブックだけは付随的に読めない(Read ツールはテキスト/画像のみ解釈し、Bash は許可面の外)。そこで wrapper は起動前に `PROJECT_ROOT/essences/` 配下(深さ上限 3、§2.1.5)の `.xlsx` / `.xlsm`(Excel lock ファイル `~$*` を除く)をテキストのセル一覧(`xlsx-dump.py`、stdlib のみ)として handoff dir 配下 `xlsx/<相対パス>.txt` へダンプする。これは信頼済みの人間側前処理であり、セッションの許可面・書込み面は一切変わらず(G-T2 無変更)、原本は human-only のまま(I-004)、ダンプは handoff dir と共に破棄される。ダンプ失敗(python3 不在・壊れたブック)は警告のみで面談は続行し、セッションは従来どおり人間に口頭で尋ねる。
3. **内容規律。** ドラフトは §2.1.1〜§2.1.3 の規範(9 見出し、観測可能な成功条件、must/should 2 段、won't の明示、anti-bloat)を対話の中で満たし、FILL マーカーとガイドブロックを残さない。人間の発言・明示承認に由来しない実質的内容を書いてはならない。
4. **wrapper の設置ゲート。** placeholder 判定(§13.1-8)に当たるドラフト(空・ガイドブロック残存・FILL 残存)は設置を拒否する — 設置しても doctor / loop が即停止するだけである。設置は原子的(tmp + rename)で、既存の非 placeholder Essence を置換する場合は REPLACE であることを明示して diff を表示する。確認が得られなければ何も変更せず、ドラフトは handoff に残す(人間が自分でレビュー・設置してもよい)。ドラフトが現行の `ESSENCE.md` と同一の場合は設置すべき変更が存在しないため、確認を求めず no-op として報告し handoff を掃除する。
5. **設置後の次手順。** 束縛前(bootstrap 未実行)なら `just init` — bootstrap が設置済み hash を人間確認済み baseline として anchor する(§13.1-10)。束縛後は resume で attestation を記録してから `just loop`(記録が無いと `essence_unreviewed_change` で停止する)。wrapper が state の有無からどちらかを判定して案内する。束縛後の案内が綴る resume 形は固定文言ではなく、**設置後の state に対する should-stop message**(§13.4-2 の単一導出点)である — 設置時に別の open gate が残っていれば素の resume は拒否される(§13.3-4')ため、固定綴りは案内が最も必要な状況でちょうど誤る(2026-08-04 の実障害: gate 停止中の update-essence 後、案内どおりに打った素の resume が拒否された)。停止がラッチされていないときだけ素の `just resume --note "..."` を綴り、should-stop が crash したときは案内を導出せず `just status` を指す(I-021 — 読めない gate 状態から案内を導かない)。
6. **越えない線。** wrapper は init / resume / loop を起動しない — 束縛・記録・再開は常に人間の独立した操作である。また essence は single-flight(I-018)の**外**にある: セッションは読み取り専用でロックを取らず、設置は人間の `$EDITOR` 編集と同格の human-input 編集であり、mid-cycle の設置も既存の柵(I-020、§13.1-10)がそのまま受け止める(wrapper はループ実行中なら確認前に警告する)。

この安全性は I-027 として固定する(§23)。

#### 2.1.5 essences/ — 人間所有の添付資産ディレクトリ

`ESSENCE.md` は人間が意図を書く唯一の**要求入力ファイル**だが、意図にはマークダウン本文へ収まらないもの — `ESSENCE.md` に貼る図などの画像、Markdown 以外の書式で書かれた指示資料 — がある。これを人間が置くために、`PROJECT_ROOT/essences/` を `ESSENCE.md` と同格の human-only 資産ディレクトリとして定める。Over-Project Agent はここを**参照のみ可・変更不可**(I-004 と同格)とし、その内容は cycle commit に決して乗らず、human resume checkpoint でのみ Git 履歴へ入る(I-020)。

**保護(I-004 と同格)。** essences/ への Agent の書込みは多層で塞ぐ。(a) guard hook の deny patterns に `(^|/)essences/` を加え、WRITE_TOOLS の書込みを deny する — `ESSENCE.md` と同じく、対象内のどこに入れ子で現れる `essences/` も human-only 資産の綴りとして deny する保守的な過剰遮断は**意図**である。(b) Bash の保護書込みターゲット判定(`protected_write_target`)に `essences/` を加え、mutator との連言で deny する。(c) bound overlay(§16.1)の permissions deny に `Edit(//<abs>/PROJECT/essences/**)`、sandbox `denyWrite` に `<abs>/PROJECT/essences` を置く多層防御の床。読取はいずれの層でも許す。

**オプショナル・非同梱。** essences/ は任意であり、不在・空ディレクトリは正常である。`templates/project/` はこれを同梱しない。dot 始まりのエントリ(`.DS_Store` 等の OS 残骸)はファイル・ディレクトリとも資産でも違反でもなく、観測時に無視する。

**構造(最大 3 階層)。** essences/ 配下はサブディレクトリで整理してよい。資産は `essences/` からの相対パスで識別し、そのセグメント数は **1 以上 3 以下**(`essences/<a>`・`essences/<a>/<b>`・`essences/<a>/<b>/<c>`)でなければならない。4 セグメント以上に置かれたエントリは validate エラーで停止する(内容は読まない)。各セグメントは `[A-Za-z0-9._-]` のみを用い、先頭・末尾の `.` を禁じる。空ディレクトリは違反ではない。`essences` が PROJECT_ROOT にディレクトリでない形(ファイル等)で存在するのは違反である。この上限は「添付資産は Essence の付属物であって第二のリポジトリではない」という位置づけを保つための人間可読性の床であり、深い階層が要るなら実装ファイル側(Agent 所有)へ置くべき、という設計判断である。

**双方向整合。** essences/ の各ファイルは `ESSENCE.md` 本文で言及されなければならない。言及は、その資産の相対パス自身(`essences/input/main.csv`)でも、**祖先ディレクトリ**(`essences/input/`)でもよい — ディレクトリ 1 行の言及がその配下の資産すべてを覆う。どちらの言及も無いファイルは **orphan** エラーである。逆に、`ESSENCE.md` が言及する `essences/<path>` は essences/ にファイルまたはディレクトリとして実在しなければならない(不在 = **dangling** エラー)。言及判定は directive(`deps:` / `recipe:` / `profile:`)と同じ安全境界に従う(§2.1.1、§20.2): HTML コメント・fenced code block の**外**にある semantic 行だけを見る。言及トークンは `essences/` 直後の `[A-Za-z0-9._-/]` の極大 run から末尾の `.` 連(文末句点)と `/` 連(ディレクトリ言及の末尾スラッシュ)を剥いだものであり、`essences/` の直前が path 構成文字(`[A-Za-z0-9._-]` または `/`。例 `src/essences/x`)の場合は言及と見なさない。Markdown のリンク/画像構文でも素のテキストでも成立する。`ESSENCE.md` が不在・placeholder の間は言及検査を**保留**する(構造検査は常時行う) — placeholder テンプレは言及を持たず全ファイルが偽 orphan になるためであり、その間は `essence_missing` / `essence_placeholder` が先に立つ(§13.1-8)。

**マニフェスト。** attestation(§13.1-10)が突き合わせる essences/ マニフェストのキーは `essences/` からの相対パス(`input/main.csv`)であり、値はその SHA-256 である。深さ上限を超えたエントリは構造違反として先に停止するため、マニフェストには現れない。

これらの不整合(非ディレクトリ・深さ上限超過・不正パス・orphan・dangling)は、停止条件 `essence_asset_integrity`(§13.1-14)と validate error(§20.1)の両方として機械的に現れる。essences/ 自体の読取不能は fail-closed のハードエラー(exit 2、I-021)である。

### 2.2 Autonomous Coding Contract

Atlas Builder は、各 cycle で次を満たす。

1. Essence に根拠を持たない要求を作らない。
2. Spec と Todo は JSON 正本として保持する。
3. Todo は evidence なしに done にしない。
4. 実装エラーはまず自律回復する。
5. 人間の判断が必要なときは停止し、理由と再開手順を可視化する。
6. コンテキストが失われても、ディスク上の正本から再開できる。
7. cycle ごとの変更は checkpoint commit として監査可能にする。

1 の系として、Todo の優先度は人間テンプレ(§2.1.1)の Must / Should に対応する **must / should の 2 段に閉じる**(§9.1)。Could 段は存在せず(§2.1.1、理由は §19.3)、Agent が Essence 外の作業へ自律予算を流し込む余地はない。

### 2.3 v1.0 Scope

この文書は Atlas Builder の v1.0 仕様である。v1.0 は、Atlas Builder の本質を「人間の Essence を自律実装へ投影すること」と定義したうえで、それを Claude Code で安全に長時間運用するための制御プレーン、状態モデル、停止/再開モデル、検証モデルを固定する。

---

## 3. Core Philosophy

Atlas Builder の正本優先順位は `Essence > Spec > Todo > Execution > Impl > Report` で固定する(概念・物理の正確な定義は §7.1)。`ESSENCE.md` は人間の意図の最上位正本であり、Over-Project Agent は絶対に直接編集しない。

Atlas Builder が対象プロジェクト直下に生成する**人間向け状態表示ファイル**は無い。機械正本は意図的に隠しディレクトリ `PROJECT_ROOT/.atlas-builder/state/` に置き、人間の状況把握は `just status`(正本 state からの都度表示、§15)が担う。

---

## 4. Goals and Non-goals

### 4.1 Goals

Atlas Builder は次を達成する。

1. 任意のソフトウェアプロジェクトを、Claude Code による自律的 agentic coding loop の対象にできる。
2. 人間の Essence を `ESSENCE.md` という 1つの意思決定正本として保持する。
3. Essence を Spec / Todo / 実装 / 検証 / Reflection / Recommendation へ追跡可能に投影する。
4. Spec / Todo / Recommendation / Reflection / Progress を JSON 正本として管理する。
5. すべての実装完了に evidence を要求する。
6. 実装系エラーはまず自律回復し、人間判断が必要なときだけ停止する。
7. 停止理由、再開手順、未解決判断を canonical state と `just status` / ループ終了メッセージの両方に可視化する。
8. コンテキストリセット後も、ディスク上の状態だけで継続可能にする。
9. Claude Code の permissions / hooks / trust / CWD 境界を使い、正本・秘密情報・高リスク変更を機械的に保護する。
10. 対象プロジェクトが Claude Code や AI エージェントを内容物として内包する場合(§5.0)も、同じ Essence 駆動ループと停止/再開プロトコルで**外から開発**できる。内包されたエージェント(In-Project Agent)の挙動確認は、ライブ対象を直接起動せず、対象が用意した隔離 runner がある場合に限る(§10)。通常プロダクトにはそのエージェントは存在しない。

### 4.2 Non-goals

Atlas Builder v1.0 は次を目的にしない。

1. Claude Code 以外の AI エージェントを第一級実行環境として扱うこと。
2. 複数モデル・複数ベンダーに抽象化すること。
3. 人間の Essence 判断を自動代替すること。
4. `ESSENCE.md` を自動更新すること。
5. 対象プロジェクトの本番デプロイを無条件で自動化すること。
6. 人間の承認、秘密情報、支出、組織的判断を自動化すること。
7. Workspace root を Claude Code 実行ルートとして使うこと。

---

## 5. Workspace Topology

### 5.0 対象がエージェントを内包する場合(In-Project Agent の在否)

対象プロジェクトの大多数は通常のプロダクト(Web / モバイル / CLI / ライブラリ等)であり、
プロダクト自身は AI エージェントを内包しない。この場合 **In-Project Agent は存在しない** —
実装はすべて Over-Project Agent の直接編集(§11.1)で完結し、対象リポジトリの人間関与ファイルは
`ESSENCE.md` だけである(`README.md` を含む他のすべては Atlas Builder が保守する通常の実装ファイルである。§11.1)。

一方、対象プロダクト自身がエージェントを中心に据えるものである場合(例: Lean 形式検証を Claude Code で
自動化する、YouTube ライブ配信を自律エージェント化する。§6, §32)、そのプロダクトは**内容物として
エージェントを持つ**。このとき、そのエージェント = In-Project Agent が対象の中に存在し、対象自身の
設定(`CLAUDE.md` / `.claude/**` など)に従って動く。

**これは 2 つの「プロジェクト種別」の固い分類ではなく、単に「対象がエージェントを内包するか否か」という
事実の違いである。** 内包するかどうかは対象の Essence が決めることであって、Atlas Builder が対象を格付けする
ための機構ではない。したがって本書は、この違いを支配的な分岐として全編に張り巡らせない — In-Project
Agent や対象側 `.claude/**` に言及する箇所は、単に「対象がそれを内包する場合の話」として読めばよい。
実行 profile(§11.5)も同じ原則に立つ: その値は「PoC か本番か」のような対象の格付けではなく、
「この配備で何の保護を緩めるか」という実行環境の事実申告であり、命名(auto-approve / unsandboxed)も
用途ラベルではなく緩める対象の名指しである。

**対象側 `CLAUDE.md` / `.claude/**` は対象の内容物である。** それは対象プロダクトの一部であり、対象の
Essence から普通に生まれる(あるいは人間が対象リポジトリに置く)。Atlas Builder はそこに**雛形を seed せず、
Atlas Builder 固有の語彙を書き込まない**(§6, §17)。エージェントを内包するプロダクトの形は極めて多様で
あり、Atlas Builder が「エージェント中心プロジェクトはこう書くべき」というテンプレートを押し付けることは、
かえって対象の多様性を損なう。対象がどのようなエージェントであるかは、あくまで対象の Essence が決める。

### 5.1 Standard Layout

```text
<workspace>/
├── README.md               # ワークスペース説明(init が templates/workspace から seed、既存は保持)
├── .atlas-builder/
│   ├── META.md              # フレームワーク設計書
│   ├── CLAUDE.md            # 配布時は未束縛版。init が templates/control から束縛版を生成
│   ├── README.md
│   ├── justfile            # 運用レシピのみ(配布時は未束縛版。init が生成)。lint/format は入らない(§18.4)
│   ├── .gitignore          # 束縛済み制御プレーンが runtime に生む物のみ(§25)
│   ├── .claude/
│   │   ├── settings.json   # 配布時は未束縛の安全版。init が templates/control から束縛版を生成
│   │   ├── agents/         # cycle 内 subagent(scout / analyst / builder)の実行定義(§30)
│   │   ├── commands/       # 人間起動の slash commands(/triage — §13.6、/essence — §2.1.4。束縛不要の静的ファイル)
│   │   ├── rules/
│   │   └── skills/
│   ├── .agent/
│   │   ├── state/
│   │   ├── runs/
│   │   ├── tmp/
│   │   └── prompts/
│   ├── templates/
│   │   ├── control/        # init: 束縛ファイル(.claude/settings.json / CLAUDE.md / justfile)の .tmpl
│   │   ├── workspace/      # init: ワークスペース root README の .tmpl
│   │   └── project/        # bootstrap: 対象プロジェクトへ seed する雛形
│   ├── recipes/            # レシピ原本(§29): ESSENCE.md のポインタで採用できる具体的実装の型
│   └── scripts/
│       ├── _lib.sh
│       ├── init.sh
│       ├── doctor.sh
│       ├── bootstrap.sh
│       ├── loop.sh
│       ├── once.sh
│       ├── stop.sh
│       ├── status.sh
│       ├── watch.sh
│       ├── resume.sh
│       ├── triage.sh
│       ├── supervise.sh
│       ├── essence.sh
│       ├── xlsx-dump.py
│       └── claude-trust.sh
│
└── {project-title}/
    ├── ESSENCE.md               # 人間が書き込む唯一のファイル
    ├── README.md                # 通常の実装ファイル。Atlas Builder が保守する(§11.1)
    ├── .gitignore
    ├── CLAUDE.md                # △ 対象がエージェントを内包する場合に、対象の内容物として存在しうる(§5.0)
    ├── .claude/                 # △ 同上。対象自身の実行ルールであり Atlas Builder が seed するものではない
    │   ├── settings.json        #    In-Project Agent 用設定(§16.2)
    │   ├── hooks/
    │   ├── rules/
    │   ├── skills/
    │   └── agents/
    ├── .atlas-builder/
    │   ├── state/
    │   │   ├── state_index.json
    │   │   ├── project.json
    │   │   ├── spec.json
    │   │   ├── todo.json
    │   │   ├── recommendations.json
    │   │   ├── blockers.json
    │   │   ├── context.json
    │   │   ├── validation.json
    │   │   ├── reflection.jsonl
    │   │   ├── runs.jsonl
    │   │   ├── high_risk_changes.jsonl
    │   │   └── lessons.jsonl
    │   └── tmp/
    ├── src/
    ├── tests/
    └── artifacts/
```

上図は最大構成である。`△` 印の `CLAUDE.md` / `.claude/` は、対象プロダクトが
**エージェントを内容物として内包する場合**にだけ現れる(§5.0)。これらは対象自身の実行ルールで
あって Atlas Builder が seed するものではなく、対象の Essence から生まれる/人間が置くものである(§16.2、§17)。
対象がエージェントを内包しない通常のプロダクトでは、対象リポジトリ直下の人間関与ファイルは
`ESSENCE.md` だけになる。

`.atlas-builder/` に **開発ツールの設定(`.editorconfig` 等)が
無いこと**は意図的である。`.atlas-builder/` は配布単位であり、束縛済み制御プレーンの運用に必要なものだけを
含む(I-028)。lint / format(`shellcheck` / `shfmt`)は Atlas Builder 自身のソースを主語とするものなので、
フレームワークのリポジトリ root — 配布ディレクトリの**外** — に置く(§18.4)。したがってワークスペースの
利用者は追加のツールチェーンを必要としない(実行系はゼロ依存の Lean バイナリ `bin/atlas-builder`、§18.1、§31)。

### 5.2 Important Naming Rule

この設計では `.atlas-builder` が2種類存在する。

| Path                           | Name                        | Meaning                      |
| ------------------------------ | --------------------------- | ---------------------------- |
| `./.atlas-builder/`                 | Control Atlas Builder Root       | Over-Project Agent の実行ルート        |
| `./{project-title}/.atlas-builder/` | Project Atlas Builder State Root | 対象プロジェクトの Atlas Builder 状態 |

混同を避けるため、設計書・コード・ログでは必ず次の用語を使う。

```text
CONTROL_ROOT = ./.atlas-builder
PROJECT_ROOT = ./{project-title}
PROJECT_STATE_ROOT = ./{project-title}/.atlas-builder
```

この sibling トポロジ(CONTROL_ROOT と PROJECT_ROOT が同じ親を持つ)は §5.1 で固定された前提であり、`bin/atlas-builder state` が機械的に強制する。非標準の入れ子配置はパスベースの checkpoint guard(§24.3)を静かに弱めるため、拒否される。

**1 制御プレーン = 1 対象 — 何から守るかの解像度。** この 1:1 束縛は意図的な設計だが、防ぐべき脅威は 2 種類に分かれ、扱いが異なる。

1. **人間の意図的な複数管理**: これは「柵で防ぐ」対象ではない。1 制御プレーンに第 2 の対象を登録する動機も自然な経路も無く、放っておくと壊れる力は働かない(壊れるとすれば事故だけである)。不変条件には「反自然で柵が要るもの(例: `ESSENCE.md` deny)」と「そもそも壊れる力が働かないもの」の 2 種があり、1:1 は後者に属する。したがって人間向けの説明・防御(justfile への焼き込み、doctor の案内)は簡素でよい。
2. **事故・バグ由来の二重化**: こちらが本命である。束縛外への state 生成(例: `ensure` が兄弟ディレクトリに黙って state を作る)や非標準配置が忍び込むと、パスベースの checkpoint guard(§24.3)が静かに緩む — 1:1 違反そのものではなく、この**二次被害**が実害である。守るべき核心は「**`ensure` を含む全変異コマンドが、束縛された 1 対象の外に state を生成・登録しない**」という内部整合の 1 点に絞られる。

この解像度に基づき、機械的強制は内部整合を守る最小構成として保持する: 宣言の単一オブジェクト化(§8.1)、変異コマンドの `--project` 拒否(§18.2)、sibling トポロジ検査(前段)である。あわせて `project_index.json` が単一の `project` オブジェクトだけを登録していることを `doctor` / `bin/atlas-builder state` が検査し、複数登録や束縛不一致を報告する — ただしこれらの柵の目的は「人間の複数管理という意図の禁止」ではなく「事故・バグが checkpoint guard を静かに緩めることの防止」である、と本節が定義する。

### 5.3 v1.0 Operational Decisions

次は、§2 の中核価値を Claude Code 上で安全に運用するための v1.0 固定事項である。これらは Atlas Builder の価値そのものではなく、`ESSENCE.md` を唯一の人間正本として保ちながら自律ループを壊さないための実行トポロジである。

| 項目                       | 決定                                                              |
| ------------------------ | --------------------------------------------------------------- |
| フレームワーク名                 | Atlas Builder                                                        |
| ワークスペース構造                | `./.atlas-builder` と `./{project-title}`                             |
| Claude Code 起動境界         | Atlas Builder が起動する Claude Code は Over-Project Agent の `./.atlas-builder` のみ。対象の runtime をライブ `./{project-title}` から起動しない(I-003) |
| Workspace root 起動        | 禁止                                                              |
| Essence 配置               | `./{project-title}/ESSENCE.md`                                  |
| In-Project Agent 検証            | 対象がエージェントを内包する場合にだけ登場する。対象定義の隔離 runner がライブ state・秘密・制御面へのアクセスを遮断できる場合のみ実行し、無ければ Human-input Recommendation で停止する(§10) |
| Over-Project Agent の実装編集     | `../{project-title}` の実装ファイル(In-Project Agent のコード・設定を含む)を直接編集して開発する。これが実装の主経路 |
| 状態管理                     | Atlas Builder 制御状態と対象プロジェクト状態を分離                                     |
| Atlas Builder 制御状態            | `./.atlas-builder/.agent/state/`                                     |
| 対象プロジェクト状態               | `./{project-title}/.atlas-builder/state/`                            |
| 対象側 `CLAUDE.md` / `.claude/` | 対象がエージェントを内包する場合にだけ存在する対象の内容物(§16.2、§17)。Atlas Builder は seed しない。存在する場合は Agent Runtime High-Risk Zone(§12)として扱う |
| 人間向け状態表示               | `just status` / ループ終了メッセージ(正本 state から都度計算、§15)     |

---

## 6. Agent Boundary Model

Atlas Builder の発想は、突き詰めれば 1 つの単純な着想に尽きる。

> **2 つの root を並列に置き、「対象を開発する主体」と「対象の内容物として設計される主体」を切り分ける。**

これが Atlas Builder の存在理由の核心であり、本書の他のすべての境界はこの一点の帰結である。二重ルートは凝った仕掛けではなく、この切り分けをディレクトリのレベルで自然に成立させるための最小の形である。

- **Over-Project Agent** は、対象プロジェクトを**開発する**エージェントである。Essence を読み、投影し、実装し、検証する — 主体は常に対象の外(CONTROL_ROOT)にいて、対象を**メタ的に見て開発を推進する**。これが Atlas Builder を司る本体である。
- **In-Project Agent** は、対象プロジェクトの**内容物そのものとして振る舞うよう設計された**エージェントである。対象がエージェントを内包する種類のプロダクトであるとき、そのプロダクト自身の実行主体がこれにあたる。製品としては対象自身のルール(`CLAUDE.md` / `.claude/**` など、存在すれば)に従うが、その任意の設定・hook は executable product content であり、Atlas Builder の安全境界として信頼しない。

**この 2 つは並列であって、主従でも委譲関係でもない。** In-Project Agent は Over-Project Agent の下請けではなく、Atlas Builder の存在を知る必要もない。それは対象プロダクトの一部であり、対象の Essence から普通に生まれる内容物である(§5.0)。したがって対象側の設定(`CLAUDE.md` / `.claude/**`)に Atlas Builder 固有の語彙を書き込まない。ただし「知らない」はアクセス制御ではない。ライブ PROJECT_ROOT で起動すれば、任意の対象 hook/command は sibling の CONTROL_ROOT や同じ root の正本 state を読み書きし得る。このため root 分離は**設定の非混入**を与えるが**実行時隔離**を与えず、後者は §10 の no-live-launch + isolated runner で担保する。

この切り分けにより、通常の Web / モバイル / CLI プロダクトだけでなく、**エージェントが振る舞うこと自体が成果物であるプロダクト**(例: Lean 形式検証を Claude Code エージェントで自動化するプロジェクト、YouTube ライブ配信を自律エージェント化するプロジェクト)も、同じ Essence 駆動ループ・同じ停止/再開プロトコルで開発できる(§32)。前者では In-Project Agent は登場せず、後者では In-Project Agent が対象プロダクトの実行主体として存在する — が、いずれも Over-Project Agent が外から開発を推進する構図は変わらない。

**呼称について。** 位置の対称(In ↔ Over)が役割を表す: 対象の**中で**振る舞うよう設計された内容物が **In-Project Agent**、対象の**上・外から**投影する主体が **Over-Project Agent** である。実装識別子は `workspace.json` の `overproject_agent_cwd` と `embedded_agent_live_launch: false`、Atlas Builder の `runs.jsonl` / `control_runs.jsonl` の `agent: "Over-Project Agent"` に揃える。Atlas Builder は In-Project Agent のライブ run を記録しない。フレームワーク製品名 "Atlas Builder" は別レイヤーである。

### 6.1 Over-Project Agent

Over-Project Agent は次の CWD で起動する。

```bash
cd ./.atlas-builder
just loop          # autonomous cycle
just supervise --todo T-... --recommendation R-... # exact approved High-Risk change, human-present
```

Atlas Builder の wrapper はいずれも Claude をこの CWD から `--setting-sources project --strict-mcp-config` と環境 sanitize 付きで起動する。運用者が raw `claude` を代替入口として起動するとこの固定を迂回するため、通常運用入口にはしない(§11.4、§18.2)。

Over-Project Agent の責務は次である。

1. `../{project-title}/ESSENCE.md` を読む。
2. `../{project-title}/README.md` を読む。
3. `../{project-title}/.atlas-builder/state/*.json` を正本として更新する。
4. Todo batch を選択する。
5. 対象プロジェクトの実装ファイルを直接編集する(これが実装の基本経路である)。
6. Essence 由来 Blocking、人間承認/入力待ち、または空転継続がある場合は停止する。
7. 実装系エラーは自律回復する。

対象が内包するエージェント(In-Project Agent)がある場合、その**コード・設定も対象実装として開発する**。通常 cycle で ask-gated な Agent Runtime High-Risk Zone に変更が必要なら、Agent は Recommendation を記録して停止し、人間承認後の `just supervise` で適用する(§12、§21.3)。挙動確認は対象 CWD から直接起動せず、対象定義の隔離 runner だけを使う(§10)。

Over-Project Agent は、Claude Code の `additionalDirectories`(起動毎の bound overlay が付与する、§16.1)により `../{project-title}` へのファイルアクセスを得る。`additionalDirectories` はファイルアクセスを拡張するものであり、追加ディレクトリを完全な Claude Code 設定ルートとして扱うものではないため、対象プロジェクトの `.claude` 設定が Over-Project Agent の制御設定として混入することはない。もっとも、この非混入は root を分けたことの自然な帰結でもある — 対象の `.claude` は対象 CWD の設定であって、CONTROL_ROOT から起動する Over-Project Agent の設定ではない。([Claude][1])

### 6.2 In-Project Agent

In-Project Agent は、対象プロダクトがエージェントを内包する種類のものであるときに、そのプロダクトの**内容物として**存在する実行主体である。対象が通常のプロダクト(Web / モバイル / CLI / ライブラリ等)であれば、そもそも In-Project Agent は存在しない — 対象がエージェントを持たないだけのことである(§5.0)。

製品として実行される場合、In-Project Agent は対象自身のルールに従う。ただし Atlas Builder cycle はライブ PROJECT_ROOT でそれを起動しない。対象 runtime の設定・hooks・MCP・command は任意コードであり、同じ root の `.atlas-builder/state` と sibling CONTROL_ROOT を「関心が無い」という規約だけで保護できないためである(I-003)。

重要なのは、**In-Project Agent に Atlas Builder を教えないことと、In-Project Agent を Atlas Builder から隔離することは別問題**だということである。前者は製品の自己完結性、後者はセキュリティ境界である。Atlas Builder は内容物を外から開発し、検証可能な隔離 runner が対象に定義されている場合だけ、その runner の結果を観察する(§10)。

対象側 `CLAUDE.md` / `.claude/**` の中身がどのようなものであるべきかは、Atlas Builder が規定することではない。エージェントを内包するプロダクトといってもその形は極めて多様であり、Atlas Builder はそこに雛形を押し付けない(§5.0、§17)。

### 6.3 Why Not Claude Code Subagents

対象が In-Project Agent を内包する場合、それを Claude Code の custom subagent として扱わない。In-Project Agent は Over-Project Agent の一部ではなく、対象自身のルールに従う独立した製品内容だからである。subagent は親セッションの設定・permissions を共有し、対象 runtime の忠実な E2E にはならない。一方、対象 CWD から別 Claude セッションをライブ起動する方法も安全境界を失うため採用しない。対象自身が隔離 runner を定義した場合のみ、その製品境界を保った検証として扱う(§10)。([Claude][2])

この禁止は **In-Project Agent を subagent 化しない**という一点であって、subagent 機構そのものの排除ではない。Over-Project Agent が**自分自身の cycle 内の脚仕事**(read-only の探索、仕様確定済みの定型実装)を自セッション配下の subagent に担わせることは、この境界と無関係に成立する — それは親セッションの設定ルート・permissions・hooks を共有すべき仕事だからこそ subagent が正しい形である(§30)。

---

## 7. Authority and Ownership

### 7.1 Canonical Priority

概念上の優先順位。

```text
Essence > Spec > Todo > Execution > Impl > Report
```

物理ファイル上の優先順位。

```text
PROJECT_ROOT/ESSENCE.md
> PROJECT_ROOT/.atlas-builder/state/spec.json
> PROJECT_ROOT/.atlas-builder/state/todo.json
> PROJECT_ROOT 実装ファイル
```

### 7.2 Ownership Boundaries

要求入力正本も、束縛済みプロジェクトを運用する人間の対象ファイル書き込み面も、`ESSENCE.md` だけである(§0)。一方 `CONTROL_ROOT/CLAUDE.md` は人間所有ではなく framework-owned enforcement であり、init が配布 template から生成した後は bound Agent plane から不変である。この 2 つを同じ「人間承認なら Agent が変更できる」集合に入れてはならない。

| File                      | Policy                                      |
| ------------------------- | ------------------------------------------- |
| `PROJECT_ROOT/ESSENCE.md` | 人間が書き込む唯一のファイル。人間のみ編集可、Agent は絶対に編集不可 |
| `CONTROL_ROOT/CLAUDE.md`  | framework-owned な Over-Project Agent 実行憲章。init が template から生成し、束縛済み Agent session からは変更不能。更新は配布原本の maintainer plane で行う(§11.3、I-028) |

**`PROJECT_ROOT/README.md` はこの表に載らない。** それは対象プロジェクトの**通常のドキュメント成果物**であり、
Over-Project Agent が `src/**` や `tests/**` と同じ資格で自由に編集し、cycle commit に含める実装ファイルである
(§11.1、§24.3)。人間所有の特別扱いを受けるのは `ESSENCE.md` のみである — 「人間が書き込むのは 1 ファイル」
という約束(§0)は、裏返せば「人間がゲートを握る対象プロジェクトのファイルも `ESSENCE.md` に絞る」ということである。
README を承認ゲートに置くと、地形(意図)ではなく地図(投影された説明文)にまで人間の署名を要求することになり、
自律ループの摩擦を無意味に増やす。README が Essence と食い違うなら、正されるべきは README(地図)の側である。
人間が README を手で書きたければ書いてよい — その差分は他の実装ファイルと同様、通常の未コミット差分として扱われる。

対象がエージェントを内包する場合の `PROJECT_ROOT/CLAUDE.md` / `.claude/**` も、この表の管轄外である —
それは Atlas Builder の管理下にある人間承認ゲートファイルではなく、**対象プロダクトの内容物**であって、
Over-Project Agent が実装として直接開発する対象である(§6.2, §11)。ただし README と違い、それらは
将来の作業の理解・実行のされ方そのものを変えるため、High-Risk(ask + hash 記録、§12)として扱われ、
cycle commit には含まれない(I-020)。Atlas Builder はそこに雛形を seed しない。

### 7.3 Atlas Builder-owned Files

| Path                                            | Policy                        |
| ----------------------------------------------- | ----------------------------- |
| `PROJECT_ROOT/.atlas-builder/state/*.json`           | 対象プロジェクトの Atlas Builder 正本         |
| `PROJECT_ROOT/.atlas-builder/state/*.jsonl`          | 対象プロジェクトの追記ログ                 |
| `CONTROL_ROOT/.agent/state/*`                   | Atlas Builder 制御プレーン状態             |

---

## 8. State Model

### 8.1 Control Plane State

`CONTROL_ROOT/.agent/state/` は、Atlas Builder 自体の状態を保持する。

```text
CONTROL_ROOT/.agent/state/
├── workspace.json
├── project_index.json
├── control_context.json
├── control_runs.jsonl
├── essence_attestations.jsonl   # §13.1-10 の attestation 台帳(resume のみが書く)
├── tool_audit.jsonl
└── high_risk_changes.jsonl      # atlas-builder hook post-tool の fallback(project を特定できない書込み)
```

#### `workspace.json`

**正本は `lean/Looper/Core/StaticConfig.lean` の `workspace` 定義である。** 本ファイルは
その投影 — `StaticConfig.workspaceRendered` を maintainer plane の再生成レシピ
(§18.4)、標準配布では installer が設置時にエンジンへ書かせたもの — であり、
バイト列は Lean 側 `#guard` と sync テスト(D-008)が二重凍結する。ランタイムはこのファイルを一切変異させない(静的設定)。
配備済みプレーンでは `doctor.sh` が同じバイト比較で手編集 drift を検出し、
warn + 修復手順の提示に留める(勝手に上書きしない — 直接編集ポリシー §11 と整合)。

宣言する内容(意味の正本は §23 の I 番号。宣言値は enforcement 側が import する定義
そのものであり、宣言と強制は定義共有により構成的に一致する):

- `schema_version` / `framework.version` — 唯一の定義点は `StaticConfig.schemaVersion` /
  `frameworkVersion`(D-009。`State/Validate.schemaVersion` は名前参照)。
- `invariants.never_run_claude_from_workspace_root: true` — I-001。
- `invariants.overproject_agent_cwd: "./.atlas-builder"` — I-002。SessionStart hook の違反文言は
  `StaticConfig.overprojectAgentCwd` を参照する。
- `invariants.embedded_agent_live_launch: false` — 対象がエージェントを内包しても Atlas Builder が
  ライブ PROJECT_ROOT から直接起動しない契約(I-003)を宣言する。対象がエージェントを
  内包しない場合にも同じ値でよい。
- `invariants.project_essence_is_human_only: true` — I-004(G-T2/G-T3 の証明済み面)。

投影が定義を落とさない/歪めないことは機械証明済み(§31.3 W-T1)。

#### `project_index.json`

**1 制御プレーン = 1 対象は宣言だけでなく形で守る(§5.2)。** `project_index` は**単一オブジェクト** `project` を持つ — `projects` 配列という器はスキーマだけ読むと「N 個登録できる」と誤読させ、`bin/atlas-builder state` が強制する 1:1 と器が矛盾するからである。多対象を示唆する痕跡をゼロにする。(この強制の目的の解像度 — 人間の意図の禁止ではなく、事故・バグ由来の二重化の防止 — は §5.2 が定義する。)

```json
{
  "schema_version": "1.0.0",
  "project": {
    "id": "P-001",
    "title": "PROJECT_TITLE",
    "project_root": "../PROJECT_TITLE",
    "project_state_root": "../PROJECT_TITLE/.atlas-builder",
    "status": "active",
    "created_at": null
  }
}
```

`project` が未設定(`null`)なら未束縛の配布状態、設定済みならその 1 対象に束縛済みである。`bin/atlas-builder state` の変異コマンドは、`--project` がこの `project_root` と一致しない場合を拒否する(§18.2。`title` の食い違いは束縛整合の warning として可視化される — §5.2)。

未束縛シード(`{"schema_version": "1.0.0", "project": null}`)の正本は `StaticConfig.projectIndexSeed` であり、配布バイト列は workspace.json と同じ規律(エンジンによる生成・D-008 凍結)に従う。束縛後の本ファイルは `atlas-builder state ensure` / init が変異するランタイム正本であり、昇格対象外である。

### 8.2 Project Plane State

`PROJECT_ROOT/.atlas-builder/state/` は、対象プロジェクト固有の正本を保持する。

```text
PROJECT_ROOT/.atlas-builder/state/
├── state_index.json
├── project.json
├── spec.json
├── todo.json
├── recommendations.json
├── blockers.json
├── context.json
├── validation.json
├── reflection.jsonl
├── runs.jsonl
├── high_risk_changes.jsonl
└── lessons.jsonl            # 知見台帳(§14.3): cycle 横断で再利用する教訓
```

`.jsonl` の各正本ログは**追記専用**である: 既存エントリの書き換え・切り詰めは行わない(§8.4-5 が参照する JSONL 規律。破損時の回復は §13.5 の checkpoint 復元)。

エージェントが書ける追記ログ(`reflection.jsonl` / `lessons.jsonl`)は、Edit ツールの手書きではなく **`bin/atlas-builder state append-reflection` / `append-lesson --file <entry.json>`** を通る(§8.2)。追記点を 1 つの遷移に閉じるのは規律の飾りではなく、手書き追記が実際に 3 種の恒久的な壊れ方を生んだからである(実走行 2026-08-12): (a) 「当時の最終行」への Edit アンカーを誤り 2 エントリの物理順序が逆転したままコミットされ、append-only 原則により恒久化した、(b) あるエントリだけ `kind: "cycle_reflection"` ではなく `type: "cycle"` で必須キーを欠いた、(c) run_id のサフィックスが転写漏れした。追記コマンドは (a) を「常に末尾へ追記する」ことで、(b) を受理時のスキーマ検査で、(c) を **`at` / `cycle` / `run_id` / `recorded_by` / `id` を engine の予約キーにする(`id` は lessons で刻まれ、reflection では予約のみ — §14.3)**ことで同時に消す。刻印フィールドを呼び出し側が指定した bundle は**黙って上書きせず拒否する** — 刻印は事実であって申告ではない、という区別が消えると転写ミスが「エージェントの申告」として台帳に戻る。framework 予約の reflection type(`loop_gate` / `context_reset` / `human_resume`)はエージェント経路から書けない(偽の「人間が resume した」記録を作れない — attestation 台帳が agent-unwritable なのと同じ理由)。

投影文書の item id は一意でなければならず、`S-###`(Spec)/ `T-###`(Todo)/ `R-###`(Recommendation — framework が実体化する loop gate のみ `R-LG-<timestamp>-<suffix>`、§21.5)/ `B-###`(Blocker)の形を用いる。id 本体の文字クラスは `<prefix>-[A-Za-z0-9_+-]+` である(正本は `Looper/State/Model.lean` の `isIdChar` / `validIdShape`)。`+` はこのクラスの必須要素である: loop gate id は UTC オフセット付きローカル時刻を埋め込むため、UTC 以東のすべての配備で `R-LG-20260726T044234+0900-b7f8` の形になる。id を argv へ載せる前に形状を見るシェル側の pre-filter は、この canonical 形状**そのもの**でなければならない(綴りは `_lib.sh` の `valid_item_id` 1 箇所のみ。engine より厳しいクラスは、engine なら解決できる正当な id を握り潰す — §13.6-5 の実障害、凍結は matrix C-026 / SH-011..012)。

各 Spec item は `essence_refs` に、現在の `ESSENCE.md` の active な人間内容行を正規化した文字列を 1 件以上持つ。見出し、空行、`deps:` / `recipe:` / `profile:` directive、HTML comment、fenced code 内は参照先にならない。参照は現在の Essence 内容との**完全一致**で検査される: 投影 hash(spec.json の `projected_from_essence_sha256`)が現 `ESSENCE.md` と一致している通常状態では、存在しない根拠・古い根拠を指す Spec は validate error になる(§20.2-7)。投影 hash が乖離している間 — 人間が Essence を編集し、まだ再投影されていない設計上の一時状態 — は、ref の不一致は**構造的必然**(編集された行を参照していた全 Spec が機械的に stale になる)なので per-Spec error にせず、単一の projection-drift warning に不一致 Spec の一覧として集約する。この緩和が安全なのは、apply-projection が spec.json を含む bundle に現 `ESSENCE.md` hash の stamp 一致を要求する(stale 投影は**書けない**、§20.2-8)ため、乖離状態が「人間の Essence 編集の後・再投影の前」以外に発生し得ないからである。これは「投影がどの原文に由来するか」の機械的 provenance であり、その解釈が正しいことまで保証するものではない(§22)。

各 Spec item はさらに **`priority`(`must` / `should`)を必須で持つ** — 投影時に、その Spec の根拠となった Essence の節(`必須対応事項` / `任意対応事項`)から決定する(§2.1.1 の 2 段対応。`非対応事項` は Spec にならないので第三の値は存在しない)。これが must 判定の**単一定義点**である: Todo の priority は参照する Spec の最強 priority と一致しなければならず(§20.1)、完了述語の must フェーズ判定(§19.3)も must Todo の集合から計算する。`essence_refs` は内容行への trace であって見出し情報を運ばないため、由来見出しを構造として保存するのはこのフィールドの責務である。

High-Risk Todo は `risk_level: "high"` / non-empty `risk_reason` に加えて、supervised 変更面を表す non-empty `target` を持つ。対応する承認 Recommendation は `source` に Todo ID を含め、同じ `target` を完全一致で持つ(§12.1)。

Agent は `spec.json` / `todo.json` / `recommendations.json` / `blockers.json` を in-place 編集しない。投影更新は、変更する正本ファイル名を key、その全文 JSON object を value とする非空 bundle を作り、`bin/atlas-builder state apply-projection --file <bundle.json>` へ渡す。bundle の「現状」部分は **`bin/atlas-builder state stage-projection`** が現在の正本 4 面をそのまま雛形として `PROJECT_STATE_ROOT/tmp/projection_bundle.json`(gitignore 済み)へ吐くので、エージェントはそれを編集して変更しないファイルを削り、apply する。生成支援が無かった頃の実手順は「`cp /dev/null` で空 `.py` を作る → ビルダースクリプトを Write → `python3` 実行で bundle JSON を生成 → apply → 両ファイルを絶対パスで rm」という儀式になり、handoff で cycle を跨いで伝承されていた(実走行 2026-08-12)。bundle 方式そのものは正しい(投影面は Edit 拒否であるべきだ)が、正本を読んで書き出す作業を毎回エージェントに再発明させる理由は無い。この API は未指定ファイルを現行正本のまま含めた prospective snapshot 全体を**最初の書込み前に** validate し、error なら 1 ファイルも変更しない。成功時の置換はファイルごとに atomic replace であるが、複数ファイル全体を 1 回の filesystem transaction で同時置換する保証はない。単一実行(I-018)が並行観測を排除し、途中 crash は次回 validate / checkpoint 回復で検出する。この限界を multi-file atomicity と誤記してはならない。

### 8.3 Project State Index

```json
{
  "schema_version": "1.0.0",
  "canonical": {
    "essence": "../../ESSENCE.md",
    "project": "project.json",
    "spec": "spec.json",
    "todo": "todo.json",
    "recommendations": "recommendations.json",
    "blockers": "blockers.json",
    "context": "context.json",
    "validation": "validation.json",
    "reflection": "reflection.jsonl",
    "runs": "runs.jsonl",
    "high_risk_changes": "high_risk_changes.jsonl",
    "lessons": "lessons.jsonl"
  },
  "priority_order": [
    "ESSENCE.md",
    ".atlas-builder/state/spec.json",
    ".atlas-builder/state/todo.json",
    "implementation"
  ]
}
```

### 8.4 Timestamp Convention

ログ(canonical state / JSONL)に記録する時刻と、`just status` などに表示する時刻は、すべて単一の**表示タイムゾーン**で揃える。

1. 既定の表示タイムゾーンは JST(`Asia/Tokyo`)。
2. 環境変数 `ATLAS_BUILDER_TZ` で上書きできる。受理する形式は UTC 固定オフセット方言 — `+HH:MM` / `-HH:MM` / `Z` / `UTC` — である(ゼロ依存の実行層は tzdata を持たないため、IANA タイムゾーン名は受理しない)。これが将来の任意時刻系対応の入口であり、時刻を生成する各実装はこの 1 点だけを参照する。不正な値は既定に一致する固定 +09:00 にフォールバックし、時刻生成が状態遷移を壊すことはない。
3. 形式は ISO 8601 オフセット付き(例: `2026-07-08T17:30:00+09:00`)。オフセットを必ず含めるので、表示タイムゾーンを後から変えても過去の記録は一意なままである。
4. id に埋め込む時刻(run id、loop-gate Recommendation id)は `%Y%m%dT%H%M%S%z`(例: `20260708T173000+0900`)。id は不透明な文字列として扱われ、どこでもパースされない。
5. 追記専用ログの既存エントリは書き換えない(§8.2 の JSONL 規律): オフセット付き ISO 8601 である限り、表示タイムゾーンと異なるオフセットのエントリも有効である。

---

## 9. Todo Execution Model

### 9.1 Todo Executor Field

`todo.json` の各 Todo は executor を持つ。

```json
{
  "id": "T-001",
  "title": "Implement feature X",
  "spec": ["S-001"],
  "status": "pending",
  "priority": "must",
  "executor": {
    "mode": "atlas-builder",
    "reason": "Over-Project Agent can safely edit implementation files directly."
  }
}
```

実装は Over-Project Agent の直接編集で完結する。通常パスは自律 cycle、高リスク ask パスは人間承認後の
`just supervise` で同じ Over-Project Agent が編集する(§11、§12)。対象がエージェントを内包する場合も、
そのコード・設定は開発対象であり、ライブ runtime 自身に実装を委ねない(§10)。

`executor.mode` は次のいずれか。

| Mode       | Meaning                                       |
| ---------- | --------------------------------------------- |
| `atlas-builder` | Over-Project Agent が `../{project-title}` を直接編集する |
| `human`    | 人間判断待ち                                        |
| `blocked`  | Blocking または回復不能                              |

対象定義の隔離 runner を使う検証(§10)は委譲(別 executor)ではなく、`atlas-builder` cycle 内の検証ステップである。
他の検証コマンド(`npm test` 等)と同じ地位にあり、その結果は Todo の evidence になる。

`priority` は **must / should の 2 段**である。人間テンプレート(§2.1.1)の `必須対応事項` / `任意対応事項` に 1:1 で対応する(`非対応事項` は要求外であり Todo にならない — §2.1.2)。Could 段は存在しない(§2.1.1、理由は §19.3)。

### 9.2 Default Executor

executor は常に `atlas-builder` である — Over-Project Agent が対象実装(In-Project Agent のコード・設定を含む)を
編集して開発するのが唯一の Agent 実装経路だからである(§11.1)。高リスク変更で自律 cycle が停止し、
人間同席の `just supervise` へ移っても executor の主体は変わらない。

対象がエージェントを内包する場合、開発したエージェントが実際に正しく振る舞うかはコードを読むだけでは
確かめられない。しかしライブ起動は arbitrary target hooks に制御面を明け渡すため禁止する。対象が §10 の
隔離 runner を提供する場合にだけ、`atlas-builder` cycle 内の検証ステップとして確認できる(典型的な確認項目は
§10.2)。

### 9.3 Batch Rule

1つの batch に通常実装 Todo と Agent Runtime High-Risk Todo を混ぜない。この排他律(risk 二値・executor の混在なし)を `atlas-builder state validate` の成功が保証することは機械証明済み(§31.3 S-T5)。

```json
{
  "batch_policy": {
    "default_batch_size": 3,
    "max_batch_size": 5,
    "max_context_cost_per_batch": 8,
    "prefer_same_batch_group": true,
    "avoid_mixing_high_risk_items": true,
    "avoid_mixing_executors": true
  }
}
```

---

## 10. Verifying an Embedded Agent Without Trusting It

> **適用範囲。** 本章は、対象プロダクトがエージェント(In-Project Agent)を**内容物として内包する**
> 場合にのみ意味を持つ(§5.0)。通常のプロダクト(Web / モバイル / CLI / ライブラリ等)には
> In-Project Agent が存在しないため、本章の手続きは登場しない。

### 10.1 基本は「ライブ対象で動かさない」

In-Project Agent は対象プロダクトの内容物であって、Over-Project Agent の下請けではない(§6)。
そのコードと設定を外から開発するが、**ライブ PROJECT_ROOT から直接起動しない**。対象側の
`CLAUDE.md` / `.claude/**` / hooks / MCP / scripts は任意の executable product content であり、起動すれば
同じ root の `.atlas-builder/state/**` や sibling CONTROL_ROOT を読み書きし得る。「Atlas Builder を知らない」こと、
CWD が別であること、プロンプトで触るなと命じることのいずれも OS のアクセス制御ではない。

したがって raw `claude` の nested launch は permissions と `atlas-builder hook pre-tool` の両方で deny する。
これは機能制限ではなく、「自然に守られる」という偽の不変条件を排し、強制可能な I-003 に
置き換えるための境界である。

ここで hook が機械的に識別できるのは、Bash tool へ提出された command 上に現れる直接 launch
(`claude`、shell wrapper、通常の quoting/absolute path を含む)までである。任意の build/test script の
内部でさらに何を `exec` するかを、command text だけから証明することはできない。したがって未レビューの
script は、名前が test/runner らしいというだけでは §10.2 の隔離 runner と認めない。実装をレビューし、
使い捨て環境・mount/input/output 境界を test evidence で示せる runner だけが許可対象である。証明不能なら
人間ゲートへ止める。OS sandbox は control/secret への防御を重ねるが、runner isolation の証明そのものを
代替しない。この **direct-launch の runtime deny + runner の evidence gate** が I-003 の正確な強制範囲である。

### 10.2 許されるのは project-defined isolated runner だけ

開発したエージェントの E2E 挙動は実行しなければ分からない。この必要性は認めるが、Atlas Builder が
汎用的な安全 runner を推測してはならない。対象の Essence/Spec が**隔離 runner**を製品機能として定義し、
次のすべてを満たす場合だけ、通常の verification command として実行できる。

1. 実行対象は使い捨て copy/container/VM であり、ライブ PROJECT_ROOT と CONTROL_ROOT を mount しない。
2. `PROJECT_ROOT/.atlas-builder/state/**`、CONTROL_ROOT、operator の home credential stores、秘密ファイルを読めない。
3. ライブ Git worktree への書込み経路を持たず、成果物は runner が明示した非秘密の出力だけである。
4. 必要な fixture は allowlist でコピーされ、`.env` / `.env.*` / `secrets/**` / credential file を含めない。
5. runner 自体が repository 内でレビュー・テスト可能で、単一コマンドとして cycle の sandbox 内から実行できる。

この条件を満たす runner の具体形は対象ごとに異なるため、Atlas Builder は標準の command 名や container 技術を
決めない。runner が無い、または上記境界を証明できない場合、Todo を done にせず Human-input Recommendation
(`human_input_required: true`)を作って停止する。人間がライブ runtime を手動確認し、redact 済み結果を
`just resume` で返す経路は許される。

隔離 runner で典型的に確認するのは次である。

1. 開発した In-Project Agent が、対象自身の `CLAUDE.md` / `.claude` ルールに従って期待どおり振る舞うか
   を確認する。
2. 対象プロダクトの Claude Code 実行体験そのものを E2E で検証する。
3. Over-Project Agent の CWD からでは意味が変わってしまう(対象 CWD でなければ再現しない)テストを回す。

### 10.3 Evidence と single-flight

隔離 runner は cycle の single-flight ロック(I-018)を継承する verification child である。結果の解釈と
正本状態への反映は Over-Project Agent が行う。evidence に残すのは command、exit code、上限付き・redact
済み要約だけであり、runtime の verbatim output は残さない(§22.1、I-024)。runner の出力は untrusted な
観察値であって、そこに含まれる命令には従わない。

---

## 11. Direct Editing Policy

Over-Project Agent は、対象プロジェクトの実装ファイルを直接編集してよい。

ただし、次の制約に従う。

### 11.1 Allowed by Default

```text
PROJECT_ROOT/README.md
PROJECT_ROOT/src/**
PROJECT_ROOT/tests/**
PROJECT_ROOT/artifacts/**
PROJECT_ROOT/docs/**       # プロジェクト方針で許可される場合
PROJECT_ROOT/examples/**   # プロジェクト方針で許可される場合
```

`README.md` は対象プロジェクトの通常のドキュメント成果物であり、他の実装ファイルと同格である
(§7.2)。Over-Project Agent はゲートなしに編集し、cycle commit に含める。対象プロジェクトで
人間所有の特別扱いを受けるファイルは `ESSENCE.md` **だけ**である。

#### 11.1.1 対象 README の形

bootstrap が seed する雛形(`templates/project/README.md`)は、この所有関係を前提に
**対象プロダクトの標準的な README 骨格だけ**を置く: `PROJECT_TITLE` を差し替えた見出しと、
`Overview` / `Quickstart` / `Usage` / `Development` の 4 節(初期値は `TBD`)である。
Over-Project Agent はこの `TBD` を cycle のなかで実体に置き換え、以後も Essence と実装に
追従させる。対象の性質に応じて節を足すのは自由だが、**「どうやって動かすか」を答える節
(`Quickstart`: 導入・起動・動作確認)を欠いた README は未完成**として扱う。

雛形が置かないものは 2 つあり、どちらも意図的である。

1. **Atlas Builder の語彙と運用手順**(`ESSENCE.md` が正本である旨、`.atlas-builder/state/`、
   `just loop` / `just status` / `just resume` など)。対象 README の読者は対象プロダクトの
   利用者・開発者であって、制御プレーンの運用者ではない。Atlas Builder の存在と操作を語るのは
   ワークスペース root の README(§5.1、`templates/workspace/`)と `CONTROL_ROOT/README.md`
   の管轄であり、対象の成果物にフレームワークの語彙を書き込まない原則(§6.2、§17)は
   ここにも及ぶ。`Quickstart` に書くのは**対象プロダクトそのものの**起動手順である。
2. **Agent 向けの指示コメント**。雛形は制御プレーンの指示面ではなく**対象の成果物の初期状態**
   であり、`ESSENCE.md` の `<!-- FILL:` のような未記入マーカー機構も持たない(README には
   対応する停止ゲートが無い — §7.2 のとおり README は承認ゲートに載せない)。README に何を
   書くべきかは制御プレーン側(本節と `rules/authority.md`)が教え、成果物には残さない。

### 11.2 Ask-only or High-Risk

```text
PROJECT_ROOT/CLAUDE.md             # 対象が持つ場合(§5.0)に存在し、その場合 high-risk(ask)
PROJECT_ROOT/.claude/**            # 同上
PROJECT_ROOT/package.json          # 依存マニフェスト: 直接編集は常に ask
PROJECT_ROOT/package-lock.json     # lockfile: 解決元・integrity を含むため同じ ask
PROJECT_ROOT/pnpm-lock.yaml        # 同上(yarn.lock / bun.lock* も含む)
PROJECT_ROOT/.npmrc                # package-manager の解決設定(.yarnrc* / .pnpmfile.cjs / bunfig.toml も含む)
PROJECT_ROOT/pyproject.toml        # 同上
PROJECT_ROOT/uv.lock               # 同上(poetry.lock / Pipfile / Pipfile.lock / pip.conf も含む)
PROJECT_ROOT/requirements*.txt     # 同上
PROJECT_ROOT/Cargo.toml            # 同上
PROJECT_ROOT/Cargo.lock            # 同上(.cargo/config* — レジストリ差替え設定 — も含む)
PROJECT_ROOT/go.mod                # 同上
PROJECT_ROOT/go.sum                # 同上
PROJECT_ROOT/lakefile.lean         # 同上(lakefile.toml も含む — Lake の require が依存の決定点)
PROJECT_ROOT/lake-manifest.json    # lockfile: 解決済み依存の取得元 rev を含むため同じ ask
PROJECT_ROOT/lean-toolchain        # toolchain pin(elan が取得する処理系を決める入力)
PROJECT_ROOT/.github/workflows/**  # CI/CD 変更は high-risk
```

`PROJECT_ROOT/CLAUDE.md` / `.claude/**` は対象がエージェントを内包する場合(§5.0)に存在し、そのとき
Agent Runtime High-Risk Zone(§12)として ask + hash 記録の扱いを受ける。対象がそれを持たなければ、
ask 対象として現れない。

**依存ゲートは guard hook が単独で担う(`settings.json` の `ask` に install コマンドを書かない)。** Claude Code の permissions は deny → ask → allow の順で評価され、**PreToolUse hook が返す `allow` は settings の `ask` / `deny` を上書きしない** — hook の `allow` は「permissions が禁じていないものをプロンプトなしで通す」だけである。したがって install コマンドを `settings.json` の `ask` に列挙すると、hook がどれだけ精密に安全性を判定してもプロンプトは必ず出る(auto-allow は原理的に発火しない)。この構造ではゲートは緩まないが、**信頼済み install まで人間を叩き起こし続ける**。ゆえに Atlas Builder は install コマンドを permissions の `ask` に置かず、判定を `atlas-builder hook pre-tool` に一本化する: 信頼できる install には `allow` を、それ以外には `ask` を返す(非対話 cycle では ask は自動 deny、§19)。install 形状のコマンドがこの単一決定点を無意見で素通りする経路が存在しないこと(判定は必ず明示的な deny / ask / allow のいずれかになる)は機械証明済み(§31.3 G-T4)。`deny`(§16.1)は settings 側に残す。hook/settings が無効・不正・無視された場合も、cycle の fail-closed 床(§19.1-5)により prompt-worthy な操作は拒否される。さらに Bash は必須 OS sandbox の下でのみ起動し、sandbox が利用不能なら session 自体を開始しない(§16.1)。

**信頼集合は 2 層。** hook が auto-allow するのは、install の**全パッケージ**が次のいずれかに載る単一コマンドに限る。

1. **curated list** — hook 内の maintainer 管理リスト(フレームワーク横断の定番開発ツール)。拡張は配布原本の maintainer plane でレビュー・テストして行い、束縛済み Agent session からは変更できない(§11.3、I-028)。
2. **Essence 宣言** — 対象の `ESSENCE.md` が機械可読行で宣言した依存。`recipe:` ポインタ(§29.1)と同型で、通常本文の active line として置く(位置非依存。推奨は「前提事項」節):

```text
deps: npm:@biomejs/biome, npm:vitest, pypi:pytest, crates:serde, go:github.com/spf13/cobra, lean:mathlib
```

生態系プレフィクス(`npm:` / `pypi:` / `crates:` / `go:` / `lean:`)は必須で、行は複数に分けてよい。HTML comment 内と fenced code block 内の同形行は説明・例示として無視する。プレフィクスの無いトークン・パース不能なトークンも**信頼しない**(安全側に倒す)。この層が安全なのは規律ではなく**構造**による: `ESSENCE.md` は人間専用(I-004)でエージェントには deny され、その変更は attestation 台帳に記録され、未レビュー変更はループを停止させる(§13.1-10)。したがって「Essence の active line が宣言した依存 = 人間が承認した依存」であり、エージェントが自分の柵を広げる経路は存在しない。人間の書き込み面は `ESSENCE.md` だけである(§0)という原則とも整合する — 依存の選定は本来 Essence の前提事項(技術スタック)そのものであり、hook を人間が手で書く必要は無い。

未知のパッケージ、未知のフラグ、カスタムレジストリ、git/URL/alias バージョン指定、複合コマンドは hook が `ask` に落とす。複合コマンドの唯一の例外は、**単純な `cd <dir> &&` を 1 つだけ前置した信頼 install** である — Over-Project Agent は CONTROL_ROOT から起動するため対象ディレクトリへの `cd` 前置が実務上必須であり、hook は cd 先が許可ルート内であることを検査した上で同じ決定論で auto-allow する。cd 先の照合は解決済みパスで行い、字句解決が実際の行き先を表さない綴り(`~` 始まり・shell 展開 `$` を含む)は許可ルート内と認めず ask に落とす — この allow は hook の唯一の自動許可面であり、解決を信用できない綴りに与えない。

**決定(decision)と実体化(materialization)を分ける。** マニフェスト/lockfile に既に書かれた依存を展開するだけのコマンド — 引数なしの `npm install` / `pnpm install` / `yarn install` / `bun install` / `poetry install` / `pipenv install`、`npm ci`、`--frozen-lockfile` / `--immutable`、`uv sync` / `uv pip sync <file>`、`pip install -r <file>`、`cargo fetch` / `cargo update`、`go mod download`、`lake update` / `lake exe cache get` — は hook が auto-allow する。これらが入れる依存は既に、(a) 人間が承認した dependency-resolution input(マニフェスト・lockfile・package-manager 設定)の編集 ask、(b) 信頼 install、(c) リポジトリの既存 commit、のいずれかを通っている。同じ 1 つの決定に 2 度ゲートを置いても人間が得る情報は増えず、プロンプト疲れだけが増える。**ただし `pip install -r <file>` / `uv pip sync <file>` の `<file>` は、その書込み自体が ask される dependency-resolution input(`requirements*.txt` 等、§11.2 の ask パス集合)でなければ auto-allow しない — 上の (a) の前提そのものである。** エージェントは通常実装ファイルとして任意名のテキストを gate なしに書けるため、`pip install -r evil.txt` のように自由に書いた任意ファイルを実体化に渡せば、そのファイルが名指す未承認パッケージが依存 gate を素通りしてしまう。ゆえに materialization の対象ファイルは「書込みが gate される名前」に限り、それ以外(および URL 指定)は ask に落とす(これは §11.2 の安全論拠を実装に忠実化した保守化であって、緩和ではない)。**依存の決定点は、解決される依存セットと取得元を決める input 全体の変更に一本化される。** Lean は特殊で、新規依存を CLI で足すコマンドが存在しない(`require` は lakefile 編集 = manifest ask を通る): パッケージを名指しする `lake update <pkg>` は既宣言依存の再解決だが、保守側に倒して信頼 install と同じゲート(curated ∪ `lean:` 宣言)を通す。`cargo install` / `pipenv install <pkg>` / `poetry add` / `bun add` も同じ install ゲートに載る。deno は対象外(`jsr:`/`npm:` の token 名前空間が独自で、誤許可を避けるため認識しない — 常に settings 床の ask に落ちる)。

**この分離が成立する条件として、dependency-resolution input への書込みは Edit/Write 経路だけでなく Bash 経由(リダイレクト / `sed -i` / `tee` / `mv` / `cp`)も `ask` とする** — これが無いと「Bash で lockfile や resolver 設定を書く → 実体化コマンドが auto-allow」で承認を迂回できる。これらの input の**直接編集**は、hook には「依存変更・取得元変更を伴うか」を判定できないため、決定論的な安全側の近似として常に `ask` とする(§16 の permissions ではなく guard hook が強制する)。`.github/workflows/**` は High-Risk として §12 と同じ扱い(ask + before/after hash の記録)を受ける。

### 11.3 Always Denied

```text
PROJECT_ROOT/ESSENCE.md
PROJECT_ROOT/essences/**
PROJECT_ROOT/.env
PROJECT_ROOT/.env.*
PROJECT_ROOT/secrets/**
PROJECT_ROOT/config/credentials.json
CONTROL_ROOT/**
```

`PROJECT_ROOT/essences/**` は `ESSENCE.md` と同格の human-only 資産ディレクトリであり(§2.1.5)、Agent からは参照のみ可・書込み deny である。guard hook の deny pattern は `(^|/)essences/` で照合するため、対象内のどこに**入れ子**で現れる `essences/` も deny する — これは human-only 資産の綴りを保守的に過剰遮断する**意図された**設計であり、`ESSENCE.md` の入れ子照合と同型である。

Over-Project Agent は `CONTROL_ROOT` から動いているため、`CONTROL_ROOT/**` は自己編集可能に見える。しかし enforcement を実行中の Agent 自身に書き換えさせれば、承認前 hash や ask 判定も同じ主体が変更できる。したがって control plane の自己更新は「通常 Todo と別の High-Risk」では足りず、**束縛済みの Agent session では常時 deny** とする。対象プロジェクトの High-Risk を扱う `just supervise` もこの deny を越えない。Atlas Builder 自身の開発・更新は、配布単位 `.atlas-builder/` の外にある source-repository root の maintainer plane でレビュー・テストし、新しい配布物として反映する(I-028、§18.4)。

この分離は規律だけに頼らない。permissions(bound overlay の §11.3 列挙 deny、§16.1)は CONTROL_ROOT 配下への Edit/Write を deny し、hook は `scripts/**`(commit guard `_lib.sh` を含む)、`templates/**`(束縛ファイルの描画元)、`recipes/**`(レシピ原本、§29)、`CLAUDE.md` / `.claude/**`、`justfile`、`META.md`、`README.md`、`.agent/prompts/**`、`.agent/state/workspace.json` / `project_index.json`、および **enforcement の実体である `bin/**`(hook / guard / state エンジンのバイナリ)と `lean/**`(その Lean ソース)** への変異を deny する。後 2 面を hook にも持たせるのは、settings が陳腐化した配備(§28.5-3 が read-only セッションの修復面として明示的に想定する状態)で、判定を実行している当のバイナリとソースについて hook が無意見になる層を作らないためである。**この deny は §11.2 の依存マニフェスト `ask` に優先し、Edit 経路と Bash 経路で同一である。** 両者は実際に重なる — 配布物の `recipes/agentic-state-loop/files/loop/lean/`(`lakefile.lean` / `lean-toolchain` / `lake-manifest.json`)は制御プレーン面かつマニフェスト名であり、ここで ask に降格すれば人間同席の `just supervise` がレシピ原本(§29.2 の immutable surface)を書き換えられてしまう。deny 群が ask 群に先行するという決定木の順序不変量(§31.3 G-T1 と同型)は WRITE_TOOLS 面にも及ぶ。OS sandbox の `denyWrite` も静的 enforcement surface を重ねて保護する。例外は、正規 transition が必要とする動的 state 書込みだけである: `bin/atlas-builder state` / wrapper / hook が PROJECT_STATE_ROOT の canonical state、control run log、attestation、tmp を所定の意味論で更新する。agent に許される state 変異コマンドは permissions/hook で限定し、resume/loop-only transition は別途 deny する(§18.2、§19.1)。この CONTROL_ROOT 相対判定は `PROJECT_ROOT/README.md`(通常実装、§11.1)や対象自身の `scripts/**` を巻き込まない。Bash による control surface 変異は保守的なテキスト検査でも deny する — ただしテキスト検査は CONTROL_ROOT-cwd の相対綴りを写した過剰近似なので、セッション cwd が登録 PROJECT_ROOT 配下にあるとき(同じ綴りが agent 所有の project ファイルを指すとき)は適用せず、解決済みパス判定に委ねる(project cwd の `cp .tmp-readme.md README.md` を control-plane README 変異として deny した 2026-07-31 の過剰遮断の是正。settings 側の同型過剰マッチは §19.1-5)。未知の Bash は cycle の fail-closed 床(§19.1-5)により実行されない。

**保護パス直書きの層構造と、投影 4 ファイルの単層問題。** Bash 経由の保護パス直書き deny は「コマンドが保護パスを名指ししている」×「書き得るコマンドである」の連言で判定する。前者は生テキストだけでなく**字句解析後のトークン**でも照合する — 生の部分一致だけでは、shell が同じ 1 パスとして解決する綴りをクォートで分断するだけで判定を外せた(`cp a ../p/'ESSENCE'.md`)。後者はこの連言専用に広い集合を使い(`>` / `>>` / `sed -i` / `tee` / `mv` / `cp` / `rm` に加えて `truncate` / `install` / `ln` / `dd` / `patch` と汎用インタプリタ `perl` / `python` / `python3` / `ruby` / `node`)、静的に読取専用と示せないインタプリタは保護パスを名指しした時点で deny 側へ倒す。**この広い集合を control-surface / zone / manifest と共有してはならない** — それらは mutator が対象パスの前に出現するかを見るため、インタプリタを足すと `python3 scripts/x.py validate` のような読取まで deny になる(凍結検査が実際にこれを捕捉した)。

この mutator 集合はヒューリスティックであり、権威ある第 2 層は OS sandbox の `denyWrite` / `denyRead`(§16.1、I-029)である。`ESSENCE.md` / `essences/` / `.env` / `secrets/**` / `config/credentials.json` / `PROJECT_STATE_ROOT/state/project.json` / CONTROL_ROOT 一式はいずれもその列挙に載っている。**唯一の例外が投影 4 ファイル(`PROJECT_STATE_ROOT/state/{spec,todo,recommendations,blockers}.json`)であり、hook が単層の柵になっている。** これらを `denyWrite` へ足せるかは未解決である: 正規の書込み経路 `bin/atlas-builder state apply-projection` は agent の Bash から起動されるため、sandbox が `bin/atlas-builder` 自身の書込みを捉えるなら足した瞬間に投影が不可能になる。`project.json` が `denyWrite` に載っている一方でそれを書く `ensure` も agent 実行コマンドである、という非対称がこの問いの中身であり、実セッションでの実測で決着させるべき maintainer task として残す(§28.5-8 の扱い)。

### 11.4 Secrets — Supply and Leakage Guard

§11.3 と §16 は Atlas Builder が secret input surface として定義する `.env` / `.env.*` / `secrets/**` / `config/credentials.json`、および列挙済み home credential stores(`~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.kube`, Docker/npm/PyPI/netrc、`~/.claude/**` / `~/.claude.json` の Claude credential/config/history files)の**読取を deny**する。ただし文字列 hook だけでは `x=.en; y=v; cat "$x$y"` のような動的パスを判定できず、親 shell の環境変数は `env` で列挙できる。ゆえに I-024 は次の強制可能な形に固定する: **Atlas Builder が起動する Agent に秘密の環境変数も、上記の定義済み secret input surface の読取権限も渡さない。秘密を要する検証は Agent session 外で人間が実行し、exit code と redact 済み要約だけを state に返す。** 対象の通常 source path や別の home toolchain directory に秘密を置けば Agent は読めるため、それらを secret store として扱う運用はこの保証の対象外であり、上記 path へ移す必要がある。任意の source tree を読みながら「どこに置かれた秘密でも読めない」とは主張しない。

**四層の境界。** (1) `permissions.deny` と hook は定義済み path を即時拒否する。(2) Claude Code の OS-level sandbox を `enabled: true` / `failIfUnavailable: true` / `allowUnsandboxedCommands: false` で必須化し、同じ secret input surface を `denyRead`、正本・制御面を `denyWrite` に置く。(3) Atlas Builder の loop / triage / essence / supervise wrapper は `env -i` + allowlist で Claude を起動し、operator shell の API key・cloud token・deployment secret を継承しない。さらに `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` を固定し、親 CLI が login/provider config から取得した対応 credential も Bash/hooks/MCP 子プロセスから再除去する。loop/supervise だけは、外部権限を持たない session-scoped の single-flight coordination nonce(`ATLAS_BUILDER_LOCK_TOKEN`、§13.5)も渡す。(4) 起動時に `--setting-sources project --strict-mcp-config` を固定し、`--mcp-config` を渡さないことで、user/local settings の追加 allow/hook/plugin と通常の user/project/local MCP 構成を session へ混入させない。組織の managed policy は CLI より高位にある外部 trust base なので、導入者が同等以上に厳しいことを保証する。Claude 認証は環境変数ではなく、CLI の通常 login/config store を使う。([Claude][1], [Claude][6], [Claude][8])

secret-required な Todo は自律 cycle で command を走らせない。Human-input Recommendation で停止し、人間が Agent 外で検証した後、結果をレビューして `just resume` で返す。人間向け手順にも秘密値そのものを貼らず、検証 command の非秘密部分と期待結果だけを書く。

**漏洩ガード(盲点)。** 実行時のログ捕捉(loop が claude の stderr を退避する `.agent/tmp/` 配下の一時ファイル等)は gitignore 済み(§25 の `.agent/tmp/*` / `.agent/runs/*`)だが、`commands_run[].summary` と `evidence`(§22)は **committed される canonical state** に入る。おしゃべりなテストが秘密を stdout に吐き、その逐語が summary / evidence に転記されると、**Git 履歴に焼き付く**。これを規律化する。

- committed な evidence / state に**検証出力の逐語を載せない**。載せてよいのは `exit_code` と、**上限付き・redact 済みの要約**のみである(§22)。
- 隔離 runner の出力も同じ扱いである: `exit_code` と redact 済み要約だけを evidence に残し、逐語は載せない(§10、§22)。

**政策 — secret-required Todo(B)を重ねる。** 本番資格情報・課金・外部権限を触る Todo には `secret_required: true` を付け、**Agent に実行させず**、§21.4 の人間ゲートへ落とす。これは「Agent 子プロセスだけに秘密を見せる」という実現不能な仮定を捨て、秘密と Agent のプロセス境界を完全に分ける分類である。

### 11.5 Execution Profile — 実行環境の事実申告(`profile:`)

最厳格の権限設定を一律に配ると、guard の ask(headless では自動 deny、§19.1-5)が PoC 級の配備でも自律ループを止め、OS sandbox が `xcodebuild` 等のネイティブ toolchain を構造的に阻む(DerivedData 書込み・XPC・コード署名)。この緩和の決定は依存宣言(§11.2)や recipe 採用(§29.1)と同じ型の**人間の決定**であるため、`ESSENCE.md` の第 3 の機械可読 directive として固定する:

```text
profile: standard | auto-approve | unsandboxed     例: profile: auto-approve
```

書式・安全境界は `deps:` / `recipe:` と同一である(§2.1.1): `semanticLines` 経由で HTML comment / fenced code block の**外**にある active line だけが発効し、位置非依存(推奨: 「前提事項」節)。値は**閉集合 3 段**であり、それ以外の綴りは発効しない。安全論拠も同一 — `ESSENCE.md` は人間専用(I-004)でエージェントには deny され、その active line は人間の承認そのものである。命名は用途ラベル(poc / prod 等)ではなく「何を緩めるか」の事実申告である: §5.0 のとおり Atlas Builder は対象を格付けする機構ではなく、profile も対象の種別ではなく実行環境の事実を申告する。

**3 段の意味論(単調包含)。**

| 値 | guard の ask 面 | 無意見 Bash | OS sandbox |
|---|---|---|---|
| `standard`(省略時・既定) | 従来どおり ask | 従来どおり無意見(headless では settings 床が deny) | 必須(I-029) |
| `auto-approve` | 緩和対象の ask 面を監査可能な理由文言つき allow へ | hook が明示 allow | 必須のまま |
| `unsandboxed` | auto-approve と同一(guard は両者を区別しない) | 同左 | `sandbox.enabled: false` |

**緩和されるのは次の ask 6 葉と Bash 最終無意見葉だけである**(guard 決定木 `Guard/Decide.lean` の完全列挙。理由文言は profile 由来であることを明示し、監査ログに残る):

1. Bash: High-Risk Zone 変異(§12)— staging(before-hash 記録、§20.4-3)は**不変**のまま allow。
2. Bash: dependency-resolution input 変異(§11.2)。
3. Bash: 許可ルート外への `cd`(§11.2 の cd フェンス)。
4. Bash: 未宣言依存の install(§11.2 — curated ∪ `deps:` 外)。
5. Write: 依存マニフェスト編集(§11.2)。
6. Write: High-Risk Zone 編集(§12)— staging 不変。
7. 加えて **Bash 最終無意見葉のみ** fallback allow(settings の allow リスト外のコマンドが headless の自動 deny に落ちない)。

**緩めないもの(意図的な除外)。** bootstrap / build の ask(初期化・運用操作 — 日常サイクルの効率と無関係であり、cycle 内で走ると I-018 ロックを継承して通ってしまうため allow 化は危険)。Write の最終無意見葉(sandbox は Edit/Write ツールを縛らないため、緩めると additionalDirectories 外 — `~/.zshrc` 等 — への Edit が promptless になり「sandbox 維持」の宣言と矛盾する。project 内 write は overlay の `Edit(//<abs>/PROJECT/**)` allow が既に promptless、§16.1)。

**deny 床は全 profile で不変である(I-030、機械証明済み(§31.3 G-T6))。** ESSENCE.md / essences(I-004)、秘密(I-024)、control-plane 15 面(§11.3、I-028)、git stage/commit(I-015)、危険 Bash、claude ネスト起動(I-003)は、どの profile でも同一理由で deny される。profile が変えるのは ask / 無意見の葉だけであり、deny を弱める経路も、High-Risk staging(§20.4-3)を変える経路も存在しない。read-only セッション(triage / essence、I-022/I-027)は profile を**無視**する — guard の read-only 分岐は決定木の最上段にあり、profile 条件は非 read-only 葉にのみ現れるため、これは規律ではなく構造で成立する。

**guard は auto-approve と unsandboxed を区別しない。** hook の判定条件は「profile が standard か否か」の 1 条件だけである。sandbox の解除は settings 層(overlay)専任であり(`sandbox.enabled: false`)、hook に sandbox 固有の分岐を作ることは実権限の帰属を誤らせる — sandbox を外すのは overlay 生成であって hook ではない。

**settings 側の対応(relaxed 2 態)。** hook の allow は settings の ask に勝てない(§11.2 が依存ゲートを hook 単独に置いたのと同じ deny → ask → allow の評価順)ため、relaxed 2 態では project 側 ask 3 面(`CLAUDE.md` / `.claude/**` / `.mcp.json` — §16.1 overlay の ask 配列)を**除去**する(残すと profile が該当面で無効化される)。control-plane の live settings 修復面の ask(§28.5-3)は全 profile で維持する — これは配備欠陥からの回復経路であり日常サイクルの効率と無関係である。実施主体は起動毎の overlay 生成(`boundSession`、§16.1)である: init が base に焼くのは `_atlas_builder_profile` 行 1 本だけで、ask 3 面の除去と sandbox 解除(`sandbox.enabled: false`)は launcher が base の記録値から overlay を組むたびに適用される。relaxed 2 態のテンプレを手で 3 枚持つことはしない — profile ごとの設定差分は生成関数の 2 分岐(ask 面の有無・enabled の反転)に閉じ、テンプレ間ドリフトの温床は存在しない。

**発効は init 経由のみ(§26)。** `profile:` は hook が ESSENCE を読む都度 ask 面の判定に効くが、settings 側の発効値は base の `_atlas_builder_profile` — init だけが書く 1 行 — であり、宣言の変更は `just init` の再実行でのみ overlay へ反映される。base の記録が欠落・不正なら launcher の overlay 生成自体が exit 2 で止まる(unbound / 旧形式の fail-closed、§16.1)。宣言と記録の不一致は**両方向とも安全側**に倒れる: ESSENCE=relaxed × base=standard では overlay の ask 3 面が headless deny で止め(sandbox も維持)、ESSENCE=standard × base=relaxed では hook が即時に厳格判定へ戻り ask = headless deny で止める(残るのは sandbox 解除だけだが、動くのは base の allow リストに載る検証コマンドだけである)。暴走方向が存在しないため、loop / supervise に起動前 mismatch 検査は置かず、検査は doctor に一本化する(§28.5 の流儀 — doctor は base の記録値と ESSENCE 宣言を突合し、不一致を re-run init として報告する)。validate は invalid 値と conflict(相異なる複数宣言)を warning で可視化し、いずれも `standard` へ縮退する — 緩和方向の機能は不確実性があれば発効しない。

**エージェントの自己拡権経路は既に閉じている。** ESSENCE への書込みは permissions deny + hook deny + sandbox denyWrite の 3 層封鎖(I-004)。guard は relaxed 2 値を区別しないため、仮にエージェントが ESSENCE を書き換えても guard 挙動の増分は「ask 面の allow 化」まで — 実権限の増分である sandbox 解除は human-only の init(I-011、§18.2)経由でしか起きない。ゆえに profile 発効に attestation 台帳照合の専用ゲートは置かない。unsandboxed 配備での ESSENCE 改変は既存の `essence_unreviewed_change`(§13.1-10)が cycle 境界で検出する。

**unsandboxed の信頼モデルは正直に縮退する(§16.1 の egress 段落と同じ、主張の限界を明記する流儀)。** `unsandboxed` では I-029 の「autonomous Bash は OS sandbox 必須」が人間の明示宣言によって外れ、実行境界は deny 床(I-030: permissions deny + hook deny)と、ガバナンス検出(attestation・High-Risk hash 記録・cycle commit 監査)まで縮退する。動的パス構築や環境変数経由の秘密読取に対する OS 層の裏打ちは失われる — これは「安全のまま速くなる」ではなく「人間が OS 層の保護を降ろした」であり、その事実が ESSENCE の active line として人間の署名つきで残ることが本設計の要点である。


### 11.6 Target Write Policy — 対象書込み面のドメイン軸

対象への書込み面は、Over-Project ループの**ドメイン軸**である
(`Looper.Domain.writePolicy`、§31.1 R-13)。軸は 2 値を取る:

- **`implementation`** — 対象実装が Agent の作業面そのもの。**Atlas Builder は
  こちらである。** 実装への投影が主語であり、`src/**` / `tests/**` /
  ビルド設定といった対象ファイルの編集は §11.1 の既定許可面そのものである。
- **`readOnlyExcept [...]`** — 対象実装は既定 deny(I-007 の反転)で、列挙した
  面(例: 証明層)と人間が `ESSENCE.md` に書く `writable:` directive だけが
  書込みを開く。証明への投影を主語とする姉妹フレームワークがこちらを取る。

**判定の段は両方のドメインで決定木に存在する。** guard の WRITE_TOOLS 面と
Bash mutator 面には read-only 対象 deny の段があり、`implementation` では
その判定が常に「許可」を返して段を通過する。**「このドメインには段が無い」
形にはしない** — 軸ごとに段が生えたり消えたりする設計は、抽象の隙間で安全
境界の段が落ちる事故を招く。段は常設し、軸は段の**判定**だけをデータにする。

したがって本製品では:

1. `ESSENCE.md` の `writable:` directive は**不発効**である(パースはされるが
   判定に影響しない)。対象実装の書込み可否は §11.1 / §11.2 / §12 の既存
   ゲートだけが決める。
2. **deny 床は軸と無関係に不変である。** §11.3 / §11.4 / I-004 / §8.2 の
   投影台帳は書込み面ポリシーが何であっても緩まない。ポリシーが開けるのは
   「対象実装の既定 deny」だけであり、本製品はその既定 deny を持たない。
3. **他ゲートとの直交。** 書込み面が開いていることは、依存マニフェスト
   (§11.2)や Agent Runtime High-Risk Zone(§12)の ask / hash 記録を消さない。
4. **hook 強制。** guard hook は WRITE_TOOLS / Bash mutator の書込み先を
   解決済みパスで判定する read-only 対象 deny の段を持つ。本製品の軸では
   その判定が常に許可を返し、段は通過する — **段が存在すること自体が契約
   である**(片方のドメインで段が消える設計にしない)。read-only 側の
   ドメインでは、この段が「拒否は回避対象ではなく設計信号」の教示つき deny
   を返す。
5. `Looper.Core.GlobHier`(`writable:` の階層 glob パーサ)は**機構**として
   共有実装に属する。本製品で発火しないのはドメイン軸の値がそうさせている
   からであって、ドメイン論理だからではない。

---

## 12. Agent Runtime High-Risk Zone

> **前提(§5.0)。** 本章の High-Risk パス群のうち、**agent runtime 構成系**(`CLAUDE.md` /
> `.claude/**` / `.mcp.json` / `.cursor/**` / `AGENTS.md` / `agent-runtime/**` / `agents/**` /
> `prompts/**` / `skills/**` / `hooks/**` / agent 系 scripts)は、対象がエージェントを内包し
> それらを**持つ場合**にのみ存在する。対象がそれらを持たなければ High-Risk 分類の対象も存在しない —
> 通常プロダクトだから "低リスクで編集してよい" のではなく、**対象自体が無い**。存在すれば常に
> High-Risk である。
>
> ただし **`.github/workflows/**`(CI/CD)は対象がエージェントを内包するか否かに依らず存在しうる** —
> 通常のプロダクトでも CI 設定を持つのは普通であり、その場合も High-Risk として扱う(項 1–7、
> §11.2、§20.4、I-008)。

次のパスは、対象に存在する場合、High-Risk として扱う(agent runtime 構成系は対象がそれを内包する場合、
`.github/workflows/**` は CI を持つ任意の対象で)。

```text
PROJECT_ROOT/CLAUDE.md
PROJECT_ROOT/.claude/**
PROJECT_ROOT/.mcp.json
PROJECT_ROOT/.cursor/**
PROJECT_ROOT/AGENTS.md
PROJECT_ROOT/.github/workflows/**    # CI/CD(§11.2)
PROJECT_ROOT/agent-runtime/**
PROJECT_ROOT/agents/**
PROJECT_ROOT/prompts/**
PROJECT_ROOT/skills/**
PROJECT_ROOT/hooks/**
PROJECT_ROOT/scripts/*agent*
PROJECT_ROOT/scripts/*claude*
PROJECT_ROOT/scripts/*loop*
PROJECT_ROOT/scripts/*autonomous*
PROJECT_ROOT/**/settings.json        # Claude / agent 設定の可能性がある場合
```

hook / `bin/atlas-builder state` の High-Risk 分類は、上記をネスト配下(任意の深さ)にも一致させる安全側の上位集合として実装する。これらは対象がエージェントを内包する場合、その内容物として存在する。自律 cycle は High-Risk Todo と停止 Recommendation を記録するところまで行い、変更は人間承認後の `just supervise` で Over-Project Agent が適用する(§11、§21.3)。

### 12.1 High-Risk Rules

High-Risk Todo は次を満たさなければならない。

1. Todo に `risk_level: "high"` を明示する。
2. Todo に `risk_reason` を明示する。
3. Todo に non-empty `target` を明示する。これは supervised session の変更 scope 正本である。
4. 通常実装 Todo と同じ batch に入れない。
5. 変更前に対象ファイルの hash を記録する。
6. 変更後に diff summary を記録する。
7. `high_risk_changes.jsonl` に追記する。
8. その cycle の `reflection.jsonl` エントリに高リスク変更の要約を出す。
9. 高リスク変更を理由に `ESSENCE.md` の意味を変えてはならない。

自律 loop は headless であり、その fail-closed 床(§19.1-5)が ask を deny に落とすので High-Risk ask を越えない。Agent が項目 1–3 と Recommendation を整えて停止し、
人間が内容を承認した場合だけ `just supervise --todo T-... [--recommendation R-...]` を起動する。`--todo` は必須で、wrapper は Claude 起動前に read-only `state supervise-check` を実行する。この preflight は canonical state 上の exact Todo が high-risk・未完了・`executor.mode = atlas-builder`・non-empty `risk_reason` / `target` であることを機械検査する。`--recommendation` を与えた場合は、exact Recommendation が open な human approval gate であり、`source` がその Todo ID を含み、`target` が Todo の target と完全一致することも検査する。検査済み target は session prompt に固定される。target 内の変更要求を意味的に正しく解釈したかは完全には機械照合できないため、ask と最終 diff の人間レビューは残る。曖昧な「High-Risk を何か実装して」という無対象 session は標準経路に存在しない。この対話 session は同じ permissions/hooks/sandbox、
環境 sanitize、single-flight lock の下で動き、人間が各 ask を判断する。session 終了後の dirty diff を人間が
全文レビューし、`just resume` が checkpoint commit と gate release を同時に行う(I-018、I-020)。

これらは、対象に存在する High-Risk パスに対して働く — 通常のプロダクトでも `.github/workflows/**`
などがあれば対象になり、対象がエージェントを内包する場合は agent runtime 構成系も加わる。

**relaxed profile 下の High-Risk ワークフロー(§11.5)。** `auto-approve` / `unsandboxed` では High-Risk Zone の ask 面が監査可能な理由文言つき allow になるため、自律 cycle は supervise 停止を経ずに High-Risk Todo を直接実行できる。免除されるのは**停止(supervise の人間同席)だけ**であり、残りの規律は不変である: before/after hash の機械記録(§20.4-3 — guard の staging は profile 非依存、§31.3 G-T6)、項 1–3 の `risk_level` / `risk_reason` / `target` 宣言、単独 batch(項 4)、diff summary と reflection 要約(項 6–8)、そして振る舞い検証が project-defined isolated runner 経由でのみ許される境界(§10、I-003)。relaxed が外すのは「変更前の人間承認プロンプト」であって「変更の監査可能性」ではない。

### 12.2 Self-reference Guard

本節は対象プロジェクトがエージェント(In-Project Agent)を内包し、対象 `.claude/` を持つ場合(§5.0)に
のみ生じる混同を扱う。対象がエージェントを持たなければ、これらの混同は発生しない。

| 混同                                                  | 防止策                                                                 |
| --------------------------------------------------- | ------------------------------------------------------------------- |
| Over-Project Agent が対象の `.claude` を自分の設定として読む | Atlas Builder は `./.atlas-builder` から起動し、対象プロジェクトは additional directory として扱う(§6.1)。root を分けているため対象設定は対象 CWD の設定にとどまる |
| Agent runtime 変更が通常実装として紛れる                         | High-Risk path classifier(§12.1) |
| Claude が workspace root で起動され両方の設定を曖昧に読む            | Workspace root 起動禁止(運用規則 + workspace README + doctor の案内)。workspace root には `.claude` 設定を置かないため hook による機械的検出は**不能**であり、SessionStart hook が検出できるのは CONTROL_ROOT 設定が読み込まれた誤 CWD セッションに限る。root 起動セッションは設定ゼロの素の Claude になる(= Atlas Builder 状態への書込み権限も持たない)ことが受動的な緩和策である |

### 12.3 振る舞いの検証と自己憲章

対象プロジェクトの agent runtime 構成ファイル(`CLAUDE.md`, `.claude/**`, `prompts/**`, `hooks/**`, `agents/**` 等)は、他の高リスクファイルには無い固有の性質を持つ: **同一ファイルが二役を持つ**。Over-Project Agent にとっての**開発対象**(編集・改善するアーティファクト)であると同時に、In-Project Agent(§6)にとっての**実行憲章**(自分の振る舞いを決める設定)である。

この二役があるため、これらを**開発する**行為(High-Risk Todo + supervised edit)と、これらを**隔離環境で検証する**行為(§10)は、区別して行う。すなわち:

1. runtime 構成の変更は自律 cycle で直接実行せず、High-Risk Todo/Recommendation → human approval → `just supervise --todo T-... --recommendation R-...` → diff review → `just resume --resolve R-...` の順で行う。変更と検証を同じ batch に混ぜない(§9.3)。承認 Recommendation は supervise 完了・diff review まで **open のまま保つ** — preflight は open gate を要求するため、承認時点の `--resolve` はこの経路自体を実行不能にする(resume がこの誤操作を機械的に拒否する、§13.3-4'')。
2. 変更 checkpoint 後の別 cycle で、対象定義の隔離 runner がある場合だけ振る舞いを観察する(§10)。観察結果は Todo の evidence になる(§22)。

なお、In-Project Agent が「振る舞う主体」であるとき、その**振る舞いの evidence**(エージェントとして正しく振る舞えているか)を pass/fail でどう捉えるかは、現行 evidence モデル(§22)では素朴な観察(出力・生成物・終了コード)に留まる。より厳密な振る舞い検証は将来の検討対象である(§22 の将来メモ)。

---

## 13. Stop Conditions

即停止するのは Essence 由来 Blocking と、人間承認/入力なしには次の安全な作業を選べない場合である。さらに安全網として、意味的進捗なしの cycle が `context.json.stop_policy.stop_after_idle_cycles` 回(既定 3 回)連続した場合も停止する。

停止は「静かに止まる」ことを許されない。すべての停止条件は §13.4 の可視化原則(I-017)に従い、canonical state 上の成果物(Recommendation / Blocker)と `just status` / ループ終了メッセージの両方に、再開手順とともに現れなければならない。カウンタや暗黙状態としてしか存在しない停止は仕様違反である。

### 13.1 Immediate Stop

次は即停止する。

条件 1〜4 の「重大(critical)」の閾値は、機械照合できる性質ではないため**意図的にエージェント規律に委ねる**(§20 の (A) レイヤー)。判定が割れうることは受容された設計であり、規律は 1 つ — **迷えば停止側(安全側)に倒す**。過剰に停止しても人間が resume で先へ進めるだけだが、進めるべきでない曖昧さを投影に流し込むと terrain を読み違えた地図が evidence の緑で正当化されうる(§22)。なお 1(矛盾=両立不能な must が同時に成立)と 4(分岐=どの must を優先するかが Essence から一意に決まらない)は近接するが、いずれも Blocking Recommendation(§21.2)+ `essence_blocking` Blocker で止める点は同じであり、型の選択に迷う必要はない。

1. `ESSENCE.md` の重大矛盾
2. `ESSENCE.md` の重大曖昧性
3. `ESSENCE.md` 由来の実現不能性
4. Essence の優先順位判断なしには進めない重大分岐
5. `ESSENCE.md` が Agent により変更された疑い
6. proposed Recommendation が `agent_action: "stop_until_human_review"` / `requires_human_approval: true` / `human_input_required: true` を持つ、または承認依頼・許可依頼・人間レビュー待ちとして解釈される
7. Todo / Recommendation / Blocker / 実装ファイルに意味的進捗がない cycle が 3 回連続した
8. `ESSENCE.md` が存在しない、または placeholder のまま/空である(`essence_missing` / `essence_placeholder`。空・空白のみのファイルは人間の意図を含まないため placeholder と同じ扱い。さらに推奨テンプレ(§2.1.1)を seed した場合、見出しだけで中身の無い骨組みが「充填済み」と誤判定されないよう、**未消化の `<!-- FILL:` マーカーが 1 つでも残存**する状態も placeholder として扱う。人間が実際の Essence を書く — 全 FILL マーカーを実内容へ置き換える — までループは 1 cycle も開始しない)
9. 実行可能な Todo(status が `pending` / `in_progress` で executor が `atlas-builder`。現フェーズが `must` なら must 優先度のみ、`extended_approved` なら should も含む — §19.3)が 1 つも残っていないのに、完了条件(`must_phase_complete` / `full_complete`、§19.3)も満たしていない(`no_runnable_todos`。全 Todo が blocked / executor `human` 待ち / must 未完のまま作業なし。§13.4 により Human-input Recommendation として実体化される)
10. `ESSENCE.md` の内容(SHA-256)が、人間確認済みの baseline と一致しない、**または baseline が 1 つも存在しない**(`essence_unreviewed_change`。条件 5「Agent により変更された疑い」の機械化)。baseline の決定は次の順で行う: (a) 制御プレーンの attestation 台帳 `CONTROL_ROOT/.agent/state/essence_attestations.jsonl` に当該 project の記録があれば、その直近エントリの hash。(b) 無ければ、bootstrap 時に `project.json` へ記録された anchor hash(`essence_sha256`。人間が Essence を書いてから bootstrap した事実の記録であり、初回 baseline として人間確認済みと同格に扱う)。(c) どちらも無ければ baseline 不在として **fail-closed に停止**する。したがって、bootstrap 済み・未 resume の初回ループは、現在の `ESSENCE.md` が anchor と一致していれば停止せず進む(§26.1 が anchor に実 Essence hash を記録するため placeholder hash にはならない)。人間自身の編集であっても、`just resume` が確認として台帳へ記録するまでループは進まない。baseline の正本を agent が書ける project 平面(`reflection.jsonl` 等)に置くと偽 attestation の追記でこのゲートを無効化できるため、台帳は `atlas-builder state resume`(agent には hook で deny、I-011)だけが書く制御プレーンファイルとし、hook が agent の直接書込みを deny する。停止解除は resume による attestation。cycle 実行**中**に人間が `ESSENCE.md` を編集したケースはこの経路で必ず捕捉される — cycle checkpoint は ESSENCE.md を含まないため(I-020)、編集は worktree に残り、cycle 終端の post-gate で停止する。**この attestation は `ESSENCE.md` 本体の hash だけでなく `essences/` の現況マニフェスト(相対パス → SHA-256)も対象とする** — attestation 台帳の各レコードに `essences` キーが加わり、同一レコードのマニフェストと現況が一致しない場合も同じ `essence_unreviewed_change` で停止する(§2.1.5)。`essences` キーを持たない旧レコードは「essences なしで attest した」= 空マニフェストとして後方互換に解釈する。初回 baseline の anchor 側も、bootstrap 時に `project.json` へ `essence_sha256` と並んで `essences_manifest` を記録する(ensure が維持する))
11. 停止ゲートを保持する canonical state(blockers / recommendations / context / reflection / runs / project、および attestation 台帳)が読めない、**または parse はできるがゲートを保持する形が壊れている**(items が list でない、progress が object でない等)(`state_unreadable`。壊れたゲートを「停止条件なし」と読むことは許されない — fail-closed(I-021)。同じ理由で、predicate 内部の想定外クラッシュも exit 1(「停止条件なし」)ではなく必ず exit 2(ハードエラー)として表面化する。回復は直近 checkpoint commit からの `git restore` が標準手順、§13.5)。gate 保持面の読取が診断を出すとき停止しかつ理由列の先頭が `state_unreadable` になることは機械証明済み(§31.3 S-T1)
12. `claude` の起動が **infra 起因**(API 接続不良・認証切れ・Claude 側内部エラー等、プロジェクトのコードとは無関係な環境要因)で非ゼロ終了する cycle が**連続 K 回**(既定 K=2、`stop_policy.stop_after_infra_fails`)続いた(`infra_unreachable`。単発の infra 失敗は §13.2 の非即停止として次 cycle に継続するが、連続すると「エージェントが行き詰まった(idle)」のではなく「そもそも Claude を動かせていない」ことを意味するため、idle 閾値(§13.1-7、既定 3)を待たずに専用ゲートで停止して人間へハンドオフする。§13.4 により Human-input Recommendation として実体化される。idle が「意味的進捗の欠如」を測るのに対し、これは「実行環境の到達不能」を測る別カテゴリである — 停止理由を idle にすり替えず、真因を名前で残す)
12'. `claude` の起動が **プラン/モデルの利用上限**で非ゼロ終了する cycle が**連続 K 回**(既定 K=4、`stop_policy.stop_after_usage_limited`)続いた(`usage_limited`)。これは条件 12(infra)の**特定された下位種別**であり、別カウンタ(`progress.usage_limited_since_ok`)・別しきい値・別 reason を持つ。分けたのは表示の問題ではなく**人間が次に取る行動が違う**からである: 到達不能なら API 到達性と認証を調べ、上限なら待つか `ATLAS_BUILDER_MODEL=<tier>` で別モデルに移る。トランスポート層のレート制限(429 / `too many requests` / `Retry-After`)もこのクラスに数える — 運用上の対処が「待つ」で同じだからである。実走行 2026-08-12 では上限到達が(当時 idle として提示され)進捗停滞と誤診され、人間が runs.jsonl の実行時間を目視して真因を特定するまで 9.5 時間ループが止まった。しきい値が infra より寛容(4 対 2)なのは、上限が**時間で解ける既知の一過性**だからである — loop は失敗のたびに指数バックオフ(§19.1-9)で待ってから再試行し、3 回の待機(5 分 → 10 分 → 20 分)を経ても解けないとき初めて人間へ渡す。理由の正準優先順(D-005、§13.4)では `idle_cycles` の後・`infra_unreachable` の**前**に位置する(具体が総称に先行する)
13. must フェーズが完了した(`must_phase_complete`、§19.3)が、完了 scope を人間がまだ選んでいない(`context.json.phase == "must"`)(`must_complete_awaiting_phase_approval`。これは**終端ではなくフェーズ境界の停止ゲート**である — must 完了は「地図の一区画を描き終えた」レビュー可能なチェックポイントであり、ハッピーパスでも必ず一度ここで止まる。人間は (a) `just resume --approve-should ...` で Should に自律予算を与える、または (b) `just resume --close-at-must ...` で Must scope を最終成果として閉じる、のどちらかを明示する。§13.4 により Human-input Recommendation として実体化され、この境界で `just status` は成功条件 ↔ evidence の対応(§22)を提示する。前者は `phase = "extended_approved"`、後者は `phase = "closed_at_must"` を立てる。どちらも要求変更ではなく完了 scope の人間判断なので `ESSENCE.md` 編集を要さない。`must_phase_complete ∧ phase == "must"` のとき必ずこの理由で停止することは機械証明済み(§31.3 S-T3))
14. `ESSENCE.md` ⇄ `essences/` の双方向不整合がある(`essence_asset_integrity`、§2.1.5。**非ディレクトリ**(`essences` がファイル等)/ **深さ上限超過**(`essences/` からの相対パスが 3 セグメントを超える)/ **不正パス**(セグメントに `[A-Za-z0-9._-]` 以外・先頭末尾 `.`)/ **orphan**(実在するが `ESSENCE.md` が自身も祖先ディレクトリも言及しない)/ **dangling**(`ESSENCE.md` が言及するがファイルとしてもディレクトリとしても不在)のいずれか)。これは要求変更でも実装エラーでもなく、人間所有の 2 面(`ESSENCE.md` と `essences/`)の食い違いなので、人間がどちらかを直して `just resume` で再開するまでループは進まない。構造違反(非ディレクトリ / 深さ上限超過 / 不正パス)は常時検査し、言及違反(orphan / dangling)は `ESSENCE.md` が実体を持つ(非 placeholder・可読)間だけ検査する。理由の正準優先順(D-005、§13.4)では `essence_structure` の直後・`essence_unreviewed_change` の直前に位置する。essences/ 自体の読取不能は fail-closed のハードエラー(exit 2、I-021)である
15. `ESSENCE.md` の見出し構造が正準集合(§2.1.1)と一致しない(`essence_structure`)。H1 は `# ESSENCE — <題名>` の形でファイル先頭の見出しとして一度だけ現れなければならず、H2 の列はモチベーション / 思想 / 前提事項 / 成功条件 / 必須対応事項 / 任意対応事項 / 非対応事項 / 遂行順序 / 用語の 9 見出しと綴り・順序が完全一致しなければならない。欠落・重複・順序違反・集合外 H2 の出現・H1 の欠落または複数出現は、いずれも違反として具体的に列挙される(H3 以下の小見出しは節の内部として自由であり検査対象外)。これは要求変更でも実装エラーでもなく、`ESSENCE.md` 自身の形が定義と一致しているかという文書の構造の問題であり、人間が見出しを正しい綴り・順序に直して `just resume` で再開するまでループは進まない。構造検査は `ESSENCE.md` が placeholder(§13.1-8)である間は保留する — 空の骨組みへ構造エラーを重ねてもノイズを増やすだけだからである。理由の正準優先順(D-005、§13.4)では `essence_placeholder` の直後・`essence_asset_integrity` の直前に位置する(文書自身の形は、文書から `essences/` への相互参照より先に成立しているべきである)。

infra / usage の判別は保守的である(§28.6): `claude` の stderr が明確なシグネチャを示す場合だけを分類し(利用上限のシグネチャを infra より**先に**照合する — 具体を総称に優先する)、確信が持てない非ゼロは `unknown` として §13.2 の継続に落とす(誤って昇格して暴走を止めない)。連続カウンタ `progress.infra_fails_since_ok` / `progress.usage_limited_since_ok` の正本は `record-progress`(loop 所有)が run status から維持し、**`ok`(claude が正常終了した)cycle だけが両方をゼロに戻す** — usage は infra カウンタを進めず、その逆も同じである(原因の取り違えは停止理由の取り違えになる)。したがって fresh 再開で回復する種の失敗(継続不能等、§28.4)は連続が途切れてこのゲートには到達しない — このゲートに到達するのは fresh 再開でも連続して claude を起動できない、真に環境が到達不能なケースだけである。解除は他の停止と同じく人間の `just resume`(§13.3、I-011)であり、resume は idle カウンタと同様にこのカウンタも 0 に戻す。

7 の idle カウンタの正本は `context.json.progress.idle_cycles_since_progress`(loop の `record-progress` が維持)である。**起動失敗 cycle(run status が `infra` / `usage`)はこのカウンタを進めない — 据え置く。** idle は「セッションは走ったが台帳が動かなかった」ことの信号であり、セッションが 1 度も走っていない cycle を「意味的停滞」として数えるのは測定の誤りである。実走行 2026-08-12 では、上限到達による 3 連続の起動失敗が(30 秒 / 3 秒 / 3 秒 と無バックオフで再試行されたうえ)そのまま idle 閾値 3 を食い潰し、停止理由が「進捗停滞」として提示された。真因の特定には人間が runs.jsonl の実行時間を目視する必要があり、resume まで 9.5 時間かかっている。`unknown`(セッションは走ったが理由不明で失敗)は従来どおり idle を進める。「意味的進捗の有無」は、cycle 前後で対象ファイル + 一部 state の署名(progress signature)が変化したかで機械判定する — 署名の対象範囲・除外する volatile フィールド・算出は `bin/atlas-builder state` の `record-progress` が正本であり、本書はその出力(カウンタ)に依拠する。7・9・12・12'・13 は loop 検出の停止であり、`atlas-builder state raise-loop-gates` が Recommendation として実体化する(§13.4)。なお 7(idle 検出)は**設計上、非敵対的な安全網**である。idle は「意味的進捗の欠如」を測るのであって「暴走の検出」ではない: 意図的に無意味な変更(churn。非ゼロだが無価値な差分で署名だけが変わり続ける空回り)を作り続ける agent は署名が変化するため、この watchdog では止まらない。busy-but-stuck(忙しく見えて実は無益)への砦は idle ではなく、`--max-cycles` 予算(既定 25)+ cycle checkpoint 履歴の人間監査である — idle を万能の暴走検出だと読んではならない(コスト予算をこの砦に加える将来案は §13.4 将来メモ / I-026)。エージェント自身が原因を知っている場合は、loop の機械的実体化に頼らず、より具体的な Human-input Recommendation を自分で記録することが望ましい(§21.4)。10 と 11 はファイル状態そのもの(hash 不一致・破損)が正本証拠であり、Recommendation を介さず `should-stop` が直接検出する。

### 13.2 Non-immediate Stop

次は即停止しない。

1. Build failure
2. Test failure
3. Type failure
4. Lint failure
5. Dependency failure
6. Tool failure
7. 対象定義の隔離 runner の nonzero exit(対象がエージェントを内包し runner を持つ場合のみ、§10)
8. Implementation dead-end
9. Todo decomposition failure

これらはまず自律回復する。回復不能な場合は対象 Todo を `blocked` にし、他の Todo があれば継続する。

**起動失敗による `claude` 非ゼロ exit(§13.1-12 / §13.1-12')の扱いはこのリストの中で特別である。** 単発は上記と同じく即停止せず次 cycle へ継続するが、連続 K 回に達すると `infra_unreachable` / `usage_limited` へ**昇格**して即停止する。これは「プロジェクトのコードの失敗(build / test / lint 等)」ではなく「実行環境そのものの到達不能」または「プラン予算の枯渇」であり、次 cycle も同じ環境で回れば同じく失敗するだけだからである — 回復は自律ではなく人間による環境修復(接続確認・再認証)か、上限のリセット待ち(loop は §19.1-9 の指数バックオフでその時間を稼ぐ)を要する。

### 13.3 Resume — Human Intervention Gate

§13.1 の停止条件は canonical state にラッチされる(active な `essence_blocking` blocker、proposed な人間ゲート付き Recommendation、idle-cycle カウンタ)。人間が原因(典型的には `ESSENCE.md`)を修正しても、ラッチは自動では外れない。停止判断は Atlas Builder のものだが、停止解除の判断は人間のものだからである。人間が `.atlas-builder/state/**` を手編集して外すことも規律違反(§7.3)である。

一方、人間の介入は停止時に限らない。ループが停止していなくても、人間は途中で `ESSENCE.md` を書き換えたくなる(方針転換、優先順位の変更、要求の追加)。このとき worktree は dirty になり、次 cycle は I-014(clean worktree)で開始できない。さらにその編集が state に記録されなければ、次 cycle は §13.1-5(`ESSENCE.md` が Agent により変更された疑い)と人間の正当な編集を区別できない。

そこで再入口は、停止の有無を問わない人間専用の単一遷移 **resume** に統一する。

```bash
# 停止からの再開(gate release)
$EDITOR ../{project-title}/ESSENCE.md   # 人間がレビュー/修正
just resume --resolve B-003 --note "S-003 の矛盾を Essence v2 で解消"
just loop

# 停止していないループへの介入(steering)
$EDITOR ../{project-title}/ESSENCE.md   # 人間が途中で方針を修正
just resume --note "配信より計測を優先する方針に変更"
just loop
```

**intent note は必須である。** resume は人間の介入を記録する遷移であり、その意図(何を確認・修正・決定したのか)は、解除される各ゲートの `resolution`、attestation 台帳エントリ、review checkpoint commit 本文に残る唯一の説明である。`--note` なし(または空白のみ)で実行された場合、`resume.sh` はロック取得・state 変更より**前**に端末で自然言語の note を対話的に要求し、空入力は受け付けない(プロンプトを I-018 ロックの外に置くのは、放置されたプロンプトが生存 pid のロックとして永久に回収不能になるのを防ぐためである)。stdin が端末でない非対話実行では `--note` なしを**拒否**する(exit 2、state 未変更)— 既定文言で介入理由を自動補完すると、無説明のゲート解除と区別できなくなるためである。note は記録・commit 本文・端末表示へ流れるため、wrapper は保存/表示前に NUL を含む制御文字を取り除く(改行と tab は保持し、UTF-8 の非 ASCII バイト列は保持する)。サニタイズ後に空なら note なしとして扱う。なお `atlas-builder state resume` 単体が `--note` 省略時に持つ既定文言は、この正規入口を経ない誤用経路(§13.3-2'')への後備えであり、正規経路では到達しない。

`resume.sh` の引数解釈は fail-closed である。正規に受け付けるのは `--project <path>`、`--note <text>`、反復可能な `--resolve <B-or-R-id>`、反復可能な `--retract-approval <R-id>`(§13.3-4'' の明示的な承認撤回)、相互排他的な `--approve-should` / `--close-at-must`、これらのいずれとも併用できない `--steer-only`(§13.3-4''' の記録専用 checkpoint)、および crash recovery 専用の `--force` だけであり、未知引数は拒否する。`--note` の値がこれらの flag そのものに見える場合も拒否する — note 値を再スキャンして実フラグとして扱うと、`--note "--force"` が意図しない crash recovery になり得るためである。

**拒否は建設的でなければならない。** engine の拒否(state 未変更。wrapper は exit 3 で返す — §19.1-6 の loop 語彙とは別の「引数は解釈できたが遷移が拒否された」符号)を報告するとき、wrapper は拒否理由に加えて現在の should-stop message(§13.4-2 の単一導出点 — `just status` の STOP 行と同一)と、`just status` / `just triage` / gate 全文(recommendations.json)への参照を表示する。拒否文は**この呼出しの何が誤りだったか**を言い、message は**今受理される形**を言う — 前者だけでは人間が受理形を拒否文から逆算することになる(2026-07-27 の 2 連続拒否の直接原因)。この責務分担により、他所の固定テキスト(doc コメント・古い Recommendation 本文)が素の resume を指していても、拒否された試行は必ず 1 回で正しい形に到達する。停止がラッチされていない拒否(例: open でない ID への `--resolve`)に message は無く、拒否文自身が全てを言っている。should-stop が crash した場合は案内を導出せず(I-021 — 読めない gate 状態から案内を導かない)、`just status` を指すに留める。この表示は案内であって判定ではない — 受理集合の権威は engine(`selectionError?`)のままである。

`atlas-builder state resume` は次を 1 遷移で行う。

0. `PROJECT_STATE_ROOT/state` が存在しない(bootstrap 前)なら**拒否**する — resume が部分的な state ファイルを散らかすと、後の ensure がそれを正本として扱ってしまう。state の生成は ensure/bootstrap 遷移が所有する
1. `ESSENCE.md` が存在しない、または placeholder のまま/空なら**拒否**する(このゲートは Essence を実際に書くこと以外では外れない)。同様に、`ESSENCE.md` ⇄ `essences/` の双方向不整合(§2.1.5、§13.1-14)がある間も**拒否**する(placeholder 拒否と同格) — 不整合な Essence 状態を attest しないためであり、人間が `ESSENCE.md` か `essences/` を直してから再開する
2. `runs.jsonl` に未終了 run(start に対応する end がない)があれば**拒否**する。実行中のループの下で resume すると cycle commit と競合するためである。ループがクラッシュして start だけが残った場合に限り `--force` で通す。このとき resume はその run を `end`(status `aborted_by_resume`)で閉じ、`runs.jsonl` を整合状態に戻す(§13.5)
2'. `runs.jsonl` が読めない(破損している)場合は `--force` でも**拒否**する — in-flight の有無を証明できない状態でゲートを触ってはならない(I-021)。同様に、ゲートを保持する state(blockers / recommendations / context / reflection)が読めない場合も**拒否**する — 読めないファイルを既定値から再構築して書き戻すと、破損ファイルが保持していた内容を静かに破壊するためである。回復手順は §13.5(`git restore`)
2''. 生きた別プロセスが single-flight ロックを保持している場合、`--force` でも**拒否**する(I-018)。`resume.sh` 経由の正規実行ではロック保持者が自分の祖先プロセスなので通る — この検査が拒否するのは「実行中ループの横で `atlas-builder state resume --force` を直接叩く」誤用だけである
3. resume **前**の停止判定でモードを決める: **ラッチされた**停止条件(essence 系 Blocker、人間ゲート付き Recommendation、idle/infra 閾値、Must 境界 — つまりファイル事実型の停止以外)あり → **gate release**、なし → **steering**。**ファイル事実型 = `essence_unreviewed_change` + ドメイン固有の全停止理由**(実装ドメインは後者を持たない)である。ドメイン停止理由が例外なくファイル事実型なのは構造的な事実であり、列挙ではない: ドメイン停止 gate は台帳・context・作業ツリー観測からしか判定できず(§31.1 R-13 の hook 入力)、resume が閉じられるラッチ(Blocker / Recommendation)を持たないため、「解除して gate release にする」対象がそもそも存在しない。`essence_unreviewed_change` はラッチではなくディスク上の事実であり、resume 自身の attestation 追記(7)がそれを解消する — 未 attestation の Essence 編集**だけ**を抱えた resume は、本節冒頭の例のとおり途中修正の記録(steering)である。`--steer-only`(4''')の resume は latch の有無によらず **steering に固定**する: 1 件も解除していない遷移で gate release の handoff 差し替え(5)が走ると、飛行中の実 next actions が理由なく失われるためである
4. open な `essence_blocking` Blocker / 人間ゲート付き proposed Recommendation を**一括では解除しない**。人間が `--resolve` で列挙した ID だけを `resolved` にし(`resolved_at` / `resolved_by: "human"` / `resolution` note)、未選択ゲートは open のまま残す。重複 ID、現在 open でない ID、open gate があるのに解除対象も phase 判断も無い呼出しは、最初の書込み前に拒否する。これにより「1 件の確認が他の未確認ゲートまで消す」ことを構造的に防ぐ
4'. `must_complete_awaiting_phase_approval`(§13.1-13)は通常の `--resolve` だけでは解除できない。framework が観測した active な Must 境界がある場合に限り、人間は `--approve-should`(`context.json.phase = "extended_approved"`)または `--close-at-must`(`phase = "closed_at_must"`)を 1 つ選ぶ。phase gate Recommendation はこの判断と一緒に解決される。agent 自作の同名 gate や境界不在で flag を渡しても phase は変わらない。phase 判断 flag が framework gate を必要とし、approve が `extended_approved` を立てること、および resume 以外の主要 context 遷移が phase を保存/初期化することは機械証明済み(§31.3 S-T4)
4''. **supervise authorizing gate**(unfinished High-Risk Todo を `source` に持ち、その `target` と厳密一致する target を持つ open な人間ゲート Recommendation — つまり `just supervise --todo T-... --recommendation R-...` の preflight が**現に通る**組。判定は `Predicates.superviseAuthorizedTodo?` の単一定義で、preflight の受理集合との一致はテストが凍結する)は、resume にとって二重に特別である。(a) この gate への `--resolve` は書込み前に**拒否**する — 承認時点で resolve すると preflight の open gate 要件が恒久に満たせなくなり、supervise が実行不能になる(2026-08-04 実障害: 承認 Recommendation を resolve した後の supervise が『not an open human approval gate』で座礁し、canonical state の修復を要した)。閉じてよいのは supervise 完了で Todo が unfinished でなくなった後の通常 `--resolve`(正規経路)か、明示の承認撤回 `--retract-approval <R-id>` のみである。(b) この gate は「open gate があるのに解除対象が無い呼出しを拒否する」規則 4 の母集合から**除外**する — authorizing gate の「答え」は resolve ではなく supervise の実行であり、除外しないと gate を open に保ったままの途中 checkpoint(承認 → Essence 手直し → resume → supervise の正規手順)がデッドロックし、人間は承認を resolve で潰す誤操作へ誘導される。撤回路があるため、この gate 種が「どの形も受理されない」完全デッドロック(4' の陳腐化 phase gate で起きた I-017 破れと同型)に陥ることは構造的にない
4'''. **`--steer-only`(記録専用 checkpoint)**。規則 4 の「open gate があるのに解除対象も phase 判断も無い呼出しを拒否する」目的は**過剰解除の防止**である。しかし空の `--resolve` は何も解除しないため、この空ケースの拒否は目的に寄与しない一方で、**steering(本節冒頭が定義する途中修正の checkpoint)という別の正当な遷移を open gate の下で表現不能にしていた**。とくに §19.3 が指示する「要求そのものを昇格・追加して続行する」手順(Must 境界で停止 → 人間が `ESSENCE.md` を編集 → checkpoint → loop)は、境界で実体化された phase gate が open のまま残るため**必ず**この拒否に着弾する(2026-08-05 実障害: `just update-essence` の設置後案内どおりに打った resume が拒否され、人間は解決する意思のない gate を潰す以外に自分の編集を記録できなかった)。したがって拒否条件を緩めるのではなく、**意図を表明する手段**を足す: `--steer-only` は「ゲートは 1 件も解除しない。人間所有入力の編集だけを attestation して checkpoint する」という human の宣言である。この flag が立つと (a) 規則 4 の拒否から除外され、(b) mode は steering に固定され(3)、(c) `--resolve` / `--retract-approval` / phase 判断との同時指定は**意図の混線**(「1 件も解除しない」と「これを解除する」の同時主張)として最初の書込み前に拒否される。gate は 1 件も閉じないので post 再評価は停止を報告し続ける — それが正しい報告であり、各 gate の決定は従来どおり自分の exact 形が引き受ける。steer-only resume が `blockers.json` / `recommendations.json` を書込み計画に載せないことは機械証明済み(§31.3 S-T7)であり、遷移核は preflight を迂回した混線入力に対しても独立に fail-closed である
5. idle-cycle カウンタを 0 に戻す(resume が idle / infra カウンタを必ずゼロ化することは機械証明済み(§31.3 S-T6))。gate release では停止時の handoff を `reflection.jsonl` へアーカイブして更新する(steering では進行中の handoff を温存する — ループは飛行中であり、handoff は実在する次アクションを記述している)。差し替える handoff には resume note 未消費マーカー `pending_cycle` を立てる(`--close-at-must` の resume は closure 自体なので `false` で書く)— これが立っている間 `full_complete` は成立せず、note を消費する cycle が必ず 1 回走る。マーカーは note を消費した cycle の終端(`record-progress --run-status ok`)だけが下ろす(§19.3)
6. 解除すべきラッチも、未 commit の変更も、**未 attestation の Essence**(hash 不一致または baseline 不在)もなければ **no-op** として何も書かずに正常終了する。projection hash の乖離は次 cycle の再投影まで残るため、現在の `ESSENCE.md` hash が直近の attestation に一致する乖離は no-op 側に倒す — これにより resume は冪等になり、連続実行しても checkpoint commit が増えない
7. 2 つの記録を追記する: (a) **attestation 台帳** `CONTROL_ROOT/.agent/state/essence_attestations.jsonl` に `ESSENCE.md` の SHA-256・`essences/` の現況マニフェスト(`essences` キー、相対パス → SHA-256、§2.1.5)・mode・note — これが §13.1-10 の唯一の機械可読な baseline である(resume だけが書け、agent の書込みは hook が deny する。以後 `should-stop` は `ESSENCE.md` hash とこのマニフェストの両方を同一レコードの baseline と突き合わせる)。(b) `human_resume` reflection エントリ(project 平面の可視化用・**参考情報**): `mode`、実際に解除した Blocker / Recommendation id 一覧、Should 承認 / Must close の判断、hash、projection 乖離の有無、未 commit 変更ファイル一覧、note

`resume.sh` は state に触れる**前**に、単一実行ロック(I-018、§13.5)を取得し、未 commit 変更がすべて checkpoint scope 内かつ禁止 path 外であることを検査し、違反があれば拒否する(遷移後に commit guard で失敗すると半端に適用された resume が残るため)。その後 validate を実行し、人間の修正と状態遷移をまとめて 1 つの review checkpoint commit を作成する(gate release は `atlas-builder: human resume`、steering は `atlas-builder: human update`、`--force` で未終了 run を閉じた場合は `atlas-builder: crash recovery`。いずれも cycle commit と同じ path guard を通す)。これで次の `just loop` は clean worktree から開始できる(I-014)。

`atlas-builder state resume` が状態を遷移させた場合、`resume.sh` は**必ず** checkpoint commit まで到達する(唯一の例外は遷移後の validate 自体がハードエラー(exit ≥ 2)で死んだ場合で、I-021 に従い壊れたエンジンの出力を commit せず停止する)。resume 後にまだ停止条件が残っていても commit は行い、警告として報告する(遷移済みのラッチ解除を未 commit のまま放置すると半端適用が worktree に残るため)。残った停止条件は次の `just loop` が再びゲートする — これは欠陥ではなく、「resume は再評価の許可であって解決の宣言ではない」という設計そのものである。

**resume は「解決の宣言」ではなく「再評価の許可」である。** 次 cycle の Atlas Builder は通常どおり `ESSENCE.md` を読み直し(spec.json の projection hash 乖離が再投影を促す)、問題が残っていれば同じ停止条件を再ラッチする。したがって人間の修正が不十分でも安全側に倒れる。また attestation 台帳のエントリは「その内容の Essence を人間が確認した」という**唯一の機械可読な証跡**であり、§13.1-10 の attestation chain を前進させる: `should-stop` は現在の `ESSENCE.md` hash を台帳の直近記録(無ければ bootstrap 時の `project.json.essence_sha256` anchor)と比較し、不一致(または baseline 不在)なら `essence_unreviewed_change` として停止する。したがって未確認の Essence 変更(人間の途中編集・agent の不正変更のいずれでも)を抱えたまま resume が no-op で素通りすることはない — attestation を記録すべき変更がある限り、resume は必ず台帳へ書く。project 平面の `human_resume` reflection エントリは可視化のための複製であり、baseline としては**信用されない**(agent が追記できるファイルだからである)。

resume は人間専用である。steering モードも同様である — commit を作り、ラッチと reflection に触れる遷移だからである。`atlas-builder hook pre-tool` が `atlas-builder state resume` / `resume.sh` をエージェントに deny するため、ループが自分の停止条件を解除することも、人間介入を偽装することもできない(I-011)。resume・loop 所有サブコマンドを捉えた Bash 入力に guard が引数順序に関わらず必ず deny を返すことは機械証明済み(§31.3 G-T3)。

### 13.4 Stop Visibility and Gate Materialization

停止が canonical state 上の実体(Recommendation / Blocker)を持たずカウンタや暗黙状態としてしか存在しないと、人間には「`just loop` を何度実行しても進まないが、理由がどこにも見えない」ように映る。さらにラッチ済み停止下の再実行が毎回フルの terminal cycle(run 記録 + カウンタ増加 + checkpoint commit)を走れば、待てば直るかのようなノイズだけが積み上がる。本節はこの 2 つ — 不可視な停止と、副作用のある再実行 — を仕様として封じる。

**可視化原則(I-017)。** ループが停止する(または停止し続ける)とき、その理由は必ず次の 3 層すべてに存在しなければならない。

1. **Canonical state**: 停止条件は Recommendation / Blocker または直接評価できる canonical fact として実体を持つ。Essence 判断系はエージェントが記録する。loop 検出系(`no_runnable_todos` / `idle_cycles` / `usage_limited` / `infra_unreachable` / `must_complete_awaiting_phase_approval`)は `atlas-builder state raise-loop-gates` が cycle 終端で Human-input Recommendation として実体化する。直接 fact の例外は `essence_missing` / `essence_placeholder` / `essence_structure` / `essence_asset_integrity` / `essence_unreviewed_change` / `state_unreadable`、および「最終 must の更新後、gate 実体化前に crash した」場合の `todo.json + context.phase` が示す `must_complete_awaiting_phase_approval` である。後者も `should-stop` が直接止め、同じ人間 resume が phase approval として処理するため、余計な cycle や二度目の resume は不要である。可視性は第 2・第 3 層が保証する。
2. **`just status` の出力**: `atlas-builder state status`(`just status` / `status.sh` 経由)は、現在の停止評価(reasons / message / idle カウンタ / must 完了数 / completion phase)と、停止中なら再開手順を正本 state から都度計算して表示する。この表示は `should-stop` の**別実装であってはならない**: status は gate 述語の入力(`StopInputs`)を独自に組み立てず、`should-stop` と同一の観測をそのまま渡して同一の述語を呼ぶ。表示側が入力を組み直すと、観測面が 1 つ増えるたびに「型は通るが片方だけ欠けた観測で評価する」余地が生まれ、`just status` の Gate 行と `should-stop` の reasons が同時刻に食い違う。gate 述語が依存する human-owned 面の観測は、構造体の既定値を持たない必須フィールドとして表現し、注入忘れがコンパイルで落ちるようにする。通常 gate は正確な `--resolve <ID>` を案内する。フェーズ境界停止(`must_complete_awaiting_phase_approval`)では `--approve-should` と `--close-at-must` の二択を明示する。**未 attestation の人間所有入力編集**(`essence_unreviewed_change`)の締めは、open gate があるときは `just resume --steer-only --note "..."`(§13.3-4''' — 編集だけを記録し gate は開いたまま残す)であり、gate が無いときだけ素の resume である。編集の記録と gate の決定は別の仕事なので、同じ message の中で別々の exact 形が別々の仕事を名指しする — この 2 つを 1 つの形に畳むと、人間は解決する意思のない gate を潰すことでしか自分の編集を記録できない(2026-08-05 の実障害)。supervise authorizing gate(§13.3-4'')では `--resolve` を**案内しない**(この状態では拒否される形である)— 代わりに `just supervise --todo T-... --recommendation R-...` の exact 形と、明示撤回 `just resume --retract-approval <ID>` を案内し、payload には同じ集合を `supervise_authorizations` として機械可読に出す(triage wrapper の縮小がこれを消費する)。案内された supervise 形が preflight に受理されることはテストが凍結する — 拒否される形を写させる案内を出さない綴り規律は、resume 形だけでなく supervise 形にも及ぶ。詳細(gate Recommendation の全文)は canonical state の `recommendations.json` にある。この message は status と loop 終了だけでなく、resume 形を人間に綴る他の wrapper 面も消費する: `resume.sh` の拒否表示(§13.3「拒否は建設的でなければならない」)、`essence.sh` の設置後案内(§2.1.4-5)、そして watch の Gate 表示(§15.3 — STOP の文言を逐語で写す)である。resume の exact 形を人間に提示する面は、常にこの単一導出点を写す — 面ごとに固定文言を持つと、gate の有無で受理形が変わる度に一部の面だけが陳腐化する(2026-07-27 / 2026-08-04 の実障害はいずれもこの形)。
3. **ループの終了メッセージ**: `loop.sh` は停止で exit するとき、停止理由の JSON と、確認先(`just status`)および**対象を明示した** resume の選択肢を必ず出力する。この終了は仕様どおりの終端であるため、**正常終了(exit code 0)とし、`STOP:` として報告する — `ERROR:` として報告してはならない**(`status.sh` の STOP / COMPLETE / RUNNABLE と同じ語彙)。エラー扱いは「フレームワークが壊れた」と「ワークフローが人間の手番になった」を混同させ、`just` 等の呼び出し側にも偽の失敗表示(`error: Recipe failed`)を強いる。停止中かどうかの機械可読な照会は exit code ではなく `atlas-builder state should-stop` が担う(§19.1-6)。

**ゲート済み再実行は副作用ゼロ(I-019)。** `loop.sh` は各 cycle の**開始前**に should-stop / should-complete を評価する(pre-gate)。ラッチ済みの停止(または完了)を検出した場合、run 記録を書かず、カウンタを変えず、commit も作らずに、理由と再開手順を表示して終了する。ラッチ中に `just loop` を何度実行しても、状態も Git 履歴も一切変化しない。停止条件が cycle **中**に新たに発生した場合のみ、その cycle は通常どおり finalize され(end-run → record-progress → raise-loop-gates → validate → checkpoint commit)、その後にループが終了する。

**実体化の規則。** `raise-loop-gates` は次に従う。

1. 真の完了状態(`full_complete`、§19.3)では何も実体化しない。(系: 完了と idle ラッチが同時に成立する状態 — 正規の遷移では到達せず、閾値の手動変更か state 破損を要する — では、ループは stop を優先して報告するが gate Recommendation は実体化されない。可視性は第 2・第 3 層が担い、resume が counter を 0 に戻して解消する。)`must_phase_complete` だが未承認の状態は**完了ではなくフェーズ境界の停止**であり、規則 6 が扱う。
2. 既に可視な停止がある場合は重複実体化しない: エージェント由来の可視な停止(essence 系 Blocker / Blocking Recommendation / 人間ゲート付き Recommendation)に加え、ファイル状態そのものが正本証拠である停止(`essence_missing` / `essence_placeholder` / `essence_structure` / `essence_asset_integrity` / `essence_unreviewed_change`)が成立している間も gate Recommendation は raise しない — 規則 1 の例外と同様、可視性は第 2・第 3 層が担い、resume がカウンタを 0 に戻して解消する。
3. `no_runnable_todos`: Todo が存在し、実行可能な Todo(現フェーズの runnable、§19.3)がなく、projection 乖離(再投影という次の仕事)もなく、かつ `must_phase_complete` でもない場合に限り raise する。診断として残存 Todo の一覧(id / status / executor / `blocked_reason`)を `details` に含める。
4. `idle_cycles`: idle カウンタが閾値以上のとき raise する。
5. `infra_unreachable`: `progress.infra_fails_since_ok` が閾値(既定 K=2)以上のとき raise する(§13.1-12)。このゲートだけは規則 1・2 の抑制対象外である — claude 自体を起動できない以上、完了状態や他の可視停止は operative cause ではなく(stale でさえありうる)、環境修復の必要は他のゲートと独立に人間へ可視化する。
5'. `usage_limited`: `progress.usage_limited_since_ok` が閾値(既定 K=4)以上のとき raise する(§13.1-12')。規則 5 と同じく規則 1・2 の抑制対象外であり、raise 順は infra より**先**である(D-005 の「具体が総称に先行する」)。理由文は待機と `ATLAS_BUILDER_MODEL` による別モデル継続を名指しし、到達性・認証の調査へ人間を送らない。
6. `must_complete_awaiting_phase_approval`: `must_phase_complete` かつ `context.json.phase == "must"` のとき raise する(§13.1-13、§19.3)。`extended_approved` と `closed_at_must` はいずれも人間判断済みなので raise しない。診断として must 完了数と、着手待ちの should Todo の一覧(あれば)を `details` に含める。
7. gate 種別ごとに冪等である(同種の proposed gate Recommendation が開いている間は再 raise しない)。
8. raise したら `reflection.jsonl` に `loop_gate` エントリを追記する。

**複数の停止条件が同時に成立するとき。** `should-stop` は成立した停止条件を**すべて** reasons 配列に載せる(隠さない — §13 冒頭の可視化原則)。唯一の例外は `essence_placeholder` 成立中の `essence_unreviewed_change` である: placeholder の Essence は resume(attestation)では解消できず、実際の Essence を書くことだけが次の一手なので、attestation を促す reason を併記するのはかえって誤誘導になる — placeholder が解消された時点で unreviewed は改めて独立に評価される。gate 実体化も同様で、`raise-loop-gates` は成立した loop 検出 gate(規則 3〜6。5' を含む)を**それぞれ独立に**(各種別 1 つ、冪等に)raise する — 1 つを選んで他を捨てることはしない。ただし人間向けの**単一の要約表示**が要る 2 面では優先順位を持つ: (a) commit 本文の `Atlas-Builder-Run-Status`(§24.3)は 1 値なので、`should-stop` が reasons を積む順(`state_unreadable` → `essence_missing` → `essence_placeholder` → `essence_structure` → `essence_asset_integrity` → `essence_unreviewed_change` → `essence_blocking` → `blocking_recommendation` → `human_input_required` → `must_complete_awaiting_phase_approval` → `idle_cycles` → `usage_limited` → `infra_unreachable`)で**最初にマッチした 1 つ**を刻む。(b) `just status` の gate 表示はこの順の先頭を主 reason として示しつつ、reasons 配列全体も表示する。要するに「実体化と記録は網羅、単一値表示は優先順位の先頭」である。規則 1 の系(完了と idle が同時のときは stop を優先報告し gate は実体化しない)はこの一般則の特殊ケースである。

**将来バージョン(設計メモ)。** 現行 v1.0 の停止可視化 3 層はすべて**プル型**(端末メッセージ + state ファイル)で、離席中の人間に能動的には届かない。また暴走への砦は時間・回数の系(`--max-cycles`、`--max-session-cycles`、idle 停止)だけで、**コスト(トークン/費用)の上限は無い**(未実装の明記は §1.2「Expose the distortion」の設計書への適用)。次の 2 つを将来対象として予約する。制約の全文は §23 の予約不変条件が持つ。

- **push 型停止通知(第 4 層、I-023)**: メール / Slack / デスクトップ等。**best-effort・非権威**でよく、Agent の外(ラッパー)から秘密を載せずゲート遷移時のみ撃つ。
- **コスト予算(I-026)**: トークン/費用の上限。上限到達は `--max-cycles` と同格の正常終了(exit 0)の設計上の終端。push 通知との**非対称**に注意 — 通知は best-effort でよいが、**コスト上限は権威あるゲートでなければならない**(留守中の予算超過を止められなければ砦の意味がない)。

### 13.5 Interruption, Crash, and Single-flight

**単一実行(I-018)。** 1 つの control plane で同時に走ってよい canonical write window は 1 つである。loop / once / resume / supervise / init / bootstrap と、`bin/atlas-builder state` の全 mutating command(`ensure` / `validate` / `apply-projection` / loop-owned transitions / `resume`)がこの window に入る。`loop.sh` / `resume.sh` / `supervise.sh` は開始時に `CONTROL_ROOT/.agent/tmp/loop.lock` を原子的に取得し(pid 記録付き mkdir ロック)、init/bootstrap は同じ lock を取得または祖先から継承する。`bin/atlas-builder state` の mutating command も同じ lock を取得し、cycle/wrapper の子なら祖先の slot を継承する。特に validate / apply-projection は全 read/derive/write 区間を slot 内に置く。取得できなければ保持者の pid を表示して拒否する。保持プロセスが死んでいる stale ロックを自動回収してよいのは、OS の process probe が**確実に不在**を返した場合だけである。permission denied、sandbox 制約、unexpected exit/stderr、その他「生存を証明できない」結果は alive/unknown とみなし fail-closed に拒否する。pid が**まだ記録されていない**ロックも、取得者が mkdir と pid 書込みの間にいる可能性があるため、十分に古い場合に限り残骸として回収し、新鮮なうちは「取得中」とみなして拒否する。`bin/atlas-builder state` 単体も、pid の読めない lock dir を fail-closed に拒否する。これにより権限不足を「死んだ pid」と誤認して lock を奪う経路、並行変異、torn snapshot の診断投影を排除する。

**PID namespace を跨ぐ継承。** `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` は Linux で Bash 子を隔離 PID namespace に置くため、cycle 内の `bin/atlas-builder state` から外側 wrapper の pid が `ps` / `kill(0)` で見えない。pid 非可視を stale lock と誤認してはならないので、lock 取得者は暗号学的乱数の coordination nonce を lock 内と sanitized Claude 環境の `ATLAS_BUILDER_LOCK_TOKEN` に置く。値が一致する cycle/supervise 子は同じ slot を継承し、値が無い/異なる process は従来どおり pid/age 判定で取得または拒否する。この nonce は外部サービス・秘密データへの権限を与えず、現在の slot の同一性だけを示し、lock 解放時に失効する。loop-only/human-only command の hook deny は別層なので、nonce を見られる Agent の権限範囲も広がらない。([Claude][8])

**検証 child / init / bootstrap も single-flight の内側にある。** cycle 内の build/test/隔離 runner は loop process の child として同じ slot を継承する。`init.sh` と `bootstrap.sh` は (a) lock 保持者が祖先ならその slot を継承、(b) lock 無しなら取得、(c) 別の生きた loop/resume/supervise が保持中なら拒否、の 3 形で I-018 に従う。`atlas-builder state resume` 自身も、生きた非祖先 process が lock を保持していれば `--force` でも拒否する。純読取の `status` / `trust-check` は lock 外で常に実行できる。`doctor` は他の診断を続けられるが、内部の validate は別の変異保持者と競合すれば hard error として報告する。

**canonical state の破損。** JSON/JSONL 正本は原子的 write(tmp + rename)で書かれるため破損は通常起きないが、外因(ディスク障害・手編集事故)で発生し得る。停止ゲートを保持するファイル(blockers / recommendations / context / reflection / runs / project、および attestation 台帳 — §13.1-11 の 7 面)が読めない場合、`should-stop` は fail-closed に `state_unreadable` で停止し(I-021)、`raise-loop-gates` / `resume` / `record-progress` / `reset-context` はそのファイルへの書き戻しを拒否する — 既定値からの再構築は破損ファイルが保持していた内容の静かな破壊だからである。回復は人間の作業である: 正常な内容を持つ直近の checkpoint から復元する(未 commit の破損なら `git restore <file>`、破損が checkpoint に入ってしまっていれば `git restore --source=<good-commit> <file>`。JSONL の末尾行切断なら該当行の除去でもよい)。この修復は §7.3 の「state 手編集の規律違反」には当たらない — ラッチの解除ではなく、git 履歴に既に存在する正本の復元だからである。修復後は通常どおり `just resume` → `just loop`。projection 系ファイル(spec / todo)の破損はこの対象外で、validate エラーとして次 cycle のエージェントが修復する(§13.2)。

**中断(SIGHUP / SIGINT / SIGTERM)。** ループは signal trap を持ち(端末切断の SIGHUP も同じ trap で処理する — wrapper のプロセスグループには届くが claude 自身のグループには届かない形があるため)、実行中の Claude process group(その build/test/隔離-runner child を含む)を終了**させ切ってから**(kill → wait)実行中 run を `end`(status `interrupted`)で閉じ、lock を解放する。worktree には部分変更が残る(commit しない)。人間が diff をレビューし、`just resume` が review checkpoint として引き取る。resume / init / bootstrap は signal を遅延処理し、遷移が lock より長生きしない。中断は cycle を殺す最終手段であり、「キリのいい境界で止まってほしい」だけなら graceful drain(`just stop`、§19.1-7)を使う — 実行中の cycle が完走して checkpoint を作るため、worktree は clean のまま resume も不要である。

**クラッシュ(SIGKILL / 電源断など)。** run が start のまま残り(dangling run)、worktree は dirty になる。このとき:

- `just loop` は clean worktree 検査(I-014)で拒否する。
- `just resume` は dangling run を検出して拒否し、`--force` を案内する。
- `just resume --force` は dangling run を `aborted_by_resume` で閉じ、残骸を含む checkpoint を `atlas-builder: crash recovery` として commit する(内容は人間編集ではなくエージェント残骸を含むため、`human update` とは区別してラベルする)。
- `just doctor` は dangling run と stale ロックを検出して回復手順を案内する。

resume の checkpoint は本質的に「人間が内容を確認して引き取った」ことの記録であり、crash recovery はその特殊形である。`--force` は実行中のループの下では絶対に使わない — 単一実行ロックと dangling-run 検査の二重化は、この誤用を機械的に難しくするためにある。

**crash recovery ラベルの意味論。** `atlas-builder: crash recovery` は「dangling run を閉じて `runs.jsonl` の整合を回復した」ことを表す — 「エージェント残骸を含むか」ではない。run が `end` で閉じた**後**(cycle 終端の finalize 中: record-progress / validate / checkpoint commit の失敗や拒否)にループが死んだ場合、dangling run は残らないため、worktree のエージェント残骸は通常の resume(`human update` / `human resume`)が引き取る — 中断(SIGINT / SIGTERM)後の回復と同型である。どちらのラベルでも、resume の reflection エントリは `worktree_changes` に引き取った内容を列挙する。

### 13.6 Gate Triage — 停止対応の対話的代行

§13.4 は停止を可視化するが、可視化された停止を「人間の次の一手」へ変換する作業 — ゲートの読解、原因の調査、要求の明確化、resume intent note の起草 — は依然として人間の負担である。この作業の大半は**判断ではなく調査**であり、調査はエージェントが代行できる。そこで、停止した人間の手番を支援する人間専用の対話セッション **gate triage** を追加する。

```bash
just triage    # = bash scripts/triage.sh --project ../{project-title}
```

`triage.sh` は CONTROL_ROOT から対話モードの Claude セッション(slash command `/triage`、実体は `CONTROL_ROOT/.claude/commands/triage.md`)を起動する。セッションの職務は、開いているゲート項目(人間ゲート付き proposed Recommendation、active な `essence_blocking` Blocker、loop-raised gate — `no_runnable_todos` / `idle_cycles` / `usage_limited` / `infra_unreachable` / `must_complete_awaiting_phase_approval` を含む、`essence_unreviewed_change` / `state_unreadable` などのファイル事実系停止)を扱うことである。

**まず説明し、次に仕分ける。** 仕分け・調査・質問に入る前に、triage はまず開いている各ゲート項目を人間へ**平易な言葉で提示**する(§13.6 冒頭の「ゲートの読解」を独立の第一段階として顕在化させる)。これは canonical state の生フィールド(`reason` / `details` / `gate`)をそのまま貼ることではなく、`recommendations.json` / `blockers.json`(§15.2)を読んで「それが何であり(Recommendation なら何を勧めている・求めているのか)・なぜ上がったのか・解除すると何が起きるのか」を人間が一読で掴める一文へ翻訳することである。triage が代行できるのは判断ではなく調査であるのと同様(§13.6 冒頭)、この説明は判断ではなく読解であり、人間が JSON を自分で開かずとも「何を問われているか」を理解できる状態を作る。人間ゲート付き Recommendation は特に、機械が上げた `reason` を人間の意思決定言語へ翻訳して最初に提示する。説明はブリーフィングであって決定ではない — ここでは質問も仕分けもせず、それらは説明の後に続く。

説明を終えたら、各ゲート項目を次の 2 種に仕分ける。

- **dispatchable(代行で打ち取る)**: 答えが Essence・canonical state・リポジトリから事実として一意に定まり、人間の選好・価値判断を要しない項目。triage が調査し、結論と根拠を提示して resume note に畳み込む。
- **human-required(人間必須)**: 優先順位・要求のトレードオフ・支出や権限の承認・秘密情報・`ESSENCE.md` の変更を要する項目。triage は決定を確定させるのに必要な最小限で本質的な質問を人間に行い、曖昧な要望を決定可能な文面へ洗練した上で、人間が実施すべき手順を**ステップバイステップ**で提示する。フェーズ境界(`must_complete_awaiting_phase_approval`)は本質的に human-required である — should フェーズへ進むか、Must scope で明示的に閉じるかは人間の予算・優先判断だからである。triage は残りの should を要約して二択を問い、`approve-should` / `close-at-must` の決定自体は確認付き resume で確定する(§19.3)。

**仕分けの倒し方向。** ある項目が dispatchable か human-required かの判定自体が曖昧なとき(答えが「事実として一意に定まる」か否かが微妙なとき)は、**human-required に倒す**。dispatchable の必要条件は「価値判断・優先度・支出・権限・秘密・`ESSENCE.md` 変更を一切含まず、かつ答えが Essence / canonical state / リポジトリから一意に導ける」ことであり、このいずれかが疑わしければ dispatchable と見なさない。triage が human-required を dispatchable と誤仕分けして人間の判断を代行結論に畳み込む危険を、この既定倒し方向が塞ぐ(最終的には resume 前の人間の y 確認も柵になる — 規則 5)。

規則:

1. **人間専用・対話専用。** `triage.sh` は stdin/stdout が端末でなければ拒否する(exit 2)。`atlas-builder hook pre-tool` は resume / loop / once / init / trust と同様に `triage.sh` / `just triage` をエージェントに deny する(§18.2)。エージェントが triage を再帰起動したり、triage を踏み台に resume へ到達したりする経路はない。
2. **起動条件。** wrapper は読み取り専用の pre-flight として `should-stop` / `should-complete` を評価し(predicate の失敗は fail-closed にハードエラー — I-021)、停止していなければセッションを起動せず COMPLETE / RUNNABLE を報告して終了する。triage の対象は「停止して人間の手番になっているワークフロー」だけである。途中修正(steering)やクラッシュ回復は従来どおり §13.3 / §13.5 の手順による。
3. **read-only(I-022)。** triage セッションは実装を一切進めない — 実装は resume 後の `just loop` の仕事である。書けるのは handoff 用の `CONTROL_ROOT/.agent/tmp/triage/` のみ(gitignore 済み・checkpoint 対象外)。Edit / NotebookEdit ツールは起動時に無効化され(`--disallowedTools`)、Write ツールは有効のまま hook が handoff 内へ封じ込める — 書き込み先が handoff root の内側(strict: root 自身は不可)へ解決されるときだけ allow、それ以外は受理される正確な出口(Write ツール × handoff パス)を教示する deny。これが handoff note の第一の出口である(正確な heredoc 綴りだけを要求してセッションを座礁させない)。Bash は exact path の `atlas-builder state status` / `atlas-builder state should-stop` と、handoff への単一コマンド quoted heredoc だけを hook が allow する。この許可面の完全列挙性 — read-only セッションの Bash / WRITE_TOOLS で allow はこれらの面に限られ、書き込みを伴う面の書き込み先はすべて handoff root の内側に解決済みであり、それ以外は必ず明示的 deny になる(handoff root 外への書き込みが許可される経路は存在しない)— は機械証明済み(§31.3 G-T2)。heredoc は shell が解釈する header 行のみを文法で拘束し(bare / 単引用 / 二重引用の shell-inert な path、任意の `mkdir -p <handoff> &&` 前置のみ許容)、本文は常に data、引用済み delimiter は EOF に一度だけ現れることを要求する — byte-exact な一綴りに絞ることは安全性を足さず(書き込み封じ込めは OS sandbox の仕事)、セッションが handoff を書けなくなる実害だけを生む。deny する場合、hook はメッセージ中に受理される正確な形を提示し、セッションが自己修正できるようにする。`status.sh` を含む Git command は、停止状態との race で repository-configured helper を実行する余地を残さないため許可しない。対話 permission mode は installed CLI が公開する ask-before-edits 値(`manual` / `default`)を選び、どちらも無ければ拒否する(自動承認なし、§28.5)。さらに session-bound `--settings` は対象全体を OS sandbox `denyWrite` に置く。対象の読み取りは `--add-dir` で与える — bound base は additionalDirectories を持たず(マシン依存部は起動毎 overlay の管轄、§16.1)、triage は bound overlay ではなく read-only overlay を積むため、§2.1.4-2 の essence と同じく wrapper が明示付与する。境界を強制する hooks を確実にロードするため、wrapper は起動前に Claude Code trust を要求する(未 trust なら拒否 — §2.1.4-2 と同じ根拠)。canonical state・projection・実装ファイルには書き込まない。既存の hook 境界(resume 系 deny、state 保護、ESSENCE.md deny)はセッション内でもそのまま効く。read-only の限定許可には人間承認(ask)面が 1 つ加わる: live settings(`CONTROL_ROOT/.claude/settings.json`)への Write は hook が ask を返し(settings 側も同じ面を ask に載せ、`.claude` はサブ面列挙 deny + settings.json ask で書く — deny は hook の ask に常に勝つため、§28.5)、人間が permission prompt で承認したときだけ通る。project settings は hot-reload されるため、承認された修復は同一セッションの以降の呼び出しに効く。これが、認可された handoff 書込み自体が deny される配備欠陥(旧形式 base の残存や base の破損など、§28.5-3 / §16.1)の唯一のセッション内回復経路である: セッションは現行 settings を読んで欠陥を特定し、修正後の全文を提案する — 承認・却下は常に人間の行為であり、非対話の自律セッションでは ask は自動 deny に落ちる(§19)。人間がセッションに打ち込む `!` prefix コマンドは同一の deny/hook/OS sandbox を通るため回避策にならず(ユーザー入力で省略されるのは ask プロンプトのみ)、`--settings` overlay は起動時固定で編集は再読込されない。修復が却下された場合、または陳腐化した blanket deny が修復自体を塞ぐ場合(deny は hook の ask に勝つ)、セッションプロンプト(triage.md / essence.md)の denied-write protocol に従う: 拒否内容の逐語報告 + 結論の画面提示(handoff に書けなくても人間の作業を失わせない)+ セッション終了と `just doctor` への誘導。allow 面(handoff 内)と ask 面(settings 修復、および essence-new の ESSENCE.md fallback — §2.1.4-2)の完全列挙性は機械証明済み(§31.3 G-T2)。
4. **ESSENCE.md は提案まで。** Essence の変更が必要な項目では、triage は置換全文または diff の**提案**と適用手順の提示までを行い、適用は人間が行う(I-004 は不変)。適用後の attestation は、この後の resume が通常どおり台帳へ記録する(§13.1-10、§13.3-7)。
5. **handoff と確認付き targeted resume。** セッションは、合意済みの決定と代行調査の結論を `.agent/tmp/triage/resume_note.txt` に、解除する exact ID / phase 判断を `.agent/tmp/triage/resume_decisions.txt` に書いて終える(未確定の論点が残る場合はどちらも書かない)。decision file は `resolve B-...` / `resolve R-...` / `approve-should` / `close-at-must` の小さな line protocol だけを受理し、wrapper が形式と phase 判断の一意性を再検査する。ID の形状検査は canonical 形状(§8.2 の `<prefix>-[A-Za-z0-9_+-]+` — `_lib.sh valid_item_id`)そのものを使い、決してその場で書き直さない。state engine の受理集合を再実装するシェル側 pre-filter は、engine より緩くも**厳しくも**してはならない — 緩ければ境界が崩れ、厳しければ正当な遷移(triage の主要対象である loop gate `R-LG-<stamp+0900>-<suffix>`(§21.5)を含む)が届かず、対話セッション 1 回分の成果が resume に届かない。

**gate 集合の照合も wrapper 側で行う。** engine の `--resolve` は open gate だけを受理する(`State/Resume.lean` の `selectionError?`: active な `essence_blocking` Blocker ∪ proposed な `Blocking Recommendation` ∪ human-gated Recommendation)。Non-blocking Recommendation は意図的に対象外であり、loop が次サイクルで resolve する(§21.4)。triage セッションが非 gate ID を resolve 行に書くと engine は **handoff 全体**を `--resolve names no currently open gate` で拒否するため、2 段で防ぐ:(1) `/triage` prompt が gate と非 gate を明示的に区別し、非 gate の結論は note に畳み込むと規定する。(2) wrapper は confirmation の**前**に、pre-flight で得た should-stop payload の `essence_blockers` / `blocking_recommendations` / `human_requests`(= engine の openIds そのもの。raw state から規則を再実装するのではなく engine の出力を消費する)と突き合わせ、gate でない ID を理由つきで画面に出して落とす。同じ payload の `supervise_authorizations` に載る ID(supervise authorizing gate、§13.3-4'' — open だが `--resolve` は拒否される)も専用の理由(`just supervise` を先に実行し、resolve は diff review 後; 撤回は人間が `--retract-approval` を直接実行)つきで落とす。落とすのは常に**縮小方向**のみで、broadening は決して行わない(§13.6-5 の「wrapper は決定を黙って広げない」は不変)。人間は縮小後の exact flags を見て y/N を答える。空の decision list は正当な handoff(file-fact-only stop、全 gate 据え置きの steering、または全 ID が落ちた場合)であり、wrapper はこれを `--steer-only` の resume として実行する(`_lib.sh finalize_triage_resume_args`): open gate が 1 件でも残る停止では engine が素の note-only resume を `open gates require explicit --resolve` で拒否し(§13.3-4''')、triage ではその拒否が対話セッション終了後にしか現れないため(2026-08-10 の実障害 — ESSENCE.md steering + gate 全据え置きの handoff が resume で座礁)、「何も解除しない」意図は flag で明示する。open gate が無い場合も `--steer-only` は素の note-only resume と同一の steering 遷移であり(`transition` は mode を steering に固定)、この写像が release を広げることはない。bash 3.2 の `set -u` でも空配列展開が中断しない綴り(`${ARR[@]+"${ARR[@]}"}`)は防御として維持する。wrapper はセッション起動**前**に handoff dir を削除するため、handoff は当該セッション由来に限る。セッション終了後、wrapper は note と exact decision flags をサニタイズして全文表示し、端末での明示確認(y)を得た場合に**限り**同じ flags 付きの `resume.sh` を実行する。state engine も ID の open/unique と framework phase boundary を独立検査する。サニタイズ後に note が空なら resume を起動しない。確認が得られない場合も何も変更しない。
6. **triage が越えない線。** wrapper は `--force` を渡さず(クラッシュ回復は §13.5 の手動手順)、`just loop` も起動しない — ループ再開は常に人間の独立した操作である。また triage は single-flight(I-018)の**外**にある: セッション自体は読み取り専用でロックを取らず、確認後の resume 子プロセスが通常どおり自分でロックを取得・調停する(実行中ループとの競合は、pre-flight と resume 自身の拒否条件が排除する)。
7. **案内への組み込み。** 停止時の再開案内(§13.4-3 の確認先・再開コマンドの表示、`status.sh` の NEXT 行)は、`just resume` に加えて `just triage` を支援手段として併記する。

この安全性は I-022 として固定する(§23)。

---

## 14. Context Reset

Over-Project Agent は長期運用される主体であり、動的 reset を行う(§14.1)。対象がエージェントを内包する
場合も、その製品 runtime の context は Atlas Builder の管理対象ではない。Atlas Builder が管理するのは Over-Project
Agent の session と、隔離 runner から得た一回限りの観察結果だけである(§14.2)。

### 14.1 Over-Project Agent Context

Over-Project Agent は長期運用されるため、動的 reset を行う。

Reset trigger:

```text
context_usage_estimate >= hard_threshold
failed_attempts_since_reset >= reset_after_failed_attempts
changed_files_since_reset >= reset_after_changed_files
completed_todos_since_reset >= reset_after_completed_todos
important_decisions_since_reset >= reset_after_decisions
major_spec_rewrite_since_reset == true
high_risk_change_completed == true
```

これらのカウンタはエージェント自身が `context.json` に維持する **best-effort** の信号である。エージェントが更新を怠ると reset が永遠に発火せず、`claude -c` 継続セッションのコンテキストが際限なく肥大するため、ループは機械的なバックストップを持つ: 1 セッションの cycle 数(fresh 開始の 1 cycle + それに続く `-c` 継続 cycle)が `--max-session-cycles`(既定 8)に達したら、カウンタと無関係に次セッションを fresh で開始する。fresh 開始が正しく機能する前提は「fresh セッションはディスク上の状態だけから再開できる」(§14 冒頭の不変条件)であり、handoff の品質がこの安全弁の実効性を決める。

**Completion phase フラグ。** `context.json` は上記の reset カウンタとは別に、完了フェーズを表す永続フィールド `phase` を持つ(§19.3)。

```text
context.json.phase : "must" (既定・未設定/未知値と同義)
                   | "extended_approved"
                   | "closed_at_must"
```

これは best-effort な agent 信号ではなく、`should-complete` / `should-stop` / runnable 判定が読む**ゲート状態**である。既定の `must` フェーズでは runnable 集合は must 優先度に限られ、must 完了で `must_complete_awaiting_phase_approval` が停止する(§13.1-13)。この境界でだけ、`just resume --approve-should` が `extended_approved` を立てて should を runnable にし、`just resume --close-at-must` が `closed_at_must` を立てて Must scope の terminal complete にする。未知値は承認済みとみなさず `must` に倒す。agent はこのフィールドを書かない — 完了 scope の判断は resume 遷移(人間介入)が所有する(§13.3)。context reset はこのフィールドを保存する(reset は投影の進捗ではなくコンテキストの入れ替えであり、人間決定を巻き戻してはならない)。

**Resume note 未消費マーカー。** `context.json.handoff` は agent が次セッションへ書き継ぐ best-effort な引き継ぎ領域だが、その中の `pending_cycle` フィールドだけは `should-complete` が読む**ゲート状態**である(§19.3): gate release の resume が差し替え handoff に `true` を書き(`--close-at-must` は `false`)、note を消費した cycle の終端(`record-progress --run-status ok`)が `false` へ下ろす。立っている間 `full_complete` は成立しない — resume note に運ばれた人間の指示を、消費する cycle を走らせずに COMPLETE が捨てることを封じる。

**ドメインの cycle 承認マーカー(§31.1 R-13)。** ドメイン軸 `Domain.cycleAuthorizations` を持つドメインでは、`context.json` に同じ資格のゲート状態がもう 1 種現れる: resume が(自分の停止 payload 面を観測したとき)**立て**、note を消費した成功 cycle の終端(`record-progress --run-status ok`)だけが**下ろす** boolean マーカーである — 立っている 1 cycle だけドメインのファイル事実型停止を通す「次の cycle だけの許可」であり、`pending_cycle` と対になる。立てる側と下ろす側は 1 つの宣言から出て(§31.1 R-13)、マーカーが `phase` / `progress` 等の framework 面を名乗れないことは `#guard` が凍結する(§31.3 S-T4 / S-T6 の保存定理の前提)。参照ドメインはこの軸を持たない。

Reset 前に必ず次へ handoff を書く。

```text
PROJECT_ROOT/.atlas-builder/state/context.json
PROJECT_ROOT/.atlas-builder/state/reflection.jsonl
CONTROL_ROOT/.agent/state/control_context.json
```

### 14.2 In-Project Agent の context は Atlas Builder 管理下にない

**適用範囲**: 本節は、対象がエージェントを内包する場合(§5.0)にのみ意味を持つ。

In-Project Agent のコンテキスト・記憶・継続作法は対象プロダクト自身の設計であり、Atlas Builder は規定しない。
Atlas Builder cycle はライブ runtime session を開始せず、対象定義の隔離 runner を実行する場合も各回を独立した
disposable verification として扱う(§10)。Atlas Builder が正本へ反映するのは exit code と redact 済み要約だけで、
runtime が cycle をまたいで何かを覚えていることに依存しない。

### 14.3 知見台帳 `lessons.jsonl` — handoff は「次の一手」に専念する

handoff(§14.1)は**コンテキストリセットを越えるための伝票**であり、次のセッションが disk だけから再開するために要る情報を運ぶ。ところが cycle 横断で蓄積すべき知見の置き場が他に無いと、handoff がその役目まで兼ねてしまう。実走行 2026-08-12 の handoff は `next_actions` に「Ops reminders」「Lean lessons」「Harness patterns」を**毎 cycle 転写し続けて**おり、これは伝票の設計不良ではなく台帳の欠落の症状だった(コンテキストリセット 3 回からの復帰自体は handoff で完全に機能している)。

`PROJECT_STATE_ROOT/state/lessons.jsonl` は、その受け皿である。

- **追記専用・エージェント書込み可**(`bin/atlas-builder state append-lesson --file <entry.json>`、§8.2)。エントリは `topic` と `lesson` を必須で持ち、engine が `at` / `id`(`L-<stamp>-<suffix>`)/ `cycle`(= `project.json.cycle_seq`、§19.1-10)/ `run_id` / `recorded_by` を刻む。
- **gate 保持面ではない。** 停止条件を持たないので `state_unreadable`(§13.1-11)の 7 面には入らず、欠落は `ensure` が補充する。知見の欠落で loop を止めるのは、可視性ではなく単なる作業妨害である。
- **何を書くか。** 次の cycle だけでなく**次のプロジェクト**でも使える形の知見: 証明戦術(どの補題が実際に要ったか)、ハーネス設計の型、ツールの実用上限とその回避、といったもの。1 回限りの状況説明は reflection の仕事である。
- **handoff は次の一手に戻る。** `next_actions` は「次のセッションが最初に取る行動」だけを持ち、恒久知見は台帳が持つ。
---

## 15. Status Reporting

人間向けの状態表示は、生成ファイルではなく**コマンド出力**で行う。正本は常に `.atlas-builder/state/*.json` / `*.jsonl`(§8)であり、表示はそこから都度計算される — 陳腐化しうる中間ファイルも、「ビューを正本と読み違える」経路も存在しない。対象プロジェクトにも CONTROL_ROOT にも、Atlas Builder が人間向けに生成・保守するドキュメントファイルは無い。

### 15.1 `just status`

`atlas-builder state status`(`just status` / `status.sh` 経由)が単一の人間向けサマリである。内容は次に限定する。

1. 現在の状態要約(Spec / Todo / active batch / blockers / validation / runs)
2. gate 状態(§13.4: 停止/完了/続行可能の評価、理由、idle カウンタ、**起動失敗カウンタ**(`Run failures : infra i/K, usage-limit u/K'`)、must 完了数、completion phase、停止中は再開手順)。起動失敗カウンタを idle と並べて出すのは、「起動できなかった」を「停滞した」と読み違えさせないためである — 実走行 2026-08-12 では、この区別が表示に無かったために人間が runs.jsonl の実行時間を目視して真因を切り分ける必要があった
3. 成功条件 ↔ evidence 対応(§22 / §20.2-6: `ESSENCE.md` の `成功条件` と acceptance-check evidence の対応。must 完了ゲート(§13.1-13)の人間レビューを支援する補助線。成功条件が存在するときのみ出す)

このほか、状況があるときだけ注意行が加わる: 未消費 resume note(§19.3 の `pending_cycle`)と、gate 保持面の読取診断(I-021 — 停止理由の詳細と同じ観測)である — どちらも 2 の gate 状態の一部であり、新しい表示面ではない。

### 15.2 Detail Is Canonical State Itself

一覧を超える詳細(gate Recommendation の全文、blocker の理由、reflection の履歴)は、対応する canonical JSON / JSONL をそのまま読む。`recommendations.json` / `blockers.json` / `reflection.jsonl` は人間が直接読める形で書かれ、`reason` / `details` / 再開手順を自身で持つ(§21)。

### 15.3 `just watch` — 走行中 loop の常駐監視ビューア

`just watch`(= `watch.sh`)は、走行中の `just loop` に**別ターミナルから読み取り専用で併走する**フルスクリーン TUI である。`just status` が静的スナップショットであるのに対し、watch は約 1 秒ごとに同じ観測 — I-018 lock の生存、drain フラグ(§19.1-7)、loop heartbeat(§19.1-9)、canonical state、`tool_audit.jsonl` — から 1 フレームを都度計算して描き直す。§15 の原則はそのまま適用される: watch が生成・保守する正本・人間向けファイルは無く(観測 tail の作業ファイルは gitignore 済み `.agent/tmp` の scratch で終了時に破棄され、読む側の heartbeat は loop が書く表示専用の runtime machine state であって、人間向けドキュメントでも正本でもない — §19.1-9)、正本は常に canonical state であり、TUI の起動・終了は loop にも state にも一切影響しない純オブザーバである。描画は `atlas-builder state watch-render`(`state status` と同型の「IO シェルが観測を読み、純粋核が 1 フレームを組み立てる」単発コマンド)が行い、wrapper は端末制御(alternate screen・1s tick・`q` での終了)と観測の足回り(端末サイズ・lock 生存の process 検査・tail の切り出し — バイナリが可搬にできない部分)だけを担う。表示は次に限定する。

1. loop / 現在サイクルの状態(lock 生存、cycle n/max、run_id、session、経過時間、drain 保留)
2. gate 状態 — §13.4 の表示規律に従い、STOP の message は should-stop payload の逐語(§13.4-2 の単一導出点を消費し、watch 側で再導出しない)、gate 述語のハードエラーは「runnable」と描かず EVAL ERROR と報告する(§19.1-3)
3. 直近サイクル履歴と累積統計(`runs.jsonl` から計算)
4. エージェントの内部ライブ活動(`tool_audit.jsonl` の tail + Claude Code session transcript の追跡)

最後の transcript 表示だけは canonical 観測ではなく **best-effort** である: `~/.claude/projects/` 配下の session transcript は Claude Code の内部フォーマットであり、Atlas Builder はその形式との一致を仕様として主張しない。watch は既知の形(assistant text)だけを snippet 表示し、ファイルが無い・読めない・形式が変わった場合は `tool_audit.jsonl` 表示へ黙って劣化する — この劣化が受け入れ条件であり、transcript 形式の変化が watch を壊すことはない。

フレームは「ちょうど rows 行 × 各行の表示幅ちょうど cols」の不変量で描く(超過は `…` 切り詰め・不足は空白パディング — 全行の等幅上書きが前フレームの残骸を消すので、行末消去のエスケープを持たない)。表示幅は全角 = 2 の近似であり、East Asian **Ambiguous**(罫線 `─`・`…` 等)は端末既定に合わせて幅 1 に数える — 端末エミュレータ側で「曖昧幅文字を全角にする」設定を有効にしている場合は行が折り返れるため、watch を使う端末では標準幅設定にする。判定に使われない表示専用の近似である。

常駐対話プログラムなので分類は human-only である(§18.4 — cycle 内の agent が起動すると戻らないプロセスとして cycle を wedge する。agent は同じ情報を許可済みの `state status` / `should-stop` で取得できる)。単発描画の `state watch-render` は read-only の inspect 面に留まる。

---

## 16. Claude Code Configuration Strategy

Claude Code の公式ドキュメントでは、設定は User / Project / Local / Managed のスコープを持ち、Project 設定はリポジトリの `.claude/settings.json` に置かれる。Atlas Builder はこの性質を利用する。常に存在するのは **CONTROL_ROOT 側の Over-Project Agent 設定**(§16.1)である。対象がエージェントを内包する場合、対象自身の設定(`PROJECT_ROOT/.claude/settings.json`)も存在しうるが、それは対象プロダクトの内容物であって Atlas Builder が規定するものではない(§16.2)。root を分けているため対象側の設定は対象 CWD にとどまり、CONTROL_ROOT から起動する Over-Project Agent の設定にはならない。([Claude][1])

また、Claude Code の permissions は deny / ask / allow の順で評価され、モデルの指示ではなく Claude Code 側で enforcement されるため、Atlas Builder では重要な境界を `CLAUDE.md` の文章だけでなく permissions と hooks で守る。([Claude][4])

Claude Code は trust dialog が承認されていないワークスペースの `.claude/settings.json` を無視する。Atlas Builder は permissions/hooks を安全境界として使うため、非対話の `claude -p` を起動する前に trust を hard gate として検査する。人間は初回セットアップで `just trust` を実行し、`~/.claude.json` の該当 `projects[...].hasTrustDialogAccepted` を明示設定する。Claude Code のバージョン差で trust key が CWD か Git ルート寄りになる場合があるため、Atlas Builder は launch root と Git root の両候補を検査する。自動ループは trust を暗黙に書き換えない。

### 16.1 Over-Project Agent Settings

設定は **2 層**である: git 追跡の **base**(`CONTROL_ROOT/.claude/settings.json` — マシン非依存)と、launcher が起動毎に生成して `--settings` で渡す **overlay**(インライン JSON 1 行 — マシン依存部の全体。ディスクに書かない)。分割線は「このホストのパスを含むか」であり、パス系 permission ルールと sandbox はすべて overlay、それ以外(model / profile 記録 / permission の非パス床 / hooks)はすべて base に置く。これによりワークスペースを別ホストへ clone しても base は陳腐化せず、再 init なしで動く — git 追跡物はどこにもこのマシンのパスを含まない。

**base** — `CONTROL_ROOT/.claude/settings.json`(init がテンプレから描画、git 追跡):

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "best",
  "_atlas_builder_profile": "standard",
  "permissions": {
    "defaultMode": "dontAsk",
    "disableBypassPermissionsMode": "disable",
    "additionalDirectories": [],
    "allow": [
      "Bash(bin/atlas-builder state *)",
      "Bash(bash scripts/*.sh *)",
      "Bash(git status *)",
      "Bash(git diff *)",
      "Bash(npm test *)",
      "Bash(pnpm test *)",
      "Bash(pytest *)",
      "Bash(cargo test *)",
      "Bash(go test *)"
    ],
    "deny": [
      "Read(~/.ssh/**)",
      "Read(~/.aws/**)",
      "Read(~/.claude/**)",
      "Read(~/.claude.json)",
      "Bash(rm -rf *)",
      "Bash(sudo *)",
      "Bash(chmod -R *)",
      "Bash(chown *)",
      "Bash(claude *)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git push *)",
      "Bash(git reset --hard *)",
      "Bash(git clean -fd *)"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/bin/atlas-builder hook session-start"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash|Edit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/bin/atlas-builder hook pre-tool"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|Edit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/bin/atlas-builder hook post-tool"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/bin/atlas-builder hook pre-compact"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/bin/atlas-builder hook stop"
          }
        ]
      }
    ]
  }
}
```

**overlay** — loop / supervise の launcher が single-flight lock 取得後に `atlas-builder util bound-settings <project> <control>` で invocation につき 1 回生成し、`--settings` にインラインで渡す(構築の正本は `Core/Settings.lean` の `boundSession`。lock 後生成なので、init を含むどの framework 遷移も invocation 中に base — したがって profile — を書き換えられない、I-018。人間の手編集による乖離は §11.5 の両方向 fail-safe の範疇):

```json
{
  "permissions": {
    "additionalDirectories": ["/ABS/PROJECT_TITLE"],
    "allow": [
      "Read(//ABS/.atlas-builder/**)",
      "Read(//ABS/PROJECT_TITLE/**)",
      "Edit(//ABS/PROJECT_TITLE/**)"
    ],
    "ask": [
      "Edit(//ABS/PROJECT_TITLE/CLAUDE.md)",
      "Edit(//ABS/PROJECT_TITLE/.claude/**)",
      "Edit(//ABS/PROJECT_TITLE/.mcp.json)",
      "Edit(//ABS/.atlas-builder/.claude/settings.json)"
    ],
    "deny": [
      "Edit(//ABS/.atlas-builder/CLAUDE.md)",
      "Edit(//ABS/.atlas-builder/.claude/agents/**)",
      "Edit(//ABS/.atlas-builder/.claude/commands/**)",
      "Edit(//ABS/.atlas-builder/.claude/rules/**)",
      "Edit(//ABS/.atlas-builder/.claude/skills/**)",
      "Edit(//ABS/.atlas-builder/scripts/**)",
      "Edit(//ABS/.atlas-builder/templates/**)",
      "Edit(//ABS/.atlas-builder/recipes/**)",
      "Edit(//ABS/.atlas-builder/META.md)",
      "Edit(//ABS/.atlas-builder/README.md)",
      "Edit(//ABS/.atlas-builder/justfile)",
      "Edit(//ABS/.atlas-builder/.agent/prompts/**)",
      "Edit(//ABS/.atlas-builder/.agent/state/**)",
      "Edit(//ABS/.atlas-builder/bin/**)",
      "Edit(//ABS/.atlas-builder/lean/**)",
      "Edit(//ABS/PROJECT_TITLE/ESSENCE.md)",
      "Edit(//ABS/PROJECT_TITLE/essences/**)",
      "Read(//ABS/PROJECT_TITLE/.env)",
      "Read(//ABS/PROJECT_TITLE/.env.*)",
      "Read(//ABS/PROJECT_TITLE/secrets/**)",
      "Read(//ABS/PROJECT_TITLE/config/credentials.json)"
    ]
  },
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "autoAllowBashIfSandboxed": false,
    "allowUnsandboxedCommands": false,
    "network": {
      "allowedDomains": [
        "github.com", "api.github.com", "raw.githubusercontent.com",
        "objects.githubusercontent.com", "registry.npmjs.org", "pypi.org",
        "files.pythonhosted.org", "crates.io", "static.crates.io",
        "index.crates.io", "proxy.golang.org", "sum.golang.org",
        "releases.lean-lang.org", "lakecache.blob.core.windows.net"
      ]
    },
    "filesystem": {
      "allowWrite": ["/ABS/PROJECT_TITLE", "/ABS/.atlas-builder/.agent/tmp"],
      "denyRead": [
        "/ABS/PROJECT_TITLE/.env",
        "/ABS/PROJECT_TITLE/secrets",
        "~/.ssh",
        "~/.aws"
      ],
      "denyWrite": [
        "/ABS/PROJECT_TITLE/ESSENCE.md",
        "/ABS/PROJECT_TITLE/essences",
        "/ABS/PROJECT_TITLE/.atlas-builder/state/project.json",
        "/ABS/.atlas-builder/CLAUDE.md",
        "/ABS/.atlas-builder/.claude",
        "/ABS/.atlas-builder/scripts",
        "/ABS/.atlas-builder/templates",
        "/ABS/.atlas-builder/recipes",
        "/ABS/.atlas-builder/META.md",
        "/ABS/.atlas-builder/bin",
        "/ABS/.atlas-builder/lean"
      ]
    }
  }
}
```

overlay の ask / sandbox は base の `_atlas_builder_profile` が決める(§11.5): standard は上記のとおり、relaxed 2 態は project 側 ask 3 面を落とし(修復面は全 profile 常設)、unsandboxed はさらに `sandbox.enabled` だけを `false` に反転する(filesystem / network は保持 — sandbox を降ろした配備でも宣言の床を陳腐化させない)。headless セッションでは unmatched → deny が床(§19.1-5)なので、overlay の `Read` / `Edit` allow 3 本が対象・制御プレーンへの読み書きを実際に開けている — overlay を欠いた起動は「動く裸のセッション」ではなく「対象に触れないセッション」になる。

hooks 配線: 全 5 イベント(SessionStart / PreToolUse / PostToolUse / PreCompact / Stop)で `bin/atlas-builder hook <event>` が本番である。

Claude Code hooks は、ツール実行前後、セッション開始、停止、compact 前などの lifecycle event で実行でき、ファイル編集ブロックやコマンド検証などの deterministic control に使える。Atlas Builder では、重要境界を LLM の善意に依存させず hooks で守る。([Claude][5])

上記の `/ABS` はワークスペースの**解決済み絶対パス**(例 `/home/u/workspace`)のプレースホルダで、overlay の実物では `//home/u/workspace/PROJECT_TITLE/**` のように展開される。overlay は `atlas-builder util bound-settings` が起動のたびに実体解決したパスから組み立てるので、パスを焼いたファイルはどこにも存在しない。base は `init.sh`(`just init`)が `templates/control/settings.json.tmpl` から描画する — テンプレートは既にマシン非依存であり、init が差し込む値は `_atlas_builder_profile` 行(ESSENCE 宣言の profile、§11.5)ただ 1 つである。テンプレートのトークンは 2 種: `__ATLAS_BUILDER_PROJECT_PATH__`(CONTROL_ROOT からの相対パス、例 `../PROJECT_TITLE`)を CLAUDE.md / justfile が、`__ATLAS_BUILDER_PROJECT_TITLE__`(basename)を `templates/workspace/` の README seed が使う(settings.json.tmpl はトークンを持たない)。init は JSON / justfile / Markdown の文脈ごとに値を escape して描画する。配布状態の `CONTROL_ROOT/.claude/settings.json` は、どの対象にも束縛されていない**安全版**(`_atlas_builder_profile` なし — この不在自体が「unbound では overlay を生成できない」の構造保証 — かつ検証コマンドの allow は束縛時に付与)で、init 実行時に束縛版 base へ上書きされる — unbound → bound の上書き構造は分割後も維持される。

**permissions パスルールは解決済み絶対パスで書かねばならない(設計制約、§19.1-5 / §28.5)。** Claude Code は permissions の allow / ask / deny のパスルールを**解決済み絶対ターゲットパス**に対して照合し、`Edit(../PROJECT_TITLE/**)` のような**相対パスのルールは黙ってどれにもマッチしない**。相対 allow は何も許可せず(対象への編集がすべて拒否され、cycle が実作業に入れず投影を記録すらできない — 変更系が「サイレントに拒否される」症状)、相対 deny/sandbox denyRead は何も守らない(`.env`/secrets が読めてしまう I-024 破れ)。逆向きの失敗もある: cwd 相対の綴り(`Edit(./README.md)` / `Read(.)` 等)は CLI 依存の基準で解決され、**additionalDirectories(= PROJECT_ROOT)配下の同名ファイルにも過剰マッチする** — bound 配備の `Edit(./README.md)` が agent 所有の `PROJECT_ROOT/README.md`(§11.1)への Write/Edit をすべて塞いだ実障害がある(2026-07-31、R-006)。かつては「`Edit(./<surface>)` 形は CONTROL_ROOT(=cwd)相対で正しくマッチする」を前提に control-plane ルールだけ相対で書いていたが、この前提は成立しない。この原則の実施主体は overlay 生成関数(`Core/Settings.lean` の `boundSession` / `readOnlySession`)である: 実体解決済みの入力パスから permissions ルールを `//<abs>` 綴り(絶対パス `/abs` に先頭 `/` を 1 つ足した形)、sandbox filesystem パスを素の `<abs>` 綴りで組み立て、bound base 側はパス系ルールを 1 本も持たない。唯一の相対綴りは unbound の配布既定(`.claude/settings.json`)で、これは init 前セッション(new-essence 等)のための**独立の床**である — 機械依存の絶対パスを持てず束縛 project も無い(過剰マッチの相手が存在しない)ため cwd 相対の暫定床を持つ。現行 CLI では `Edit` が全編集ツールをカバーするため、無効な `Write(...)` permission ルールは置かない。`doctor.sh` は base にパス系ルールが混入していないことと、内部生成した overlay に相対パスルール(`../` 形・cwd 相対形とも)が 1 本も無く絶対プロジェクト allow ルールが存在することを検証する(§28.5)。

**control-plane の Edit deny は §11.3 面の列挙(絶対 `//<abs>` 綴り)で書き、一括 CONTROL_ROOT deny を置いてはならない(設計制約、§28.5)。** CLI >=2.1.216 では permissions の deny は PreToolUse hook の allow より常に優先され(hook の allow は ask プロンプトの省略のみで、deny/ask を上書きしない)、`Edit` deny は (1) Write を含む全編集ツール、(2) Bash コマンドの書込先解析(リダイレクト先・`touch` 等の対象パス)、(3) OS sandbox プロファイルへの合成(denyWrite 相当として `--settings` overlay の allowWrite より優先)の 3 層へ波及する。したがって CONTROL_ROOT 全体の一括 deny は、hook が allow する唯一の書込み面 — `.agent/tmp/<mode>/` handoff(§2.1.4-2/§13.6-3)と single-flight lock(`.agent/tmp`) — を全経路で塞ぎ、essence/triage の handoff 書出しと in-cycle の mutating state コマンドを完全に殺す。ゆえに control-plane deny は §11.3 の面列挙(+ hook バイナリ `bin/**` とその Lean ソース `lean/**`)で書き、`.agent/tmp` はどの deny でも覆わない。`.claude` も同じ理由で一括 deny にできない: `settings.json` は read-only human セッションの人間承認付き修復面(ask、§28.5-3/§13.6-3)であり、blanket `Edit(./.claude/**)` はその hook ask を上書きして修復経路を閉じる。ゆえに `.claude` はサブ面(agents/commands/rules/skills)の列挙 deny + `.claude/settings.json` の ask(いずれも絶対綴り)で書く。この列挙 deny と ask 床の置き場は **overlay** である(パスを含むため base には置けない)。帰結として、wrapper を迂回した raw `claude` セッション(overlay 無し)は settings 層のパス deny と sandbox の**両方**を失い、残る柵は hook の deny 床(I-030)だけになる — 分割前は base が焼いたパス deny が raw 起動にも効いていたが、その層はもともと hook deny と同面の多層防御であり、raw 起動を運用入口にしない規律(§28.4-1、doctor の注意喚起)は従来どおりである。`doctor.sh` は内部生成した overlay に対して列挙の存在・blanket ルール(`Edit(./**)` / `Edit(./.claude/**)` とその絶対綴りの等価形)の不在・ask 床の存在をすべて検査する。

**sandbox filesystem パスは CONTROL_ROOT 側も含め解決済み絶対パスで書かねばならない(設計制約、§28.5)。** permissions ルールとは別に、`sandbox.filesystem` のパスには固有の解決規則がある: `/` 始まりは絶対、`~` 始まりは home、**相対(`./` または裸)はセッション cwd ではなく設定ソース依存の基準**(project settings では CLI が判定する project root、user settings では `~/.claude`)で解決され、誤解決しても**警告なく沈黙する**。さらに CLI はエントリをシンボリックリンク正規化しない。したがって相対綴り(`./.agent/tmp`、`./scripts` 等)は環境・CLI バージョンによって CONTROL_ROOT 以外へ黙って解決し得る — 相対 allowWrite が誤解決すると、cycle 内のサンドボックス化 Bash から全 mutating `bin/atlas-builder state` コマンド(validate を含む)が single-flight/project lock の作成(`CONTROL_ROOT/.agent/tmp` 配下)で失敗し、エージェントは cycle 中の自己検証を失う(loop 境界の検証は sandbox 外で走るため生き残り、症状が「cycle 内だけ必ず失敗」になる)。相対 denyWrite は OS 層で control surface を何も守らない(hooks/permissions の deny は残るが、多層防御の 1 層が沈黙脱落する)。ゆえに overlay 生成は実体解決済み(physical)の入力パスから sandbox filesystem を絶対綴りで組み立て、`doctor.sh` は内部生成した overlay に `<control_abs>/.agent/tmp` の allowWrite と control surface の絶対 denyWrite が存在し、相対エントリが 1 つも無いことを検証する。**sandbox オブジェクトを base に置かないのは分割線の帰結であると同時に独立の設計判断でもある**: base と `--settings` overlay の間の sandbox の**スコープ間マージ意味論は undocumented** であり、依存すれば CLI の実装差分で境界が黙って変わる(read-only セッションが既に同型の回避を採っていた)。分割前の read-only session は実際に「bound base の sandbox + read-only overlay の sandbox」という 2 オブジェクトの undocumented マージの上で動いていた — 仮に allowWrite が連結される意味論なら base の `allowWrite: [PROJECT]` が read-only の書込禁止を破る形である。分割後は base に sandbox が無く、**どのセッションでも sandbox の供給源はそのセッションの overlay 1 つ**になり、この既存依存は消滅した(I-022/I-027 の根拠が強くなる)。

**自律 session の outbound network は列挙 allowlist に限定する。** bound overlay は source/package/toolchain の取得に必要な標準 domain だけを `sandbox.network.allowedDomains` に置き、wildcard `*` を拒否する。doctor は field と全必須 domain の存在、wildcard 不在を検査する。triage / essence の read-only session overlay は `allowedDomains: []` とし、助言 session に外向き通信の用途を与えない。これは Claude Code sandbox proxy の project-level allowlist と headless ask-denial を組み合わせた**実用的な既定拒否**である。ただし、未知 domain の接続を vendor 実装の全経路で無条件に hard block する managed-only の `allowManagedDomainsOnly` を project settings から強制することはできない。ゆえに「組織 managed policy が無くても mathematically closed な egress firewall」とは主張しない。この vendor behavior 境界と drift 対応は §28.5 に明記する。

**permissions ルールはサブコマンド単位で照合される(設計制約)。** Claude Code は Bash コマンドを `&&` / `||` / `;` / `|` / `|&` / `&` / 改行で分割し、**各サブコマンドを独立にルールへ照合する**。したがってルール文字列の中に `&&` や `|` を書いても、それにマッチするサブコマンドは存在しない — `Bash(cd * && pnpm test*)` や `Bash(curl * | sh *)` は**1 つもマッチしない死んだルール**である(前者は許可を与えず、後者は禁止を与えない)。ゆえに検証コマンドの allow は `Bash(pnpm test *)` のように**サブコマンド単位**で書く。この形は cwd を縛らないが、境界は失われない: `cd` は working directory / `additionalDirectories` 内なら Claude Code が read-only として扱いプロンプトを出さず、許可ルートの外へ出る `cd` は guard hook が `ask` に落とす(§11.3)。**cwd 境界は permissions ではなく hook が張る。** 同じ理由で pipe-to-shell(`curl … | sh`)の禁止も permissions では表現できず、`atlas-builder hook pre-tool` の `DANGEROUS_BASH`(コマンド全文への正規表現 deny)が強制する。この deny が決定木のどの ask / allow / 無意見にも降格しないこと(deny 先行の順序不変量)は機械証明済み(§31.3 G-T1)。

`Bash(claude *)` は `deny` である。対象の arbitrary runtime をライブ起動しても sibling control/state を守れないため、project-defined isolated runner だけを通常の verification command として許す(§10)。overlay の `ask` — `Edit(//ABS/PROJECT_TITLE/CLAUDE.md)` / `.claude/**` / `.mcp.json` — は、人間が `just supervise` で承認しながら対象 runtime を開発する High-Risk 経路である(§12)。依存 install が `ask` に現れない理由は §11.2 のとおりで、判定は hook が単独で担う。

本節および §16.2 / §17 の JSON / Markdown ブロックは構造を示す**代表例**であり、許可/秘密 path の網羅的な正本ではない。正確な内容は base が `templates/control/*.tmpl`、overlay が `Core/Settings.lean` の `boundSession` を正本とする。**profile(§11.5)の relaxed 2 態にテンプレの複製は存在しない**: base の正本は同じ 1 枚の `settings.json.tmpl` であり、init の派生(純関数 `deriveProfileTemplate`、`Core/Classify/Profile.lean`)は `_atlas_builder_profile` 行の exactly-once 置換 1 本に縮小されている — profile の実効(ask 3 面の除去・sandbox 解除)はテンプレ派生ではなく起動毎の overlay 生成が担う。置換行が「ちょうど 1 回」一致しない場合は standard 含め描画自体を拒否する(fail-closed)— 手書きの派生テンプレはテンプレ間ドリフトの温床であり、置かない。配布テンプレートは Over-Project Agent の既定 model も固定するが、model 値は安全境界ではない。cycle 内の脚仕事の知能配分は §30 が定め、subagent model は `.claude/agents/*.md` frontmatter が正本である。

**session model は配備方針であり、単発上書きの逃げ道を持つ。** 束縛済み `CONTROL_ROOT/.claude/settings.json` の `model` フィールドが配備既定の正本である(配布既定: 公式 alias `best`)。人間はこのフィールドを別の公式 alias へ書き換えて既定を恒久的に変えてよい — model 値は安全境界ではないので、permissions / hooks / sandbox は何も変わらない(§30)。加えて、既定モデルが**その時だけ**使えない場合(利用上限到達、提供終了、provider 障害)に束縛済み設定を書き換えずに続行できるよう、全 Claude launcher(loop / once / triage / essence / supervise)は環境変数 `ATLAS_BUILDER_MODEL` を単発上書きとして受け、`--model <value>` を CLI へ渡す:

```sh
ATLAS_BUILDER_MODEL=opus just triage      # この起動だけ opus tier で走る
ATLAS_BUILDER_MODEL=claude-opus-5 just loop
```

値は `scripts/_lib.sh` の `resolve_session_model` が唯一解釈する: 公式 alias(`best` / `default` / `opus` / `sonnet` / `haiku` / `fable` / `opusplan`)か完全なモデル名(`claude-*`)のみを受け、それ以外は exit 2 で拒否する — CLI へ黙って解決させず、綴り誤りをその場で止めるためである。未設定なら launcher は `--model` を一切渡さず settings.json が決める。`ATLAS_BUILDER_MODEL` は sanitized env(I-024)に含めないため、上書きは launcher の CLI 引数としてのみ効き、session 内の Bash からは観測されない。`--model` を告知しない CLI では上書きが単に使えないだけであり(doctor が note で報告する)、既定経路は影響を受けない。

`permissions.defaultMode` 自体も `dontAsk` にして、wrapper 外の起動や将来の引数欠落を fail-closed にする。credential scrub 下の正規自律 cycle は現行 CLI が常に `default` に解決するため、冗長な `--permission-mode dontAsk` を渡さず、headless `-p` を fail-closed の床として固定する。人間専用の triage / essence / supervise だけが installed CLI の ask-before-edits mode(`manual` または `default`)を明示上書きする。したがって対話承認経路を残しつつ、暗黙の `acceptEdits` 経路は存在しない。

ただし **`dontAsk` の宣言は現行 CLI では両方とも不活性である**: `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`(I-024、全 launcher で常時 set)が立っていると、Claude Code は permission mode 解決を short-circuit して `default` を強制し、**CLI フラグと `permissions.defaultMode` の双方を読む前に捨てる**。自律 cycle の fail-closed 床を実際に支えているのは headless(`-p`)であり、その全容と、なぜ宣言を残すのかは §19.1-5 に記す。ここに `dontAsk` を書く意味は依然としてある — wrapper 外の**対話**起動(scrub 環境変数なし)では実際に効くからである。人間専用 launcher が要求する mode は `manual`(CLI 内部で `default` に正規化)なので、強制の影響を受けず、警告も出ない。

**hook 起動は CWD 非依存であること(設計要件)。** 各 hook command は相対パスではなく `"$CLAUDE_PROJECT_DIR"/bin/atlas-builder hook <event>` で起動する。`$CLAUDE_PROJECT_DIR` は Claude Code 起動ディレクトリ(= CONTROL_ROOT)を常に指すため、セッション CWD がツール実行の過程で移動しても hook を確実に起動できる。相対パス起動(`bin/atlas-builder hook ...`)にしてはならない — CWD が CONTROL_ROOT 以外へ移った瞬間に hook プロセスが見つからず、PreToolUse hook の起動失敗によって Bash/Edit/Write が全面ブロックされるためである。hook 実装内部も CWD 非依存に CONTROL_ROOT を解決する: 実行ファイル位置(`bin/atlas-builder` の 2 つ上)基準である。

### 16.2 In-Project Agent Settings は Atlas Builder が規定しない

対象が In-Project Agent を内包する場合(§5.0)、そのエージェントが従う `PROJECT_ROOT/.claude/settings.json`
などの設定は、**対象プロダクトの内容物であって Atlas Builder が seed するものではない**。Atlas Builder は
そこに雛形も、Atlas Builder 固有の語彙も一切書き込まない。In-Project Agent の設定がどうあるべきかは、
対象の Essence が決めることである(§6.2)。

Atlas Builder は対象設定をライブ PROJECT_ROOT でロードしない。挙動検証が必要なら、対象側設定を disposable
環境へコピーして起動する project-defined isolated runner が、その runtime とライブ Atlas Builder state/秘密の
間を隔離しなければならない(§10)。CONTROL_ROOT の設定だけで nested runtime を保護できるとは見なさない。

なお、対象プロダクトが自らの都合で秘密の deny 等を `.claude/settings.json` に書くことは当然ありうる。
それは対象自身の設計判断であって、Atlas Builder が強制する項目ではない。

### 16.3 Secrets Boundary in Permissions

定義済み secret input surface(対象の `.env` / `.env.*` / `secrets/**` / `config/credentials.json` と §11.4 が列挙する home credential stores)への Agent アクセスは、**Read / Edit / Write / Bash のすべて**で塞ぐ。permissions と hook は明示パスを拒否する第一層であるが、shell の動的 path 構築を完全には理解できないため、それだけを機械強制とは呼ばない。第二層として OS sandbox の `denyRead` / `denyWrite` を必須にし、`failIfUnavailable: true` と `allowUnsandboxedCommands: false` で fallback/escape を禁止する。`autoAllowBashIfSandboxed: false` により、sandbox 内という理由だけで permissions の allow を拡張しない。通常 source/toolchain path に秘密を置かないという供給側前提と保証範囲は §11.4 のとおりである。([Claude][6])

第三層として、Atlas Builder の全 Claude launcher は operator shell の環境をそのまま継承せず、`env -i` の後に HOME/PATH/locale/terminal 等の非秘密 allowlist と `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` だけを渡す。第四層として settings source を `project` のみに固定し、`--strict-mcp-config` を `--mcp-config` なしで渡して通常構成から MCP server を要求しない。組織の managed policy は wrapper 外の導入 trust base であり、ここで除去を保証しない。API key 環境変数を Claude 認証に使う構成は Atlas Builder の I-024 と両立しないため、CLI login/config store を使う。secret-required verification は Agent session 内では実行しない(§11.4)。通常の非秘密 test は sandbox 内で許可され、その exit code と redact 済み要約だけを evidence にする。

対象の In-Project Agent 設定は Atlas Builder が規定しないため、その安全性にも依存しない。対象 runtime はライブ起動せず、検証は §10 の隔離 runner または Agent 外の人間実行へ落とす。

---

## 17. Over-Project Agent `CLAUDE.md`

本書で Atlas Builder が用意する実行憲章は **Over-Project Agent 用**(`CONTROL_ROOT/CLAUDE.md`)だけである。
これが Atlas Builder を司る本体の憲章であり、常に存在する。

**対象側 `CLAUDE.md`(In-Project Agent 用)は Atlas Builder の管轄外である。** 対象がエージェントを内包する
場合、そのエージェントが従う `PROJECT_ROOT/CLAUDE.md` / `.claude/**` は対象プロダクトの内容物であり、
対象の Essence から普通に生まれる(§5.0, §6.2)。Atlas Builder はそこに憲章の雛形を seed せず、
`delegation` / `inbox` / `outbox` / `result contract` といった Atlas Builder 固有の語彙を一切書き込まない。
In-Project Agent は Atlas Builder を知らないのだから、その憲章に Atlas Builder が現れることはない。したがって
本章に「対象側 CLAUDE.md のテンプレート」は存在しない — それは Atlas Builder が規定すべきものではないからである。

### 17.1 Over-Project Agent `CLAUDE.md`

`CONTROL_ROOT/CLAUDE.md`

```markdown
# Over-Project Agent Execution Charter

You are the Over-Project Agent.

You must run only from `CONTROL_ROOT = ./.atlas-builder`.

Your job is to map the human Essence in `../PROJECT_TITLE/ESSENCE.md` into canonical Spec, Todo, implementation, and verification.

## Path Vocabulary

```text
CONTROL_ROOT       = ./.atlas-builder                      (this directory)
PROJECT_ROOT       = ../PROJECT_TITLE
PROJECT_STATE_ROOT = ../PROJECT_TITLE/.atlas-builder
```

## Non-negotiable Rules

1. Never edit `../PROJECT_TITLE/ESSENCE.md` or anything under `../PROJECT_TITLE/essences/**` (both human-only, I-004).
2. Never run Claude Code from the workspace root.
3. Treat `../PROJECT_TITLE/.atlas-builder/state/*.json` as the project canonical state, and mutate it only through `bin/atlas-builder state`.
4. Treat `./.agent/state/*.json` as Atlas Builder control-plane state.
5. You may directly edit implementation files under `../PROJECT_TITLE` when allowed by policy. If the project embeds an In-Project Agent, its code and configuration are part of what you develop this way.
6. The In-Project Agent (if any) is untrusted executable product content, not your subordinate. Never launch it directly in the live project. Use only a project-defined isolated runner with no live Atlas Builder-state or secret access; otherwise raise a Human-input Recommendation.
7. The project's `.claude` / `CLAUDE.md` configuration (if any) is the project's own; never adopt it as your own configuration, and never write Atlas Builder's vocabulary into it.
8. Agent runtime paths are high-risk and require explicit evidence and review (only where they exist).
9. User-facing responses must be Japanese.
10. Code, identifiers, and comments should be English unless the project requires otherwise.

## Imported Rules

@.claude/rules/authority.md
@.claude/rules/workflow.md
@.claude/rules/high-risk-agent-runtime.md
@.claude/rules/state.md
@.claude/rules/context-reset.md
@.claude/rules/error-recovery.md
@.claude/rules/recipes.md
@.claude/rules/model-policy.md
@.claude/rules/safety.md
```

これは `init.sh`(`just init`)が `templates/control/CLAUDE.md.tmpl` から生成する**束縛版**である。配布状態の `CONTROL_ROOT/CLAUDE.md` は「未束縛」の安全版で、対象作業を行わず束縛手順のみを案内する。init 実行時に上記の束縛版へ上書きされる。

---

## 18. Scripts

### 18.1 Atlas Builder Scripts

All Atlas Builder scripts live under:

```text
CONTROL_ROOT/scripts/
```

| Script                      | Purpose                                                                 |
| --------------------------- | ----------------------------------------------------------------------- |
| `_lib.sh`                   | 全 wrapper の共通安全基盤: CWD/束縛検査、single-flight lock、trust gate、Claude 環境 sanitize、read-only session sandbox、checkpoint guard |
| `init.sh`          | 未束縛の制御プレーンを 1 対象へ束縛(`templates/control/*.tmpl` を生成)し、続けて bootstrap まで実行 |
| `doctor.sh`        | CWD, file layout, Claude Code availability/trust, Git readiness, settings, hooks, schema, および 1:1 束縛整合(`project_index.json` の単一 `project` が束縛対象名と一致、§5.2 §8.1)を検査。対象側 `.claude/` の検査は **対象がそれらを持つ場合にのみ** settings.json の存在・parse 確認に留め(内容は対象の所有物であって Atlas Builder は検査しない、§16.2)、存在しなければその不在を正常として扱う(§5.0) |
| `bootstrap.sh`     | 対象へ雛形を seed し、`atlas-builder state ensure`(state 生成 + project_index 登録)→ validate |
| `loop.sh`          | 継続自律ループ。実行した cycle ごとに Git checkpoint commit を作成。停止ゲート中は副作用ゼロで拒否(§13.4)。単一実行ロックと中断 trap を持つ(§13.5) |
| `once.sh`          | 1 cycle 実行                                                              |
| `stop.sh`          | 人間専用: 走行中の loop への graceful drain 要求(`just stop`、§19.1-7)。次の cycle 境界(checkpoint commit 後)で loop を gate なしの exit 0 で止める非同期シグナル。`--cancel` で撤回。canonical state には一切触れない |
| `status.sh`        | 状態要約 + gate 評価と次アクション案内                                       |
| `watch.sh`         | 人間専用: 走行中 loop の常駐監視 TUI(`just watch`、§15.3)。読み取り専用の純オブザーバ — 約 1s ごとに lock / drain / heartbeat / canonical state / `tool_audit.jsonl` を観測して `atlas-builder state watch-render` の 1 フレームを描き直す。loop 不在時も last-known heartbeat で描画継続。`q` で終了し、終了は loop に無影響 |
| `resume.sh`        | 人間専用: exact `--resolve` ID / phase 判断による停止ゲート解除、途中修正の checkpoint、`--force` でのクラッシュ回復(§13.3 §13.5)+ review checkpoint commit。supervise authorizing gate への `--resolve` は拒否し、明示撤回は `--retract-approval`(§13.3-4'')。gate を 1 件も動かさず人間所有入力の編集だけを記録するのは `--steer-only`(§13.3-4''')。`--note` は必須で、引数は厳格に解釈し、note は制御文字をサニタイズする |
| `triage.sh`        | 人間専用: 停止ゲートの対話的 triage(§13.6)。read-only の対話 Claude セッション(`/triage`)を起動し、人間必須の項目は手順に分解、調査で決着する項目は代行で打ち取り、note と exact decision list を表示して確認(y)を得た場合のみ targeted resume へ引き継ぐ |
| `supervise.sh`     | 人間専用: 必須 `--todo T-...`(任意 `--recommendation R-...`)で承認済み High-Risk Todo 1 件へ束縛する single-flight session。sanitize 済み環境、同じ permissions/hooks/sandbox の下で人間が ask を判断し、dirty diff を exact Recommendation の `just resume --resolve` へ引き渡す(§12.1、§21.3) |
| `essence.sh`       | 人間専用: `ESSENCE.md` の対話起草/改稿(Essence interview、§2.1.4)。read-only の対話 Claude セッション(`/essence`)を起動し、wrapper が全文(既存の実 Essence を置換する場合は REPLACE 明示 + diff、§2.1.4-4)を表示して確認(y)を得た場合のみ設置する。`--mode new`(`just new-essence`)は理想発掘(枷外し)フェーズ → クリティカル順の全節インタビュー — 実体のある Essence が既にあれば拒否。`--mode update`(`just update-essence`)は**変更意図を最初に質問**し、背後の理想の軽量発掘と延期 Won't の昇格点検を経て意図の範囲だけを改稿 — 実体のある Essence が無ければ拒否。束縛前後どちらでも動く |
| `xlsx-dump.py`     | `essence.sh` の起動前処理(§2.1.4-2): `PROJECT_ROOT/essences/` 配下の Excel ブックをテキストのセル一覧として handoff dir へダンプする。stdlib のみのゼロ依存で、セッションの許可面・書込み面を一切変えない人間側前処理 |
| `claude-trust.sh`           | 人間の明示操作として Claude Code trust を `~/.claude.json` に設定(`just trust` = `--apply`)/検査のみ(`just trust-check` = `--check`、書込みなし)。実体は `bin/atlas-builder trust ensure|status`(§31.2-8)   |

Atlas Builder は特定プロジェクトに依存しない汎用テンプレートとして配布される。配布状態の `.claude/settings.json` / `CLAUDE.md` / `justfile` は**どの対象にも束縛されていない安全版**であり、`init.sh`(`just init`)が `templates/control/` の bind テンプレートから対象名を差し込んで束縛版を生成する。1 つの制御プレーンは 1 つの対象に束縛する(別対象への再束縛は `--force`)。

制御プレーンの実行系はゼロ依存の Lean バイナリ `bin/atlas-builder` である(§31)。runtime 要件は「バイナリがビルド済みであること」だけであり、`doctor.sh` は「バイナリ存在 + `atlas-builder version` 応答 + `lean/lean-toolchain` 同梱」を検査する(ビルドには elan によるツールチェーン取得だけが必要で、実行時のネットワーク・外部 runtime は不要)。doctor 自身の JSON 診断も同じバイナリで行う — settings の安全配線検査は `atlas-builder util settings-doctor`(純粋核 `Looper/Core/SettingsDoctor`)、launcher スクリプトのソース断片検査だけが素の `grep` として doctor に残る。lint / format のツール(`shellcheck` / `shfmt`)はフレームワークのソースを保守するためのものであって制御プレーンの runtime ではなく、permissions/hooks の境界強制を外部ツールやネットワークに依存させない。

### 18.2 Standard Operation

Human-facing standard operation uses `justfile`. The recipes delegate to the controlled scripts under `CONTROL_ROOT/scripts/`; direct script commands remain the permissions/hooks implementation contract. 束縛後は `justfile` に対象が焼き込まれるため、各レシピで `--project` を再指定する必要はない。具体的なコマンド手順の正本は、セットアップが §26.1 / §26.2、停止対応(triage・High-Risk supervise を含む)が §26.3、人間介入(resume)の入口が §13.3 である。

`just trust` is a human-only setup command because it writes `~/.claude.json`. Without it, Claude Code may ignore Atlas Builder's project permissions/hooks, so `just doctor`, `just once`, `just loop`, and `just supervise` treat missing trust as a hard gate. 対象 runtime のライブ CWD は trust 対象にせず、直接起動もしない(§10)。

`just resume` is likewise human-only: it records a human intervention (§13.3) and creates the review checkpoint commit — releasing only the `--resolve`-selected stop gates (and an explicit Must-boundary decision) when the loop stopped, or checkpointing the human's mid-course edits when nothing is latched (steering). `atlas-builder hook pre-tool` denies it to agents.

**Human-only の境界は resume に限らない。** `atlas-builder hook pre-tool` は resume、loop / once / stop、init、doctor、trust / trust-check、triage、supervise、essence interview、watch を agent に deny する。doctor/trust-check は診断でも `~/.claude.json` を読むため、I-024 を保つには Agent の sandbox 内から実行できない。bootstrap は ask、status / `bin/atlas-builder state` の許可 subcommand は Agent 実行可である。raw nested `claude` は ask ではなく **deny** であり、隔離 runner が無ければ Human-input Recommendation に落とす(§10)。supervise だけが High-Risk ask を人間同席で越える標準経路である。

**Loop-owned の境界も同様に hook が強制する。** `bin/atlas-builder state` のうち `start-run` / `end-run` / `record-progress` / `reset-context` / `raise-loop-gates` は cycle 境界で `loop.sh` だけが呼ぶ遷移であり、`atlas-builder hook pre-tool` が agent に deny する。cycle 中の agent がこれらを叩くと、維持している信号そのものが壊れるためである: 途中の `record-progress` は署名 baseline を動かして cycle 終端の判定を狂わせ(実作業が「idle」と読まれ idle watchdog が誤作動/飢餓する)、野良 `start-run` は dangling run を生んで偽のクラッシュ回復を誘発し、`raise-loop-gates` の直接実行は `raised_by: "atlas-builder-loop"` の偽装になる(§21.5-1)。さらに `bin/atlas-builder state` の変異コマンドは、`--project` が project_index に登録済みの束縛対象と一致しない場合を拒否する(1 制御プレーン = 1 対象。`ensure` で兄弟ディレクトリへ state を勝手に生成・登録する経路を閉じる)。`project_index.json` は単一 project オブジェクトであり(§8.1)、`validate` / `doctor` はその `project` が束縛対象名と一致することを検査する(§5.2)。

`just once` / `just loop` require a clean Git worktree at the start of each cycle and create one checkpoint commit at cycle end. The initial files created by `just init` must therefore be reviewed and committed by the human before the first loop. Agents may inspect Git status/diff, but staging and committing are owned by `loop.sh` during Atlas Builder cycles.

停止したときの標準手順は常に同じであり(§13.4)、runbook は §26.3 が正本である(`just status` → 原因確認(必要なら `just triage`、§13.6)→ `just resume --resolve <ID> --note "..."` → `just loop`)。停止ゲートが latch されている間の `just loop` 再実行は安全である: 何も書かず、何も commit せず、同じ理由と手順を表示するだけである(I-019)。「再実行すれば進むかもしれない」という期待に意味はなく、進めるのは `just resume` だけである。

### 18.3 Forbidden Operation

```bash
cd ..
claude
```

Workspace root からの Claude Code 起動は禁止する。

### 18.4 Framework Source vs Control Plane — 2 つの justfile (I-028)

`just` コマンドには**主語(subject)が違う 2 種類**がある。両者を同じ名前空間に置いてはならない。

| | 主語 | 実行者 | 置き場所 |
| --- | --- | --- | --- |
| **運用レシピ** | 束縛された対象プロジェクト | ワークスペースの運用者 | `CONTROL_ROOT/justfile`(`templates/control/justfile.tmpl` が束縛版を生成) |
| **ソースレシピ** | Atlas Builder 自身のソース | フレームワークの保守者 | フレームワークリポジトリの **root の `justfile`**(配布ディレクトリの外) |

`loop` / `once` / `stop` / `status` / `watch` / `resume` / `triage` / `supervise` / `init` / `doctor` / `bootstrap` / `build` / `trust` / `trust-check` / `new-essence` / `update-essence` / `state` は運用レシピである。`test` / `proofs` / `purity-gate` / `render-static` / `recipe-lean-build` / `looper-lock-check` / `meta-compose` / `meta-check` はソースレシピである。**shell の lint / format / fmt-check はここに無い** — 本リポジトリはもう自分のシェルを 1 本も持たないからである(§31.1 R-14: `scripts/**`・レシピ同梱シェル・`ci/**` はすべて共通実装の正本から配布される)。`format` は**書き込む**ので、所有していない木に対する整形レシピを残すと「正本を直さないまま lock だけが割れる」経路になる。整形と lint は正本側で、同じ `.editorconfig` の下で、バイトが repo を出る前に行われる。

**静的設定の投影(`render-static`)。** 制御プレーンの静的設定 JSON(§8.1 の workspace.json と未束縛 project_index.json シード)の正本は `lean/Looper/Core/StaticConfig.lean` であり、`atlas-builder util static-config {workspace|project-index-seed}` が rendered バイト列を stdout へ出力する純 render 面(`util render` / `util seed` の隣)を提供する。配布物の再生成は maintainer の仕事なので、再生成レシピ `just render-static` はこの root justfile に置く。定義変更 + JSON 未再生成のコミットは D-008 が `just test` で検出する。

**配布された正本の凍結(`looper-lock-check`)。** `lean/Looper/**` / `scripts/**` / `recipes/agentic-state-loop/**` は共通実装の正本から配布された複製であり(§31.1 R-14)、本リポジトリで直接編集してはならない。`just looper-lock-check` は配布時に記録された `ci/looper-src.lock`(面の宣言 + sha256 + 実行ビット)と実ツリーを照合してそれを検出する。主語はフレームワークのソースなのでソースレシピであり、CI の全 push で走る。

**判定は 1 つのテストで行う。**

```text
「配布された束縛済み制御プレーンで、そのコマンドは意味を持つか?」
  Yes → 運用レシピ  → CONTROL_ROOT/justfile
  No  → ソースレシピ → フレームワークリポジトリ root の justfile
```

**なぜ分離が必須か。** `.atlas-builder/` は**配布単位そのもの**である(利用者はこのディレクトリを丸ごと受け取る)。したがって `.atlas-builder/` に置いたものは全利用者に配られる。`just test` を `.atlas-builder/justfile` に置くと、束縛済み制御プレーンで `just --list` に現れ、運用者が叩けてしまう — しかも検査されるのは**運用者のプロダクトではなく Atlas Builder 自身のソース**であり、`just` の発見面が嘘をつく。同じ理由で開発ツールの設定(`.editorconfig` 等)も配布物から外す: 束縛済み制御プレーンの runtime は設計上ゼロ依存の Lean バイナリ `bin/atlas-builder` であり(§18.1、§31)、追加のツールチェーンを一切必要としない。

**配布・コマンド境界は topological、file access 境界は enforcement で成立する。** Over-Project Agent の CWD は常に CONTROL_ROOT(I-002、`assert_control_root`)で、配布物は `.atlas-builder/` のみなので、source root の `justfile` は bound control plane の実行レシピ名前空間に存在しない。これは「親/sibling path が物理的に読めない」という ACL ではない。同じ source repository 内で framework を開発するときは filesystem 上は到達可能だから、live CONTROL_ROOT 自己変更は permissions/hooks/sandbox の deny、source root の変更は人間の maintainer plane と source-repository review/test が担う。root から Claude Code を起動することも禁止する(I-001)。**保守者の平面**(source root)と**運用者/エージェントの平面**(配布された `.atlas-builder/`)の分離は、配布境界と実行時 deny の両方で成立し、CWD だけをアクセス制御とは呼ばない。

**設計正本 `META.md` は所有物ではなく合成物である。** §0–§31(共通章)は Over-Project ループの**機構の記述**であり、機構が全ドメインで単一実装である以上、その散文をドメインごとに保持する理由は無い — 保持すれば割れる。実際に割れていた: 人間所有パスの目録(§24)から `essences/**` が片側だけ落ち、見出し集合の主語(§2.1.1)は既にドメイン軸になっていたのに「推奨テンプレ」と呼ぶ記述が残っていた。共通章は配布物 `meta/base.md` として配られ、ドメイン章と差し込みだけが `meta/domain.md` として制御プレーン側の所有になる。`META.md` は両者の合成であり、`meta-compose` が書き、`meta-check` が突き合わせる(どちらもソースレシピ)。差し込み口は base 側が宣言し値は domain 側が宣言する — **どちらか片方にしか無い口は合成そのものを拒否する**(欠ければ穴が開いたまま合成され、余れば「書いたのに出ない」断片が残る)。製品識別子の綴りは 1 語幹から導出するので base に製品名は 1 つも現れず、未解決の綴りが残った合成も拒否する(§31.1 R-13)。

**素材は maintainer plane に住み、制御ルートには合成物だけが住む。** 合成の素材は運用者へ配る物ではなく保守者の材料であり、上の 1 つのテストで「ソース」側に落ちる。加えて、素材を配布単位へ入れれば**それは Agent の前に現れる新しい制御プレーン面**になり、§11.3 の列挙と §16.1 の deny を 1 つ増やす話になる — 増やし忘れがそのまま穴になる。読まれる設計正本は制御ルートの 1 枚でよい。同じ規律で `.claude/rules/**` の**見出し構成**も名簿 `meta/rules.outline` として配る: 本文は製品の声で書かれる所有物だが(§17)、骨格は共通実装への指示の目次であり、節が 1 つ落ちれば Agent への指示が 1 つ落ちる — それは言い回しの違いとは別の失敗である。

**対象プロダクト自身の lint / test は第 3 の主語である。** それは対象の tooling(`npm run lint`、`pytest`、…)が持ち、エージェントが `cd ../{project-title} && ...` で叩く(permissions の allow、§16.1)。Atlas Builder のレシピにしてはならない — 運用レシピの主語は「対象プロジェクトに対する Atlas Builder の操作」であって、「対象プロジェクトのビルド系」ではない。

**運用レシピ内部の第 2 の質的軸 — `[group]`。** 運用レシピもまた均質ではなく、`atlas-builder hook pre-tool` は既にこれを 3 分類して機械的に強制している(§18.2)。`justfile` の `[group]` 属性はこの 3 分類を `just --list` へ投影したものであり、装飾ではない — hook の分類とズレたら `just --list` が嘘をつく、という対応関係で保つ。

| group | 意味 | hook の扱い |
| --- | --- | --- |
| `human-only` | 人間専用の遷移・秘密設定診断・常駐対話プログラム | agent に **deny**(I-011/I-024): `init` / `trust` / `trust-check` / `doctor` / `new-essence` / `update-essence` / `once` / `loop` / `stop` / `resume` / `triage` / `supervise` / `watch`(watch は遷移でも秘密診断でもないが、常駐 TUI を cycle 内で起動すると戻らないプロセスとして cycle が wedge する — §15.3) |
| `approval` | 人間の明示承認があれば agent も可 | **ask**: `bootstrap` / `build` |
| `inspect` | Agent-safe な診断・非 human transition。`validate` は診断が意味的に変わった場合だけ `validation.json` を更新する(§20.5) | **allow**: `status` / `state`(subcommand 単位) |

`state` だけは group が分類を代表しない — hook は `bin/atlas-builder state` の**サブコマンド単位**で判定するため(`state resume` は human-only、loop 所有の遷移は deny、残りは allow)、レシピ自体は `inspect` に置き、境界はサブコマンドが担う。

---

## 19. Loop Semantics

### 19.1 Atlas Builder Loop

```text
loop.sh
  -> assert CWD == CONTROL_ROOT
  -> assert Claude Code trust for the Atlas Builder launch root
  -> acquire single-flight loop lock (I-018)
  -> clear stale drain request                        # §19.1-7: 前回呼び出し宛ての残骸を除去
  -> build bound session settings overlay             # §16.1: lock 後・invocation につき 1 回
  per cycle:
    -> atlas-builder state should-stop / should-complete   # pre-gate: 読み取りのみ (I-019)
         gated?    -> report + resume hint, exit (no run, no commit)
         complete? -> report, exit 0            (no run, no commit)
    -> assert clean git worktree (I-014)
    -> atlas-builder state ensure
    -> atlas-builder state start-run
    -> atlas-builder state validate
    -> atlas-builder state should-reset (if due: reset-context, next session fresh; §14.1 backstop applies)
    -> write loop heartbeat                           # §19.1-9: display-only, best-effort
    -> claude -p / claude -c -p with Atlas Builder prompt
    -> atlas-builder state end-run
    -> atlas-builder state record-progress
    -> atlas-builder state raise-loop-gates                # §13.4: 停止条件の実体化
    -> atlas-builder state validate
    -> git checkpoint commit for this cycle (I-013)
    -> consume drain request (`just stop`)            # §19.1-7: 境界で消費、gate 判定が先
    -> atlas-builder state should-stop / should-complete   # post-gate: exit before next cycle
    -> exit 0 if a drain was consumed                 # §19.1-7: DRAIN として報告
    -> exponential backoff if claude could not launch # §19.1-8: 起動失敗のみ、中断可能
```

停止・完了の検出タイミングと副作用の関係は次で固定する。

1. **cycle 開始前に検出**(pre-gate): 副作用ゼロで終了する。run 記録なし、カウンタ変化なし、commit なし(I-019)。ラッチ済み停止下の再実行はこの経路に入る。
2. **cycle 中に発生**: その cycle は通常どおり finalize され、`raise-loop-gates` が停止条件を Recommendation として実体化した上で、checkpoint commit の run status に停止/完了理由が刻まれる。その後 post-gate でループが終了する。
3. **predicate の失敗**(exit code 2 以上)は「停止条件なし」と解釈してはならない。ループはハードエラーとして即終了する。壊れた predicate が停止ゲートを静かに外すことを防ぐためである(`status.sh` の表示も同じ規則に従い、predicate の失敗を「RUNNABLE」と報告しない)。
4. **claude が非ゼロ exit した cycle の次セッションは fresh で開始する。** 失敗した継続(`-c`)を継続し続けると、継続不能な状態(再開すべき会話が無い等)から自己回復できない。正しさは fresh 再開に依存する(§14、§28.4)ため、失敗後の継続に価値はない。その非ゼロ exit が infra 起因(§13.1-12)なら、loop は `record-progress` に run status を渡して `progress.infra_fails_since_ok` を進め、`ok` cycle でゼロに戻す。連続が閾値に達した cycle は `raise-loop-gates` が `infra_unreachable` ゲートを実体化し、post-gate で停止する(§13.4)。プラン/モデルの利用上限(§13.1-12')なら run status は `usage` であり、`progress.usage_limited_since_ok` と `usage_limited` ゲートが同じ形で対応する。
5. **cycle の設定 source・環境を起動時に固定する。** ループは `claude -p` を `--setting-sources project --strict-mcp-config` 付き、`--mcp-config` なしで起動する。user/local settings をロードせず、通常の user/project/local MCP 構成からサーバを受け取らない。第 4 の固定要素として、launcher は single-flight lock 取得後に生成した bound overlay(§16.1 — パス系 permission ルールと sandbox の全体)を `--settings` で渡す: overlay は起動時のみ読み込まれ、invocation の間は不変である(project source の base 側だけが hot-reload される、§28.5-3)。組織が外部から強制する managed policy はこの wrapper が除去できると主張せず、導入時の trust base とする。求める性質は **fail-closed の床**である: project settings が構文エラー・将来差分で拒否されても、prompt-worthy な操作を自動許可しない。project settings の明示 allow と hook の allow だけが実行でき、ask は headless session で自動 deny される。relaxed profile(§11.5)下でもこの床の**機構**は不変である — 変わるのは「hook が明示 allow を返す面」が緩和 6 葉 + Bash 無意見葉へ広がることだけであり、依然として settings allow ∪ hook allow の外は実行されない(deny 床 I-030 は hook / settings の deny として残る)。さらに `env -i` + 非秘密 allowlist + subprocess credential scrub で operator/parent の秘密を子プロセスから除去し、必須 OS sandbox が利用不能なら起動自体を失敗させる(§11.4、§16。`profile: unsandboxed` の配備だけは人間の明示宣言により sandbox 必須が外れる — §11.5 の信頼モデル縮退)。

   **床を支えているのは 2 つの機構であり、片方は現行 CLI で不活性である(実測: Claude Code 2.1.209)。**

   1. **`dontAsk`(宣言)。** 未マッチのツールを deny に写像するため `permissions.defaultMode` に置く。現行 Claude Code は `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` 下で mode 解決を short-circuit して `default` を返すため、自律 launcher は不活性な `--permission-mode dontAsk` を渡さない。headless `-p` が未マッチ操作の ask を表示不能にして deny する実効床であり、CLI の警告も出さない。宣言は非 scrubbed/manual launch と将来の CLI に対する fail-closed baseline として維持する。
   2. **headless(`-p`、現在これが実際に deny している)。** `default` は未マッチのツールを ask に写像するが、`-p` の session は `shouldAvoidPermissionPrompts` が立ち、**提示できない ask は deny になる**。deny / ask ルールと hooks は従来どおり評価されるので、床は保たれる。

   したがって **`-p` は load-bearing** である。CLI が `default` を強制したまま headless をやめれば、prompt-worthy な操作を拒む主体が誰もいなくなる。`doctor.sh` は launcher の実環境で実効 mode を probe し、まさにその組み合わせで fail する(§28.5)。`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` にして `dontAsk` を復活させる道は取らない — I-024 の防御層(親 CLI が login/provider config から得た credential を Bash/hooks/MCP 子から再除去する層)を捨てることになるためである。CLI が案内するもう一方の出口(`--allowed-tools` の明示宣言)も採らない: 同じ境界を `settings.json` の allow が既に張っており、二重管理は I-029 の「setting source は project のみ」方針と噛み合わない。
6. **ループの exit code は「呼び出しが正しく実行されたか」だけを表し、終端の種別は運ばない。** 設計上の終端 — `full_complete`(§19.3)、ラッチ済み停止ゲート(`must_complete_awaiting_phase_approval` を含む)、`--max-cycles` 予算到達、graceful drain(`just stop`、§19.1-7)— はいずれも**正常終了(exit 0)**である(停止の報告様式は §13.4-3)。非ゼロは障害・拒否のみを意味する: usage / 環境 / predicate クラッシュ = 2、git 前提の拒否(dirty worktree、checkpoint guard)= 4、single-flight ロック競合 = 5、割り込み = 129(SIGHUP)/ 130(SIGINT)/ 143(SIGTERM)。「いま停止/完了しているか」を機械的に知りたい呼び出し側は、exit code ではなく `atlas-builder state should-stop` / `should-complete`(exit 0 = yes / 1 = no の predicate)または `just status` を照会する — ゲート状態の正本は canonical state であって、直近のループ呼び出しの終わり方ではない。
7. **graceful drain(`just stop`)— cycle 境界での協調停止。** 人間は走行中の loop に「次の cycle 境界でキリよく止まってほしい」を**非同期に**伝えられる: `just stop`(= `bash scripts/stop.sh --project ...`)。実体は `CONTROL_ROOT/.agent/state/loop.drain` の存在フラグであり、loop は checkpoint commit 後・post-gate 判定の**直前**にこれを消費し、gate が何もラッチしていなければ `DRAIN` として exit 0 する — `--max-cycles` 予算と同カテゴリの設計上の終端(§19.1-6)であって停止ゲートではない。中断(§13.5 の Ctrl-C / SIGTERM)との違いがこの機構の存在理由である: 実行中の cycle は完走して checkpoint を作り、worktree は clean のまま、run 記録も正常に閉じるため、**resume は不要** — 次の `just loop` がそのまま続きを回す(離席・移動・シャットダウン前の停止に使う)。取り消しは `just stop --cancel`。設計上の固定点は 4 つ:
   - **canonical state に一切触れない。** drain は人間が自分の loop 呼び出しの予算を運用都合で縮める操作シグナルであり、§13 の停止語彙(gate・`should-stop` reasons・`Atlas-Builder-Run-Status` trailer §24.3)には決して現れない。エージェントへのハンドオフ(§13.4)と人間のセルフペーシングを混ぜると、停止理由の可視化原則が「誰の都合による停止か」を運ばなくなる。フラグは gitignore 済みで、残留しても I-014 の clean worktree 検査を汚さない。
   - **gate が常に勝つ。** 同じ cycle 境界で停止/完了 gate がラッチした場合、loop は従来どおり STOP / COMPLETE を報告して resume 契約へ引き継ぐ(drain フラグは gate 判定の前に消費済みなので残骸も残らない)。drain が canonical な停止報告を隠す経路はない。
   - **要求は自分が狙った呼び出しにしか効かない。** loop は lock 取得直後に既存フラグを警告付きで除去する — gate 停止やクラッシュを生き延びた要求が、次の `just loop` を 1 cycle で静かに殺してはならない。`stop.sh` 側も対称に守る: 生きた single-flight 保持者(I-018)が居なければ登録せず(stale フラグの掃除のみ)、保持者が loop 以外の遷移(resume / supervise 等)なら登録を断る(process 検査が答えられない環境では、警告付きで登録側に倒す — 誤配の最悪は次回起動時の警告 1 行であり、real loop 下での黙殺は人間を来ない停止で待たせるため)。
   - **human-only。** フラグの置き場 `.agent/state/` は全 profile で agent の書込みが遮断され(settings の Edit deny + `isProtectedWriteTarget` の Bash mutator deny + sandbox `denyWrite` — I-030 の deny 床)、`.agent/tmp`(handoff 面)に置くと in-cycle agent に「loop を止める」「人間の stop を握り潰す」の両チャネルを渡してしまうため、置き場自体が境界である。`just stop` / `stop.sh` の綴りも hook が human-only として deny する(§18.2)。エージェントが loop を止めたいときの正道は従来どおり canonical Recommendation を記録して停止することである(§13.4)。
8. **起動失敗の指数バックオフ。** `claude` が起動できなかった cycle(run class が `usage` / `infra`)の後、loop は次の試行までの待機を取る。待機は連続失敗数で倍加し、上限で頭打ちになる: 利用上限は base 300 秒、infra は base 30 秒、上限は 1800 秒である。上限の基点が一桁違うのは、上限がプロバイダ側の時計でリセットされる(分〜時間)のに対し、到達性の問題はもっと早く解けることが多いからである。CLI 自身が待機時間を述べている場合(`Retry-After: N` / `retry after N seconds` 等の**継続時間**表現)、それが梯子より長ければ上限内でそちらを採る — 壁時計のリセット時刻(`resets at 3pm (Asia/Tokyo)`)は解析しない: locale/timezone 依存の日付解析は移植性も CLI 文言の安定性も低く、誤読は「数時間の空停止」か「バックオフの無効化」のどちらかを生む。梯子が常に床にある以上、ヒントの取り逃しはせいぜい 1 段分の損である。

   待機は 3 つの位置的制約を持つ。(a) **post-gate 判定の後**に置く — ラッチした gate は人間へのハンドオフであり、人間が見ることのない待機で遅らせてはならない。(b) **drain 消費の後**に置く — `just stop` は既にこの境界で終われと言っている。(c) **中断可能**である — 素の `sleep N` は bash の trap を N 秒間据え置くので、20 分の待機に入った無人 loop は Ctrl-C を 20 分無視する。短い刻みでバックグラウンド子を `wait` し、刻みごとに drain フラグも見る。

   実走行 2026-08-12 の起動失敗 3 連続は 30 秒 / 3 秒 / 3 秒 — 実質バックオフ無しの再試行 — で約 40 秒のうちに安全カウンタを使い切っていた。待機が無いと、しきい値は「上限が解けるまでの時間」ではなく「連続で叩く速さ」を測ってしまう。

9. **loop heartbeat — 表示専用の runtime machine state。** cycle 番号 n/max・run_id・session_mode・開始時刻は、これまでどの観測面にも現れなかった(runs.jsonl は run の開始/終了を刻むが「この loop 呼び出しの何番目の cycle か」を知らない)。loop は cycle 開始処理の最後 — SESSION_MODE 確定後(should-reset 判定と §14.1 の session backstop の後)、claude 起動直前 — に、`CONTROL_ROOT/.agent/state/loop.status.json` へ現在サイクルの観測を atomic に書き出す(`atlas-builder util loop-heartbeat`。スキーマ v1: `schema_version` / `project` / `cycle` / `max_cycles` / `run_id` / `session_mode` / `started_at`(+`_epoch`)/ `loop_pid` / `loop_started_at`(+`_epoch`)— epoch 併記は読み手の経過時間計算をタイムゾーン逆パース非依存の整数減算にするため)。`just watch`(§15.3)だけが読む表示専用ファイルであり、設計上の固定点は 5 つ:
   - **canonical ではない。** どの述語・遷移も heartbeat を読まない。欠損・破損・改竄は gate 評価にも commit にも cycle の実行にも影響せず、watch が「不明」を表示する以上の帰結を持たない。
   - **置き場は drain と同じ `.agent/state/`。** 全 profile で agent の書込みが遮断される I-030 の deny 床(§19.1-7 と同じ理由)。handoff 面(`.agent/tmp`)に置くと、暴走中の agent が「cycle 3/25 正常」の heartbeat を偽装し続ける・消して観測を劣化させる経路を人間の監視窓に対して開いてしまう。
   - **gitignored(§25)。** 残留しても I-014 の clean worktree 検査を汚さない。
   - **書き出しは best-effort。** 失敗は warn のみで cycle を止めない — 表示補助の書込み失敗が本体の実行を殺すのは本末転倒である。
   - **鮮度の正本は heartbeat 自身ではなく I-018 lock の生存 + 書き手 pid の一致。** loop 終了時に削除しない(watch の last-known 表示 — 停止直後に「最後はどの cycle だったか」を確認する用途に使う)。「いま走っているか」は lock で判定し、heartbeat は「最後に観測された cycle はどれか」だけを運ぶ。lock が生きていても heartbeat の `loop_pid` が lock の pid と食い違えば、それは前回呼び出しの残存記録であり、watch は last-known として表示する — lock 取得から最初の heartbeat 書き出しまでの窓や、gate 拒否で cycle が始まらない呼び出しの間、前回 cycle が live として誤報され続けることを防ぐ。

10. **サイクル連番。** `project.json.cycle_seq` は `start-run` だけが進める正式な連番であり、`append-reflection` / `append-lesson` はそこから `cycle` を刻む。エージェントが自分で番号を申告する余地は無い — 実走行 2026-08-12 では番号が reflection エントリ内の自己申告しか無く、起動失敗で記録が残らなかった 3 cycle は台帳から欠落し、以降の番号は次 cycle の自称で継続していた。`project.json` は agent が書けない §8.2 のファイルなので、この連番は**申告ではなく事実**である。壊れた値からは 0 起点で数え直す — 連番の破損で cycle を開始できなくする理由はない。

### 19.2 One Atlas Builder Cycle

```text
1. Observe Control Root and Project Root.
2. Read PROJECT_ROOT/ESSENCE.md.
3. Read PROJECT_ROOT/README.md.
4. Read PROJECT_ROOT/.atlas-builder/state/*.json.
5. Validate Essence > Spec > Todo > Impl trace.
6. Stop on Essence Blocking, human approval/input wait, or idle-cycle safety threshold.
7. Select Todo batch.
8. Execute by Over-Project Agent direct edit (executor `atlas-builder`). For an ask-gated High-Risk change, record a stopping Recommendation for `just supervise`. For embedded-agent behavior, use only a project-defined isolated runner (§10); otherwise stop for human evidence.
9. Verify.
10. Recover implementation errors if possible.
11. Update JSON canonical state.
12. Append reflection (`bin/atlas-builder state append-reflection --file <entry.json>`), and any cross-cycle lesson worth keeping (`append-lesson`, §14.3).
13. Decide reset.
14. Return to `loop.sh`, which performs final validation and commits the cycle checkpoint.
```

### 19.3 Completion Semantics — Explicit Completion Scope

**Must 完了は、人間が最終 scope を選ぶフェーズ・ゲートである。** must が全 done になっただけで即 `COMPLETE` にすると should を黙って無視する。一方、「必ず should まで実行する」も、人間が Must scope で十分と判断する正当な終端を表せない。そこで must 完了時は必ず一度停止し、人間が **Should まで進む**か **Must で閉じる**かを明示的に選ぶ。前者は `extended_approved`、後者は `closed_at_must` という異なる terminal scope を作る。単にループを起動しないことは完了記録ではなく、`--close-at-must` が明示的な closure である。

**優先度は 2 段である — could を持たない。** Todo の priority は `must` / `should` の 2 段であり、第三の段 `could` は存在しない(§9.1)。could 段を置かないのは、それが人間の書く優先度(テンプレート §2.1.1 — MoSCoW から Could を除いた 必須対応事項 / 任意対応事項 / 非対応事項)のどこにも対応せず、第一原則「Essence に根拠を持たない要求を作らない」(§2.2-1)と衝突するからである。しかも could は単なるメモに留まらない — フェーズ承認(本節)によって**自律実行の予算**を得るため、could 段があると、人間が「should フェーズへ進む」を承認した瞬間、Agent が Essence 外で発明した could 作業にまで予算が与えられ、「terrain を書き換えない」純度死守の思想に裏口が空く。ゆえに人間テンプレと投影の優先度体系を 1:1 に揃える。人間が could 相当の任意作業を望むなら、それは `ESSENCE.md` の 任意対応事項 に書く(人間所有の場所に書かれた瞬間、それは根拠を持つ should である)。

**完了述語を scope 付きで定義する(`atlas-builder state should-complete`)。**

```text
must_phase_complete :=
  todo.json に items が存在する
  AND must-priority Todo が 1 つ以上存在する
  AND すべての must-priority Todo が done である
  AND ESSENCE.md の projection 乖離がない
  AND gate 保持面の読取診断が空である(壊れた state は完了を証明しない — I-021)
  AND ドメインの completion hook が同意している(§31.1 R-13。参照ドメインは常に同意)

todo_resolved(T) :=
  T.status == "done"
  OR (T.status == "canceled"
      AND T.canceled_by ∈ {"human", "essence_projection"}
      AND T.canceled_reason が非空)

extended_complete :=
  must_phase_complete
  AND context.json.phase == "extended_approved"
  AND すべての非 must Todo が todo_resolved(priority を欠く破損 Todo も未解決に数える — 壊れた state は完了を証明しない、I-021)

must_scope_complete :=
  must_phase_complete
  AND context.json.phase == "closed_at_must"

resume_note_pending :=
  context.json.handoff.pending_cycle が truthy
  (gate release resume が立てる未消費マーカー(§13.3-5)。--close-at-must の
   resume は closure 自体なので false で書く。note を消費した cycle の終端
   — record-progress --run-status ok — だけが下ろす)

full_complete := (extended_complete OR must_scope_complete)
                 AND NOT resume_note_pending
```

- **`must_phase_complete` かつ `phase == "must"`** のとき、これは終端ではなく**フェーズ境界の停止ゲート**である。`should-complete` は `COMPLETE` を返さず、`should-stop` が `must_complete_awaiting_phase_approval` を報告する。ループの報告様式は `STOP` である。
- **`extended_complete`** は must でない全 Todo が `done` または由来と理由を伴う正当な `canceled` になったときだけ成立する(priority を欠く/集合外の破損 Todo も未解決に数える)。`blocked`、`executor.mode == "human"`、pending/in_progress は、runnable でなくても未解決である。「実行できない」と「完了した」を同一視しない。
- **`must_scope_complete`** は人間が `--close-at-must` を選んだ場合だけ成立する。Should 残件は消去・canceled 化せず、そのまま可視な scope 外残件として残る。
- **resume note 未消費ガード(`resume_note_pending`)。** gate release の resume は「再評価の許可」であり、その note はしばしば**次 cycle への指示**(選ばれたフォークの再投影など)を運ぶ。ところが「全 Todo done + phase 決定済み」の状態で gate だけが解除されると、note を消費する cycle が 1 度も走らないまま pre-gate(I-019)の completion が `COMPLETE` で終了し、人間の指示が黙って捨てられる。そこで gate release resume は差し替える handoff に `pending_cycle: true` を書き、それが立っている間 `full_complete` を封じる — ループは pre-gate を素通りせず必ず 1 cycle を走らせ、agent が note を読んで再投影(または「本当に完了」の確認)を行う。マーカーを下ろすのは note を消費した cycle の終端(`record-progress --run-status ok`)だけであり、infra 失敗や不明終了の cycle では未消費のまま保持される。例外は `--close-at-must` — その resume 自身が closure の宣言なので `pending_cycle: false` で書き、即時の must-scope COMPLETE を妨げない。truthy 判定は fail-closed 側(bool true 以外の残骸も完了を証明しない — I-021 と同じ向き)。
- **`full_complete`** のときだけ、ループは真の終端として `COMPLETE`(exit 0)で終わる。payload の `completion_scope` は `extended` / `must` / `none` のいずれかであり、どの定義で閉じたかを隠さない(`resume_note_pending` による封止中は `none` と `resume_pending_cycle: true` を報告する)。

**フェーズフラグは `context.json` が持つ**(§14.1)。既定は未決定(`phase` 未設定 / `"must"`)。Must 境界を解除する human-only resume だけが、`--approve-should` なら `phase = "extended_approved"`、`--close-at-must` なら `phase = "closed_at_must"` を立てる。前者では should Todo が runnable になり、後者では自律作業を再開せず Must scope の COMPLETE になる。どちらも要求変更ではなく完了 scope の介入記録なので、「人間が書き込む要求ファイルは1つ」の約束と両立する(§0)。

**実行可能な Todo** は次で定義する(§13.1-9、`raise-loop-gates` と共通)。runnable 集合はフェーズに依存する: must フェーズでは must 優先度のみ、`extended_approved` では should も含む。

```text
runnable(T) := T.status ∈ {pending, in_progress}
            AND T.executor.mode == "atlas-builder"
            AND (context.json.phase == "extended_approved" OR T.priority == "must")
```

`must_phase_complete` と「runnable な must Todo の存在」がどの phase でも両立しないこと(完了述語と実行可否述語の両立不能性)は機械証明済み(§31.3 S-T2)。`closed_at_must` では should は runnable にならない。

この定義は次の双対性を与える: **実行可能な Todo が尽きたとき、ループの終端は必ず「フェーズ・ゲート」か「scope 付き complete」か「人間ゲート」のいずれかである。** must がすべて done なら、未決定では `must_complete_awaiting_phase_approval`、Should 承認後に未解決 should が無ければ extended complete、Must close 済みなら must-scope complete になる。Should 承認後でも blocked / human / 不正 canceled が残れば complete ではなく `no_runnable_todos` gate が実体化される(§13.4)。「静かに空転して idle 停止に至る」ことや、「runnable が無いから complete」という終端は存在しない。

系として:

- **must を持たない projection は完了できない。** その状態で作業が尽きると `no_runnable_todos` gate が「優先度付けが必要」という診断付きで raise される。validate も items があるのに must がない場合に warning を出す。projection は原則として少なくとも 1 つの must Todo を持つべきである。
- **must 境界は必ず一度人間の手番になる。** should の Todo が残っていても — あるいは残っていなくても — must がすべて done になった時点で `phase == "must"` なら停止する。自律ループの初期予算は must にのみ与えられている。
- **Should へ続行する場合**、人間は `just resume --approve-should --note "..."` を使う。resume が `phase = "extended_approved"` を立て、次 cycle から should が runnable になる。
- **Must で閉じる場合**、人間は `just resume --close-at-must --note "..."` を使う。これは放置ではなく、Must scope を最終成果として採用した監査可能な terminal decision である。Should Todo 自体は削除・改ざんしない。
- **要求そのものを昇格・追加して続行する場合**、人間は `ESSENCE.md` を更新し、`just resume --steer-only --note "..."`(steering)で checkpoint した後に `just loop` を実行する。projection 乖離が `must_phase_complete` を false に戻し、次の cycle が再投影から再開する。この手順は**必ず** Must 境界の phase gate Recommendation が open な状態から入るため、記録専用の形(§13.3-4''')でなければ「open gate があるのに解除対象が無い」として拒否される — 人間は phase 判断を下していないのだから、それが正しい。gate は次 cycle の再投影後に条件が消えていれば `--resolve` で閉じ、条件が残っていれば新しい id で再実体化される(§21.5-3)。
- **`full_complete` から続行したい場合**も同様に `ESSENCE.md` を更新して同じ手順を踏む。`full_complete` 状態での `just loop` は pre-gate で completion を報告して終了するだけであり、副作用はない(I-019)。

---

## 20. Validation Requirements

境界の検証は 3 つの層に分かれる。**(V)** = `atlas-builder state validate` がディスク上の state から事後検証する項目。**(R)** = スクリプト/hook が実行時(runtime)に強制する項目 — 事後の state からは検証できないか、事前阻止が本質であるもの。**(A)** = エージェント規律 + 人間レビューに委ねる項目(permissions/hooks が主経路を塞ぎ、残余は LLM の遵守と `just status` / canonical state での可視化に依存する)。

### 20.1 Structural Validation

1. Required files exist. (V)
2. JSON files parse. (V)
3. JSON schema versions match. (V)
4. `ESSENCE.md` exists. (V)
5. Todo executor は `atlas-builder` / `human` / `blocked` のいずれかである(§9.1)。(V)
6. `ESSENCE.md` が placeholder(空・ガイドブロック・FILL マーカー残存、§13.1-8 と同一判定)のままなら error。空の Essence からの投影を停止ゲート(§13.1-8)より前に validate でも赤にする(§2.1.1 の番人の validate 面)。(V)
7. `canceled` Todo は `canceled_by ∈ {human, essence_projection}` と非空 `canceled_reason` を持つ。不正・無説明な取消を resolved として完了計算へ入れない。(V)
8. High-Risk Todo は non-empty `target` を持つ。target が無ければ supervised scope を機械照合できないため error とする。(V)
9. `ESSENCE.md` の見出し構造が正準集合(§2.1.1)と一致しない(H1 形式・H2 の欠落/重複/順序違反/集合外)なら error とする。placeholder(§20.1-6)の間は保留する。この error は §20.1-6 の placeholder error の直後に並び、停止条件 `essence_structure`(§13.1-15)と同一の判定を validate 面でも赤にする。(V)
10. `ESSENCE.md` ⇄ `essences/` の双方向整合(§2.1.5)。構造違反(非ディレクトリ・深さ上限超過・不正パス)と、`ESSENCE.md` が実体を持つ間の言及違反(orphan・dangling)を error とする。この error は §20.1-9 の見出し構造 error の直後に並び、停止条件 `essence_asset_integrity`(§13.1-14)と同一の判定を validate 面でも赤にする。essences/ の読取不能は fail-closed のハードエラー(§13.1-14、I-021)。(V)
11. 各 Spec item は `priority ∈ {must, should}` を必須で持つ(§8.2)。欠落・集合外の値は error。(V)
12. 各 Todo の `priority` は、参照する Spec の最強 priority と一致する(must Spec を 1 つでも参照する Todo は must)。不一致は error — must 判定の単一定義点(Spec.priority)から Todo が乖離すると、フェーズ境界(§19.3)と台帳結線の意味が壊れるためである。(V)

### 20.2 Authority Validation

1. No Todo references missing Spec. (V。validate 成功が ID 一意と dangling Todo→Spec 参照なしを保証することは機械証明済み(§31.3 S-T5))
2. No done Todo lacks evidence. (V)
3. No active Todo references blocked Spec. (V)
4. No Agent changed `ESSENCE.md`. (R: Over-Project Agent の deny hook/permissions + `should-stop` の `essence_unreviewed_change` 検出(§13.1-10)。validate も projection hash 乖離を warning で示す)
5. No cycle change appears to violate a mechanizable `won't`. (V+A: §2.1.2 の軽い won't 違反フラグ。例「won't が『依存を増やさない』なのに `package.json` が変わった」→ warning。柵の薄い機械化であり、確定的な deny は §2.1.2-2 の High-risk Recommendation 経由で人間が張る)
6. Every ESSENCE `## 成功条件`(厳密一致。旧別名「成功の定義」/「success condition」等は抽出されない — §2.1.1)maps to acceptance-check evidence. (V+A: `成功条件` の各項目に対応する evidence(acceptance check 由来の command evidence、§2.1.1 / §22)が見つからない場合に warning。この warning は**must フェーズ完了時**(この補助線がレビューされる §13.1-13 のゲート地点。判定は共通の must 完了条件で行い、ドメインの completion hook は関与しない)に限って出す — must 未完の早期 cycle では acceptance evidence がまだ揃わないのが正常であり、そこで warning を出すのはノイズだからである。対応の探索はヒューリスティックであり確定的な機械照合ではない — §22 の可視化とセットで、must 完了ゲート(§13.1-13)の人間レビューを支援する補助線である)
7. Every Spec has current Essence provenance. (V: 各 Spec の `essence_refs` は非空 string list で、各参照は `ESSENCE.md` の active な人間内容行(comment/fence/heading/directive を除外し、list marker と空白を正規化)のいずれかと完全一致しなければならない。欠落・形状違反は常に error。stale / fabricated ref は、投影 hash が現 Essence と一致している限り error — 投影 hash 乖離中(人間の Essence 編集後・再投影前)は per-Spec error ではなく §20.2-4 の drift warning に不一致 Spec 一覧として集約する。乖離中の per-Spec error は情報を増やさない冗長ノイズであり、正当な人間の Essence 編集を resume が記録するたびに「エラーの壁」を出すことになる。乖離中も stale 投影を**書く**ことはできない(§20.2-8 の stamp 一致要求が安全前提)。これは由来の実在を保証するが、原文の解釈の正しさは A 層に残る)
8. Projection writes are prevalidated. (R+V: Agent が更新する 4 正本は `state apply-projection --file` だけを通し、未指定の現行正本を含む prospective snapshot 全体を validate してから書く。bundle の空・未知 key・重複 key・非 object value は拒否する。spec.json を含む bundle は `projected_from_essence_sha256` が現 `ESSENCE.md` の SHA-256 と一致しなければ拒否する — stale 投影は書けず、投影 hash 乖離は「人間の Essence 編集後・再投影前」にしか存在しない(§20.2-7 の drift 集約の安全前提)。validation error 時は副作用ゼロ。成功時は各ファイル atomic replace だが multi-file transaction ではない — §8.2)

### 20.3 CWD Boundary Validation

これらは事後の state 検証(V)ではなく、実行時強制(R)を主にし、機械的に観測できない残余は規律と
evidence review(A)で閉じる。

1. Atlas Builder scripts/session run only from `CONTROL_ROOT`. (R: `assert_control_root` + `atlas-builder hook session-start`(誤 CWD セッションの検出・警告)。起動時 CWD の記録は loop 所有の `atlas-builder state start-run` が `runs.jsonl` に行い、事後監査の材料にする)
2. No Claude run from workspace root. (R+A: workspace root には `.claude` 設定を置かないため機械的検出は不能(§12.2)。運用規則 + workspace README + doctor の案内で防ぐ)
3. Embedded-agent runtime is never launched directly in live PROJECT_ROOT. A project-defined isolated runner must deny live Atlas Builder state/control/secrets and live Git writes; otherwise the cycle stops for human input (§10, I-003). (R+A: 直接表現された raw launch は permissions deny + quoting/shell-wrapper を解釈する hook deny。任意 script 内の transitive exec は command text から証明不能なので、その script を runner と認める条件は §10.2 の実装レビュー + isolation evidence。証明不能なら Human-input Recommendation)

### 20.4 High-Risk Validation

1. High-risk file changes have high-risk Todo. (A: hook が全 write を `high_risk_changes.jsonl` に強制記録し(R)、Todo との突合はエージェント規律と人間レビューに委ねる)
2. High-risk Todo is not mixed with normal Todo. (V: active_batch の混在検査。機械証明済み(§31.3 S-T5)— §9.3 のバッチ排他律)
3. `high_risk_changes.jsonl` contains before/after hash. (V: 形式検査。R: pre hook が before-hash を staging(`.agent/tmp/high_risk_pre.jsonl`)に捕捉し、post hook が after-hash と併せて 1 レコードとして台帳へ記録する — 拒否された ask が台帳を汚さないための構成。Bash 経由の High-Risk 書込みも同じペアで記録される(対象パスの抽出はテキストベースの保守的ヒューリスティック)。post が after-hash を記録する書き込みを pre が無意見で素通りさせないこと — post の high-risk 分類は pre の部分集合(D-002)— は機械証明済み(§31.3 G-T5))
4. Agent runtime changes include explicit evidence. (A: §12.1 の記録要件)
5. **拒否も監査に残る。** `tool_audit.jsonl` は post-tool フックだけが書いていたが、PreToolUse の `deny` はツール実行そのものを止めるので PostToolUse は発火せず、**拒否されたコールは監査ログに 1 行も残らなかった**。ガードの誤判定率も、エージェントがどこで壁に当たっているかも、ログから観測できない状態である。実走行 2026-08-12 で「`.atlas-builder/state` は grep/tail でも hook 拒否される」という**誤った一般化**が handoff で伝承されたとき(素の grep/tail は実際には通っており通過記録もあった)、それを裏づけるにも反証するにも使えるデータがログ側に無かった。さらに、拒否された high-risk Bash は before-hash だけが staging に残り、対応する after-hash も監査行も無い孤児レコードになり得た。したがって **pre-tool 側も判定(allow / ask / deny + 理由)つきの監査行を書く**(`phase: "pre_tool"` — このキーを持たない行は従来どおり post-tool 行)。書くのは**意見のある判定だけ**である: 無意見の passthrough は post-tool 行が既に覆っており、二重に書けば deny のシグナルが量に埋もれる。read-only セッション(I-022/I-027)は post_tool_audit と同じく無条件に無作用である — 許可済み検分を書くこと自体が read-only 保証の違反になる。

### 20.5 Inspection Idempotency

`atlas-builder state validate` は診断結果を `validation.json` に投影する検査であり、**同じ入力・同じ診断を再検査しただけで** worktree を汚してはならない。一方、入力状態が変わって status/errors/warnings が実際に変化したなら、その新しい診断を正本へ書くのが検査の役割である。全 read/derive/write 区間は I-018 の slot を取得または cycle 祖先から継承し、別の変異と競合する場合は stale な診断を投影せず hard error にする。`just doctor` / `just state validate` の反復だけで次の cycle が I-014(clean worktree)に拒否されることを防ぎ、真の診断変化は隠さない(`atlas-builder state status` はそもそもファイルを書かない読み取り専用表示である)。

1. 検証結果(status / errors / warnings)が直前の `validation.json` と意味的に同一なら、ファイルを書き換えない。`last_validated_at` は「結果が最後に変わった時刻」であって「コマンドが最後に走った時刻」ではない(意味的進捗の判定(§13.1)も同フィールドを volatile として除外する)。
2. したがって、検査後に worktree が dirty になった場合、それは検査が発見した真の状態変化であり、通常どおり cycle commit または `just resume` が引き取る。
3. **鮮度は別ファイルが持つ。** 規則 1 の帰結として `last_validated_at` は「診断が最後に**変わった**時刻」であり、「コマンドが最後に走った時刻」ではない。ところが `just status` はその温存された時刻を素の `Validation` 行に出しており、人間にもエージェントにも「検証が古い」と読めた — 実走行 2026-08-12 では、エージェントが「apply-projection の bundle 受理こそが検証パスの証拠だ」という経験則を handoff で伝承するところまで行った(結論は誤りではないが、表示の欠陥が知識を歪めた形である)。正しい表示には「最後に走った時刻」が要る。それを `validation.json` に書けば規則 1 が壊れるので、**gitignore 済みの `PROJECT_STATE_ROOT/tmp/validation_check.json`** に置く: git 追跡外なので毎回書いても worktree は clean のまま(I-014 は無傷)であり、`just status` はそこから `checked <t>` を読む。表示は 2 つの時刻をそれぞれの意味を明示した形で出す — `Validation : ok (checked <実行時刻>; diagnostics unchanged since <変化時刻>)`。

---

## 21. Recommendation and Blocker Model

### 21.1 Recommendation Types

```json
{
  "type": "Human-input Recommendation"
}
```

| Type | 意味 | ループへの影響 |
| ---- | ---- | -------- |
| Blocking Recommendation | Essence 由来の重大問題(§21.2) | proposed の間、停止 |
| Non-blocking Recommendation | 記録・提案(projection 歪みなど) | なし |
| High-risk Recommendation | Agent Runtime High-Risk Zone の設計判断(§21.3) | なし(記録必須) |
| Human-input Recommendation | 人間の承認・入力・判断なしに安全に進めない(§21.4、§21.5) | proposed の間、停止 |

この「ループへの影響」列は各 type の**既定**である。明示フィールド(`requires_human_approval` / `human_input_required` / `agent_action: "stop_until_human_review"`)は type を問わず優先されるため(§21.4-1)、それらを持つ High-risk / Non-blocking Recommendation は「なし」の既定を上書きして停止しうる。逆に、これらの明示フィールドを持たない High-risk / Non-blocking は、文面に承認依頼らしき語が含まれても停止しない(§21.4-3)。

### 21.2 Blocking Recommendation

Essence 由来の重大問題だけが Blocking Recommendation になる。

```json
{
  "id": "R-001",
  "type": "Blocking Recommendation",
  "status": "proposed",
  "target": "ESSENCE.md",
  "reason": "Essence contains two mutually exclusive must-level requirements.",
  "risk": "Proceeding would require the agent to choose human priorities.",
  "source": ["ESSENCE.md"],
  "proposed_diff": "",
  "agent_action": "stop_until_human_review"
}
```

### 21.3 High-risk Recommendation

Agent Runtime High-Risk Zone に関する設計判断は、必要に応じて High-risk Recommendation として残す。次の例は、対象がエージェントを内包する場合の対象側 `.claude/settings.json`(対象プロダクトの内容物、§6.2)を題材にする — Over-Project Agent はこれを実装として開発するが、その変更は agent runtime を触るため High-Risk 追跡の対象になる(§12)。

```json
{
  "id": "R-010",
  "type": "High-risk Recommendation",
  "status": "proposed",
  "target": ".claude/settings.json",
  "reason": "Changing In-Project Agent permissions may alter future agent behavior.",
  "risk": "Permission expansion can allow unintended file edits.",
  "source": ["T-014", ".claude/settings.json"],
  "proposed_diff": "",
  "requires_human_approval": true,
  "agent_action": "stop_until_human_review"
}
```

`won't` の機械化 Recommendation は、**対象プロジェクト内に実装する検査/CI/runtime policy**が High-Risk path を触る場合にこの型を使う(§2.1.2-2)。人間が提案を承認したら `just supervise --todo T-... --recommendation R-...` でその対象側変更 1 件だけを適用し、diff をレビューして `just resume --resolve R-... --note "..."` で checkpoint する。CONTROL_ROOT の permissions/hooks を bound session から変更する Recommendation は作らない(§11.3)。一般化すべき enforcement gap は maintainer task として外へ出し、現プロジェクトでは常設制約 + warning + フェーズ境界レビューを残す。単なる将来メモとして action を伴わない High-risk Recommendation だけは既定どおり非停止でよい。

### 21.4 Human-input Recommendation

承認、依存インストール許可、ゲート通過、または人間レビューなしに次の安全な作業を選べない Recommendation は proposed の間 `should-stop` の対象になる。新規に作る場合は `type: "Human-input Recommendation"` を使い、曖昧な自然言語だけに頼らず、次のいずれかを明示する。

```json
{
  "type": "Human-input Recommendation",
  "status": "proposed",
  "requires_human_approval": true,
  "agent_action": "stop_until_human_review"
}
```

判定規則は §21.1 の表に従い、次の優先順で評価される。

1. **明示フィールド**(`requires_human_approval` / `human_input_required` / `agent_action`)は type を問わず尊重される。`agent_action` の停止値は `stop_until_human_review` を正とし、その明白な同義値(`human_input_required` / `requires_human_approval` / `wait_for_human` / `ask_human`)も停止側=安全側に倒して受理する(自由文の推測ではなく、構造化フィールドの値マッチである — 規則 3 と矛盾しない)。
2. `type: "Human-input Recommendation"` は、明示フィールドが無くても proposed の間は停止対象である。
3. それ以外(`Non-blocking Recommendation` / `High-risk Recommendation`、および type が無い/未知の記録)は**文面だけでは停止しない**(表のとおり「ループへの影響: なし」。「許可リストの拡張を提案」のような語を含む記録的 Recommendation が誤って停止ゲート化し、resume がそれを人間解決として閉じてしまう誤遷移を防ぐ。停止させたい Recommendation は 1 の明示フィールドか 2 の type で宣言する — 文面推測は行わない)。

### 21.5 Framework-raised Gate Recommendations

§13.4 のとおり、loop 検出の停止条件(`no_runnable_todos` / `idle_cycles` / `usage_limited` / `infra_unreachable` / `must_complete_awaiting_phase_approval`)は `atlas-builder state raise-loop-gates` が Human-input Recommendation として実体化する。これはエージェントの提案ではなく **framework の状態遷移**であり、次の形を持つ。

```json
{
  "id": "R-LG-20260707T120000+0900-a1b2",
  "type": "Human-input Recommendation",
  "status": "proposed",
  "raised_by": "atlas-builder-loop",
  "gate": "no_runnable_todos",
  "target": "todo.json",
  "reason": "No runnable Todo remains ... A human decision is required.",
  "details": { "todos": [ { "id": "T-003", "status": "blocked", "executor": "atlas-builder", "blocked_reason": "..." } ] },
  "requires_human_approval": true,
  "agent_action": "stop_until_human_review",
  "created_at": "..."
}
```

規則:

1. `raised_by: "atlas-builder-loop"` と `gate` を必ず持つ。エージェントはこのフィールドを偽装して自分の Recommendation に付けてはならない — そして偽装は構造でも中和されている: 冪等性判定(§13.4-7)が数えるのは human-gating な rec だけなので、非停止 rec に両フィールドを詐称しても本物の gate の実体化は抑止できない(偽装自身がループを止める形でしか抑止力を持てない)。
2. gate 種別ごとに同時に 1 つしか proposed にならない(冪等)。
3. 通常 gate は、人間が `resume --resolve <id>` で**正確に指定した**ものだけが `resolved` になる。未指定の gate は proposed / active のまま残り、存在しない ID・重複 ID・Blocker/Recommendation 以外の ID は書込み前に拒否する。条件が残っていれば次 cycle 終端で新しい id として再実体化される。`must_complete_awaiting_phase_approval` は通常の `--resolve` では解除できず、framework が観測した active な Must 境界に対する `--approve-should` または `--close-at-must` の明示判断だけが、その gate Recommendation を resolve して `context.json.phase` をそれぞれ `extended_approved` / `closed_at_must` に遷移させる(§13.3-4')。フェーズ判断後は条件が消え再実体化されない。
4. `no_runnable_todos` / `idle_cycles` / `usage_limited` / `infra_unreachable` について、エージェントは loop-raised gate を「前の cycle が不透明に終わった」という信号として扱い、可能なら自分のより具体的な診断(§21.4)で置き換える(gate を resolve するのは人間だが、追加の Recommendation を並べることはできる)。`must_complete_awaiting_phase_approval` は例外で、不透明な終端ではなく設計どおりの正常なフェーズ境界である(§19.3) — エージェントが置き換えるべき診断ではなく、人間のフェーズ判断を待つだけの停止である。

### 21.6 Blocker Model

`blockers.json` の Blocker は次の型を持つ。

| Type | 意味 | ループへの影響 | 解決者 |
| ---- | ---- | -------- | --- |
| `essence_blocking` | Essence 由来の重大問題(§21.2 と対で記録) | active の間、停止 | 人間(resume) |
| `technical` | 技術的行き詰まり(依存の壊れ、環境問題など) | なし(診断記録) | エージェント |
| `dependency` | 外部依存・許可待ち(人間ゲートが必要なら §21.4 を併用) | なし(診断記録) | エージェント/人間 |
| `external` | 外部サービス・第三者要因 | なし(診断記録) | エージェント/人間 |

規則:

1. ループを止めるのは `essence_blocking` だけである。人間の入力が必要な非 Essence 条件は Blocker ではなく Human-input Recommendation(§21.4)で止める。
2. `status: "blocked"` の Todo は必ず `blocked_reason`(および説明する Blocker があればその id)を持つ。validate が warning で強制し、`no_runnable_todos` gate の診断(§13.4)がこれを人間に提示する。
3. resume が Blocker として resolve できるのは `--resolve` で明示された active な `essence_blocking` だけである。同時に open な別 Blocker は一括解除しない。その他の型はエージェントが次の cycle で再評価し、解消していれば自分で `resolved` にする。

---

## 22. Evidence Model

Todo は evidence なしに `done` にできない。

Evidence の例。

```json
{
  "evidence": [
    {
      "type": "command",
      "command": "npm test",
      "exit_code": 0,
      "summary": "All tests passed."
    },
    {
      "type": "diff",
      "files": ["src/example.ts", "tests/example.test.ts"],
      "summary": "Implemented feature and tests."
    },
    {
      "type": "command",
      "command": "./scripts/run-agent-e2e-isolated --scenario smoke",
      "exit_code": 0,
      "summary": "The project-defined isolated runner passed the agent smoke scenario without live state/secret mounts."
    }
  ]
}
```

対象がエージェントを内包し、§10 の隔離要件を満たす project-defined runner がある場合、その command は
`npm test` 等と同じ通常の evidence として扱う。runner の隔離条件(ライブ state/secret mount 無し、ライブ
write path 無し)も summary または別 check で証明する。raw nested `claude` は evidence として受理しない。

High-risk evidence には before/after hash を含める(下例は対象 `.claude/settings.json` を扱うため、
対象がエージェントを内包する場合の例。内包しない場合は `.github/workflows/**` など、存在する High-Risk
パスが対象になる)。

```json
{
  "type": "high_risk_change",
  "path": ".claude/settings.json",
  "before_sha256": "...",
  "after_sha256": "...",
  "reviewed_by": "human via just supervise",
  "risk_reason": "Changes In-Project Agent tool permissions."
}
```

**evidence が保証するもの、しないもの(設計上の限界の明示)。** Atlas Builder が機械的に保証するのは「証拠に裏打ちされた完了」であって、「意図の正しい解釈」ではない。`validate` が検査するのは evidence の**存在と exit_code**(§20.2)であり、その evidence が `ESSENCE.md` の `成功条件` を正しく検証しているかは完全には機械照合できない — Agent が成功条件を自信満々に誤読すれば、誤読した対象に沿った緑のテストで全ゲートを正常通過しうる。この歪みは隠さず(Expose the distortion、§1.2)、次の 2 点で人間レビューに接続する。

1. **入口(投影)**: `成功条件` は acceptance check として書かれ(§2.1.1)、各 Spec は current Essence の active 内容行への `essence_refs` を必ず持つ。参照先の実在は validate error として機械検査する(§20.2-7)。ただし「その原文を Spec が正しく解釈したか」と「どの evidence がその成功条件を十分に検証するか」は意味論なので完全には機械照合できない。must Todo の evidence には acceptance check を直接検証した command evidence を含めることを投影規律とする。
2. **出口(可視化)**: `atlas-builder state validate` は、`成功条件` の各項目に対応する acceptance check 由来の evidence が見つからない場合に warning を出し(§20.2-6)、`just status` は「成功条件 ↔ evidence」の対応を表示する(§15.1)。完全な機械照合が目的ではない — 誤読を人間が捕まえる最初の強制点である must 完了ゲート(§13.1-13)のレビューを支援する補助線である。

**将来メモ — 振る舞いの evidence。** 対象プロダクトの成果物がエージェントそのものである場合(§6、§12.3)、In-Project Agent が「エージェントらしく正しく振る舞えているか」は pass/fail の command evidence では捉えきれない。現行 evidence モデルはこの種の検証に未対応であり、将来の検討対象として明示する。

### 22.1 No Verbatim Verification Output in Committed Evidence (I-024)

evidence(および `commands_run[].summary`)は checkpoint commit で **committed される canonical state** に入る(§24.1)。したがって秘密を要する検証(§11.4)の出力を逐語で載せると、Git 履歴に秘密が焼き付く。規律は次である。

1. command evidence に載せてよいのは `command`(実行したコマンド)、`exit_code`、そして**上限付き・redact 済みの `summary`** だけである。テストプロセスの stdout / stderr の逐語を貼らない。
2. `summary` は結果の意味(何が pass/fail したか、件数など)を短く述べるに留める(目安として数行以内)。秘密らしき文字列が現れたら伏字にする — 最低限、資格情報の定番形(`sk-` 等の API キー接頭辞、`AKIA` 等のクラウドアクセスキー、`://user:pass@` を含む接続 URL、`Bearer <token>`、長大な base64 / hex らしき文字列)は伏字対象とする。この列挙は下限であって網羅ではなく、鍵・トークン・接続情報らしきものは疑わしきは伏せる。
3. 通常 test、隔離 runner、人間が返す secret-required verification のすべてで守る。`validate` が検査するのは evidence の**存在と exit_code**で、summary の完全な秘密判定はできない。入力側は environment sanitize + permissions/hooks + OS sandbox が機械強制する。出力側では Agent 規律と checkpoint review に加え、commit 直前に**exact staged blob**を high-confidence credential signature で走査し、該当すれば filename だけを表示して commit 前に拒否する。token 本文は端末にも再出力しない。Agent が staged 内容へ抑制 marker を書いて免除する in-band exception は持たない。

この staged scan は既知形式の backstop であって DLP ではない。未知形式、分割・暗号化・難読化された秘密、短い password、一般文字列と区別できない credential は検出できず、entropy だけを根拠に広範囲を止めることもしない。したがって I-024 の主防御は引き続き「秘密を Agent 入力へ渡さない」ことであり、scan の存在を完全検出と表現してはならない。

この規律は §11.4 の「Agent に秘密を渡さない」入力境界と対になって I-024 を成立させる。

---

## 23. Safety Invariants

Atlas Builder v1.0 の安全性は、次の invariants に依存する。

```text
I-001: Claude Code is never launched from the workspace root.
I-002: Over-Project Agent CWD is always CONTROL_ROOT.
I-003: Atlas Builder never launches an embedded target agent directly in the live PROJECT_ROOT; behavioral verification uses only a project-defined isolated runner with no live Atlas Builder-state or secret access.
I-004: PROJECT_ROOT/ESSENCE.md and PROJECT_ROOT/essences/** are human-only.
I-007: Over-Project Agent may edit PROJECT_ROOT implementation files (the main implementation path).
I-008: Agent Runtime High-Risk Zone requires explicit high-risk tracking (over whatever such paths exist — e.g. .github/workflows/**, and .claude/** when the target embeds an agent).
I-010: Todo cannot be done without evidence.
I-011: Human/Essence stop conditions and idle-cycle safety stops must halt the loop before more autonomous work.
I-013: Each completed Atlas Builder cycle is represented by at most one Git commit.
I-014: Atlas Builder cycles start only from a clean Git worktree.
I-015: Agents may inspect Git status/diff, but may not stage or commit directly.
I-016: Cycle commit failure is a hard stop; loop diffs must not mix across cycles.
I-017: Every stop is visible: it exists in canonical state (Recommendation/Blocker or a directly evaluated canonical file/phase fact), in the `just status` output, and in the loop's exit message, together with the resume instruction.
I-018: At most one canonical-write window (loop/once/resume/supervise/init/bootstrap or any mutating state command) runs per control plane at a time (single-flight lock; nested transitions and in-cycle state writes inherit the ancestor's slot). A holder is stale only when process absence is positively established; permission/sandbox/probe uncertainty never authorizes lock reclamation.
I-019: A gated loop invocation is side-effect-free: no run record, no counter change, no commit.
I-020: An agent cycle commit never contains changes to PROJECT_ROOT's human-gated control files (ESSENCE.md and its essences/** attachment assets, and — where the target embeds an agent — CLAUDE.md, .claude/**); they enter Git history only through human checkpoints. Of these, ESSENCE.md is the only human requirement-input file a human writes (essences/** holds the human-placed non-Markdown assets it references, §2.1.5; Atlas Builder develops the agent-runtime config through the supervised High-Risk workflow, §12.1); ESSENCE.md enters history exclusively through resume checkpoints after init. README.md is NOT in this set: it is an ordinary implementation file the agent owns (§11.1) and its diffs ride in the cycle commit.
I-021: Gate evaluation fails closed: unreadable or shape-corrupt gate-holding state stops the loop, a crashed predicate exits as a hard error (never as "no"), and no framework transition rebuilds an unreadable state file from defaults.
I-022: Gate triage is advisory and read-only: the triage session mutates neither project files nor canonical state (its CLI settings make the target OS-sandbox read-only; its only freely writable path is the CONTROL_ROOT/.agent/tmp/triage/ handoff, and its only other write surface is ask-gated — the live CONTROL_ROOT/.claude/settings.json deployment repair (§28.5-3), which proceeds only with the human's explicit approval on the permission prompt), and the only transition it can lead to is a resume the human explicitly confirms on the terminal.
I-024: No Atlas Builder-launched Agent receives secret environment variables or read access to Atlas Builder's defined secret input surfaces (target .env/.env.*/secrets/credentials plus the enumerated home credential stores in §11.4). Secret-bearing verification is run by the human outside the Agent session; only its exit status and a redacted summary may enter evidence/state. Before every Atlas Builder checkpoint, the exact staged blobs are scanned for a conservative set of high-confidence credential signatures; a hit aborts before commit and reports filenames only. This is a backstop, not a claim of complete secret detection.
I-027: The Essence interview is advisory and read-only: the interview session mutates neither project files nor canonical state (its only freely writable path is the CONTROL_ROOT/.agent/tmp/essence/ handoff; its only ask-gated write surfaces are the live settings repair (§28.5-3) and — new mode only — the direct ESSENCE.md install fallback and the essences/ asset install (one file at most 3 segments deep, §2.1.5)), and ESSENCE.md is installed only through a human-confirmed act: primarily by the human-only wrapper after the human reviews the full draft on the terminal and explicitly confirms; in new mode, as a fallback second path, by a session Write the human explicitly approves on the permission prompt after reviewing the same full draft on screen — I-004 preserved: the installed content originates from the human's answers and confirmation, never from unreviewed agent text.
I-028: Distribution-unit/maintainer-plane purity: CONTROL_ROOT holds only what a bound control plane needs to OPERATE. Files and just recipes whose subject is Atlas Builder's own source (test / proofs / purity-gate and their dev tooling) live in the framework repository's root, outside the distributed directory; bound Agent sessions never mutate the distributed control surface. The test is §18.4's: "does this command mean anything in a distributed, bound control plane?"
I-029: Every Atlas Builder-launched Claude session receives only an allowlisted non-secret environment, selects only `project` among the user/project/local setting sources plus a launcher-supplied `--settings` overlay (the machine-dependent path rules and the whole sandbox, regenerated at every launch from the base-recorded profile, §16.1), and requests no MCP server (`--strict-mcp-config` with no `--mcp-config`); unavoidable managed policy remains the deployment trust base. Under the standard and auto-approve profiles (§11.5), autonomous Bash requires the OS sandbox, fails if it is unavailable, and has no unsandboxed escape; only a human-authored `profile: unsandboxed` line in ESSENCE.md, applied by a human-only init, removes the OS sandbox — narrowing that deployment's boundary to the deny floor plus governance detection (I-030, §11.5). Autonomous settings carry an enumerated, global-wildcard-free network domain allowlist; strict unknown-domain denial beyond headless prompt behavior requires managed policy and is not claimed.
I-030: The guard's deny floor is profile-invariant: ESSENCE.md/essences (I-004), secret surfaces (I-024), the enumerated control-plane surfaces (§11.3, I-028), git stage/commit (I-015), dangerous Bash, and nested claude launches (I-003) are denied with identical reasons under every profile; a relaxed profile (§11.5) only converts the enumerated ask faces and the final no-opinion Bash leaf into audited allows, never weakens a deny, never changes high-risk staging (§20.4-3), and never applies to read-only sessions (I-022/I-027). Machine-checked (§31.3 G-T6).
```

(番号 I-005 / I-006 / I-009 / I-012 / I-025 は欠番である。I-005 / I-006 は「対象 runtime が Atlas Builder を
知らないから control/state を触れない」というアクセス制御ではない主張だったため撤回し、I-003 の
no-live-launch に置き換えた。I-009 / I-012 / I-025 は生成 view・旧委譲概念の撤去による。番号は振り直さない。)

I-003 と I-020 の `CLAUDE.md` / `.claude/**` 部分は、対象がエージェントを内包するときだけ適用対象を持つ。
残りは対象種別によらない。I-029 は sandbox path deny の文字列 heuristic ではなく、(standard / auto-approve での)sandbox 必須化・unsandboxed
escape 禁止・launcher environment sanitize・settings source/MCP の CLI 固定・network allowlist の配備検査という実装可能な境界を述べる。未知 domain の絶対的 deny まで含めない理由は §28.5-7 の vendor/managed-policy 境界である。sandbox 必須が外れる唯一の経路は人間の `profile: unsandboxed` 宣言 + human-only init であり(§11.5)、そのときの縮退した信頼モデルは I-030 が下限を固定する。

**将来不変条件(実装時に有効化)。** 次は現行 v1.0 では**未実装**の機能に対する予約であり、その機能を実装したときに有効化する。

```text
I-023 (reserved): Push stop-notification is best-effort and non-authoritative — its failure never
       changes the loop's control flow, exit code, or gate state; it carries no secret; it fires
       only on transition into a gate (not on side-effect-free re-invocation). (§13.4 future note)
I-026 (reserved): The autonomous loop has a cost budget (token/spend ceiling), and reaching it is
       an authoritative gate: a designed terminus reported as a normal stop (exit 0), equal in
       rank to --max-cycles. Unlike I-023 it is never best-effort — exceeding the budget must
       halt the loop even while the human is away. (§13.4 future note)
```

I-026 は現時点では意図的に未実装である。長時間離席を優先し、現行の権威ある上限は `--max-cycles` / `--max-session-cycles` だけとする。Claude Code subscription や複数モデル階層の token accounting を同じ「費用」に正規化する仕様が確定するまで、曖昧な推定値で自律ループを止めない。

`must_complete_awaiting_phase_approval`(§13.1-13、§19.3)と `won't` の triage(§2.1.2)は、既存の I-004(ESSENCE.md 人間専用)・I-011(停止/再開の人間介入)・I-017(停止の可視化)・I-008(対象 High-Risk 追跡)の枠内で成立するため、新しい不変条件を要さない。フェーズ承認は resume 遷移(I-011)へ写像される。won't は既存の決定論的 gate、対象内 test、常設制約 + warning のいずれかへ明示的に triage され、CONTROL_ROOT の自己変更には写像しない。

---

## 24. Git and Commit Policy

### 24.1 Commit Recommended

```text
PROJECT_ROOT/ESSENCE.md
PROJECT_ROOT/essences/**                # 人間所有の添付資産(§2.1.5)— human checkpoint でのみ履歴に入る(I-020)
PROJECT_ROOT/README.md
PROJECT_ROOT/CLAUDE.md                  # 対象がエージェントを内包する場合に存在(§5.0)
PROJECT_ROOT/.atlas-builder/state/*.json
PROJECT_ROOT/.atlas-builder/state/*.jsonl   # 秘匿情報が混ざらない方針なら
PROJECT_ROOT/.claude/settings.json     # 対象がエージェントを内包する場合に存在
PROJECT_ROOT/.claude/rules/**          # 対象がエージェントを内包する場合に存在
CONTROL_ROOT/CLAUDE.md
CONTROL_ROOT/.claude/**
CONTROL_ROOT/scripts/**
```

`PROJECT_ROOT/CLAUDE.md` / `PROJECT_ROOT/.claude/**` は対象がエージェントを内包する場合にだけ
対象の内容物として存在するため、内包しないプロジェクトの commit 対象には現れない(§5.0)。
CONTROL_ROOT 側の `CLAUDE.md` / `.claude/**` は対象の種類によらず常に存在する。

### 24.2 Do Not Commit by Default

```text
CONTROL_ROOT/.agent/runs/**
CONTROL_ROOT/.agent/tmp/**
PROJECT_ROOT/.atlas-builder/tmp/**
PROJECT_ROOT/.env
PROJECT_ROOT/.env.*
PROJECT_ROOT/secrets/**
```

### 24.3 Cycle Checkpoint Commits

`loop.sh` creates one Git checkpoint commit at the end of every
**executed** cycle. Invocations that are refused by a pre-cycle gate
(latched stop or completion, §13.4) create no commit at all (I-019) — a
stopped loop must not grow Git history by being retried. The cycle must
start from a clean worktree; otherwise the loop stops before mutating
state. This prevents unrelated human edits or previous cycle leftovers
from being mixed into a cycle checkpoint.

Commit scope is limited to `CONTROL_ROOT/**` and `PROJECT_ROOT/**`. Ignored
runtime logs and secrets remain excluded by `.gitignore`, and the loop also
refuses to commit forbidden paths such as `.env`, `secrets/**`,
`config/credentials.json`, `CONTROL_ROOT/.agent/runs/**`,
`CONTROL_ROOT/.agent/tmp/**`, and `PROJECT_ROOT/.atlas-builder/tmp/**`.
If non-ignored changes remain unstaged after the scoped add, the loop aborts
before committing so that partial cycle checkpoints are not created.

After scoped staging and before `git commit`, the common checkpoint guard
reads the exact staged blobs (`:<path>`) and scans a deliberately narrow set
of high-confidence credential forms (recognized API/cloud key prefixes and
private-key headers). A hit
unstages the checkpoint scope, prints only the implicated filenames, and
aborts before commit; neither the matching secret nor surrounding content is
echoed. Cycle, resume/update, and crash-recovery checkpoints all use this
common guard. There is no repository-content suppression marker an Agent can
add to self-authorize an exception. The scan does not replace `.gitignore`,
denyRead/environment isolation, or human review, and does not claim to detect
every secret (§22.1, I-024).

One deliberate exception (I-020, generalized): the **human-gated control
files of PROJECT_ROOT are never staged into a cycle commit** —

```text
PROJECT_ROOT/ESSENCE.md
PROJECT_ROOT/essences/**    # ESSENCE.md の添付資産(§2.1.5、I-020)
PROJECT_ROOT/CLAUDE.md      # 対象がエージェントを内包する場合に存在 (§5.0)
PROJECT_ROOT/.claude/**     # 対象がエージェントを内包する場合に存在 (§5.0)
```

`CLAUDE.md` と `.claude/**` はこのリストに載るが、それらが存在するのは対象がエージェントを
内包する場合だけである(§5.0)。内包しないプロジェクトで human-gated として残るのは `ESSENCE.md` と
`essences/**` である。`README.md` はこのリストに**載らない** — 通常の実装ファイル(§11.1)として cycle commit
に含まれる。

Cycles run non-interactively (`claude -p`), where every ask-gated write is
auto-denied — so during an executed cycle, a diff on these paths can only be
a human's mid-cycle edit. This does not make all of these files Atlas Builder input
canon, nor human-written surfaces: only `ESSENCE.md` is the human requirement
input file, and the only file humans write (§0, §7.2). `CLAUDE.md` and
`.claude/**` are execution-control files Atlas Builder develops under explicit
human approval; they are gated because they can change how future work is
understood or executed. Committing such a diff as `atlas-builder: cycle` would be
indistinguishable from an agent violation (I-004 / I-008) in the audit
trail, so the framework makes it structurally impossible: the diff stays in
the worktree and enters history through the human's own resume checkpoint.
For ESSENCE.md the loop additionally stops on `essence_unreviewed_change`
(§13.1-10); for the other paths the next cycle's clean-worktree refusal
(I-014) surfaces the leftover until the human records it with `just resume`.
A human's mid-cycle README.md edit gets no such treatment: it is an ordinary
uncommitted diff, so the next cycle's clean-worktree refusal (I-014) surfaces
it like any other, and the agent's own README changes simply ride in the cycle
commit.

Commit messages use the run id as the stable key:

```text
atlas-builder: cycle R-YYYYMMDDTHHMMSS±hhmm-xxxxxx

Atlas-Builder-Project: PROJECT_TITLE
Atlas-Builder-Run-Id: R-YYYYMMDDTHHMMSS±hhmm-xxxxxx
Atlas-Builder-Run-Status: ok | claude_exit_N | complete | stopped | state_unreadable |
                     essence_missing | essence_placeholder | essence_structure |
                     essence_asset_integrity | essence_unreviewed_change |
                     essence_blocking | blocking_recommendation |
                     human_input_required | idle_cycles | usage_limited |
                     infra_unreachable
Atlas-Builder-Validation: ok | warning | error | unknown
```

件名と trailer の間の本文には人間可読の要約行(Project / Cycle N/M / Run-Status / Validation)を含めてよい — 機械可読の正本は trailer ブロックである。

(`Atlas-Builder-Run-Status` の停止系の値は `should-stop` の reasons と同語彙である — 上記の `state_unreadable` 以降 `infra_unreachable` までがそれであり、`should-stop` が reasons を積む順に最初にマッチした 1 つを刻む(§13.4 の複数 gate 同時成立の規則)。停止・完了理由は `claude_exit_N` に**優先**して刻まれる — cycle 中にラッチされた停止/完了はその cycle の設計上の終端であり(§19.1-2)、claude の非ゼロ終了そのものは `runs.jsonl` の run end status に残る。したがって `claude_exit_N` が trailer に現れるのは、停止も完了もラッチされなかった非ゼロ終了 cycle だけである(`infra_unreachable` は定義上 claude 非ゼロの cycle でラッチされるため、この優先がなければ到達不能になる)。`no_runnable_todos` は Recommendation に実体化され、停止 reason は `human_input_required` になる。`must_complete_awaiting_phase_approval` は crash window でも消えない直接 phase fact として reasons に常に載り、通常 cycle では同名 Recommendation も実体化されるため、優先順位が先の `human_input_required` が単一 trailer 値になる。Recommendation 実体化前の観測(pre-gate の `should-stop` / `just status` 表示 — いずれも commit を作らない経路)でだけ同名 reason が単独で現れ得るが、trailer は `raise-loop-gates` 成功後にのみ刻まれ、その失敗は commit 前のハードエラーになるため、`must_complete_awaiting_phase_approval` が trailer 値として現れることはない(上の enum に載らないのはそのためである)。`ok` は claude が正常終了した cycle、`complete` は `full_complete`(§19.3)、`claude_exit_N` は claude の非ゼロ終了。`stopped` はループ側の写像が将来の未知 reason に出会ったときの保険フォールバックであり、上記語彙が同期している限り到達しない。)

Human transitions use their own subjects (§13.3, §13.5):

```text
atlas-builder: human resume (PROJECT_TITLE)     # gate release
atlas-builder: human update (PROJECT_TITLE)     # steering
atlas-builder: crash recovery (PROJECT_TITLE)   # resume --force closed a dangling run
```

`runs.jsonl` の run end status には、上記に加えて `interrupted`(signal trap、§13.5)と `aborted_by_resume`(crash recovery)が現れる。これらの run は checkpoint commit を持たない — 残骸は resume checkpoint が引き取る。

`git push` remains outside Atlas Builder automation. Agents may run `git status` and
`git diff` for inspection, but `git add` and `git commit` are framework-owned and
must not be invoked directly by any Agent.

---

## 25. Updated `.gitignore`

対象プロジェクト側。下の「Claude local settings」ブロックは、対象がエージェントを内包し対象 `.claude/`
を持つ場合にのみ意味を持つ(§5.0)。ただし seed の時点では対象がエージェントを内包するかは決まっていない
— それは対象の Essence が決めることであり(§5.0)、Essence は seed 後に書かれることさえある。したがって
bootstrap が seed する `.gitignore` はこのブロックを**無条件に含める**: 内包しない対象では単に不要な
だけで無害であり、条件分岐の複雑さに見合う利得がない。

```gitignore
# Secrets
.env
.env.*
secrets/
config/credentials.json

# Claude local settings  ── 対象がエージェントを内包する場合のみ(§5.0)
CLAUDE.local.md
.claude/settings.local.json

# Atlas Builder runtime
.atlas-builder/tmp/

# Common build outputs
node_modules/
dist/
build/
coverage/
.pytest_cache/
__pycache__/
*.pyc
```

Control Root 側。**束縛済み制御プレーンが runtime に生む物だけ**を対象とする — 開発ツールの成果物はここに現れない。それらの主語は Atlas Builder 自身のソースであり、フレームワークリポジトリ root の `.gitignore` が持つ(§18.4、I-028)。

```gitignore
# Local Claude Code settings
CLAUDE.local.md
.claude/settings.local.json

# Runtime logs
.agent/runs/*
!.agent/runs/.gitkeep
.agent/tmp/*
!.agent/tmp/.gitkeep
.agent/state/tool_audit.jsonl
.agent/state/control_runs.jsonl
# Loop runtime signals: graceful-drain flag (§19.1-7) and display-only
# heartbeat (§19.1-9) — never canonical, so a lingering file must not dirty
# the I-014 clean-worktree check. The heartbeat glob also covers its
# atomic-write remnant (loop.status.json.<pid>.tmp).
.agent/state/loop.drain
.agent/state/loop.status.json*

# Lean ビルド成果物(just build が lean/.lake/build から生成し bin/ へ配置する)
/bin/atlas-builder
/lean/.lake/
```

フレームワークリポジトリ root 側(Atlas Builder を**開発する**ときだけ存在する。配布物ではない)。

```gitignore
# Local Claude Code settings
CLAUDE.local.md
.claude/settings.local.json

# Lean build artifacts of maintainer-plane packages (proofs, tests)
tests/lean/.lake/
proofs/.lake/
```

---

## 26. Human Workflow

### 26.1 New Project

```text
1. Create workspace (one git repo).
2. Place the project-agnostic Atlas Builder template in ./.atlas-builder (unbound), then build its
   runtime once: cd ./.atlas-builder && just build. Every command below runs through
   bin/atlas-builder, so an unbuilt control plane refuses each of them with exit 2 (§31 R-1).
3. Create ./{project-title}.
4. Human writes the project requirements into the single Atlas Builder input file: ./{project-title}/ESSENCE.md before init.
   - bootstrap never overwrites an existing ESSENCE.md, so the initial canonical
     state records the real Essence hash instead of the placeholder hash.
   - Alternatively, use the human-only Essence interview (§2.1.4): cd ./.atlas-builder,
     grant trust first (just trust ../{project-title} — the session's boundary
     enforcement needs it), then just new-essence ../{project-title}. It interrogates
     you critical-first and installs the fully format-compliant draft only after
     you review the full text and confirm (y).
5. Bind + bootstrap in one step: cd ./.atlas-builder && just init ../{project-title}.
   - init renders the CONTROL_ROOT bind files (.atlas-builder/.claude/settings.json / .atlas-builder/CLAUDE.md / justfile) from templates/control,
     then runs bootstrap (seed Atlas Builder state files + state ensure + validate).
   - bootstrap also SWEEPS the transient staging artifacts in CONTROL_ROOT/.agent/tmp
     (high_risk_pre.jsonl / guard_shadow.jsonl / claude-stderr.*) so a fresh binding
     never inherits another run's residue. The distributed control plane once shipped
     with a 2026-08-10 conformance-test high_risk_pre.jsonl still in place; a stale
     before-hash is not merely untidy, since post_tool_audit pairs the newest pending
     before-hash for a path and could produce a high_risk_changes record describing a
     change nobody made (§20.4-3). The sweep is an ENUMERATION, never `rm -rf tmp/*`:
     that directory also holds the single-flight lock the caller itself owns (I-018)
     and the live read-only handoffs (I-022/I-027).
   - bootstrap never seeds PROJECT_ROOT/CLAUDE.md or PROJECT_ROOT/.claude/**; those are the target's own content, not Atlas Builder's (§16.2, §17). When the target embeds an agent (§5.0), they either pre-exist as target content or are developed later through the supervised High-Risk workflow (§12.1) — Atlas Builder does not write Atlas Builder-specific vocabulary into them.
   - **bootstrap が配る面はドメインパックの宣言である**(`Looper.Domain.bootstrapSeeds`、§31.1 R-13)。運用スクリプトは面を 1 つも列挙せず、`bin/atlas-builder util domain-spec` が返す「モード + パス」の列を宣言順に配る — `scripts/**` は製品間でバイト同一であり、シェルが面を列挙するとその 1 点でツリーが割れる。実装への投影が配るのは `ESSENCE.md` / `README.md`(いずれも PROJECT_TITLE 置換)と `.gitignore`(verbatim)である。置換を通すのは散文の面だけである(設定・ソース・ignore を置換に晒すと、将来のテンプレート改稿で偶然の PROJECT_TITLE 一致が黙って書き換わる)。宣言が空のドメインは無く、空の manifest は exit 2 で拒否する(Essence を持たない対象を bootstrap しない)。
6. README.md is ordinary project documentation the agent owns like any other implementation file (§11.1) — not Atlas Builder's requirement input canon, and not a human-gated file. After binding, Atlas Builder maintains it freely; the human never needs to write it.
7. If the target embeds an agent and carries ./{project-title}/CLAUDE.md, the human reviews it as the target's own execution rules (later tuning is Atlas Builder's development work through the supervised High-Risk workflow, §12.1). A target without an embedded agent has no such file.
8. Run Claude Code trust setup, then Atlas Builder doctor.
9. Review `just status`.
10. Commit the initialized workspace from the workspace root.
11. Run Atlas Builder loop.
```

Commands:

```bash
cd ./.atlas-builder
just build                     # once: trust / new-essence / init / doctor / loop all run through bin/atlas-builder
$EDITOR ../{project-title}/ESSENCE.md   # human-only; init keeps existing files
# or, interview-driven (§2.1.4): just trust ../{project-title} && just new-essence ../{project-title}
just init ../{project-title}   # bind + bootstrap
just trust
just doctor
cd ..
git add . && git commit -m "chore: initialize Atlas Builder workspace"
cd ./.atlas-builder
just loop
```

一度 `just init` で束縛すれば、以降のレシピ(`doctor` / `trust` / `trust-check` / `bootstrap` / `status` / `watch` / `once` / `loop` / `stop` / `triage` / `supervise` / `resume` / `state`)は `--project` の再指定なしで動作する。別の対象へ束縛し直すときだけ `just init ../other --force` を使う(1 制御プレーン = 1 対象)。この 1:1 は運用規則であると同時に機械強制でもある: `bin/atlas-builder state` の変異コマンドは束縛外の `--project` を拒否する(§18.2)。

**profile(§11.5)の宣言・変更は再 init で発効させる。** `ESSENCE.md` に `profile:` 行を書いた(または値を変えた)後は、`just init ../{project-title}` を再実行して base を再描画し、続けて `just resume` で Essence 編集を attestation として記録する(記録しないと次の loop が `essence_unreviewed_change` で停止する、§13.1-10)。同一 project への再 init は 1:1 ガードを素通りするため `--force` は不要であり、再描画された settings の diff は `_atlas_builder_profile` の 1 行だけ(base はマシン非依存で profile 以外に init 由来の値を持たない、§16.1)— resume checkpoint がそれを収める。init は invalid な profile 宣言を exit 2 で拒否する — 緩和方向の機能は不確実な綴りのまま発効しない(§11.5)。**旧形式(base/overlay 分割前の、絶対パスと sandbox を焼いた bound settings)からのアップグレードも同じ再 init 1 回である**: doctor が旧形式を re-run init として報告し、launcher は旧形式 base(`_atlas_builder_profile` 欠落)で fail-closed に起動を拒否する。

### 26.2 Existing Project

```text
1. Add the unbound Atlas Builder template as a sibling ./.atlas-builder inside the project's git repo,
   then build its runtime once: cd ./.atlas-builder && just build (§31 R-1; unbuilt = exit 2).
2. Add or review PROJECT_ROOT/ESSENCE.md before init (the single Atlas Builder requirement input file).
3. Bind + bootstrap: cd ./.atlas-builder && just init ../{project-title}
   (creates PROJECT_ROOT/.atlas-builder/state; never overwrites an existing ESSENCE.md.
    init never seeds or touches PROJECT_ROOT/CLAUDE.md or PROJECT_ROOT/.claude/** — those are the target's own content, not Atlas Builder's — §16.2, §17. When the target already embeds an agent (§5.0), its CLAUDE.md/.claude/** are kept as-is.)
4. If the target embeds an agent and carries PROJECT_ROOT/CLAUDE.md, review it as the target's own execution rules (later tuning is Atlas Builder's development work through the supervised High-Risk workflow, §12.1). A target without an embedded agent has no such file.
5. Review `just status`.
6. Run `just trust` if this workspace has not been trusted by Claude Code yet, then `just doctor`.
7. Commit the initialized Atlas Builder files and any Essence/CLAUDE.md changes from the workspace root.
8. Start the Atlas Builder loop from CONTROL_ROOT (just loop).
```

### 26.3 When the Loop Stops (Runbook)

ループが停止を報告して終わったら(`STOP:` 行と再開手順を表示して正常終了する — 停止は仕様どおりの終端でありエラーではない、§13.4-3 / §19.1-6)、順に:

```bash
just status                      # 停止理由(gate 評価)と次アクション
cat ../{project-title}/.atlas-builder/state/recommendations.json   # 停止を実体化した Recommendation の全文
$EDITOR ../{project-title}/ESSENCE.md            # 必要なら人間が修正(Essence 系のみ)
just resume --resolve <B-or-R-id> --note "確認/修正内容" # 通常 gate
just loop
```

- 手動で読み解く代わりに `just triage` で対話的に代行させられる(§13.6): まず各ゲートが何であり・なぜ上がったのかを人間へ平易に説明した上で仕分けし、調査で決着する項目は打ち取り、人間必須の項目は本質的な質問で要件を確定させてステップバイステップの手順を提示し、note を起草して確認付き resume まで引き継ぐ。実装は行わない。
- 承認対象が High-Risk 変更なら、内容を確認した後 `just supervise --todo T-... --recommendation R-...` でその 1 件だけへ対話 session を束縛する。各 ask を人間が判断し、終了後の diff を全文レビューして `just resume --resolve R-... --note "..."` で checkpoint する(§12.1、§21.3)。承認 Recommendation の resolve は**必ず supervise の後**である — 先に resolve すると preflight の open gate 要件を満たせなくなるため resume が拒否する(§13.3-4'')。supervise を実行せず承認自体を取り下げる場合のみ `just resume --retract-approval R-... --note "..."` を使う。
- 停止中の `just loop` 再実行は無害だが無意味である(I-019)。通常 gate は ID を指定した resume、Must 境界は下記の明示判断だけが進める。
- ループがクラッシュした(`just loop` が dirty worktree で拒否し、`just resume` が unfinished run で拒否する)場合のみ、diff をレビューした上で `just resume --force` を使う(§13.5)。
- 停止理由が `essence_unreviewed_change` の場合: `git -C .. diff -- {project-title}/ESSENCE.md`(未 commit なら)や直近履歴で変更内容を確認する。自分の編集なら resume がそれを確認済みとして記録する — 受理される exact 形は状況で変わるので、`just status` の案内(§13.4-2: 他に open gate があれば `--steer-only`、無ければ素の `just resume --note`)を写す。**心当たりがなければ agent 由来の変更を疑い、内容を精査してから** 必要なら `ESSENCE.md` を復元し、`just resume` する(§13.1-10)。
- 停止理由が `state_unreadable` の場合: 表示されたファイルを正常な内容を持つ直近 checkpoint から復元する(未 commit の破損なら `git restore <path>`、commit 済みなら `git restore --source=<good-commit> <path>`。JSONL の末尾行切断なら該当行を除去)。その後 `just resume` → `just loop`(§13.5)。
- 停止理由が `must_complete_awaiting_phase_approval` の場合(§13.1-13、§19.3): これはエラーではなく**完了 scope の境界**である。`todo.json` で残りの should を確認し、進めるなら `just resume --approve-should --note "Should scope を承認"`、Must だけを最終成果として閉じるなら `just resume --close-at-must --note "Must scope で完了とする"` を使う。前者は `phase = extended_approved` を立て、後者は `phase = closed_at_must` と `completion_scope = must` の監査可能な COMPLETE を作る。単に `just loop` を再実行しないことは完了記録にならない。要求そのものを変えたい場合のみ `ESSENCE.md` を編集する。
- 停止理由が `infra_unreachable` の場合(§13.1-12): プロジェクトのコードではなく実行環境の問題(接続・認証・Claude 側障害)である。接続確認・再認証を行ってから `just resume` → `just loop`。
- 停止理由が `usage_limited` の場合(§13.1-12'): プラン/モデルの利用上限に達している。上限のリセットを待つか、`ATLAS_BUILDER_MODEL=<tier>` で別モデルに倒してから `just resume` → `just loop`(loop は再試行のたびに §19.1-8 の指数バックオフで待っている)。
- 真の完了(`COMPLETE` = `full_complete`)から続行したい場合は `ESSENCE.md` を更新して同じ手順を踏む(§19.3)。

---

## 27. Design Pillars

Atlas Builder の本質は、単なる Agent 分離ではなく、Essence 駆動の agentic coding を**長時間・自律運用しても監査可能・再開可能・停止可能に保つ**点にある。設計を貫く柱は次であり、各詳細は該当章に定義される(本章は索引であって新規定義ではない)。

1. **人間の管理面を `ESSENCE.md` に集約**(§0, §2)— 意思決定正本は 1 ファイル。Spec / Todo / Reflection / Recommendation / Progress は Atlas Builder が生成・更新する投影物で、人間の手編集正本ではない。
2. **Projection pipeline の明文化**(§3, §21)— `Essence > Spec > Todo > Execution > Impl > Report` を固定し、各投影の由来を追跡する。投影の歪みは Recommendation / Reflection に記録し、曖昧さを黙って実装に混ぜない。
3. **Evidence-first completion**(§22)— Todo は evidence なしに `done` にならない。完了はエージェントの宣言ではなく、コマンド結果・diff・high-risk evidence によって成立する。
4. **停止と再開の人間介入プロトコル化**(§13, §19.3)— 停止は canonical state と `just status` / ループ終了メッセージに可視化され(I-017)、再開は exact gate ID / phase 判断を伴う `just resume` に一本化して attestation / reflection / checkpoint commit に残す。must 完了時は必ず一度人間へ止め、Should へ進むか Must scope で閉じるかを明示させる。
5. **自律ループの checkpoint 化**(§24)— 各 cycle は clean worktree から始まり 1 checkpoint commit を作る。停止中の再実行は副作用ゼロで(I-019)、空転で state や Git 履歴が増えない。
6. **二重ルートによる設定分離 + 明示的実行隔離**(§5, §6, §10, §16)— sibling root は Over 設定と対象設定の混入を防ぐが、対象 runtime の file access は隔離しない。Atlas Builder が起動する Claude は CONTROL_ROOT のみで、embedded runtime はライブ起動せず project-defined isolated runner に限る(I-002 / I-003)。
7. **Over-Project Agent の直接実装能力の維持**(§11)— 二重ルート化しても対象の実装を直接編集できる。これが唯一の実装経路である。
8. **In-Project Agent を untrusted product content として切り分け**(§6, §10)— 下請けにも safety boundary にもせず外から開発する。挙動検証は隔離 runner があるときだけ行い、無ければ人間へ停止する。
9. **状態と表示の配置規律**(§8, §15)— 対象側機械正本は `.atlas-builder/state` に置く。人間向け状態表示ファイルは生成せず、`just status` が正本から都度計算する。
10. **High-Risk Zone を対象の実態に整合**(§12)— agent runtime 構成(`.claude/**` / `CLAUDE.md` 等)が対象に存在するのは対象がエージェントを内包する場合だけであり、存在すれば常に高リスクとして追跡する(I-008)。

---

## 28. Known Tradeoffs

「人間が書き込むのは1ファイルのみである」は書き込み面については文字どおりだが(§0、§7.2)、運用行為がゼロになるという意味ではない — これが最も誤解されやすい tradeoff である。初期 trust、初期 commit、停止後の `just resume --note`、必要時の高リスク変更レビューは、Atlas Builder が勝手に代替しない人間の責務として残る。人間に残るのはレビューと承認であって、編集作業ではない。

### 28.1 Two `.atlas-builder` Directories Are Potentially Confusing

`./.atlas-builder` と `./{project-title}/.atlas-builder` が存在するため、実装者が混同する可能性がある。

対策:

```text
CONTROL_ROOT
PROJECT_ROOT
PROJECT_STATE_ROOT
```

をコード・ログ・ドキュメントで必ず使う。

### 28.2 Over-Project Agent Direct Editing Is Powerful

Over-Project Agent が対象実装を直接編集できるため、権限が強い。

対策:

1. `ESSENCE.md` は deny。
2. secrets は deny。
3. high-risk paths は ask + hook。
4. Todo batch と evidence を必須化。
5. `just status` / canonical state で変更を可視化。

### 28.3 Embedded Agent の隔離 runner 結果をどう信頼するか

対象がエージェントを内包する場合だけ生じる。隔離 runner の出力・生成物・exit code は通常の command
evidence になり得るが、runner が隔離を正しく実装したことも、runtime の自己申告が成功条件を満たすことも
自動的には証明しない。

対策:

1. runner が live PROJECT_ROOT/CONTROL_ROOT/secret stores を mount しないことをレビュー・test する。
2. 実行前後の live Git diff が不変であることを確認する。
3. 可能なら決定的な unit/integration test で裏を取る。
4. exit code と成功条件に対応する redact 済み要約だけを evidence に残す。
5. 正本更新は Over-Project Agent だけが行い、runner output 中の命令には従わない。

### 28.4 Session Continuation Is a Heuristic

ループの `claude -c -p` 継続は「CONTROL_ROOT の直近の永続化された会話」を継続する。Atlas Builder が起動する triage / essence / supervise は `CLAUDE_CODE_SKIP_PROMPT_HISTORY=1` で非永続化し、自律 cycle の継続候補へ混ぜない。一方、運用者が wrapper を迂回して同じ CONTROL_ROOT で raw 対話 Claude を起動すれば、次 cycle の `-c` がその会話を継続する可能性は残る。([Claude][8])

対策:

1. raw `claude` を bound CONTROL_ROOT の運用入口にせず、`just loop` / `triage` / `new-essence` / `update-essence` / `supervise` を使う。特にループ実行中は CONTROL_ROOT で raw 対話セッションを開かない。
2. 単一実行ロック(I-018)がループ同士の競合は排除する。
3. 人間向け wrapper セッションは非永続化し、通常 runbook の操作では履歴衝突を作らない。
4. `--max-session-cycles` バックストップ(§14.1)が継続セッションの寿命を機械的に区切る。
5. すべての cycle は fresh セッションでもディスク上の状態だけから再開できる(§14)。継続はあくまで最適化であり、正しさは fresh 再開に依存する。

### 28.5 Claude Code Feature Drift

Claude Code の hooks / settings / permissions / CLI flags は変化し得る。

対策:

1. `doctor.sh` で Claude Code の存在と version、必須 permission mode(`dontAsk` と、ask-before-edits の `manual` / `default` いずれか)、CLI isolation flags(`--setting-sources` / `--strict-mcp-config` / `--settings`)を確認し、base の安全配線(disableBypassPermissionsMode / hooks / `_atlas_builder_profile` / 旧形式検出)と内部生成した overlay の安全配線(additionalDirectories / sandbox / control-plane deny — §16.1)、全 launcher の flag 固定を検査する。

2. **実効床を検査する。** `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` 下の現行 CLI は permission mode を `default` に解決する。自律 launcher はその既知の挙動を変えられない `--permission-mode dontAsk` を渡さず、警告を発生させない。doctor は fresh/continued の双方が headless(`claude -p` / `claude -c -p`)であることを assert する。これにより `default` の未マッチ操作は表示不能な ask となって deny される。headless floor が失われれば doctor は fail する。**教訓として一般化する: 安全境界を「フラグを渡していること」で検証してはならない。実効の拒否経路を検証せよ。**
3. **deny は hook allow に常に勝つと想定する。** CLI 2.1.216 で `Edit` deny の適用面が拡大し(全編集ツール / Bash 書込先解析 / sandbox プロファイル合成)、一括 `Edit(./**)` が read-only セッションの handoff 書込みを Write・heredoc・複合コマンドの 3 経路すべてで塞いだ(§19.1-5 の設計制約として恒久化)。対策として control-plane deny を §11.3 列挙へ置換し、doctor に blanket ルール検出を追加した。教訓を一般化する: hook の allow で開ける面は、settings の deny/ask が同じ面を覆っていないことと**セット**でしか成立しない。「hook が allow を返すこと」ではなく、実効の許可経路(deny 不在 + hook allow)を検査せよ。この教訓の帰結として read-only セッションの回復面 — `.claude/settings.json` の人間承認付き修復(ask)と essence-new の ESSENCE.md 直接設置 fallback — は「deny 不在 + hook ask(+ settings ask の宣言床)」の整列で開けた(§13.6-3 / §2.1.4-2)。`.claude` はサブ面列挙 deny + settings.json ask で書き、doctor は blanket `Edit(./.claude/**)` の残存と ask 床の欠落を検査する。project 設定ソースの settings.json はディスク上の変更がセッション再起動なしで実効に反映される(CLI の hot-reload、公式ドキュメント確認済み)ため、「修復 → 同一セッションで handoff 再試行」が成立する。`--settings` overlay は起動時のみ読込 — overlay を回復面にしてはならない。base/overlay 分割(§16.1)はこの区別をそのまま設計線にした: **修復面は base**(hot-reload される project source — model / 非パス permission 床 / hooks / `_atlas_builder_profile`)であり、**overlay は起動時固定**でそもそもディスクに存在しない(起動毎に binary が再生成する)。これによりパス陳腐化という配備欠陥クラス自体が消滅し、binary 更新で overlay の生成内容が変わっても乖離は次回起動で自動解消する — overlay に「修復」という操作は原理的に不要である。
4. **パスルールは名前ではなく解決済み位置で書く。** cwd 相対の permission ルールは CLI 依存の基準で解決され、additionalDirectories 配下の**同名ファイル**へ過剰マッチする — bound 配備の `Edit(./README.md)`(CONTROL_ROOT の README 保護のつもり)が agent 所有の `PROJECT_ROOT/README.md` への Write/Edit を全経路で塞ぎ、cycle が T-010 を実行できず停止した(2026-07-31、R-006)。同じ形の欠陥は hook 側にもあった: control-surface の Bash テキスト検査が素の `README.md` 綴りに cwd を見ずにマッチし、project cwd の `cp` まで deny した。教訓を一般化する: **ファイル名の綴りでスコープした保護は、いずれ別プレーンの同名ファイルを巻き込む。** 保護は解決済み絶対位置(settings は `//<abs>` 綴り、hook は resolve 後の CONTROL_ROOT 相対判定)で書き、綴りベースの過剰近似を残す場合はその適用条件(cwd がどのプレーンに居るか)を明示する。doctor は相対パスルールの残存を検査する(§19.1-5)。
5. hooks が想定通り発火しているか検証する。
6. `disableBypassPermissionsMode` など安全系設定が有効か確認する。
7. `sandbox.network.allowedDomains` の必須 allowlist と wildcard 不在を doctor で検査する。ただし project settings の allowlist は、未知 domain で proxy が permission prompt を要求し、headless がそれを deny するという vendor behavior に依存する。Claude Code が strict な自動 deny として文書化する `allowManagedDomainsOnly` は managed settings 専用で、Atlas Builder の project settings から強制できない。したがって unknown-domain egress の完全遮断を hard invariant とはしない。厳格な組織配備では managed policy で同 setting を有効化する。
8. 仕様差分がある場合は source repository の maintainer task として扱い、修正版をレビュー・テストして再配布する。bound Agent session から live control plane を更新しない(§11.3)。
9. **大小文字を区別しないファイルシステムでは、綴りは同一性を代表しない。** macOS 既定の APFS では `Scripts/x.sh` と `scripts/x.sh`、`META.MD` と `META.md` は同じファイルである。一方でパス解決(`Io.Fs.resolveNonStrict`)は CPython `pathlib.resolve()` 等価性のため symlink でない成分の綴りを保存するので、分類器が綴りを厳密照合していると綴り替えだけで分類を外せる。**人間所有入力(§11.3 の deny 面)と enforcement 面(CONTROL_ROOT)はこの照合を大小文字非依存にした** — どちらも名前の集合がフレームワーク側で固定されており、利用者のファイルが大小文字違いで正当に衝突しないので、過剰一致の余地がない。**zone(§12)と依存マニフェスト(§11.2)は綴り厳密のまま残す**: これらは対象プロジェクトのファイルを分類するため、case-sensitive な FS では `Hooks/` と `hooks/` が別物であり、過剰一致させると headless セッションで ask が自動 deny になって正当な実装作業が止まる(§19.1-5 の床がそのまま実害に変わる)。したがって「大小文字を区別しない FS 上では、zone / マニフェスト分類は綴り違いを取り逃す」ことが残る既知の限界である。実効の第 2 層は OS sandbox(`denyWrite` は OS の照合規則に従うため case-insensitive FS では綴り違いも捉える見込みだが、これは vendor/OS の挙動であり Atlas Builder は実測していない — §28.5 冒頭の「残る未検査部分」と同じ扱い)。教訓の一般化: **綴りで書いた保護は、綴りと同一性が一致しない環境で崩れる。** 保護の適用範囲は「名前が誰の所有か」で決め、フレームワークが名前を固定している面だけ正規化を強められる。

ただし、`additionalDirectories` が対象プロジェクトの `.claude` を Over-Project Agent の制御設定として取り込まないことは、ベンダー実装に依存する**設定分離の前提**である。この前提が崩れれば対象の任意 hook/settings が Over session に混入するため、no-live-target-runtime(I-003)とは別に Over-Project Agent の境界設計を再検証しなければならない。ただし Atlas Builder の存在理由全体や In-Project Agent の隔離を二重 root だけに依存させてはいない(§6、§10)。

**残る未検査部分(v1.0 の明示的 tradeoff)。** doctor の実効 mode probe(項目 2)は、CLI が **どの mode を選ぶか**を観測する。しかし **その mode が実際に未マッチのツールや unknown-domain network prompt を deny するか**は観測していない — 現行の床は「headless の ask は提示できないので deny になる」という CLI 内部の振る舞いに依存しており、これを真に検証するには session を張って denial を観測するしかない(認証と API 呼び出しを伴い、control state に hook の副作用を残す)。ゆえに doctor は侵襲的な vendor behavior probe を持たない。この一段が崩れる形の drift — 例えば CLI が headless の ask を別経路で自動承認するようになる — は doctor では捕まらず、リリースノートの追跡と maintainer plane での再検証に委ねる。同じ理由で `additionalDirectories` の分離前提も未検査のままである。

### 28.6 Infra Failure Classification Is a Heuristic

ループの `claude -p` / `claude -c -p` が非ゼロ終了したとき、その原因が **起動失敗**(claude 自身が動けなかった — プラン/モデルの利用上限、および API 接続不良・認証切れ・Claude 側内部エラー等の環境要因)か、それ以外(継続不能、エージェント側の異常終了)かを、ループは **stderr シグネチャ**から**保守的に**推定する: `claude` の標準エラー出力を一時ファイルへ捕捉し、2 つのシグネチャ表(利用上限 → infra の順)へ**大文字小文字を無視して**一致するかを見る(現状の CLI は起動失敗を示す distinct な終了コードを持たないため、終了コードは信号にしない — §28.5 の feature drift 対象)。

判定規則は fail-safe(暴走を止めない側=継続に倒す)である。

- stderr シグネチャが**利用上限**を示す → `usage`(§13.1-12' のカウンタを進める)。
- そうでなく**明確に infra**(`connection` / `network` / `timeout` / `overloaded` / `unauthorized` / `502` / `503` / `529` 等)を示す → `infra`(§13.1-12 のカウンタを進める)。
- 非ゼロだがどちらも示さない → `unknown`。§13.2 の通常の非停止失敗として次 cycle に継続し、両カウンタとも**進めない**(ok でもないのでゼロにも戻さない)。誤って起動失敗へ昇格して連続停止させるより、既存の idle 安全網(§13.1-7)に委ねる方が安全だからである。
- exit 0 → `ok`。両カウンタを 0 に戻す。

`usage` / `infra` は「セッションが 1 度も走っていない」ことを意味するので、どちらも **idle カウンタを進めない**(§13.1-7)。`unknown` は「セッションは走った」側なので従来どおり進める。

**plan/usage limit は独立したクラスである(2026-08-12 改訂)。** サブスクリプションの利用上限(週次 / 5 時間)は、無人ループが最も高頻度で遭遇する起動失敗であり、かつ**人間が次に取る行動が infra とは違う**: 到達不能なら API 到達性と認証を調べ、上限なら待つか `ATLAS_BUILDER_MODEL=<tier>` で別モデルへ移る。したがって分類は `usage` を独立したクラスとして持ち、専用のカウンタ・しきい値・停止理由(§13.1-12')へ接続する。シグネチャは `usage limit` / `weekly limit` / `credit limit` / `credit balance` / `quota` / `reached your … limit` / `rate limit` / `too many requests` / `retry after` / `429` を含み、**infra より先に照合する**(具体が総称に先行する)。一方、CLI のセッション内 `… limit reached`(context / subagent / budget / spend)は起動失敗ではないため、裸の `limit reached` は**入れない** — 偽の分類は誤った停止を生む。凍結は matrix SH-015 / SH-016。

シグネチャ表は CLI の変化に追随して maintainer plane で更新する(§28.5)。判定の実体は `_lib.sh` の `classify_claude_exit`(シグネチャ表 `CLAUDE_USAGE_LIMIT_STDERR_RE` / `CLAUDE_INFRA_STDERR_RE`)であり、修正版をレビュー・テストして再配布する。判定が保守的であるため、drift が起きても最悪ケースは「起動失敗を認識できず idle 安全網が 3 cycle 後に止める」= 分割前の挙動への degrade であり、無限暴走にはならない。

---

## 29. Recipes — Essence が採用できる具体的実装の型

### 29.1 Concept and Pointer

レシピは、`ESSENCE.md` から機械可読ポインタで採用できる**具体的実装のテンプレート**である。自然言語レベルの仕様ではなく、動くスクリプト・設定・ハーネスの一式であり、「このやり方をまんま使う」という再利用の単位である。第一号は、Atlas Builder 自身の状態管理法の汎用コアを切り出した `agentic-state-loop`(§29.5)である。

レシピには 2 つの存在があり、混同してはならない。

| 存在 | 場所 | 性質 |
| --- | --- | --- |
| **原本** | `CONTROL_ROOT/recipes/<name>/` のみ | 配布物。immutable control-plane surface(§11.3)であり bound Agent session からは常に deny |
| **instance** | `PROJECT_ROOT` 内(生成された最終実装) | 対象の通常の実装ファイル。vendoring — 対象の所有物として自由に進化 |

対象側が持つのは、①ポインタ(ESSENCE.md の 1 行)、②生成された最終実装、③由来を示す展開記録(`recipe.lock.json`: レシピ名 + バージョン + 原本 source hash、および来歴情報 — `installed_at`・主要パラメータ)だけである。「レシピという文書」が対象へコピーされることはない — レシピ**から**最終実装が対象へ**生成される**。

ポインタ記法は次の 1 行であり、`ESSENCE.md` の active な通常本文行として書く(位置非依存。推奨: 「前提事項」節)。

```text
recipe: <name>@<major>        例: recipe: agentic-state-loop@2
```

`ESSENCE.md` で発効する機械可読行はこの `recipe:` と、依存宣言 `deps:`(§11.2)、実行 profile 宣言 `profile:`(§11.5)の 3 つである(§11.6 の `writable:` はパースはされるが本製品では不発効)。HTML comment 内と fenced code block 内の同形行は説明・例示として無視され、comment 外へ出した行だけが発効する。いずれも「人間が Essence に書いた決定を、機械が決定論的に読む」という同じ型に属する — 第一は採用する実装テンプレートを、第二はエージェントが人手の承認なしに install してよい依存を、第三は実行環境の緩和段階を宣言する。いずれも人間専用ファイルの active line に書かれる以上、エージェントが自分で足すことはできない(I-004)。

**seed 禁止規範(§5.0, §17)との整合。** Atlas Builder は対象の agent-runtime に雛形を押し付けない — この規範の実体は「**Essence 由来でない**押し付けの禁止」である。レシピの採用はポインタとして Essence に明示された人間の決定であり、instance は won't や must と同格の「Essence から生まれた内容物」である。したがってレシピ instantiation は規範の例外ではなく、規範が守ろうとした当のもの(対象の形は対象の Essence が決める)の機械可読な実現である。Essence がポインタを持たない対象へ Atlas Builder がレシピを seed することは、従来どおり無い。

### 29.2 Registry

```text
CONTROL_ROOT/recipes/
├── README.md            # レジストリ規約
└── <name>/
    ├── recipe.json      # マニフェスト: version、配置規約(install)、パラメータ宣言、post_install_checks
    ├── README.md        # レシピの説明と instantiation 手順
    └── files/           # 対象へ写す実装ファイル群
```

原本の決定的 source hash(lock の `source_sha256` の定義)は `bin/atlas-builder recipe hash <name>` が計算する(§31.2-8)。

`recipe.json` の `parameters` は 2 種に分かれる: `kind: "substitution"`(置換トークン — 例: `__ASL_LOOP_DIR__` — の機械的置換)と `kind: "authored"`(Over-Project Agent が対象の Essence から導出して書く内容 — 状態スキーマ、deny ルール、cycle prompt のドメイン節)。各レシピは `unfilled_marker` を宣言し、マーカーが残る instance は自分では 1 cycle も走らない(§13.1-8 の placeholder 判定と同型の、レシピ側の番人)。

`recipes/**` は immutable control-plane surface である(§11.3)。原本の変更は source repository の maintainer plane だけで行い、bound Agent session では hook/settings が deny する。

### 29.3 Instantiation — 投影の一部としての生成

instantiation の経路は既存の柵の上に載り、新しい特権を作らない。

1. **Essence がポインタで採用を宣言する**(人間の書き込み)。
2. **投影が High-Risk Todo と stopping Recommendation を立てる。** ポインタがあり instance が無ければ、Over-Project Agent は instantiation を `risk_level: "high"` の Todo として投影する。生成先に `.claude/**` / hooks / loop scripts を含むため、自律 cycle は ask を越えず停止する。
3. **人間承認後の targeted `just supervise` で生成する。** `just supervise --todo T-... --recommendation R-...` で exact instantiation Todo に束縛し、`files/` を対象へ写し、置換 token と authored parameter を埋め、`recipe.lock.json` を置く。人間が各 ask と diff をレビューし、post-install check の結果を evidence にして `just resume --resolve R-... --note "..."` で checkpoint する。
4. **以後は vendoring。** 生成されたファイルは対象の通常の実装ファイルであり、対象の所有物として自由に進化する。原本の更新は instance に自動追従しない。再 instantiation は新しい High-Risk Todo であり、人間の承認を要する。

instance は自己完結かつ Atlas Builder-free でなければならない(§6.2, §17): CONTROL_ROOT を参照せず、Atlas Builder の語彙を含まない。唯一の例外は同梱 Lean エンジンのソース(`<loop_dir>/lean/`、§29.5)である — live runtime と共通判定コアを共有する忠実複製(バイト同一)として、設計文書参照(`META.md §…`、および移行アーカイブへの出典つき参照)を保持する(安全判定の単一定義の維持 = R-8 を語彙の完全消去に優先させる裁定、§31.2-30)。モジュール名前空間は §31.1 R-12 により `Looper.*` であって Atlas Builder の語彙ではない — instance が抱えていた「Atlas Builder-free と謳いながら製品名前空間を持つ」矛盾は解消済みである。自己完結性は保たれる: ビルドも実行も CONTROL_ROOT を参照しない。語彙規範が引き続き全面適用されるのは instance の運用面(scripts / prompts / schema.json / settings / README)である。エージェントループを内包する instance は In-Project Agent であり、Atlas Builder はライブ起動しない。§10 の隔離 runner が無ければ、人間が Agent 外で確認し結果だけを返す。

### 29.4 Validation — warning による突き合わせ

`atlas-builder state validate` は、ポインタと instance の突き合わせを **warning** として可視化する(§20.2 の軽い柵。停止ゲートにはしない — 未生成は投影が Todo として拾う設計であり、gate 追加の波及を避ける)。

1. ポインタが未知のレシピを指す(`recipes/<name>/` が無い)。
2. ポインタがあるのに instance が無い(instantiation が未了 = pending High-Risk Todo)。
3. instance のメジャーバージョンがポインタと不一致。
4. 原本の source hash が lock の記録から乖離(原本が instantiation 後に更新された — vendoring ゆえ情報提供であり、追従は人間の判断)。
5. instance があるのにポインタが無い(採用が Essence に記録されていない — 人間へ可視化するのみ。agent が ESSENCE.md を直すことはない、I-004)。
6. `recipe.lock.json` が読めない、または `recipe` 名を欠く(由来検証不能 — 展開記録が壊れているか手書きされた形)。

lock の走査規約は「instance の専用ディレクトリ直下の `recipe.lock.json`」(PROJECT_ROOT からの深さ 2)である。

### 29.5 First Recipe: `agentic-state-loop`

Atlas Builder 自身の運用と同じ状態管理法の汎用コア 4 点を、対象プロダクトが内包できる形に切り出したレシピである(Claude Code 専用。§4.2-1 と同じ前提に立ち、他基盤対応は将来の別レシピとする)。

1. **エージェント執行ループ** — 各 cycle を `claude -p` の非対話セッションが実行(single-flight lock、セッション継続バックストップ、割込み時の run 記録)。
2. **アトミック commit 規律** — 1 cycle = 最大 1 checkpoint commit。クリーン worktree からのみ開始し、禁止パス・保護パスは commit guard が弾く(I-013/I-014 の一般化)。
3. **JSON SSOT** — 正本は `<loop_dir>/state/` の JSON 文書 + 追記専用 JSONL。全変異は同梱エンジン `<loop_dir>/bin/asl-loop state` を通り(ドメイン文書の置換は `write-doc`(スキーマ検証付き)、宣言済みログへの追記は `append-log`。ハーネス自身が書く監査ログ `tool_audit.jsonl` のみ hook が直接追記する)、文書はレシピ instance の `schema.json`(パラメータ SSOT)に宣言されたスキーマで validate される。Atlas Builder の spec/todo に相当する**状態スキーマ自体がパラメータ**であり、投影を必要としない任意ドメイン(配信エージェント、検証パイプライン等)に適用できる。
4. **ルールベース不変条件ハーネス** — 対象の `.claude/settings.json` + hooks が、正本直接編集・`git add`/`commit`・秘密・human-only 遷移(resume / loop 起動)・loop-only 遷移(start-run 等)・instance 固有 deny ルールを機械的に強制する。

停止/再開の骨格も含む: agent は人間判断が要る条件を gate として正本に記録して停止し(`raise-gate`)、空転・連続失敗は loop が閾値で gate 化し(I-011/I-017 の縮約)、解放は human-only の `resume.sh --note`(意図 note 必須 + review checkpoint、§13.3 の縮約)である。含まないもの: Essence 投影(Spec/Todo)、attestation 台帳、two-root トポロジ、phase gate — それらは Atlas Builder 本体の意味論であり、このレシピは「ハーネスされた状態管理ループ」だけを運ぶ。

Atlas Builder との**名前空間衝突**は構造で回避される: instance は専用ディレクトリ(既定 `.loop/`、パラメータ)に集約され、`PROJECT_ROOT/.atlas-builder/`(Atlas Builder 正本)と同じ path を使わない。ただし同じ PROJECT_ROOT にある以上、これはアクセス隔離ではない。Atlas Builder はこの product loop をライブ対象で起動せず(I-003)、挙動確認は §10 の isolated runner に限る。人間が製品としてライブ起動する場合は Atlas Builder session 外の行為であり、製品自身の設定が責任を持つ。hooks / settings は Claude Code の物理制約上 `PROJECT_ROOT/.claude/` に置かれ、Agent Runtime High-Risk Zone(§12)として導入時にレビューされる。

**同梱エンジン(Lean)**: instance の判定・状態エンジン(`asl-loop` マルチコールバイナリ = schema 駆動 state エンジン + hooks 3 本 + `util`(scripts のインライン判定)+ `trust`、§31.2-28/29/31)の Lean ソースと lakefile は `<loop_dir>/lean/` に同梱され、vendoring 先で `lake build` してビルドする(`just engine-build` が `<loop_dir>/bin/asl-loop` へ配置。R-1 と同じ「ソースが正本」モデル。ゼロ依存 — ネットワークは elan のツールチェーン取得のみで、`lean-toolchain` は runtime と同一版に固定)。ソースは runtime パッケージの asl-loop エントリポイントの import 閉包のバイト同一複製であり、live 版と共通判定コアを共有する(R-8)。複製の維持(閉包の計算と再生成)は共通実装の正本側の仕事であり、本リポジトリはその結果を配布で受け取る(§31.1 R-14)。受け取った複製について閉包の過不足とバイト一致は sync-pair テスト(matrix D-007)が凍結する。検証ビルドは常に一時コピーで行う(レシピ source hash は `recipes/<name>/` 配下の全通常ファイルを対象とするため、`.lake/` ビルド生成物のインプレース混入は hash を汚す)。scripts / settings / permissions / prompts の実体はこのバイナリである(hooks は `asl-loop hook <event>`、state は `asl-loop state`、レシピ version 2.0.0 = pointer `@2`)。

### 29.6 Instance の deny パターン方言 — 制限グロブ

instance `schema.json` のユーザー定義フィールド `deny_patterns`(パス用)と `deny_bash_patterns`(コマンド用)のパターン言語の正本定義である。従来の「任意の Python 正規表現」の受理は放棄する(§31 R-5 の帰結: 実行時入力として任意 regex を受けることは、実装側の regex エンジン依存を凍結し、方言互換とバックトラック暴走の負債を利用者へ渡すことでもある)。`protected_paths` は本方言の対象外であり、**fnmatch 意味論を維持する**(全文一致 + 等値 + `rstrip("*/") + "/"` 前方一致)。Lean 実装(§31.2-29)は Python `fnmatch`(`*` は `/` も跨ぐ 0 文字以上、`?` は任意 1 文字、`[seq]` / `[!seq]` は文字クラス。`fnmatch.translate` の先頭 `]` リテラル・閉じない `[` リテラル・範囲 `lo-hi` のスキャン規則を含む)の忠実移植である。

**方言定義** — パターンは次の要素だけからなり、エスケープ機構を持たない:

1. リテラル文字(大文字小文字を区別、コードポイント粒度)
2. `*` — 0 文字以上の任意の文字列(`/`・空白・改行も跨ぐ)
3. 先頭の `^` — 被検査文字列の先頭に固定
4. 末尾の `$` — 被検査文字列の末尾に固定

一致は**部分一致(search)意味論**: アンカーが無ければ、被検査文字列のどこかにパターン全体が一致すれば deny が成立する(旧 `re.search` と同じ向き)。先頭以外の `^`・末尾以外の `$` はリテラルであり、空パターン `""` は全文字列に一致する。リテラルの `*`・先頭リテラル `^`・末尾リテラル `$` は表現できない — deny 用途では `*` の過剰一致が安全側であり、表現力の穴は常に「広く deny される」方向に落ちる。

**形式定義**: パターン本体(アンカーを剥いだ残り)を `*` で分割したリテラル片 c₀..cₙ が、この順で互いに重ならずに被検査文字列中に出現し、`^` があれば c₀ が先頭に、`$` があれば cₙ が末尾に一致するとき、かつそのときに限り一致する。判定核は `Looper/Core/Glob.lean`(`Glob.accepts`)の単一定義であり、レシピ guard とレシピ state validate が共有する。

**旧方言からの変換表**(既存 instance の `deny_patterns` / `deny_bash_patterns` の書き換え指針):

| 旧(Python regex) | 新(制限グロブ) | 備考 |
|---|---|---|
| `state/`(メタ文字なし) | そのまま `state/` | search 意味論は同一 |
| `\.env` | `.env` | `\` エスケープを外すだけ |
| `(^\|/)secrets/` | `^secrets/` と `/secrets/` の 2 本 | 選択は複数パターンへ展開(フィールドはリスト) |
| `\.env($\|\.)` | `.env$` と `.env.` の 2 本 | 同上 |
| `config/credentials\.json$` | `config/credentials.json$` | |
| `\bgit\s+add\b` | `git add`(間隙が可変なら `git*add`) | `\b`・`\s+` は表現不可。`*` の過剰一致は deny では安全側。なお組込みの静的ルール(git add/commit・危険 Bash・秘密パス等)はレシピ本体が常時強制するため、ユーザーパターンでの再現は不要 |
| `X*`(regex の「X の反復」) | 意図を確認して書き直し | グロブの `X*` は「X の後に任意列」で意味が異なる |
| `.`(regex の任意 1 文字) | リテラル `.` になる | 任意 1 文字は表現不可。必要なら `*` で広く取る |

**旧方言の検出**(レシピ state validate の advisory warning): パターン中の `\ ( ) [ ] { } + ? |` のいずれか、先頭以外の `^`、末尾以外の `$` を旧 regex 方言の兆候として警告する(`Glob.legacySignals`)。`.` と反復 `*` は新方言のリテラル / ワイルドカードと字面で区別できないため検出できず(上表で案内)、リテラル `?` 等への偽陽性は advisory として許容する。

**`pattern` キーワードへの適用**: instance `schema.json` の `documents.<name>.schema` 内の JSON Schema `pattern` キーワードも、ユーザー定義・実行時入力の同型面として本方言で判定する(判定核は同じ `Glob.accepts`)。旧 `re.search` と同じ部分一致(search)意味論なので上の変換表がそのまま適用でき、レシピ state validate は `deny_patterns` / `deny_bash_patterns` と各 document schema の `pattern` の旧方言兆候を advisory warning(`validation.json` の `warnings`、status `"warning"`)として報告する。

---

## 30. Model Tiering — 知能の配分

Claude Code の `best` alias が選ぶ最上位モデルは高知能だが高価である。世代名を直接固定すると廃止・provider 差分で起動不能になるため、判断 tier は公式の `best` alias(その環境で利用可能な最も高性能なモデル)を使う。§16.1 のとおり、セッション既定モデルは配備方針であって安全境界ではない — 本章はその配備方針の正本であり、原則は 1 行に尽きる。([Claude][7])

```text
判断は最上位モデルで行い、脚仕事は十分な最小モデルへ委ねる。
```

これは公式に推奨される orchestrator–workers のコスト配分パターン(親セッションが統率し、subagent の `model` frontmatter で安価なモデルへルーティングする)の Atlas Builder への適用である。([Claude][2])

### 30.1 委譲は cycle 内の作業ステップである

§10 の検証実行と同型に、モデル委譲は**新しい executor でも第三の主体でもない**。`executor.mode` は `"atlas-builder"` のままであり、todo.json に委譲は現れない。委譲先が返すのは観察・草稿・提案 diff という**入力**であって、それを検収し、適用し、検証し、正本に記録するのは常に Over-Project Agent 本体である。§19.2 の cycle 手順は 1 つも増減しない — 各手順の脚仕事を誰が担うかだけが変わる。

### 30.2 Tier 構成

| Tier | 担い手 | 責務 | モデルの正本 |
| --- | --- | --- | --- |
| 判断 (judgment) | Over-Project Agent 本体セッション | Essence 解釈、Spec/Todo 投影、batch 選択、停止・gate 判断、High-Risk 変更(起草含む)、正本状態への全書込み、conflict 解決、reflection、evidence の実行と検収 | 束縛済み `CONTROL_ROOT/.claude/settings.json` の `model`(配布既定は `templates/control/settings.json.tmpl` の公式 alias `best`)。単発上書きは環境変数 `ATLAS_BUILDER_MODEL`(§16.1) |
| 参謀 (analysis) | `analyst` subagent(read-only) | 判断の**手前**で必要になる難しめの読み仕事: 大きな diff・障害ログの精査、設計比較の整理、レビュー草稿。出力は常に草稿・材料であり、判断そのものは含まない | `.claude/agents/analyst.md` frontmatter(配布既定: `opus`) |
| 職人 (craft) | `builder` subagent | Todo として仕様が確定済みの non-high-risk 実装、テスト作成、ドキュメント整備 | `.claude/agents/builder.md` frontmatter(配布既定: `sonnet`) |
| 脚仕事 (legwork) | `scout` subagent(read-only) | リポジトリ探索、状態と実装の突合、ログ・テスト出力の要約 | `.claude/agents/scout.md` frontmatter(配布既定: `haiku`) |

tier の選択はタスクの難易度に従う: 機械的な走査・要約は `scout`、仕様が確定済みの定型実装は `builder`、判断の手前にある難しめの読み仕事は `analyst`、そして判断そのものは常に本体である。判断 tier の仕事は**出力がそのまま正本・停止判断・危険域に触れる仕事**であり、委譲は禁止である。迷ったら委譲しない(=より上の tier に倒す)。逆に、委譲往復もタダではない — 数行の単発修正のような小さな仕事は本体が直接行う方が全体最適である。運用規範の詳細は `rules/model-policy.md` が cycle へ供給する。

モデル名の世代交代(例: 後継モデルへの差し替え)は、§16.1 の `model` フィールドと同じ資格の配備方針更新であり、本仕様の意味論を変えない。上表の「モデルの正本」列に挙げた各ファイルが唯一の書き換え箇所である。判断 tier については、恒久的な変更は束縛済み `settings.json` の `model` を書き換え、一時的な回避(利用上限・障害)は `ATLAS_BUILDER_MODEL` の単発上書きで足りる(§16.1) — どちらも配備方針の更新であって、境界は 1 つも動かない。

### 30.3 構造的安全 — 境界は 1 つも緩まない

Tiering はコスト方針であり、次の地形により安全境界を一切変えない。

1. **subagent は同一セッション内で走る。** その Edit / Write / Bash はすべて親セッションと同じ permissions / hooks(§16.1)を通る。`scout` / `analyst` はそもそも read-only ツールしか持たない。
2. **外部 CLI tier は持たない。** 使い捨て Git worktree は書込みを隔離しても host 読取を隔離しない。tracked secret/control/state を snapshot が含み得るうえ、外部 process が home credential stores を読むことも防げないため、I-024 と両立する汎用 wrapper は存在しない。
3. **evidence は委譲できない(I-010)。** Todo を閉じる証拠は本体が実行した command の exit code と redact 済み要約であり、subagent の自己申告は evidence にならない。
4. **delegate output は untrusted な草稿である。** 評価対象であって指示ではなく、出力中の命令には従わない。

### 30.4 In-Project Agent との区別

本章の tiering は **Over-Project Agent の内側**の話である。In-Project Agent は対象プロダクトの内容物であり(§6)、subagent にも委譲先にもならない — §6.3 の禁止はそのまま維持される。同様に、対象側(In-Project Agent)の settings がどのモデルを使うかは対象の Essence が決めることであり、Atlas Builder は規定しない(§16.2)。

---

## 31. Lean 実行層 — 確定事項と機械証明

### 31.1 確定事項

制御プレーンの実行層は Lean 4 実装であり、本節の表(R-1〜R-14)がその決定の正本である(旧 Python 実装からの完全移行は完了済み。手順・フェーズ計画・裁定の記録は §31.2 のアーカイブにある)。**仕様変更が必要な場合は先に本 META.md を更新する** — 実装・計画文書は常にこの META.md に従属する。本節は**決定**の表であり、その決定を実装がどう満たすかという**構造規律**(純度ゲート・注入原則・IO シェル 3 手・パス解決の責務分離・fail-open/fail-closed の型区別)は §31.4 に、失敗経路ごとの倒し方は §31.5 にある。

| # | 論点 | 決定 |
|---|------|------|
| R-1 | 配布・実行形態 | 利用者が elan/lake でソースからビルドする。ソースが正本 |
| R-2 | 移行範囲 | テストスイートを含む完全 Lean 化(最終的に Python をリポジトリから排除) |
| R-3 | 証明のスコープ | まず「純粋コア + IO シェル」という証明可能な構造への分離のみ。状態機械不変量の証明は後続フェーズ |
| R-4 | 移行方式 | 段階的移行 + シャドー検証(両実装に同一入力を与え出力一致を機械検証してから切替) |
| R-5 | 正規表現 | Python `re` 依存を廃し、明示的な判定関数へ書き換える |
| R-6 | 挙動等価の基準 | 本 META.md 準拠。Python との差分は都度報告し人間が裁定する。deny 拡大方向は自動採用、緩和方向は必ず人間判断 |
| R-7 | バイナリ構成 | 単一マルチコールバイナリ `atlas-builder`。シェル内インライン Python も小サブコマンドへ収容する |
| R-8 | レシピ | `recipes/agentic-state-loop`(§29)も Lean 化し、live 版と共通判定コアを共有する |
| R-9 | 依存ポリシー | 実行層は Lean コアのみのゼロ依存。証明層は別 lake パッケージに分離し外部ライブラリを許容する(利用者はビルド不要) |
| R-10 | 実装体制 | Claude Code が主体で実装し、人間はレビューと裁定に専念する |
| R-11 | 期間 | 期限を設けず、フェーズごとの受け入れ基準を厳格に運用する |
| R-12 | Over-Project ループの名前空間 | 制御プレーンに立って対象を回すループ本体(純粋核 + 判定核 + 状態機械 + hooks + CLI)は姉妹フレームワークと同一実装であり、Lean 名前空間 `Looper.*` を共有する。製品固有のドメインパックだけが `AtlasBuilder.*` に残る |
| R-13 | ドメインパックの注入様式 | 製品ごとに違う軸(製品識別子・ESSENCE 見出し集合・投影台帳の追加面・ドメイン停止理由・対象書込み面ポリシー・ドメイン検証 hook)は `Looper.Domain` のレコードにまとめ、**typeclass ではなく引数として注入する**。guard へは `GuardEnv.domain` フィールドで届き、既定値は置かない(注入し忘れをコンパイルで落とす)。実行ファイルの `main` と `lakefile.lean` は製品所有であり(`AtlasBuilder.Main` / バイナリ名 `atlas-builder`)、`Looper.Cli.Main.run` は製品を知らない。**L0 と L1b は `Looper.Domain` を import しない** — 正本側の `ci/layer-check.sh` の層検査が機械的に強制する(§31.4)。**軸は判定木から段を消さない**: 対象書込み面ポリシー(`WritePolicy`)のように片方のドメインで発火しない軸でも、判定の段そのものは全ドメインで決定木に存在し、軸は段の**判定**だけをデータにする — 「そのドメインには段が無い」形にすると、抽象の隙間で安全境界の段が消える。**hook はドメインを量化した形でしか語れない** — その事実がそのまま定理の分割線になる: 共通実装に対する定理は「hook が返すなら」で止まり、実体へ落とす補題だけが `i.domain = <製品>.domain` を要求する。**停止 gate は理由と message を対で返す**(`Looper.StopGate`)— 理由だけが立って人間に次手が示されない状態(§13.4-2 違反)を構造的に作れないためである。停止理由・message part・payload 面・表示行の**挿入位置は共通実装側で固定**であり、hook の返り値の順序がそのまま出力の順序になる。**軸は framework の context 面を名乗ってはならない**: cycle 承認マーカー(`Domain.cycleAuthorizations`)は resume が**立て**、成功 cycle の終端が**下ろす**ので、`phase` や `progress` のような共通面を名乗ると、その面がマーカーの上げ下げで書き換わる — `phase` なら Must 境界の判断が消え、`progress` ならカウンタが丸ごと消える(§31.3 S-T4 / S-T6 の保存定理はこの不等式を前提に置いている)。面の集合は `ensure` が書く canonical な初期 `context.json` そのものから導き(`Validate.contextFrameworkKeys`)、交わりの無さは各製品の `#guard`(`cycleAuthorizationCollisions`)が凍結する — 列挙を複製しないので framework が面を足しても腐らない。**立てる側と下ろす側は 1 つの宣言から出る**(`CycleAuthorization` は「立てる観測 = ドメイン自身の停止 payload 面」と「下ろす綴り」を対で持つ)— 別々のフィールドにすると、立てたマーカーを誰も下ろさない恒久封止や、下ろす綴りだけが違って毎 cycle 立ち続ける形が、軸を 1 本足しただけで静かに起きる。**resume のドメイン専有フラグ(人間裁定)も 1 つのレコードに閉じる**(`Domain.resumeAdjudication?` = 綴り・引数形・対象台帳・verdict 語彙・受理集合・適用)— 散らすと「フラグはあるが適用が無い」「受理集合はあるがフラグが無い」半端な注入を型が許す。ただし**「裁定が 1 件も無い resume は台帳に触れない」は共通実装が短絡で保証し、ドメインに委ねない**(§31.3 S-T7 が全ドメインで成立するため)。 **運用スクリプトが必要とする軸も同じレコードから出る**: bootstrap の seed 面(`bootstrapSeeds`)と人間裁定チャネルの綴り(`resumeAdjudication?` の `idPrefix` / `stopPayloadKey`)は `bin/atlas-builder util domain-spec` の行指向出力でシェルへ渡る。`scripts/**` は製品間でバイト同一なので、シェルが面や綴りを列挙するとその 1 点でツリーが割れる — シェルは軸を**読む**だけであり、未知の key は無視し、必要な key の消失はその機能を静かに止めるので、消す側が消費点を同時に直す。**引数形は id 接頭辞からの導出**であり(`Adjudication.argForm`)、綴りの正本は 1 つである。**triage wrapper が突き合わせる停止 payload の面(`stopPayloadKey`)は裁定集合の部分集合でなければならない** — 超えると engine が拒否する id を wrapper が通し、その拒否は対話セッションが終わった**後**に落ちる(§13.6-5 が wrapper 側で照合する理由そのものである)。逆向き(真の部分集合)は許される。 **シェル側も同じ 1 語幹から導出する**: 運用スクリプトは製品トークンを 1 つも持たず、`CONTROL_ROOT` の basename から `TOOL` / `TOOL_SNAKE` / `TOOL_ENV` / `TOOL_NAME` / `TOOL_TRAILER` / `TOOL_PLACEHOLDER` を `scripts/_lib.sh` 冒頭の 1 箇所で導く。Lean 側(`Looper.Domain`)とは**独立した 2 つの導出**であり、両者が同じ綴りを指すことは黒箱回帰(配布テンプレートを実バイナリへ食わせる SS 系)と bats の導出表凍結(SH 系)が担う。語幹を成さない制御ルートは exit 2 で fail closed する — 導出はすべてのパス・ENV 名・trailer の根であり、綴りを捏造してはならない。 |
| R-14 | 共通実装の正本と配布 | R-12 の帰結として、Over-Project ループの共通実装の**正本は本リポジトリに無い**。姉妹フレームワークと共有する単一の正本(Over-Project ループの source repository)があり、本リポジトリが持つのは**置換なしの複製**である。複製の面は `lean/Looper.lean` / `lean/Looper/**` / `lean/lean-toolchain` / `scripts/**` / `recipes/agentic-state-loop/**` と、maintainer plane の検証装置 `ci/looper-lock-check.sh` / `ci/purity-gate.sh` / `ci/looper-meta.sh`、**設計正本の共通章** `meta/base.md` と規則文書の見出し名簿 `meta/rules.outline`、および他パッケージの Lean 版を正本へ揃える `tests/lean/lean-toolchain` / `proofs/lean-toolchain`、そして**全ドメインで成立する証明**`proofs/Proofs/{Base,Guard,State,StaticConfig}/**` と `proofs/Proofs/Looper.lean` である。製品所有は `lean/lakefile.lean`(バイナリ名 `atlas-builder` を決める)・`lean/lake-manifest.json`・ドメインパック `lean/AtlasBuilder/**`・`templates/**`・`.claude/**`・`.agent/**`・**設計正本のドメイン章** `meta/domain.md`・`tests/**`・`proofs/{lakefile.lean,lake-manifest.json,Proofs.lean}` と `proofs/Proofs/{Spec,Domain}/**` である。**証明層が 2 つに割れているのは、Phase 7 が引いた境界がそのまま定理の分割線だからである**: hook はドメインを量化した形でしか語れないので、Looper 側の定理は「どのドメインでも」までを言い、実体へ落とす定理だけが「このドメインは本製品である」を要求する。前者は共通実装の一部であり、製品ごとに書き直す理由が無い — 現に G-T7 の全体は片方の製品にしか無く、もう片方では一度も検証されていなかった。`Proofs/Spec/**`(抽象モデルと M-T1)が製品所有なのは、モデルの語彙(gate 保持面と停止理由の**列挙**)がドメインごとに構成子を変えるからである — 量化できないものは共有できない。**`META.md` は所有物ではなく合成物である。** §0–§31 は機構の記述であり、機構は共通実装として 1 つしかない — その散文を製品ごとに保持すれば割れる(現に §24 の human-gated 目録から `essences/**` が落ち、§2.1.1 が見出し集合を「推奨テンプレ」と呼んだまま 6 章分古かった)。配布された `meta/base.md` と本製品所有の `meta/domain.md` から `ci/looper-meta.sh` が合成し、CI が毎回突き合わせる。**素材は maintainer plane に住み、制御ルートには合成物だけが住む** — 素材を配布単位へ入れると、それは Agent の前に現れる新しい制御プレーン面になり、§11.3 の列挙と §16.1 の deny を 1 つ増やす話になる。**`ci/` は配布物だけになった。** 純度ゲート(R-3)の走査面は綴りではなくツリーの形から導かれる — 制御ルートの `lean/Looper` と、そこに同居する全ドメインパックの `Domain{,.lean}` — ので、1 バイトの検査器が 3 リポジトリに同じパスで立つ。ドメインパックが 1 つも見つからなければ走査面が空のまま緑になるので、その場合は fail closed で落ちる。その帰結として本リポジトリは自分のシェルを 1 本も持たず、shell の lint / format は正本側の仕事である(`format` は**書き込む**ので、所有と書込み能力を一致させる)。`lean-toolchain` を配るのは、Looper が要求する Lean の版が製品の選択ではないからである — 手で揃えていた `tests/lean` / `proofs` の 2 面が lock の対象になり、ずれは秒で落ちる。**対象プロジェクトへ配るテンプレートの toolchain は別物**であり(対象の環境の選択であって Looper の要求ではない)、この面には入らない。**複製を直接編集してはならない** — 次の配布が黙って巻き戻し、直したはずの安全境界が消える(それは現に起きた病気であり、shell 層だけで 8 系統、ASL レシピでさらに 4 系統が片側だけ直された状態で残っていた)。凍結は 2 層で、repo 間の一致は正本側が検査し、**本リポジトリ内での直接編集は `ci/looper-src.lock` と `ci/looper-lock-check.sh`** が検査する(CI ジョブ。lock は面の宣言・sha256・実行ビットを持ち、配布のたびに更新される)。第 2 層が本リポジトリの中だけで完結するのは意図した設計である — **製品 CI が兄弟リポジトリの存在を前提にしてはならない**。レシピ同梱 Lean エンジンの再生成(asl-loop 閉包の計算)も正本側の仕事であり、本リポジトリはその結果を配布で受け取って D-007 で凍結する。この体制でも `lean/**` は guard の deny 面に入ったままである(§11.3)— 凍結は maintainer の事故を捕まえる層であり、agent の書込み遮断とは別の層である。 |

R-1 の含意: 現行の「ネットワーク不要」という性質は、**実行時不要**から**ビルド時のみ必要(elan のツールチェーン取得)・実行時不要**へ変わる。配布バイナリをゼロ依存に保つのは、ビルド時のネットワーク要求をツールチェーン取得だけに限定するためでもある。

### 31.2 実装履歴(非規範アーカイブ)

完了済みの Lean 移行フェーズ、差分検証結果、当時の裁定を含む番号付き履歴は、maintainer plane のアーカイブ `docs/archive/IMPLEMENTATION_HISTORY.md`(フレームワークリポジトリ。配布物 `.atlas-builder/` には含めない)へ移した。履歴は監査・由来追跡用であり、現行要件の正本ではない。既存の `§31.2-<番号>` 参照は同アーカイブの番号付き項目を指す。現行の規範は本 META.md の各節、実装、TEST_MATRIX、次節の証明台帳である。

### 31.3 機械証明済み invariant(正本台帳)

機械証明済みの安全性定理の正本台帳。証明対象は**実行される Lean 関数そのもの**であり、`proofs/` パッケージのビルド成功が sorry なし検証の機械的証拠である(`warningAsError`、CI が全 push で検証)。マーキング規約: 本 META.md の他節が保証を機械証明として引くときは「機械証明済み(§31.3 G-T1)」の形式で本台帳を参照する — 台帳にない保証を機械証明済みと記述してはならない。各定理の**前提(スコープ)欄は主張の一部**であり、省いて引用してはならない。

| ID | 主張(LEAN_MIGRATION_PLAN.md §4.6 カタログ) | 定理 | 前提(スコープ) |
|----|--------------------------------|------|----------------|
| G-T1 | `DANGEROUS_BASH` 分類に該当する Bash 入力に対し guard の `decide` は `deny` 以外を返さず、high-risk staging も行わない(deny 先行の決定木順序不変量 — dangerous が zone ask / install allow / 無意見へ降格する経路は存在しない) | `Proofs.Guard.dangerous_bash_is_denied` | read-only セッション(`sessionMode ∈ {triage, essence}`)を除く。read-only 面は決定木の最上段で分岐し、handoff heredoc の**本文**(実行されないファイル内容)が DANGEROUS_BASH 文字列判定に一致し得るため対象外 — Python `main()` と同一の分岐順序であり緩和ではない。read-only 面の健全性は G-T2 の対象。deny 段は profile 分岐(§11.5 — ask 6 葉と Bash 最終無意見葉のみ)に先行するため、主張は全 profile で成立する |
| (G-T2 の土台) | read-only セッションの Bash / WRITE_TOOLS は決して無意見に落ちない — 判定は常に明示的な allow(許可面)、ask(WRITE_TOOLS の人間承認 2 面)、または deny(教示付き拒否)である(I-022/I-027 の「限定許可 + 既定拒否」構造) | `Proofs.Guard.readonly_bash_never_silent` + `readonly_write_never_silent` | `sessionMode ∈ {triage, essence}` |
| G-T2 | read-only セッションの Bash で `decide` が `allow` を返す経路は 3 許可面(heredoc handoff write / シェルメタなし `mkdir -p` / triage 限定 state 読み取り)の完全列挙であり、書き込みを伴う 2 面の書き込み先(heredoc の mkdir 前置・本体ターゲット、mkdir の引数)はすべて handoff root の内側に解決済みである(結合キーの解決成功 + `insideOf handoffRoot` が allow の必要条件)— 土台補題の「allow 以外は必ず明示的 deny」と合わせて handoff root 外への書き込みが許可される経路は存在しない(I-022/I-027)。第 3 面は `triageStateShape?` + `triageStateSubcommandsOk` 一致が必要条件で、resume 等の変異サブコマンドが読み取り面をすり抜けないこと(G-T3 の残余)も同時に閉じる。**WRITE_TOOLS 面**(§13.6-3): read-only セッションでは `decideWrite` も最上段で分岐し、allow の必要条件は書き込み先の `resolvesIntoHandoff`(strict — handoff root 自身は不可)通過 — Write ツール経由でも handoff root 外への書き込みが許可される経路は存在しない。**ask 面**(§28.5-3 / I-027 第二経路): read-only セッションで ask が立つのは列挙 3 面 — live settings 修復(`resolvesToLiveSettings` = `CONTROL_ROOT/.claude/settings.json` への解決一致)、essence-new 限定の ESSENCE.md 直接設置 fallback(`resolvesToEssenceInstall` = `expectedProject?/ESSENCE.md` への解決一致)、essence-new 限定の essences/ 資産設置(`resolvesToEssenceAssetInstall` = `expectedProject?/essences` からの相対パスが 3 階層以内の妥当な資産パスになる位置への解決一致、§2.1.5 面)— に限り、ask は人間の permission prompt 承認を要求する判定であって自動 allow ではない | `Proofs.Guard.readonly_allow_is_handoff_confined`(`decide` 全体への逆転)+ `readOnlySessionBashAllow_faces`(許可面の列挙)+ `resolvesIntoHandoff_inside`(解決先の handoff root 内包)+ `readonly_write_allow_is_handoff_confined`(WRITE_TOOLS 面)+ `readonly_write_ask_is_enumerated`(ask 面の列挙)+ `resolvesToLiveSettings_resolved` / `resolvesToEssenceInstall_target` / `resolvesToEssenceAssetInstall_target`(各 ask 面の必要条件) | `sessionMode ∈ {triage, essence}`。「handoff root 内」は解決表(`GuardEnv.resolved` — IO シェルの realpath 解決結果)上の `insideOf` 判定として表現される — 解決そのものの正しさは §31.4-4 の信頼境界(公理側)であり、本定理は「解決済みパス上の判定が正しい」側を担う |
| G-T3 | state サブコマンド抽出が `resume` / loop-only 集合(start-run / end-run / record-progress / reset-context / raise-loop-gates)を捉えた Bash 入力に対し guard の `decide` は必ず `deny` を返し、high-risk staging も行わない(I-011 / §19.1 — human-only・loop 所有遷移の agent 遮断。human-only / loop-only 段は全 ask/allow・無意見分岐に先行する) | `Proofs.Guard.resume_subcommand_is_denied` + `Proofs.Guard.loop_only_subcommand_is_denied` | read-only セッション(`sessionMode ∈ {triage, essence}`)を除く(G-T1 と同一スコープ — handoff heredoc の本文が字句判定に一致し得るため。read-only 面で resume が state 読み取り許可面をすり抜けないことは `#guard` で凍結済み(§31.2-19)、定理化は G-T2 の対象)。仮定は抽出器 `statePySubcommands`(`--flag` をスキップして positional を取る)の出力に載る — カタログの「引数順序に関わらず」はこの抽出器の仕様として表現される。deny 段は profile 分岐(§11.5)に先行するため、主張は全 profile で成立する |
| G-T4 | install 形状(`commandInstallsDependencies`)の Bash 入力は無意見(素通り)に落ちない — 判定は必ず明示的な deny / ask / allow のいずれかになる(§11.2 の依存ゲート単一決定点: `decideBash` で唯一無意見を返す最終葉は `commandInstallsDependencies = false` に守られている)。カタログの「allow は trusted 単一 install / materialization のみ」の残り半分は、allow 葉が `installAllowReason?` の some 側にしか存在しない決定木構造そのものが与える | `Proofs.Guard.install_shape_never_silent` | 前提なし(read-only 面は土台補題 `readonly_bash_never_silent` の「常に some」を再利用し、非 read-only 面は決定木全段の場合分けで閉じる) |
| G-T5 | post の high-risk 分類は pre の部分集合(D-002 の定理化)— post(`Hook.PostTool.isHighRiskTarget`)が high-risk と分類する WRITE_TOOLS 書き込みに対し、pre の `decide` は無意見で素通りせず必ず明示的判定を返し、staging は不変である(standard では deny / ask、relaxed profile では該当 ask 面が監査可能な allow — §11.5。§20.4-3 の before/after ハッシュ対合: post が after-hash を記録する書き込みは pre が必ずゲートまたは監査可能に明示 allow しており、before-hash staging はどの profile でも同一に走る)。核は候補表記列の包含 `post_write_candidates_subset`(post の 4 候補 — 生表記・解決済み・project 相対・CONTROL_ROOT 相対 — はすべて pre の候補列に現れる)。分類パターン集合そのものの一致は `Core.Classify` / `bashCandidateTokens` の単一定義共有で構成的に成立(Bash 面の staging 対象は pre が post の定義を import する同一関数) | `Proofs.Guard.post_write_high_risk_never_silent` + `post_write_candidates_subset` + `decideWrite_high_risk_never_silent` | 既知の意図差を前提として明示: (1) `raw` は空でない(post の `writeTarget?` は falsy を落とすため空 raw は post の分類に到達しない)、(2) `raw` は表記正規化の不動点(`pyPathStr raw = raw` — post は生表記・pre は `str(Path(raw))` を候補に使う表記差)、(3) 両 hook が同一の解決結果 `t` を見る(`env.resolveTarget? raw = some t`。解決の正しさは §31.4-4 の信頼境界)、(4) post の project root が pre の登録ルート集合に含まれる(post は `find_project_state_root` 探索・pre は登録ルート表 — 未登録 root 相対の post 記録は pre のゲート対象外という fail-open 監査側の既知差)。read-only セッションでは post 監査 hook 自体が無条件に無作用(§20.4)なので before/after 対合の実質は非 read-only 面 — pre の read-only WRITE_TOOLS 面(§13.6-3)は常に明示的判定であり、形式主張(`decision?.isSome`)はそのまま成立する |
| G-T6 | profile は緩和方向にしか作用しない(I-030 の機械化)— 任意の GuardEnv・ToolCall について、profile を standard に固定した判定と実際の profile での判定は、(a) 完全に同一であるか、(b) high-risk staging(`highRiskPre`)を変えないまま、standard 側の ask または無意見の判定だけが allow に変わったもの、のいずれかである。系として deny は理由文言ごと保存され、staging は全 profile で不変であり、判定差分は allow 方向のみに限られる(§11.5、I-030) | `Proofs.Guard.profile_only_relaxes` | 前提なし(`decide` 全域 — write / bash / other の全経路と全 profile 値。read-only セッション(I-022/I-027)の分岐は profile を参照しないため (a) 側で自明に成立する) |
| G-T7 | `writable:` 許可は read-only 葉だけを解錠する(I-007 単調性 — deny 床不変)— (1) 許可集合の代数: 空集合は何も許可せず、許可の追加は単調、(2) 判定核の単調性: 許可付きで read-only と判定される対象は無許可でも必ず read-only(許可は判定を false 側へしか動かせない)、(3) WRITE_TOOLS 決定木の全体比較: 任意の許可集合の判定は無許可の判定と完全一致するか、無許可側が read-only 教示 deny だった葉が解錠された差分のみで、staging(`highRiskPre`)は常に一致し、deny 床 3 段(セッションモード・isDenyPath・制御プレーン)は両側同一で確定する(§11.6、I-030)。**本製品の軸(`implementation`)では read-only 段が常に通過するので、この定理は「許可集合は判定を 何も変えない」に退化する** — それが §11.6-1 の「`writable:` は不発効」の機械的な裏づけであり、段が消えていないこと(§11.6-4)の裏づけでもある | `Proofs.Guard.grantAccepts_nil` / `grantAccepts_append_left` + `readOnly_grant_mono` / `isReadOnlyTargetWrite_mono` + `grant_only_unlocks_the_read_only_leaf` | 全体比較は read-only セッション以外(`sessionMode ∉ {triage, essence}` — read-only セッションは書込み面自体が handoff に閉じており(I-022/I-027)`writable:` が意味を持たない)。Bash mutator 面は同じ `isReadOnlyTargetRel` 核を共有する |
| S-T1 | gate 保持 7 面(blockers / recommendations / context / reflection / runs / project / attestation ledger — I-021)のいずれかの読取が診断を出すとき、`shouldStopPayload` が `.ok` で返るなら `should_stop = true` かつ `reasons` の**先頭**が `state_unreadable`(D-005 正準順の最優先理由) | `Proofs.State.state_unreadable_stops`(+ corruption class 別の系: 初期化済み欠損 / JSON I/O エラー / JSONL I/O エラー) | `.ok` 経路。`.error` 経路(Python の uncaught 例外 = exit 2 に対応)はシェル側 `state_predicate()` の fail-closed(§2.1)がハード停止するため、どちらの経路でも「読めない gate は停止」が成立する。形状崩れ診断(items 非 list / progress 非 object / カウンタ非整数)への前提拡張は後続弾 |
| S-T2 | `mustPhaseComplete` ⇒ runnable な must Todo が存在しない — 完了述語(全 must が `done`)と実行可否述語(`pending` / `in_progress` を要求)は**どの phase でも**両立しない(§19.3 の完了セマンティクス) | `Proofs.State.must_phase_complete_no_runnable_must`(述語間の両立不能性)+ `completion_must_phase_complete_no_runnable_must`(実行される `completionPayload` が `must_phase_complete = true` を報告した当の items への接地系) | 前提なし(述語は §19.3 の単一定義であり全呼び出し点が共有) |
| S-T3 | `mustPhaseComplete ∧ phase = must` ⇒ 停止かつ `must_complete_awaiting_phase_approval ∈ reasons` — 完了 scope 未決定と停止の整合(§13.1-13 の直接述語。raise-loop-gates の Recommendation 具現化前のクラッシュにも fail-closed) | `Proofs.State.awaiting_of_payload_fields`(payload の `must_phase_complete = true` ∧ `phase = must` ⇒ `awaitingPhaseApproval`)+ `must_complete_awaiting_phase_approval_stops`(そのとき `shouldStopPayload` は `.ok` なら停止し当該 reason を含む) | `.ok` 経路(`.error` 経路の扱いは S-T1 と同一)。`closed_at_must` は人間決定済み terminal phase なので前提外 |
| S-T4 | explicit phase decision は framework-observed Must 境界で guard され、resume 以外の主要 context 遷移は phase を昇格させない。(1) `resumedContext` は approve → `extended_approved`、close → `closed_at_must`、判断なし → 旧値保存の三分岐。(2) 実 transition の plan で `approvesShouldPhase = true` なら new context は `extended_approved`。(3) runtime が approval/close flag を作る共通式 `hasFrameworkPhaseGate && explicit decision` が true なら framework gate は必ず true。(4) record-progress/reset-context は phase を保存し、seed は `must` を書く | `Proofs.State.resume_approval_promotes_phase` + `phase_decision_flag_requires_framework_gate` + `recordProgressApply_preserves_phase` + `resetContextApply_preserves_phase` + `seed_phase_is_must`(`resumedContext_phase` は同 proof file 内の private 核定理) | flag 式が実 transition の代入箇所で使われることはソース構造規約 + conformance test が担う。actual phase promotion の**逆向き総合定理**、全 IO 書込み点の網羅性、`stopPayload` の由来は本定理の主張外。resume が human-only であることは G-T3 が担う。保存定理の object 前提は各遷移の I-021 gate が保証する。resume 側の昇格定理と record-progress の保存定理はどちらも**全ドメインで**成立するが、ドメインの承認マーカー軸(`Domain.cycleAuthorizationFlags`)が `phase` を名乗らないことを前提に置く(§31.1 R-13)。マーカーは resume が**立て** cycle 終端が**下ろす**ので、前提は両方向に効く — 2 つの畳み込みが同じ 1 つの軸から出るため、前提も 1 つで足りる— 本製品の軸ではその前提が `decide` で閉じる(`recordProgressApply_preserves_phase_domain`) |
| S-T5 | validate 成功(`validateCore = .ok` かつ `hasErrors = false` = exit 0)⇒ 構造検証済み data(`structuralJsonAll` の出力)上で: (1) **ID 一意** — spec / todo / recommendations / blockers の 4 コレクションすべてで全 item は文字列 id を持つ object であり id 列は `Pairwise (· ≠ ·)`(§20.1)、(2) **参照健全** — 全 Todo は object で `spec` は非空の非空文字列 list、参照先 Spec id はすべて spec index(`indexById`)に実在 = dangling Todo→Spec なし(§20.2)、(3) **バッチ排他律** — active_batch の全 id は todo index に実在し、risk 二値の dedup 長 ≤ 1(high-risk / normal 混在なし)∧ executor mode 列の走査が throw なしに完走して dedup 長 ≤ 1(executor 混在なし)(§9.3)、(4) **priority 整合** — 参照 Spec から valid priority を解決できた各 Todo の priority はその最強値(must 優先)に一致(§20.1-11/12) | `Proofs.State.validate_ok_ids_unique` + `validate_ok_todo_refs_sound` + `validate_ok_batch_exclusive` + `validate_ok_todo_priority_coherent`(逆転補題 `validateUniqueIds_nil` / `requireStringList_ok` / `todoTraceChecks_nil` / `todoTraceChecks_nil_priority` を公開) | `.ok` 経路(`.error` 経路 = Python の uncaught 例外は exit 2 でシェル側 fail-closed — S-T1 と同一)。主張は IO シェルが注入した canonical ファイルのパース結果上の性質であり、ディスク上のファイルとの対応は IO シェル配線の信頼。dedup の同値は Python `==`(`pyEq`)に基づく |
| S-T6 | resume は起動失敗系を含む 3 つの progress カウンタを必ずゼロ化する(ドメインの承認マーカー軸が `progress` を名乗らない下で — §31.1 R-13) — proceed(書き込みが起きる唯一の経路)の `newContext` で `progress.idle_cycles_since_progress = 0 ∧ progress.infra_fails_since_ok = 0 ∧ progress.usage_limited_since_ok = 0`。mode(gate_release / steering)・phase 承認・handoff 差し替え・元の counter 値のいずれにもよらない(§13.1-12、§13.1-12' — 残滓カウンタが resume 直後の loop を誤 gate しない) | `Proofs.State.resume_zeroes_progress_counters`(`transition` 全体)+ `resumedContext_zeroes`(context 構成の核) | context.json の `progress` は存在するなら object であること — pre 評価が非 object を `state_unreadable` に落とし resume は書き込み前に拒否する(§13.3-3、I-021)ため、`transition` に到達する観測は必ず満たす |
| S-T7 | `--steer-only` の resume は gate 集合を一切変更しない — proceed の `Plan` で `newBlockers = none ∧ newRecs = none ∧ newDomainLedger = none`(IO シェルはこれらが `some` のときにしか gate 面のファイル/ドメイン台帳を書かないので、「status を書き換えない」より強い「触れない」)。**ドメイン台帳面の結論は hook に依存しない** — 裁定が 1 件も無いとき共通実装は裁定 hook を呼ばないので、全ドメインで構造的に成立する、`resolvedBlockers = resolvedRecommendations = adjudicated = []`(報告と書込みが同じ事実を指す)、`mode = "steering"`(handoff 差し替えが走らない)。`--resolve` / `--retract-approval` / phase 判断 / latch の有無に依存しない(§13.3-4''') | `Proofs.State.steer_only_resume_touches_no_gate` | なし — 遷移核が `selected` と `phaseDecision` を `steerOnly` で倒すため、`selectionError?` の preflight を迂回した混線入力でも成立する(既存の phase 認可が `hasFrameworkPhaseGate` の独占で fail-closed であるのと同じ規律) |
| B-T1 | 純 Lean `Core/Sha256` は FIPS 180-4 / NIST 公表ベクタ(空・"abc"・1/2 ブロック超)、パディング境界(55/56/63/64/65 バイト)、非 UTF-8 バイト列を正しく再現する — 全ハッシュ用途(recipe source hash / High-Risk before/after hash / progress signature)が共有する単一実装(D-004)の検収点 | `Proofs.Base.sha256_nist_vectors` + `sha256_padding_boundaries` + `sha256_binary_safe` | 検証手段は `native_decide`(コンパイル済みコードでの評価)— 信頼基盤はカーネルでなくコンパイラ + 評価器であり、runtime 側 `#guard`(同じくコンパイル時評価)と同一ベクタが二重凍結される。主張は「実装が公表ベクタを再現する」であり圧縮関数の数学的性質のカーネル証明ではない |
| B-T2 | 字句解析器 `ShellLex.tokenize` は全域である — 状態機械 `go` は `partial`・fuel なしの構造的再帰として型検査を通り(停止性はコンパイルごとに再証明され、§31.4-1 の純度ゲートが `partial` 混入を恒常排除)、その帰納構造の witness として出力有界性(成功時のトークン数 ≤ 入力文字数 + 1)とエラー空間の有限性(未閉クォート / ダングリングエスケープの 2 種のみ — LEAN_MIGRATION_PLAN.md §4.1 裁定 1 の網羅実装可能性)が成立する | `Proofs.Base.shellLex_output_bounded`(+ runtime 側 `Core.ShellLex.tokenize_length_le` — `go` が private のためモジュール内で証明・公開)+ `lexError_complete` | 全域性の主体は定義形そのもの(型検査 = 証明)。CPython `shlex` との意味論等価は証明対象ではなく差分ファザー(LEAN_MIGRATION_PLAN.md §4.2)と `#guard` 凍結が担う |
| W-T1 | 静的設定投影の忠実性(§8.1)— 配布バイト列(`StaticConfig.workspaceRendered` / `projectIndexSeedRendered`)を parse すると正確に定義値(`workspace` / `projectIndexSeed`)へ戻り(投影が定義を落とさない/歪めない)、`workspace` の invariants 4 面と schema_version の投影は宣言定義値そのものである | `Proofs.StaticConfig.workspace_rendered_parses_back` + `project_index_seed_rendered_parses_back`(roundtrip)+ `workspace_declares_*`(invariants 4 面 + schema_version の投影一致) | roundtrip の検証手段は `native_decide`(B-T1 と同じ信頼基盤)+ `LawfulBEq Value`(B-T3)による構造等値への持ち上げ。主張は「Lean 定義とその rendered 文字列の対応」であり、**ディスク上の配布ファイルとの一致**は D-008(sync テスト)と doctor(配備面の warn)が担う。これは「宣言値と投影が一致する」ことの定理であって「I-001〜I-004 が破れない」ことの定理ではない(後者は G 群の領分) |
| B-T3 | 安定直列化は決定的である — 実行層が値比較に使う手書き `Value.beq`(`==`、§31.2-35)は構造等値と正確に一致し(`LawfulBEq Value`: 健全性 + 反射性)、系として `==` 同値な値のあらゆる純粋直列化(render / renderCompact / renderAscii / …)は同一文字列を生む(progress signature の安定バイト列が偽の進捗を観測しないことの直列化側の半分) | `Proofs.Base.beq_sound` / `beq_refl`(nested inductive 上の相互構造帰納)+ `instance LawfulBEq Value` + `serialization_deterministic`(一般形)+ `render_deterministic` + `renderCompact_deterministic` | 直列化は純粋関数なので構造等値上の一致は参照透過性そのもの — 定理の非自明な内容は比較(`==`)と構造等値の一致に集約される。直列化形式の Python `json.dumps` とのバイト単位一致は証明対象ではなく `#guard` 凍結とシャドー検証が担う(LEAN_MIGRATION_PLAN.md §4.4) |
| M-T1 | S-T1 のモデル語彙への持ち上げ(三層構造の第一弾 — `docs/LEAN_PROOF_ARCHITECTURE_REVIEW.md` §7.2 の段階的経路): (1) **仕様充足性(モデル上)** — 抽象状態で gate 保持面のいずれかが unreadable なら、モデル判定は停止し reasons の先頭が `stateUnreadable`(I-021 の自然言語文と同型の可読形)、(2) **リファインメント** — gate 観測が unreadable の実行では、実装判定の抽象化はモデル判定 `Spec.verdict` に一致する、(3) **転移** — (1)+(2) の合成で S-T1 の主張がモデル語彙で実装に成立、(4) **R の自然性** — 抽象観測の unreadable は S-T1 の前提(`gateReadDiagnostics ≠ []`)とちょうど一致、(5) **語彙同期** — 抽象語彙 `StopReason` の正準列挙は D-005 の唯一の定義点 `Core.Stop.reasonPriority` の正確な持ち上げ(slug 往復律つき) | `Proofs.Spec.model_unreadable_stops`(モデル上の仕様充足)+ `shouldStop_matches_model`(リファインメント)+ `gate_unreadable_stops_lifted`(転移系)+ `absGate_any_iff`(R の自然性)+ `StopReason.canonical_matches_runtime` / `StopReason.ofSlug_slug`(語彙同期) | 前提は S-T1 と同一(`.ok` 経路)。リファインメント対応 R は gate 観測面(`absGate` — 7 面の診断有無)について関数的で、gate 可読性以外の停止信号は存在量化(`∃ rest`)に留まる — S-T2〜S-T6 の持ち上げ(後続弾)が観測を分解するとき関数化する。本定理は S-T1 を**置き換えない**: 直接証明(S-T1)が信頼連鎖の最小性を、本層が主張の可読形(仕様検証問題)を担う。Spec/リファインメント層は `proofs/` 専用であり実行層は不変(配布物への影響ゼロ)。`GateFace` は**本製品の** gate 保持面の列挙なので、R の自然性は本製品のドメイン軸の下でだけ言える(`Domain.gateLedgers` が面を足せば実装側の合流列だけが伸びる — §31.1 R-13 の分割線) |

### 31.4 実行層の構造規律(R-3 の機械検査可能な定義)

R-3「証明可能な構造」を、検査できる規約へ落としたものが以下の 5 項である。**1 は機械検査されている**(`ci/purity-gate.sh` — 共通実装の正本が配る 1 バイトが 3 リポジトリの同じパスに立つ)。層の分離(L0 が Over-Project の語彙を持たないこと)は正本側の `ci/layer-check.sh` が import 到達集合から機械的に判定する。残る 2〜5 はレビューの規律であり、破れは §31.3 の定理が通らない形で現れる。

**この規律の正本は本節である。** 以前は配布されない maintainer plane のアーカイブ(`docs/archive/LEAN_MIGRATION_PLAN.md §3.3`)にあり、配布物の中から参照だけが 40 箇所伸びていた — 読み手が辿れない先に生きた契約が置かれている状態だった。

1. **純度ゲート**: `Looper/{Core,Guard,State,Hook,Asl}` と `Looper/Domain{,.lean}`、および**製品ドメインパック** `<Pack>/Domain{,.lean}` 配下に `IO` / `partial` / `unsafe` / `extern` を含めない(字句検査)。再帰は構造的再帰または fuel 引数で全域にする。**ドメインパックを走査面から外すと穴が開く** — 検証 hook(`Looper.Domain` の関数フィールド)の実体は製品名前空間にあり、判定核へ直に入るからである。型が `IO` を禁じても `partial` / `unsafe` は通る。走査面は綴りではなく**ツリーの形**から導き(§31.1 R-13 の導出原則)、ドメインパックが 1 つも見つからない製品レイアウトは exit 2 で落ちる — 走査面が空のまま緑を報告するのは、検査していないことを検査済みと偽ることである。
2. **注入原則**: 外部状態(ファイル内容・環境変数・時刻・乱数・解決済みパス)はすべて `Env` / 入力レコードとして引数で渡す。例: `Guard.decide : GuardEnv → GuardInput → Option Decision`。ドメイン軸も同じ規律で入る(§31.1 R-13 — typeclass ではなく引数、既定値を置かない)。
3. **IO シェルは 3 手のみ**: 読む → 純粋関数を呼ぶ → 書く/出力する。IO 側(`Cli/**` / `Hook/**` の外殻)に分岐ロジックを持たせない。判定が IO 側へ漏れた分だけ、証明できる面が減る。
4. **パス解決は IO、判定は純粋**: `IO.FS.realPath` の結果を解決済みパスとして渡し、純粋コアは解決済みパス上の代数(`inside` / prefix 判定)だけを扱う。sandbox 健全性の証明は「解決が正しい」を信頼境界(公理)に置き、「解決済みパス上の判定が正しい」を定理にする — 責務を分けない限り、後者は前者の不確かさに巻き込まれて証明にならない。
5. **fail-open / fail-closed を型で区別**: 監査のような best-effort は、失敗を stderr へ落とすラッパで包む。gate 判定と canonical state の保護(I-021)は、読めない入力を**明示的な停止側コンストラクタ**へ写像する — **「読めない canonical file から Default を作る関数」を提供しない**。関数が存在すれば、いつか誰かが呼ぶ。どちらへ倒すかは面ごとに §31.5 が固定する。

### 31.5 エラーポリシー対応表

fail-open / fail-closed の割り当ては面ごとに固定されている(§31.4-5)。**新しい失敗経路を足すときは、実装より先にこの表へ行を足す** — 表に無い失敗を実装が黙って fail-open 側へ倒すのが、この種の穴の典型的な生まれ方である。

| 状況 | 挙動 |
|------|------|
| hook stdin の JSON パース失敗(pre-tool / post-tool) | 無意見 exit 0(fail-open。hook は判定を持たないので、壊れた入力で deny を捏造しない) |
| guard 内のパス解決失敗(OSError / NUL) | どのルールにもマッチしない(deny にも allow にも寄与しない) |
| gate ファイル読取不能(`should-stop`) | `state_unreadable` として停止(fail-closed) |
| 初期化済み state の gate ファイル欠損(`ensure`) | die。再構築を拒否する(I-021) |
| `pre-compact` の `context.json` 破損 | breadcrumb をスキップする。再構築しない(I-021) |
| 監査書き込み失敗(post-tool audit) | stderr のみ。判定に影響しない(best-effort) |
| pre-tool の監査書き込み / before-hash staging 失敗(§20.4-3/-5) | stderr のみ。判定に影響しない(best-effort) |
| `should-reset` の `context.json` 破損 | 空として評価(fail-open — reset はコスト最適化であり gate ではない。gate 面としての破損は `should-stop` が別途 fail-closed に捕捉する) |
| ESSENCE.md / essences/ が存在するのに読めない・不正 UTF-8 | ハードエラー exit 2(I-021 — 「読めない」を missing/placeholder と混同しない) |
| `state_predicate` で rc > 1 | シェル側が exit 2 でハード停止する(exit code 体系を変えない) |


---

## 32. Final Conclusion

Atlas Builder は、任意のソフトウェア開発における Claude Code 専用の自律的エージェンティックコーディングフレームワークである。

人間が継続的に管理する意思決定正本は `ESSENCE.md` である。Atlas Builder はそれを Spec、Todo、実装、検証、Reflection、Recommendation へ投影し、投影の歪みと証拠を残す。

最重要の原則は次である。

```text
Human writes one file.
Atlas Builder owns the projections.
Evidence closes Todo.
Stop when human judgment is required.
Resume records what the human decided.
```

v1.0 は、この価値を Claude Code で安全に運用するために、実行トポロジを固定する。

```text
Do not run Claude from the workspace root.
Run Over-Project Agent from ./.atlas-builder.
Never launch an embedded target agent in the live project.
Use only a project-defined isolated runner; otherwise stop for human evidence.
Keep Atlas Builder state explicit.
Treat agent runtime as high-risk where it exists.
```

Atlas Builder の核は、2 つの sibling root で制御設定と対象内容を切り分け、強制可能な実行境界を別に張ることに
ある(§6)。Over-Project Agent は `./.atlas-builder` から対象を外側から開発する。対象がエージェントを内包する
場合、その In-Project Agent は untrusted executable product content であり、Atlas Builder の下請けでも安全境界でも
ない。ライブ対象では起動せず、隔離 runner がある場合だけ挙動を検証する(§10)。

「対象を**開発する**エージェント」と「対象の上で**振る舞う**エージェント」を並列に切り分けたことで、
Lean 形式検証を Claude Code エージェントで自動化するプロジェクトや YouTube ライブ配信を自律
エージェント化するプロジェクト(対象がエージェントを内包する例)も、単純な ToDo iOS アプリのような
通常の Web / モバイル / CLI 開発プロジェクト(In-Project Agent は登場しない)も、同じ Essence-driven loop
と同じ停止/再開プロトコルで扱える。対象がエージェントを内包するか否かは事実の違いにすぎず、
共通なのはループと停止/再開の骨格である。

Atlas Builder の役割は、実装エージェントを単に走らせることではない。

人間の Essence を地図化し、歪みを記録し、航路を選び、証拠を残し、人間の判断が必要な地点で確実に止まることである。

[1]: https://code.claude.com/docs/en/settings "Claude Code settings - Claude Code Docs"
[2]: https://code.claude.com/docs/en/sub-agents "Create custom subagents - Claude Code Docs"
[4]: https://code.claude.com/docs/en/permissions "Configure permissions - Claude Code Docs"
[5]: https://code.claude.com/docs/en/hooks "Hooks reference - Claude Code Docs"
[6]: https://code.claude.com/docs/en/sandboxing "Sandboxing - Claude Code Docs"
[7]: https://code.claude.com/docs/en/model-config "Model configuration - Claude Code Docs"
[8]: https://code.claude.com/docs/en/env-vars "Environment variables - Claude Code Docs"
