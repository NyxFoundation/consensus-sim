# agentic-state-loop — ハーネス付き自律エージェントループ(レシピ第一号)

Over-Project ループが自分自身の運用に使っている状態管理法の汎用コアを、対象プロダクトが内包できる形に
切り出したレシピである。次の 4 点セットを提供する。

1. **エージェント執行ループ** — 各 cycle を Claude Code の非対話セッション(`claude -p`)が実行する
   (`scripts/loop.sh` / `once.sh`。single-flight lock、セッション継続と fresh 再開のバックストップ付き)。
2. **アトミック commit 規律** — 1 cycle = 最大 1 checkpoint commit。cycle はクリーンな worktree
   からしか始まらず、禁止パス(秘密・tmp débris)と保護パスは commit guard が機械的に弾く。
   さらに commit 直前に **staged blob そのもの**を高確度の credential 署名で走査し(秘密の値も
   その行も出力しない)、対象の外に staged されたパスを拒否する — パス隔離だけでは、
   うるさいツールが credential を通常のソースやログへ書き写す形を防げない。**抑止マーカーは
   意図的に用意していない**(staged 内容を編集できる agent が自分で迂回を許可できてしまう):
   検出されたら人間が除去/秘匿する。`resume.sh` は同じ条件を**状態を変異させる前**に見て、
   通らなければ何も書かずに拒否する(半適用の resume を残さない)。
3. **JSON SSOT** — 正本は `state/` の JSON 文書 + 追記専用 JSONL。全変異は同梱 Lean エンジン
   `<loop_dir>/bin/asl-loop state` を通り(ドメイン文書の置換は `write-doc`(スキーマ検証付き・
   原子的)、宣言済みログへの追記は `append-log`)、文書は `schema.json` に宣言されたスキーマで
   validate される。`state/` への直接編集は hooks が deny する。
4. **ルールベース不変条件ハーネス** — `.claude/settings.json` + hooks が、正本の直接編集・
   git add/commit・秘密・human-only 遷移(resume / loop 起動)・loop-only 遷移
   (start-run / end-run / record-progress)・instance 固有 deny ルールを機械的に強制する。

停止/再開の骨格も付属する: 人間の判断が要る条件は agent が **gate** として正本に記録して停止し
(`asl-loop state raise-gate`)、空転(idle streak)・連続失敗(failed-run streak)は loop が閾値で gate 化する。
gate の解放は human-only の `resume.sh --note "..."`(意図 note 必須、review checkpoint commit 付き)。

## 対象内の配置(instance)

```text
<target>/
├── <loop_dir>/                # 既定 .loop — パラメータ loop_dir
│   ├── recipe.lock.json       # 展開記録(レシピ名 + version + source hash)
│   ├── schema.json            # instance のパラメータ SSOT(文書スキーマ・policy・deny/protected)
│   ├── prompts/cycle.md       # cycle prompt(ドメイン節は authored パラメータ)
│   ├── lean/                  # asl-loop エンジン(state + hooks + util + trust)の Lean ソース + lakefile
│   │                          #   (vendoring 先で lake build — `just engine-build`)
│   ├── bin/asl-loop           # ビルド成果物(gitignore 済み。scripts / hooks / permissions が実行する実体)
│   ├── scripts/               # loop.sh / once.sh / resume.sh / status.sh / _lib.sh
│   ├── state/                 # 正本(ensure が生成; control.json / runs.jsonl / 宣言済み文書)
│   └── tmp/                   # ロック等の débris(gitignore 済み・commit guard も拒否)
├── .claude/                   # ハーネス(settings.json + hooks) — Claude Code の物理制約上ここ
└── justfile                   # 人間向けショートカット(既存があればマージ)
```

instance は自己完結である: 対象リポジトリ単体を clone すれば動き、Over-Project 側(CONTROL_ROOT)を
知らないし参照もしない。唯一の例外は `<loop_dir>/lean/` の同梱エンジンソース — live runtime と
共通判定コアを共有する忠実複製(バイト同一)であり、設計文書参照(`META.md §…`)を
保持する(META.md §29.3 の規範整理)。その名前空間 `Looper.*` は Over-Project ループ
共通の綴りであって製品固有の語彙ではない。参照はコード内の名前だけで、CONTROL_ROOT への
ビルド・実行時参照は無い。運用面(scripts / prompts / schema / settings)に Over-Project 側の
語彙は現れない。

## instantiation 手順(Over-Project Agent / 人間 共通)

1. `files/loop/` → `<target>/<loop_dir>/`、`files/claude/` → `<target>/.claude/`(既存とマージ)、
   `files/justfile` → `<target>/justfile`(既存とマージ)に写す。
2. 全ファイルの `__ASL_LOOP_DIR__` トークンを選んだ `loop_dir` 名で置換する。
3. エンジンをビルドする: `just engine-build`(= `cd <loop_dir>/lean && lake build` +
   `<loop_dir>/bin/asl-loop` への配置)。elan/lake が前提で、ネットワークは固定 toolchain の
   取得のみ。scripts / hooks / permissions はすべてこのバイナリを実行する。
