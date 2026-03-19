if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

return {
	format = require("lib.dns.format"),
	pretty_print = require("lib.dns.pretty_print"),
	tcp_client = require("lib.dns.tcp_client"),
}
