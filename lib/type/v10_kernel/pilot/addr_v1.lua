-- lib/type/v10_kernel/pilot/addr_v1.lua
--
-- Program-point addressing signature (`addr-v1`), pilot step 1+2, committed
-- per docs/typechecker-v10-pilot-signatures-proposal.md §1.2 exactly as
-- specified there — no deviation from the operator list or shapes, since
-- the proposal's own summary table (§5) marks this signature "Committable
-- as written — no cross-signature dependency." Declared over the canonical
-- v10 core (lib/type/v10_cleanroom/, per the owner-ratified canon swap).
--
-- Deliberately signature-only (no rules/axioms/replayer wiring): that is
-- pilot step 3+, gated separately per the proposal's scope note. This
-- module lives beside (not inside) lib/type/v10_kernel/theories/ precisely
-- because theories/ pairs a vocabulary with rule schemas (see hm.lua) —
-- addr-v1 is vocabulary only, so it does not belong there yet.
--
-- A path denotes a location by literal descent from the chunk root:
-- path_child(path_child(path_root, succ(zero)), zero) = "child 1, then
-- child 0 of the chunk root" (0-indexed via peano zero/succ). entry_of/
-- exit_of turn a bare structural coordinate into a flow point without a
-- second sort. File content enters only as a bit-list built from two
-- nullary constants (bs_nil/bs_cons over b0/b1) — no string payload
-- anywhere, per proposal §1.1's file-identity choice (A).

local ta = require("lib.type.v10_cleanroom.term_algebra")

local M = {}

-- Declare the addr-v1 signature. Call once; share the returned signature
-- object with every consumer that needs to cite its sorts (e.g.
-- narrow_pilot_v1.lua's `imports`) — sort/operator identity is the
-- declared object itself, never a re-declaration.
--: () -> (Signature | nil, string | nil)
function M.declare()
	return ta.declare_signature({
		name = "addr-v1",
		version = 1,
		sorts = { "nat", "bit", "bitstring", "file_id", "path", "point" },
		ops = {
			zero        = { result = "nat", args = {} },
			succ        = { result = "nat", args = { { sort = "nat" } } },

			b0          = { result = "bit", args = {} },
			b1          = { result = "bit", args = {} },
			bs_nil      = { result = "bitstring", args = {} },
			bs_cons     = { result = "bitstring", args = { { sort = "bit" }, { sort = "bitstring" } } },
			file_id_of  = { result = "file_id", args = { { sort = "bitstring" } } },

			path_root   = { result = "path", args = {} },
			path_child  = { result = "path", args = { { sort = "path" }, { sort = "nat" } } },

			entry_of    = { result = "point", args = { { sort = "file_id" }, { sort = "path" } } },
			exit_of     = { result = "point", args = { { sort = "file_id" }, { sort = "path" } } },
		},
	})
end

return M
