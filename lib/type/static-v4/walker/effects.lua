-- Walker sub-phase H — effects: yield, throw, pcall.
--
-- Per docs/typechecker-ast-walker-design.md §10. This module is the final
-- CALL_EXPR-handler layer in the sub-phase chain (B → C → F → G → H). It
-- recognises three call shapes that interact with the effect set in ways
-- ordinary call-application cannot express:
--
--   * `error(msg, ...)`        — adds `throw` to env.effects, synthesises to
--                                V.bot() (the call does not return).
--   * `pcall(f, args...)`      — invokes f in a throw-consuming context; the
--                                inner throw effect is MASKED from the
--                                outer body's accumulation. Returns a union
--                                `(true, R) | (false, string)` representing
--                                Lua's pcall protocol.
--   * `xpcall(f, msgh, ...)`   — same throw-mask, slightly different
--                                signature (the message handler runs in the
--                                throw branch). Sub-phase H gives it the
--                                same return shape as pcall.
--
-- Ordinary effect plumbing is already in place from sub-phase C's
-- `apply_arrow` (functions.lua): a call whose arrow advertises effects
-- contributes those effects to env.effects. Specifically,
-- `coroutine.yield(...)` needs no special handling here — provided
-- `coroutine` is bound in the outer env with a field `yield: () -> nil
-- with effects = { yield }`, the field-synth + apply_arrow path
-- accumulates yield automatically. The "yield detection mechanism"
-- mentioned in the design §10.1 is the standard binding-driven path —
-- the only special-cased intrinsics are the ones whose return type or
-- effect behaviour cannot be expressed as a plain V.fn.
--
-- Effect annotation parsing:
--
-- The v4 walker consumes pre-resolved V4Type annotations on AST nodes
-- (the bridge from legacy ann.lua's v3 IDs to V4Type is sub-phase J's
-- integration phase). `V.fn(params, ret, effects)` already accepts an
-- effect set; the walker's body-vs-annotation check (functions.lua
-- lines 501-507) already enforces that the body's accumulated effect
-- set is a subset of the annotated arrow's effect set. No additional
-- parser-side machinery is required within sub-phase H: the legacy
-- `(A) -[yield]-> B` surface syntax has no consumer in v4 yet, and
-- adding it to ann.lua would be premature — the v4 bridge needs to
-- exist first (sub-phase J). The walker's interpretation IS the
-- de-facto spec, and it is "effects ride on V.fn's `effects` slot;
-- annotation upper-bounds body accumulation."
--
-- pcall return-type representation:
--
-- Lua's pcall protocol is a tagged union: on success, (true, ret...);
-- on failure, (false, err). v4 has no first-class match-types-on-tuples
-- shape that captures this without `V.match`. Sub-phase H uses the
-- closest faithful encoding: a UNION of two closed records,
--   V.rec({ "1" = literal(true),  "2" = R          }, false)
--   ∪
--   V.rec({ "1" = literal(false), "2" = V.string_ }, false).
-- Multi-return R values are spread by representing R itself as the
-- record's positional slots — when R is a tuple-shaped rec, the slots
-- are flattened into the success branch. This matches the design's
-- PcallReturn schema (typechecker-reference.md line 289) modulo the
-- match-type sugar.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Intentionally annotation-free; same rationale as functions.lua and
-- indexed_access.lua (cross-module `--::` alias resolution limitation
-- documented in walker/README.md).

local V       = require("lib.type.static-v4")
local E       = require("lib.type.static-v4.walker.env")
local defs    = require("lib.type.static.defs")
local subtype_mod = require("lib.type.static-v4.subtype")
local forall_mod  = require("lib.type.static-v4.forall")

local _types  = require("lib.type.static-v4.types")
local _ = _types

local M = {}

local function walker_mod()
	return require("lib.type.static-v4.walker.walker")
end

-- Bare-identifier shape check. Mirrors the convention from
-- ffi_cdef.lua's is_ffi_cdef_callee: a NODE_IDENTIFIER with the
-- expected name. We do NOT introspect the binding's type — a user
-- shadowing `error` / `pcall` / `xpcall` with a local of the same
-- name is shadowing a prelude intrinsic; that is a user error and
-- the walker still treats the call as the intrinsic.
local function is_named_identifier(node, name)
	return node.tag == defs.NODE_IDENTIFIER and node.name == name
end

