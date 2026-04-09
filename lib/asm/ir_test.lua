if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T  = require("lib.test.assert")
local ir = require("lib.asm.ir")

-- ---------------------------------------------------------------------------
-- Helper: find interval by vreg id
-- ---------------------------------------------------------------------------
local function find_interval(intervals, id)
  for _, iv in ipairs(intervals) do
    if iv.id == id then return iv end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Type helpers
-- ---------------------------------------------------------------------------
T.describe("ir.is_simd", function()
  T.it("scalar types return false", function()
    T.ok(not ir.is_simd("i32"))
    T.ok(not ir.is_simd("f64"))
    T.ok(not ir.is_simd("ptr"))
  end)
  T.it("128-bit SIMD types return true", function()
    T.ok(ir.is_simd("i8x16"))
    T.ok(ir.is_simd("f32x4"))
    T.ok(ir.is_simd("f64x2"))
  end)
  T.it("256-bit SIMD types return true", function()
    T.ok(ir.is_simd("i8x32"))
    T.ok(ir.is_simd("f32x8"))
    T.ok(ir.is_simd("f64x4"))
  end)
end)

T.describe("ir.is_scalar", function()
  T.it("scalar types return true", function()
    T.ok(ir.is_scalar("i8"))
    T.ok(ir.is_scalar("i32"))
    T.ok(ir.is_scalar("f64"))
    T.ok(ir.is_scalar("ptr"))
  end)
  T.it("SIMD types return false", function()
    T.ok(not ir.is_scalar("i32x4"))
    T.ok(not ir.is_scalar("f32x8"))
  end)
end)

T.describe("ir.reg_class", function()
  T.it("gpr for scalar types", function()
    T.eq(ir.reg_class("i32"), "gpr")
    T.eq(ir.reg_class("f64"), "gpr")
    T.eq(ir.reg_class("ptr"), "gpr")
  end)
  T.it("simd for SIMD types", function()
    T.eq(ir.reg_class("i32x4"), "simd")
    T.eq(ir.reg_class("f32x8"), "simd")
    T.eq(ir.reg_class("i8x16"), "simd")
  end)
end)

T.describe("ir.type_width", function()
  T.it("scalar widths", function()
    T.eq(ir.type_width("i8"),  1)
    T.eq(ir.type_width("i16"), 2)
    T.eq(ir.type_width("i32"), 4)
    T.eq(ir.type_width("i64"), 8)
    T.eq(ir.type_width("f32"), 4)
    T.eq(ir.type_width("f64"), 8)
    T.eq(ir.type_width("ptr"), 8)
  end)
  T.it("128-bit SIMD widths", function()
    T.eq(ir.type_width("i32x4"),  16)
    T.eq(ir.type_width("f32x4"),  16)
    T.eq(ir.type_width("i8x16"),  16)
    T.eq(ir.type_width("f64x2"),  16)
  end)
  T.it("256-bit SIMD widths", function()
    T.eq(ir.type_width("f32x8"),  32)
    T.eq(ir.type_width("i8x32"),  32)
    T.eq(ir.type_width("i32x8"),  32)
    T.eq(ir.type_width("f64x4"),  32)
  end)
end)

