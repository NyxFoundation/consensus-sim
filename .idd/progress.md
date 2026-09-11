# 進捗台帳

<!-- 周回エージェントが保守する。IDEAL.md「実現する状態」の各条件を 1 行ずつ。
     状態は unmet / met / blocked の 3 値。met にできるのは証拠を記録した周回だけ。
     証拠列は、最初に現れる出典を idd が読む:
       cycle N: <コマンド> exit 0   周回 N(1 以上、現在の周回以下)で検証が通った
       human <at>: <要点>           台帳(journal.jsonl)の human resume 行 <at> を出典とする人間の確認
     IDEAL.md が変わったら(sha が下と違う)条件を投影し直し、消えた条件は行ごと消す。
     階層は 必須 / 望ましい。ID 列は IDEAL.md の番号を装飾なしで書く(`C1`。`**C1**` にしない)。
     列は 5 つ固定: | ID | 階層 | 条件 | 状態 | 証拠 |。idd はこの形で met / unmet を数え、完了を検算する。 -->

ideal_sha: 91605e6398bfbddf392a585b2fe893cd39f7db35487fe4f16b2a571a25ddea68

| ID | 階層 | 条件 | 状態 | 証拠 |
|----|------|------|------|------|
| C1 | 必須 | 最抽象モデルがドメイン層にあり、既定 4 体がスロット 0 から進み UI に反映される | met | cycle 1: npx vitest run tests/domain/blockTree.test.ts tests/domain/localView.test.ts tests/domain/simulation.test.ts tests/ui/appShell.test.tsx exit 0 |
| C2 | 必須 | バリデータ数 4〜10(既定 4)、カタカナ人名が UI 全域で表示される | met | cycle 1: npx vitest run tests/domain/validatorSet.test.ts tests/ui/appShell.test.tsx exit 0 |
| C3 | 必須 | 簡約プロトコル骨格(3 観測時点・fork choice・FFG・committee・proposer boost・タイブレーク) | met | cycle 1: npx vitest run tests/domain/checkpoint.test.ts tests/domain/forkChoice.test.ts tests/domain/protocolParams.test.ts tests/domain/simulation.test.ts exit 0 |
| C4 | 必須 | シミュレーションの完全決定性(同一シナリオで同一結果、短い実行は長い実行の prefix) | met | cycle 1: npx vitest run tests/domain/simulation.test.ts tests/domain/localView.test.ts tests/domain/intervention.test.ts tests/domain/combined.test.ts exit 0 |
| C5 | 必須 | 状態表のセル展開で各バリデータの View・head・チェーン状態・body を個別観測、差分強調 | met | cycle 1: npx vitest run tests/ui/stateTable.test.tsx tests/ui/interventions.test.tsx exit 0 |
| C6 | 必須 | UI は チェーン表示 / 型一覧 / 攻撃一覧 の 3 ページ、ネットワーク表示・全体表示は無い | met | cycle 1: npx vitest run tests/ui/appShell.test.tsx exit 0(grep で NetworkMode / GlobalMode は src・tests に無出力) |
| C7 | 必須 | 状態表(行 = バリデータ / 列 = スロット、動的項目選択・差分強調・約 10 列・歴代 F) | met | cycle 1: npx vitest run tests/ui/stateTable.test.tsx tests/ui/layout.test.ts tests/ui/appShell.test.tsx exit 0 |
| C8 | 必須 | 型一覧ページの独自レイアウト(ヘッダーのみ＋依存グラフ 8 割・フォーカス 2 割) | met | cycle 1: npx vitest run tests/ui/typesPage.test.tsx tests/ui/layout.test.ts exit 0(人間承認済みのレイアウトを本周回は変更していない) |
| C9 | 必須 | 分断・稼働状態・二重提案/二重投票・遅延/欠落・投票先指定・取り込み省略の介入 | met | cycle 1: npx vitest run tests/domain/intervention.test.ts tests/domain/steering.test.ts tests/ui/interventions.test.tsx tests/ui/steering.test.tsx exit 0 |
| C10 | 必須 | parent 指定(フォーク作成)とフォーク数 4 の上限、超える生成行動は破棄印 | met | cycle 1: npx vitest run tests/domain/forkCount.test.ts tests/domain/intervention.test.ts tests/domain/attack.test.ts tests/ui/interventions.test.tsx exit 0 |
| C11 | 必須 | 任意の過去スロットへの巻き戻しで全バリデータの状態が再現される | met | cycle 1: npx vitest run tests/domain/simulation.test.ts tests/ui/interventions.test.tsx exit 0 |
| C12 | 必須 | シナリオを localStorage に保存・再読込して同一結果が再現される | met | cycle 1: npx vitest run tests/domain/scenarioCodec.test.ts tests/ui/scenario.test.tsx tests/ui/attack.test.tsx exit 0 |
| C13 | 必須 | シナリオ操作が説明書なしで UI 上だけで発見・実行でき、状態変化が読み取れる | met | cycle 1: npx vitest run tests/ui/polish.test.tsx tests/ui/prose.test.tsx tests/ui/appShell.test.tsx exit 0 |
| C14 | 必須 | ドメイン層は UI 技術・DOM・I/O に依存せず、UI は src/domain の export だけを消費 | met | cycle 1: npx vitest run tests/domain/purity.test.ts exit 0 |
| C15 | 必須 | 型一覧に本質的仕様の型が依存グラフとして表示され、実装と一致する | met | cycle 1: npx vitest run tests/ui/typeGraph.test.ts tests/ui/typesPage.test.tsx exit 0 |
| C16 | 必須 | docs/INSPECTION.md に 3 観点＋改訂分の再実施の記録があり未解消項目が無い | met | cycle 1: npm test exit 0(docs/INSPECTION.md に観点 (1)(2)(3) の節と「再実施: 改訂で追加された必須対応事項の総点検」の節があり、未解消項目なし) |
| C17 | 必須 | 攻撃の形式体系(攻撃者集合の条件・攻撃目標・戦略の 3 つ組)がドメイン層にある | met | cycle 1: npx vitest run tests/domain/attack.test.ts tests/domain/attackGoal.test.ts exit 0 |
| C18 | 必須 | 攻撃者の能力範囲は公開・配送の 2 基底、範囲外の行動は破棄印で残る | met | cycle 1: npx vitest run tests/domain/attack.test.ts exit 0 |
| C19 | 必須 | 攻撃目標述語 4 種以上を神視点で毎スロット評価し、段ごとの判定推移を表示 | met | cycle 1: npx vitest run tests/domain/attackGoal.test.ts tests/ui/attack.test.tsx exit 0 |
| C20 | 必須 | 戦略はドメイン層の TypeScript(攻撃ライブラリ)で、UI に組み立て機能は無い | met | cycle 1: npx vitest run tests/domain/attackLibrary.test.ts tests/domain/purity.test.ts exit 0 |
| C21 | 必須 | 攻撃はシナリオの構成要素で手動介入と併用でき、生成行動・破棄が印付きで残る | met | cycle 1: npx vitest run tests/domain/attack.test.ts tests/domain/scenarioCodec.test.ts tests/ui/attack.test.tsx exit 0 |
| C22 | 必須 | 攻撃一覧ページ(体系の定義＋ライブラリ由来の表、行選択で既定実行構成を提案) | met | cycle 1: npx vitest run tests/ui/attacksPage.test.tsx tests/ui/attack.test.tsx exit 0 |
| C23 | 必須 | 攻撃ライブラリに 12 攻撃があり、既定実行構成の自動再生で達成/未達が観測できる | met | cycle 1: npx vitest run tests/domain/attackLibrary.test.ts tests/ui/autoplay.test.tsx exit 0 |
| C24 | 必須 | プロトコルパラメータとシードを個別設定でき、プリセットで一括切替・保存される | met | cycle 1: npx vitest run tests/domain/protocolParams.test.ts tests/domain/scenarioCodec.test.ts tests/ui/params.test.tsx exit 0 |
| C25 | 必須 | ステークは枝ごとのチェーン状態から導出され、UI から初期値を設定でき表示される | met | cycle 1: npx vitest run tests/domain/penalties.test.ts tests/domain/chainState.test.ts tests/ui/params.test.tsx exit 0 |
| C26 | 必須 | 罰則(スラッシング・inactivity leak)がプロトコルパラメータで状態表に反映される | met | cycle 1: npx vitest run tests/domain/penalties.test.ts tests/ui/params.test.tsx exit 0 |
| C27 | 必須 | 緩和策(fork choice 規則・割引・チェックポイント切替の 2 スイッチ)がパラメータ | met | cycle 1: npx vitest run tests/domain/mitigations.test.ts tests/domain/protocolParams.test.ts exit 0 |
| C28 | 必須 | ドメイン層が model / sim の 2 モジュールに分割され、依存は sim → model の一方向 | met | cycle 1: npx vitest run tests/domain/purity.test.ts tests/ui/typeGraph.test.ts exit 0 |
| C29 | 必須 | チェーン状態(枝ごとのステーク・justified・finalized の決定的導出と FFG リンク) | met | cycle 1: npx vitest run tests/domain/chainState.test.ts tests/domain/checkpoint.test.ts exit 0 |
| C30 | 必須 | UI の視覚・情報設計がデザイン方針「計器」に従う((a)〜(f) の機械検査) | met | cycle 1: npx vitest run tests/ui/designTokens.test.ts tests/ui/layout.test.ts tests/ui/prose.test.tsx tests/ui/theme.test.tsx exit 0(人間承認済みの見た目・情報設計を本周回は変更していない) |
| C31 | 必須 | 攻撃の自動再生(一定間隔の送り・一時停止/再開・達成または終了スロットで停止) | met | cycle 1: npx vitest run tests/ui/autoplay.test.tsx exit 0 |
| C32 | 必須 | 本質的仕様モジュールのコメントは日本語で、型一覧の全型が宣言とコメントを持つ | met | cycle 1: npx vitest run tests/domain/modelComments.test.ts tests/ui/typesPage.test.tsx exit 0 |
| C33 | 必須 | デプロイ契約(clean copy の scripts/ci.sh が exit 0、dist が相対参照で自己完結) | blocked | 周回 2 で再確認。作業木では ci.sh の手順 2〜4 に当たる検査がすべて通る(`npm test` exit 0 / `npm run build` exit 0 / `dist/index.html` の参照は `./assets/` 2 件、絶対・スキーム参照 0 件)。残るのは手順 1 の clean install で、複製先の `bash …/scripts/ci.sh` も一時ディレクトリへの `cd` も権限モード(don't ask)が拒否するため起動できない。人間の判断待ち(周回 2 の記録の問い) |
| C34 | 望ましい | 自動再生の速度調整と、攻撃を伴わないシナリオの自動再生・一時停止 | met | cycle 1: npx vitest run tests/ui/autoplay.test.tsx exit 0(「auto-play without an attack」「auto-play speed」の suite を含む) |
| C35 | 望ましい | 介入・シナリオ操作のキーボードショートカット | met | cycle 1: npx vitest run tests/ui/shortcuts.test.tsx exit 0 |
| C36 | 望ましい | シナリオに名前とメモを付けて保存でき、一覧に表示される | met | cycle 1: npx vitest run tests/ui/scenario.test.tsx exit 0(「scenario name and note」の suite を含む) |
