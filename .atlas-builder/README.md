# CONTROL_ROOT — Atlas Builder v1.0

このディレクトリは Over-Project Agent の実行ルート(制御プレーン)です。設計の正本は同ディレクトリの [META.md](META.md) を参照してください。

Atlas Builder は**特定プロジェクトに依存しない汎用テンプレート**として配布されます。配布状態の `.atlas-builder/` はどのプロジェクトにも束縛されていません(`CLAUDE.md` / `.claude/settings.json` / `justfile` は「未束縛・安全版」)。`just init` で 1 つの対象プロジェクトへ束縛してから運用します。

## セットアップ(新規プロジェクト)

ワークスペースは 1 つの git リポジトリで、その直下に `.atlas-builder/`(制御プレーン)と `{project-title}/`(対象プロジェクト)を**兄弟**として置きます。cycle commit は両者が同一 git リポジトリにあることを要求します。

```bash
# 1. ワークスペース(= 1 git repo)を用意し、この .atlas-builder/ を配置
mkdir my-workspace && cd my-workspace && git init
cp -R /path/to/atlas-builder/.atlas-builder ./.atlas-builder
mkdir my-project            # 対象プロジェクト(空でも可。既存プロジェクトを置いてもよい)

# 2. Lean ランタイムをビルド(初回のみ)。以降の trust / new-essence / init /
#    doctor / loop はすべて bin/atlas-builder を実行系とするため、未ビルドだと
#    各コマンドがこのビルドを案内して exit 2 で停止する
cd ./.atlas-builder && just build && cd ..

# 3. 対象の ESSENCE.md を人間が記述(手段はどちらでも; 適用・確定は常に人間)
#    エージェントは ESSENCE.md を編集しない。init/bootstrap は既存 ESSENCE.md を保持する
#    (a) 自分で書く。必要なら .atlas-builder/templates/project/ESSENCE.md を参考にする
$EDITOR my-project/ESSENCE.md
#    (b) 対話起草(Essence interview, META.md §2.1.4): エージェントがクリティカルな要件から
#        順に質問して完全準拠のドラフトを作り、人間が全文を確認(y)した場合のみ設置される。
#        セッション内の境界強制(hooks)のため、先に trust を通す
cd ./.atlas-builder && just trust ../my-project && just new-essence ../my-project && cd ..

# 4. 制御プレーンへ移り、対象へ束縛 + bootstrap を一括実行
cd ./.atlas-builder
just init ../my-project     # = bash scripts/init.sh --project ../my-project

# 5. Claude Code trust → 健全性検査 → 初期状態を commit → 実行
just trust                  # ~/.claude.json にこのワークスペースの trust を明示設定(3-(b) で済みなら no-op)
just doctor
cd ..
git add . && git commit -m "chore: initialize Atlas Builder workspace"
cd ./.atlas-builder
just loop

# 6. 人間がレビュー/修正したら(停止中でも、ループの合間でも): just resume → just loop(META.md §13.3)
```

`just init` は `templates/control/*.tmpl` から `.claude/settings.json` / `CLAUDE.md` / `justfile` を対象名で生成(束縛)し、続けて `bootstrap.sh`(seed + state ensure + validate)まで実行します。bootstrap は既存の `ESSENCE.md` を上書きしないため、新規プロジェクトでは `just init` の前に人間が実際の `ESSENCE.md` を置くのが標準です(`just new-essence` での対話起草を含む — META.md §2.1.4)。`ESSENCE.md` が未作成の場合だけ bootstrap が placeholder 雛形を seed しますが、その場合は人間が置換してから `doctor` / `loop` に進みます。init 前に書かれた `ESSENCE.md` は bootstrap がその hash を人間確認済み baseline(anchor)として記録しますが、init **後**に書いた/置換した `ESSENCE.md` は、初回ループの前に `just resume` で人間確認(attestation)を記録してください — 記録が無いと初回ループは `essence_unreviewed_change` で停止します(META.md §13.1-10)。Claude Code は trust 済みでないワークスペースの `.claude/settings.json` permissions/hooks を無視するため、初回は `just trust` を実行します。`just trust` は人間用の明示操作として `~/.claude.json` の `projects[...].hasTrustDialogAccepted` を設定します。これを避けたい場合は、`just trust-check` が表示する全パスを Claude Code の trust dialog または `~/.claude.json` の手動編集で信頼済みにしてください。`just loop` は clean worktree からしか開始しないため、`ESSENCE.md` と生成された初期状態をレビューして commit してから実行します。`ESSENCE.md` が placeholder のまま、または Claude Code trust が未設定なら `doctor` と `loop` は hard gate として停止します。1 つの制御プレーンは 1 つの対象に束縛されます(別対象へ束縛し直すには `just init ../other --force`)。

