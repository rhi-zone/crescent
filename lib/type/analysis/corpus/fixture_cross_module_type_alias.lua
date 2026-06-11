-- Fixture: cross-module named type alias not visible across require() boundary
--
-- Source fire: lib/dns/tcp_client.lua lines 11-15; comment: "epoll is
--   `unknown | nil` because the `epoll` type alias declared in
--   lib/epoll/init.lua is not visible across modules. Once cross-module named
--   types are supported, type this as `epoll | nil`."
--
-- What a CORRECT checker must conclude:
--   A type alias `--:: Epoll = { ... }` declared in module A must be usable
--   in module B's annotations when B requires A. A parameter annotated as
--   `Epoll | nil` must narrow correctly after a nil-guard. Field access on the
--   narrowed value (`ep.wait()`) must succeed without errors.
--
--   In-file (same-module) form: the alias IS visible — this fixture confirms
--   that the narrowing and field access work correctly when the alias is local.
--   The real cross-module gap requires checking lib/dns/tcp_client.lua against
--   lib/epoll/init.lua together; that pair is the true repro.
--
-- Feature families:
--   - Type aliases (`--:: Foo = ...`) — cross-module visibility
--   - `require` return type inference (exported alias propagation)
--   - Optional parameters typed with named types (`Foo | nil`)
--   - Nil-narrowing / field access after nil-guard on union type
--
-- Legacy verdict (CURRENT checker): 0 errors for the in-file alias form.
--   The cross-module form (dns/tcp_client.lua uses `unknown | nil` as a
--   documented workaround) is a remaining gap: to verify, run
--   `bin/cr check lib/dns/tcp_client.lua` and observe `epoll: unknown | nil`.
--   A correct checker must propagate the alias across the require boundary
--   and allow `epoll: Epoll | nil` with correct narrowing.

--:: Epoll = { fd: integer, wait: () -> nil }

--: (cb: () -> nil, epoll: Epoll | nil) -> nil
local function connect(cb, epoll)
  local ep = epoll
  if ep == nil then
    -- Simulate creating a new handle when none was injected.
    ep = { fd = 0, wait = function() end }
  end
  -- After nil-guard, ep is narrowed to Epoll; .wait() is accessible.
  ep.wait()
  cb()
end

return { connect = connect }
