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

		-- Regression test: wait()'s EV_EOF handling used to call the same
		-- remove_fd() that only cleared this module's own bookkeeping
		-- (read_cbs/rets/count/...) without issuing the EV_DELETE kevent
		-- changes, unlike add()'s returned `remove` closure which always
		-- did. A fd removed via that internal path stayed registered in
		-- the kernel kqueue set forever, so EV_EOF kept re-firing on every
		-- subsequent kevent() call -- the same livelock shape as the
		-- epoll HUP/RDHUP bug fixed alongside this one.
		--
		-- The witness differs from epoll's, though: EPOLL_CTL_ADD on an
		-- already-registered fd fails with EEXIST, which epoll's test
		-- uses directly. kqueue's EV_ADD has upsert semantics -- adding a
		-- filter that is already registered for a fd just updates the
		-- existing knote and does not error (this is also why
		-- kqueue.add()'s own "duplicate fd" test above is a purely
		-- Lua-side read_cbs check, not a kernel-level one). So instead we
		-- issue an EV_DELETE ourselves after the internal removal and
		-- check the kernel's answer: with nevents=0, kevent() reports a
		-- failing change via the call's own return value, and deleting a
		-- filter that has no registered knote fails with ENOENT. If the
		-- internal path had left the knote registered (the bug), this
		-- manual delete would instead succeed.
		T.it("a fd removed via the internal EV_EOF path is fully deregistered from the kernel", function()
			local pipefd = ffi.new("int[2]")
			assert(ffi.C.pipe(pipefd) == 0, "pipe() failed")
			local read_fd, write_fd = pipefd[0], pipefd[1]

			local kq = kqueue.new()
			local hup_count = 0
			local w, r = kq:add(read_fd, function() end, function() hup_count = hup_count + 1 end)
			T.ok(w, "add returned write function")
			T.ok(r, "add returned remove function")

			-- Closing the write end makes the read end hang up (EV_EOF).
			ffi.C.close(write_fd)

			-- wait() observes the hangup and removes read_fd via the
			-- internal EV_EOF path (remove_fd), NOT via the `r` closure
			-- returned above.
			kq:wait(1000)
			T.eq(hup_count, 1, "close callback fired once on hangup")
			T.eq(kq.count, 0, "bookkeeping count dropped to 0 after internal removal")

			-- Kernel-level witness: deleting an already-absent knote
			-- fails with ENOENT (return -1) when nevents=0. If the
			-- EV_EOF path hadn't issued EV_DELETE, this knote would
			-- still exist and the delete would succeed (return 0).
			local del = ffi.new("struct kevent[1]")
			del[0].ident = read_fd
			del[0].filter = -1 --[[EVFILT_READ]]
			del[0].flags = 0x0002 --[[EV_DELETE]]
			del[0].fflags = 0
			del[0].data = 0
			del[0].udata = nil
			local ret = ffi.C.kevent(kq.fd, del, 1, nil, 0, nil)
			T.ok(ret < 0, "deleting the fd's knote after internal removal failed with ENOENT (regression: EV_EOF-path removal left the knote registered in the kernel)")

			ffi.C.close(read_fd)
		end)
	end)
end)