## 起動境界(絶対規則)

```bash
# Over-Project Agent は安全設定を固定する wrapper から起動する
cd ./.atlas-builder
just loop
# 承認済み High-Risk 変更だけ: just supervise --todo T-... --recommendation R-...

# 対象がエージェントを内包していても、Atlas Builder は live PROJECT_ROOT で
# それを直接起動しない。対象固有の隔離 runner のみを検証に使う(META.md §10)。
```

ワークスペースルートから `claude` を起動してはならない(I-001)。

## レイアウト

```text
.atlas-builder/
├── META.md              # フレームワーク設計書(正本)。§0–§31 の共通章と本ドメインの章の**合成物**であり、素材と合成器はフレームワークリポジトリ側にある(META.md §18.4)
├── CLAUDE.md            # Over-Project Agent 実行憲章
├── .claude/
│   ├── settings.json    # permissions + hooks 配線(全 5 イベントを bin/atlas-builder hook <event> へ。境界の機械的強制)。マシン非依存の base — パス系ルールと sandbox は launcher が起動毎に生成する --settings overlay が担う(META.md §16.1)
│   ├── agents/          # モデル配分 subagents(scout / builder / analyst — META.md §30)
│   ├── commands/        # 人間起動の slash commands(/triage, /essence — META.md §13.6, §2.1.4)
│   ├── rules/           # 束縛版 CLAUDE.md がインポートする規範 9 本
│   └── skills/          # プロジェクト固有 skills 置き場(配布時は空)
├── .agent/
│   ├── state/           # 制御プレーン状態(workspace.json, project_index.json, ...)
│   ├── prompts/         # ループ用サイクルプロンプト
│   ├── runs/            # 実行ログ(コミット対象外)
│   └── tmp/
├── templates/
│   ├── control/         # init が束縛ファイルを生成する雛形(settings.json/CLAUDE.md/justfile の .tmpl)
│   ├── workspace/       # init がワークスペース root README を seed する雛形(既存は保持)
│   └── project/         # bootstrap が対象プロジェクトへ seeding する雛形(ESSENCE.md / README / .gitignore のみ。対象側 CLAUDE.md / .claude は seed しない — META.md §5.0)
├── recipes/             # レシピ原本: ESSENCE.md のポインタ(recipe: <name>@<major>)で採用できる具体的実装の型(META.md §29。justfile の「レシピ」= just recipe とは別物)
├── scripts/             # 運用スクリプト一式(init.sh を含む)
├── lean/                # Lean ランタイムのソース(ソースが正本 — META.md §31.1 R-1)
├── bin/                 # ビルド済み atlas-builder バイナリの配置先(just build。gitignore 対象)
└── justfile             # 人間向け標準運用コマンド(配布時は未束縛)
```

このディレクトリは**配布単位そのもの**なので、束縛済み制御プレーンの運用に必要なものだけが入ります(I-028)。Atlas Builder 自身のソースを lint / format / test するコマンドと、その保守ツーリング(`shellcheck` / `shfmt`、Lean のテスト・証明パッケージ)はここには**ありません** — 主語が違うので、フレームワークリポジトリの root に置かれます(META.md §18.4)。実行系はゼロ依存の Lean バイナリ `bin/atlas-builder` だけで動きます(初回のみ `just build` でソースからビルド)。

## 標準運用

束縛済み(`just init` 実行後)の制御プレーンでは、`justfile` に対象が焼き込まれているため `--project` の指定は不要です。

