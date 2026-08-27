import Looper.Core.Text
import Looper.Core.Essence
import Looper.Core.ShellLex
import Looper.Core.Classify

/-!
`Looper.Core.Classify` 第 3 部 — 依存インストールゲート(META.md §11.2)の
純粋実装。旧 Python guard との等価性は差分ファザーで検証済み(§31.2-16)。

凍結した意味論(旧 pre_tool_guard.py「Dependency gate (§11.2)」節由来):

1. 信頼パッケージ判定 — 精選リスト(`TRUSTED_NPM` 等 4 エコシステム +
   scope / prefix)∪ ESSENCE.md の `deps:` 宣言。`trustedInstallPackage` が
   `_trusted_install_package` に対応。
2. トークン文法 5 種 — `_NPM_NAME` / `_NPM_VERSION` / `_PYPI_TOKEN` /
   `_CRATE_TOKEN` / `_GO_TOKEN` と、宣言名文法 3 種(`_PYPI_NAME` /
   `_CRATE_NAME` / `_GO_NAME`)。すべて全域アンカー(`^...$`)の ASCII
   文字クラス文法で、CPython `$` の「末尾ちょうど 1 個の `\n` の直前でも
   成立する」実挙動(`_npm_package("react\n") == "react\n"`、実測)まで写す。
3. `_install_argv` / `_materialization_argv` — argv 列上のインストール形状 /
   materialization 形状の判定(`python(3) -m pip` の正規化を含む)。
4. `install_allow_reason` の純粋部分 — `installGateShape`(`&&` 分割・
   シェルメタ検査・`cd` セグメント文法)+ `installAllowSegReason?`(shlex →
   materialization / 信頼インストール判定 → 理由文字列)。**`cd` 先の解決と
   許可ルート照合は IO の責務**(§31.4-4): 呼び出し側が `installGateShape` の
   `withCd` を解決してから `installAllowSegReason?` を呼ぶ。理由文字列は
   Python の f-string 出力とバイト一致(シャドー検証を正規化なし比較にする)。
5. `command_installs_dependencies` — `[;&|\n]+` セグメント × shlex
   (失敗時 `str.split()` 退避)× 形状判定の any。
6. `essence_declared_packages` のテキスト部分 — `deps:` 行
   (`^[ \t>*-]*deps:[ \t]*(.+)$` MULTILINE)のトークン列挙と正準化。
   ファイル読取・複数ルートの走査は IO の責務で、`essenceDeclaredInto` を
   ルートごとの本文で fold する。

正規表現 → 判定関数の等価根拠(バックトラック消去):
- 全文法がアンカー付きで、隣接する反復クラスと後続リテラルの先頭文字が
  互いに素(scope の `/`・バージョンの `@`・演算子の `=<>~!`・`deps:` の
  `d` はいずれも直前のクラスに含まれない)。よって貪欲一致 = 唯一の分割で、
  受理は最長 run の走査と同値。
- `_GO_TOKEN` の怠惰量指定子 `+?` は、名前クラスが `@` を含まないため
  受理言語に影響しない(名前 = 最初の `@` まで、が唯一の候補)。
- `_PYPI_TOKEN` の演算子選択肢はバージョンクラスが `=<>` を含むため
  どの選択肢を取っても残余条件が同値(`===` を先に取る Python の順序を
  そのまま写すが、受理は変わらない)。

方言差: **なし**。本弾の文字クラスはすべて ASCII リテラル(`\w` / `\b` /
`\d` 不使用)で、`\s` は `_CD_SEGMENT` のみ(`isPySpace` で一致)。#guard の
期待値はすべて CPython 3.14 実測。

拡張(post-M3、§31.2-45): Python 完全排除後の新規面としてエコシステム
`lean`(Lake / Reservoir)と、既存 4 エコシステムのツール追加
(bun / poetry / pipenv / `cargo install`・`cargo update` / `uv pip sync` /
`lake update`・`lake exe cache get`)を導入した。これらはバイト一致契約の
対象外(移行元の Python 実装が存在しない)。判定原則は §11.2 のまま:
auto-allow は「全パッケージ信頼済みの単一 install」と「パッケージを名指し
しない materialization」の 2 形だけで、追加ツールもこの 2 形へ写像する。
Lean には「新規依存を CLI で足す」コマンドが存在しない(require は
lakefile 編集 = manifest ask を通る)ため、`lake update <pkg>` の名指しは
既宣言依存の更新だが、保守側に倒して install ゲート(信頼判定)を通す。
-/

namespace Looper.Core.Classify

open Looper.Core.Prim (dropLit?)
open Looper.Core.Text (isPySpace pyStrip containsSub)

/-! ## エコシステムと宣言済みパッケージ集合 -/

/-- 依存インストールの 5 エコシステム(旧 4 種は Python 実装の文字列タグと
1:1、`lean` は post-M3 拡張 — モジュール頭注)。 -/
inductive Ecosystem where
  | npm | pypi | crates | go | lean
deriving BEq, Repr

/-- ecosystem 文字列(理由文字列・`deps:` プレフィクスに使用)。 -/
def Ecosystem.tag : Ecosystem → String
  | .npm => "npm"
  | .pypi => "pypi"
  | .crates => "crates"
  | .go => "go"
  | .lean => "lean"

/-- ESSENCE.md `deps:` 宣言由来の信頼パッケージ集合(エコシステム別・正準名)。
Python の `essence_declared_packages()` が返す dict に対応する。 -/
structure DeclaredPackages where
  npm : List String := []
  pypi : List String := []
  crates : List String := []
  go : List String := []
  lean : List String := []
deriving BEq, Repr

def DeclaredPackages.names (d : DeclaredPackages) : Ecosystem → List String
  | .npm => d.npm
  | .pypi => d.pypi
  | .crates => d.crates
  | .go => d.go
  | .lean => d.lean

private def DeclaredPackages.insert (d : DeclaredPackages) (eco : Ecosystem)
    (name : String) : DeclaredPackages :=
  if (d.names eco).contains name then d
  else match eco with
    | .npm => { d with npm := d.npm ++ [name] }
    | .pypi => { d with pypi := d.pypi ++ [name] }
    | .crates => { d with crates := d.crates ++ [name] }
    | .go => { d with go := d.go ++ [name] }
    | .lean => { d with lean := d.lean ++ [name] }

/-! ## 精選リスト(pre_tool_guard.py から逐語転記。人間は High-Risk Zone の
hook ソース編集でのみ拡張する — Lean 移行後も同じ統制が本ファイルに移る) -/

def trustedNpmScopes : List String := ["@types/"]

def trustedNpm : List String :=
  [ -- language / build toolchain
    "typescript", "tsx", "ts-node", "esbuild", "vite", "rollup", "webpack",
    "@vitejs/plugin-react", "@vitejs/plugin-vue", "tsup", "turbo",
    -- lint / format
    "eslint", "prettier", "@biomejs/biome", "oxlint", "eslint-config-prettier",
    "typescript-eslint", "@typescript-eslint/parser",
    "@typescript-eslint/eslint-plugin", "eslint-plugin-react",
    "eslint-plugin-react-hooks", "eslint-plugin-import",
    -- test
    "vitest", "@vitest/coverage-v8", "@vitest/ui", "jsdom", "happy-dom",
    "jest", "ts-jest", "supertest", "playwright", "@playwright/test",
    "@testing-library/react", "@testing-library/jest-dom",
    "@testing-library/user-event",
    -- frameworks / runtime staples
    "react", "react-dom", "react-router-dom", "next", "vue", "vue-router",
    "svelte", "express", "fastify", "hono",
    -- utility staples
    "zod", "axios", "lodash", "dayjs", "date-fns", "uuid", "nanoid", "dotenv",
    "cross-env", "commander", "yargs", "chalk", "pino", "winston",
    -- css toolchain
    "tailwindcss", "postcss", "autoprefixer", "sass",
    -- dev workflow
    "nodemon", "concurrently", "rimraf", "npm-run-all", "husky", "lint-staged",
    "prisma", "@prisma/client" ]

