if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T    = require("lib.test.assert")
local ir   = require("lib.asm.ir")
local ra   = require("lib.asm.ra")
local abi  = require("lib.asm.abi.x64")
local emit = require("lib.asm.emit.x64")
local ffi  = require("ffi")

-- Skip on non-x86-64.
if not jit or jit.arch ~= "x64" then
  T.describe("emit.x64", function()
    T.it("skipped: not x86-64", function()
      T.ok(true, "skipped on " .. tostring(jit and jit.arch or "unknown arch"))
    end)
  end)
  return
end

-- ---------------------------------------------------------------------------
-- Helper: compile a kernel and return the callable.
-- ---------------------------------------------------------------------------
local function compile_kernel(desc, regfile, abi_def, ctype)
  local alloc  = ra.allocate(desc.intervals, regfile)
  local fn, err = emit.compile(desc, alloc, abi_def, ctype)
  T.ok(err == nil, "compile succeeded (err=" .. tostring(err) .. ")")
  T.ok(fn ~= nil, "fn is not nil")
  return fn
end

-- ---------------------------------------------------------------------------
-- Test 1: smoke — no-op kernel
-- ---------------------------------------------------------------------------
T.describe("emit.x64 no-op kernel", function()
  T.it("compiles and calls without crashing", function()
    -- Kernel: no args, no instructions, no returns.
    local k    = ir.kernel({}, {})
    local desc = k:finalize()
    local fn   = compile_kernel(desc, abi.sysv, abi.sysv, "void(*)(void)")
    if fn then fn() end  -- must not crash
  end)
end)

