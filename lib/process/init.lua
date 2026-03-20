if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")

pcall(ffi.cdef, [[
  int pipe(int pipefd[2]);
  int fork(void);
  int execvp(const char *file, char *const argv[]);
  int waitpid(int pid, int *status, int options);
  int dup2(int oldfd, int newfd);
  int close(int fd);
  int chdir(const char *path);
  ssize_t read(int fd, void *buf, size_t count);
  ssize_t write(int fd, const void *buf, size_t count);
  int kill(int pid, int sig);
  char *strerror(int errnum);
  void _exit(int status);
  int setenv(const char *name, const char *value, int overwrite);
  int clearenv(void);
]])

local SIGTERM = 15
local SIGKILL = 9
local WNOHANG = 1

local buf = ffi.new("char[65536]")
local int1 = ffi.new("int[1]")
local int2 = ffi.new("int[2]")

local mod = {}

--[[@param fd integer]]
--[[@return string]]
local function read_fd(fd)
  local parts = {}
  while true do
    local n = ffi.C.read(fd, buf, 65536)
    if n <= 0 then break end
    parts[#parts + 1] = ffi.string(buf, n)
  end
  return table.concat(parts)
end

--[[@param status integer]]
--[[@return integer exit_code]]
local function decode_status(status)
  -- WIFEXITED: (status & 0x7f) == 0 → WEXITSTATUS: (status >> 8) & 0xff
  -- WIFSIGNALED: ((status & 0x7f) + 1) >> 1 > 0 → signal = status & 0x7f
  local lo = bit.band(status, 0x7f)
  if lo == 0 then
    return bit.band(bit.rshift(status, 8), 0xff)
  end
  -- killed by signal — return 128 + signal (shell convention)
  return 128 + lo
end

--: (string, string[]?, { stdin: string?, cwd: string?, env: { [string]: string }? }?) -> number, string, string | nil, string
function mod.exec(cmd, args, opts)
  opts = opts or {}

  -- create pipes: stdout, stderr, stdin (if needed)
  local stdout_pipe = ffi.new("int[2]")
  local stderr_pipe = ffi.new("int[2]")
  local stdin_pipe = opts.stdin and ffi.new("int[2]") or nil

  if ffi.C.pipe(stdout_pipe) ~= 0 then return nil, "pipe() failed for stdout" end
  if ffi.C.pipe(stderr_pipe) ~= 0 then
    ffi.C.close(stdout_pipe[0]); ffi.C.close(stdout_pipe[1])
    return nil, "pipe() failed for stderr"
  end
  if stdin_pipe and ffi.C.pipe(stdin_pipe) ~= 0 then
    ffi.C.close(stdout_pipe[0]); ffi.C.close(stdout_pipe[1])
    ffi.C.close(stderr_pipe[0]); ffi.C.close(stderr_pipe[1])
    return nil, "pipe() failed for stdin"
  end

  local pid = ffi.C.fork()
  if pid < 0 then
    ffi.C.close(stdout_pipe[0]); ffi.C.close(stdout_pipe[1])
    ffi.C.close(stderr_pipe[0]); ffi.C.close(stderr_pipe[1])
    if stdin_pipe then ffi.C.close(stdin_pipe[0]); ffi.C.close(stdin_pipe[1]) end
    return nil, "fork() failed"
  end

  if pid == 0 then
    -- child process
    -- redirect stdout
    ffi.C.close(stdout_pipe[0])
    ffi.C.dup2(stdout_pipe[1], 1)
    ffi.C.close(stdout_pipe[1])

    -- redirect stderr
    ffi.C.close(stderr_pipe[0])
    ffi.C.dup2(stderr_pipe[1], 2)
    ffi.C.close(stderr_pipe[1])

    -- redirect stdin
    if stdin_pipe then
      ffi.C.close(stdin_pipe[1])
      ffi.C.dup2(stdin_pipe[0], 0)
      ffi.C.close(stdin_pipe[0])
    end

    -- chdir if requested
    if opts.cwd then
      if ffi.C.chdir(opts.cwd) ~= 0 then ffi.C._exit(127) end
    end

    -- environment
    if opts.env then
      ffi.C.clearenv()
      for k, v in pairs(opts.env) do
        ffi.C.setenv(k, v, 1)
      end
    end

    -- build argv: {cmd, args..., NULL}
    local nargs = args and #args or 0
    local argv = ffi.new("const char*[?]", nargs + 2)
    argv[0] = cmd
    for i = 1, nargs do
      argv[i] = args[i]
    end
    argv[nargs + 1] = nil

    ffi.C.execvp(cmd, ffi.cast("char *const*", argv))
    -- execvp only returns on error
    ffi.C._exit(127)
  end

  -- parent process
  ffi.C.close(stdout_pipe[1])
  ffi.C.close(stderr_pipe[1])

  -- write stdin if provided, then close
  if stdin_pipe then
    ffi.C.close(stdin_pipe[0])
    local input = opts.stdin
    if input and #input > 0 then
      ffi.C.write(stdin_pipe[1], input, #input)
    end
    ffi.C.close(stdin_pipe[1])
  end

  -- read stdout and stderr
  local stdout_str = read_fd(stdout_pipe[0])
  local stderr_str = read_fd(stderr_pipe[0])

  ffi.C.close(stdout_pipe[0])
  ffi.C.close(stderr_pipe[0])

  -- wait for child
  ffi.C.waitpid(pid, int1, 0)
  local exit_code = decode_status(int1[0])

  return exit_code, stdout_str, stderr_str
end

--[[@class process_handle]]
--[[@field pid integer]]
local handle = {}
handle.__index = handle

--[[@param signal integer?]]
function handle:kill(signal)
  ffi.C.kill(self.pid, signal or SIGTERM)
end

--[[@return integer exit_code]]
function handle:wait()
  ffi.C.waitpid(self.pid, int1, 0)
  return decode_status(int1[0])
end

--: (string, string[]?, { cwd: string?, env: { [string]: string }? }?) -> { pid: number, kill: (self, number?) -> nil, wait: (self) -> number } | nil, string?
function mod.spawn(cmd, args, opts)
  opts = opts or {}

  local pid = ffi.C.fork()
  if pid < 0 then return nil, "fork() failed" end

  if pid == 0 then
    -- child process
    if opts.cwd then
      if ffi.C.chdir(opts.cwd) ~= 0 then ffi.C._exit(127) end
    end

    if opts.env then
      ffi.C.clearenv()
      for k, v in pairs(opts.env) do
        ffi.C.setenv(k, v, 1)
      end
    end

    local nargs = args and #args or 0
    local argv = ffi.new("const char*[?]", nargs + 2)
    argv[0] = cmd
    for i = 1, nargs do
      argv[i] = args[i]
    end
    argv[nargs + 1] = nil

    ffi.C.execvp(cmd, ffi.cast("char *const*", argv))
    ffi.C._exit(127)
  end

  -- parent
  return setmetatable({ pid = pid }, handle)
end

return mod
