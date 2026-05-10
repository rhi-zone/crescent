local mod = {}

--:: require "lib.http.server"

--: ({ [string]: (http_request, http_server_response, http_client_sock) -> unknown }) -> (http_request, http_server_response, http_client_sock) -> unknown
mod.router = function (cbs)
	return function (req, res, sock)
		local cb = cbs[req.method]
		if cb then return cb(req, res, sock) end
	end
end

return mod
