-- lib/stb/init.lua
-- Tiered image decode and resize via stb_image / stb_image_resize2.
-- Tier order: vendored binary > system (libvips) > pure Lua.
-- Tier selected at load time via pcall; best available wins.
--
-- Public API:
--   M._tier   -> "vendored" | "system-vips" | "pure-lua"
--   M.decode(data, channels?) -> pixels, w, h, ch  OR  nil, errmsg
--   M.resize(pixels, src_w, src_h, dst_w, dst_h, channels) -> pixels  OR  nil, errmsg

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Platform detection ────────────────────────────────────────────────────────

local function detect_platform()
  -- jit is only available under LuaJIT.
  if not jit then return "unknown" end
  local os_name = jit.os
  local arch    = jit.arch
  if os_name == "Linux" then
    if arch == "x64"   then return "linux-x86_64"  end
    if arch == "arm64" then return "linux-aarch64"  end
  elseif os_name == "OSX" then
    if arch == "x64"   then return "macos-x86_64"   end
    if arch == "arm64" then return "macos-aarch64"   end
  elseif os_name == "Windows" then
    if arch == "x64"   then return "windows-x86_64"  end
  end
  return "unknown"
end

-- ── Script directory resolution ───────────────────────────────────────────────
-- debug.getinfo returns "@./lib/..." — strip "@" and normalize "./" prefix.

local function script_dir()
  local src = debug.getinfo(1, "S").source
  -- Strip leading "@"
  local path = src:gsub("^@", "")
  -- Normalize "./" prefix (debug.getinfo may return "@./lib/...")
  path = path:gsub("^%./", "")
  -- Strip filename to get directory.
  local dir = path:match("^(.*)/[^/]*$") or "."
  return dir
end

-- ── Tier 1: Vendored binary ───────────────────────────────────────────────────
-- Pre-compiled stb shared library committed to vendor/<platform>/.

local function try_vendored()
  local ffi = require("ffi")
  local plat = detect_platform()
  if plat == "unknown" then return false end

  local dir = script_dir()
  local ext
  if plat:match("^macos") then
    ext = "dylib"
  elseif plat:match("^windows") then
    ext = "dll"
  else
    ext = "so"
  end

  local lib_path = dir .. "/vendor/" .. plat .. "/stb." .. ext
  local ok, lib = pcall(ffi.load, lib_path)
  if not ok then return false end

  local bind = require("lib.stb.ffi")
  local api  = bind(lib)
  M.decode = api.decode
  M.resize = api.resize
  M._tier  = "vendored"
  return true
end

-- ── Tier 2: System (libvips) ──────────────────────────────────────────────────
-- Only attempted on Linux/macOS. Unreliable on NixOS without LD_LIBRARY_PATH.
-- TODO: implement full vips decode/resize wrappers when vendored binary is absent
--       and vips is confirmed available (e.g. CI with system vips installed).

local function try_system_vips()
  -- Only probe on Linux/macOS — vips is not practical on Windows.
  if jit and jit.os == "Windows" then return false end
  local ffi = require("ffi")
  local ok, _lib = pcall(ffi.load, "vips")
  if not ok then return false end

  M._tier = "system-vips"
  function M.decode(_data, _channels)
    return nil, "system-vips tier not yet implemented"
  end
  function M.resize(_pixels, _src_w, _src_h, _dst_w, _dst_h, _channels)
    return nil, "system-vips tier not yet implemented"
  end
  return true
end

-- ── Tier 3: Pure Lua fallback ─────────────────────────────────────────────────

local function use_pure_lua()
  local img = require("lib.stb.pure.image")
  local rsz = require("lib.stb.pure.resize")
  M.decode = img.decode
  M.resize = rsz.resize_nn
  M._tier  = "pure-lua"
  return true
end

-- ── Tier selection ────────────────────────────────────────────────────────────

local ok1 = pcall(try_vendored)
if not (ok1 and M._tier == "vendored") then
  local ok2 = pcall(try_system_vips)
  if not (ok2 and M._tier == "system-vips") then
    use_pure_lua()
  end
end

return M