-- Build `(true, R) | (false, string)` as a union of two closed records.
-- When R is a tuple (rec with positional string keys), its slots become
-- positional slots 2..n+1 of the success record. When R is a scalar, it
-- occupies slot 2.
--
-- Spread vs scalar distinction is delegated to a tuple-shape helper to
-- keep the parameter's inferred type permissive (the typechecker
-- otherwise unifies pcall_return_type's parameter against the
-- field-access pattern, which V4Type's union shape resists).
local function tuple_slots(ret_ty)
	if ret_ty.tag ~= "rec" then return nil end
	local fields = ret_ty.fields
	if fields == nil then return nil end
	if fields["1"] == nil then return nil end
	local out = {}
	local i = 1
	while true do
		local slot = fields[tostring(i)]
		if slot == nil then break end
		out[i] = slot
		i = i + 1
	end
	return out
end

local function pcall_return_type(ret_ty)
	local true_lit = V.literal("boolean", true)
	local false_lit = V.literal("boolean", false)
	local success_fields = {}
	success_fields["1"] = true_lit
	local slots = tuple_slots(ret_ty)
	if slots ~= nil then
		for i, slot in ipairs(slots) do
			success_fields[tostring(i + 1)] = slot
		end
	else
		success_fields["2"] = ret_ty
	end
	local success = V.rec(success_fields, false, nil)
	local failure = V.rec({ ["1"] = false_lit, ["2"] = V.string_ }, false, nil)
	return V.union({ success, failure })
end

-- ── error(msg, ...) ──────────────────────────────────────────────────────
--
-- §10.2: a call to `error(...)` adds `throw` to the current frame's
-- effects and produces V.bot() as the call's synthesized type (since
-- the call does not return — anything reading the result is dead code).
-- The message argument is synthesized but not type-checked beyond
-- that: Lua's error accepts any value as the message.

local function synth_error(node, env, solver)
	local W = walker_mod()
	local args = node.args or {}
	for i, a in ipairs(args) do
		local _ty, env2, err = W.walk_synth(a, env, solver)
		env = env2
		if err ~= nil then
			return nil, env,
				"error: argument " .. tostring(i) .. ": " .. err
		end
	end
	env = E.add_effect(env, V.EFFECT_THROW)
	return V.bot(), env, nil
end

-- ── pcall(f, args...) ─────────────────────────────────────────────────────
--
-- §10.3: pcall calls `f` in a throw-consuming context. The walker:
--   1. Synthesizes `f` and the args.
--   2. Applies the arrow (constraints on params, ret synth) but discards
--      the throw effect contribution; non-throw effects accrue normally.
--   3. Wraps the arrow's return type in PcallReturn.
--
-- A non-throwing inner function still produces the (boolean, R) | (false,
-- string) shape — pcall's protocol is uniform regardless of whether the
-- inner function CAN throw. The failure branch is then logically
-- unreachable but the type system still constructs it.