def trustedPypi : List String :=
  [ -- test / quality
    "pytest", "pytest-cov", "pytest-asyncio", "pytest-mock", "pytest-xdist",
    "hypothesis", "coverage", "ruff", "mypy", "black", "isort", "flake8",
    "pylint", "pre-commit", "tox",
    -- web / api
    "fastapi", "uvicorn", "starlette", "flask", "django", "requests", "httpx",
    "aiohttp",
    -- data / models
    "numpy", "pandas", "scipy", "matplotlib", "pydantic", "pydantic-settings",
    "sqlalchemy", "alembic",
    -- utility staples
    "python-dotenv", "pyyaml", "jinja2", "click", "typer", "rich", "tqdm",
    "orjson", "attrs", "structlog" ]

def trustedCrates : List String :=
  [ "serde", "serde-json", "tokio", "anyhow", "thiserror", "clap", "rand",
    "regex", "log", "env-logger", "tracing", "tracing-subscriber", "chrono",
    "itertools", "once-cell", "futures", "rayon", "tempfile", "criterion",
    "reqwest" ]

def trustedGoModules : List String :=
  [ "github.com/stretchr/testify", "github.com/spf13/cobra",
    "github.com/spf13/viper", "github.com/google/uuid",
    "github.com/gorilla/mux", "github.com/gin-gonic/gin",
    "github.com/rs/zerolog", "google.golang.org/grpc",
    "google.golang.org/protobuf" ]

def trustedGoPrefixes : List String := ["golang.org/x/"]

/-- Lake パッケージ名(`require` 宣言 / `lake update` の positional に現れる
名前。Reservoir の定番 — mathlib とその標準的な依存群 + 公式ツール)。
ドメイン固有の既定信頼は `Domain.trustedLeanExtra` が足す(D-19: allow 拡大
方向なので統合しない — 根拠を持たない側の床が理由なく下がる)。 -/
def trustedLean : List String :=
  [ "mathlib", "batteries", "aesop", "proofwidgets", "Qq", "importGraph",
    "LeanSearchClient", "plausible", "Cli", "doc-gen4" ]

/-! ## 文字クラスと `$` 特例(re 互換プリミティブ) -/

private def isAsciiAlnum (c : Char) : Bool :=
  ('A' ≤ c && c ≤ 'Z') || ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')

private def isAsciiDigit (c : Char) : Bool := '0' ≤ c && c ≤ '9'

/-- `$`(MULTILINE なし)の実挙動: 末尾がちょうど 1 個の `\n` ならそれを
剥いでから全域一致を取る(本弾の全クラスは `\n` を含まないため同値)。 -/
private def dropDollarNl (cs : List Char) : List Char :=
  match cs.reverse with
  | '\n' :: rest => rest.reverse
  | _ => cs

/-- 最初の `sep` で分割(`str.partition` の見つかった側)。 -/
private def splitAtFirst? (sep : Char) : List Char → Option (List Char × List Char)
  | [] => none
  | c :: cs =>
    if c == sep then some ([], cs)
    else (splitAtFirst? sep cs).map fun (l, r) => (c :: l, r)

/-- 最後の `sep` で分割(`str.rpartition` の見つかった側)。 -/
private def splitAtLast? (sep : Char) (cs : List Char) :
    Option (List Char × List Char) :=
  ((splitAtFirst? sep cs.reverse).map fun (l, r) => (r.reverse, l.reverse))

/-! ## トークン文法(すべて CPython `re` のアンカー付き文法の直訳) -/

