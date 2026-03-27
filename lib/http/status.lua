-- RFC 9110 §15 — Status Codes

local mod = {}

-- RFC 9110 §15 — Standard status codes
mod.status_names = {
	-- RFC 9110 §15.2 — Informational 1xx
	[100] = "Continue",
	[101] = "Switching Protocols",
	[102] = "Processing",
	-- RFC 9110 §15.3 — Successful 2xx
	[200] = "OK",
	[201] = "Created",
	[202] = "Accepted",
	[203] = "Non-Authoritative Information",
	[204] = "No Content",
	[206] = "Partial Content",
	[207] = "Multi-Status",
	-- RFC 9110 §15.4 — Redirection 3xx
	[300] = "Multiple Choices",
	[301] = "Moved Permanently",
	[302] = "Found",
	[303] = "See Other",
	[304] = "Not Modified",
	[305] = "Use Proxy",
	[307] = "Temporary Redirect",
	[308] = "Permanent Redirect",
	-- RFC 9110 §15.5 — Client Error 4xx
	[400] = "Bad Request",
	[401] = "Unauthorized",
	[402] = "Payment Required",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[406] = "Not Acceptable",
	[407] = "Proxy Authentication Required",
	[408] = "Request Timeout",
	[409] = "Conflict",
	[410] = "Gone",
	[411] = "Length Required",
	[412] = "Precondition Failed",
	[413] = "Payload Too Large",
	[414] = "Request-URI Too Long",
	[415] = "Unsupported Media Type",
	[416] = "Request Range Not Satisfiable",
	[417] = "Expectation Failed",
	[421] = "Misdirected Request",
	[422] = "Unprocessable Entity",
	[423] = "Locked",
	[424] = "Failed Dependency",
	[425] = "Too Early",
	[426] = "Upgrade Required",
	[429] = "Too Many Requests",
	[431] = "Request Header Fields Too Large",
	[451] = "Unavailable For Legal Reasons",
	-- RFC 9110 §15.6 — Server Error 5xx
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
	[502] = "Bad Gateway",
	[503] = "Service Unavailable",
	[504] = "Gateway Timeout",
	[506] = "Variant Also Negotiates",
	[507] = "Insufficient Storage",
	[508] = "Loop Detected",
	[510] = "Not Extended",
	[511] = "Network Authentication Required",
}

-- Non-standard / vendor codes not defined in RFC 9110
mod.nonstandard_status_names = {
	[418] = "I'm a teapot",           -- RFC 2324 (joke RFC)
	[420] = "Enhance Your Calm",      -- Twitter
	[444] = "No Response",            -- nginx
	[450] = "Blocked by Windows Parental Controls", -- Microsoft
	[497] = "HTTP Request Sent to HTTPS Port", -- nginx
	[498] = "Token expired/invalid",  -- Esri
	[499] = "Client Closed Request",  -- nginx
	[509] = "Bandwidth Limit Exceeded", -- cPanel/Apache
	[521] = "Web Server Is Down",     -- Cloudflare
	[522] = "Connection Timed Out",   -- Cloudflare
	[523] = "Origin Is Unreachable",  -- Cloudflare
	[525] = "SSL Handshake Failed",   -- Cloudflare
	[599] = "Network Connect Timeout Error", -- proxy
}

--[[@enum http_status]]
mod.status_ids = {
	continue = 100,
	switching_protocols = 101,
	processing = 102,
	ok = 200,
	created = 201,
	accepted = 202,
	non_authoritative_information = 203,
	no_content = 204,
	partial_content = 206,
	multi_status = 207,
	multiple_choices = 300,
	moved_permanently = 301,
	found = 302,
	see_other = 303,
	not_modified = 304,
	use_proxy = 305,
	temporary_redirect = 307,
	permanent_redirect = 308,
	bad_request = 400,
	unauthorized = 401,
	payment_required = 402,
	forbidden = 403,
	not_found = 404,
	method_not_allowed = 405,
	not_acceptable = 406,
	proxy_authentication_required = 407,
	request_timeout = 408,
	conflict = 409,
	gone = 410,
	length_required = 411,
	precondition_failed = 412,
	payload_too_large = 413,
	request_uri_too_long = 414,
	unsupported_media_type = 415,
	request_range_not_satisfiable = 416,
	expectation_failed = 417,
	im_a_teapot = 418,
	enhance_your_calm = 420,
	misdirected_request = 421,
	unprocessable_entity = 422,
	locked = 423,
	failed_dependency = 424,
	too_early = 425,
	upgrade_required = 426,
	too_many_requests = 429,
	request_header_fields_too_large = 431,
	no_response = 444,
	blocked_by_windows_parental_controls = 450,
	unavailable_for_legal_reasons = 451,
	http_request_sent_to_https_port = 497,
	token_expired_or_invalid = 498,
	client_closed_request = 499,
	internal_server_error = 500,
	not_implemented = 501,
	bad_gateway = 502,
	service_unavailable = 503,
	gateway_timeout = 504,
	variant_also_negotiates = 506,
	insufficient_storage = 507,
	loop_detected = 508,
	bandwidth_limit_exceeded = 509,
	not_extended = 510,
	network_authentication_required = 511,
	web_server_is_down = 521,
	connection_timed_out = 522,
	origin_is_unreachable = 523,
	ssl_handshake_failed = 525,
	network_connect_timeout_error = 599,
}

return mod