local function synth_pcall(node, env, solver)
	local W = walker_mod()
	local args = node.args or {}
	if #args == 0 then
		return nil, env,
			"pcall: expected at least one argument (the function to call)"
	end
	local f_ty, env2, ferr = W.walk_synth(args[1], env, solver)
	if ferr ~= nil then return nil, env2, ferr end
	if f_ty == nil then
		return nil, env2, "pcall: first argument has no synthesized type"
	end
	local raw0 = f_ty
	if raw0.tag == "forall" then raw0 = forall_mod.instantiate(raw0) end
	if raw0.tag ~= "fn" then
		return nil, env2,
			"pcall: first argument has non-function type " .. V.show(f_ty)
	end
	-- Fresh local binds the fn-narrowed shape so field accesses resolve to
	-- V4Fn's fields, not the V4Type union view.
	local raw = raw0
	local params = raw.params or {}
	local ret = raw.ret or V.nil_
	local effects = raw.effects or {}
	local n_params = #params
	-- Synthesize and constrain remaining args.
	local supplied = 0
	for i = 2, #args do
		local ty, env3, aerr = W.walk_synth(args[i], env2, solver)
		env2 = env3
		if aerr ~= nil then return nil, env2, aerr end
		if ty == nil then
			return nil, env2,
				"pcall: argument " .. tostring(i) .. " has no synthesized type"
		end
		supplied = supplied + 1
		local slot = params[supplied]
		if slot == nil then
			return nil, env2,
				"pcall: too many arguments for inner arrow (expected " ..
				tostring(n_params) .. ", got " .. tostring(#args - 1) .. ")"
		end
		subtype_mod.constrain(solver, ty, slot)
		if solver.error ~= nil then
			return nil, env2, solver.error
		end
	end
	if supplied < n_params then
		return nil, env2,
			"pcall: too few arguments for inner arrow (expected " ..
			tostring(n_params) .. ", got " .. tostring(supplied) .. ")"
	end
	-- Effect masking: throw is consumed; other effects ride through.
	for name in pairs(effects) do
		if name ~= V.EFFECT_THROW and type(name) == "string" then
			env2 = E.add_effect(env2, name)
		end
	end
	return pcall_return_type(ret), env2, nil
end

-- ── xpcall(f, msgh, args...) ──────────────────────────────────────────────
--
-- Identical throw-masking semantics as pcall. The message handler `msgh`
-- runs in the throw branch; its non-throw effects propagate to the outer
-- frame, but a throw inside msgh is NOT masked (the protocol re-raises).

local function synth_xpcall(node, env, solver)
	local W = walker_mod()
	local args = node.args or {}
	if #args < 2 then
		return nil, env,
			"xpcall: expected at least two arguments (the function and a message handler)"
	end
	local f_ty, env2, ferr = W.walk_synth(args[1], env, solver)
	if ferr ~= nil then return nil, env2, ferr end
	if f_ty == nil then
		return nil, env2, "xpcall: first argument has no synthesized type"
	end
	local raw0 = f_ty
	if raw0.tag == "forall" then raw0 = forall_mod.instantiate(raw0) end
	if raw0.tag ~= "fn" then
		return nil, env2,
			"xpcall: first argument has non-function type " .. V.show(f_ty)
	end
	local raw = raw0
	local params = raw.params or {}
	local ret = raw.ret or V.nil_
	local effects = raw.effects or {}
	local n_params = #params
	local msgh_ty, env3, merr = W.walk_synth(args[2], env2, solver)
	if merr ~= nil then return nil, env3, merr end
	if msgh_ty == nil then
		return nil, env3, "xpcall: message-handler argument has no synthesized type"
	end
	local msgh_raw0 = msgh_ty
	if msgh_raw0.tag == "forall" then msgh_raw0 = forall_mod.instantiate(msgh_raw0) end
	if msgh_raw0.tag ~= "fn" then
		return nil, env3,
			"xpcall: message-handler argument has non-function type " .. V.show(msgh_ty)
	end
	local msgh_raw = msgh_raw0
	local msgh_effects = msgh_raw.effects or {}
	-- Synthesize and constrain remaining args.
	local supplied = 0
	for i = 3, #args do
		local ty, env4, aerr = W.walk_synth(args[i], env3, solver)
		env3 = env4
		if aerr ~= nil then return nil, env3, aerr end
		if ty == nil then
			return nil, env3,
				"xpcall: argument " .. tostring(i) .. " has no synthesized type"
		end
		supplied = supplied + 1
		local slot = params[supplied]
		if slot == nil then
			return nil, env3,
				"xpcall: too many arguments for inner arrow (expected " ..
				tostring(n_params) .. ", got " .. tostring(#args - 2) .. ")"
		end
		subtype_mod.constrain(solver, ty, slot)
		if solver.error ~= nil then
			return nil, env3, solver.error
		end
	end
	if supplied < n_params then
		return nil, env3,
			"xpcall: too few arguments for inner arrow (expected " ..
			tostring(n_params) .. ", got " .. tostring(supplied) .. ")"
	end
	for name in pairs(effects) do
		if name ~= V.EFFECT_THROW and type(name) == "string" then
			env3 = E.add_effect(env3, name)
		end
	end
	for name in pairs(msgh_effects) do
		if type(name) == "string" then
			env3 = E.add_effect(env3, name)
		end
	end
	return pcall_return_type(ret), env3, nil
end

-- ── NODE_CALL_EXPR (overrides G) ──────────────────────────────────────────
--
-- The wrapper inspects the callee's shape against the three intrinsic
-- names. Any other call falls through to the captured handler from
-- sub-phase G (which itself falls through to F's indexed-callee
-- handler, which falls through to C's apply_arrow). This is the same
-- override-with-fallback discipline ffi_cdef.lua established.

local existing_call_handler -- captured at register-time

local function synth_call(node, env, solver)
	local callee = node.callee
	if callee ~= nil then
		if is_named_identifier(callee, "error") then
			return synth_error(node, env, solver)
		end
		if is_named_identifier(callee, "pcall") then
			return synth_pcall(node, env, solver)
		end
		if is_named_identifier(callee, "xpcall") then
			return synth_xpcall(node, env, solver)
		end
	end
	return existing_call_handler(node, env, solver)
end

-- ── registration ─────────────────────────────────────────────────────────

function M.register(W)
	local ffi_cdef = require("lib.type.static-v4.walker.ffi_cdef")
	existing_call_handler = ffi_cdef.synth_call_for_subphase_h
	if existing_call_handler == nil then
		error("walker sub-phase H: cannot capture sub-phase G's synth_call — " ..
			"ffi_cdef.lua does not expose synth_call_for_subphase_h")
	end
	W.register_synth(defs.NODE_CALL_EXPR, synth_call)
end

-- Test hooks.
M.pcall_return_type = pcall_return_type
M.is_named_identifier = is_named_identifier

return M
