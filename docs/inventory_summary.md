# Crescent inventory summary

At-a-glance index of what's in `lib/`. For per-library detail, grep `docs/inventory.md`.

## Type preludes
LuaJIT stdlib in `lib/type/static/stdlib_types.lua` (default-loaded). Browser/DOM/JS host surface (Element, Event, fetch, history, ...) in `lib/web/js_types.lua` (2078 lines). Other `_types.lua` for caps, http, imap, ccv2, taskgraph, ctx, and per-app preludes under `lib/platform/apps/*/`. **Use `lib/web/js_types.lua` before redeclaring any browser/JS type.**

## Type system / tooling
Static typechecker at `lib/type/static/` (stable; cli + lsp + parser + constrain/narrow/unify). Runtime schema typechecker at `lib/type/`. Wip: `lib/type/search/` (Hoogle-style), `lib/lua2ts/`, `lib/doc/`, `lib/lsp/`, `lib/mcp/`, `lib/pkg/` (foundation only — no install algo). Stable: `lib/jsonrpc/`, `lib/cr/`, `lib/cli/`, `lib/bundle/`, `lib/sandbox/`.

## Test infrastructure
`lib/test/` (runner, assert, coverage, fixture/snapshot, fuzz fast+guided, prop, arb integrated shrinking). `lib/bench/` micro-benchmarks. `lib/testing_utils/` (mocks, spies, fake clock, HTTP recorder). All stable.

## Network protocols
HTTP mature (server, client, routers, tested). Stable: WebSocket, SMTP, OAuth/OAuth2, GitHub, keyring, ljsocket, x509, wire framing. Wip: epoll, fuse, git, https, inotify, tls. Stub or broken: dns, imap, mud_cp, socket, tcp.

## Codecs / formats / serialization
JSON (multiple impls — `lib/json/` and tiered `lib/format/json/`), CBOR, MessagePack, TOML, YAML, BSON, Protobuf (`proto` and `protocol_buffer` parallel), CSV (+ csv_query, csv_transform), Avro absent, ASN.1, BCD via decimal, INI, NDJSON, netstring, multipart, PEM, struct, tar, PNG, SVG, XML, XPath, iCalendar, base32/58/64, ascii85, hex_dump, sexp, url, uuid, mime/mimetype.

## Compression
Brotli, tiered zlib/gzip (`lib/compress/`), Huffman, LZ4, LZ77 (raw), RLE, Snappy, Zstd. All stable.

## Crypto
Tiered AES-GCM/ChaCha20-Poly1305/HKDF (`lib/crypto/`) + pure-Lua bag (`lib/cryptography/`). Argon2, BLAKE2, JWT (HS256), Curve25519, Ed25519, PBKDF2, Poly1305, scrypt, SipHash, MurmurHash, Shamir, TOTP/HOTP, classical ciphers. `lib/hash/` rolls up md5/sha1/sha256/hmac/crc32/xxhash. All stable.

## Parsers / grammars / DSLs
PEG impls in three places (`lib/grammar/`, `lib/peg/`, `lib/parser_combinators/`). Tiered regex (PCRE2 > pure), Thompson-NFA `regexp`, regex_builder. CSS parser, GraphQL parser+schema+executor, Datalog, Prolog, µKanren. Diff (Myers + text_diff char-level), merge3, expression evaluators (`expr` and `expression_evaluator`), markdown (`markdown` and `markdown_it`), tokenizer, sscanf, glob, aho_corasick, log_parser.

## Markup / unified pipeline
`lib/unified/` (unified.js port — many submodules, wip with empty shells). Top-level `lib/hast/`, `lib/mdast/`, `lib/remark*`, `lib/rehype*` are stub shells; real impls live under `lib/unified/`. Stable text utilities: template/template_engine/string_template/mustache, html builder, word_wrap/text_justify/text_stats/spell_check/porter_stemmer/soundex/levenshtein/fuzzy_match/markov/nat_lang/i18n/locale/humanize.

## Web / UI
`lib/web/` framework (middleware, routing, cookies, CSRF, static, html builder, reactive_dom). `lib/glass-ui/` opt-in design tokens + components + theme toggle (CSS/JS, no Lua). Router, canvas (PPM/PGM/BMP), color toolchain, TUI on top of ANSI, layout, pretty_print, barcode, qrencode (wip).

## Reactive / state / signals
Push signals (`lib/reactive/`) and auto-tracking signals (`lib/signals/`) parallel. reactive_db (live queries), reactive_optics, reactive_store (Redux-style), reactive_stream (Rx pull), reactive_var. Two observable impls (`observable`, `observer`); two event-bus impls (`event`, `event_emitter`). pubsub, mediator, event_sourcing. `lib/signal/` is POSIX signals (different concept).

