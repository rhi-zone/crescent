# Lua / LuaJIT gotchas

Language and runtime quirks that bite the unwary. Referenced from CLAUDE.md.

## LuaJIT is Lua 5.1 + extensions

Use `unpack(t)`, not `table.unpack(t)`. Do not shadow the built-in `assert` — in test files, bind the assertion library to a local (e.g. `local T = require("lib.test.assert")`).

## Table construction: all data fields go in the literal, methods go on a prototype

LuaJIT shapes tables at construction time. Fields present in the literal become part of the hidden class; adding fields afterward transitions to a new hidden class and breaks JIT monomorphic dispatch. The correct pattern:

```lua
-- data fields inline — JIT sees the full shape at construction
local obj = { insns = {}, args = {}, next_id = 0 }
-- methods on a shared prototype, not on the instance
setmetatable(obj, { __index = Proto })
```

All shape-defining fields belong in the literal. Post-construction field assignment (`obj.field = value` for initialization) defeats the hidden-class optimization and puts the field outside the typechecker's view.

## `local x = expr` — `x` is NOT in scope inside `expr`

In Lua, a local variable is not in scope within its own initializer expression. A closure created inside `expr` that references `x` will see a global (or nil), not the local being declared.

This matters whenever you want a callback/executor to reference the object being created:

```lua
-- WRONG: rt is a global lookup inside the executor (nil if no global)
local rt = N.runtime({ executors = { foo = function() rt:bar() end } })

-- CORRECT: pre-declare rt so the closure captures the local variable slot
local rt
rt = N.runtime({ executors = { foo = function() rt:bar() end } })
```

The same applies to test code that passes executors inline to a constructor. Always pre-declare the variable, then assign.