/-- `[a-z0-9~]`(npm 名の先頭文字)。 -/
private def isNpmHead (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || isAsciiDigit c || c == '~'

/-- `[a-z0-9._~-]`(npm 名の後続文字)。 -/
private def isNpmNameChar (c : Char) : Bool :=
  isNpmHead c || c == '.' || c == '_' || c == '-'

private def npmNameCore : List Char → Bool
  | [] => false
  | c :: rest => isNpmHead c && rest.all isNpmNameChar

/-- `_NPM_NAME.match` 等価: `^(@[a-z0-9~][a-z0-9._~-]*/)?[a-z0-9~][a-z0-9._~-]*$`。
scope 部のクラスは `/` を含まないため、`@` 開始なら「最初の `/`」が唯一の
分割点(以降に `/` があれば名前部で不成立)。 -/
def isNpmName (s : String) : Bool :=
  match dropDollarNl s.toList with
  | '@' :: rest =>
    match splitAtFirst? '/' rest with
    | some (scope, name) => npmNameCore scope && npmNameCore name
    | none => false
  | cs => npmNameCore cs

/-- `[0-9A-Za-z.*+<>=~^-]`(npm バージョンの後続文字)。 -/
private def isNpmVerChar (c : Char) : Bool :=
  isAsciiAlnum c || c == '.' || c == '*' || c == '+' || c == '<' || c == '>'
    || c == '=' || c == '~' || c == '^' || c == '-'

/-- `[~^><=]`(npm バージョンの範囲演算子接頭辞)。 -/
private def isNpmRangeChar (c : Char) : Bool :=
  c == '~' || c == '^' || c == '>' || c == '<' || c == '='

/-- `_NPM_VERSION.match` 等価:
`^(latest|[~^><=]*[0-9xX*][0-9A-Za-z.*+<>=~^-]*)$`。接頭辞クラスと
`[0-9xX*]` は互いに素なので貪欲 dropWhile が唯一の分割。 -/
def isNpmVersionSpec (s : String) : Bool :=
  let cs := dropDollarNl s.toList
  cs == "latest".toList ||
    match cs.dropWhile isNpmRangeChar with
    | c :: tail =>
      (isAsciiDigit c || c == 'x' || c == 'X' || c == '*') && tail.all isNpmVerChar
    | [] => false

/-- `[A-Za-z0-9._-]`(PyPI 名の後続文字)。 -/
private def isPypiNameChar (c : Char) : Bool :=
  isAsciiAlnum c || c == '.' || c == '_' || c == '-'

/-- `[A-Za-z0-9._,-]`(PyPI extras の内容文字)。 -/
private def isPypiExtraChar (c : Char) : Bool := isPypiNameChar c || c == ','

/-- `[0-9A-Za-z.*+!,<>=-]`(PyPI バージョン指定の後続文字)。 -/
private def isPypiVerChar (c : Char) : Bool :=
  isAsciiAlnum c || c == '.' || c == '*' || c == '+' || c == '!' || c == ','
    || c == '<' || c == '>' || c == '=' || c == '-'

/-- PyPI の比較演算子(Python の選択肢順。バージョンクラスが `=<>` を含む
ため順序は受理に影響しない)。 -/
private def pypiOps : List String :=
  ["===", "==", ">=", "<=", "~=", "!=", ">", "<"]

private def pypiOpTail? (cs : List Char) : Option (List Char) :=
  pypiOps.firstM fun op => dropLit? cs op.toList

/-- `_PYPI_TOKEN.match` 等価:
`^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[A-Za-z0-9._,-]+\])?((===|==|...|<)[ver]*)?$`。
一致すれば group 1(名前部。`$` 特例の `\n` は含まれない)。 -/
def pypiTokenName? (s : String) : Option String :=
  match dropDollarNl s.toList with
  | [] => none
  | c :: rest =>
    if !isAsciiAlnum c then none
    else
      let nameTail := rest.takeWhile isPypiNameChar
      let name := String.ofList (c :: nameTail)
      let afterName := rest.dropWhile isPypiNameChar
      let afterExtras : Option (List Char) :=
        match afterName with
        | '[' :: es =>
          let content := es.takeWhile isPypiExtraChar
          match es.dropWhile isPypiExtraChar with
          | ']' :: tail => if content.isEmpty then none else some tail
          | _ => none
        | cs => some cs
      match afterExtras with
      | none => none
      | some [] => some name
      | some cs =>
        match pypiOpTail? cs with
        | some tail => if tail.all isPypiVerChar then some name else none
        | none => none

/-- `[A-Za-z0-9_-]`(crate 名の文字)。 -/
private def isCrateNameChar (c : Char) : Bool :=
  isAsciiAlnum c || c == '_' || c == '-'

/-- `[0-9A-Za-z.+-]`(crate バージョンの後続文字)。 -/
private def isCrateVerChar (c : Char) : Bool :=
  isAsciiAlnum c || c == '.' || c == '+' || c == '-'

/-- `_CRATE_TOKEN.match` 等価: `^([A-Za-z0-9_-]+)(@[0-9][0-9A-Za-z.+-]*)?$`。
一致すれば group 1。 -/
def crateTokenName? (s : String) : Option String :=
  let cs := dropDollarNl s.toList
  let name := cs.takeWhile isCrateNameChar
  if name.isEmpty then none
  else match cs.dropWhile isCrateNameChar with
    | [] => some (String.ofList name)
    | '@' :: d :: tail =>
      if isAsciiDigit d && tail.all isCrateVerChar then some (String.ofList name)
      else none
    | _ => none

/-- `[A-Za-z0-9./_-]`(go モジュール名の文字)。 -/
private def isGoNameChar (c : Char) : Bool :=
  isAsciiAlnum c || c == '.' || c == '/' || c == '_' || c == '-'

/-- `[0-9A-Za-z.+-]`(go バージョンの文字)。 -/
private def isGoVerChar (c : Char) : Bool := isCrateVerChar c

/-- `_GO_TOKEN.match` 等価: `^([A-Za-z0-9./_-]+?)(@[0-9A-Za-z.+-]+)?$`。
名前クラスが `@` を含まないため怠惰 `+?` でも「最初の `@` まで」が唯一の
候補(モジュール頭注)。一致すれば group 1。 -/
def goTokenName? (s : String) : Option String :=
  let cs := dropDollarNl s.toList
  let name := cs.takeWhile isGoNameChar
  if name.isEmpty then none
  else match cs.dropWhile isGoNameChar with
    | [] => some (String.ofList name)
    | '@' :: v => if !v.isEmpty && v.all isGoVerChar then some (String.ofList name)
                  else none
    | _ => none

/-- `_PYPI_NAME.match` 等価: `^[A-Za-z0-9][A-Za-z0-9._-]*$`。 -/
def isPypiName (s : String) : Bool :=
  match dropDollarNl s.toList with
  | c :: rest => isAsciiAlnum c && rest.all isPypiNameChar
  | [] => false

/-- `_CRATE_NAME.match` 等価: `^[A-Za-z0-9_-]+$`。 -/
def isCrateName (s : String) : Bool :=
  let cs := dropDollarNl s.toList
  !cs.isEmpty && cs.all isCrateNameChar

/-- `_GO_NAME.match` 等価: `^[A-Za-z0-9./_-]+$`。 -/
def isGoName (s : String) : Bool :=
  let cs := dropDollarNl s.toList
  !cs.isEmpty && cs.all isGoNameChar

/-- Lake パッケージ名 `^[A-Za-z0-9_-]+$`(crate 名と同クラス。post-M3 拡張 —
バージョン指定・URL・`/` scope は不成立)。一致すれば `$` 特例の `\n` を
剥いだ名前(既存文法と異なり生トークンを返さない — 新規面のため Python の
境界挙動を写す義務がない)。 -/
def leanTokenName? (s : String) : Option String :=
  let cs := dropDollarNl s.toList
  if !cs.isEmpty && cs.all isCrateNameChar then some (String.ofList cs) else none

/-! ## パッケージ名の抽出と正準化 -/

/-- Python `str.lower()` の ASCII 部分(対象文字列は上記 ASCII 文法を通過
済みのため全域一致)+ `str.replace("_", "-")`。 -/
private def canonPypi (s : String) : String :=
  String.ofList (s.toList.map fun c =>
    if 'A' ≤ c && c ≤ 'Z' then Char.ofNat (c.toNat + 32)
    else if c == '_' then '-' else c)

private def canonCrate (s : String) : String :=
  String.ofList (s.toList.map fun c => if c == '_' then '-' else c)

/-- `_npm_package(token)` 等価: scope 付きは**最後**の `@`(`rpartition`)、
素の名前は**最初**の `@`(`partition`)でバージョン指定を切り離し、指定が
空でなければ `_NPM_VERSION` を検査、名前は `_NPM_NAME` を検査して返す。
`token == "a@"` は spec が空文字列(falsy)になり検査を素通りする —
CPython 実測 `_npm_package("@s/p@") == "@s/p"` を含めて写す。 -/
def npmPackage? (token : String) : Option String :=
  let cs := token.toList
  let (name, spec) :=
    match cs with
    | '@' :: rest =>
      if rest.contains '@' then
        match splitAtLast? '@' rest with
        | some (n, sp) => ('@' :: n, sp)
        | none => (cs, [])
      else (cs, [])
    | _ =>
      match splitAtFirst? '@' cs with
      | some (n, sp) => (n, sp)
      | none => (cs, [])
  if !spec.isEmpty && !isNpmVersionSpec (String.ofList spec) then none
  else if !isNpmName (String.ofList name) then none
  else some (String.ofList name)

/-- `_declared_name(ecosystem, name)` 等価: `deps:` トークンの正準名。
プレーンなパッケージ名だけを受理する(バージョン指定・URL は不成立)。
`$` 特例により末尾 1 個の `\n` は名前に残ったまま返る(CPython 実測
`_declared_name("pypi", "A.B_c\n") == "a.b-c\n"`)— 実運用の呼び出しは
strip 済みトークンのみで、この境界は等価性のためだけに写す。 -/
def declaredName? : Ecosystem → String → Option String
  | .npm, name => if isNpmName name then some name else none
  | .pypi, name => if isPypiName name then some (canonPypi name) else none
  | .crates, name => if isCrateName name then some (canonCrate name) else none
  | .go, name => if isGoName name then some name else none
  | .lean, name => leanTokenName? name  -- 正準化なし(Lake 名は大小・`_`/`-` 有意)

/-- `_trusted_install_package(ecosystem, token, declared)` 等価: インストール
トークンが精選リスト上か ESSENCE 宣言済みなら true。 -/
def trustedInstallPackage (d : Domain) (declared : DeclaredPackages) :
    Ecosystem → String → Bool
  | .npm, token =>
    match npmPackage? token with
    | some name =>
      trustedNpm.contains name || trustedNpmScopes.any (name.startsWith ·)
        || declared.npm.contains name
    | none => false
  | .pypi, token =>
    match pypiTokenName? token with
    | some raw =>
      let name := canonPypi raw
      trustedPypi.contains name || declared.pypi.contains name
    | none => false
  | .crates, token =>
    match crateTokenName? token with
    | some raw =>
      let name := canonCrate raw
      trustedCrates.contains name || declared.crates.contains name
    | none => false
  | .go, token =>
    match goTokenName? token with
    | some name =>
      trustedGoModules.contains name || trustedGoPrefixes.any (name.startsWith ·)
        || declared.go.contains name
    | none => false
  | .lean, token =>
    match leanTokenName? token with
    | some name => trustedLean.contains name || d.trustedLeanExtra.contains name
      || declared.lean.contains name
    | none => false

/-! ## argv 形状判定 -/

/-- `_INSTALL_SUBCOMMANDS` の逐語転記 + post-M3 追加ツール(bun / poetry /
pipenv / `cargo install`・材料は §11.2 のまま / `lake update` — 頭注)。
`poetry install` / `pipenv install` / `bun install` は bare なら materialization
が先勝ちし(`installAllowSegReason?` の判定順)、ここは名指し形の受け皿。 -/
def installSubcommand? : String → String → Option Ecosystem
  | "npm", "install" | "npm", "i" | "npm", "add"
  | "pnpm", "add" | "pnpm", "install" | "pnpm", "i"
  | "yarn", "add"
  | "bun", "add" | "bun", "install" | "bun", "i" => some .npm
  | "pip", "install" | "pip3", "install"
  | "poetry", "add" | "poetry", "install"
  | "pipenv", "install" => some .pypi
  | "cargo", "add" | "cargo", "install" => some .crates
  | "go", "get" => some .go
  | "lake", "update" => some .lean
  | _, _ => none

/-- `_SAFE_INSTALL_FLAGS` の逐語転記 + post-M3 追加(npm の `-d` = bun の
dev 指定、crates の `--locked` = `cargo install --locked`)。 -/
def safeInstallFlags : Ecosystem → List String
  | .npm => ["-D", "--save-dev", "-E", "--save-exact", "--save", "--save-prod",
             "--save-peer", "--save-optional", "--dev", "--exact",
             "-w", "--workspace-root", "-d"]
  | .pypi => ["-U", "--upgrade", "--dev"]
  | .crates => ["--dev", "--build", "--locked"]
  | .go => ["-u", "-t"]
  | .lean => []

/-- `_MATERIALIZE_FLAGS` の逐語転記 + post-M3 追加(poetry の `--no-root` /
`--sync`、pipenv の `--deploy` — いずれも展開の決定論を強める方向のみ)。 -/
def materializeFlags : List String :=
  ["--frozen-lockfile", "--immutable", "--locked", "--frozen", "--offline",
   "--prefer-offline", "--ignore-scripts", "--no-audit", "--no-fund",
   "--no-optional", "--production", "--prod", "--no-dev", "--silent",
   "--no-root", "--sync", "--deploy"]

/-- `_MATERIALIZE_SUBCOMMANDS` の逐語転記 + post-M3 追加(`go mod`・pip 系・
`uv pip sync`・`lake exe cache get` は専用分岐)。`cargo update` /
`lake update` の bare 形は lockfile の再解決 = bare `npm install` と同型。 -/
private def isMaterializeSub (a b : String) : Bool :=
  match a, b with
  | "npm", "install" | "npm", "i" | "npm", "ci"
  | "pnpm", "install" | "pnpm", "i"
  | "yarn", "install"
  | "bun", "install" | "bun", "i"
  | "poetry", "install" | "poetry", "sync"
  | "pipenv", "install" | "pipenv", "sync"
  | "uv", "sync" | "cargo", "fetch" | "cargo", "update"
  | "lake", "update" => true
  | _, _ => false

/-- `python(3) -m pip ...`(4 要素以上)を `pip ...` に正規化(両判定共通の
前処理)。 -/
private def normalizePipArgv (argv : List String) : List String :=
  match argv with
  | py :: "-m" :: "pip" :: rest =>
    if (py == "python" || py == "python3") && !rest.isEmpty then "pip" :: rest
    else argv
  | _ => argv

/-- `_install_argv(argv)` 等価: インストールコマンドなら
(エコシステム, サブコマンド以降の残り引数)。 -/
def installArgv? (argv : List String) : Option (Ecosystem × List String) :=
  match normalizePipArgv argv with
  | "uv" :: "pip" :: "install" :: rest => some (.pypi, rest)
  | "uv" :: "add" :: rest => some (.pypi, rest)
  | a :: b :: rest => (installSubcommand? a b).map ((·, rest))
  | _ => none

/-- `pip install` の残り引数が requirements ファイル駆動のとき、そのファイル
名リスト(裸のパッケージ名・未知フラグ・値なし `-r` は不成立)。 -/
private def pipRequirementsFiles? : List String → Bool → List String →
    Option (List String)
  | [], true, _ => none
  | [], false, acc => if acc.isEmpty then none else some acc.reverse
  | t :: ts, true, acc => pipRequirementsFiles? ts false (t :: acc)
  | t :: ts, false, acc =>
    if t == "-r" || t == "--requirement" then pipRequirementsFiles? ts true acc
    else if t.startsWith "-" then
      if materializeFlags.contains t then pipRequirementsFiles? ts false acc
      else none
    else none

/-- `_materialization_argv(argv)` 等価: 既にゲート済みの manifest/lockfile を
展開するだけのコマンドなら、その人間可読ソース。パッケージを自ら名指しする
コマンド(= 依存の意思決定)は none で、ゲートに残る。 -/
def materializationArgv? (argv : List String) : Option String :=
  match normalizePipArgv argv with
  | a :: b :: rest =>
    if (a == "pip" || a == "pip3") && b == "install" then
      (pipRequirementsFiles? rest false []).bind fun files =>
        -- §11.2 安全論拠: materialization を auto-allow できるのは「展開する
        -- 依存が既に gate を通っている」からであり、その gate は当のファイルの
        -- **書込みが ask される**こと(`isAskPath`)に他ならない。エージェントが
        -- 自由に書ける名前(`evil.txt` 等)は書込み ask を通らないため、
        -- materialization でも auto-allow せず ask に落とす(`requirements*.txt`
        -- 等の宣言済み manifest だけが通る。2026-07-27 の bypass 凍結)。
        -- URL(`://`)は末尾が `/requirements.txt` だと isAskPath を通るので
        -- 別途弾く(取得元差し替えの回避)。
        if files.isEmpty || files.any (fun f => containsSub f "://")
            || !files.all isAskPath then none
        else some ("requirements file(s): " ++ String.intercalate ", " files)
    else if a == "go" && b == "mod" then
      if rest == ["download"] then some "go.mod" else none
    else if a == "uv" && b == "pip" then
      -- `uv pip sync <files>`: 位置引数のファイル群が pip `-r` と同型の
      -- 「既ゲート manifest の展開」(post-M3 拡張)。同じ §11.2 論拠で、各
      -- ファイルは書込みが ask される依存入力(`isAskPath`)でなければならない。
      match rest with
      | "sync" :: args =>
        let files := args.filter (fun t => !t.startsWith "-")
        let flags := args.filter (·.startsWith "-")
        if files.isEmpty then none
        else if flags.any (fun f => !materializeFlags.contains f) then none
        else if files.any (fun f => containsSub f "://") then none
        else if !files.all isAskPath then none
        else some ("requirements file(s): " ++ String.intercalate ", " files)
      | _ => none
    else if a == "lake" && b == "exe" then
      -- `lake exe cache get`(引数なし限定): manifest に固定済みの依存の
      -- ビルド済み olean を取得するだけ(post-M3 拡張)。
      if rest == ["cache", "get"] then
        some "the prebuilt Mathlib cache for dependencies already pinned in the manifest"
      else none
    else if isMaterializeSub a b then
      if rest.any (fun t => !t.startsWith "-") then none
      else if rest.any (fun t => !materializeFlags.contains t) then none
      else some "the manifest/lockfile already in the repository"
    else none
  | _ => none

/-! ## install_allow_reason の純粋部分 -/

/-- `_INSTALL_SHELL_META` = `[;&|<>`$\r\n]`(`&&` 分割後の各セグメントを検査
するため、複合シェル文法・リダイレクト・展開を一括で拒否する)。 -/
def installShellMetaChar (c : Char) : Bool :=
  c == ';' || c == '&' || c == '|' || c == '<' || c == '>' || c == '`'
    || c == '$' || c == '\r' || c == '\n'