## Async / concurrency / scheduling
Coroutine actor model, async/await, async_queue, Go-style chan, promise, scheduler, semaphore family, task_queue, task_runner, taskgraph (wip), workflow, pipeline + pipeline_dsl, circuit_breaker, connection_pool, retry, cron + cron_parser (parallel), notify. Two rate-limit impls (`ratelimit`, `rate_limiter`). Linux timerfd wip.

## Data structures
bigint/bignum, bitarray/bits/bitset (parallel), bloom family (4 parallel impls), cache + lru/lru_cache/lru_ttl (parallel), columnar, consistent_hash, count_min, cuckoo, deque, disjoint_set, fenwick, hamt, heaps (heap, pairing_heap), hyperloglog, interval/interval_tree, inverted_index, kdtree, kv_store, multimap/multiset/ordered_map/set, patricia_trie, persistent, pool/pool_allocator, quadtree/spatial_hash, queue, red_black_tree, ringbuf, rope, segment_tree, skiplist, sparse_matrix, suffix_array, treap, trie. All stable.

## Numerics / math / stats / ML
astar, bayesian_filter, bezier, complex, constraint_solver, convex_hull, datetime/duration/time/time_series, decision_tree, dice, dsp, easing, finance/money, finite_field, flow_network, genetic, geo + geo_hash + geohash (duplicate), geom/geometry_3d/game_math/vec/matrix/matrix_ext, graph family (5 modules), gradient_descent, hamming, interpolation, kalman, knn, lindenmayer/lsystem (parallel), luhn, math_ext, minimax (+MCTS), neural/neural_net (parallel), noise/noise_gen (parallel), number_theory, particle, physics_2d, pid, rand, rational, roman/roman_numeral (parallel), sat (DPLL), simulated_annealing, stats, symbolic_diff, tfidf, units, voronoi, wavelet/wave, xgboost.

## Storage / DB
SQLite FFI (`lib/sqlite/`), conversation tree, db abstraction, ecs (SQLite) + entity_component (in-memory) parallel, mini_orm, query_builder, raft state machine, schema migrations.

## OS / FFI / platform
asm (CPU detect + kernel compile), caps (type aliases), env + env_schema, fs, path, process, exec, signal, stb (image FFI tiered). Wip: dynamic_library, linux /proc, posix. `lib/platform/` is the runner (tarball loader + sandboxed entrypoints + cap dispatch + daemon).

## Apps and demos
`lib/crescent_examples/` (demos, not a library). `lib/platform/apps/`: charactercardv2, library (collection browser), system_dashboard (BFF — packs + projections), sillytavern (wip).

## Game / generative / simulation
Two automata families parallel (`automata`/`finite_automata`, `automata_2d`/`cellular_automata`). behavior_tree, circuit_sim (analog MNA), logic_circuit (digital + Quine-McCluskey), midi, network_sim, solitaire, steering, tilemap. **Five FSM impls** (`state`, `state_machine`, `statemachine`, `state_machine_hsm`, `fsm`) — pick one.

## Reliability / observability / config
config (layered), feature_flags, log, metric (Prometheus), openapi, pagination, schema_gen, service_registry, tracing (OTel). Validation/schema impls overlap heavily: `schema_validator`, `json_schema`, `jsonschema`, `validate`, `validation` — pick one.

## FP / optics / monads
`lib/fp/` typeclass hierarchy (wip, design in flux — see `lib/fp/CLAUDE.md`). Stable adjacent: curry, either (top-level + fp/either parallel), functional, iter, option (parallel to fp/maybe), result, stream.

## Misc / utilities
agent (wip), ai provider registry (wip), command/command_queue, crdt, deepcopy, hot_reload, image_processing, ir, memoize, merge, merkle/merkle_tree (parallel), search, semver, string_ext/table_ext, spreadsheet, vm.

## Known duplicate clusters
Listed inline in `inventory.md`. Notable: 5 FSM impls; `json_schema` vs `jsonschema` vs `schema_validator` vs `validate` vs `validation`; multiple `lru*`, `bloom*`, `merkle*`; `geo_hash` vs `geohash`; `cron` vs `cron_parser`; `proto` vs `protocol_buffer`; `neural` vs `neural_net`; `noise` vs `noise_gen`; `ratelimit` vs `rate_limiter`; `observable` vs `observer`; `event` vs `event_emitter`; `automata` vs `finite_automata`; `automata_2d` vs `cellular_automata`; `expr` vs `expression_evaluator`; `roman` vs `roman_numeral`; `lindenmayer` vs `lsystem`; `merkle` vs `merkle_tree`; `option` / `either` / `fp/maybe` / `fp/either`; top-level `lib/json/` vs tiered `lib/format/json/`; top-level `lib/patch/` vs `lib/json_patch/`; stub shells under `lib/hast/`, `lib/mdast/`, `lib/remark*`, `lib/rehype*` (real impls in `lib/unified/`). Don't add to these — pick the existing one or consolidate.
