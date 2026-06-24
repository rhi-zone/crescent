-- lib/sem/bridge/exec_test.lua
-- REALITY-BRIDGE differential pipeline for the OPERATIONAL / EXECUTION axis:
-- WELL-TYPED TERM → executed on REAL LuaJIT → RESULT INHABITS its INFERRED TYPE.
-- This is the checker's soundness claim (synth + progress/preservation) tested
-- against the real interpreter. See docs/reality-bridge.md §"Operational axis".
--
-- For each battery term we (1) translate it to runnable Lua (exec.term_to_lua),
-- (2) run it on the vendored LuaJIT (popen-injected cap), capturing the result
-- value + shape, (3) pin its INFERRED type `synth [] term` (computed in
-- proof/bridge_exec_oracle.v, asserted verbatim here), (4) assert the real
-- result INHABITS the inferred type, REUSING the value-membership bridge
-- (atom.lua's REAL atom predicates; records via per-field predicates). Then we
-- report agreement counts and SURFACE the PDiv faithfulness gap (proof Nat.div
-- vs real float `/`) and any other disagreements.
--
-- CAPS-FIRST: the real interpreter is reached ONLY through injected caps; if the
-- vendored LuaJIT cannot be probed, the real-side legs SKIP (never fail) so
-- `bin/cr test` stays green on a bare clone.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local exec = require("lib.exec")
local atom = require("lib.sem.bridge.atom")
local ex   = require("lib.sem.bridge.exec")

--:: require "lib.caps.types"
--:: require "lib.sem.bridge.atom"
--:: require "lib.sem.bridge.exec"

--:: ExecCaps = { popen: POpenFn, open: OpenFn, remove: RemoveFn, tmpname: TmpnamFn }

local LUAJIT = "./bin/luajit"

-- ── caps-first interpreter probe ─────────────────────────────────────────────
--: (ExecCaps, string) -> boolean
local function probe(caps, cmd)
	local out = exec.run(cmd, { "-e", "io.write('crbridge-probe')" },
		{ popen = caps.popen, stderr = "discard" })
	if out == nil then return false end
	return out:find("crbridge-probe", 1, true) ~= nil
end

-- ── run a Lua chunk in the real interpreter, return stdout (or nil) ──────────
--: (ExecCaps, string, string) -> (string | nil)
local function run_chunk(caps, cmd, src)
	local path = caps.tmpname() .. ".bridge-exec.lua"
	local fh = caps.open(path, "w")
	if fh == nil then error("bridge: cannot open temp file " .. path) end
	fh:write(src)
	fh:close()
	local out = exec.run(cmd, { path }, { popen = caps.popen, stderr = "discard" })
	caps.remove(path)
	return out
end

-- ── the INFERRED-TYPE model (a small port of the BTy fragment the battery uses)
-- The inferred type per battery term, exactly as `synth [] term` produces
-- (proof/bridge_exec_oracle.v). We only need the fragment the battery covers:
-- scalar atoms, a union of atoms, an open record, and a reference.
--:: ITAtom  = { k: "atom", a: BridgeAtom }
--:: ITUnion = { k: "union", l: InferType, r: InferType }
--:: ITRec   = { k: "rec", fields: { k: string, T: InferType }[] }
--:: ITRef   = { k: "ref", inner: InferType }
--:: InferType = ITAtom | ITUnion | ITRec | ITRef
local IT = {}
--: (BridgeAtom) -> InferType
function IT.atom(a) return { k = "atom", a = a } end
--: (InferType, InferType) -> InferType
function IT.union(l, r) return { k = "union", l = l, r = r } end
--: ({ k: string, T: InferType }[]) -> InferType
function IT.rec(fields) return { k = "rec", fields = fields } end
--: (InferType) -> InferType
function IT.ref(inner) return { k = "ref", inner = inner } end

-- ── inhabitance predicate SOURCE: build a Lua boolean expression deciding
-- whether the value bound to name `x` INHABITS the inferred type `it`, REUSING
-- the atom bridge's REAL atom predicates (atom.atom_real_predicate, textually
-- rebound from `x` to the relevant access expression). Records reduce to a
-- per-field open/width conjunction (like rec.lua's field predicate); a ref's
-- value is a `{ v = … }` cell whose `.v` must inhabit the inner type. ─────────
--: (InferType, string) -> string
local function inhabit_expr(it, access)
	if it.k == "atom" then
		local pred = atom.atom_real_predicate(it.a) --[[: string]]
		-- the atom predicates reference only `x` (and globals type/math); rebind
		-- `x` to the access expression (same trick rec.lua uses).
		local pred_at = (pred:gsub("%f[%w]x%f[%W]", "(" .. access .. ")"))
		return "(" .. pred_at .. ")"
	elseif it.k == "union" then
		return "((" .. inhabit_expr(it.l, access) .. ") or ("
			.. inhabit_expr(it.r, access) .. "))"
	elseif it.k == "rec" then
		-- a value inhabits BRec fields iff it is a table AND each (k,T) is present
		-- with value ∈ T (OPEN / width — extra keys allowed).
		local parts = { 'type(' .. access .. ') == "table"' } --[[: { [integer]: string } ]]
		for i = 1, #it.fields do
			local fld = it.fields[i]
			local fa = "(" .. access .. ")[" .. ("%q"):format(fld.k) .. "]"
			parts[#parts + 1] = "(" .. fa .. " ~= nil and ("
				.. inhabit_expr(fld.T, fa) .. "))"
		end
		return "(" .. table.concat(parts, " and ") .. ")"
	elseif it.k == "ref" then
		-- a reference cell `{ v = … }`: a table whose `.v` inhabits the inner type.
		local va = "(" .. access .. ").v"
		return '(type(' .. access .. ') == "table" and ('
			.. inhabit_expr(it.inner, va) .. "))"
	end
	error("bridge: unknown inferred-type kind " .. tostring(it.k))
end

-- ── run a term + check its result inhabits the inferred type, IN real LuaJIT ──
-- Returns { shape = <result shape string>, inhabits = <boolean> } or nil on
-- interpreter failure. The result shape is the value's observable rendering
-- (exec.program_for_shape's classifier inlined); inhabitance is the predicate
-- above evaluated on the real result.
--:: RunResult = { shape: string, inhabits: boolean }
--: (ExecCaps, string, Term, InferType) -> (RunResult | nil)
local function run_and_check(caps, cmd, term, it)
	local expr = ex.term_to_lua(term) --[[: string]]
	local pred = inhabit_expr(it, "__r") --[[: string]]
	local lines = {
		"local __r = (" .. expr .. ")",
		"local __inh = (" .. pred .. ")",
		"local function shp(x)",
		"  local ty = type(x)",
		"  if ty == 'number' then return 'number|' .. tostring(x) end",
		"  if ty == 'boolean' then return 'boolean|' .. tostring(x) end",
		"  if ty == 'nil' then return 'nil|' end",
		"  if ty == 'string' then return 'string|' .. x end",
		"  if ty == 'table' then",
		"    local ks = {}",
		"    for k in pairs(x) do ks[#ks+1] = tostring(k) end",
		"    table.sort(ks)",
		"    local fs = {}",
		"    for _, k in ipairs(ks) do fs[#fs+1] = k .. '=' .. type(x[k]) end",
		"    return 'table|' .. table.concat(fs, ';')",
		"  end",
		"  return ty .. '|' .. tostring(x)",
		"end",
		"io.write((__inh and 'INHABITS' or 'OUTSIDE') .. '\\t' .. shp(__r))",
	} --[[: { [integer]: string } ]]
	local out = run_chunk(caps, cmd, table.concat(lines, "\n") .. "\n")
	if out == nil then return nil end
	local verdict, shape = out:match("^(%u+)\t(.*)$")
	if verdict == nil then return nil end
	return { shape = shape, inhabits = (verdict == "INHABITS") }
end

-- ── THE BATTERY ──────────────────────────────────────────────────────────────
-- Each entry: a description, the proof term (ported via exec constructors), and
-- its INFERRED type `synth [] term` (verbatim from proof/bridge_exec_oracle.v).
--:: BatteryCase = { desc: string, term: Term, infer: InferType }
--: () -> BatteryCase[]
local function battery()
	local L = ex
	local Ai = IT.atom("AInt")
	local An = IT.atom("ANum")
	local Ab = IT.atom("ABool")
	local Anil = IT.atom("ANil")
	return {
		-- arithmetic 3 + 4 : ANum
		{ desc = "3 + 4 : ANum",
			term = L.prim("PAdd", L.lit_int(), L.lit_int()), infer = An },
		-- subtraction 10 - 4 : ANum
		{ desc = "10 - 4 : ANum",
			term = L.prim("PSub", L.lit_int(), L.lit_int()), infer = An },
		-- multiplication 6 * 7 : ANum
		{ desc = "6 * 7 : ANum",
			term = L.prim("PMul", L.lit_int(), L.lit_int()), infer = An },
		-- comparison 3 < 4 : Bool
		{ desc = "3 < 4 : Bool",
			term = L.prim("PLt", L.lit_int(), L.lit_int()), infer = Ab },
		-- comparison 5 <= 5 : Bool
		{ desc = "5 <= 5 : Bool",
			term = L.prim("PLe", L.lit_int(), L.lit_int()), infer = Ab },
		-- equality 4 == 4 : Bool
		{ desc = "4 == 4 : Bool",
			term = L.prim("PEq", L.lit_int(), L.lit_int()), infer = Ab },
		-- conditional if (3<4) then 1 else 0 : ANum ∪ ANum (synth: AInt∪AInt)
		{ desc = "if 3<4 then 1 else 0 : AInt ∪ AInt",
			term = L.if_(L.prim("PLt", L.lit_int(), L.lit_int()),
				L.lit_int(), L.lit_int()),
			infer = IT.union(Ai, Ai) },
		-- let x = 6+1 in x*2 : ANum
		{ desc = "let x = 6+1 in x*2 : ANum",
			term = L.let_(L.prim("PAdd", L.lit_int(), L.lit_int()),
				L.prim("PMul", L.var(0), L.lit_int())),
			infer = An },
		-- record { x = 3+4, y = 5 } : BRec [(x,ANum),(y,AInt)]
		{ desc = "{ x = 3+4, y = 5 } : { x: ANum, y: AInt }",
			term = L.rec({
				{ k = "x", e = L.prim("PAdd", L.lit_int(), L.lit_int()) },
				{ k = "y", e = L.lit_int() },
			}),
			infer = IT.rec({ { k = "x", T = An }, { k = "y", T = Ai } }) },
		-- projection { x = 3+4, y = 5 }.x : ANum
		{ desc = "{ x = 3+4, y = 5 }.x : ANum",
			term = L.proj(L.rec({
				{ k = "x", e = L.prim("PAdd", L.lit_int(), L.lit_int()) },
				{ k = "y", e = L.lit_int() },
			}), "x"),
			infer = An },
		-- ref alloc + deref  !(ref (2+3)) : ANum
		{ desc = "!(ref (2+3)) : ANum",
			term = L.deref(L.alloc(L.prim("PAdd", L.lit_int(), L.lit_int()))),
			infer = An },
		-- ref alloc  ref (2+3) : BRef ANum  (the cell itself)
		{ desc = "ref (2+3) : BRef ANum",
			term = L.alloc(L.prim("PAdd", L.lit_int(), L.lit_int())),
			infer = IT.ref(An) },
		-- ref mutation reading the new value
		--   let r = ref 0 in (r := 9 ; !r) : AInt
		{ desc = "let r = ref 0 in (r := 9 ; !r) : AInt",
			term = L.let_(L.alloc(L.lit_int()),
				L.seq(L.assign(L.var(0), L.lit_int()), L.deref(L.var(0)))),
			infer = Ai },
		-- function application  (\x:ANum. x+1) 5 : ANum
		{ desc = "(\\x. x+1) 5 : ANum",
			term = L.app(L.lam(L.prim("PAdd", L.var(0), L.lit_int())),
				L.lit_int()),
			infer = An },
		-- counting while-loop: local i = ref(0+0); while !i<3 do i:=!i+1 end; !i
		--   : ANum  (synth-acceptable form, see bridge_exec_oracle.v b_while)
		{ desc = "let i=ref(0+0) in (while !i<3 do i:=!i+1 end ; !i) : ANum",
			term = L.let_(L.alloc(L.prim("PAdd", L.lit_int(), L.lit_int())),
				L.seq(
					L.while_(L.prim("PLt", L.deref(L.var(0)), L.lit_int()),
						L.assign(L.var(0),
							L.prim("PAdd", L.deref(L.var(0)), L.lit_int()))),
					L.deref(L.var(0)))),
			infer = An },
		-- nil literal : ANil
		{ desc = "nil : ANil", term = L.lit_nil(), infer = Anil },
		-- boolean literal : ABool
		{ desc = "true : ABool", term = L.lit_bool(true), infer = Ab },
	}
end

T.describe("sem reality-bridge: well-typed term executes to a value inhabiting its inferred type", function()
	local caps = {
		popen = io.popen, open = io.open, remove = os.remove, tmpname = os.tmpname,
	} --[[: ExecCaps]]

	-- ── leg (0): pure translator sanity (no interpreter needed) ───────────────
	-- The translator is total over the battery and produces non-empty source.
	T.it("translator: every battery term translates to runnable Lua source", function()
		local cases = battery()
		for i = 1, #cases do
			local src = ex.term_to_lua(cases[i].term)
			T.ok(type(src) == "string" and #src > 0,
				"translated source for: " .. cases[i].desc)
		end
		print("  [bridge] exec translator: " .. #cases .. "/" .. #cases
			.. " battery terms translated")
	end)

	-- ── leg (1): RESULT-INHABITS-TYPE — the core soundness-against-reality leg ─
	-- For each battery term: translate, run on real LuaJIT, assert the result
	-- INHABITS its inferred type (via the value-membership bridge's real preds).
	T.it("result inhabits inferred type on real LuaJIT (the battery)", function()
		if not probe(caps, LUAJIT) then
			T.skip("vendored LuaJIT not probeable; execution leg skipped (bare-clone safe)")
			return
		end
		local cases = battery()
		local inhabited = 0
		local outside = {} --: string[]
		for i = 1, #cases do
			local c = cases[i]
			local rr = run_and_check(caps, LUAJIT, c.term, c.infer)
			T.neq(rr, nil, "real interpreter produced a result for: " .. c.desc)
			if rr ~= nil then
				if rr.inhabits then
					inhabited = inhabited + 1
				else
					outside[#outside + 1] = c.desc .. " (result shape: " .. rr.shape .. ")"
				end
			end
		end
		print("  [bridge] result-inhabits-type: " .. inhabited .. "/" .. #cases
			.. " well-typed programs executed to a value INHABITING their inferred type")
		for i = 1, #outside do print("    [OUTSIDE TYPE] " .. outside[i]) end
		T.eq(#outside, 0,
			"every well-typed program's real result inhabits its inferred type (checker soundness vs reality)")
	end)

	-- (The former leg (2) "PDiv faithfulness gap" — proof Nat.div 7/2=3 vs real
	-- float 7/2=3.5 — was DELETED in the "types, not magnitudes" refactor: the
	-- model no longer computes a number magnitude, so there is no model value to
	-- disagree with reality. The bridge's claim is now purely the TYPE claim,
	-- validated by leg (1) above.)
end)
