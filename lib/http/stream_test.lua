local T = require("lib.test.assert")
local stream = require("lib.http.stream")

local describe, it = T.describe, T.it

--- Make a recv_fn from a list of string chunks.
local function mock_recv(chunks)
	local i = 0
	return function()
		i = i + 1
		return chunks[i]
	end
end

describe("http/stream", function()
	describe("read_headers", function()
		it("should parse status line and headers", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Foo: bar\r\n\r\nbody"
			}))
			local headers, err = s:read_headers()
			T.ok(headers, "headers returned")
			T.eq(s:status(), 200)
			T.eq(headers["content-type"][1], "text/plain")
			T.eq(headers["x-foo"][1], "bar")
		end)

		it("should handle headers split across chunks", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nContent",
				"-Type: text/html\r\n\r\n",
			}))
			local headers = s:read_headers()
			T.ok(headers)
			T.eq(s:status(), 200)
			T.eq(headers["content-type"][1], "text/html")
		end)

		it("should return error on incomplete headers", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nFoo: bar\r\n",
			}))
			local headers, err = s:read_headers()
			T.eq(headers, nil)
			T.eq(err, "incomplete headers")
		end)

		it("should parse multiple values for same header", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n"
			}))
			local headers = s:read_headers()
			T.ok(headers)
			T.eq(#headers["set-cookie"], 2)
			T.eq(headers["set-cookie"][1], "a=1")
			T.eq(headers["set-cookie"][2], "b=2")
		end)
	end)

	describe("read_body", function()
		it("should read body with Content-Length", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
			}))
			local body = s:read_body()
			T.eq(body, "hello")
		end)

		it("should read body split across chunks", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhel",
				"lo ",
				"worl",
				"d",
			}))
			local body = s:read_body()
			T.eq(body, "hello world")
		end)

		it("should read body until EOF when no Content-Length", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\nabc",
				"def",
			}))
			local body = s:read_body()
			T.eq(body, "abcdef")
		end)
	end)

	describe("chunks (chunked transfer encoding)", function()
		it("should decode chunked encoding", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
				"5\r\nhello\r\n",
				"6\r\n world\r\n",
				"0\r\n\r\n",
			}))
			local result = {}
			for chunk in s:chunks() do
				result[#result + 1] = chunk
			end
			T.eq(#result, 2)
			T.eq(result[1], "hello")
			T.eq(result[2], " world")
		end)

		it("should handle chunks split across recv boundaries", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
				"lo\r\n0\r\n\r\n",
			}))
			local result = {}
			for chunk in s:chunks() do
				result[#result + 1] = chunk
			end
			T.eq(#result, 1)
			T.eq(result[1], "hello")
		end)

		it("should handle chunk extensions", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
				"5;ext=val\r\nhello\r\n",
				"0\r\n\r\n",
			}))
			local result = {}
			for chunk in s:chunks() do
				result[#result + 1] = chunk
			end
			T.eq(#result, 1)
			T.eq(result[1], "hello")
		end)

		it("should handle hex chunk sizes", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
				"a\r\n0123456789\r\n",
				"0\r\n\r\n",
			}))
			local result = {}
			for chunk in s:chunks() do
				result[#result + 1] = chunk
			end
			T.eq(#result, 1)
			T.eq(result[1], "0123456789")
		end)
	end)

	describe("events (SSE)", function()
		it("should parse basic SSE events", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
				"data: hello\n\n",
				"data: world\n\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(#result, 2)
			T.eq(result[1].data, "hello")
			T.eq(result[2].data, "world")
		end)

		it("should parse event types", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\n",
				"event: message_start\ndata: {\"type\":\"start\"}\n\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(#result, 1)
			T.eq(result[1].event, "message_start")
			T.eq(result[1].data, '{"type":"start"}')
		end)

		it("should parse event IDs", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\n",
				"id: 42\ndata: test\n\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(result[1].id, "42")
			T.eq(result[1].data, "test")
		end)

		it("should handle multi-line data", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\n",
				"data: line1\ndata: line2\ndata: line3\n\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(result[1].data, "line1\nline2\nline3")
		end)

		it("should skip comments", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\n",
				": this is a comment\ndata: real\n\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(#result, 1)
			T.eq(result[1].data, "real")
		end)

		it("should handle data split across chunks", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\n",
				"data: hel",
				"lo\n\ndata: world\n\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(#result, 2)
			T.eq(result[1].data, "hello")
			T.eq(result[2].data, "world")
		end)

		it("should handle \\r\\n line endings in SSE", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\n",
				"data: test\r\n\r\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(#result, 1)
			T.eq(result[1].data, "test")
		end)

		it("should flush pending event at EOF", function()
			local s = stream.new(mock_recv({
				"HTTP/1.1 200 OK\r\n\r\n",
				"data: final\n",
			}))
			local result = {}
			for event in s:events() do
				result[#result + 1] = event
			end
			T.eq(#result, 1)
			T.eq(result[1].data, "final")
		end)
	end)
end)
