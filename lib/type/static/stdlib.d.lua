-- lib/type/static/stdlib.d.lua
-- Lua 5.1 / LuaJIT standard library type declarations.
-- Loaded by prelude.populate(); no executable code here.
-- Variable bindings use --:: declare name = type.
-- Type aliases (for primitive meta types) use --:: name = type.

---------------------------------------------------------------------------
-- Global functions
---------------------------------------------------------------------------

--:: declare print = (...any) -> ()
--:: declare tostring = (val: any) -> string
--:: declare tonumber = (val: any, base: any?) -> number?
--:: declare type = (val: any) -> string
--:: declare error = (msg: any, level: any?) -> never
--:: declare assert = (val: any, ...any) -> any
--:: declare pcall = (fn: any, ...any) -> (boolean, any)
--:: declare xpcall = (fn: any, msgh: any, ...any) -> (boolean, any)
--:: declare require = (modname: string) -> any
--:: declare select = (index: any, ...any) -> any
--:: declare rawget = (t: any, k: any) -> any
--:: declare rawset = (t: any, k: any, v: any) -> any
--:: declare rawequal = (a: any, b: any) -> boolean
--:: declare rawlen = (t: any) -> integer
--:: declare unpack = (t: any, i: any?, j: any?) -> any
--:: declare pairs = (t: any) -> ((any, any) -> (any, any), any, any)
--:: declare ipairs = (t: any) -> ((any, integer) -> (integer, any), any, integer)
--:: declare next = (t: any, k: any?) -> (any, any)
--:: declare setmetatable = (t: any, mt: any?) -> any
--:: declare getmetatable = (t: any) -> any
--:: declare collectgarbage = (opt: any?, arg: any?) -> any
--:: declare gcinfo = () -> integer
--:: declare dofile = (filename: any?) -> any
--:: declare loadfile = (filename: any?) -> (any, any?)
--:: declare loadstring = (s: string, chunkname: any?) -> (any, any?)
--:: declare load = (chunk: any, chunkname: any?, mode: any?, env: any?) -> (any, any?)
--:: declare newproxy = (mt: any?) -> any
--:: declare rawprint = (s: any) -> ()
--:: declare _VERSION = string
--:: declare ffi = any
--:: declare _G = { [string]: any, ... }
--[[::
declare bit = {
    tobit:   (x: number) -> integer,
    tohex:   (x: integer, n: integer?) -> string,
    bnot:    (x: integer) -> integer,
    band:    (x: integer, ...integer) -> integer,
    bor:     (x: integer, ...integer) -> integer,
    bxor:    (x: integer, ...integer) -> integer,
    lshift:  (x: integer, n: integer) -> integer,
    rshift:  (x: integer, n: integer) -> integer,
    arshift: (x: integer, n: integer) -> integer,
    bswap:   (x: integer) -> integer,
    rol:     (x: integer, n: integer) -> integer,
    ror:     (x: integer, n: integer) -> integer
}
]]
--:: declare jit = any

---------------------------------------------------------------------------
-- string table
---------------------------------------------------------------------------

--[[::
declare string = {
    format:  (fmt: string, ...any) -> string,
    len:     (s: string) -> integer,
    sub:     (s: string, i: integer, j: any?) -> string,
    find:    (s: string, pattern: string, init: any?, plain: any?) -> (any, any),
    match:   (s: string, pattern: string, init: any?) -> any,
    gmatch:  (s: string, pattern: string) -> any,
    gsub:    (s: string, pattern: string, repl: any, n: any?) -> (string, integer),
    rep:     (s: string, n: integer, sep: any?) -> string,
    byte:    (s: string, i: any?, j: any?) -> integer,
    char:    (...integer) -> string,
    upper:   (s: string) -> string,
    lower:   (s: string) -> string,
    reverse: (s: string) -> string,
    dump:    (fn: any, strip: any?) -> string
}
]]

---------------------------------------------------------------------------
-- table table
---------------------------------------------------------------------------

--[[::
declare table = {
    insert:  (t: any, v: any) -> (),
    remove:  (t: any, pos: any?) -> any,
    concat:  (t: any, sep: any?, i: any?, j: any?) -> string,
    sort:    (t: any, comp: any?) -> (),
    unpack:  (t: any, i: any?, j: any?) -> any,
    move:    (a1: any, f: integer, e: integer, t: integer, a2: any?) -> any,
    maxn:    (t: any) -> integer
}
]]

---------------------------------------------------------------------------
-- math table
---------------------------------------------------------------------------

