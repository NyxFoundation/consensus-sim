/-!
`Looper.Io.Env` — 実行環境の解決(IO シェル)。
-/

namespace Looper.Io.Env

/-- CONTROL_ROOT = 実行バイナリ(`CONTROL_ROOT/bin/<tool>`)の 2 つ上。
Python 実装の `Path(__file__).resolve()` 起点の相対配置
(hooks は 3 つ上、recipes/recipe_hash.py は 1 つ上)に対応する配置規約。 -/
def controlRoot? : IO (Option System.FilePath) := do
  let exe ← IO.appPath
  pure (exe.parent.bind (·.parent))

end Looper.Io.Env
