-- Walker sub-phase K6c — operator and cast handlers.
--
-- Per docs/typechecker-ast-walker-design.md §3.4 (unary), §3.5 (binary), and
-- §3.13 (cast). Registers SYNTHESIZE handlers for the three node kinds whose
-- absence is responsible for ~350 v4 errors in the K6 parity bucket:
--
--   NODE_BINARY_EXPR  — arithmetic, comparison, equality, logical, concat
--   NODE_UNARY_EXPR   — unary minus, `not`, length `#`
--   NODE_CAST_EXPR    — `--[[: T]] expr` (checked) and `--[[:! T]] expr` (force)
--
-- Decoded node shapes (post-decoder)
-- ──────────────────────────────────
--   NODE_BINARY_EXPR  { tag, line, col, op: string, lhs: Node, rhs: Node }
--   NODE_UNARY_EXPR   { tag, line, col, op: string, operand: Node }
--   NODE_CAST_EXPR    { tag, line, col, expr: Node,
--                       annotation: V4Type | nil,         -- resolved annotation
--                       annotation_id: integer | nil,     -- raw pool id from
--                                                         -- decoder
--                       force: boolean }
--
-- `op` is the string from decoder.lua's OP_NAME table ("+", "-", "*", "/",
-- "%", "^", "..", "==", "~=", "<", "<=", ">", ">=", "and", "or", "not",
-- "#"). Floor-division and bitwise ops are not currently in OP_NAME (the
-- parser does not produce them as discriminated ops); attempts to use them
-- fall through to the "unknown operator" branch and error loudly rather
-- than silently mishandling.
--
-- CHECK mode follows the §2.1 default rule (synthesize, then constrain).
-- Bidirectional CHECK would buy nothing for operator nodes since their
-- result shape is constructor-determined.
--
-- Cast semantics
-- ──────────────
--   `--[[: T]] expr` (checked, `force = false`):
--     emit `synth(expr) <: T`; result is T.
--   `--[[:! T]] expr` (force, `force = true`):
--     emit `is_empty(inter(synth(expr), T))`; if empty, error (no overlap —
--     CLAUDE.md "Library Conventions" force-cast contract). Otherwise the
--     subtype check is BYPASSED and the result is T.
--
-- The annotation is taken from `node.annotation` (a pre-resolved V4Type).
-- When `annotation` is absent but `annotation_id` is present, the cast
-- handler reports E_CAST naming the unresolved annotation — this is the
-- annotation-parser-bridge gap (K6e / sub-phase J's `--::` bridge), not
-- a temp-measure: the diagnostic surfaces the missing piece honestly.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Intentionally annotation-free; same rationale as functions.lua,
-- control_flow.lua, statements.lua (cross-module `--::` alias-resolution
-- limitation documented in walker/README.md).

local V       = require("lib.type.static-v4")
local D       = require("lib.type.static-v4.walker.diag")
local defs    = require("lib.type.static.defs")
local subtype = require("lib.type.static-v4.subtype")
local empty   = require("lib.type.static-v4.empty")

local _types  = require("lib.type.static-v4.types")
local _ = _types

local M = {}

local function walker_mod()
	return require("lib.type.static-v4.walker.walker")
end

-- ── numeric / string subtype probes ─────────────────────────────────────
--
-- We need decidable answers to "is T provably a subtype of integer / number
-- / string?" Use a fresh solver per query so the probe's bookkeeping does
-- not contaminate the caller's constraints. Variable bounds accrued on the
-- probe DO persist on the variable record itself (see subtype.lua's note
-- on M.subtype); for primitive-typed operand checks this is harmless since
-- the bounds match what a real `constrain` would have added anyway.

local function is_subtype(t, sup)
	local ok = V.subtype(t, sup)
	return ok
end

local function is_integer(t)  return is_subtype(t, V.integer) end
local function is_number(t)   return is_subtype(t, V.number)  end
local function is_string(t)   return is_subtype(t, V.string_) end

-- A type is "numeric-or-string" for `..`: each operand of concat may be
-- either a number or a string (Lua coerces numbers to strings).
local function is_num_or_str(t)
	return is_number(t) or is_string(t)
end

-- ── binary handler ──────────────────────────────────────────────────────

-- Arithmetic ops with integer-preserving semantics (+, -, *, %, //):
-- result is integer iff both operands are integer; otherwise number.
local ARITH_INT_PRESERVE = {
	["+"] = true, ["-"] = true, ["*"] = true, ["%"] = true, ["//"] = true,
}

-- Arithmetic ops that always produce number (/, ^).
local ARITH_ALWAYS_NUMBER = { ["/"] = true, ["^"] = true }

-- Comparison ops (<, <=, >, >=): operands must be both numeric or both
-- strings; result boolean.
local COMPARISON = {
	["<"] = true, ["<="] = true, [">"] = true, [">="] = true,
}

-- Equality (==, ~=): any operands, result boolean.
local EQUALITY = { ["=="] = true, ["~="] = true }

-- Logical (and / or): result depends on operand types per Lua semantics.
local LOGICAL_AND = { ["and"] = true }
local LOGICAL_OR  = { ["or"]  = true }

-- (binary `op` lookup is by direct string compare below; we keep the
-- tables above for the dispatch.)

local function synth_binary(node, env, solver)
	local W = walker_mod()
	local op = node.op

	-- Synthesize both sides for SYNTH side effects regardless of op. This
	-- ensures undefined-name / sub-error diagnostics surface even when the
	-- operator itself is rejected.
	local lhs_ty, env1, err1 = W.walk_synth(node.lhs, env, solver)
	if err1 ~= nil then return nil, env1, err1 end
	local rhs_ty, env2, err2 = W.walk_synth(node.rhs, env1, solver)
	if err2 ~= nil then return nil, env2, err2 end

	if ARITH_INT_PRESERVE[op] or ARITH_ALWAYS_NUMBER[op] then
		-- Both operands must be number-or-narrower. The constrain emits
		-- the diagnostic on failure; we surface op-typed E_OP_TYPE.
		if not is_number(lhs_ty) then
			return nil, env2, D.emit(env2, D.E_OP_TYPE,
				"operator " .. op .. ": left operand is not numeric")
		end
		if not is_number(rhs_ty) then
			return nil, env2, D.emit(env2, D.E_OP_TYPE,
				"operator " .. op .. ": right operand is not numeric")
		end
		if ARITH_ALWAYS_NUMBER[op] then
			return V.number, env2, nil
		end
		-- ARITH_INT_PRESERVE: integer iff both integer.
		if is_integer(lhs_ty) and is_integer(rhs_ty) then
			return V.integer, env2, nil
		end
		return V.number, env2, nil
	end

	if COMPARISON[op] then
		-- Both numeric, or both string. Anything else rejects.
		local both_numeric = is_number(lhs_ty) and is_number(rhs_ty)
		local both_string  = is_string(lhs_ty) and is_string(rhs_ty)
		if not (both_numeric or both_string) then
			return nil, env2, D.emit(env2, D.E_OP_TYPE,
				"operator " .. op .. ": operands must be both numeric or both strings")
		end
		return V.boolean, env2, nil
	end

	if EQUALITY[op] then
		-- Lua permits == / ~= on any two operands. Disjoint operands return
		-- false (or true for ~=) at runtime — that's a valid program shape,
		-- so we do NOT reject. Future: an opt-in warning for provably
		-- constant comparisons would land here.
		return V.boolean, env2, nil
	end

	if op == ".." then
		-- Each operand must be string-or-number.
		if not is_num_or_str(lhs_ty) then
			return nil, env2, D.emit(env2, D.E_OP_TYPE,
				"operator ..: left operand must be string or number")
		end
		if not is_num_or_str(rhs_ty) then
			return nil, env2, D.emit(env2, D.E_OP_TYPE,
				"operator ..: right operand must be string or number")
		end
		return V.string_, env2, nil
	end

	if LOGICAL_AND[op] then
		-- `a and b`: if a is truthy, returns b; if falsy, returns a.
		-- Per design §3.5, the result is approximately
		--   union(falsy(a), b)
		-- where falsy(a) is the part of a that is nil or false.
		-- We approximate via union(lhs_ty, rhs_ty) — a sound upper bound:
		-- the value can be any inhabitant of a (when falsy) or of b
		-- (when truthy). Precise truthy/falsy splitting is achievable via
		-- V.inter with V.neg(nil) / V.neg(false_literal), but the union
		-- form is the canonical conservative shape and matches the
		-- design doc's bidirectional treatment.
		--
		-- Narrowing on `and`/`or` for control-flow guards is handled in
		-- walker/control_flow.lua's guard recognizer (sub-phase D); this
		-- handler concerns only the result type of the expression.
		return V.union({ lhs_ty, rhs_ty }), env2, nil
	end

	if LOGICAL_OR[op] then
		-- `a or b`: if a is truthy, returns a; if falsy, returns b.
		-- Conservative union, same rationale as `and` above.
		return V.union({ lhs_ty, rhs_ty }), env2, nil
	end

	-- Floor division (`//`) and bitwise ops (`&`, `|`, `~`, `<<`, `>>`) are
	-- not currently produced by the parser (decoder OP_NAME table lacks
	-- them). If an op string we don't recognise lands here, that's either a
	-- parser/decoder drift or a future op the walker hasn't been taught
	-- about. Either way: loud rejection.
	return nil, env2, D.emit(env2, D.E_OP_TYPE,
		"operator " .. tostring(op) .. ": unknown binary operator")
end

-- ── unary handler ───────────────────────────────────────────────────────

local function synth_unary(node, env, solver)
	local W = walker_mod()
	local op = node.op

	local ty, env1, err = W.walk_synth(node.operand, env, solver)
	if err ~= nil then return nil, env1, err end

	if op == "-" then
		-- Unary minus: operand must be numeric. Result integer if operand
		-- integer, else number (mirrors arithmetic int-preserve discipline).
		if not is_number(ty) then
			return nil, env1, D.emit(env1, D.E_OP_TYPE,
				"unary -: operand is not numeric")
		end
		if is_integer(ty) then return V.integer, env1, nil end
		return V.number, env1, nil
	end

	if op == "not" then
		-- `not x` returns boolean for any operand. Narrowing of `if not x`
		-- guards is in control_flow.lua; the expression-level type is just
		-- boolean.
		return V.boolean, env1, nil
	end

	if op == "#" then
		-- Length: operand must be string or table (record-shaped). Result
		-- integer. We accept either:
		--   * a (sub)type of string
		--   * a record (open or closed) — represented as V.rec
		-- Anything else rejects.
		if is_string(ty) then return V.integer, env1, nil end
		if type(ty) == "table" and ty.tag == "rec" then
			return V.integer, env1, nil
		end
		return nil, env1, D.emit(env1, D.E_OP_TYPE,
			"unary #: operand must be a string or table")
	end

	-- `~` (bitwise not) and any other op string: loud rejection. Same
	-- rationale as the binary fall-through.
	return nil, env1, D.emit(env1, D.E_OP_TYPE,
		"unary " .. tostring(op) .. ": unknown unary operator")
end

-- ── cast handler ────────────────────────────────────────────────────────

local function synth_cast(node, env, solver)
	local W = walker_mod()
	local target = node.annotation
	if target == nil then
		-- The annotation-parser bridge has not populated this cast's
		-- target type. Per CLAUDE.md no-temp-measures, reject loudly
		-- rather than silently widening or returning `unknown` — the
		-- diagnostic names the gap so a future session sees the cause.
		return nil, env, D.emit(env, D.E_CAST,
			"cast annotation not resolved (annotation-parser bridge not wired " ..
			"for NODE_CAST_EXPR yet; annotation_id=" .. tostring(node.annotation_id) .. ")")
	end

	local inner_ty, env1, err = W.walk_synth(node.expr, env, solver)
	if err ~= nil then return nil, env1, err end
	if inner_ty == nil then
		-- walk_synth returned (nil, env, nil) — the cast's inner expression
		-- is a statement node, not an expression. That's an invariant
		-- violation at the call site, not a recoverable type error.
		return nil, env1, D.emit(env1, D.E_INTERNAL,
			"cast: inner expression synthesised no type (statement in expression position?)")
	end

	if node.force then
		-- Force cast: bypass subtype, require overlap. Per design §3.13:
		-- `is_empty(inter(inner, T))` ⇒ reject; otherwise synthesised type
		-- is T.
		local inter = V.inter({ inner_ty, target })
		-- empty.is_empty wants a solver; we use a fresh one to avoid
		-- polluting the caller's constraint state.
		local probe = V.new_solver()
		if empty.is_empty(inter, probe) then
			return nil, env1, D.emit(env1, D.E_CAST,
				"force cast: operand type does not overlap with target type")
		end
		return target, env1, nil
	end

	-- Checked cast: standard subtype check.
	subtype.constrain(solver, inner_ty, target)
	if solver.error ~= nil then
		return nil, env1, D.from_solver(env1, D.E_CAST,
			"cast: value does not satisfy target type",
			solver, inner_ty, target)
	end
	return target, env1, nil
end

-- ── registration ────────────────────────────────────────────────────────

function M.register(W)
	W.register_synth(defs.NODE_BINARY_EXPR, synth_binary)
	W.register_synth(defs.NODE_UNARY_EXPR,  synth_unary)
	W.register_synth(defs.NODE_CAST_EXPR,   synth_cast)
end

return M
