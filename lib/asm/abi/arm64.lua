if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- ARM64 ABI register file for ra.allocate().
--
-- One calling convention:
--   aapcs64 — Procedure Call Standard for the Arm 64-bit Architecture
--             used on Linux, macOS (Apple Silicon), and Windows ARM.
--
-- GPR pool:
--   x0–x18   caller-saved (x16/x17 are intra-procedure-call scratch; included)
--   x19–x28  callee-saved
--   x29 (fp) and x30 (lr) excluded from allocation pool.
--   x31 is sp/xzr context-dependent; excluded.
--
-- SIMD pool:
--   v0–v7    caller-saved, arg/return registers
--   v8–v15   callee-saved (lower 64 bits per AAPCS64; upper 64 bits volatile)
--   v16–v31  caller-saved
--
-- Register aliases (bidirectional):
--   v_i is the canonical 128-bit name; q_i d_i s_i h_i b_i are width aliases.
--   ra.lua will block all width aliases when v_i is in use.

local M = {}

-- Build bidirectional aliases for v0–v31 ↔ q/d/s/h/b.
local function make_arm64_aliases()
  local aliases = {} --: { [string]: string, ... }
  local widths = { "q", "d", "s", "h", "b" }
  for i = 0, 31 do
    local vi = "v" .. i
    for _, w in ipairs(widths) do
      local wi = w .. i
      aliases[wi] = vi   -- narrow → canonical
      aliases[vi] = wi   -- canonical → narrow (last write wins; store one representative)
    end
  end
  -- Prefer q as the reverse alias since it is closest in width to v.
  -- Overwrite the v→? entry set above with the q alias (most natural pairing).
  for i = 0, 31 do
    aliases["v" .. i] = "q" .. i
  end
  return aliases
end

local arm64_aliases = make_arm64_aliases()

-- callee_saved table for all registers in the allocation pool.
local aapcs64_callee_saved = {} --: { [string]: boolean, ... }
do
  -- GPR: x0–x18 caller-saved, x19–x28 callee-saved.
  for i = 0, 18 do aapcs64_callee_saved["x" .. i] = false end
  for i = 19, 28 do aapcs64_callee_saved["x" .. i] = true  end

  -- SIMD: v0–v7 and v16–v31 caller-saved; v8–v15 callee-saved.
  for i = 0,  7  do aapcs64_callee_saved["v" .. i] = false end
  for i = 8,  15 do aapcs64_callee_saved["v" .. i] = true  end
  for i = 16, 31 do aapcs64_callee_saved["v" .. i] = false end
end

M.aapcs64 = {
  -- Caller-saved first so RA prefers them; callee-saved at the end.
  -- x29 (fp) and x30 (lr) deliberately excluded.
  gpr  = {
    "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
    "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
    "x16", "x17", "x18",
    "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28",
  },
  -- v0–v7 arg/return (caller-saved), v16–v31 caller-saved, v8–v15 callee-saved.
  simd = {
    "v0",  "v1",  "v2",  "v3",  "v4",  "v5",  "v6",  "v7",
    "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
    "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31",
    "v8",  "v9",  "v10", "v11", "v12", "v13", "v14", "v15",
  },

  callee_saved = aapcs64_callee_saved,
  aliases      = arm64_aliases,

  -- Calling convention metadata (used by emit/, not ra.lua).
  arg_gpr  = { "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7" },
  arg_simd = { "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7" },
  ret_gpr  = { "x0", "x1" },
  ret_simd = { "v0" },
}

return M