4. authored パラメータを対象の意図(Essence)から導出して書く — `schema.json` の `documents` /
   `policy` / `protected_paths` / `deny_patterns` / `deny_bash_patterns`(下記の制限グロブ方言)、
   `prompts/cycle.md` のドメイン節、`.claude/settings.json` の `permissions.allow` への
   ドメイン検証コマンド追加
   (`verify_allows` — 無いと非対話 cycle は検証コマンドを auto-deny する)。
   `ASL-PARAMETER-UNFILLED` マーカーを 1 つも残さない(残る限り loop は起動を拒否する)。
5. `recipe.lock.json` を `<loop_dir>/` 直下に置く(`recipe.json` の `lock_format`。
   `source_sha256` は Over-Project 側で `bin/<tool> recipe hash agentic-state-loop` を実行した出力。
   `<tool>` は制御プレーンのバイナリ名 = CONTROL_ROOT の basename から先頭の `.` を落としたもの)。
6. `recipe.json` の `post_install_checks` を全て実行して確認する。

## 運用

```bash
cd <target>
just engine-build                       # 初回のみ: 同梱 Lean ソースからエンジンをビルド
CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 claude --setting-sources project --strict-mcp-config
                                        # 初回のみ: trust を受諾して退出(hooks の強制に必須)
bash <loop_dir>/scripts/once.sh         # 1 cycle だけ回す
bash <loop_dir>/scripts/loop.sh         # 連続ループ(既定 25 cycle 上限)
bash <loop_dir>/scripts/status.sh       # 状態サマリ(正本から都度計算)
bash <loop_dir>/scripts/resume.sh --note "..."   # human-only: gate 解放 + review checkpoint
```

停止(STOP)は設計どおりの人間への hand-off であり exit 0。非 0 は失敗のみ
(2 環境/エンジン、3 dangling run の拒否 — クラッシュ後は `resume.sh --force`、
4 git 拒否、5 ロック競合、129/130/143 割込み)。

## deny パターンの方言(制限グロブ)

`schema.json` の `deny_patterns` / `deny_bash_patterns`、および `documents.<name>.schema` の
`pattern` キーワードは、**正規表現ではなく制限グロブ方言**で判定される(正本定義は
META.md §29.6、判定核は同梱エンジンの `Core/Glob.lean`)。要素は 4 つだけ — リテラル文字・
`*`(0 文字以上、`/` も跨ぐ)・先頭 `^`(先頭固定)・末尾 `$`(末尾固定)。エスケープはなく、
一致は部分一致(search)意味論。`protected_paths` は対象外で fnmatch 意味論のまま。

旧(regex)方言からの変換表:

| 旧(Python regex) | 新(制限グロブ) | 備考 |
|---|---|---|
| `state/`(メタ文字なし) | そのまま `state/` | search 意味論は同一 |
| `\.env` | `.env` | `\` エスケープを外すだけ |
| `(^\|/)secrets/` | `^secrets/` と `/secrets/` の 2 本 | 選択は複数パターンへ展開(フィールドはリスト) |
| `\.env($\|\.)` | `.env$` と `.env.` の 2 本 | 同上 |
| `config/credentials\.json$` | `config/credentials.json$` | |
| `\bgit\s+add\b` | `git add`(間隙が可変なら `git*add`) | `\b`・`\s+` は表現不可。`*` の過剰一致は deny では安全側 |
| `X*`(regex の反復) | 意図を確認して書き直し | グロブの `X*` は「X の後に任意列」で意味が異なる |
| `.`(regex の任意 1 文字) | リテラル `.` になる | 任意 1 文字は表現不可。必要なら `*` で広く取る |

`asl-loop state validate` は旧 regex 方言の兆候(`\ ( ) [ ] { } + ? \|`、先頭以外の `^`、
末尾以外の `$`)を advisory warning として報告する(`validation.json` の `warnings`)。

## 注意

- **cycle commit は対象が属する git リポジトリに積まれる。** Over-Project ワークスペース内で
  開発中の対象で本ループを回すと、その commit はワークスペースのリポジトリ履歴に入る。
  Over-Project の cycle 内から挙動確認するときは通常 `once.sh` を使い、Over-Project の single-flight
  (I-018)の下で行うこと。本番運用は対象を独立リポジトリとして clone した先で行う。
- ハーネスは Claude Code の trust が前提である(未 trust なら loop.sh が起動を拒否する)。
- `schema.json` は instance の enforcement surface の一部であり、agent の編集は ask で守られる。
- 同じ理由で、**判定を実行しているエンジン自身** — `<loop_dir>/lean/`(同梱ソース)と
  `<loop_dir>/bin/`(ビルド済み `asl-loop`)— への agent の書込みも `scripts/` と同格の
  ask である。settings は既に sandbox `denyWrite` で両方を、permissions deny で `bin/**` を
  覆っているが、hook 自身が無意見だと「ハーネスの実行体をハーネスが何も言わずに
  書き換えられる」層が残るため、hook 側でも ask に揃えてある。
