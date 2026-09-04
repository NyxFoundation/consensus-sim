# Recipes — 対象プロジェクトへ instantiate できる具体的実装の型

(用語注意: `just` がサブコマンドを "recipe" と呼ぶのとは別概念である。本書のレシピは
Atlas Builder の概念で、META.md §29 が正本である。)

レシピは、`ESSENCE.md` から機械可読ポインタで指定できる**具体的実装のテンプレート**である
(META.md §29)。自然言語レベルの仕様ではなく、動くスクリプト・設定・ハーネスの一式であり、
対象プロダクトがそのまま内包できる形で配布される。

## 原本と instance

- **原本**はこのディレクトリ(`CONTROL_ROOT/recipes/<name>/`)にのみ存在する。
  immutable control-plane surface の一部であり、bound Agent session からの書込みは常に
  deny される。原本更新は source repository の maintainer plane で行う(META.md §11.3)。
- **instance** は、Essence のポインタに従って Over-Project Agent が対象へ**生成した最終実装**である。
  生成は vendoring — 生成後のファイルは対象の通常の実装ファイルであり、対象の所有物として
  自由に進化する。由来は `recipe.lock.json`(レシピ名 + バージョン + source hash)だけが記録する。
  原本の更新が instance に自動追従することはない。原本更新への追従(再 instantiation)は
  新しい High-Risk Todo であり、人間の承認を要する(META.md §29.3-4)。

## ESSENCE.md からの指定(ポインタ記法)

`ESSENCE.md` の任意の行(推奨: 前提事項の節)に、次の 1 行を書く。

```text
recipe: <name>@<major>
```

例: `recipe: agentic-state-loop@2`

`atlas-builder state validate` はポインタと instance(`recipe.lock.json`)の突き合わせを warning で可視化する
(未生成 / 未知レシピ / メジャーバージョン不一致 / 原本 hash の乖離 / ポインタなしの instance —
採用が Essence に記録されていない、META.md §29.4)。停止ゲートにはしない —
未生成は投影が High-Risk Todo として自然に拾い、生成は人間承認(ask)を通る。

## ディレクトリ規約

```text
recipes/
├── README.md            # この文書
└── <name>/
    ├── recipe.json      # マニフェスト: バージョン、配置規約、パラメータ宣言、生成後チェック
    ├── README.md        # レシピの説明と instantiation 手順
    └── files/           # 対象へ写す実装ファイル群(置換トークン・パラメータ面を含む)
```

原本の決定的 source hash(lock の `source_sha256` の定義)は
`bin/atlas-builder recipe hash <name>` が計算する。

`recipe.json` の `parameters` は 2 種に分かれる:
`kind: "substitution"`(トークンの機械的置換)と `kind: "authored"`(Essence から Over-Project
Agent が導出して書く内容 — 状態スキーマ、deny ルール、cycle prompt のドメイン節など)。
`unfilled_marker` が残る instance は自分では 1 cycle も走らない(レシピ側の placeholder 柵)。

## instantiation の経路(META.md §29.3)

1. Essence がポインタでレシピを指定する。
2. Over-Project Agent が投影で High-Risk Todo(`risk_level: "high"`)を立てる —
   生成先に `.claude/**` / hooks / loop スクリプトを含むため、既存の High-Risk 柵
   (ask + hash 記録、§12)がそのまま効く。
3. Todo 実行で `files/` を対象へ写し、置換トークンを埋め、authored パラメータを Essence から
   導出して書き、`recipe.lock.json` を置く(`source_sha256` は `bin/atlas-builder recipe hash <name>`)。
4. `recipe.json` の `post_install_checks` を実行し、結果を Todo の evidence にする。
