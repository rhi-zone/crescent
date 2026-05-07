-- lib/stb/build.lua
-- Compile stb headers into vendored platform binaries.
-- Developer/CI tool — NOT part of the load-time tier chain.
--
-- Usage:
--   luajit lib/stb/build.lua
--
-- Prerequisites:
--   Place stb_image.h, stb_image_resize2.h, stb_truetype.h in lib/stb/src/
--   Download from: https://github.com/nothings/stb

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- ── Locate script directory ───────────────────────────────────────────────────

local src = debug.getinfo(1, "S").source --[[:! string]]
local path = src:gsub("^@", ""):gsub("^%./", "")
local script_dir = path:match("^(.*)/[^/]*$") or "."

-- ── Check prerequisites ───────────────────────────────────────────────────────

local required_headers = {
  "stb_image.h",
  "stb_image_resize2.h",
  "stb_truetype.h",
}

local missing = {}
for _, h in ipairs(required_headers) do
  local f = io.open(script_dir .. "/src/" .. h, "r")
  if not f then
    missing[#missing + 1] = h
  else
    f:close()
  end
end

if #missing > 0 then
  io.stderr:write("Missing stb headers in " .. script_dir .. "/src/:\n")
  for _, h in ipairs(missing) do
    io.stderr:write("  " .. h .. "\n")
  end
  io.stderr:write("\nDownload from: https://github.com/nothings/stb\n")
  io.stderr:write("Place the .h files in: " .. script_dir .. "/src/\n")
  io.stderr:write("Then re-run: luajit lib/stb/build.lua\n")
  os.exit(1)
end

-- ── Platform detection ────────────────────────────────────────────────────────

--: () -> (string, string, string)
local function detect_platform() --[[FALLTHROUGH unreachable]]
  if not jit then
    io.stderr:write("build.lua requires LuaJIT (jit global not available)\n")
    os.exit(1)
  end
  local os_name = jit.os
  local arch    = jit.arch
  if os_name == "Linux" then
    if arch == "x64"   then return "linux-x86_64",   "so",     "Linux"   end
    if arch == "arm64" then return "linux-aarch64",   "so",     "Linux"   end
  elseif os_name == "OSX" then
    if arch == "x64"   then return "macos-x86_64",   "dylib",  "macOS"   end
    if arch == "arm64" then return "macos-aarch64",   "dylib",  "macOS"   end
  elseif os_name == "Windows" then
    -- Windows cross-compile via MSVC or MinGW is not automated here.
    io.stderr:write("Windows build is not yet automated by build.lua.\n")
    io.stderr:write("Use a MinGW cross-compiler or MSVC to produce stb.dll manually.\n")
    os.exit(1)
  end
  io.stderr:write("Unsupported platform: " .. tostring(os_name) .. " / " .. tostring(arch) .. "\n")
  os.exit(1)
  error("unreachable")
end

local plat, ext, plat_name = detect_platform()

-- ── Detect C compiler ─────────────────────────────────────────────────────────

--: () -> string | nil
local function find_cc()
  local candidates = { "cc", "gcc", "clang" }
  for _, cc in ipairs(candidates) do
    -- `which` returns exit 0 on success; os.execute returns true on success in LuaJIT.
    local ok = os.execute("which " .. cc .. " >/dev/null 2>&1")
    if ok == true or ok == 0 then
      return cc
    end
  end
  return nil
end

local cc = find_cc()
if not cc then
  io.stderr:write("No C compiler found. Install cc, gcc, or clang.\n")
  os.exit(1)
end
local _ = cc --[[:! string]]
cc = _

io.write("Compiler: " .. cc .. "\n")
io.write("Platform: " .. plat .. " (" .. plat_name .. ")\n")

-- ── Build ─────────────────────────────────────────────────────────────────────

local out_dir  = script_dir .. "/vendor/" .. plat
local out_file = out_dir .. "/stb." .. ext

-- Ensure output directory exists.
os.execute("mkdir -p " .. out_dir)

-- Build the shared library from stdin via a heredoc-style approach.
-- We pass the source on stdin using a temporary file to remain portable.

local tmp_c = os.tmpname() .. ".c"
do
  local f0 = io.open(tmp_c, "w")
  if not f0 then error("failed to open " .. tmp_c) end
  local f = f0 --[[:! { close: (any) -> (boolean | nil, string | nil), flush: (any) -> (boolean | nil, string | nil), lines: (any) -> () -> string | nil, read: (any, ...string | number) -> string | nil, seek: (any, string | nil, integer | nil) -> (integer | nil, string | nil), setvbuf: (any, string, integer | nil) -> (boolean | nil, string | nil), write: (any, ...string | number) -> (any, string | nil) }]]
  f:write('#define STB_IMAGE_IMPLEMENTATION\n')
  f:write('#define STB_IMAGE_RESIZE2_IMPLEMENTATION\n')
  f:write('#define STB_TRUETYPE_IMPLEMENTATION\n')
  f:write('#include "' .. script_dir .. '/src/stb_image.h"\n')
  f:write('#include "' .. script_dir .. '/src/stb_image_resize2.h"\n')
  f:write('#include "' .. script_dir .. '/src/stb_truetype.h"\n')
  f:close()
end

local compile_flags
if plat_name == "macOS" then
  compile_flags = "-O2 -dynamiclib -fPIC"
else
  compile_flags = "-O2 -shared -fPIC"
end

local cmd = table.concat({
  cc,
  compile_flags,
  "-o", out_file,
  tmp_c,
  "-lm",
}, " ")

io.write("Compiling: " .. cmd .. "\n")
local rc = os.execute(cmd)
os.remove(tmp_c)

if rc == true or rc == 0 then
  io.write("Success: " .. out_file .. "\n")
else
  io.stderr:write("Compilation failed (exit code " .. tostring(rc) .. ")\n")
  os.exit(1)
end