/-- `_CD_SEGMENT.match` 等価: `^cd\s+(\S+)$`(strip 済み・シェルメタなしの
セグメントに適用されるため `$` の `\n` 特例は到達不能)。 -/
private def cdTarget? (seg : String) : Option String :=
  match dropLit? seg.toList "cd".toList with
  | none => none
  | some rest =>
    let tokStart := rest.dropWhile isPySpace
    if rest.length == tokStart.length then none  -- `\s+` は 1 文字以上
    else
      let tok := tokStart.takeWhile (fun c => !isPySpace c)
      if tok.isEmpty || tok.length != tokStart.length then none
      else some (String.ofList tok)

/-- `install_allow_reason` 前半の構造判定の結果。`withCd` の cd 先解決と
許可ルート(CONTROL_ROOT ∪ 登録 PROJECT_ROOT)照合は IO シェルの責務
(§11.2 の cd フェンス)。 -/
inductive InstallShape where
  | notGate
  | bare (seg : String)
  | withCd (cdTargetRaw : String) (seg : String)
deriving BEq, Repr

/-- `install_allow_reason(command)` の前半等価: `&&` で 1〜2 分割・strip・
全セグメント非空・シェルメタなし・2 分割時は先頭が `cd <target>` 単文。 -/
def installGateShape (command : String) : InstallShape :=
  let segments := (command.splitOn "&&").map pyStrip
  if segments.length > 2 || segments.any (· == "") then .notGate
  else if segments.any (fun s => s.toList.any installShellMetaChar) then .notGate
  else match segments with
    | [seg] => .bare seg
    | [cdSeg, seg] =>
      match cdTarget? cdSeg with
      | some target => .withCd target seg
      | none => .notGate
    | _ => .notGate

