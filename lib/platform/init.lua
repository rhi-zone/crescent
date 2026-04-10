-- lib/platform/init.lua
-- Platform runner: load a card (PNG file), extract its script chunk, run sandboxed.
--
-- A "card" is a PNG file with:
--   "script" tEXt chunk — Lua code to run (required)
--   "data"   tEXt chunk — structured content the script reads via caps.png (optional)
--   any other tEXt/zTXt chunks the script declares it needs
--
-- API:
--   platform.load_card(path)          -> card | nil, err
--   platform.run_card(card, env, opts?) -> ok, result | err
--   platform.load_and_run(path, env, opts?) -> ok, result | err
--   platform.caps.png                 -> require("lib.platform.caps.png")
--   platform.caps.llm                 -> require("lib.platform.caps.llm")
--   platform.caps.render              -> require("lib.platform.caps.render")
--   platform.caps.fs                  -> require("lib.platform.caps.fs")
--
-- card fields:
--   card.path   : string
--   card.chunks : png chunk array  (pass to png_cap if the script needs chunk access)
--   card.script : string           (the Lua source from "script" tEXt chunk)
--   card.data   : string | nil     (from "data" tEXt chunk, if present)
--
-- Typical usage:
--   local platform = require("lib.platform")
--   local sandbox  = require("lib.sandbox")
--   local render   = require("lib.platform.caps.render")
--   local llm_mod  = require("lib.platform.caps.llm")
--
--   local session, get_output = render.collect_session()
--   local env = sandbox.env(
--     sandbox.stdlib,
--     { globals = {
--       llm    = llm_mod.llm_cap({ endpoint = "http://localhost:8000", model = "gemma3" }),
--       render = render.render_cap(session),
--       png    = require("lib.platform.caps.png").png_cap(path, { allow = {"chara","crescent"} }),
--     }}
--   )
--   local ok, result = platform.load_and_run("card.png", env)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local png     = require("lib.png")
local sandbox = require("lib.sandbox")

local M = {}

-- load_card(path) -> card | nil, err
-- Reads a PNG file and extracts the script (required) and data (optional) chunks.
function M.load_card(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, "platform: cannot open " .. tostring(path) .. ": " .. tostring(err) end
	local bytes = f:read("*a")
	f:close()

	local chunks, perr = png.read(bytes)
	if not chunks then return nil, "platform: PNG parse failed: " .. tostring(perr) end

	local script = png.get_text(chunks, "script")
	if not script then return nil, "platform: card has no 'script' tEXt chunk" end

	return {
		path   = path,
		chunks = chunks,
		script = script,
		data   = png.get_text(chunks, "data"),
	}
end

-- run_card(card, env, opts?) -> ok, result | err
-- Runs card.script inside the given sandbox environment.
-- opts.budget: instruction limit (via debug.sethook)
-- opts.name  : chunk name in error messages (default "@<path>")
function M.run_card(card, env, opts)
	opts = opts or {}
	opts.name = opts.name or ("@" .. tostring(card.path))
	return sandbox.run(card.script, env, opts)
end

-- load_and_run(path, env, opts?) -> ok, result | err
-- Convenience: load_card + run_card in one call.
function M.load_and_run(path, env, opts)
	local card, err = M.load_card(path)
	if not card then return false, err end
	-- FIXME: typechecker: does not narrow `card` to non-nil in function call
	-- arguments even after `if not card then return end`. Use direct field access
	-- to bypass the nil branch instead of delegating to run_card.
	opts = opts or {}
	opts.name = opts.name or ("@" .. tostring(card.path))
	return sandbox.run(card.script, env, opts)
end

-- caps: lazy proxy for the four capability factory sub-modules.
-- platform.caps.png  → lib/platform/caps/png.lua
-- platform.caps.llm  → lib/platform/caps/llm.lua
-- platform.caps.render → lib/platform/caps/render.lua
-- platform.caps.fs   → lib/platform/caps/fs.lua
M.caps = setmetatable({}, {
	__index = function (t, k)
		local ok, mod = pcall(require, "lib.platform.caps." .. k)
		if ok then t[k] = mod; return mod end
		return nil
	end,
})

return M
