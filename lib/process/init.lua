if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")
local bit = require("bit")
local close_fds = require("lib.os_isolation.close_fds")

ffi.cdef[[
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
]]

local SIGTERM = 15
local SIGKILL = 9
local WNOHANG = 1

local buf = (ffi.new("char[65536]") --[[: unknown]]) --[[:! integer & { [0]: integer }]]
local int1 = (ffi.new("int[1]") --[[: unknown]]) --[[:! { [0]: integer }]]
local int2 = (ffi.new("int[2]") --[[: unknown]]) --[[:! { [0]: integer, [1]: integer }]]

local mod = {}

--:: Process = { pid: integer, kill: (Process, integer | nil) -> nil, wait: (Process) -> integer }

--: (integer) -> string
local function read_fd(fd)
  local parts = {}
  while true do
    local n = ffi.C.read(fd, buf, 65536)
    if n <= 0 then break end
    parts[#parts + 1] = ffi.string(buf, n --[[:! integer]])
  end
  return table.concat(parts)
end

--: (integer) -> integer
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

--: (string, { [integer]: string } | nil, { stdin: string | nil, cwd: string | nil, env: { [string]: string } | nil } | nil) -> (integer | nil, string, string | nil)
function mod.exec(cmd, args, opts)
  --: { stdin: string | nil, cwd: string | nil, env: { [string]: string } | nil }
  local opts_ = (opts or {}) --[[:! { stdin: string | nil, cwd: string | nil, env: { [string]: string } | nil }]]
  opts = opts_

  -- create pipes: stdout, stderr, stdin (if needed)
  local stdout_pipe = (ffi.new("int[2]") --[[: unknown]]) --[[:! { [integer]: integer }]]
  local stderr_pipe = (ffi.new("int[2]") --[[: unknown]]) --[[:! { [integer]: integer }]]
  local stdin_pipe = (opts.stdin and ffi.new("int[2]") or nil) --[[: unknown]] --[[:! { [integer]: integer } | nil]]

  if ffi.C.pipe(stdout_pipe) ~= 0 then return nil, "pipe() failed for stdout", nil end
  if ffi.C.pipe(stderr_pipe) ~= 0 then
    ffi.C.close(stdout_pipe[0]); ffi.C.close(stdout_pipe[1])
    return nil, "pipe() failed for stderr", nil
  end
  if stdin_pipe and ffi.C.pipe(stdin_pipe) ~= 0 then
    ffi.C.close(stdout_pipe[0]); ffi.C.close(stdout_pipe[1])
    ffi.C.close(stderr_pipe[0]); ffi.C.close(stderr_pipe[1])
    return nil, "pipe() failed for stdin", nil
  end

  local pid = ffi.C.fork()
  if pid < 0 then
    ffi.C.close(stdout_pipe[0]); ffi.C.close(stdout_pipe[1])
    ffi.C.close(stderr_pipe[0]); ffi.C.close(stderr_pipe[1])
    if stdin_pipe then ffi.C.close(stdin_pipe[0]); ffi.C.close(stdin_pipe[1]) end
    return nil, "fork() failed", nil
  end

  if pid == 0 then
    -- child process
    -- Sweep every fd except the not-yet-dup2'd pipe ends this child is
    -- about to wire onto 0/1/2, before doing anything else -- including
    -- the dup2 dance itself. Descriptors survive exec unless CLOEXEC was
    -- set on them, so a leaked fd here would reach the exec'd program too.
    -- A sweep failure is fatal: proceeding into exec'd, caller-controlled
    -- code with an unknown descriptor set is exactly the hazard this
    -- guards against.
    do
      local keep = { stdout_pipe[1], stderr_pipe[1] } --[[: { [integer]: integer } ]]
      if stdin_pipe then keep[#keep + 1] = stdin_pipe[0] end
      local sweep_fn = close_fds.close_fds_except
      local swept = sweep_fn and sweep_fn(keep)
      if not swept then ffi.C._exit(126) end
    end

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
    --: { [integer]: string | nil }
    --: { [integer]: string | nil }
    local argv = (ffi.new("const char*[?]", nargs + 2) --[[: unknown]]) --[[:! { [integer]: string | nil }]]
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
    if input then
      local input_ = input --[[:! string]]
      if #input_ > 0 then
        ffi.C.write(stdin_pipe[1], input_, #input_)
      end
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

local handle = {}
handle.__index = handle

--: (self: Process, integer | nil) -> nil
function handle:kill(signal)
  ffi.C.kill(self.pid, signal or SIGTERM)
end

--: (self: Process) -> integer
function handle:wait()
  ffi.C.waitpid(self.pid, int1, 0)
  return decode_status(int1[0])
end

--: (string, { [integer]: string } | nil, { cwd: string | nil, env: { [string]: string } | nil } | nil) -> (Process | nil, string | nil)
function mod.spawn(cmd, args, opts)
  --: { cwd: string | nil, env: { [string]: string } | nil }
  local opts_ = (opts or {}) --[[:! { cwd: string | nil, env: { [string]: string } | nil }]]
  opts = opts_

  local pid = ffi.C.fork()
  if pid < 0 then return nil, "fork() failed" end

  if pid == 0 then
    -- child process
    -- mod.spawn has no pipes of its own -- the exec'd program inherits the
    -- caller's real stdio directly (this is the pass-through spawn, unlike
    -- mod.exec above which redirects stdout/stderr/stdin through pipes), so
    -- 0/1/2 are named explicitly here because the child genuinely needs
    -- them, not as an implicit default. A sweep failure is fatal: proceeding
    -- into exec'd, caller-controlled code with an unknown descriptor set is
    -- exactly the hazard this guards against.
    local sweep_fn = close_fds.close_fds_except
    local swept = sweep_fn and sweep_fn({ 0, 1, 2 })
    if not swept then ffi.C._exit(126) end

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
    --: { [integer]: string | nil }
    --: { [integer]: string | nil }
    local argv = (ffi.new("const char*[?]", nargs + 2) --[[: unknown]]) --[[:! { [integer]: string | nil }]]
    argv[0] = cmd
    for i = 1, nargs do
      argv[i] = args[i]
    end
    argv[nargs + 1] = nil

    ffi.C.execvp(cmd, ffi.cast("char *const*", argv))
    ffi.C._exit(127)
  end

  -- parent
  --: Process
  return (setmetatable({ pid = pid }, handle) --[[:! Process]])
end

return mod
