-- Valid fixture: explicit generic annotation syntax <T>
-- Tests that <T>(T) -> T annotations create proper polymorphic functions.

-- Identity function: explicit generic annotation
--: <T>(T) -> T
local function identity(x)
  return x
end

-- Each call site gets an independent instantiation
local s = identity("hello")  --: string
local n = identity(42)       --: integer

-- Two-param generic: swap pair
--: <A, B>(A, B) -> (A, B)
local function swap(a, b)
  return b, a
end

-- Generic with table param
--: <T>({ value: T }) -> T
local function unwrap(box)
  return box.value
end

local v = unwrap({ value = "world" })

-- Generic with optional return
--: <T>(T[]) -> T | nil
local function first(arr)
  return arr[1]
end

-- Call-site explicit type args: --[[:<T, _>]] pre-binds type params before inference.
-- The annotation appears between the callee token and the opening (.
-- In Lua 5.1 / LuaJIT, ( cannot be on a new line from the callee (ambiguous call
-- syntax), so the annotation must share the callee's line.

--: <A, B>(A) -> B | nil
local function cast_or_nil(x)
  return nil
end

-- Explicit first arg, second inferred
local r1 = cast_or_nil --[[:<string, _>]] ("hello")
local r2 = cast_or_nil --[[:<integer, _>]] (42)
