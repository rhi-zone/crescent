if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")
local bit = require("bit")

if ffi.os == "Windows" then return nil, "pty_ffi: not available on this platform" end

local is_linux = ffi.os == "Linux"
local is_macos = ffi.os == "OSX"

if not is_linux and not is_macos then
  return nil, "pty_ffi: unsupported platform: " .. ffi.os
end

local M = {}

-- ── Platform constants ──────────────────────────────────────────────────────

local TIOCSWINSZ = is_linux and 0x5414 or 0x80087467
local TIOCSCTTY  = is_linux and 0x540E or 0x20007461
local O_RDWR     = 2
local O_NOCTTY   = is_linux and 0x100 or 0x20000
local TCSANOW    = 0
local F_GETFL    = 3
local F_SETFL    = 4
local O_NONBLOCK = is_linux and 0x800 or 0x4

-- ── C declarations ──────────────────────────────────────────────────────────

ffi.cdef[[
  struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
  };

  int ioctl(int fd, unsigned long request, ...);
  int close(int fd);
  ssize_t read(int fd, void *buf, size_t count);
  ssize_t write(int fd, const void *buf, size_t count);
  char *strerror(int errnum);
  int fcntl(int fd, int cmd, ...);

  int fork(void);
  int setsid(void);
  int dup2(int oldfd, int newfd);
  void _exit(int status);
  int open(const char *pathname, int flags, ...);

  int posix_openpt(int flags);
  int grantpt(int fd);
  int unlockpt(int fd);
  char *ptsname(int fd);
]]

-- termios struct layout differs between Linux and macOS
if is_linux then
  ffi.cdef[[
    struct termios {
      unsigned int c_iflag;
      unsigned int c_oflag;
      unsigned int c_cflag;
      unsigned int c_lflag;
      unsigned char c_line;
      unsigned char c_cc[32];
      unsigned int c_ispeed;
      unsigned int c_ospeed;
    };
  ]]
else
  ffi.cdef[[
    struct termios {
      unsigned long c_iflag;
      unsigned long c_oflag;
      unsigned long c_cflag;
      unsigned long c_lflag;
      unsigned char c_cc[20];
      unsigned long c_ispeed;
      unsigned long c_ospeed;
    };
  ]]
end

ffi.cdef[[
  int tcgetattr(int fd, struct termios *termios_p);
  int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
  void cfmakeraw(struct termios *termios_p);
]]

-- forkpty/openpty declarations (used by system tier)
ffi.cdef[[
  int openpty(int *amaster, int *aslave, char *name,
              const struct termios *termp, const struct winsize *winp);
  int forkpty(int *amaster, char *name,
              const struct termios *termp, const struct winsize *winp);
]]

-- ── Helpers ─────────────────────────────────────────────────────────────────

local buf = ffi.new("char[65536]")
local int1 = ffi.new("int[1]")
local int2 = ffi.new("int[2]")

--: () -> string
local function last_error()
  return ffi.string(ffi.C.strerror(ffi.errno()))
end

-- ── Tier selection: openpty / forkpty ────────────────────────────────────────

-- Tier 1 (system): libc or libutil provide openpty/forkpty directly.
-- glibc >= 2.34 has them in libc. Older glibc needs libutil. macOS has them
-- in libSystem (accessible via ffi.C).
local tier_lib
do
  -- try libc first
  local ok = pcall(function() return ffi.C.openpty end)
  if ok then
    tier_lib = ffi.C
  else
    -- try libutil (older glibc, some BSDs)
    local ok2, lib = pcall(ffi.load, "util")
    if ok2 then
      tier_lib = lib
    end
  end
end

if tier_lib then
  M._tier = "system"
  --: () -> (integer, integer) | (nil, string)
  function M.openpty()
    if tier_lib.openpty(int1, int2, nil, nil, nil) == -1 then
      return nil, "pty_ffi: openpty: " .. last_error()
    end
    return int1[0], int2[0]
  end
  --: () -> (integer, integer) | (nil, string)
  function M.forkpty()
    local pid = tier_lib.forkpty(int1, nil, nil, nil)
    if pid == -1 then
      return nil, "pty_ffi: forkpty: " .. last_error()
    end
    if pid == 0 then
      -- child process
      return 0, 0
    end
    -- parent: int1[0] is master fd
    return int1[0], pid
  end