/-- `install_allow_reason` 後半等価: インストールセグメント 1 本を shlex →
materialization / 全パッケージ信頼済みインストールの順に判定し、auto-allow の
理由文字列(Python 出力とバイト一致)を返す。字句解析不能は none(Python の
`shlex.ValueError` → None と一致。退避なし)。 -/
def installAllowSegReason? (d : Domain) (declared : DeclaredPackages)
    (seg : String) :
    Option String :=
  match ShellLex.split seg with
  | .error _ => none
  | .ok rawArgv =>
    let argv := normalizeCommandArgv rawArgv
    match materializationArgv? argv with
    | some source =>
      some ("Materialization (META.md §11.2): installs " ++ source
        ++ ", naming no package of its own. The dependency set it expands was "
        ++ "already gated when the manifest was written (manifest edits ask).")
    | none =>
      match installArgv? argv with
      | none => none
      | some (eco, rest) =>
        let packages := rest.filter (fun t => !t.startsWith "-")
        let flags := rest.filter (·.startsWith "-")
        if packages.isEmpty then none
        else if flags.any (fun f => !(safeInstallFlags eco).contains f) then none
        else if packages.all (trustedInstallPackage d declared eco) then
          some ("Trusted dependency install (META.md §11.2): "
            ++ String.intercalate ", " packages ++ " (" ++ eco.tag
            ++ ") are all on the curated list or declared in the project's "
            ++ "ESSENCE.md; anything else still requires the human.")
        else none

/-! ## command_installs_dependencies -/

/-- `uv pip sync <args>` の**形**(auto-allow の可否とは独立)。

§11.2 は file 引数を取る 2 つの materialization —`pip install -r <file>` と
`uv pip sync <file>`— について、対象ファイルが「書込みが ask される依存入力」
でなければ「**ask に落とす**」と明示する。前者は `installArgv?` が
`pip install` として拾うので ask になるが、後者は `installArgv?`
(`uv pip install` / `uv add` のみ)にも、auto-allow に失敗した
`materializationArgv?`(files が `isAskPath` を満たさなければ none)にも載らず、
**無意見で素通り**していた。素通りは「エージェントが gate なしに書ける任意名の
ファイルが名指す未承認パッケージを、ゲートの教示なしに実体化できる形」であり、
`pip install -r evil.txt` と同じ bypass の別綴りである(2026-07-28 是正)。

`npm ci <pkg>` 等の「壊れた materialization」を意見なしのまま残す既存の裁定
(matrix G-030 の境界)とは性質が違う: あれは実効的な依存決定を成立させない
綴りだが、`uv pip sync <file>` は正当かつ実効的な install コマンドである。 -/
def isUvPipSyncShape (argv : List String) : Bool :=
  match argv with
  | "uv" :: "pip" :: "sync" :: _ => true
  | _ => false

/-- `command_installs_dependencies(command)` 等価: `[;&|\n]+` セグメントの
いずれかがインストール形状か materialization 形状なら true(shlex 失敗時は
Python 実装と同じ `str.split()` 退避 — `tokensLenient`)。ask 経路の判定で
あり、allow 経路(`installAllowSegReason?`)より広い網を張る。 -/
def commandInstallsDependencies (command : String) : Bool :=
  (Looper.Core.Text.runsOf
      (fun c => c != ';' && c != '&' && c != '|' && c != '\n') command).any
    fun seg =>
      let argv := normalizeCommandArgv (tokensLenient (String.ofList seg))
      !argv.isEmpty
        && ((installArgv? argv).isSome || (materializationArgv? argv).isSome
          || isUvPipSyncShape argv)

/-! ## ESSENCE `deps:` 宣言のテキスト解析 -/

/-- `str.strip("`")`: 先頭・末尾の連続バッククォートを除去。 -/
private def stripBackticks (s : String) : String :=
  let cs := s.toList.dropWhile (· == '`')
  String.ofList ((cs.reverse.dropWhile (· == '`')).reverse)

/-- `_ESSENCE_DEPS_LINE` の 1 行分: `^[ \t>*-]*deps:[ \t]*(.+)$`。接頭辞
クラスは `d` を含まないため貪欲 dropWhile が唯一の分割(モジュール頭注)。 -/
private def depsLinePayload? (line : String) : Option String :=
  let rest := line.toList.dropWhile fun c =>
    c == ' ' || c == '\t' || c == '>' || c == '*' || c == '-'
  match dropLit? rest "deps:".toList with
  | none => none
  | some r =>
    let payload := r.dropWhile (fun c => c == ' ' || c == '\t')
    if payload.isEmpty then none else some (String.ofList payload)

/-- `_ESSENCE_DEP_TOKEN.match` 等価 + post-M3 の `lean:`:
`^(npm|pypi|crates|go|lean):(.+)$`。 -/
private def depToken? (token : String) : Option (Ecosystem × String) :=
  [Ecosystem.npm, .pypi, .crates, .go, .lean].firstM fun eco =>
    match dropLit? token.toList (eco.tag ++ ":").toList with
    | some rest => if rest.isEmpty then none else some (eco, String.ofList rest)
    | none => none

/-- `essence_declared_packages()` の 1 テキスト分: `deps:` 行の各トークン
(`,` 区切り・strip・バッククォート剥ぎ)を正準化して集合へ足し込む。
MULTILINE の `^`/`$` は `\n` のみを行境界とするため分割は `splitOn "\n"`
(`str.splitlines` の境界 10 種ではない)。複数ルートの走査は IO 側が
本関数を fold する。 -/
def essenceDeclaredInto (d : DeclaredPackages) (text : String) :
    DeclaredPackages :=
  (Essence.semanticLines text).foldl
    (fun d line =>
      match depsLinePayload? line with
      | none => d
      | some payload =>
        (payload.splitOn ",").foldl
          (fun d raw =>
            let token := pyStrip (stripBackticks (pyStrip raw))
            match depToken? token with
            | none => d
            | some (eco, name) =>
              match declaredName? eco (pyStrip name) with
              | some canon => d.insert eco canon
              | none => d)
          d)
    d

