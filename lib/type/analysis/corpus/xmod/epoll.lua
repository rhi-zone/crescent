-- Cross-module fixture — EXPORTING module (the `lib/epoll/init.lua` shape).
--
-- Declares the `Epoll` type alias that the ENTRY module (xmod/tcp_client.lua)
-- references by bare name across the `require` boundary. This is the exporting
-- half of the TRUE cross-module form of the original
-- `fixture_cross_module_type_alias.lua` (whose in-file form is the same-module
-- approximation). See docs/agnostic-static-analysis-crescent-slice.md §6.6.

--:: Epoll = { fd: integer, wait: () -> nil }

--: () -> Epoll
local function new()
  return { fd = 0, wait = function() end }
end

return { new = new }
