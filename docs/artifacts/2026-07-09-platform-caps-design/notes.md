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

**Not everything is a cap**: pure logic (combinators, parsers, encoders) is just code — `require` it directly. Caps are for things that involve external state, I/O, platform-managed resources, or anything where swappability matters. A JSON parser doesn't need to be a cap because there's no reason to swap it behind the consumer's back. An LLM client does because the provider might change. But a library that *uses* I/O doesn't have to *be* a cap — it can be pure logic that receives I/O caps as function arguments.

## Design intent from prior sessions

Mined from session `4b24c1b4` (2026-04-20 to 2026-04-23), where the capability model was originally designed. Owner's words verbatim or near-verbatim.

### Capabilities are not just for security

> "capabilities are not just for security." (turn 125)

> "llms being a cap is wider api surface (bad!) but llms not being a cap means we must have a way to make apis swappable (like dependency injection?) with all the capability management that implies — but how?" (turn 126)

> "permission boundaries are kinda the most important, right? but flexibility would be a sick feature to have, some way or other? it doesn't have to be as capabilities, right? but that doesn't mean it won't need to integrate with the cap system" (turn 139)

Two concerns live in the same system: permission boundaries (security) and swappability (flexibility). They don't have to be the same mechanism, but they must integrate.

### Prior art: powerbox, Sandstorm

> "what is the difference between swappable deps and powerbox" (turn 141)

> "also consider https://sandstorm.org/ as prior art?" (turn 139)

### Caps are entrypoint-only

> "caps.* global should only be accessible by the entrypoint. otherwise caps leak into the global scope of other scripts which is BAD" (turn 172)

> "pure lua library does NOT need to be injected because it's just pure lua, just vendor it" (turn 171)

Caps don't leak to dependencies. A library receives caps as function arguments from the entrypoint that holds them, not from a global.

### FFI is not a grantable capability

> [re: ffi is explicitly whitelisted as a cap] "unacceptable" (turn 163)

### Even "zero-privilege" caps can be restricted

> [re: making time cap required] "what about in an env that genuinely has no access to time?" (turn 181)

No cap is unconditionally granted, even seemingly harmless ones.

### Write as explicit enablement

> "they should be 'regular' caps with write capability explicitly enabled" (turn 198)

Read is the default. Write is an explicit grant — aligns with attenuation (narrowing from read-write to read-only).

### Sandbox model

Tarball modules load in the sandbox environment, not the host loader — otherwise they become an escape vector (a module loaded outside the sandbox could access host APIs and bypass the cap system entirely). Dev and prod sandbox behavior must be consistent — inconsistency is a bug, not a feature.

Caps are injected at the entrypoint and passed explicitly to code that needs them — they don't propagate via globals or implicit require.

### Reference doc

`docs/platform-design.md` is the canonical platform design reference. Should be consulted before any platform work. (See turn 251 for context on scoping this to platform-specific CLAUDE.md rather than the top-level one.)

### Permission dialog and grant fatigue

From sessions `cabdea3b` and `4b24c1b4`:

> "ALL the caps need to be 'trusted' through a permissions dialog, that's the point" (cabdea3b)

> "never auto-grant?" (cabdea3b)

> "--grant mustn't be persisted imo" (cabdea3b)

> "A 'default allow for harmless caps' reduces grant fatigue... not too sure about that. can be recommended during setup but not default" (cabdea3b)

> "the same set of permissions every time sounds like decision fatigue though... may need a way to go 'this is the same as your <x> settings preset' AND/OR a preset selector" (4b24c1b4, turn 145)

No silent grants — every cap goes through a permission dialog. But repeated identical dialogs are zero-information decisions. The mitigation is user-defined presets: the user creates their own permission profiles, not predefined app-type categories. Predefined presets are unacceptable — the system must not decide what's "normal."

The goal is compression: only surface dialogs that carry actual information (genuinely context-dependent decisions). Risk/severity levels on caps (`M.risk()` in cap implementations) already flag which grants are low-information vs high-information.

Open: the condition DSL for presets ("sexpr dsl structured editor style conditions" — turn 147) was mentioned but not designed.

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
- Powerbox vs caps: are they the same thing in crescent, or is there a meaningful distinction? (raised 2026-04-20, not resolved)
- Permission presets: user-defined preset system with condition DSL mentioned but not designed. How to compress grant dialogs to only true decision points without predefined app-type categories.