else
  -- Tier 2 (posix): hand-roll from POSIX primitives.
  -- posix_openpt, grantpt, unlockpt, ptsname are POSIX and present in musl,
  -- glibc, and macOS.
  M._tier = "posix"
  --: () -> (integer, integer) | (nil, string)
  function M.openpty()
    local master = ffi.C.posix_openpt(O_RDWR + O_NOCTTY)
    if master == -1 then
      return nil, "pty_ffi: posix_openpt: " .. last_error()
    end
    if ffi.C.grantpt(master) == -1 then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: grantpt: " .. err
    end
    if ffi.C.unlockpt(master) == -1 then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: unlockpt: " .. err
    end
    local name = ffi.C.ptsname(master)
    if name == nil then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: ptsname: " .. err
    end
    local slave = ffi.C.open(name, O_RDWR)
    if slave == -1 then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: open slave: " .. err
    end
    return master, slave
  end
  --: () -> (integer, integer) | (nil, string)
  function M.forkpty()
    -- Split openpty logic inline to avoid union unpacking
    local master = ffi.C.posix_openpt(O_RDWR + O_NOCTTY)
    if master == -1 then
      return nil, "pty_ffi: posix_openpt: " .. last_error()
    end
    if ffi.C.grantpt(master) == -1 then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: grantpt: " .. err
    end
    if ffi.C.unlockpt(master) == -1 then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: unlockpt: " .. err
    end
    local name = ffi.C.ptsname(master)
    if name == nil then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: ptsname: " .. err
    end
    local slave = ffi.C.open(name, O_RDWR)
    if slave == -1 then
      local err = last_error()
      ffi.C.close(master)
      return nil, "pty_ffi: open slave: " .. err
    end
    -- Now fork
    local pid = ffi.C.fork()
    if pid == -1 then
      local err = last_error()
      ffi.C.close(master)
      ffi.C.close(slave)
      return nil, "pty_ffi: fork: " .. err
    end
    if pid == 0 then
      -- child: new session, set controlling terminal
      ffi.C.close(master)
      ffi.C.setsid()
      ffi.C.ioctl(slave, TIOCSCTTY, 0)
      ffi.C.dup2(slave, 0)
      ffi.C.dup2(slave, 1)
      ffi.C.dup2(slave, 2)
      if slave > 2 then ffi.C.close(slave) end
      return 0, 0
    end
    -- parent
    ffi.C.close(slave)
    return master, pid
  end
end

-- ── termios ─────────────────────────────────────────────────────────────────

--: (integer) -> (cdata | nil, string | nil)
function M.tcgetattr(fd)
  local t = ffi.new("struct termios[1]")
  if ffi.C.tcgetattr(fd, t) == -1 then
    return nil, "pty_ffi: tcgetattr: " .. last_error()
  end
  return t
end

--: (integer, cdata) -> (true | nil, string | nil)
function M.tcsetattr(fd, termios)
  if ffi.C.tcsetattr(fd, TCSANOW, termios) == -1 then
    return nil, "pty_ffi: tcsetattr: " .. last_error()
  end
  return true
end

--: (cdata) -> nil
function M.cfmakeraw(termios)
  ffi.C.cfmakeraw(termios)
end

-- ── ioctl: window size ──────────────────────────────────────────────────────

--: (integer, integer, integer) -> (true | nil, string | nil)
function M.set_winsize(fd, rows, cols)
  local ws = ffi.new("struct winsize[1]")
  ws[0].ws_row = rows
  ws[0].ws_col = cols
  ws[0].ws_xpixel = 0
  ws[0].ws_ypixel = 0
  if ffi.C.ioctl(fd, TIOCSWINSZ, ws) == -1 then
    return nil, "pty_ffi: ioctl TIOCSWINSZ: " .. last_error()
  end
  return true
end

-- ── fd operations ───────────────────────────────────────────────────────────

--: (integer) -> (true | nil, string | nil)
function M.close(fd)
  if ffi.C.close(fd) == -1 then
    return nil, "pty_ffi: close: " .. last_error()
  end
  return true
end

--: (integer, integer | nil) -> (string | nil, string | nil)
function M.read(fd, n)
  local len = ffi.C.read(fd, buf, n or 65536)
  if len == -1 then
    return nil, "pty_ffi: read: " .. last_error()
  end
  return ffi.string(buf, len)
end

--: (integer, string) -> (integer | nil, string | nil)
function M.write(fd, data)
  local len = ffi.C.write(fd, data, #data)
  if len == -1 then
    return nil, "pty_ffi: write: " .. last_error()
  end
  return len --: integer
end

--: (integer) -> (true | nil, string | nil)
function M.set_nonblock(fd)
  local flags = ffi.C.fcntl(fd, F_GETFL)
  if flags == -1 then
    return nil, "pty_ffi: fcntl F_GETFL: " .. last_error()
  end
  if ffi.C.fcntl(fd, F_SETFL, ffi.cast("int", bit.bor(flags, O_NONBLOCK))) == -1 then
    return nil, "pty_ffi: fcntl F_SETFL: " .. last_error()
  end
  return true
end

return M
