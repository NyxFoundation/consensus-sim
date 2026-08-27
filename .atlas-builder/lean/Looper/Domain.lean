import Looper.Core.Json

/-!
`Looper.Domain` — 製品(ドメインパック)が Looper へ注入する軸。

Over-Project ループの機構は製品によらず同一だが、いくつかの軸だけが製品ごとに
違う: 製品識別子、ESSENCE の正準見出し集合、投影台帳の追加面、ドメイン固有の
停止理由、対象書込み面のポリシー。**それらをデータとして 1 箇所に集め、Looper
本体は軸を参照するだけにする**のがこの構造体の役目である。

設計の固定点(抽出計画 D-5 / D-9 / D-10):

- **データ + 関数のレコードである。** 台帳スキーマの DSL は発明しない。
  ドメイン論理の実体は製品名前空間に置き、ここは呼び出し口だけを持つ。
- **typeclass ではなく引数として注入される。** `GuardEnv` と同じ様式であり、
  guard へは `GuardEnv.domain` フィールドで届く。既存の証明は env を量化して
  いるので、証明の書き直しが 1 回の事象に集約される。
- **綴りは 1 語幹から導出する(D-10)。** 表示名・ENV 接頭辞・制御ルート名・
  placeholder マーカー・commit trailer はすべて `tool` から機械的に導く。
  列挙は必ず取りこぼすので、フィールドを増やして列挙する方向へは進めない。
- **L0 と L1b はこのモジュールを import しない。** 純粋核(L0)と In-Project
  ループ(L1b)はドメインを知らない。`Looper/Domain.lean` は L1a にあり、
  `ci/layer-check.sh` の「L0 → L1a import 0」検査がこの不変条件を機械的に
  強制する。

フィールドは軸ごとに段階的に増える(投影台帳・停止理由・書込み面ポリシー・
ドメイン検証 hook)。**先に抽象を描かず、移植 → データ化 → 束ねるの順で
実関数の形から決める**(D-7)— 抽象の隙間で安全境界の段が消える事故(K-1)への
構造的対策である。
-/

namespace Looper

/-- 対象プロジェクトへの書込み面ポリシー(§11.6 / I-007)。

**この軸は決定木から段を消さない。** `implementation` は「read-only 段が
存在して、常に通過する」を意味する — 「そのドメインには段が無い」ではない。
抽象の隙間で安全境界の段が消える事故(抽出計画 K-1)への構造的対策であり、
段の有無ではなく段の**判定**をデータにするのが要点である。 -/
inductive WritePolicy where
  /-- 対象実装が Agent の作業面そのもの。read-only 段は常に通過する。 -/
  | implementation
  /-- 既定 read-only。`allowed` は対象 root 相対の既定許可 prefix 群
  (例 `["proofs"]`)。制御 state 面 `.<tool>` は機構として常に許可される
  (対象側の canonical state はどのドメインでも書き手が居る)。人間の
  `writable:` 宣言(§11.6-1)だけがこの既定を解除する。 -/
  | readOnlyExcept (allowed : List String)
  deriving BEq, Repr

/-! ## ドメイン検証 hook の入出力(形状層 / 意味層)

`state validate` は共通台帳(spec / todo / recommendations / blockers)の
検査を持つが、ドメインが足した台帳(`extraLedgers`)の検査は**ドメイン論理**
であり、製品名前空間に実体を置く。Looper 側は「読む → 呼ぶ → 束ねる」だけを
担い、hook はそのための入口である。

層は 2 つある。**形状層**(§20.1 系 — enum 語彙・必須フィールド・型・id
一意性・参照実在)は共通台帳の区画検査と同じ位置に挿さり、**意味層**は
形状が通った後の台帳間・台帳↔ESSENCE・台帳↔worktree の突合である。
節番号はドメイン側の META にしかないので、ここでは節を名指さない —
**共通実装がドメインの章番号を指すと、その章を持たない製品で参照が切れる**。

**ドメインは canonical state を再パースしない。** 読み取りと JSON 解釈は
Looper の IO シェルと純粋核が済ませ、hook には解釈済みの観測だけを渡す —
読み方が 2 系統に割れると、片方だけが fail-safe を持つ事故になる。 -/

/-- ドメイン台帳の検査に渡す観測。 -/
structure LedgerInputs where
  /-- ドメイン台帳(`extraLedgers` の各面)の parse 済み文書。キーは
  `<面>.json`(読めない・不在は空 object として現れる — 構造エラーは
  Looper 側の共通の構造検査が既に報告している)。 -/
  ledgers : List (String × Core.Json.Value)
  /-- 共通台帳 `spec.json` / `todo.json` の item 列(object のみ)。 -/
  specItems : List Core.Json.Value
  todoItems : List Core.Json.Value
  /-- ESSENCE の特別扱い節(`essenceTrustHeading?`)の active 内容行
  (空白正規化済み)。節を持たないドメインでは空。 -/
  essenceTrustItems : List String
  /-- 投影 hash が乖離中か(§20.2-7)。乖離中の不整合は個別 error ではなく
  単一の drift warning へ集約する、という共通の裁定に合わせるための入力。 -/
  drift : Bool
  /-- `observePaths` が要求した対象 root 相対パス → 作業ツリー生バイト列の
  `sha256:<hex>`(不在は none)。ドメインは自分でファイルを読まない。 -/
  observations : List (String × Option String)

