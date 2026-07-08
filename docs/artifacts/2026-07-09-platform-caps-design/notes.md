# Platform Capabilities — Design Notes (2026-07-09)

## What determines capability level

A capability is at the right level when it's a **swappable unit**: a stable interface the app depends on, with an implementation the platform controls and can swap — potentially hot-swap at runtime.

- **Too low** (raw I/O — sockets, file handles): couples the app to implementation details, exposes secrets (API keys), prevents provider swapping.
- **Too high** (all services bundled): can't swap one service independently of others.
- **Right level**: per-swappable-unit. Each cap is something the platform can replace behind the app's back.

## Properties of capabilities

**Attenuation**: any cap can be narrowed before passing it on. A writable cap can be attenuated to read-only. The granularity of the cap type doesn't have to be maximally fine-grained because attenuation handles scoping dynamically.

**Construction**: the platform assembles higher-level caps from lower-level resources + configuration. The app never sees the parts — it receives the assembled cap.

**Dependency inversion**: the app depends on the cap's interface (e.g. "send messages, get completions"), not the implementation (e.g. Anthropic's API). The platform injects the implementation. `key_name: "anthropic"` is platform-side config, invisible to the app.

**Swappability**: because the cap is an object with methods, the platform can swap the implementation while the app is running — switch LLM providers mid-session, migrate storage backend live, redirect a server to a different port. The app holds a reference; the internals change; the app doesn't know.

**Not everything is a cap**: pure logic (combinators, parsers, encoders) is just code — `require` it directly. Caps are for things that involve external state, I/O, or platform-managed resources. But a library that *uses* I/O doesn't have to *be* a cap — it can be pure logic that receives I/O caps as function arguments.

## Existing caps in charactercardv2 (the only platform app so far)

| Cap | Type | What it does |
|-----|------|-------------|
| self | self | App identity, tarball entries, PNG metadata |
| self_write | self (writable) | Write card state back to PNG |
| kv | kv | In-memory per-app key-value store |
| time | time | Wall-clock timestamps |
| server | http_server | Serve HTTP routes |
| llm | llm | LLM API access (provider-swappable, key hidden) |
| conversations | shared_db | SQLite with per-app-instance row isolation |
| create_instance | create_instance | Spawn new app instances |

These are at different abstraction levels and serve different purposes. The common thread is swappability, not abstraction level.

## shared_db specifics

shared_db is three things in one:
1. **Performance**: one SQLite file instead of one per app instance — fewer file handles, shared page cache, one WAL.
2. **Per-instance isolation** (default): views filtered by `_app_id()`, INSTEAD OF triggers force app_id on writes, SQLite authorizer blocks direct base table access and DDL.
3. **Cross-instance visibility** (when granted): a dashboard or overview app could receive a wider view across app_ids.

Tested and real: app A cannot read, update, or delete app B's rows. Even if the app passes a different app_id in an INSERT, the trigger overwrites it.

## "crescent as the entire computer" — capability surface

Reincarnate's platform API (~/git/rhizone/reincarnate/) covers: 2D graphics, 3D graphics, audio (node graph), input (keyboard/mouse/touch/gamepad/IME), images, persistence, timing, window management, clipboard, network (HTTP), files. This is useful prior art for the operations inventory, but factored for portability (swap backends), not for capability scoping (swap per-service). Crescent's factoring should be per-swappable-unit.

Reincarnate's own docs note the original system traits were "at the wrong abstraction level" and are marked as dead code, superseded by a more granular platform interface. Even the newer interface groups a lot under single headings — whether those are one trait or separate capabilities is undecided.

What a computer does (user-facing, not exhaustive):
- See things (display, graphics)
- Hear things (audio playback, routing)
- Say things (microphone, voice)
- Type things (text input)
- Point at things (mouse, touch, pen, gamepad)
- Connect to things (network, bluetooth, USB)
- Store things (files, databases)
- Find things (search)
- Organize things (collections, tags)
- Read/watch/listen (content consumption)
- Write/draw/compose (content creation)
- Talk to people (communication)
- Automate things (scripts, schedules, triggers)
- Install/manage software
- Secure things (auth, permissions, encryption)
- Manage power (battery, sleep, shutdown)
- Print/scan (physical I/O)
- Configure (cross-cutting — settings on any of the above, not its own category)

Each of these implies capabilities. Design pass needed to determine the right factoring — per-swappable-unit, not per-OS-service or per-abstraction-level.

## Open questions

- Are the ccv2 cap levels right for the general case, or shaped by ccv2's specific needs? Need more apps to tell.
- How does attenuation compose across multiple levels? (app attenuates a cap before passing to a sub-component — does that work cleanly?)
- What's the cap story for browser-only apps (no server, service worker only)?
- Mining previous sessions for design intent: `normalize sessions messages --grep` on platform-related sessions.
