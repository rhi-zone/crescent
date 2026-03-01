-- lib/type/static/stdlib.d.lua
-- LuaJIT / Lua 5.1 standard library type declarations.
-- Loaded by builtins.lua; no executable code here.

-- Global functions
--: declare print: (...any) -> ()
--: declare tostring: (any) -> string
--: declare tonumber: (any) -> number?
--: declare type: (any) -> string
--: declare error: (any) -> never
--: declare assert: (any, ...any) -> any
--: declare pcall: ((any) -> any, ...any) -> (boolean, any)
--: declare xpcall: ((any) -> any, (any) -> any) -> (boolean, any)
--: declare require: (string) -> any
--: declare select: (integer | string, ...any) -> any
--: declare rawget: ({}, any) -> any
--: declare rawset: ({}, any, any) -> {}
--: declare rawequal: (any, any) -> boolean
--: declare rawlen: (any) -> integer
--: declare unpack: ({}, integer?, integer?) -> any
--: declare pairs: ({}) -> (() -> (any, any), {}, nil)
--: declare ipairs: ({}) -> (() -> (integer, any), {}, integer)
--: declare next: ({}, any?) -> (any, any)
--: declare setmetatable: ({}, {}?) -> {}
--: declare getmetatable: (any) -> {}?
--: declare collectgarbage: (string?) -> any
--: declare dofile: (string?) -> any
--: declare loadfile: (string?) -> (any, string?)
--: declare load: (string | (() -> string?)) -> (any, string?)
--: declare loadstring: (string) -> (any, string?)
--: declare true: true
--: declare false: false
--: declare nil: nil
--: declare _VERSION: string
--: declare arg: string[]

--[[:
declare table: {
  concat: ({}, string?, integer?, integer?) -> string,
  insert: ({}, any) -> (),
  remove: ({}, integer?) -> any,
  sort: ({}, ((any, any) -> boolean)?) -> (),
  move: ({}, integer, integer, integer, {}?) -> {}
}
]]

--[[:
declare string: {
  byte: (string, integer?, integer?) -> integer,
  char: (...integer) -> string,
  find: (string, string, integer?, boolean?) -> (integer?, integer?),
  format: (string, ...any) -> string,
  gmatch: (string, string) -> (() -> any),
  gsub: (string, string, string | {} | ((string) -> string), integer?) -> (string, integer),
  len: (string) -> integer,
  lower: (string) -> string,
  upper: (string) -> string,
  match: (string, string, integer?) -> (string?, string?, string?, string?),
  rep: (string, integer, string?) -> string,
  reverse: (string) -> string,
  sub: (string, integer, integer?) -> string,
  dump: ((any) -> any) -> string
}
]]

--[[:
declare math: {
  abs: (number) -> number,
  ceil: (number) -> integer,
  floor: (number) -> integer,
  sqrt: (number) -> number,
  sin: (number) -> number,
  cos: (number) -> number,
  tan: (number) -> number,
  log: (number, number?) -> number,
  exp: (number) -> number,
  max: (number, ...number) -> number,
  min: (number, ...number) -> number,
  random: (integer?, integer?) -> number,
  randomseed: (number) -> (),
  huge: number,
  pi: number,
  maxinteger: integer,
  mininteger: integer
}
]]

--[[::
  File = {
    read: (any) -> string?,
    write: (...any) -> any,
    close: () -> (boolean?, string?),
    lines: () -> (() -> string?),
    seek: (string?, integer?) -> (integer?, string?),
    flush: () -> ()
  }
]]

--[[:
declare io: {
  open: (string, string?) -> (File?, string?),
  close: (any?) -> (boolean?, string?),
  read: (...any) -> string?,
  write: (...any) -> any,
  lines: (string?) -> (() -> string?),
  stdin: File,
  stdout: File,
  stderr: File
}
]]

--[[:
declare os: {
  time: ({}?) -> integer,
  date: (string?, integer?) -> (string | {}),
  clock: () -> number,
  execute: (string?) -> (boolean?, string?, integer?),
  getenv: (string) -> string?,
  remove: (string) -> (boolean?, string?),
  rename: (string, string) -> (boolean?, string?),
  exit: ((boolean | integer)?) -> (),
  tmpname: () -> string
}
]]

--[[:
declare debug: {
  getinfo: (any, string?) -> { source?: string, short_src?: string, what?: string, currentline?: integer, linedefined?: integer, name?: string },
  sethook: ((() -> ()), string, integer?) -> (),
  getlocal: (any, integer) -> (string?, any),
  setlocal: (any, integer, any) -> string?,
  getmetatable: (any) -> {}?,
  setmetatable: (any, {}?) -> any,
  traceback: (string?, integer?) -> string,
  getupvalue: (any, integer) -> (string?, any),
  setupvalue: (any, integer, any) -> string?
}
]]

--[[:
declare ffi: {
  cdef: (string) -> (),
  new: (string | any, ...any) -> any,
  cast: (string | any, any) -> any,
  typeof: (string) -> any,
  sizeof: (any) -> integer,
  string: (any, integer?) -> string,
  copy: (any, any, integer) -> (),
  fill: (any, integer, integer?) -> (),
  istype: (any, any) -> boolean,
  C: any,
  os: string,
  arch: string
}
]]

--[[:
declare bit: {
  tobit: (number) -> integer,
  tohex: (number, integer?) -> string,
  bnot: (number) -> integer,
  band: (number, ...number) -> integer,
  bor: (number, ...number) -> integer,
  bxor: (number, ...number) -> integer,
  lshift: (number, number) -> integer,
  rshift: (number, number) -> integer,
  arshift: (number, number) -> integer,
  rol: (number, number) -> integer,
  ror: (number, number) -> integer,
  bswap: (number) -> integer
}
]]