/-- 単一テキストからの宣言集合(空集合からの `essenceDeclaredInto`)。 -/
def essenceDeclared (text : String) : DeclaredPackages :=
  essenceDeclaredInto {} text

/-! ## コンパイル時検査(期待値はすべて pre_tool_guard.py の実関数の
CPython 3.14 実測。方言差なし) -/

-- npmPackage?(partition/rpartition と空 spec の素通り)
#guard npmPackage? "react" == some "react"
#guard npmPackage? "react@18" == some "react"
#guard npmPackage? "react@" == some "react"
#guard npmPackage? "@types/node" == some "@types/node"
#guard npmPackage? "@types/node@1.2" == some "@types/node"
#guard npmPackage? "@scope/p@1@2" == none
#guard npmPackage? "a@1@2" == none
#guard npmPackage? "@a" == none
#guard npmPackage? "@a/b/c" == none
#guard npmPackage? "REACT" == none
#guard npmPackage? "lodash@latest" == some "lodash"
#guard npmPackage? "x@^1.2" == some "x"
#guard npmPackage? "x@>=1.0" == some "x"
#guard npmPackage? "x@*" == some "x"
#guard npmPackage? "x@1.x" == some "x"
#guard npmPackage? "a@=1" == some "a"
#guard npmPackage? "a@v1" == none
#guard npmPackage? "react\n" == some "react\n"
#guard npmPackage? "@types/node\n" == some "@types/node\n"
#guard npmPackage? "a@1\n" == some "a"
#guard npmPackage? "" == none
#guard npmPackage? "@" == none
#guard npmPackage? "a@latest@1" == none
#guard npmPackage? "@s/p@" == some "@s/p"

-- isNpmVersionSpec
#guard isNpmVersionSpec "latest" == true
#guard isNpmVersionSpec "latestx" == false
#guard isNpmVersionSpec "" == false
#guard isNpmVersionSpec "^1.2.3" == true
#guard isNpmVersionSpec ">=1.0" == true
#guard isNpmVersionSpec "*" == true
#guard isNpmVersionSpec "x" == true
#guard isNpmVersionSpec "X1" == true
#guard isNpmVersionSpec "=2" == true
#guard isNpmVersionSpec "<>1" == true
#guard isNpmVersionSpec "1.2.3-beta.1" == true
#guard isNpmVersionSpec "v1" == false
#guard isNpmVersionSpec "latest\n" == true
#guard isNpmVersionSpec "~^<>=1" == true

-- pypiTokenName?
#guard pypiTokenName? "requests" == some "requests"
#guard pypiTokenName? "requests==2.0" == some "requests"
#guard pypiTokenName? "Requests[socks]==2.*" == some "Requests"
#guard pypiTokenName? "a[b,c]>=1" == some "a"
#guard pypiTokenName? "a[]" == none
#guard pypiTokenName? "a==" == some "a"
#guard pypiTokenName? "a=1" == none
#guard pypiTokenName? "a===1.0" == some "a"
#guard pypiTokenName? "a~=1.0" == some "a"
#guard pypiTokenName? "a!=1,<2" == some "a"
#guard pypiTokenName? "_a" == none
#guard pypiTokenName? "a[b]c" == none
#guard pypiTokenName? "a\n" == some "a"
#guard pypiTokenName? "a[b]" == some "a"
#guard pypiTokenName? "a[b]==" == some "a"
#guard pypiTokenName? ".a" == none
#guard pypiTokenName? "a." == some "a."
#guard pypiTokenName? "a-b_c.d" == some "a-b_c.d"
#guard pypiTokenName? "a<2" == some "a"

-- crateTokenName? / goTokenName?
#guard crateTokenName? "serde" == some "serde"
#guard crateTokenName? "serde@1" == some "serde"
#guard crateTokenName? "serde@1.0.0-alpha+x" == some "serde"
#guard crateTokenName? "serde@x" == none
#guard crateTokenName? "serde@" == none
#guard crateTokenName? "serde_json@1" == some "serde_json"
#guard crateTokenName? "a@1@2" == none
#guard crateTokenName? "a@1\n" == some "a"
#guard crateTokenName? "-a@1" == some "-a"
#guard crateTokenName? "_" == some "_"
#guard goTokenName? "github.com/a/b" == some "github.com/a/b"
#guard goTokenName? "github.com/a/b@v1.2.3" == some "github.com/a/b"
#guard goTokenName? "a@1@2" == none
#guard goTokenName? "a@" == none
#guard goTokenName? "@v1" == none
#guard goTokenName? "golang.org/x/tools@latest" == some "golang.org/x/tools"
#guard goTokenName? "a@v1\n" == some "a"
#guard goTokenName? "a@v1+meta" == some "a"
#guard goTokenName? "a@v_1" == none

-- leanTokenName?(post-M3: `\n` 特例は剥いで返す)
#guard leanTokenName? "mathlib" == some "mathlib"
#guard leanTokenName? "doc-gen4" == some "doc-gen4"
#guard leanTokenName? "Qq" == some "Qq"
#guard leanTokenName? "mathlib\n" == some "mathlib"
#guard leanTokenName? "mathlib@1" == none
#guard leanTokenName? "a/b" == none
#guard leanTokenName? "" == none

-- declaredName?
#guard declaredName? .npm "react" == some "react"
#guard declaredName? .npm "@S/p" == none
#guard declaredName? .npm "@types/x" == some "@types/x"
#guard declaredName? .pypi "My_Pkg" == some "my-pkg"
#guard declaredName? .pypi "-a" == none
#guard declaredName? .crates "a_b" == some "a-b"
#guard declaredName? .crates "a.b" == none
#guard declaredName? .go "a/b" == some "a/b"
#guard declaredName? .go "a@1" == none
#guard declaredName? .npm "react\n" == some "react\n"
#guard declaredName? .pypi "A.B_c\n" == some "a.b-c\n"
#guard declaredName? .lean "Qq" == some "Qq"      -- 大小文字は正準化しない
#guard declaredName? .lean "a_b" == some "a_b"    -- `_`/`-` も有意
#guard declaredName? .lean "a.b" == none

-- trustedInstallPackage(精選リスト + 宣言)
private def declTest : DeclaredPackages :=
  { npm := ["leftpad"], pypi := ["my-pkg"], crates := ["foo-bar"],
    go := ["example.com/m"], lean := ["my-lake-dep"] }
#guard trustedInstallPackage Domain.fixture declTest .npm "react" == true
#guard trustedInstallPackage Domain.fixture declTest .npm "leftpad@1.0" == true
#guard trustedInstallPackage Domain.fixture declTest .npm "@types/node@20" == true
#guard trustedInstallPackage Domain.fixture declTest .npm "unknown" == false
#guard trustedInstallPackage Domain.fixture declTest .pypi "PyTest" == true
#guard trustedInstallPackage Domain.fixture declTest .pypi "My_Pkg==1.0" == true
#guard trustedInstallPackage Domain.fixture declTest .pypi "my_pkg[x]" == true
#guard trustedInstallPackage Domain.fixture declTest .crates "serde_json" == true
#guard trustedInstallPackage Domain.fixture declTest .crates "foo_bar@1" == true
#guard trustedInstallPackage Domain.fixture declTest .go "golang.org/x/tools" == true
#guard trustedInstallPackage Domain.fixture declTest .go "example.com/m@v1" == true
#guard trustedInstallPackage Domain.fixture declTest .go "example.com/mm" == false
#guard trustedInstallPackage Domain.fixture declTest .lean "mathlib" == true
#guard trustedInstallPackage Domain.fixture declTest .lean "my-lake-dep" == true
#guard trustedInstallPackage Domain.fixture declTest .lean "Mathlib" == false  -- 大小文字有意
#guard trustedInstallPackage Domain.fixture declTest .lean "unknown-dep" == false
-- ドメイン軸(D-19)は両方向に効く: 持つドメインだけが追加を信頼する
#guard trustedInstallPackage Domain.fixture declTest .lean "extra-lean"
  == false
