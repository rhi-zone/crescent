if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T   = require("lib.test.assert")
local asm = require("lib.asm")
local ffi = require("ffi")

-- asm.compile wraps the full ir → ra → emit pipeline.
-- Tests are gated on architecture and CPU features.

-- ---------------------------------------------------------------------------
-- Error-path tests (architecture-independent)
-- ---------------------------------------------------------------------------

T.describe("asm.compile error paths", function()
  T.it("returns error when opts is not a table", function()
    local fn, err = asm.compile("bad", function() end)
    T.eq(fn, nil)
    T.ok(err ~= nil, "error returned")
  end)

  T.it("returns error when build_fn is not a function", function()
    local fn, err = asm.compile({ args = {}, ret = {}, ctype = "void(*)(void)" }, 42)
    T.eq(fn, nil)
    T.ok(err ~= nil, "error returned")
  end)

  T.it("returns error when ctype is missing", function()
    local fn, err = asm.compile({ args = {}, ret = {} }, function() end)
    T.eq(fn, nil)
    T.ok(err ~= nil, "error returned")
  end)

  T.it("wraps build_fn errors", function()
    local fn, err = asm.compile({ args = {}, ret = {}, ctype = "void(*)(void)" }, function()
      error("intentional error")
    end)
    T.eq(fn, nil)
    T.ok(err ~= nil, "error returned for thrown build_fn")
  end)
end)

-- ---------------------------------------------------------------------------
-- Functional tests (x86-64 + AVX only)
-- ---------------------------------------------------------------------------

if not jit or jit.arch ~= "x64" then
  T.describe("asm.compile functional", function()
    T.it("skipped: not x86-64", function()
      T.ok(true, "skipped on " .. tostring(jit and jit.arch or "unknown arch"))
    end)
  end)
  return
end

local cpu = require("lib.asm.cpu")
local have_avx = cpu.avx

T.describe("asm.compile no-op kernel", function()
  T.it("compiles and calls a no-op kernel", function()
    local fn, err = asm.compile(
      { args = {}, ret = {}, ctype = "void(*)(void)" },
      function(_k) end)
    T.ok(err == nil, "no error: " .. tostring(err))
    T.ok(fn ~= nil, "fn is not nil")
    if fn then fn() end  -- must not crash
  end)
end)

T.describe("asm.compile vmulps kernel", function()
  T.it("multiplies float[8] arrays via the high-level API", function()
    if not have_avx then
      T.skip("AVX not available on this CPU")
    end
    local fn, err = asm.compile(
      { args = { "ptr", "ptr", "ptr", "i64" }, ret = {},
        ctype = "void(*)(float*, float*, float*, int64_t)" },
      function(k)
        local dst = k:arg(1)
        local a   = k:arg(2)
        local b   = k:arg(3)
        local va  = k:vreg("f32x8")
        local vb  = k:vreg("f32x8")
        local vc  = k:vreg("f32x8")
        k:emit("load",  va, a, { imm = 0 })
        k:emit("load",  vb, b, { imm = 0 })
        k:emit("mul",   vc, va, vb)
        k:emit("store", dst, vc, { imm = 0 })
      end)
    T.ok(err == nil, "compile succeeded: " .. tostring(err))
    if fn == nil then return end

    local a_arr   = ffi.new("float[8]", { 1, 2, 3, 4, 5, 6, 7, 8 })
    local b_arr   = ffi.new("float[8]", { 2, 3, 4, 5, 6, 7, 8, 9 })
    local dst_arr = ffi.new("float[8]")
    fn(dst_arr, a_arr, b_arr, 8)
    for i = 0, 7 do
      T.eq(dst_arr[i], a_arr[i] * b_arr[i], "element " .. i)
    end
  end)
end)

T.describe("asm.compile vaddps kernel", function()
  T.it("adds float[8] arrays via the high-level API", function()
    if not have_avx then
      T.skip("AVX not available on this CPU")
    end
    local fn, err = asm.compile(
      { args = { "ptr", "ptr", "ptr" }, ret = {},
        ctype = "void(*)(float*, float*, float*)" },
      function(k)
        local dst = k:arg(1)
        local a   = k:arg(2)
        local b   = k:arg(3)
        local va  = k:vreg("f32x8")
        local vb  = k:vreg("f32x8")
        local vc  = k:vreg("f32x8")
        k:emit("load",  va, a, { imm = 0 })
        k:emit("load",  vb, b, { imm = 0 })
        k:emit("add",   vc, va, vb)
        k:emit("store", dst, vc, { imm = 0 })
      end)
    T.ok(err == nil, "compile succeeded: " .. tostring(err))
    if fn == nil then return end

    local a_arr   = ffi.new("float[8]", { 1, 2, 3, 4, 5, 6, 7, 8 })
    local b_arr   = ffi.new("float[8]", { 10, 20, 30, 40, 50, 60, 70, 80 })
    local dst_arr = ffi.new("float[8]")
    fn(dst_arr, a_arr, b_arr)
    for i = 0, 7 do
      T.eq(dst_arr[i], a_arr[i] + b_arr[i], "element " .. i)
    end
  end)
end)
