# 知見

## 実行と検証
- `npm test` = `vitest run`(38 ファイル / 約 440 テスト)。`npm run build` = `tsc --noEmit && vite build`。`npm run typecheck` は tsc のみ。
- `bash scripts/ci.sh` は `npm ci` を含み作業木の node_modules/ を置き換えるので、作業木では実行しない。`mktemp -d` の複製(package.json / package-lock.json / tsconfig*.json / vite.config.ts / index.html / src / tests / scripts / docs)で `npm_config_cache=$TMPDIR/npm-cache bash scripts/ci.sh` を実行し、exit と dist/index.html の src/href(`./assets/` のみ)を確認する。相対参照検査は否定例(絶対パス・https)を合成ファイルで一度検出させると検査が空でないことを示せる。
- `npm --prefix <dir> ci` は EUSAGE で使えない。clean install は `cd <copy> && npm ci` の単独形にする。npm の既定キャッシュが書けない環境では `--cache "$TMPDIR/npm-cache"` か `npm_config_cache` を使う。
- `vitest run` は console.log を表示しない。挙動の推移(スロットごとの head / finalized / 判定)を見たいときは tests/ 配下に一時の *.test.ts を置き、node:fs で $TMPDIR にテキストを書き出して cat する。診断後は必ず削除する(npm test に拾われる)。
- 周回の環境ではブラウザ(Playwright Chromium)を起動できない前提。UI の検証は vitest + jsdom(ファイル先頭の `// @vitest-environment jsdom`、react-dom/client の createRoot + act、`dispatchEvent(new Event(..., { bubbles: true }))`)。実ブラウザ確認は人間の手元(`npm run dev`、`npm run build && node scripts/verify-ui.mjs`)。
- シェルの作業ディレクトリは呼び出し間で持ち越される。`cd` を含む複合コマンドの後は相対パスが変わるので、絶対パスを使う。

## テストの書き方
- React の制御コンポーネント(<input value onChange>)は jsdom で `el.value = 'x'` + input イベントでは onChange が発火しない。`Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, 'x')` の後に `new Event('input', { bubbles: true })` を dispatch する。<select> は `.value =` + 'change' で足りる。数値入力は aria-label で引く。
- 自動再生のテストは render 前に `vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })`、1 刻みを `await act(async () => { vi.advanceTimersByTime(PLAY_INTERVAL_MS) })`(定数は src/ui/useSimulation.ts から import)、afterEach で `vi.useRealTimers()`。
- jsdom はレイアウトを計算しない。「主役が面積の過半」「10 スロット収まる」は tests/ui/layout.test.ts が tokens.css / styles.css / App.tsx をテキストで読み、grid 契約と代表視口(1280×720 / 1440×900 / 1920×1080)の面積比を算術で確認する。実測は scripts/verify-ui.mjs(人間の手元)。
- 「パネル常駐の説明文なし」は tests/ui/prose.test.tsx が描画テキストノードを TreeWalker で走査し『。』を含むノードが無いことを見る。説明は Hint 部品の data-hint / aria-label にだけ持たせ、空状態・状態文は『。』を付けない短い読み出しにする。ツールチップは createPortal で body に fixed 配置(overflow: auto の操作盤に切り取られないため)。
- 設計トークン契約(tests/ui/designTokens.test.ts): styles.css に色リテラル・px 直書き・font-family 直書きを置かない。native の <select/input/button/details/textarea> は src/ui/components/ の統一部品を通す。
- 型一覧は import.meta.glob('../domain/model/*.ts', { query: '?raw', import: 'default', eager: true }) で本質的仕様のソースを逐語同梱し、抽出器(src/ui/typeGraph.ts)がコメント・文字列を遮蔽した影テキスト上で宣言を切り出す。新しい model ファイルは自動で追随する。tests/ui/typeGraph.test.ts が実装との一致を固定する。
- モジュール境界(sim → model の一方向、UI は src/domain の export のみ、index.ts が全ファイルを再輸出)は tests/domain/purity.test.ts がソース文字列で固定する。
- 識別子のソートは flavored 型(`number & { readonly __sort?: 'X' }`)。数値リテラルは各ソートに入り、ソート間の代入だけが型エラーになる。分離は `@ts-expect-error` の 1 行テストで固定する。
- 既存の DOM テストがクラス名で要素を探すので、同じクラスを別の場所に再利用すると querySelector の最初の一致が変わって壊れる。役割ごとにクラスを分ける。

## モデルの事実(攻撃ライブラリの設計で踏んだもの)
- 配送は単調で、送信者は自分のメッセージを常に見る。正直者自身の当該票は消せないので、攻撃対象ブロックの守りは最低 1 票残る(boost がそれを上回る必要がある)。
- 生成行動(戦略)は計算済みスロットに触れてはならない。MessageRef の公開前の名指し(送信者×スロット×種別)で次スロットの自分の提案を保留・選択配送する。最初の効果スロット ≤ 境界の行動は not-causal として破棄印を残す。
- propose-parent は能力範囲により攻撃者が提案するスロット(round-robin なら slot mod n が攻撃者)でしか成立しない。手動介入 probe で成立した構成が戦略化で破棄されうるので、generated の discarded 印を必ず確認する。
- エクイボケーション割引は View が相反 2 票を保持した瞬間に発火する局所規則。片側しか見ない View(バランシング)では発火しない。
- 即時スラッシング(merge)下では、エクイボケーションを含む戦略は自分の証拠の取り込み省略(omit-inclusion)を観測状態から動的に生成しないと自分をスラッシングする。
- 証拠は各バリデータの相異なる (source, target) の代表(最初の票)どうしだけを対にする。繰り返し票を対にすると正直者からも証拠が量産される。
- バウンシング(A05)は committee = エポック分割(1 エポック 1 投票)でのみ持続する。unrealized justification は起点の跳ねに作用しない。
- 攻撃目標の判定は『状態列の履歴 + 評価位置 → 根拠付き verdict』の純関数。増分状態を持たせない(決定性・巻き戻し・prefix 一貫性が自動で成り立つ)。根拠は表示文字列でなく判別共用体で持つ。
- チェックポイントは {epoch, block}。エポック境界スロットが空でも隣接判定はエポック番号で行う(ブロックの slot から推定すると finalize が 1 エポック遅れる)。
- 緩和策の簡約意味論が攻撃の成立要件と衝突するケース(割引の View 局所発火・即時スラッシング・スロット内順序独立)は、自律で意味論を変えず ask で人間に戻す(不変条件)。
