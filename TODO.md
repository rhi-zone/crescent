# TODO

## stdlib
- [ ] http: extract network layer (client.lua, server.lua) — needs lib/ljsocket, lib/epoll, lib/socket/server.lua
- [ ] http: extract routers — needs lib/path, lib/mimetype, lib/fs, lib/lunajson
- [ ] Extract and polish websocket from ~/git/lua
- [ ] Extract and polish dns from ~/git/lua
- [ ] Extract and polish sqlite from ~/git/lua
- [ ] Extract and polish fs utilities from ~/git/lua

## typechecker
- [ ] Parse LuaJIT FFI cdef blocks
- [ ] Type inference for local bindings
- [ ] Structural typing for tables
- [ ] Typed holes / completions

## infra
- [ ] Bench infrastructure (pure Lua, handgrown)
- [ ] Fuzz infrastructure (pure Lua, handgrown)
- [ ] Formalize code style conventions — don't assume ~/git/lua conventions are correct, decide fresh
- [ ] `cr` binary entry point
- [ ] Third-party libs under lib/ must preserve original LICENSE

## package manager
- [ ] Vendor-first install (copy .lua files into project)
- [ ] Registry / index format
