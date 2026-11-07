import Lean

/-! `@[leanjs_stack_safe]`: the declaration's recursion uses the JavaScript stack only as deep
as its data's shape (a view tree, a batch of commands), not as long as its input. LeanJS then
emits it without the stack-recursion note. Portable code may import this module: it registers
the attribute only and has no compiler dependency. -/

namespace LeanJS
open Lean

initialize stackSafeAttr : TagAttribute ←
  registerTagAttribute `leanjs_stack_safe
    "LeanJS: recursion bounded by the data's shape; do not report it as stack recursion"

end LeanJS
