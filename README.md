# Atlas Builder Workspace — consensus-sim

Atlas Builder v1.0(Human-Essence-Driven Agentic Coding Framework)のワークスペースです。設計の正本は [.atlas-builder/META.md](.atlas-builder/META.md) を参照してください。

## 構造

```text
<workspace>/
├── .atlas-builder/                    # CONTROL_ROOT — Over-Project Agent の実行ルート(META.md はここ)
└── consensus-sim/   # PROJECT_ROOT — 対象プロジェクト(In-Project Agent を含み得るが Atlas Builder は live 起動しない)
```

## 絶対規則

**このディレクトリ(ワークスペースルート)から `claude` を起動しないでください**(invariant I-001)。

制御セッションは必ず次の場所から起動します。

```bash
# Over-Project Agent(制御・投影・直接実装・検証)は wrapper 経由
cd ./.atlas-builder && just loop
# 承認済み High-Risk 変更だけ: just supervise --todo T-... --recommendation R-...

# 対象がエージェントを内包していても、Atlas Builder は live PROJECT_ROOT で
# それを直接起動しません。対象固有の隔離 runner が無ければ人間にゲートします(META.md §10)。
```

## はじめかた

```bash
# 1. 人間が Essence を書く/確認する(エージェントは絶対に編集しません)
$EDITOR consensus-sim/ESSENCE.md
# (または対話起草: cd ./.atlas-builder && just trust && just new-essence — セッションの境界強制に
#  trust が先に必要。クリティカルな要件から順に質問し、全文を確認(y)した場合のみ設置される。
#  既存 Essence の途中改稿は just update-essence — 変更意図を最初に聞き、その範囲だけを改稿する。
#  META.md §2.1.4)

# 2. 制御プレーンで健全性検査 → ループ(束縛済みなら --project 不要)
cd ./.atlas-builder
just trust
just doctor
just status
cd ..
git add . && git commit -m "chore: initialize Atlas Builder workspace"
cd ./.atlas-builder
# init 後に ESSENCE.md を書き換えた場合(placeholder の置換を含む)は、
# 人間確認の記録(attestation)を先に済ませる — 記録が無いと初回ループは
# essence_unreviewed_change で停止する(META.md §13.1-10)。
# init 前に書いた Essence のままなら、この resume は無害な no-op である。
just resume --note "initial essence"
just loop
# (別ターミナルからの併走: just watch — 読み取り専用の監視 TUI、META.md §15.3。
#  キリのよい停止は just stop — 実行中 cycle は完走して checkpoint を作る、§19.1-7)

# 3. ループが停止したら(STOP: 行を表示して正常終了する。エラーではない):
#    停止理由と再開手順は `just status` とループの終了メッセージに表示される。
#    人間がレビュー/修正してから、人間専用の resume で再開する(META.md §13.3)
just resume --resolve R-... --note "確認/修正内容" # 指定した gate だけを解除
just loop

# Must 完了境界は通常 gate と別の明示判断:
# just resume --approve-should --note "Should scope を承認"
# just resume --close-at-must --note "Must scope で完了とする"

# 3'. 停止対応を対話的に代行させる場合(META.md §13.6): ゲートを仕分けし、
#     調査で決着する項目は代行、人間必須の項目は手順に分解、note と exact
#     decision list を起草して y 確認後に targeted resume まで引き継ぐ(実装は行わない)
just triage

# 3''. 承認済み High-Risk 変更を人間同席で適用する場合
just supervise --todo T-... --recommendation R-...
just resume --resolve R-... --note "承認済み High-Risk 変更をレビュー"
just loop
```

このワークスペースは `just init ../consensus-sim` で束縛・初期化済みです。別プロジェクトへ束縛し直すには `.atlas-builder/` 内で `just init ../<other> --force` を実行します。

`just` が入っていない場合、人間は `.atlas-builder/` 内で対応する `bash scripts/*.sh --project ../consensus-sim` を直接実行できます。ただし loop / once / stop / watch / init / resume / triage / supervise / essence / trust / trust-check / doctor は入口の綴りによらず人間専用で、Agent session からの直接実行も hook が拒否します。Agent が実行できるのは settings と hook が明示許可する status/validation/state 操作だけです(META.md §18.2)。

詳細な運用手順は [.atlas-builder/README.md](.atlas-builder/README.md) を参照してください。
