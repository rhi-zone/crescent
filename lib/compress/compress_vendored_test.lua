-- lib/compress/compress_vendored_test.lua
-- CI assertion: on platforms where dep/ ships a vendored libz, the
-- vendored tier must be the one that loads. This catches dep/
-- regressions without removing the runtime fallback to system zlib
-- (which is intentional — see CLAUDE.md "Don't degrade runtime to
-- surface CI gaps").

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local T = require("lib.test.assert")

-- Mirror lib/compress/system.lua's vendored_name() exactly.
local function expected_vendored_path()
  local os_, arch = ffi.os, ffi.arch
  if os_ == "Linux" then
    return arch == "arm64" and "dep/zlib/libz-linux-aarch64.so"
                           or  "dep/zlib/libz-linux-x86_64.so"
  elseif os_ == "OSX" then
    return arch == "arm64" and "dep/zlib/libz-macos-arm64.dylib" or nil
  elseif os_ == "Windows" then
    return arch == "x86" and "dep/zlib/zlib-x86.dll" or "dep/zlib/zlib-x64.dll"
  end
  return nil
end

T.describe("compress: vendored tier", function()
  local expected = expected_vendored_path()
  if not expected then
    T.it("platform has no vendored artifact (skipped)", function()
      T.ok(true, "no dep/ artifact for " .. tostring(ffi.os) .. "/" .. tostring(ffi.arch))
    end)
    return
  end

  local ok, sys = pcall(require, "lib.compress.system")
  if not ok then
    T.it("compress.system loads on a platform with a vendored artifact", function()
      error("lib.compress.system failed to load: " .. tostring(sys))
    end)
    return
  end

  T.it("_loaded_from equals the vendored dep/ path", function()
    T.eq(sys._loaded_from, expected)
  end)

  T.it("_tier is system-zlib", function()
    T.eq(sys._tier, "system-zlib")
  end)
end)
