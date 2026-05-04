-- lib/asm/cpu.lua
-- CPU feature detection at load time.
-- Returns a table of boolean feature flags and cpu.arch.
--
-- x86-64: sse2, sse3, ssse3, sse4_1, sse4_2, avx, avx2, avx512f
-- ARM64:  neon (always true), sve, sve2
-- All:    arch = "x86_64" | "aarch64" | "unknown"

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi") --[[: any]]

local M = {}

local arch_jit = jit and jit.arch or "unknown"
local os_jit   = jit and jit.os   or "unknown"

-- Normalise jit.arch to crescent arch names.
if arch_jit == "x64" then
  M.arch = "x86_64"
elseif arch_jit == "arm64" then
  M.arch = "aarch64"
else
  M.arch = "unknown"
end

-- ── x86-64 feature names as they appear in /proc/cpuinfo and sysctlbyname ───

--:: X86Flags = { sse2: string, sse3: string, ssse3: string, sse4_1: string, sse4_2: string, avx: string, avx2: string, avx512f: string }

local X86_PROC_FLAGS = {
  sse2   = "sse2",
  sse3   = "sse3",
  ssse3  = "ssse3",
  sse4_1 = "sse4_1",
  sse4_2 = "sse4_2",
  avx    = "avx",
  avx2   = "avx2",
  avx512f = "avx512f",
}

local X86_SYSCTL_FLAGS = {
  sse2    = "hw.optional.sse2",
  sse3    = "hw.optional.sse3",
  ssse3   = "hw.optional.supplementalsse3",
  sse4_1  = "hw.optional.sse4_1",
  sse4_2  = "hw.optional.sse4_2",
  avx     = "hw.optional.avx1_0",
  avx2    = "hw.optional.avx2_0",
  avx512f = "hw.optional.avx512f",
}

local ARM_PROC_FLAGS = {
  neon = "asimd",
  sve  = "sve",
  sve2 = "sve2",
}

local ARM_SYSCTL_FLAGS = {
  neon = "hw.optional.arm64",  -- always true on Apple Silicon
  sve  = "hw.optional.arm.FEAT_SVE",
  sve2 = "hw.optional.arm.FEAT_SVE2",
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Parse /proc/cpuinfo and return a table of flag names set to true.
local function parse_proc_cpuinfo()
  local f = io.open("/proc/cpuinfo", "r")
  if not f then return nil end
  local flags = {}
  for line in f:lines() do
    -- Match "flags\t: ..." (x86) or "Features\t: ..." (ARM)
    local vals = line:match("^[Ff](?:lags|eatures)%s*:%s*(.+)$")
    if not vals then
      -- Also handle "flags\t:" with literal tab
      vals = line:match("^[Ff]lags%s*:%s*(.+)$") or line:match("^Features%s*:%s*(.+)$")
    end
    if vals then
      for flag in vals:gmatch("%S+") do
        flags[flag] = true
      end
      -- Only need the first matching CPU entry.
      break
    end
  end
  f:close()
  return flags
end

-- sysctlbyname — macOS only. Declared at module level so the typechecker can
-- see it via ffi.cdef processing. On Linux the symbol does not exist in libc;
-- sysctl_int is only called from detect_macos_* which only runs on OSX.
-- The ffi.C.sysctlbyname call is wrapped in pcall so that any missing-symbol
-- error on non-macOS systems is caught gracefully.
ffi.cdef [[
  int sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                   void *newp, size_t newlen);
]]

-- Returns the int32 value at the given sysctl name, or nil on failure.
local function sysctl_int(name)
  local val = ffi.new("int[1]", 0)
  local len = ffi.new("size_t[1]", ffi.sizeof("int"))
  local ok, ret = pcall(ffi.C.sysctlbyname, name, val, len, nil, 0)
  if not ok or ret ~= 0 then return nil end
  return tonumber(val[0])
end

-- ── Linux detection ───────────────────────────────────────────────────────────

local function detect_linux_x86()
  local flags = parse_proc_cpuinfo()
  if not flags then return end
  for feat, proc_name in pairs(X86_PROC_FLAGS) do
    M[feat] = flags[proc_name] == true
  end
end

local function detect_linux_arm()
  local flags = parse_proc_cpuinfo()
  -- neon is baseline for aarch64; fall back to true if /proc/cpuinfo missing.
  M.neon = true
  if not flags then return end
  -- ARM Linux uses "asimd" for NEON in /proc/cpuinfo.
  if flags["asimd"] ~= nil then
    M.neon = flags["asimd"] == true
  end
  M.sve  = flags["sve"]  == true
  M.sve2 = flags["sve2"] == true
end

-- ── macOS detection ───────────────────────────────────────────────────────────

local function detect_macos_x86()
  for feat, sysctl_name in pairs(X86_SYSCTL_FLAGS) do
    local v = sysctl_int(sysctl_name)
    M[feat] = not (v == nil or v == 0)
  end
end

local function detect_macos_arm()
  -- hw.optional.arm64 is always 1 on Apple Silicon → neon always true.
  M.neon = true
  for feat, sysctl_name in pairs(ARM_SYSCTL_FLAGS) do
    local v = sysctl_int(sysctl_name)
    M[feat] = not (v == nil or v == 0)
  end
  -- Guarantee neon = true even if sysctl lookup failed.
  M.neon = true
end

-- ── Windows: no detection yet ─────────────────────────────────────────────────

local function set_all_false_x86()
  for feat in pairs(X86_PROC_FLAGS) do M[feat] = false end
end

local function set_all_false_arm()
  M.neon = false
  M.sve  = false
  M.sve2 = false
end

-- ── Dispatch ─────────────────────────────────────────────────────────────────

-- Initialise all flags to false so every key is always a boolean.
set_all_false_x86()
set_all_false_arm()

if M.arch == "x86_64" then
  if os_jit == "Linux" then
    local ok, err = pcall(detect_linux_x86)
    if not ok then
      -- /proc/cpuinfo unreadable or parse error — safe defaults.
      set_all_false_x86()
      -- sse2 is baseline for x86-64; assume true.
      M.sse2 = true
    end
    -- sse2 is mandatory for x86-64; ensure it is never reported false.
    M.sse2 = true
  elseif os_jit == "OSX" then
    local ok = pcall(detect_macos_x86)
    if not ok then set_all_false_x86() end
    M.sse2 = true
  else
    -- Windows or unknown OS.
    set_all_false_x86()
    M.sse2 = true  -- x86-64 baseline
  end
elseif M.arch == "aarch64" then
  if os_jit == "Linux" then
    local ok = pcall(detect_linux_arm)
    if not ok then
      set_all_false_arm()
      M.neon = true
    end
  elseif os_jit == "OSX" then
    local ok = pcall(detect_macos_arm)
    if not ok then
      set_all_false_arm()
      M.neon = true
    end
  else
    set_all_false_arm()
    M.neon = true
  end
else
  -- Unknown arch: all false.
  set_all_false_x86()
  set_all_false_arm()
end

return M
