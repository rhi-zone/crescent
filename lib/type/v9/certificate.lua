-- lib/type/v9/certificate.lua
-- Certificate emitter seam — RESERVED; no-op impl now. Proof oracle: the
-- synth/check derivation DAG (check.v). The whole reason `synth`/`check` expose
-- a first-class `Deriv` is so a real emitter can be slotted in HERE later
-- (serialize the Deriv to a content-addressed, replayable certificate) with NO
-- change to the inference engine. This no-op proves the wiring: it consumes the
-- Deriv and returns a trivial certificate.

--:: require "lib.type.v9.type_defs"

local M = {}
M.name = "noop"

-- Echo the derivation as a trivial certificate. A real emitter replaces this
-- body; the SIGNATURE is the load-bearing contract.
--: (Deriv) -> (Cert | nil, string | nil)
function M.emit(deriv)
    return { kind = "noop", root = deriv }, nil
end

return M
