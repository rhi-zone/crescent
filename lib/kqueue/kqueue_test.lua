local ffi = require("ffi")

local T = require("lib.test.assert")

local ok_kqueue, kqueue = pcall(require, "lib.kqueue")
if not ok_kqueue then return end

T.describe("kqueue", function()
	T.describe("api shape", function()
		T.it("exports new", function()
			T.eq(type(kqueue.new), "function")
		end)

		T.it("exports add", function()
			T.eq(type(kqueue.add), "function")
		end)

		T.it("exports wait", function()
			T.eq(type(kqueue.wait), "function")
		end)

		T.it("exports loop", function()
			T.eq(type(kqueue.loop), "function")
		end)

		T.it("exposes kqueue class with modify", function()
			T.ok(kqueue.kqueue, "kqueue.kqueue exists")
			T.eq(type(kqueue.kqueue.modify), "function")
		end)
	end)

	-- functional tests require macOS (ffi.os == "OSX"); kqueue() is not
	-- available on Linux. the api-shape checks above run everywhere.
	if ffi.os ~= "OSX" then return end

	pcall(ffi.cdef, "int pipe(int pipefd[2]);")
	pcall(ffi.cdef, "int close(int fd);")
	pcall(ffi.cdef, "ssize_t write(int fd, const void *buf, size_t count);")

	T.describe("functional", function()
		T.it("creates a kqueue instance", function()
			local kq = kqueue.new()
			T.ok(kq, "kqueue.new() returned a value")
			T.ok(kq.fd >= 0, "kqueue fd is non-negative")
			T.eq(kq.count, 0)
		end)

		T.it("adds a file descriptor and receives data", function()
			local pipefd = ffi.new("int[2]")
			assert(ffi.C.pipe(pipefd) == 0, "pipe() failed")

			local read_fd = pipefd[0]
			local write_fd = pipefd[1]

			local kq = kqueue.new()
			local received = false
			local write_fn, remove_fn = kq:add(read_fd, function(data)
				received = data
			end)

			T.ok(write_fn, "add returned write function")
			T.ok(remove_fn, "add returned remove function")
			T.eq(kq.count, 1)

			-- write to the pipe so EVFILT_READ fires
			local msg = "hello"
			ffi.C.write(write_fd, msg, #msg)

			kq:wait()
			T.eq(received, "hello")

			remove_fn()
			T.eq(kq.count, 0)
			ffi.C.close(read_fd)
			ffi.C.close(write_fd)
		end)

		T.it("returns error when adding duplicate fd", function()
			local pipefd = ffi.new("int[2]")
			assert(ffi.C.pipe(pipefd) == 0)

			local kq = kqueue.new()
			local _, _ = kq:add(pipefd[0], function() end)
			local w2, r2, err = kq:add(pipefd[0], function() end)
			T.eq(w2, nil)
			T.eq(r2, nil)
			T.ok(err, "got error string for duplicate fd")

			ffi.C.close(pipefd[0])
			ffi.C.close(pipefd[1])
		end)

		T.it("supports weak fds that don't increment count", function()
			local pipefd = ffi.new("int[2]")
			assert(ffi.C.pipe(pipefd) == 0)

			local kq = kqueue.new()
			local _, remove = kq:add(pipefd[0], function() end, nil, true)
			T.eq(kq.count, 0, "weak fd does not increment count")

			remove()
			T.eq(kq.count, 0)
			ffi.C.close(pipefd[0])
			ffi.C.close(pipefd[1])
		end)

		T.it("modifies a watched fd", function()
			local pipefd = ffi.new("int[2]")
			assert(ffi.C.pipe(pipefd) == 0)

			local kq = kqueue.new()
			kq:add(pipefd[0], function() end)

			local w, r = kq:modify(pipefd[0], function() end)
			T.ok(w, "modify returned write function")
			T.ok(r, "modify returned remove function")

			-- modify on unknown fd returns error
			local w2, r2, err = kq:modify(99999, function() end)
			T.eq(w2, nil)
			T.eq(r2, nil)
			T.ok(err, "got error for unknown fd")

			ffi.C.close(pipefd[0])
			ffi.C.close(pipefd[1])
		end)
	end)
end)
