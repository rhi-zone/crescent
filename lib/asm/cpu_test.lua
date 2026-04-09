-- lib/asm/cpu_test.lua
-- Tests for CPU feature detection.
-- Cannot assert specific feature values (machine-dependent), but validates
-- module structure and invariants.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T   = require("lib.test.assert")
local cpu = require("lib.asm.cpu")

local VALID_ARCHS = { x86_64 = true, aarch64 = true, unknown = true }

local X86_FLAGS = { "sse2", "sse3", "ssse3", "sse4_1", "sse4_2", "avx", "avx2", "avx512f" }
local ARM_FLAGS = { "neon", "sve", "sve2" }

T.describe("cpu: module shape", function()
  T.it("loads and returns a table", function()
    T.eq(type(cpu), "table", "cpu is a table")
  end)

  T.it("arch is a valid string", function()
    T.eq(type(cpu.arch), "string", "cpu.arch is a string")
    T.ok(VALID_ARCHS[cpu.arch], "cpu.arch is one of x86_64, aarch64, unknown")
  end)
end)

T.describe("cpu: x86-64 flags", function()
  T.it("all x86 flags are boolean", function()
    for _, flag in ipairs(X86_FLAGS) do
      T.eq(type(cpu[flag]), "boolean", flag .. " is boolean")
    end
  end)

  T.it("sse2 is true on x86_64 (baseline requirement)", function()
    if cpu.arch == "x86_64" then
      T.ok(cpu.sse2, "sse2 must be true on x86_64")
    end
  end)
end)

T.describe("cpu: arm64 flags", function()
  T.it("all arm flags are boolean", function()
    for _, flag in ipairs(ARM_FLAGS) do
      T.eq(type(cpu[flag]), "boolean", flag .. " is boolean")
    end
  end)

  T.it("neon is true on aarch64 (baseline requirement)", function()
    if cpu.arch == "aarch64" then
      T.ok(cpu.neon, "neon must be true on aarch64")
    end
  end)
end)
