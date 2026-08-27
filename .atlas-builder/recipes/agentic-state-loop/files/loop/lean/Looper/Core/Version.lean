/-!
このモジュールは純粋コア層であり、`IO`・`partial`・`unsafe`・`extern` を一切含めない
(この規約は CI が字句検査する)。バージョン文字列という単純な純粋定義のみを提供する。
-/

namespace Looper.Core

def versionString : String := "1.0.0"

end Looper.Core
