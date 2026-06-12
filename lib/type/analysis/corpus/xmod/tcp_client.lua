-- Cross-module fixture — ENTRY module (the `lib/dns/tcp_client.lua` shape).
--
-- The TRUE cross-module form: `Epoll` is declared in xmod/epoll.lua (NOT in this
-- file), and referenced here by bare name in the `epoll: Epoll | nil` parameter
-- annotation. The `require` of the exporting module brings its `--::` aliases into
-- this file's annotation scope (slice v2 increment 2, §6.6).
--
-- What a correct checker concludes: `Epoll` resolves to the exporting module's
-- `Ty`, the `Epoll | nil` parameter narrows after the nil-guard, and the field
-- access `ep.wait()` succeeds — with 0 errors and the cross-module resolution
-- recorded as a visible `cross_module_alias` trust boundary (§6.6.5).
--
-- Before this increment, `Epoll` would be `unknown-type-name` and the file would
-- be forced to write `unknown | nil` (the documented workaround the real
-- lib/dns/tcp_client.lua still carries at lines 12-15).

local epoll_mod = require("lib.type.analysis.corpus.xmod.epoll")

--: (cb: () -> nil, epoll: Epoll | nil) -> nil
local function connect(cb, epoll)
  local ep = epoll
  if ep == nil then
    ep = epoll_mod.new()
  end
  -- After the nil-guard, ep is narrowed to Epoll; .wait() is accessible.
  ep.wait()
  cb()
end

return { connect = connect }
