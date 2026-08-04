-- lib/fractal/type_ref_kinds_common.lua — the refined-kind vocabulary,
-- ported from fractal's packages/type-ir/src/kinds/common.ts and the modules
-- it re-exports.
--
-- `kinds/common.ts` is a composite barrel: it re-exports `wire-numerics`
-- (`int-widths` + `float-widths`), `temporal` (`date-time` + `duration`),
-- `semantic-strings`, `bytes`, and `refinements`. Everything runtime-bearing
-- in that set is collected here.
--
-- REQUIRING THIS MODULE HAS A SIDE EFFECT, and that is the point. Each kind
-- module in fractal calls `registerParent(...)` at import time, so a consumer
-- opts into the refined lattice by importing the module (individually, or the
-- whole vocabulary via `kinds/common`). `lib/fractal/type_ref.lua` seeds only
-- the two built-in relationships (`integer -> number`, `method -> function`);
-- requiring THIS module extends that shared lattice with everything below.
-- A projector that has no `uuid` handler only falls back to its `string`
-- handler once this module has been required — exactly as in fractal, where
-- no projector imports the kind modules itself.
--
-- NOT ported: `kinds/refinements.ts`. It declares branded TS types
-- (`MinLength<N>`, `Pattern<P>`, …) read by `from-typescript.ts`'s static
-- analysis to recover `meta` refinement keys from a TS source file. It
-- registers no kind, exports no runtime value, and has no emit — there is
-- nothing to port. The `meta` keys it produces (`minLength`, `pattern`, …)
-- are plain entries in a TypeRef's open `meta` bag and need no declaration
-- here. The same goes for `semantic-strings.ts`'s `Uuid`/`Uri`/`Email` brand
-- types, which exist only to steer that same TS extractor.
--
-- Each constructor takes an optional `meta` bag and returns a TypeRef, NOT a
-- shape — matching fractal's kind modules, which are defined as
-- `t({ kind: "..." }, meta)`. That is an asymmetry with `type_ref.types.*`,
-- whose entries are bare shapes; the asymmetry is fractal's and is preserved
-- rather than smoothed over, so a port of a consumer reads the same either
-- side.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")

local M = {}

--:: Meta = { [string]: unknown }

-- ── Lattice registration ─────────────────────────────────────────────────────

-- Fixed-width integers (kinds/int-widths.ts) — all refine `integer`.
type_ref.register_parent("int8", "integer")
type_ref.register_parent("int16", "integer")
type_ref.register_parent("int32", "integer")
type_ref.register_parent("int64", "integer")
type_ref.register_parent("uint8", "integer")
type_ref.register_parent("uint16", "integer")
type_ref.register_parent("uint32", "integer")
type_ref.register_parent("uint64", "integer")

-- Fixed-width floats (kinds/float-widths.ts) — both refine `number`.
type_ref.register_parent("float32", "number")
type_ref.register_parent("float64", "number")

-- Temporal (kinds/date-time.ts, kinds/duration.ts).
--
-- `datetime` and `date` are registered with NO parent, deliberately. They
-- name the DOMAIN type (JS `Date`), not a wire format — a `Date` is not
-- structurally a string, so chaining to `string`'s handlers and constraints
-- (minLength, pattern, …) wherever a projector lacks an explicit entry would
-- be structurally wrong. The ISO-8601 string is a projection concern,
-- produced by whichever projector targets that wire format.
--
-- `time` DOES refine `string`: there is no native time-of-day domain type the
-- way `Date` backs datetime/date, so representing it as anything but a
-- formatted string would invent a domain type the runtime does not have.
--
-- The two `nil` registrations are not no-ops — `register_parent(k, nil)`
-- clears any parent a previously-loaded module set, which is what makes
-- "explicitly a root" distinguishable from "never mentioned".
type_ref.register_parent("datetime", nil)
type_ref.register_parent("date", nil)
type_ref.register_parent("time", "string")
type_ref.register_parent("duration", "string")

-- Semantically-tagged strings (kinds/semantic-strings.ts).
type_ref.register_parent("uuid", "string")
type_ref.register_parent("uri", "string")
type_ref.register_parent("email", "string")

-- Binary blob (kinds/bytes.ts). Explicitly a root: orthogonal to `string`,
-- never a subtype of it.
type_ref.register_parent("bytes", nil)

-- ── Constructors ─────────────────────────────────────────────────────────────

-- Every constructor below is `(Meta | nil) -> TypeRef` over a payload-free
-- shape, so they are generated from one closure factory rather than written
-- out N times. Each call allocates a fresh shape table, matching fractal's
-- `t({ kind: "..." }, meta)`, which likewise allocates per call rather than
-- sharing a constant (unlike `type_ref.types.*`'s payload-free singletons).
--: (string) -> ((Meta | nil) -> TypeRef)
local function kind_constructor(kind)
	--: (Meta | nil) -> TypeRef
	return function(meta)
		return type_ref.type_ref_from_shape({ kind = kind }, meta)
	end
end

M.int8 = kind_constructor("int8")
M.int16 = kind_constructor("int16")
M.int32 = kind_constructor("int32")
M.int64 = kind_constructor("int64")
M.uint8 = kind_constructor("uint8")
M.uint16 = kind_constructor("uint16")
M.uint32 = kind_constructor("uint32")
M.uint64 = kind_constructor("uint64")

M.float32 = kind_constructor("float32")
M.float64 = kind_constructor("float64")

M.datetime = kind_constructor("datetime")
M.date = kind_constructor("date")
M.time = kind_constructor("time")
M.duration = kind_constructor("duration")

M.uuid = kind_constructor("uuid")
M.uri = kind_constructor("uri")
M.email = kind_constructor("email")

M.bytes = kind_constructor("bytes")

return M
