# TODO

## stdlib
- [ ] http: extract network layer (client.lua, server.lua) — needs lib/ljsocket, lib/epoll, lib/socket/server.lua
- [ ] http: extract routers — needs lib/path, lib/mimetype, lib/fs, lib/lunajson
- [ ] Review and polish all libraries pulled from ~/git/lua (bulk import done)
- [ ] lib/utf8.lua: crescent has a 29-line version, ~/git/lua had a 142-line version — reconcile
- [ ] lib/todo/: conflicts with dep/todo/ (stubs for jpeg, png, xcb, soloud + a sqlitex.lua, webp.lua) — decide what to keep
- [ ] Audit vendored third-party libs (ljsocket, lunajson, sqlite, cparser, etc.) — ensure LICENSE files present
- [ ] Review lib/cli/ scripts — many have implicit dep on lib/ layout, may need path fixups
- [ ] Remove or integrate duplicate/overlapping libs (e.g., mock.lua vs mock/, lil.lua vs lil/)

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