--[[::
declare math = {
    floor:      (x: number) -> integer,
    ceil:       (x: number) -> integer,
    abs:        (x: number) -> number,
    sqrt:       (x: number) -> number,
    max:        (x: number, ...number) -> number,
    min:        (x: number, ...number) -> number,
    random:     (m: any?, n: any?) -> number,
    randomseed: (x: number) -> (),
    sin:        (x: number) -> number,
    cos:        (x: number) -> number,
    tan:        (x: number) -> number,
    asin:       (x: number) -> number,
    acos:       (x: number) -> number,
    atan:       (x: number) -> number,
    atan2:      (y: number, x: number) -> number,
    exp:        (x: number) -> number,
    log:        (x: number, base: any?) -> number,
    log10:      (x: number) -> number,
    pow:        (x: number, y: number) -> number,
    fmod:       (x: number, y: number) -> number,
    modf:       (x: number) -> (number, number),
    frexp:      (x: number) -> (number, integer),
    ldexp:      (m: number, e: integer) -> number,
    huge:       number,
    pi:         number,
    max_integer: integer,
    min_integer: integer
}
]]

---------------------------------------------------------------------------
-- io table
---------------------------------------------------------------------------

--[[::
declare io = {
    open:    (path: string, mode: any?) -> (any, any?),
    close:   (file: any?) -> any,
    write:   (...any) -> any,
    read:    (...any) -> any,
    lines:   (filename: any?, ...any) -> any,
    popen:   (cmd: string, mode: any?) -> (any, any?),
    tmpfile: () -> any,
    stdin:   any,
    stdout:  any,
    stderr:  any
}
]]

---------------------------------------------------------------------------
-- os table
---------------------------------------------------------------------------

--[[::
declare os = {
    time:     (t: any?) -> integer,
    clock:    () -> number,
    date:     (format: any?, time: any?) -> any,
    exit:     (code: any?, close: any?) -> (),
    getenv:   (name: string) -> string?,
    difftime: (t2: number, t1: number) -> number,
    rename:   (oldname: string, newname: string) -> (boolean, any?),
    remove:   (path: string) -> (boolean, any?),
    tmpname:  () -> string,
    execute:  (cmd: any?) -> (any, any?, integer?)
}
]]

---------------------------------------------------------------------------
-- coroutine table
---------------------------------------------------------------------------

--[[::
declare coroutine = {
    create:     (fn: any) -> any,
    resume:     (co: any, ...any) -> (boolean, any),
    yield:      (...any) -> any,
    wrap:       (fn: any) -> any,
    status:     (co: any) -> string,
    running:    () -> (any, boolean),
    isyieldable: () -> boolean
}
]]

---------------------------------------------------------------------------
-- debug table (minimal)
---------------------------------------------------------------------------

--[[::
declare debug = {
    getinfo:      (thread_or_f: any, what: any?) -> any,
    traceback:    (thread_or_msg: any?, msg: any?, level: any?) -> string,
    sethook:      (thread_or_fn: any, mask: any, count: any?) -> (),
    getlocal:     (level: any, local_: integer) -> (string, any),
    setlocal:     (level: any, local_: integer, value: any) -> string,
    getmetatable: (t: any) -> any,
    setmetatable: (t: any, mt: any?) -> any
}
]]

---------------------------------------------------------------------------
-- Primitive meta type aliases
-- Type aliases (no 'declare') for ctx.number_meta_tid etc.
-- Used by unify.lua when checking structural meta constraints.
---------------------------------------------------------------------------

--[[::
number_meta = {
    #__add:    (a: number, b: number) -> number,
    #__sub:    (a: number, b: number) -> number,
    #__mul:    (a: number, b: number) -> number,
    #__div:    (a: number, b: number) -> number,
    #__mod:    (a: number, b: number) -> number,
    #__pow:    (a: number, b: number) -> number,
    #__unm:    (a: number) -> number,
    #__lt:     (a: number, b: number) -> boolean,
    #__le:     (a: number, b: number) -> boolean,
    #__concat: (a: any, b: any) -> string
}
]]

--[[::
integer_meta = {
    #__add:    (a: integer, b: integer) -> integer,
    #__sub:    (a: integer, b: integer) -> integer,
    #__mul:    (a: integer, b: integer) -> integer,
    #__div:    (a: integer, b: integer) -> number,
    #__mod:    (a: integer, b: integer) -> integer,
    #__pow:    (a: integer, b: number) -> number,
    #__unm:    (a: integer) -> integer,
    #__lt:     (a: number, b: number) -> boolean,
    #__le:     (a: number, b: number) -> boolean,
    #__concat: (a: any, b: any) -> string
}
]]

--[[::
string_meta_ops = {
    #__concat: (a: string, b: any) -> string,
    #__len:    (s: string) -> integer,
    #__lt:     (a: string, b: string) -> boolean,
    #__le:     (a: string, b: string) -> boolean
}
]]