#guard trustedInstallPackage Domain.fixtureRich declTest .lean "extra-lean"
  == true
#guard trustedInstallPackage Domain.fixtureRich declTest .lean "unknown-dep"
  == false

-- installArgv?
#guard installArgv? ["npm", "install", "react"] == some (.npm, ["react"])
#guard installArgv? ["npm", "i"] == some (.npm, [])
#guard installArgv? ["pnpm", "add", "-D", "x"] == some (.npm, ["-D", "x"])
#guard installArgv? ["pip", "install", "requests"] == some (.pypi, ["requests"])
#guard installArgv? ["python3", "-m", "pip", "install", "x"] == some (.pypi, ["x"])
#guard installArgv? ["python", "-m", "pip", "install"] == some (.pypi, [])
#guard installArgv? ["python3", "-m", "pip"] == none
#guard installArgv? ["uv", "pip", "install", "x", "y"] == some (.pypi, ["x", "y"])
#guard installArgv? ["uv", "add", "x"] == some (.pypi, ["x"])
#guard installArgv? ["uv", "pip", "x"] == none
#guard installArgv? ["cargo", "add", "serde"] == some (.crates, ["serde"])
#guard installArgv? ["go", "get", "x"] == some (.go, ["x"])
#guard installArgv? ["npm", "run", "x"] == none
#guard installArgv? [] == none
#guard installArgv? ["NPM", "install", "x"] == none
-- post-M3 追加ツール
#guard installArgv? ["bun", "add", "react"] == some (.npm, ["react"])
#guard installArgv? ["bun", "install", "react"] == some (.npm, ["react"])
#guard installArgv? ["poetry", "add", "pytest"] == some (.pypi, ["pytest"])
#guard installArgv? ["pipenv", "install", "requests"] == some (.pypi, ["requests"])
#guard installArgv? ["cargo", "install", "ripgrep"] == some (.crates, ["ripgrep"])
#guard installArgv? ["lake", "update", "mathlib"] == some (.lean, ["mathlib"])
#guard installArgv? ["lake", "build"] == none
#guard installArgv? ["deno", "add", "npm:zod"] == none  -- deno は対象外(頭注)

-- materializationArgv?
#guard materializationArgv? ["npm", "install"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["npm", "ci"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["npm", "install", "--production"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["npm", "install", "react"] == none
#guard materializationArgv? ["pnpm", "install", "--frozen-lockfile"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["uv", "sync"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["go", "mod", "download"] == some "go.mod"
#guard materializationArgv? ["go", "mod", "download", "x"] == none
#guard materializationArgv? ["go", "mod", "tidy"] == none
#guard materializationArgv? ["pip", "install", "-r", "requirements.txt"]
  == some "requirements file(s): requirements.txt"
#guard materializationArgv? ["pip", "install", "-r", "requirements.txt", "-r", "requirements-dev.txt"]
  == some "requirements file(s): requirements.txt, requirements-dev.txt"
#guard materializationArgv? ["pip", "install", "-r"] == none
#guard materializationArgv? ["pip", "install", "-r", "http://x/requirements.txt"] == none
#guard materializationArgv? ["pip", "install", "-r", "-x"] == none
#guard materializationArgv? ["pip", "install", "-r", "requirements.txt", "x"] == none
#guard materializationArgv? ["pip3", "install", "--requirement", "requirements.txt", "--no-audit"]
  == some "requirements file(s): requirements.txt"
#guard materializationArgv? ["pip", "install", "-r", "requirements.txt", "--upgrade"] == none
#guard materializationArgv? ["python3", "-m", "pip", "install", "-r", "requirements.txt"]
  == some "requirements file(s): requirements.txt"
-- §11.2 bypass 凍結(2026-07-27): 書込みが gate されない任意ファイルは
-- materialization でも auto-allow せず ask に落とす(isAskPath 偽 → none)。
#guard materializationArgv? ["pip", "install", "-r", "evil.txt"] == none
#guard materializationArgv? ["pip", "install", "-r", "notes/anything.md"] == none
#guard materializationArgv? ["pip3", "install", "--requirement", "/tmp/whatever"] == none
#guard materializationArgv? ["uv", "pip", "sync", "mystuff.lock"] == none
#guard materializationArgv? ["uv", "pip", "sync", "requirements.txt"]
  == some "requirements file(s): requirements.txt"
#guard materializationArgv? ["npm", "i", "-D"] == none
#guard materializationArgv? ["uv", "sync", "--locked"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["uv", "sync", "x"] == none
-- post-M3 追加ツール
#guard materializationArgv? ["bun", "install"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["bun", "install", "react"] == none
#guard materializationArgv? ["poetry", "install"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["poetry", "install", "--no-root"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["poetry", "sync"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["pipenv", "install"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["pipenv", "sync"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["pipenv", "install", "--deploy"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["cargo", "update"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["cargo", "update", "-p"] == none
#guard materializationArgv? ["lake", "update"]
  == some "the manifest/lockfile already in the repository"
#guard materializationArgv? ["lake", "update", "mathlib"] == none
#guard materializationArgv? ["lake", "exe", "cache", "get"]
  == some "the prebuilt Mathlib cache for dependencies already pinned in the manifest"
#guard materializationArgv? ["lake", "exe", "cache", "get", "Mathlib.Data.Nat"] == none
#guard materializationArgv? ["uv", "pip", "sync", "requirements.txt", "requirements-dev.txt", "--offline"]
  == some "requirements file(s): requirements.txt, requirements-dev.txt"
#guard materializationArgv? ["uv", "pip", "sync"] == none
#guard materializationArgv? ["uv", "pip", "sync", "https://x/requirements.txt"] == none
#guard materializationArgv? ["uv", "pip", "sync", "requirements.txt", "--upgrade"] == none
-- §11.2: 書込みが gate されないファイル名は ask（isAskPath 偽）
#guard materializationArgv? ["uv", "pip", "sync", "a.txt", "b.txt"] == none

-- installGateShape
#guard installGateShape "npm install react" == .bare "npm install react"
#guard installGateShape " npm  install   react " == .bare "npm  install   react"
#guard installGateShape "npm install react\n" == .bare "npm install react"
#guard installGateShape "cd /p && npm ci" == .withCd "/p" "npm ci"
#guard installGateShape "cd  /p && npm ci" == .withCd "/p" "npm ci"
#guard installGateShape "cd a b && npm ci" == .notGate
#guard installGateShape "cda && npm ci" == .notGate
#guard installGateShape "ls && npm ci" == .notGate
#guard installGateShape "&& npm ci" == .notGate
#guard installGateShape "npm ci &&" == .notGate
#guard installGateShape "a && b && c" == .notGate
#guard installGateShape "npm install react; ls" == .notGate
#guard installGateShape "npm install `x`" == .notGate
#guard installGateShape "npm install $X" == .notGate
#guard installGateShape "npm install react|cat" == .notGate
#guard installGateShape "npm install react > log" == .notGate

