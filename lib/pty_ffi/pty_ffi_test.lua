local ffi = require("ffi")
if ffi.os ~= "Linux" and ffi.os ~= "OSX" then return end

ffi.cdef[[
  int waitpid(int pid, int *status, int options);
  int execvp(const char *file, char *const argv[]);
  void _exit(int status);
]]

local T = require("lib.test.assert")

local ok_pty, pty = pcall(require, "lib.pty_ffi")
if not ok_pty then return end

T.describe("pty_ffi", function()
  T.describe("tier", function()
    T.it("exposes _tier as a string", function()
      T.ok(pty._tier == "system" or pty._tier == "posix",
        "_tier should be 'system' or 'posix', got: " .. tostring(pty._tier))
    end)
  end)

  T.describe("openpty", function()
    T.it("allocates a PTY pair", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      T.ok(slave, "openpty returned slave fd")
      T.ok(master >= 0, "master fd is non-negative")
      T.ok(slave >= 0, "slave fd is non-negative")
      T.ok(master ~= slave, "master and slave are different fds")
      pty.close(master)
      pty.close(slave)
    end)
  end)

  T.describe("set_winsize", function()
    T.it("sets terminal window size on a PTY", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      local ok_ws, err = pty.set_winsize(slave, 24, 80)
      T.ok(ok_ws, "set_winsize succeeded: " .. tostring(err))
      pty.close(master)
      pty.close(slave)
    end)
  end)

  T.describe("termios", function()
    T.it("gets and sets termios attributes", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      local termios, err = pty.tcgetattr(slave)
      T.ok(termios, "tcgetattr succeeded: " .. tostring(err))
      local ok_set, err2 = pty.tcsetattr(slave, termios)
      T.ok(ok_set, "tcsetattr succeeded: " .. tostring(err2))
      pty.close(master)
      pty.close(slave)
    end)

    T.it("applies cfmakeraw without error", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      local termios, err = pty.tcgetattr(slave)
      T.ok(termios, "tcgetattr succeeded: " .. tostring(err))
      pty.cfmakeraw(termios)
      local ok_set, err2 = pty.tcsetattr(slave, termios)
      T.ok(ok_set, "tcsetattr after cfmakeraw succeeded: " .. tostring(err2))
      pty.close(master)
      pty.close(slave)
    end)
  end)

  T.describe("forkpty", function()
    T.it("forks with a PTY and reads child output", function()
      local master, pid = pty.forkpty()
      T.ok(master, "forkpty returned a value")
      if master == 0 then
        -- child: exec echo
        local argv = ffi.new("const char*[3]")
        argv[0] = "echo"
        argv[1] = "hello_pty"
        argv[2] = nil
        ffi.C.execvp("echo", ffi.cast("char *const*", argv))
        ffi.C._exit(127)
      end
      -- parent
      T.ok(master > 0, "master fd is positive")
      T.ok(pid > 0, "child pid is positive")
      -- wait for child to finish
      local status = ffi.new("int[1]")
      ffi.C.waitpid(pid, status, 0)
      -- read output from master
      local output, err = pty.read(master)
      T.ok(output, "read from master succeeded: " .. tostring(err))
      T.ok(output:find("hello_pty"), "output contains 'hello_pty', got: " .. tostring(output))
      pty.close(master)
    end)
  end)

  T.describe("read and write", function()
    T.it("writes to master and reads from master", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      -- write to slave side, read from master side
      local n, err = pty.write(slave, "test_data")
      T.ok(n, "write succeeded: " .. tostring(err))
      T.ok(n > 0, "wrote bytes")
      local data, err2 = pty.read(master)
      T.ok(data, "read succeeded: " .. tostring(err2))
      T.ok(data:find("test_data"), "read data contains 'test_data', got: " .. tostring(data))
      pty.close(master)
      pty.close(slave)
    end)
  end)

  T.describe("close", function()
    T.it("closes a file descriptor", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      local ok_close, err = pty.close(master)
      T.ok(ok_close, "close master succeeded: " .. tostring(err))
      local ok_close2, err2 = pty.close(slave)
      T.ok(ok_close2, "close slave succeeded: " .. tostring(err2))
    end)

    T.it("returns error on double close", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      pty.close(master)
      local ok_close, err = pty.close(master)
      T.fail(ok_close, "double close should fail")
      T.ok(err, "error message returned")
      pty.close(slave)
    end)
  end)

  T.describe("set_nonblock", function()
    T.it("sets a fd to non-blocking mode", function()
      local master, slave = pty.openpty()
      T.ok(master, "openpty returned master fd")
      local ok_nb, err = pty.set_nonblock(master)
      T.ok(ok_nb, "set_nonblock succeeded: " .. tostring(err))
      pty.close(master)
      pty.close(slave)
    end)
  end)
end)
