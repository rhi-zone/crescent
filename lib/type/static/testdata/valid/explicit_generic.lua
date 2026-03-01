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
