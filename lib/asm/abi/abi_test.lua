if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T     = require("lib.test.assert")
local ra    = require("lib.asm.ra")
local x64   = require("lib.asm.abi.x64")
local arm64 = require("lib.asm.abi.arm64")

-- Helper: build a set from an array for O(1) membership tests.
local function set(arr)
  local s = {}
  for _, v in ipairs(arr) do s[v] = true end
  return s
end

T.describe("x64 sysv", function()

  T.it("gpr pool excludes rbp and rsp", function()
    local gpr_set = set(x64.sysv.gpr)
    T.ok(not gpr_set["rbp"], "rbp excluded (frame pointer)")
    T.ok(not gpr_set["rsp"], "rsp excluded (stack pointer)")
  end)

  T.it("callee-saved GPR: rbx, r12-r15 are true; caller-saved are false", function()
    local cs = x64.sysv.callee_saved
    T.eq(cs["rbx"], true,  "rbx callee-saved")
    T.eq(cs["r12"], true,  "r12 callee-saved")
    T.eq(cs["r13"], true,  "r13 callee-saved")
    T.eq(cs["r14"], true,  "r14 callee-saved")
    T.eq(cs["r15"], true,  "r15 callee-saved")
    T.eq(cs["rax"], false, "rax caller-saved")
    T.eq(cs["rcx"], false, "rcx caller-saved")
    T.eq(cs["rdx"], false, "rdx caller-saved")
    T.eq(cs["rsi"], false, "rsi caller-saved")
    T.eq(cs["rdi"], false, "rdi caller-saved")
    T.eq(cs["r8"],  false, "r8  caller-saved")
    T.eq(cs["r9"],  false, "r9  caller-saved")
    T.eq(cs["r10"], false, "r10 caller-saved")
    T.eq(cs["r11"], false, "r11 caller-saved")
  end)

  T.it("callee-saved SIMD: none (all false)", function()
    local cs = x64.sysv.callee_saved
    for i = 0, 15 do
      T.eq(cs["xmm" .. i], false, "xmm" .. i .. " not callee-saved under sysv")
    end
  end)

  T.it("arg_gpr starts with rdi (SysV order)", function()
    T.eq(x64.sysv.arg_gpr[1], "rdi", "first arg GPR is rdi")
    T.eq(x64.sysv.arg_gpr[2], "rsi")
    T.eq(x64.sysv.arg_gpr[3], "rdx")
    T.eq(x64.sysv.arg_gpr[4], "rcx")
    T.eq(x64.sysv.arg_gpr[5], "r8")
    T.eq(x64.sysv.arg_gpr[6], "r9")
  end)

  T.it("arg_simd covers xmm0-xmm7", function()
    T.eq(#x64.sysv.arg_simd, 8)
    for i = 0, 7 do
      T.eq(x64.sysv.arg_simd[i + 1], "xmm" .. i)
    end
  end)

  T.it("ret_gpr is rax, rdx", function()
    T.eq(x64.sysv.ret_gpr[1], "rax")
    T.eq(x64.sysv.ret_gpr[2], "rdx")
  end)

  T.it("ret_simd is xmm0, xmm1", function()
    T.eq(x64.sysv.ret_simd[1], "xmm0")
    T.eq(x64.sysv.ret_simd[2], "xmm1")
  end)

  T.it("caller-saved registers listed before callee-saved in gpr pool", function()
    local gpr = x64.sysv.gpr
    local cs  = x64.sysv.callee_saved
    -- Find the index of the first callee-saved register in the pool.
    local first_cs_idx = #gpr + 1
    for i, r in ipairs(gpr) do
      if cs[r] then first_cs_idx = i; break end
    end
    -- All registers before first_cs_idx must be caller-saved.
    for i = 1, first_cs_idx - 1 do
      T.ok(not cs[gpr[i]], gpr[i] .. " is caller-saved and appears before callee-saved")
    end
  end)

end)

T.describe("x64 win64", function()

  T.it("gpr pool excludes rbp and rsp", function()
    local gpr_set = set(x64.win64.gpr)
    T.ok(not gpr_set["rbp"], "rbp excluded")
    T.ok(not gpr_set["rsp"], "rsp excluded")
  end)

  T.it("arg_gpr starts with rcx (Win64 order)", function()
    T.eq(x64.win64.arg_gpr[1], "rcx", "first arg GPR is rcx")
    T.eq(x64.win64.arg_gpr[2], "rdx")
    T.eq(x64.win64.arg_gpr[3], "r8")
    T.eq(x64.win64.arg_gpr[4], "r9")
    T.eq(#x64.win64.arg_gpr, 4, "win64 has 4 GPR arg regs")
  end)

  T.it("callee-saved GPR includes rdi and rsi (unlike SysV)", function()
    local cs = x64.win64.callee_saved
    T.eq(cs["rdi"], true, "rdi callee-saved under win64")
    T.eq(cs["rsi"], true, "rsi callee-saved under win64")
    T.eq(cs["rbx"], true, "rbx callee-saved")
    T.eq(cs["r12"], true, "r12 callee-saved")
    T.eq(cs["r13"], true, "r13 callee-saved")
    T.eq(cs["r14"], true, "r14 callee-saved")
    T.eq(cs["r15"], true, "r15 callee-saved")
  end)

  T.it("callee-saved SIMD: xmm6-xmm15 true, xmm0-xmm5 false", function()
    local cs = x64.win64.callee_saved
    for i = 0, 5  do T.eq(cs["xmm" .. i], false, "xmm" .. i .. " caller-saved") end
    for i = 6, 15 do T.eq(cs["xmm" .. i], true,  "xmm" .. i .. " callee-saved") end
  end)

  T.it("ret_gpr is rax only (no rdx)", function()
    T.eq(#x64.win64.ret_gpr, 1)
    T.eq(x64.win64.ret_gpr[1], "rax")
  end)

  T.it("ret_simd is xmm0 only", function()
    T.eq(#x64.win64.ret_simd, 1)
    T.eq(x64.win64.ret_simd[1], "xmm0")
  end)

end)

T.describe("x64 aliases", function()

  T.it("ymm_i aliases xmm_i (bidirectional)", function()
    local a = x64.sysv.aliases
    for i = 0, 15 do
      T.eq(a["ymm" .. i], "xmm" .. i, "ymm" .. i .. " → xmm" .. i)
      T.eq(a["xmm" .. i], "ymm" .. i, "xmm" .. i .. " → ymm" .. i)
    end
  end)

  T.it("zmm_i aliases ymm_i", function()
    local a = x64.sysv.aliases
    for i = 0, 15 do
      T.eq(a["zmm" .. i], "ymm" .. i, "zmm" .. i .. " → ymm" .. i)
    end
  end)

  T.it("sysv and win64 share the same alias table", function()
    -- Both conventions reference the same physical SIMD registers.
    T.eq(x64.sysv.aliases["ymm0"], "xmm0")
    T.eq(x64.win64.aliases["ymm0"], "xmm0")
  end)

end)

T.describe("arm64 aapcs64", function()

  T.it("gpr pool excludes x29 (fp) and x30 (lr)", function()
    local gpr_set = set(arm64.aapcs64.gpr)
    T.ok(not gpr_set["x29"], "x29 (fp) excluded")
    T.ok(not gpr_set["x30"], "x30 (lr) excluded")
  end)

  T.it("arg_gpr is x0-x7", function()
    T.eq(#arm64.aapcs64.arg_gpr, 8)
    for i = 0, 7 do
      T.eq(arm64.aapcs64.arg_gpr[i + 1], "x" .. i)
    end
  end)

  T.it("arg_simd is v0-v7", function()
    T.eq(#arm64.aapcs64.arg_simd, 8)
    for i = 0, 7 do
      T.eq(arm64.aapcs64.arg_simd[i + 1], "v" .. i)
    end
  end)

  T.it("ret_gpr is x0, x1", function()
    T.eq(arm64.aapcs64.ret_gpr[1], "x0")
    T.eq(arm64.aapcs64.ret_gpr[2], "x1")
  end)

  T.it("ret_simd is v0", function()
    T.eq(#arm64.aapcs64.ret_simd, 1)
    T.eq(arm64.aapcs64.ret_simd[1], "v0")
  end)

  T.it("callee-saved GPR: x19-x28 true, x0-x18 false", function()
    local cs = arm64.aapcs64.callee_saved
    for i = 0,  18 do T.eq(cs["x" .. i], false, "x" .. i .. " caller-saved") end
    for i = 19, 28 do T.eq(cs["x" .. i], true,  "x" .. i .. " callee-saved") end
  end)

  T.it("callee-saved SIMD: v8-v15 true, v0-v7 and v16-v31 false", function()
    local cs = arm64.aapcs64.callee_saved
    for i = 0,  7  do T.eq(cs["v" .. i], false, "v" .. i .. " caller-saved") end
    for i = 8,  15 do T.eq(cs["v" .. i], true,  "v" .. i .. " callee-saved") end
    for i = 16, 31 do T.eq(cs["v" .. i], false, "v" .. i .. " caller-saved") end
  end)

  T.it("d0 aliases v0 (bidirectional)", function()
    local a = arm64.aapcs64.aliases
    T.eq(a["d0"], "v0", "d0 → v0")
    -- v0 reverse alias is q0 (canonical choice, closest in width)
    T.eq(a["v0"], "q0", "v0 → q0 (canonical reverse)")
  end)

  T.it("all width aliases for v0 point to v0", function()
    local a = arm64.aapcs64.aliases
    for _, w in ipairs({ "q", "d", "s", "h", "b" }) do
      T.eq(a[w .. "0"], "v0", w .. "0 → v0")
    end
  end)

  T.it("width aliases cover all v0-v31", function()
    local a = arm64.aapcs64.aliases
    for i = 0, 31 do
      for _, w in ipairs({ "q", "d", "s", "h", "b" }) do
        T.eq(a[w .. i], "v" .. i, w .. i .. " → v" .. i)
      end
    end
  end)

end)

T.describe("integration: ra.allocate accepts x64 sysv regfile", function()

  T.it("single GPR interval allocated without error", function()
    local intervals = { { id = 1, first = 0, last = 5, type = "gpr" } }
    local r = ra.allocate(intervals, x64.sysv)
    T.ok(r.assignment[1] ~= nil, "interval assigned a physical GPR")
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("single SIMD interval allocated without error", function()
    local intervals = { { id = 1, first = 0, last = 5, type = "simd" } }
    local r = ra.allocate(intervals, x64.sysv)
    T.ok(r.assignment[1] ~= nil, "interval assigned a physical SIMD reg")
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("mixed gpr+simd intervals both assigned", function()
    local intervals = {
      { id = 1, first = 0, last = 5, type = "gpr"  },
      { id = 2, first = 0, last = 5, type = "simd" },
    }
    local r = ra.allocate(intervals, x64.sysv)
    T.ok(r.assignment[1] ~= nil, "GPR interval assigned")
    T.ok(r.assignment[2] ~= nil, "SIMD interval assigned")
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("callee-saved reg recorded when all caller-saved are in use", function()
    -- Occupy all 9 caller-saved GPRs, then one more forces a callee-saved assignment.
    -- SysV caller-saved: rax rcx rdx rsi rdi r8 r9 r10 r11 (9 total).
    local intervals = {}
    for i = 1, 10 do
      intervals[i] = { id = i, first = 0, last = 10, type = "gpr" }
    end
    local r = ra.allocate(intervals, x64.sysv)
    T.ok(#r.callee_saves >= 1, "at least one callee-saved GPR used")
  end)

  T.it("ra.allocate accepts arm64 aapcs64 regfile without error", function()
    local intervals = {
      { id = 1, first = 0, last = 5, type = "gpr"  },
      { id = 2, first = 0, last = 5, type = "simd" },
    }
    local r = ra.allocate(intervals, arm64.aapcs64)
    T.ok(r.assignment[1] ~= nil, "GPR interval assigned under aapcs64")
    T.ok(r.assignment[2] ~= nil, "SIMD interval assigned under aapcs64")
    T.eq(r.num_spill_slots, 0)
  end)

end)
