# consensus-sim ワークスペース

[Ideal-Driven Development(IDD)](https://github.com/banr1/ideal-driven-development) で開発するワークスペースです。人間は `consensus-sim/IDEAL.md` に「実現したい状態」を書き、エージェントがそれを正として周回を回します。IDD 自体の説明はフレームワーク側の README を参照してください。

## 構造

```text
<workspace>/                          1 つの Git リポジトリ
├── .github/workflows/deploy.yml      GitHub Pages への薄い shim(人間が管理。consensus-sim/scripts/ci.sh を 1 本呼ぶ)
├── README.md                         この文書
└── consensus-sim/                    IDD のプロジェクト(PROJECT_ROOT)。idd はここで実行する
    ├── IDEAL.md                      人間の正本(人間だけが書く。周回は書き換えない)
    ├── .idd/                         progress.md(条件台帳)/ knowledge.md(知見)/ cycles/(周回記録)/ journal.jsonl(台帳)
    ├── essences/deep-research-report.md   人間が配置した攻撃の出典(人間所有。IDEAL.md から参照)
    ├── scripts/ci.sh                 CI の実体(npm ci → test → build → dist 検査)
    └── src/ tests/ docs/ …           アプリ本体
```

フレームワーク(`idd` コマンド)はプロジェクトの外にあります(`~/.local/bin/idd`)。このリポジトリには `CLAUDE.md` も `.claude/` も置きません。文脈は周回プロンプトが注入し、境界は起動時の設定注入・環境注入と git hook が担います。

## 使い方

すべて `consensus-sim/` で実行します。

```bash
cd consensus-sim
idd doctor                    # エージェント CLI・ガードレールの配線・IDEAL.md の構造・clean 判定
idd once                      # 1 周回だけ(様子を見る)
idd loop                      # 既定 25 周回まで。止まったら STOP: と次の一手を表示して exit 0 する
idd status                    # 状態・停止理由・次の一手
idd show [N]                  # 周回記録を読む(既定: 最新)
idd watch                     # 別の端末から観る読取専用 TUI(q で終了)
idd stop [--cancel]           # 走行中のループを次の周回境界で止める
```

止まったときの人間の手番:

```bash
idd show                      # ask なら「人間への問い」を読む
idd refine                    # 変更意図から始める尋問で IDEAL.md を書き直す(問いへの答えもここに書く)
idd resume --note "…"         # 介入を台帳に刻み、停止状態を解除してから idd loop
```

`IDEAL.md` を手で直した場合も、未 commit のままなら次の `idd loop` が人間の編集として取り込みます。必須条件がすべて met になると `realized` で止まり、「望ましい」へ進むかは `idd resume` で人間が決めます。

## 公開

main への push ごとに `.github/workflows/deploy.yml` が `bash consensus-sim/scripts/ci.sh` を実行し、成功したときだけ `consensus-sim/dist/` を GitHub Pages(`https://nyxfoundation.github.io/consensus-sim/`)に公開します。shim の変更は人間の作業です(周回は PROJECT_ROOT の外を読み書きしません)。

## 来歴

このワークスペースは Atlas Builder(`.atlas-builder/` + `ESSENCE.md`)で開発されていましたが、IDD に置き換えました。旧正本は `git show 41169f7:consensus-sim/ESSENCE.md` で読めます。`IDEAL.md` の条件 C1〜C32 は旧 必須対応事項 1〜32 と同じ番号で、コードのコメントが引く旧番号はそのまま `IDEAL.md` で引けます。