初回セットアップ(束縛・trust・doctor・初期 commit)は上の「セットアップ」の手順が正本です。
`just bootstrap` は必要時のみの再初期化(テンプレート更新後の再 seed や欠損ファイルの修復。
冪等で、既存ファイルは上書きしない)に使います。

```bash
cd ./.atlas-builder

# 1. 状態確認
just status

# 2. 実行
just once   # 1 サイクル
just loop   # 継続ループ(既定 25 サイクル上限)

# 2'. 走行中のループをキリよく止める(graceful drain、META.md §19.1-7)
just stop   # 別ターミナルから。実行中 cycle は完走して checkpoint を作り、
            # 次の境界で gate なしの exit 0 — resume 不要で次の just loop が続きを回す
            # (Ctrl-C の中断と違い worktree は clean のまま。撤回: just stop --cancel)

# 2''. 走行中のループを別ターミナルから読み取り専用で監視する(META.md §15.3)
just watch  # 現在サイクル・gate 状態・履歴/統計・エージェントのライブ活動を
            # 約 1 秒ごとに再描画するフルスクリーン TUI。純オブザーバ:
            # q / Ctrl-C で終了しても loop に無影響。停止後の last-known 確認にも使える

# 3. 人間がレビュー/修正したら再開(META.md §13.3)— 停止中(gate release)でも、
#    停止していないループの合間の方針修正(steering)でも、入口は同じ
$EDITOR ../{project-title}/ESSENCE.md      # (または just update-essence で対話的に改稿 — 変更意図を最初に聞き、確認(y)後に設置。META.md §2.1.4)
just resume --resolve R-... --note "何を確認/修正したか" # 指定した停止ゲートだけを解除 + review checkpoint commit
just resume --note "途中修正の意図"       # gate が 1 つも open でないときの steering の記録
just resume --steer-only --note "要求を追加した"  # open gate を保ったまま編集だけを記録(§13.3-4''')
just loop                   # (--note を省くと対話プロンプトが意図の入力を要求する)

# Must 完了境界では通常 gate の --resolve ではなく、完了 scope を明示する
just resume --approve-should --note "Should scope を承認"
# または: just resume --close-at-must --note "Must scope で完了とする"

# 3'. 停止対応を対話的に代行させる場合(META.md §13.6)
just triage                 # ゲートの説明・仕分け・代行調査・質問 → note + exact decision list を y 確認後に resume

# 3''. 承認済み High-Risk Recommendation を適用する場合(META.md §12.1, §21.3)
just supervise --todo T-... --recommendation R-... # exact Todo/Recommendation に束縛。人間が各 ask と全 diff をレビュー
just resume --resolve R-... --note "承認済み High-Risk 変更をレビュー"
just loop
```

状態遷移の人間向け入口は `just state <command>` です。内部では束縛済み対象に対して `bin/atlas-builder state <command> --project ../{project-title}` を実行します(`ensure` / `validate` / `apply-projection` / `stage-projection` / `append-reflection` / `append-lesson` / `should-stop` / `should-complete` / `should-reset` / `supervise-check` / `record-progress` / `raise-loop-gates` / `start-run` / `end-run` / `reset-context` / `resume` / `status`)。Spec / Todo / Recommendation / Blocker の更新は、一時 bundle を `apply-projection --file <bundle.json>` に渡して全体を事前検証してから適用し、個別 JSON を直接編集しません。bundle の雛形は `stage-projection` が現在の正本 4 面をそのまま `{project}/.atlas-builder/tmp/projection_bundle.json`(gitignore 済み)へ吐きます。追記専用台帳(`reflection.jsonl` / 知見台帳 `lessons.jsonl` — META.md §14.3)への追記は `append-reflection` / `append-lesson --file <entry.json>` を通り、スキーマ検証のうえ `at` / `cycle` / `run_id` を canonical state から engine が刻みます。ただし複数ファイルの置換は filesystem transaction ではないため、プロセス停止等による途中失敗は次回 `validate` / checkpoint guard が検出します。`supervise-check` は High-Risk scope の read-only preflight です。`resume` は commit まで含む `just resume` から実行するのが標準です。