-- ---------------------------------------------------------------------------
-- Test 2: arg pass-through — kernel that takes one i64 arg
-- The kernel has no body; the arg stays in the ABI return register only if we
-- arrange for that.  Instead we test that the kernel compiles cleanly and the
-- ptr value round-trips through without corruption on the stack.
-- (A true pass-through return requires the IR to express return values;
--  we verify the compiled code doesn't segfault when called with a pointer.)
-- ---------------------------------------------------------------------------
T.describe("emit.x64 arg pass-through", function()
  T.it("compiles a one-ptr-arg kernel and calls it", function()
    local k    = ir.kernel({ "ptr" }, {})
    local desc = k:finalize()
    -- ctype: function taking one pointer, returning void.
    local fn   = compile_kernel(desc, abi.sysv, abi.sysv, "void(*)(void*)")
    if fn then
      -- Pass a non-null pointer (stack address); must not crash.
      local dummy = ffi.new("int[1]", 42)
      fn(dummy)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Test 3: VMULPS kernel — element-wise multiply of two float[8] arrays
-- ---------------------------------------------------------------------------
T.describe("emit.x64 vmulps kernel", function()
  T.it("multiplies float[8] arrays correctly", function()
    -- Kernel: (dst: ptr, a: ptr, b: ptr, n: i64)
    -- Body: single iteration over 8 floats (no loop for simplicity).
    --   va  = load(a, 0)    → f32x8
    --   vb  = load(b, 0)    → f32x8
    --   vc  = mul(va, vb)   → f32x8
    --   store(dst, vc, 0)

    local k   = ir.kernel({ "ptr", "ptr", "ptr", "i64" }, {})
    local dst = k:arg(1)
    local a   = k:arg(2)
    local b   = k:arg(3)
    -- i64 arg (n) declared but not used in this single-shot test.

    local va = k:vreg("f32x8")
    local vb = k:vreg("f32x8")
    local vc = k:vreg("f32x8")

    k:emit("load", va, a, { imm = 0 })
    k:emit("load", vb, b, { imm = 0 })
    k:emit("mul",  vc, va, vb)
    k:emit("store", dst, vc, { imm = 0 })

    local desc = k:finalize()
    local fn   = compile_kernel(desc, abi.sysv, abi.sysv,
      "void(*)(float*, float*, float*, int64_t)")
    if fn == nil then return end

    local a_arr   = ffi.new("float[8]", {1, 2, 3, 4, 5, 6, 7, 8})
    local b_arr   = ffi.new("float[8]", {2, 3, 4, 5, 6, 7, 8, 9})
    local dst_arr = ffi.new("float[8]")
    local expected = {}
    for i = 0, 7 do
      expected[i] = a_arr[i] * b_arr[i]
    end

    fn(dst_arr, a_arr, b_arr, 8)

    for i = 0, 7 do
      T.eq(dst_arr[i], expected[i])
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Test 4: VADDPS kernel
-- ---------------------------------------------------------------------------
T.describe("emit.x64 vaddps kernel", function()
  T.it("adds float[8] arrays correctly", function()
    local k   = ir.kernel({ "ptr", "ptr", "ptr" }, {})
    local dst = k:arg(1)
    local a   = k:arg(2)
    local b   = k:arg(3)

    local va = k:vreg("f32x8")
    local vb = k:vreg("f32x8")
    local vc = k:vreg("f32x8")

    k:emit("load", va, a, { imm = 0 })
    k:emit("load", vb, b, { imm = 0 })
    k:emit("add",  vc, va, vb)
    k:emit("store", dst, vc, { imm = 0 })

    local desc = k:finalize()
    local fn   = compile_kernel(desc, abi.sysv, abi.sysv,
      "void(*)(float*, float*, float*)")
    if fn == nil then return end

    local a_arr   = ffi.new("float[8]", {10, 20, 30, 40, 50, 60, 70, 80})
    local b_arr   = ffi.new("float[8]", {1,  2,  3,  4,  5,  6,  7,  8})
    local dst_arr = ffi.new("float[8]")

    fn(dst_arr, a_arr, b_arr)

    for i = 0, 7 do
      T.eq(dst_arr[i], a_arr[i] + b_arr[i])
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Test 5: VMULPS loop kernel — element-wise multiply of float[N] arrays
-- ---------------------------------------------------------------------------
T.describe("emit.x64 vmulps loop kernel", function()
  T.it("multiplies 32-element float arrays with a loop", function()
    -- Kernel: (dst: ptr, a: ptr, b: ptr, n: i64)
    -- Loop: i = 0; while i < n: dst[i..i+8] = a[i..i+8] * b[i..i+8]; i += 32
    -- (n is in bytes; 8 floats = 32 bytes)

    local k     = ir.kernel({ "ptr", "ptr", "ptr", "i64" }, {})
    local dst   = k:arg(1)
    local a_arg = k:arg(2)
    local b_arg = k:arg(3)
    local n_arg = k:arg(4)

    -- Loop counter (byte offset).
    local i = k:vreg("i64")
    k:emit("mov", i, { imm = 0 })

    local loop_lbl = k:label()

    local va = k:vreg("f32x8")
    local vb = k:vreg("f32x8")
    local vc = k:vreg("f32x8")

    k:emit("load",  va, a_arg, { imm = 0 })
    k:emit("load",  vb, b_arg, { imm = 0 })
    k:emit("mul",   vc, va, vb)
    k:emit("store", dst, vc, { imm = 0 })

    -- Advance pointers by 32 bytes (8 floats × 4 bytes).
    k:emit("add", a_arg, a_arg, { imm = 32 })
    k:emit("add", b_arg, b_arg, { imm = 32 })
    k:emit("add", dst, dst, { imm = 32 })
    k:emit("add", i, i, { imm = 32 })
    k:emit("cmp", i, n_arg)
    k:loop(loop_lbl)

    local desc = k:finalize()
    local fn   = compile_kernel(desc, abi.sysv, abi.sysv,
      "void(*)(float*, float*, float*, int64_t)")
    if fn == nil then return end

    local N     = 32  -- elements (4 × 8)
    local a_arr = ffi.new("float[?]", N)
    local b_arr = ffi.new("float[?]", N)
    local d_arr = ffi.new("float[?]", N)
    for i2 = 0, N - 1 do
      a_arr[i2] = i2 + 1
      b_arr[i2] = (i2 + 1) * 2
    end

    -- n = total bytes for N floats.
    fn(d_arr, a_arr, b_arr, N * 4)

    local ok = true
    for i2 = 0, N - 1 do
      local expected = a_arr[i2] * b_arr[i2]
      if d_arr[i2] ~= expected then
        ok = false
        break
      end
    end
    T.ok(ok, "loop kernel produced correct results")
  end)
end)