-- ---------------------------------------------------------------------------
-- Empty kernel
-- ---------------------------------------------------------------------------
T.describe("empty kernel", function()
  T.it("finalizes with no instructions or intervals", function()
    local k = ir.kernel({}, {})
    local desc = k:finalize()
    T.eq(#desc.instructions, 0)
    T.eq(#desc.intervals,    0)
    T.eq(#desc.args,         0)
    T.eq(#desc.rets,         0)
    T.eq(desc.num_labels,    0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Single load + store
-- ---------------------------------------------------------------------------
T.describe("load and store", function()
  T.it("load produces an interval; store does not add a dst interval", function()
    local k   = ir.kernel({ "ptr", "ptr" }, {})
    local src = k:arg(1)
    local dst = k:arg(2)
    local v   = k:vreg("i32")
    k:emit("load",  v,   src)
    k:emit("store", dst, v)
    local desc = k:finalize()

    -- load: v is defined at instruction 1.
    -- store: dst is an arg (first=0), v is used at instruction 2.
    local iv_v = find_interval(desc.intervals, v.id)
    T.ok(iv_v ~= nil, "load result must have an interval")
    T.eq(iv_v.first, 1)
    -- v is used in store (insn 2).
    T.eq(iv_v.last, 2)

    -- Args are always present in intervals.
    local iv_src = find_interval(desc.intervals, src.id)
    T.ok(iv_src ~= nil)
    T.eq(iv_src.first, 0)

    -- store produces no dst vreg in the instruction.
    local store_insn = desc.instructions[2]
    T.eq(store_insn.op, "store")
    T.ok(store_insn.dst == nil, "store must have nil dst")
  end)
end)

-- ---------------------------------------------------------------------------
-- arg() gets first=0; vreg defined at 3, used at 7
-- ---------------------------------------------------------------------------
T.describe("interval boundaries", function()
  T.it("arg vregs have first=0", function()
    local k = ir.kernel({ "i64", "i64" }, {})
    local a = k:arg(1)
    local b = k:arg(2)
    -- emit some padding instructions so b is used late
    local tmp = k:vreg("i64")
    k:emit("add", tmp, a, b)  -- insn 1: tmp defined, a+b used
    -- 5 more dummy adds to push the index
    local t2 = k:vreg("i64"); k:emit("add", t2, tmp, ir.imm(1))  -- insn 2
    local t3 = k:vreg("i64"); k:emit("add", t3, t2,  ir.imm(1))  -- insn 3
    local t4 = k:vreg("i64"); k:emit("add", t4, t3,  ir.imm(1))  -- insn 4
    local t5 = k:vreg("i64"); k:emit("add", t5, t4,  ir.imm(1))  -- insn 5
    local t6 = k:vreg("i64"); k:emit("add", t6, t5,  ir.imm(1))  -- insn 6
    -- use b again at insn 7
    local t7 = k:vreg("i64"); k:emit("add", t7, t6, b)            -- insn 7

    local desc = k:finalize()

    local iv_a = find_interval(desc.intervals, a.id)
    T.eq(iv_a.first, 0, "arg a first=0")

    local iv_b = find_interval(desc.intervals, b.id)
    T.eq(iv_b.first, 0, "arg b first=0")
    T.eq(iv_b.last,  7, "arg b last=7 (used at insn 7)")
  end)

  T.it("non-arg vreg defined at 3, used at 7 → [3,7]", function()
    local k = ir.kernel({ "i64" }, {})
    local a = k:arg(1)
    -- emit 2 dummy instructions so vreg is defined at insn 3
    local d1 = k:vreg("i64"); k:emit("add", d1, a, ir.imm(0))  -- insn 1
    local d2 = k:vreg("i64"); k:emit("add", d2, a, ir.imm(0))  -- insn 2
    local v  = k:vreg("i64"); k:emit("add", v,  a, ir.imm(0))  -- insn 3: v defined
    -- 3 more insns before we use v
    local x1 = k:vreg("i64"); k:emit("add", x1, a, ir.imm(0))  -- insn 4
    local x2 = k:vreg("i64"); k:emit("add", x2, a, ir.imm(0))  -- insn 5
    local x3 = k:vreg("i64"); k:emit("add", x3, a, ir.imm(0))  -- insn 6
    local x4 = k:vreg("i64"); k:emit("add", x4, v, ir.imm(0))  -- insn 7: v used

    local desc = k:finalize()
    local iv_v = find_interval(desc.intervals, v.id)
    T.eq(iv_v.first, 3, "v defined at insn 3")
    T.eq(iv_v.last,  7, "v last-used at insn 7")
  end)
end)

-- ---------------------------------------------------------------------------
-- Unused vreg: last = first + 1
-- ---------------------------------------------------------------------------
T.describe("unused vreg", function()
  T.it("defined but never used gets last = first+1", function()
    local k   = ir.kernel({}, {})
    local v   = k:vreg("i32")
    local src = k:vreg("i32")
    -- define v at insn 1 (dst of add), but never use it again
    k:emit("add", v, ir.imm(1), ir.imm(2))  -- insn 1
    -- define src at insn 2 but never use
    k:emit("add", src, ir.imm(3), ir.imm(4))  -- insn 2

    local desc = k:finalize()
    local iv_v = find_interval(desc.intervals, v.id)
    T.eq(iv_v.first, 1)
    T.eq(iv_v.last,  2, "unused vreg: last = first+1 = 2")
  end)
end)

-- ---------------------------------------------------------------------------
-- Loop interval extension
-- ---------------------------------------------------------------------------
T.describe("loop liveness extension", function()
  T.it("vreg spanning loop body is extended to loop instruction index", function()
    local k = ir.kernel({ "i64", "i64" }, {})
    local a   = k:arg(1)
    local cnt = k:arg(2)
    local i   = k:vreg("i64")
    k:emit("add", i, a, ir.imm(0))  -- insn 1: i defined

    -- Loop header is at instruction 2.
    local lbl = k:label()          -- position = 2

    local tmp = k:vreg("i64")
    k:emit("add", tmp, i, ir.imm(1))  -- insn 2: tmp defined, i used inside body
    k:emit("cmp", i, cnt)             -- insn 3: i used
    k:loop(lbl)                        -- insn 4: loop backedge

    -- i is defined at 1, used at insns 2 and 3 (last_use=3 before extension).
    -- Loop header is at position 2, loop insn is at 4.
    -- i's interval spans the header (first=1 <= 2, last=3 >= 2) so last→4.
    local desc = k:finalize()
    local iv_i = find_interval(desc.intervals, i.id)
    T.ok(iv_i ~= nil, "i must have an interval")
    T.eq(iv_i.first, 1)
    T.eq(iv_i.last,  4, "i last extended to loop insn index 4")
  end)
end)

-- ---------------------------------------------------------------------------
-- finalize() returns correct args array
-- ---------------------------------------------------------------------------
T.describe("finalize args", function()
  T.it("args array matches kernel arg list in order", function()
    local k = ir.kernel({ "ptr", "i64", "f32" }, {})
    local desc = k:finalize()
    T.eq(#desc.args, 3)
    T.eq(desc.args[1].type, "ptr")
    T.eq(desc.args[2].type, "i64")
    T.eq(desc.args[3].type, "f32")
    -- vreg_ids must be distinct
    T.ok(desc.args[1].vreg_id ~= desc.args[2].vreg_id)
    T.ok(desc.args[2].vreg_id ~= desc.args[3].vreg_id)
  end)
end)

-- ---------------------------------------------------------------------------
-- Realistic kernel: dst[i] = a[i] * b[i] loop
-- ---------------------------------------------------------------------------
T.describe("realistic elementwise multiply loop", function()
  T.it("has correct instruction count, interval count, and arg count", function()
    -- Kernel: (dst_ptr, a_ptr, b_ptr, n) -> ()
    -- Body: load a[i], load b[i], mul, store dst[i], add i, cmp, loop
    local k   = ir.kernel({ "ptr", "ptr", "ptr", "i64" }, {})
    local dst = k:arg(1)
    local a   = k:arg(2)
    local b   = k:arg(3)
    local cnt = k:arg(4)

    local i = k:vreg("i64")
    k:emit("add", i, ir.imm(0), ir.imm(0))  -- insn 1: i = 0

    local lbl = k:label()                    -- loop header at insn 2

    local va = k:vreg("f32x8")
    local vb = k:vreg("f32x8")
    local vc = k:vreg("f32x8")

    k:emit("load",  va, a,   i)             -- insn 2
    k:emit("load",  vb, b,   i)             -- insn 3
    k:emit("mul",   vc, va,  vb)            -- insn 4
    k:emit("store", dst, vc, i)             -- insn 5
    k:emit("add",   i,  i,   ir.imm(32))   -- insn 6
    k:emit("cmp",   i,  cnt)                -- insn 7
    k:loop(lbl)                             -- insn 8

    local desc = k:finalize()

    -- 8 instructions total.
    T.eq(#desc.instructions, 8)

    -- 4 arg vregs + 4 body vregs = 8 intervals.
    T.eq(#desc.intervals, 8)

    -- 4 args.
    T.eq(#desc.args, 4)
    T.eq(desc.arg_types[1], "ptr")
    T.eq(desc.arg_types[4], "i64")

    -- Loop extends i's liveness to insn 8.
    local iv_i = find_interval(desc.intervals, i.id)
    T.ok(iv_i ~= nil)
    T.eq(iv_i.last, 8, "i must be live until loop insn 8")

    -- va is defined at insn 2, last used at insn 4 (mul operand).
    local iv_va = find_interval(desc.intervals, va.id)
    T.eq(iv_va.first, 2)
    T.eq(iv_va.last,  4)

    -- vc is defined at insn 4, used at insn 5.
    local iv_vc = find_interval(desc.intervals, vc.id)
    T.eq(iv_vc.first, 4)
    T.eq(iv_vc.last,  5)

    -- reg_class for f32x8 vregs should be simd.
    T.eq(iv_va.type, "simd")
    T.eq(iv_vc.type, "simd")

    -- reg_class for i64 vregs should be gpr.
    T.eq(iv_i.type, "gpr")
  end)
end)