ループが停止するときは、`STOP:` 行と再開手順を表示して**正常終了**します(exit 0)— 停止は人間へ手番を渡す仕様どおりの終端であり、エラーではありません(META.md §13.4、§19.1)。停止理由と再開手順は `just status` にも必ず表示されます(I-017)。loop 検出の停止(実行可能 Todo なし / 意味的進捗なし / 利用上限の連続到達 — `usage_limited` / infra 起因の `claude` 連続失敗 / must フェーズ完了のフェーズ境界 — `must_complete_awaiting_phase_approval`)は canonical state(`recommendations.json`)に Human-input Recommendation(`raised_by: "atlas-builder-loop"`)として実体化されます。停止ゲートが latch されている間の `just loop` 再実行は副作用ゼロで同じ案内を表示するだけです(I-019)— 通常 gate は ID を指定した `just resume --resolve ...`、Must 境界は `--approve-should` / `--close-at-must` の明示判断だけが進めます。

`just resume` は人間専用で、人間介入の唯一の入口です。停止していた場合(gate release): 停止条件(Essence 由来 Blocking、人間レビュー待ち Recommendation、loop が実体化した gate、idle-cycle 安全停止)は state にラッチされるため、人間が `ESSENCE.md` 等を修正しただけでは `just loop` は再開しません。通常 gate は `--resolve B-...` / `--resolve R-...` を繰り返して exact ID を選び、**選ばなかった gate は開いたまま**にします。存在しない ID・重複指定・通常 `--resolve` による Must 境界解除は書込み前に拒否されます。Must 境界は `--approve-should`(Should へ進む)か `--close-at-must`(Must scope で閉じる)の排他的な二択です。選択した状態遷移と修正内容を 1 つの review checkpoint commit(`atlas-builder: human resume`)にまとめます。停止していない場合(steering): ループの合間に `ESSENCE.md` 等を修正したときは、gate を選ばない `just resume` を実行します。**停止中に人間所有入力を修正した場合**(典型は Must 境界で要求を追加するとき — META.md §19.3)は `just resume --steer-only --note "..."` を使います: gate を 1 件も解除せずに編集だけを attestation して checkpoint する形で、gate の決定は従来どおりそれぞれの exact 形が引き受けます(§13.3-4''')。`--steer-only` は `--resolve` / `--retract-approval` / Must 境界の二択とは併用できません(意図の混線として拒否されます)。介入は制御プレーンの attestation 台帳(`.agent/state/essence_attestations.jsonl`。`ESSENCE.md` の SHA-256 を記録する、停止判定が信頼する唯一の baseline — META.md §13.1-10)と `human_resume` reflection エントリ(変更ファイル一覧つきの参考情報)に記録され、`atlas-builder: human update` の checkpoint commit が作られるため、次の `just loop` は clean worktree(I-014)から開始でき、次サイクルはその Essence 変更を「人間の正当な編集」として扱えます。解除すべきラッチも修正もなければ no-op です。未終了の run が記録されている間は競合防止のため拒否します。ループがクラッシュして start だけが残った場合のみ `--force` を使うと、その run を閉じて残骸を `atlas-builder: crash recovery` の checkpoint として引き取ります(META.md §13.5)。どのモードでも次サイクルは Essence と未解除 gate を再評価し、問題が残れば停止します(resume は blanket な「全解決」宣言ではない)。介入の意図を残す自然言語の note は必須です: `--note "..."` で渡すか、省略時は対話プロンプトが入力を要求します(空入力は不可、非対話実行での省略は拒否 — META.md §13.3)。エージェントによる `resume` 実行は hook が deny します(I-011)。

`just new-essence` / `just update-essence` は人間専用の対話セッションで、`ESSENCE.md` の起草・改稿を質問駆動で代行します(Essence interview、META.md §2.1.4)。`new-essence` は新規起草用で、クリティカルな決定から順に(モチベーション → 必須対応事項 → 成功条件 → 前提事項 → 思想 → 遂行順序 → 非対応事項 → 任意対応事項 → 用語 → 実装のこだわり)本質的な質問で要件を確定させます — 実体のある(非 placeholder の)`ESSENCE.md` が既に存在する場合は起動を拒否します(改稿は `update-essence` の仕事)。`update-essence` は既存 Essence の途中改稿用で、**最初に変更意図を質問**し(何を・なぜ変えたいか)、意図が触れる決定だけをインタビューして、それ以外の文は一字一句そのまま繰り越します — 実体のある `ESSENCE.md` が無い場合は実行時エラーになります(先に `new-essence`)。どちらも曖昧な回答は検証可能な文面へ言い換えて読み戻し、完全にフォーマット準拠のドラフトを handoff(`.agent/tmp/essence/`)に書いて終わります。`essences/` 配下に Excel ブック(`.xlsx` / `.xlsm`)がある場合、wrapper が起動前にテキストのセル一覧へダンプして handoff dir に置くため、セッションはシート構成やセル座標を人間に尋ねず直接読めます(原本は human-only のまま・セッションの書込み面は不変)。セッションは read-only(I-027)で `ESSENCE.md` 自体には書けず(I-004 は hook が強制)、wrapper がドラフト全文(既存の実 Essence を置換する場合は diff も)を端末に表示して、明示確認(y)を得た場合に限り設置します — 内容はすべて人間の回答・承認に由来し、確認の keystroke が人間の記入行為にあたります。設置後の次手順(束縛前なら `just init`、束縛後なら `just resume` → `just loop`)は wrapper が判定して案内します。セッションの境界強制に trust が必要なため、未束縛の初回は `just trust ../{project-title}` を先に実行します。エージェントによる `just new-essence` / `just update-essence` 実行は hook が deny します(I-004 / I-027、META.md §18.2)。

`just triage` は人間専用の対話セッションで、停止対応の人間側作業を代行します(META.md §13.6)。まず開いている各ゲート項目を人間へ平易な言葉で提示し(それが何であり — 人間ゲート付き Recommendation なら何を勧めている・求めているのか — なぜ上がったのか・解除すると何が起きるのかを、生の JSON ではなく一読で掴める一文へ翻訳します)、その上で「調査で決着する(代行で打ち取る)」「人間の判断が必要」の 2 種に仕分け、前者は結論と根拠を提示して resume note に畳み込み、後者は決定に必要な最小限で本質的な質問で要件を確定させた上で、人間が実施すべき手順をステップバイステップで提示します。セッションは read-only(I-022)で、Edit/NotebookEdit ツールを無効化し、Write ツールは hook が handoff 内へ封じ込め、対象全体を session-bound OS sandbox でも read-only にします。書けるのは handoff 用の `.agent/tmp/triage/` のみです。実装・state 変更は一切行わず、handoff には note と exact decision list(`--resolve` ID 群または一つの phase decision)だけを書きます。wrapper はその line protocol と現在の open gate を再検証し、端末へ表示して人間が y と答えた場合に限り targeted `just resume` 相当を実行します(`--force` は渡さず、`just loop` も起動しません)。ESSENCE.md の変更は提案までで、適用は人間が行います(I-004)。停止していなければセッションを起動せず終了します。エージェントによる `just triage` 実行は hook が deny します(I-022、META.md §18.2)。

`just supervise --todo T-... [--recommendation R-...]` は、承認済み High-Risk Todo **1 件**を適用するための人間専用対話セッションです。`--todo` は必須で、Claude 起動前の canonical preflight が exact Todo の unfinished / high-risk / `executor.mode=atlas-builder` / non-empty `risk_reason` / non-empty `target` を検査します。`--recommendation` を与えた場合は、open な human approval Recommendation の `source` が exact Todo ID を含み、両者の `target` が完全一致しなければ拒否します。検査済み target は session prompt に固定されますが、その内側の意味的な実装妥当性は ask と最終 diff で人間が確認します。自律 loop は headless で走り、提示できない ask は自動 deny になるため(§19.1-5)、loop 自身がこの境界を越えることはありません。supervise は loop/resume と同じ single-flight lock、permissions/hooks/OS sandbox、秘密を除いた環境で Over-Project Agent を起動し、人間が各 ask を判断します。終了後は dirty diff を全文レビューし、対応する gate があれば `just resume --resolve R-... --note "..."` で human checkpoint にします。エージェントによる supervise の再帰起動は hook が deny します。

`just once` / `just loop` は各 Atlas Builder cycle の開始時に Git worktree が clean であることを要求し、cycle 終了時に `atlas-builder: cycle R-...` 形式の checkpoint commit を 1 件作成します。全 checkpoint は commit 前に exact staged blob を、秘密本文を出力しない狭い credential signature(private-key header と既知 API/cloud key prefix)で走査します。該当時と scan 自体の失敗時は scope を unstage して hard stop しますが、これは未知形式まで保証する DLP ではありません。commit 失敗も hard stop です。Agent が直接 `git add` / `git commit` を実行することはありません。

`just trust` は Claude Code の信頼済みワークスペース情報を `~/.claude.json` に書くため、人間が明示的に実行する初回セットアップです。`just trust-check` は書き込みなしで現在の trust 状態だけを確認しますが、秘密設定ファイルを読むので `doctor` と同じく人間専用です(I-024)。Claude Code のバージョン差で trust key が CWD か Git ルート寄りになる場合があるため、Atlas Builder は両方の候補を検査します。

### Just レシピ

利用できるレシピは `just --list` で確認できます。`justfile` は人間の運用者向けの標準入口です。permissions と hooks は内部の `bash scripts/...` / `bin/atlas-builder state ...` に対して境界を強制します。Over-Project Agent の実行ルールは [CLAUDE.md](CLAUDE.md) に従います。

`just --list` はレシピを 3 つの group に分けて表示します。これは表示上の都合ではなく、PreToolUse guard(`atlas-builder hook pre-tool`)が実際に強制している 3 分類を発見面へ投影したものです(META.md §18.2、§18.4)。

| group | 意味 | エージェントに対する扱い |
| --- | --- | --- |
| `human-only` | 人間専用の遷移・秘密設定診断・常駐対話プログラム | **deny**: `init` / `trust` / `trust-check` / `doctor` / `new-essence` / `update-essence` / `once` / `loop` / `stop` / `resume` / `triage` / `supervise` / `watch` |
| `approval` | 人間の明示承認があれば実行可 | **ask**: `bootstrap` / `build` |
| `inspect` | Agent-safe な診断(`validate` は診断変化時だけ `validation.json` を更新) | **allow**: `status` / `state`(subcommand 単位) |

`state` だけはサブコマンド単位で判定されます(`state resume` は人間専用、loop 所有の遷移は deny、残りは allow)。

**ここに `lint` / `format` / `test` はありません。** それらの主語は「対象プロジェクト」ではなく「Atlas Builder 自身のソース」なので、フレームワークリポジトリの root にある別の `justfile` が持ちます(META.md §18.4、I-028)。`.atlas-builder/` は配布単位なので、ここに置けば全利用者に配られます。判定は「配布された束縛済み制御プレーンで、そのコマンドは意味を持つか?」の 1 テストです。

なお、state エンジンも hooks(全 5 イベント)も Lean 4 実装の単一バイナリ `bin/atlas-builder`(ゼロ依存、`just build` で配置)で実行されます — permissions のコマンド文字列一致と hooks(境界強制)を外部 runtime やネットワークに依存させないためです。

## モデル配分(Model Tiering、META.md §30)

判断は最上位モデル、脚仕事は十分な最小モデル — Over-Project Agent 本体のセッション既定モデル(`settings.json` の `model`、配布既定は公式 alias `best`)が Essence 解釈・投影・停止判断・High-Risk 変更・正本書込みのすべてを担い、cycle 内の脚仕事だけを安価な tier へ委ねます。

| tier | 担い手 | 既定モデル |
| --- | --- | --- |
| 判断 | 本体セッション | `best`(`settings.json`: 利用可能な最も高性能なモデルを選ぶ公式 alias) |
| 参謀(read-only 難所分析・レビュー草稿) | `analyst` subagent | `opus`(`.claude/agents/analyst.md`) |
| 職人(定型実装) | `builder` subagent | `sonnet`(`.claude/agents/builder.md`) |
| 脚仕事(read-only 探索・要約) | `scout` subagent | `haiku`(`.claude/agents/scout.md`) |

モデル値は配備方針であって安全境界ではありません(§16.1)。既定モデルが使えないとき(利用上限・提供終了・障害)は、束縛済み `settings.json` の `model` を別の公式 alias へ書き換えて恒久的に変えるか、環境変数 `ATLAS_BUILDER_MODEL` で **その起動だけ** 上書きできます — `loop` / `once` / `triage` / `essence` / `supervise` のすべてが受け付けます。

```sh
ATLAS_BUILDER_MODEL=opus just triage          # この triage セッションだけ opus tier
ATLAS_BUILDER_MODEL=claude-opus-5 just loop   # 完全なモデル名で固定することもできる
```

受け付ける値は公式 alias(`best` / `default` / `opus` / `sonnet` / `haiku` / `fable` / `opusplan`)か `claude-*` 形式のモデル名のみで、それ以外は起動前に exit 2 で拒否します。未設定なら `settings.json` の値がそのまま使われます。

tier はタスクの難易度で選び、迷ったら上の tier(最終的には本体)へ倒します。委譲は cycle 内の作業ステップであって安全境界の変更ではありません。`scout` / `analyst` / `builder` は本体と同じ permissions / hooks の下で動きます。ホストの読取境界を強制できない外部 CLI 委譲は、秘密境界(I-024)と両立しないため標準 tier に含めません。

## 前提

- 対象プロジェクトの `ESSENCE.md` は人間が書く。placeholder のままでは実行不可。エージェントは絶対に編集しない。対話起草・改稿(`just new-essence` / `just update-essence`、META.md §2.1.4)を使う場合も、設置は人間の全文確認(y)を経てのみ行われる。
- Markdown 以外の指示資料や `ESSENCE.md` に埋め込む画像などは、任意の human-only 資産ディレクトリ `PROJECT_ROOT/essences/`(最大 3 階層まで入れ子可)に人間が置ける(`ESSENCE.md` と同格。エージェントは参照のみ)。各ファイルは本文で `essences/<path>` と正確に言及する(祖先ディレクトリの言及 — 例 `essences/input/` — がその配下すべてを覆う) — 未言及/不在の不整合は `essence_asset_integrity` で停止する(META.md §2.1.5、§13.1-14)。
- 正本は `{project}/.atlas-builder/state/*.json` / `*.jsonl`。人間向けの状態表示は `just status` が正本 state から都度計算する(編集・信頼すべき生成ファイルは存在しない)。
- ループは Essence 由来 Blocking、人間承認/入力待ち、実行可能 Todo の枯渇(完了条件未達のまま)、must フェーズ完了(完了 scope の人間判断待ち — `must_complete_awaiting_phase_approval`。ハッピーパスでも必ず一度ここで止まり、`just resume --approve-should` なら should が自律予算に入り、`just resume --close-at-must` なら Must scope で監査可能に閉じる — META.md §13.1-13, §19.3)、意味的進捗なし 3 cycle 連続(既定)、プラン/モデル利用上限の連続到達(既定 4 回 — `usage_limited`。待つか `ATLAS_BUILDER_MODEL=<tier>` で別モデルへ)、infra 起因の `claude` 連続失敗(既定 2 回 — `infra_unreachable`)、および `ESSENCE.md` の欠如・placeholder・人間未確認の変更(`essence_unreviewed_change`)やゲート保持 state の破損(`state_unreadable`)で停止する。実装系エラーは自律回復する。停止理由は必ず `just status` とループの終了メッセージに現れ、loop 検出系は Recommendation としても実体化される(I-017、META.md §13.4)。
- 人間介入(停止からの再開・停止していないループへの途中修正・クラッシュ回復)の入口は人間専用の `just resume`(META.md §13.3, §13.5)。エージェントは自分の停止条件を解除できず、人間介入を偽装できない(I-011)。
