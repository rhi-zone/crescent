-- lib/type/static/v2/stdlib.d.lua
-- Lua 5.1 / LuaJIT standard library type declarations.
-- Loaded by prelude.populate(); no executable code here.
-- Variable bindings use --:: declare name = type.
-- Type aliases (for primitive meta types) use --:: name = type.

---------------------------------------------------------------------------
-- Global functions
---------------------------------------------------------------------------

--:: declare print = (...any) -> ()
--:: declare tostring = (any) -> string
--:: declare tonumber = (any, any?) -> number?
--:: declare type = (any) -> string
--:: declare error = (any, any?) -> never
--:: declare assert = (any, ...any) -> any
--:: declare pcall = (any, ...any) -> (boolean, any)
--:: declare xpcall = (any, any, ...any) -> (boolean, any)
--:: declare require = (string) -> any
--:: declare select = (any, ...any) -> any
--:: declare rawget = (any, any) -> any
--:: declare rawset = (any, any, any) -> any
--:: declare rawequal = (any, any) -> boolean
--:: declare rawlen = (any) -> integer
--:: declare unpack = (any, any?, any?) -> any
--:: declare pairs = (any) -> ((any, any) -> (any, any), any, any)
--:: declare ipairs = (any) -> ((any, integer) -> (integer, any), any, integer)
--:: declare next = (any, any?) -> (any, any)
--:: declare setmetatable = (any, any?) -> any
--:: declare getmetatable = (any) -> any
--:: declare collectgarbage = (any?, any?) -> any
--:: declare gcinfo = () -> integer
--:: declare dofile = (any?) -> any
--:: declare loadfile = (any?) -> (any, any?)
--:: declare loadstring = (string, any?) -> (any, any?)
--:: declare load = (any, any?, any?, any?) -> (any, any?)
--:: declare newproxy = (any?) -> any
--:: declare rawprint = (any) -> ()
--:: declare _VERSION = string
--:: declare ffi = any
--:: declare bit = any
--:: declare jit = any

---------------------------------------------------------------------------
-- string table
---------------------------------------------------------------------------

--[[::
declare string = {
    format:  (string, ...any) -> string,
    len:     (string) -> integer,
    sub:     (string, integer, any?) -> string,
    find:    (string, string, any?, any?) -> (any, any),
    match:   (string, string, any?) -> any,
    gmatch:  (string, string) -> any,
    gsub:    (string, string, any, any?) -> (string, integer),
    rep:     (string, integer, any?) -> string,
    byte:    (string, any?, any?) -> integer,
    char:    (...integer) -> string,
    upper:   (string) -> string,
    lower:   (string) -> string,
    reverse: (string) -> string,
    dump:    (any, any?) -> string
}
]]

---------------------------------------------------------------------------
-- table table
---------------------------------------------------------------------------

--[[::
declare table = {
    insert:  (any, any) -> (),
    remove:  (any, any?) -> any,
    concat:  (any, any?, any?, any?) -> string,
    sort:    (any, any?) -> (),
    unpack:  (any, any?, any?) -> any,
    move:    (any, integer, integer, integer, any?) -> any,
    maxn:    (any) -> integer
}
]]

---------------------------------------------------------------------------
-- math table
---------------------------------------------------------------------------

--[[::
declare math = {
    floor:      (number) -> integer,
    ceil:       (number) -> integer,
    abs:        (number) -> number,
    sqrt:       (number) -> number,
    max:        (number, ...number) -> number,
    min:        (number, ...number) -> number,
    random:     (any?, any?) -> number,
    randomseed: (number) -> (),
    sin:        (number) -> number,
    cos:        (number) -> number,
    tan:        (number) -> number,
    asin:       (number) -> number,
    acos:       (number) -> number,
    atan:       (number) -> number,
    atan2:      (number, number) -> number,
    exp:        (number) -> number,
    log:        (number, any?) -> number,
    log10:      (number) -> number,
    pow:        (number, number) -> number,
    fmod:       (number, number) -> number,
    modf:       (number) -> (number, number),
    frexp:      (number) -> (number, integer),
    ldexp:      (number, integer) -> number,
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
    open:    (string, any?) -> (any, any?),
    close:   (any?) -> any,
    write:   (...any) -> any,
    read:    (...any) -> any,
    lines:   (any?, ...any) -> any,
    popen:   (string, any?) -> (any, any?),
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
    time:     (any?) -> integer,
    clock:    () -> number,
    date:     (any?, any?) -> any,
    exit:     (any?, any?) -> (),
    getenv:   (string) -> string?,
    difftime: (number, number) -> number,
    rename:   (string, string) -> (boolean, any?),
    remove:   (string) -> (boolean, any?),
    tmpname:  () -> string,
    execute:  (any?) -> (any, any?, integer?)
}
]]

---------------------------------------------------------------------------
-- coroutine table
---------------------------------------------------------------------------

--[[::
declare coroutine = {
    create:     (any) -> any,
    resume:     (any, ...any) -> (boolean, any),
    yield:      (...any) -> any,
    wrap:       (any) -> any,
    status:     (any) -> string,
    running:    () -> (any, boolean),
    isyieldable: () -> boolean
}
]]

---------------------------------------------------------------------------
-- debug table (minimal)
---------------------------------------------------------------------------

--[[::
declare debug = {
    getinfo:      (any, any?) -> any,
    traceback:    (any?, any?, any?) -> string,
    sethook:      (any, any, any?) -> (),
    getlocal:     (any, integer) -> (string, any),
    setlocal:     (any, integer, any) -> string,
    getmetatable: (any) -> any,
    setmetatable: (any, any?) -> any
}
]]

---------------------------------------------------------------------------
-- Primitive meta type aliases
-- Type aliases (no 'declare') for ctx.number_meta_tid etc.
-- Used by unify.lua when checking structural meta constraints.
---------------------------------------------------------------------------

--[[::
number_meta = {
    #__add:    (number, number) -> number,
    #__sub:    (number, number) -> number,
    #__mul:    (number, number) -> number,
    #__div:    (number, number) -> number,
    #__mod:    (number, number) -> number,
    #__pow:    (number, number) -> number,
    #__unm:    (number) -> number,
    #__lt:     (number, number) -> boolean,
    #__le:     (number, number) -> boolean,
    #__concat: (any, any) -> string
}
]]

--[[::
integer_meta = {
    #__add:    (integer, integer) -> integer,
    #__sub:    (integer, integer) -> integer,
    #__mul:    (integer, integer) -> integer,
    #__div:    (integer, integer) -> number,
    #__mod:    (integer, integer) -> integer,
    #__pow:    (integer, number) -> number,
    #__unm:    (integer) -> integer,
    #__lt:     (number, number) -> boolean,
    #__le:     (number, number) -> boolean,
    #__concat: (any, any) -> string
}
]]

--[[::
string_meta_ops = {
    #__concat: (string, any) -> string,
    #__len:    (string) -> integer,
    #__lt:     (string, string) -> boolean,
    #__le:     (string, string) -> boolean
}
]]