/-- ドメイン台帳の意味検査の結果。 -/
structure LedgerIssues where
  errors : List String := []
  warnings : List String := []
  /-- 乖離中に §20.2-7 の**単一** drift warning へ足す注記(空 = 無し)。
  個別 error として出さないのは、再投影前の stale を人間へ N 行で見せない
  という共通の裁定に従うためである。 -/
  driftNote : String := ""

/-! ## ドメイン停止 gate / 完了封止 / 表示行の入出力

停止(§13.1)・完了(§19.3)・表示(§15.1)には、ドメイン固有の判定が加わり
うる。**理由の綴りは `domainStopReasons` が、発火の判定と文言は以下の hook が
持つ** — 前者は `Core.Stop.reasonPriority` の正準順を決めるデータであり、後者は
ドメイン論理だからである。

台帳検査 hook と同じ規律に従う: **ドメインは canonical state を再パースしない。**
読み取りと JSON 解釈は Looper が済ませ、hook には解釈済みの観測だけを渡す。 -/

/-- ドメインの gate 評価に渡す観測(停止 gate・完了封止・表示行が共有する)。 -/
structure GateInputs where
  /-- ドメイン台帳(`extraLedgers` の各面)の parse 済み文書。キーは
  `<面>.json`(読めない・不在は空 object として現れる — 読めなさは
  `gateLedgers` の面について Looper 側が `state_unreadable` へ写す)。 -/
  ledgers : List (String × Core.Json.Value)
  /-- 共通台帳 `spec.json` の item 列(object のみ)。 -/
  specItems : List Core.Json.Value
  /-- `context.json` の読取結果(読めなければ空 object)。 -/
  context : Core.Json.Value
  /-- `observePaths` が要求した対象 root 相対パス → 作業ツリー生バイト列の
  `sha256:<hex>`(不在は none)。ドメインは自分でファイルを読まない。 -/
  observations : List (String × Option String)

/-- 停止 gate の評価に渡す観測。 -/
structure StopGateInputs extends GateInputs where
  /-- 停止 message の締めに使う「その state で**受理される**形」への参照
  (§13.4-2)。open gate があるときの素の `just resume` は拒否されるので、
  ドメインが固定文言を綴ると、同じ message の中に受理される形と拒否される形が
  同居する — 参照は Looper 側が gate の有無から決めて渡す。 -/
  resumeHint : String

/-- 発火しているドメイン停止 gate 1 件。 -/
structure StopGate where
  /-- 停止理由の綴り(`domainStopReasons` の要素であること)。 -/
  reason : String
  /-- 停止 message の part。**理由 1 件につき 1 part** — 理由の列と part の列を
  別々に返す形にすると、片方だけを足した gate が「理由はあるが説明が無い」形で
  成立する(§13.4-2 は人間へ次手を示すことを停止の要件にしている)。 -/
  message : String

/-- ドメイン停止 gate の評価結果。 -/
structure StopGates where
  /-- 発火している gate(`domainStopReasons` の順)。reasons 配列への挿入点は
  `human_input_required` の直後、message part の挿入点は supervise
  authorization part の直後で固定である。**返り値の順序が出力の順序**である。 -/
  gates : List StopGate := []
  /-- payload へ足す面(挿入点は `supervise_authorizations` の直後)。
  **発火の有無によらず同じキー列を返すこと** — 機械読者(triage wrapper)は
  キーの存在を前提に照合するので、停止していない cycle でキーが消えると壊れる。 -/
  payload : List (String × Core.Json.Value) := []

/-- ドメインによる完了述語(§19.3)への寄与。 -/
structure CompletionGates where
  /-- must フェーズ完了の**追加条件**(共通条件との論理積)。台帳結線のように
  「must Spec が台帳で被覆されている」を要求するドメインが使う。 -/
  mustPhaseComplete : Bool := true
  /-- 完了そのものの封止。`true` の間 `full_complete` は成立しない — 承認済みの
  再検証のような「1 cycle も走らないまま COMPLETE へ素通りしてはならない」
  状態を表す。 -/
  sealsCompletion : Bool := false
  /-- payload へ足す面(挿入点は `resume_pending_cycle` の直後)。 -/
  payload : List (String × Core.Json.Value) := []

/-- `just status` のドメイン表示行に渡す観測。 -/
structure StatusLineInputs extends GateInputs where
  /-- must 境界(should フェーズの承認待ち)か。「境界でだけ出す行」の条件。 -/
  awaitingPhaseApproval : Bool

/-! ## resume の人間裁定チャネル(§13.3 のドメイン専有フラグ)

停止 gate の中には「**人間の裁定だけが動かせる**台帳 entry」を伴うものがある
(反例が確定した must finding のような)。裁定は resume 遷移の専有であり、
エージェントの投影経路は同じ集合を `projectionRefusal` が拒否する — 両者が
一致しないと、誰も動かせない entry(デッドロック)か、エージェントが自分の
発見を握りつぶす経路が生まれる。

**チャネルの記述は 1 つのレコードに閉じる。** CLI の綴り・受理集合・適用の
実体を Domain の別々のフィールドへ散らすと、「フラグはあるが適用が無い」
「受理集合はあるがフラグが無い」という半端な注入を型が許してしまう。
`Option Adjudication` 1 つにしたので、持つドメインは全部を持ち、持たない
ドメインは何も持たない。

台帳検査 hook と同じ規律に従う: **ドメインは canonical state を再パース
しない。** 読み取りと JSON 解釈は Looper が済ませ、hook には解釈済みの観測
だけを渡す。 -/

