if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")

pcall(ffi.cdef, [[
  typedef struct {
    unsigned long __val[16]; /* 1024 / (8 * sizeof(unsigned long)) */
  } sigset_t;

  typedef void (*sighandler_t)(int);
  sighandler_t signal(int signum, sighandler_t handler);
  int kill(int pid, int sig);
  int getpid(void);
  int sigemptyset(sigset_t *set);
  int sigaddset(sigset_t *set, int signum);
  int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
]])

local SIG_DFL = ffi.cast("sighandler_t", 0)
local SIG_IGN = ffi.cast("sighandler_t", 1)

-- sigprocmask how constants
local SIG_BLOCK   = 0
local SIG_UNBLOCK = 1

local mod = {}

-- Signal constants (Linux x86_64)
--: number
mod.SIGHUP  = 1
mod.SIGINT  = 2
mod.SIGQUIT = 3
mod.SIGILL  = 4
mod.SIGABRT = 6
mod.SIGFPE  = 8
mod.SIGKILL = 9
mod.SIGUSR1 = 10
mod.SIGUSR2 = 12
mod.SIGPIPE = 13
mod.SIGALRM = 14
mod.SIGTERM = 15
mod.SIGCHLD = 17
mod.SIGCONT = 18
mod.SIGSTOP = 19
mod.SIGTSTP = 20

-- Store active callbacks to prevent GC
local callbacks = {} --[[@type table<integer, ffi.cdata*>]]

--- Install a Lua function as a signal handler.
--: (number, (number) -> nil) -> (boolean | nil, string | nil)
function mod.handle(signum, fn)
  -- Free previous callback for this signal if any
  local prev = callbacks[signum]
  local cb = ffi.cast("sighandler_t", fn)
  callbacks[signum] = cb
  local ret = ffi.C.signal(signum, cb)
  if ret == ffi.cast("sighandler_t", -1) then
    callbacks[signum] = prev
    return nil, "signal() failed"
  end
  if prev then prev:free() end
  return true
end

--- Ignore a signal.
--: (number) -> (boolean | nil, string | nil)
function mod.ignore(signum)
  local prev = callbacks[signum]
  local ret = ffi.C.signal(signum, SIG_IGN)
  if ret == ffi.cast("sighandler_t", -1) then
    return nil, "signal() failed"
  end
  if prev then prev:free() end
  callbacks[signum] = nil
  return true
end

--- Reset a signal to its default handler.
--: (number) -> (boolean | nil, string | nil)
function mod.default(signum)
  local prev = callbacks[signum]
  local ret = ffi.C.signal(signum, SIG_DFL)
  if ret == ffi.cast("sighandler_t", -1) then
    return nil, "signal() failed"
  end
  if prev then prev:free() end
  callbacks[signum] = nil
  return true
end

--- Send a signal to a process.
--: (number, number) -> (boolean | nil, string | nil)
function mod.kill(pid, signum)
  local ret = ffi.C.kill(pid, signum)
  if ret ~= 0 then return nil, "kill() failed" end
  return true
end

--- Get the current process ID.
--: () -> number
function mod.getpid()
  return ffi.C.getpid()
end

--- Block a signal.
--: (number) -> (boolean | nil, string | nil)
function mod.block(signum)
  local set = ffi.new("sigset_t")
  ffi.C.sigemptyset(set)
  ffi.C.sigaddset(set, signum)
  local ret = ffi.C.sigprocmask(SIG_BLOCK, set, nil)
  if ret ~= 0 then return nil, "sigprocmask() failed" end
  return true
end

--- Unblock a signal.
--: (number) -> (boolean | nil, string | nil)
function mod.unblock(signum)
  local set = ffi.new("sigset_t")
  ffi.C.sigemptyset(set)
  ffi.C.sigaddset(set, signum)
  local ret = ffi.C.sigprocmask(SIG_UNBLOCK, set, nil)
  if ret ~= 0 then return nil, "sigprocmask() failed" end
  return true
end

return mod