-- installAllowSegReason?(理由文字列のバイト一致まで検査)
#guard installAllowSegReason? Domain.fixture declTest "npm install react"
  == some ("Trusted dependency install (META.md §11.2): react (npm) are all "
    ++ "on the curated list or declared in the project's ESSENCE.md; anything "
    ++ "else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "npm install react vue"
  == some ("Trusted dependency install (META.md §11.2): react, vue (npm) are "
    ++ "all on the curated list or declared in the project's ESSENCE.md; "
    ++ "anything else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "npm install unknownpkg" == none
#guard installAllowSegReason? Domain.fixture declTest "npm install 'react'"
  == installAllowSegReason? Domain.fixture declTest "npm install react"
#guard installAllowSegReason? Domain.fixture declTest "npm install -D typescript"
  == some ("Trusted dependency install (META.md §11.2): typescript (npm) are "
    ++ "all on the curated list or declared in the project's ESSENCE.md; "
    ++ "anything else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "npm install --unknown react" == none
#guard installAllowSegReason? Domain.fixture declTest "npm install react@18"
  == some ("Trusted dependency install (META.md §11.2): react@18 (npm) are "
    ++ "all on the curated list or declared in the project's ESSENCE.md; "
    ++ "anything else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "npm install" -- materialization が先勝ち
  == some ("Materialization (META.md §11.2): installs the manifest/lockfile "
    ++ "already in the repository, naming no package of its own. The "
    ++ "dependency set it expands was already gated when the manifest was "
    ++ "written (manifest edits ask).")
#guard installAllowSegReason? Domain.fixture declTest "go mod download"
  == some ("Materialization (META.md §11.2): installs go.mod, naming no "
    ++ "package of its own. The dependency set it expands was already gated "
    ++ "when the manifest was written (manifest edits ask).")
#guard installAllowSegReason? Domain.fixture declTest "pip install -r requirements.txt"
  == some ("Materialization (META.md §11.2): installs requirements file(s): "
    ++ "requirements.txt, naming no package of its own. The dependency set it "
    ++ "expands was already gated when the manifest was written (manifest "
    ++ "edits ask).")
#guard installAllowSegReason? Domain.fixture declTest "uv add my_pkg"
  == some ("Trusted dependency install (META.md §11.2): my_pkg (pypi) are all "
    ++ "on the curated list or declared in the project's ESSENCE.md; anything "
    ++ "else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "npm install 'react" == none
-- post-M3 追加ツール(理由文字列は既存形をそのまま流用)
#guard installAllowSegReason? Domain.fixture declTest "lake update mathlib"
  == some ("Trusted dependency install (META.md §11.2): mathlib (lean) are all "
    ++ "on the curated list or declared in the project's ESSENCE.md; anything "
    ++ "else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "lake update my-lake-dep"
  == some ("Trusted dependency install (META.md §11.2): my-lake-dep (lean) are "
    ++ "all on the curated list or declared in the project's ESSENCE.md; "
    ++ "anything else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "lake update unknown-dep" == none
#guard installAllowSegReason? Domain.fixture declTest "lake update"  -- bare は materialization
  == some ("Materialization (META.md §11.2): installs the manifest/lockfile "
    ++ "already in the repository, naming no package of its own. The "
    ++ "dependency set it expands was already gated when the manifest was "
    ++ "written (manifest edits ask).")
#guard installAllowSegReason? Domain.fixture declTest "cargo install --locked ripgrep" == none
#guard installAllowSegReason? Domain.fixture declTest "poetry add pytest"
  == some ("Trusted dependency install (META.md §11.2): pytest (pypi) are all "
    ++ "on the curated list or declared in the project's ESSENCE.md; anything "
    ++ "else still requires the human.")
#guard installAllowSegReason? Domain.fixture declTest "bun add react"
  == some ("Trusted dependency install (META.md §11.2): react (npm) are all "
    ++ "on the curated list or declared in the project's ESSENCE.md; anything "
    ++ "else still requires the human.")

-- commandInstallsDependencies
#guard commandInstallsDependencies "npm install x" == true
#guard commandInstallsDependencies "ls; npm ci" == true
#guard commandInstallsDependencies "echo a | pip install x" == true
#guard commandInstallsDependencies "ls" == false
#guard commandInstallsDependencies "npm ci\ngo mod download" == true
#guard commandInstallsDependencies "echo 'npm install x'" == false
#guard commandInstallsDependencies "npm 'install x" == false
#guard commandInstallsDependencies "x && npm i" == true
#guard commandInstallsDependencies "uv sync" == true
#guard commandInstallsDependencies "uv add" == true
#guard commandInstallsDependencies "lake update mathlib" == true
#guard commandInstallsDependencies "lake exe cache get" == true
#guard commandInstallsDependencies "lake build" == false
#guard commandInstallsDependencies "bun install" == true
#guard commandInstallsDependencies "poetry add x" == true
#guard commandInstallsDependencies "pipenv sync" == true
#guard commandInstallsDependencies "cargo update" == true
#guard commandInstallsDependencies "cargo install ripgrep" == true
#guard commandInstallsDependencies "uv pip sync requirements.txt" == true
-- §11.2: 非 ask-path ファイル・URL・引数なしの `uv pip sync` も install 形
-- として捉える(auto-allow はしないので ask に落ちる。素通りさせない)
#guard commandInstallsDependencies "uv pip sync evil.txt" == true
#guard commandInstallsDependencies "uv pip sync deps/list.txt" == true
#guard commandInstallsDependencies "uv pip sync https://x/r.txt" == true
#guard commandInstallsDependencies "uv pip sync" == true
#guard commandInstallsDependencies "uv pip compile x.in" == false
#guard isUvPipSyncShape ["uv", "pip", "sync"] == true
#guard isUvPipSyncShape ["uv", "pip", "install", "x"] == false

-- essenceDeclared(接頭辞クラス・バッククォート剥ぎ・二重 strip・正準化)
#guard (essenceDeclared "deps: npm:leftpad").npm == ["leftpad"]
#guard (essenceDeclared "  - deps: npm:a, pypi:B_b")
  == { npm := ["a"], pypi := ["b-b"] }
#guard (essenceDeclared "> deps: crates:x_y").crates == ["x-y"]
#guard (essenceDeclared "*- deps: go:example.com/m").go == ["example.com/m"]
#guard (essenceDeclared "deps:npm:a").npm == ["a"]
#guard (essenceDeclared "deps: `npm:a`, ``pypi:b``")
  == { npm := ["a"], pypi := ["b"] }
#guard essenceDeclared "x deps: npm:a" == {}
#guard (essenceDeclared "deps: npm:a\ndeps: pypi:b")
  == { npm := ["a"], pypi := ["b"] }
#guard essenceDeclared "deps: a, npm:" == {}
#guard (essenceDeclared "deps: npm: a").npm == ["a"]
#guard (essenceDeclared "deps: npm:a,npm:a").npm == ["a"]
#guard essenceDeclared "deps:  " == {}
#guard essenceDeclared "deps: npm:A" == {}
#guard essenceDeclared "DEPS: npm:a" == {}
#guard (essenceDeclared "-deps: npm:a").npm == ["a"]
#guard (essenceDeclared "deps: unknown:x, npm:ok").npm == ["ok"]
#guard essenceDeclared "deps: npm:`a`" == {}
#guard essenceDeclared "deps: go:a@1" == {}
#guard essenceDeclared "deps: pypi:a==1" == {}
#guard (essenceDeclared "deps: lean:mathlib, lean:Qq").lean == ["mathlib", "Qq"]
#guard essenceDeclared "deps: lean:a@1" == {}
#guard (essenceDeclared "deps: lean:my_dep").lean == ["my_dep"]  -- 正準化なし
#guard essenceDeclared "<!-- deps: npm:hidden -->" == {}
#guard essenceDeclared "```\ndeps: npm:hidden\n```" == {}
#guard (essenceDeclared "<!-- deps: npm:hidden -->\ndeps: npm:live").npm == ["live"]

end Looper.Core.Classify