/-- 裁定の適用に渡す観測。 -/
structure AdjudicationInputs where
  /-- 裁定対象台帳(`Adjudication.ledger`)の parse 済み文書
  (読めない・不在は空 object として現れる)。 -/
  document : Core.Json.Value
  /-- 受理された (entry id, verdict) 列。`--steer-only` は何も解除しないと
  いう宣言なので、そのときここは空になる(§13.3-4''')。 -/
  verdicts : List (String × String)
  /-- 遷移の時刻(`resolved_at` のような刻印に使う)。 -/
  now : String
  /-- 人間が書いた note(裁定の根拠として台帳へ残す)。 -/
  note : String

/-- 裁定の適用結果。 -/
structure Adjudicated where
  /-- **実際に適用された** (id, verdict) 列。preflight(`selectionError?`)を
  迂回した呼び出しでも対象外の entry が動かないよう、ドメインは受理条件を
  ここで独立に再検査する — 遷移核の fail-closed である。 -/
  applied : List (String × String) := []
  /-- 書き換え後の台帳文書。**`applied` が空のとき Looper はこれを捨てる**
  ので、何も裁定しなかった resume は台帳ファイルに一切触れない。 -/
  document : Core.Json.Value := .obj []

/-- resume のドメイン専有フラグ(人間裁定チャネル)。 -/
structure Adjudication where
  /-- CLI フラグの綴り。引数は `<id>=<verdict>` の 1 語である。 -/
  flag : String
  /-- 裁定対象 entry の id 接頭辞(`F-001` の `F`)。台帳の id 規約は
  ドメインの語彙なので Looper 側では綴れない。引数形の誤り文言
  (`argForm`)も triage wrapper の形式検査もここから導く — **綴りを 2 箇所に
  置くと、フラグは受け付けるが wrapper が全部落とす形で静かに割れる**。 -/
  idPrefix : String
  /-- 裁定が書き換える台帳の canonical ファイル名。**`extraLedgers` の面で
  なければならない** — Looper が hook へ渡す文書はその集合からしか来ない。 -/
  ledger : String
  /-- 受理する verdict の語彙。**順序が誤り文言の順序**である。 -/
  verdicts : List String
  /-- 誤り文言が裁定対象集合を指す語(`<flag> targets only <targetNoun>: …`)。 -/
  targetNoun : String
  /-- reflection と stdout payload が報告する面のキー。**発火の有無によらず
  同じキーを出す** — 機械読者はキーの存在を前提に照合するので、裁定の無い
  cycle でキーが消えると壊れる。 -/
  payloadKey : String
  /-- **停止 payload** 側の面キー: triage wrapper(§13.6-5)は
  `stopGates.payload` のこの面と突き合わせ、載らない id を理由つきで落とす。

  **この面の id は `adjudicableIds` の部分集合でなければならない。** 超える
  と wrapper が engine の拒否する id を通し、その拒否は**対話セッションが
  終わった後**に落ちる — §13.6-5 が wrapper 側で照合する理由そのものである。
  逆向き(真の部分集合)は許される: 停止の引き金より広い集合を人間が裁定
  できてよい(裁定は resume を直に叩けば届く)。各製品の `#guard` が包含を
  凍結する。 -/
  stopPayloadKey : String
  /-- 人間裁定が動かせる台帳 entry の id 集合。

  **この集合は `projectionRefusal` が握りつぶしを拒否する集合と一致していな
  ければならない。** 一致しないと、エージェントも人間も動かせない entry が
  生まれ、誰も抜けられないデッドロックになる。両者は同じドメインパック内に
  置き、一致を機械検査で凍結すること。 -/
  adjudicableIds : List (String × Core.Json.Value) → List String
  /-- 裁定の適用(台帳の書き換え計画)。書くのは Looper の IO シェルである。 -/
  apply : AdjudicationInputs → Adjudicated

/-- cycle 承認マーカー(§14.1)。resume が「次の cycle だけ」の許可として
立て、成功 cycle の終端(`--run-status ok`)が下ろす面である。

**立てる側と下ろす側が 1 つの宣言から出る**のがこの型の要点である。綴りを
別々に持つと、立てたマーカーを誰も下ろさない(恒久封止)か、下ろす綴りだけが
違って毎 cycle 立ち続ける — どちらも軸を足した瞬間に静かに起きる。

**押し忘れが常に安全側になる**のがこの軸の性質である: 当該 cycle が許可の
目的を果たしていなければ、判定の根拠になった事実(台帳と作業ツリーの乖離など)が
残り、次の境界で再び停止する。立っている間の完了封止は
`completionGates.sealsCompletion` が受ける。 -/
structure CycleAuthorization where
  /-- context.json の面キー。**framework の context キーを名乗ってはならない**
  (§31.1 R-13 — 軸が `phase` を名乗ると cycle 終端が phase を消す)。 -/
  flag : String
  /-- これを立てる観測: **停止 payload のこの面が truthy であること**。面は
  ドメイン自身の `stopGates.payload` が出すものなので、raise の条件と
  停止理由の根拠が同じ 1 つの観測から出る。 -/
  raisedBy : String

/-- bootstrap が対象 root へ配る seed の 1 面(§26.1)。

`templates/project/` は製品所有のツリーであり、**そこから何を配るか**も
ドメインの宣言である(実装への投影は README と .gitignore を、証明への投影は
証明層 skeleton を配る)。運用スクリプトは軸を読むだけで、面の列挙を持たない
— 持たせると、シェルが製品ごとに割れて `scripts/**` のバイト同一が壊れる。 -/
structure BootstrapSeed where
  /-- `templates/project/` 相対のパス。対象 root の同じ相対位置へ置かれる。 -/
  path : String
  /-- PROJECT_TITLE 置換を通さず、バイトのまま配るか。**置換が要る散文の面
  だけが `false` を選ぶ** — 設定・ソース・ignore の類まで置換に晒すと、将来の
  テンプレート改稿で偶然の PROJECT_TITLE 一致が黙って書き換わる。 -/
  verbatim : Bool
  deriving BEq, Repr

/-- 製品(ドメインパック)が注入する軸。 -/
structure Domain where
  /-- ESSENCE.md の正準 H2 列(この綴り・この順序・全節必須、§2.1.1' /
  §13.1-15)。人間が書く唯一の正本の骨格そのものがドメインの語彙であり、
  Looper 側は「閉じた集合を強制する」機構だけを持つ。

  **`Core.Essence.essenceSuccessHeading`(§20.2-6 の受け入れ基準節)を必ず
  含むこと。** その 1 節だけは全ドメインで綴りが一致しており、Looper が
  共通の定数として持っている — 列から落ちると成功条件の抽出が黙って空に
  なる(構造検査は落ちるので停止はするが、原因が遠い)。 -/
  essenceHeadings : List String
  /-- 人間がスコープの柵(won't)を宣言する節の見出し(§2.1.2)。
  `essenceHeadings` の要素でなければならない。 -/
  essenceWontHeading : String
  /-- ドメインが**特別扱い**する節の見出し(無ければ `none`)。「証明せず
  信頼するもの」の宣言面のように、ドメイン検証がその節の内容行を錨として
  使う節を指す。`some h` のとき `h` は `essenceHeadings` の要素である。 -/
  essenceTrustHeading? : Option String
  /-- 製品識別子の 1 語幹(D-10)。fixture の `"looper"` を例に取ると、表示名
  `Looper`・ENV 接頭辞 `LOOPER`・制御ルート名 `.looper`・placeholder マーカー・
  commit trailer はすべてここから導出される。**このファイルは製品綴りを
  1 つも含まない** — 含めた瞬間、配布物は製品ごとに別バイトになるほかない。
  綴りの不在は `ci/sync-looper.sh` の payload 検査が、配布先の制御ルート名から
  禁止綴りを導いて機械的に見る(列挙ではなく導出であり、製品が増えても腐らない)。 -/
  tool : String
  /-- 投影台帳の**追加**面(§8.2)。共通 4 面 `spec` / `todo` /
  `recommendations` / `blockers` は全ドメインが持つので、ここには差分だけを
  置く。挿入位置は `todo` の直後で固定である — progress 署名(§13.1-7)は
  この順で直列化されるので、**順序を変えると署名のバイト列が変わり、
  「意味的進捗なし」の判定が過去の記録と接続しなくなる**。 -/
  extraLedgers : List String
  /-- ドメイン固有の停止理由(§13.1)。`Core.Stop.reasonPriority` の
  **`human_input_required` の直後**に挿さる(§13.4 の優先順)— 人間への
  ハンドオフ系より後、完了・予算・環境系より先という位置づけである。
  Run-Status(§24.3)の綴りもここから決まる。 -/
  domainStopReasons : List String
  /-- 対象書込み面ポリシー(§11.6 / I-007)。`Guard.Decide` の read-only 段が
  消費する。 -/
  writePolicy : WritePolicy
  /-- 制御ルートの `.agent/state` 面のうち、配布 settings の **sandbox
  filesystem denyWrite**(OS の床)で塞ぐパス(制御ルート相対、§16.1)。

  **この軸は統合できない**(抽出計画 D-18)。全面 deny は `loop.drain` /
  `loop.status.json` の偽造不能性を担保する一方、sandbox 下の Bash から走る
  `state ensure` の project_index 登録まで殺すドメインもある。どちらの理由も
  実在し、どちらも他方では成立しない — R-7 の「判定不能なら分岐のまま残す」を
  データとして表現した形である。 -/
  controlStateDenyWrite : List String
  /-- 同じ `.agent/state` 面の **permission 層** `Edit` deny ルール(制御ルート
  相対の glob)。OS の床(`controlStateDenyWrite`)より細かく列挙できるのは、
  permission 層が個別ファイル単位で書けるからである。 -/
  controlStateDenyEdit : List String
  /-- 既定で信頼する Lake パッケージの**追加**集合(§11.2)。Reservoir の定番は
  Looper 側が共通に持ち、ここにはドメイン固有の追加分だけを置く。

  **allow 拡大方向なので統合しない**(R-5 / 抽出計画 D-19)。片方に「意味検証
  支援は中核価値」のような裁定があっても、他方にその根拠は無い — 統合すると
  根拠の無い側の床が理由なく下がる。 -/
  trustedLeanExtra : List String
  /-- `extraLedgers` のうち **gate 保持面**(§13.5、I-021)に加わる面。
  ensure の再構築拒否と should-stop の `state_unreadable` が同じ集合を見る。
  台帳のすべてが gate 面とは限らない — 破損でループを止める理由が無い面
  (知見台帳のような)はここに載せない。 -/
  gateLedgers : List String
  /-- evidence(§22)の `type` のうち、**台帳 entry の名指し**(`ledger`)を
  必須で持つもの。転記フィールドの台帳整合は `ledgerMeaningIssues` が見る。 -/
  evidenceLedgerTypes : List String
  /-- cycle 承認マーカー(§14.1)。resume が立て、成功 cycle の終端が下ろす。
  **立てる側と下ろす側は同じ 1 つの宣言から綴りを取る**(`CycleAuthorization`)。 -/
  cycleAuthorizations : List CycleAuthorization
  /-- ドメイン台帳の**形状**検査(§20.1 系: enum 語彙・必須フィールド・
  list/object 型・id 一意性・参照実在)。共通台帳の区画検査と同じ層・同じ
  位置に挿さるので、返り値の順序がそのまま errors 配列の順序になる。 -/
  ledgerShapeErrors : LedgerInputs → List String
  /-- ドメイン台帳の**意味**検査。形状層が通った後の、台帳間・
  台帳↔ESSENCE・台帳↔worktree の突合である。 -/
  ledgerMeaningIssues : LedgerInputs → LedgerIssues
  /-- 作業ツリーの**生バイトを見たい**対象 root 相対パス(重複可、呼び出し側が
  一意化する)。IO シェルがこれを hash して `LedgerInputs.observations` として
  返す — **純粋関数がパスを決め、IO シェルが読む**の分業であり、ドメイン論理を
  IO へ漏らさないための形である。 -/
  observePaths : List (String × Core.Json.Value) → List String
  /-- `apply-projection` の**最初の書込み前**の拒否(§8.2)。引数は
  (現在のドメイン台帳, bundle が差し替えようとしているドメイン台帳)で、
  どちらも `<面>.json` → 文書。`none` = 受理。

  共通の受理条件(schema・投影 hash・validate 全体)を通っても、ドメインには
  「エージェントが自分の発見を握りつぶす経路」のような**書込み前に閉じるべき
  扉**がありうる。検査ではなく拒否なので、validate とは別の口を持つ。 -/
  projectionRefusal : List (String × Core.Json.Value) → List (String × Core.Json.Value) →
    Option String
  /-- ドメイン固有の停止 gate(§13.1)の評価。返り値の gate 列は
  `domainStopReasons` の順であること — reasons 配列の正準順(§13.4)は
  `Core.Stop.reasonPriority` が軸から作るので、順序が食い違うと
  「停止理由の順序が優先順である」という契約が破れる。 -/
  stopGates : StopGateInputs → StopGates
  /-- ドメインによる完了述語への寄与(§19.3)。 -/
  completionGates : GateInputs → CompletionGates
  /-- `just status` のドメイン表示行(§15.1)。**行の位置は Gate 行の直後・
  診断行の前で固定**であり、返り値の順序がそのまま表示順である。 -/
  statusLines : StatusLineInputs → List String
  /-- resume のドメイン専有フラグ(人間裁定チャネル、§13.3)。チャネルを
  持たないドメインは `none` — CLI がフラグを綴らず、遷移核も裁定を受理しない。 -/
  resumeAdjudication? : Option Adjudication
  /-- bootstrap が `templates/project/` から対象 root へ配る面(§26.1)。
  **順序が配布順である。** 運用スクリプトはこの列を読むだけで、面の名前を
  1 つも持たない — 持たせると `scripts/**` が製品ごとに割れる。 -/
  bootstrapSeeds : List BootstrapSeed

/-- 誤り文言が示す引数形(`<F-id>=<verdict>`)。**`idPrefix` からの導出**で
あり、綴りの正本は 1 つである。 -/
def Adjudication.argForm (a : Adjudication) : String :=
  "<" ++ a.idPrefix ++ "-id>=<verdict>"

/-- 運用スクリプトの綴り(`scripts/<stem>.sh`)。**ドメインに依らない** —
中立名化(抽出計画 D-12)で製品接頭辞が消え、綴りは 3 リポジトリで 1 つに
なった。`scripts/` を冠したパス形なのは、それが唯一**実際に動く**呼び出し形
だからである: 運用スクリプトは `assert_control_root` で CWD が CONTROL_ROOT
であることを要求するので、`cd scripts && bash resume.sh` は guard に一致する
前にスクリプト自身が exit 2 で落ちる。素の basename で照合すると、対象
プロジェクトのありふれた `init.sh` / `status.sh` まで human-only として拒否
してしまう(過剰 deny は fail-closed だが、対象での作業を理由なく止める)。 -/
def scriptPath (stem : String) : String := "scripts/" ++ stem ++ ".sh"

namespace Domain

/-- 成功 cycle の終端が下ろす context の承認マーカーの綴り
(`cycleAuthorizations` の `flag` 列)。**下ろす側はこの導出だけを見る** —
立てる側(resume)と同じ 1 つの宣言から出るので、両者が別の綴りを持つ状態を
構造的に作れない。 -/
def cycleAuthorizationFlags (d : Domain) : List String :=
  d.cycleAuthorizations.map (·.flag)

/-- 制御ルート/対象側 state ルートのディレクトリ名(`.<tool>`)。CONTROL_ROOT の
basename であり、対象側にも同名の state ルートが置かれる(§5.1 / §8.1)。 -/
def controlDirName (d : Domain) : String := "." ++ d.tool

/-- 人間やエージェントが**打つコマンド**の綴り(D-17)。バイナリは PATH に
無く `CONTROL_ROOT/bin/` 固定であり、配布 settings の allow 規則も
`Bash(bin/<tool> …)` の文字列一致なので、この形が正である。 -/
def binCommand (d : Domain) : String := "bin/" ++ d.tool

/-- ENV 接頭辞(`sample-tool` → `SAMPLE_TOOL`)。ハイフンは `_` へ、
英小文字は大文字へ。 -/
def envPrefix (d : Domain) : String :=
  String.ofList (d.tool.toList.map fun c =>
    if c == '-' then '_' else c.toUpper)

/-- snake 綴り(`sample-tool` → `sample_tool`)。settings の
`_<snake>_profile` キーなど、識別子として埋め込む面が使う。 -/
def snake (d : Domain) : String :=
  String.ofList (d.tool.toList.map fun c => if c == '-' then '_' else c)

/-- 表示名(`sample-tool` → `Sample Tool`)。ハイフン区切りの各語を
語頭大文字化して空白で連結する。 -/
def displayName (d : Domain) : String :=
  String.intercalate " " ((d.tool.splitOn "-").map fun w =>
    match w.toList with
    | [] => ""
    | c :: rest => String.ofList (c.toUpper :: rest))

/-- ループ実行体の名乗り(`<tool>-loop`)。framework が実体化した gate
Recommendation の `raised_by`(§21.5-1)と、その詐称を弾く照合(§13.3-4')が
共有する 1 つの綴りである。**かつてスクリプト名(`<tool>-loop.sh`)と字面が
重なっていたが、別の軸である**: こちらは台帳へ永続化される実行体の識別子で
あり、スクリプトのファイル名が中立化された(`scriptPath "loop"`)いまも
製品ごとに違う。字面の一致で 1 つにまとめていれば、中立名化で割れていた。 -/
def loopActor (d : Domain) : String := d.tool ++ "-loop"

/-- テンプレート未編集マーカー(§13.1-8)。`sample-tool` →
`SAMPLE-TOOL-TEMPLATE-PLACEHOLDER`。ハイフンは `envPrefix` と違い保存する —
これは識別子ではなく配布テンプレート本文に埋め込まれる見出し語である。 -/
def placeholderMarker (d : Domain) : String :=
  String.ofList (d.tool.toList.map Char.toUpper) ++ "-TEMPLATE-PLACEHOLDER"

/-- `rel`(対象 root 相対のパス)が**既定の**書込み許可面か(§11.6)。
`writable:` 宣言による解除は guard 側が別に足す — ここはドメインの既定だけを
答える。 -/
def allowsWriteRel (d : Domain) (rel : String) : Bool :=
  match d.writePolicy with
  | .implementation => true
  | .readOnlyExcept allowed =>
    (allowed ++ ["." ++ d.tool]).any fun p =>
      rel == p || rel.startsWith (p ++ "/")

/-- 投影台帳の全面(共通 4 面 + `extraLedgers`)。順序は
`spec → todo → 追加 → recommendations → blockers`。 -/
def projectionLedgers (d : Domain) : List String :=
  ["spec", "todo"] ++ d.extraLedgers ++ ["recommendations", "blockers"]

/-- 投影台帳の canonical ファイル名(`projectionLedgers` に `.json` を付けた
もの)。deny 面(`Core.Classify.isDenyPath`)・`state apply-projection` の
受理集合・progress 署名の直列化順がこれを共有する。 -/
def projectionFiles (d : Domain) : List String :=
  d.projectionLedgers.map (· ++ ".json")

/-- Looper 単体の検査用ドメイン(抽出計画 D-10)。`#guard` と Looper の単体
テストはこれで駆動する。**製品綴りの凍結は各製品の黒箱 conformance スイートが
担う** — fixture へ寄せて `#guard` を弱めるときは、当該 `#guard` が凍結して
いた製品出力を conformance 側が覆っていることを先に確認すること(K-7)。

**これは同時に、標準配布 `looper init` が出荷する参照ドメインである**
(抽出計画 Phase 12)。任意軸をすべて空にしたまま**実運用に耐える**こと —
束縛して 1 cycle 回るところまで — が要件であり、`bootstrapSeeds` が
`.<tool>/.gitignore` を含むのはそのためである(対象の制御 state 面に
`tmp/` の ignore が無いと、鮮度マーカーが I-014 の clean worktree 検査を
毎 cycle 汚す)。軸が空でも成立することの黒箱検査は、正本リポジトリの
`just test` が本ドメインを駆動して行う。 -/
def fixture : Domain :=
  { tool := "looper", extraLedgers := [], domainStopReasons := []
    writePolicy := .implementation
    essenceHeadings := ["モチベーション", "思想", "成功条件", "対象外"]
    essenceWontHeading := "対象外"
    essenceTrustHeading? := none
    controlStateDenyWrite := [".agent/state"]
    controlStateDenyEdit := [".agent/state/**"]
    trustedLeanExtra := []
    gateLedgers := [], evidenceLedgerTypes := []
    cycleAuthorizations := []
    ledgerShapeErrors := fun _ => [], ledgerMeaningIssues := fun _ => {}
    observePaths := fun _ => [], projectionRefusal := fun _ _ => none
    stopGates := fun _ => {}, completionGates := fun _ => {}
    statusLines := fun _ => [], resumeAdjudication? := none
    bootstrapSeeds :=
      [{ path := "ESSENCE.md", verbatim := false },
       { path := ".looper/.gitignore", verbatim := true }] }

/-- 任意軸をすべて**非空**にした fixture。`fixture` だけでは「軸が空の
ドメイン」しか検査できず、パラメータ化が効いていることを凍結できない —
両方あって初めて「持つドメインでは効き、持たないドメインでは効かない」の
2 方向が言える。綴り(`"extra"` / `"domain_stop"`)に意味は無く、製品の実
集合の凍結は各製品の黒箱 conformance スイートが担う(K-7)。 -/
def fixtureRich : Domain :=
  { fixture with
    extraLedgers := ["extra"]
    domainStopReasons := ["domain_stop"]
    writePolicy := .readOnlyExcept ["open"]
    essenceHeadings := ["モチベーション", "思想", "成功条件", "信頼面", "対象外"]
    essenceTrustHeading? := some "信頼面"
    controlStateDenyWrite := [".agent/state/ledger.jsonl"]
    controlStateDenyEdit := [".agent/state/ledger.jsonl", ".agent/state/audit.jsonl"]
    trustedLeanExtra := ["extra-lean"]
    gateLedgers := ["extra"]
    evidenceLedgerTypes := ["extra"]
    -- 立てる観測は自分の stop payload の面(`domain_gate_ledgers`)である。
    -- 立てる側と下ろす側が 1 つの宣言から出ることを fixture でも表現する。
    cycleAuthorizations :=
      [{ flag := "domain_authorized", raisedBy := "domain_gate_ledgers" }]
    -- 検査の**中身**は製品が持つ。fixture の hook は「軸が消費点まで届いて
    -- いる」ことだけを凍結できればよいので、入力を素通しした印を返す。
    -- 発火条件は context の印にする — 停止・完了・cycle 終端の 3 消費点が
    -- 同じ 1 つの入力で駆動できて、配管の切れ目が `#guard` で見分けられる。
    stopGates := fun i =>
      { gates := if ((i.context.get? "domain_gate").getD .null).truthy then
          [{ reason := "domain_stop"
             message := s!"domain gate ({i.ledgers.length} ledger(s), "
               ++ s!"{i.observations.length} observation(s)); run " ++ i.resumeHint }]
        else []
        payload := [("domain_gate_ledgers", .arr (i.ledgers.map fun l => .str l.1))] }
    completionGates := fun i =>
      { mustPhaseComplete := !((i.context.get? "domain_incomplete").getD .null).truthy
        sealsCompletion := ((i.context.get? "domain_authorized").getD .null).truthy
        payload := [("domain_specs", .num (Int.ofNat i.specItems.length) 0)] }
    statusLines := fun i =>
      [s!"Domain       : {i.ledgers.length} ledger(s)"]
        ++ (if i.awaitingPhaseApproval then ["Domain       : boundary review"] else [])
    resumeAdjudication? := some {
      flag := "--resolve-extra"
      idPrefix := "X"
      ledger := "extra.json"
      verdicts := ["yes", "no"]
      targetNoun := "open extra entries"
      payloadKey := "resolved_extras"
      stopPayloadKey := "domain_gate_ledgers"
      adjudicableIds := fun ledgers => ledgers.map (·.1)
      -- 適用の実体は製品が持つ。fixture は「裁定が消費点まで届いている」ことと
      -- 「applied が空なら台帳に触れない」ことを凍結できればよい。
      apply := fun i =>
        { applied := i.verdicts
          document := i.document.set "resolution" (.str i.note) } }
    ledgerShapeErrors := fun i => i.ledgers.map fun l => s!"shape:{l.1}"
    ledgerMeaningIssues := fun i =>
      { errors := [s!"meaning:{i.observations.length}"]
        warnings := [s!"trust:{i.essenceTrustItems.length}"]
        driftNote := if i.drift then " drift-note." else "" }
    observePaths := fun ledgers => ledgers.map (·.1)
    projectionRefusal := fun _ prospective =>
      if prospective.isEmpty then none else some "fixture refuses"
    bootstrapSeeds :=
      [{ path := "ESSENCE.md", verbatim := false },
       { path := "extra/README.md", verbatim := false },
       { path := ".looper/.gitignore", verbatim := true }] }

-- ESSENCE 見出し軸の内部整合(特別扱い見出しは正準列の要素である)。
-- 成功条件見出しとの整合は `Core.Essence` 側(定数の所在がそちらなので)。
#guard Domain.fixture.essenceHeadings.contains Domain.fixture.essenceWontHeading
#guard Domain.fixtureRich.essenceHeadings.contains
  Domain.fixtureRich.essenceWontHeading
#guard match Domain.fixtureRich.essenceTrustHeading? with
  | some h => Domain.fixtureRich.essenceHeadings.contains h
  | none => true
#guard Domain.fixture.essenceTrustHeading? == none

-- 停止 gate hook が名乗る理由は `domainStopReasons` の綴りに限る(reasons 配列の
-- 正準順は `Core.Stop.reasonPriority` が同じ軸から作るので、食い違うと「順序が
-- 優先順である」契約が破れる)。製品の実集合は黒箱 conformance が覆う(K-7)。
private def gateProbe (fire : Bool) : StopGateInputs :=
  { ledgers := [], specItems := [], observations := [], resumeHint := "H",
    context := .obj [("domain_gate", .bool fire)] }
#guard ((Domain.fixtureRich.stopGates (gateProbe true)).gates.map (·.reason)).all
  (Domain.fixtureRich.domainStopReasons.contains ·)
#guard !(Domain.fixtureRich.stopGates (gateProbe true)).gates.isEmpty
#guard (Domain.fixtureRich.stopGates (gateProbe false)).gates.isEmpty
#guard (Domain.fixture.stopGates (gateProbe true)).gates.isEmpty

-- cycle 承認マーカーを立てる観測は、**そのドメイン自身の stop payload の面**で
-- なければならない。誰も出さない面を名乗ると、マーカーは永久に立たず、それを
-- 前提にした停止(再検証待ちのような)が恒久デッドロックになる。payload のキー列は
-- 入力に依らない契約なので probe 1 本で凍結できる。
#guard Domain.fixtureRich.cycleAuthorizations.all fun a =>
  ((Domain.fixtureRich.stopGates (gateProbe true)).payload.map (·.1)).contains a.raisedBy
#guard !Domain.fixtureRich.cycleAuthorizations.isEmpty
#guard Domain.fixture.cycleAuthorizations.isEmpty
-- §31.1 R-13: 軸は framework の context キーを名乗れない(名乗ると成功 cycle の
-- 終端が phase を消す)。証明側は前提として要求し、ここは fixture で凍結する。
#guard !Domain.fixtureRich.cycleAuthorizationFlags.contains "phase"

-- 人間裁定チャネルの裁定先は、そのドメインが宣言した台帳面に限る。Looper が
-- hook へ渡す文書は `extraLedgers` の集合からしか来ないので、他の面を名乗った
-- チャネルは「常に空文書を裁定する」= 何も動かせない形で静かに成立する。
#guard match Domain.fixtureRich.resumeAdjudication? with
  | some a => (Domain.fixtureRich.extraLedgers.map (· ++ ".json")).contains a.ledger
  | none => true
#guard match Domain.fixture.resumeAdjudication? with
  | some a => (Domain.fixture.extraLedgers.map (· ++ ".json")).contains a.ledger
  | none => true
#guard Domain.fixture.resumeAdjudication?.isNone
#guard Domain.fixtureRich.resumeAdjudication?.isSome
-- 引数形は id 接頭辞からの導出であり、綴りの正本は 1 つである。
#guard match Domain.fixtureRich.resumeAdjudication? with
  | some a => a.argForm == "<X-id>=<verdict>"
  | none => false
-- triage wrapper(§13.6-5)が突き合わせる停止 payload の面は、そのドメイン
-- 自身の `stopGates.payload` が出す面でなければならない。出さない面を名乗ると
-- wrapper は**すべての裁定を落とす**(人間が動かせない形で静かに成立する)。
#guard match Domain.fixtureRich.resumeAdjudication? with
  | some a =>
    ((Domain.fixtureRich.stopGates (gateProbe true)).payload.map (·.1)).contains
      a.stopPayloadKey
  | none => false

-- bootstrap の seed 面はドメインの宣言である(§26.1)。空の宣言は「対象へ
-- 何も配らない」= Essence すら置かない bootstrap を意味するので、どの
-- ドメインも最低限 ESSENCE.md を配る。
#guard Domain.fixture.bootstrapSeeds.any (·.path == "ESSENCE.md")
#guard Domain.fixtureRich.bootstrapSeeds.any (·.path == "ESSENCE.md")
-- 制御 state 面の ignore を配るドメインは、自分の制御ディレクトリ名で配る。
#guard Domain.fixture.bootstrapSeeds.all fun sd =>
  !(sd.path.startsWith ".") || sd.path.startsWith Domain.fixture.controlDirName
#guard Domain.fixtureRich.bootstrapSeeds.all fun sd =>
  !(sd.path.startsWith ".") || sd.path.startsWith Domain.fixtureRich.controlDirName
-- 参照ドメインは対象の制御 state 面の ignore を配る(§26.1)。これが無いと
-- 鮮度マーカー(`PROJECT_STATE_ROOT/tmp/`)が I-014 の clean worktree 検査を
-- 毎 cycle 汚し、束縛直後の対象で 1 cycle も回らない。
#guard Domain.fixture.bootstrapSeeds.any fun sd =>
  sd.verbatim && sd.path == Domain.fixture.controlDirName ++ "/.gitignore"

-- 綴り導出(D-10)は 1 語幹から閉じる。列挙は必ず取りこぼすので、
-- フィールドを増やす方向へは進めない。
#guard Domain.fixture.controlDirName == ".looper"
#guard Domain.fixture.binCommand == "bin/looper"
#guard Domain.fixture.envPrefix == "LOOPER"
#guard Domain.fixture.snake == "looper"
#guard Domain.fixture.displayName == "Looper"
#guard Domain.fixture.loopActor == "looper-loop"
#guard Domain.fixture.placeholderMarker == "LOOPER-TEMPLATE-PLACEHOLDER"
-- 複合語幹(実製品の形)でも同じ規則で閉じる
#guard ({ Domain.fixture with tool := "sample-tool" } : Domain).envPrefix
  == "SAMPLE_TOOL"
#guard ({ Domain.fixture with tool := "sample-tool" } : Domain).snake
  == "sample_tool"
#guard ({ Domain.fixture with tool := "sample-tool" } : Domain).displayName
  == "Sample Tool"
#guard ({ Domain.fixture with tool := "sample-tool" } : Domain).controlDirName
  == ".sample-tool"
#guard ({ Domain.fixture with tool := "sample-tool" } : Domain).loopActor
  == "sample-tool-loop"
#guard ({ Domain.fixture with tool := "sample-tool" } : Domain).placeholderMarker
  == "SAMPLE-TOOL-TEMPLATE-PLACEHOLDER"

end Domain

end Looper
