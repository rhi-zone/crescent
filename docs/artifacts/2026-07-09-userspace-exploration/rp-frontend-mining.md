# RP Frontend — Prior Session Mining

Mined via `normalize sessions` (binary at `/home/me/.local/bin/normalize`, not
`~/git/rhizone/normalize/target/{debug,release}/` as the roadmap guessed — that
path doesn't exist; the built binary lives elsewhere). Findings below are grounded
in transcript text, not inference — quotes are what the owner or assistant actually
wrote.

## Which session actually has the design intent

The roadmap's claim ("almost certainly a previous session worth mining") pointed at
nothing specific. Grepping all crescent sessions for `sillytavern|character card|
roleplay|RP frontend` turned up 3 sessions — two of them (`fd8f7edf`, `b5062725`)
are the roadmap-authoring session and *this* mining task itself, recursively
referencing each other; the third (`dc28d3ca`) only matches because a `git log`
line scrolled through its transcript. None of the three contain original design
content.

The real source is a session that predates the "AI RP frontend" label entirely and
doesn't match those grep terms because it uses the project's actual working name at
the time: **`01805bae-b0c7-45aa-8105-b5255d1a076a`** (2026-04-13/14, ~6h47m, opus).
Found by tracing `git log` for the app's origin commits (`feat(card): BFF backend`,
`feat(card): static frontend`, both dated 2026-04-14) and searching sessions active
in that window for `"BFF"` / `"static frontend"` / `"character card"`. This is the
session that produced `docs/platform-design.md`'s tarball/manifest/cap design and
most of `docs/card-app-design.md`. **Both docs already exist and are current** —
1275 and 504 lines respectively — so nothing here is un-recorded; this write-up is
a guide to what's already written down and why, not new information.

## What got decided (chronological, session `01805bae`)

**App format.** Not a single-script PNG card — a gzip-compressed tar archive
(`manifest.json` + arbitrary Lua files + assets), embedded as `base64(gzip(tar))` in
a PNG/JPEG/WebP `lua` chunk (any of tEXt/zTXt/iTXt — host's choice), OR distributed
as a raw `.tar.gz` with no image at all. The image is decoration, never load-bearing.
Rejected names along the way: `crescent` (conflates app format with ecosystem),
`rhi`, `lumis`/`cartridge`/`scroll` (inconsistent naming), `card`/`app`-as-chunk-name
(overclaims — "why would one node editor or IDE be a 'card'"). Landed on `lua` as
the chunk name — descriptive of contents, not a claim about app type.

**Entrypoints.** No common-denominator "render cap." Each app declares named
entrypoints in the manifest (`dom`, `mcp`, `tui`, `headless`, whatever) — real,
independent implementations per target, same principle as crescent's perf tiers.
Critical correction mid-session: the conversation UI, character editor, and
lorebook editor are **not separate entrypoints** — they're internal views/routes
within one `dom` entrypoint, so state and transitions stay smooth. The shell only
ever launches `dom`; it has no idea what CCv2 is.

**Manifest.** JSON, not Lua — `manifest.json`, because tools need to inspect apps
without a Lua runtime ("can't exiftool | tar | jq" a Lua table). Declares
per-entrypoint caps as a named map (not a flat list), `required`/`optional`
distinction, global caps merged with entrypoint caps, `readonly` flag for caps like
`caps.db`. No shared/reactive-signal requirement baked into the format — that's a
host/script agreement layered on top if both sides want it, not a manifest rule.

**Caps.** App declares what it needs; the *user/operator* grants, never the host
unilaterally. Principle of least privilege, per-entrypoint. Landed cap set:
`caps.kv` (key-value, allowlisted by key/prefix) for lightweight state,
`caps.db` (pre-opened SQLite handle, host decides the file — passing handles beats
passing paths so the app can't request arbitrary files) for relational data. State
caps should be signal-shaped (reactive), action caps stay plain functions — this
generalized into "all caps reactive by default, except purely imperative ones."

**Cross-app isolation vs. cross-app search** (23k-card scale, stated directly by
owner) was the hardest sub-thread. Rejected in order: per-app db files (doesn't
scale — 23k × N files), structured query API ("just use SQL to not let users use
SQL"), temp views alone (don't actually block table access, app can query
`sqlite_master` and route around them). Landed on: **temp views + SQLite
authorizer callback**, authorizer denies raw table access, host connection has no
authorizer so cross-app search still works. Performance concern (LuaJIT FFI
callback trampoline overhead) resolved by noting `lib/asm/` can JIT-compile the
authorizer natively — no C shim needed.

**Vendoring.** App-specific logic (conversation tree, context assembly, format
parsers) ships *inside the app's own tarball*, copied from crescent's canonical
`lib/` source, not required from host stdlib at runtime — protects the app from
host API drift. `require` resolution: tarball root checked first, falls through to
host `lib.*` only for things the app didn't vendor. No forced `app.`/`lib.` prefix
convention — if you want the clarity of `require("app.conversation")`, put the file
at `app/conversation.lua` in your own tarball; the platform doesn't enforce it.

**Conversation tree.** Not linear-with-swipe-history (correctly identified as what
ST actually is, despite ST's UI implying real branching). Real tree:
`{role, content, id, parent_id, session_id}`, plus `canonical_child_id` on *every*
node (not just the active path) — so navigating into and back out of any branch
resumes exactly where you left it in that branch. This is explicitly framed as
better than anything ST does. `session_id` kept on messages directly (not derived by
walking to root) because "give me all messages in this session" is a hot query path.

**Saved state / multi-device.** Server-centric, not local-first/CRDT — owner
accesses ST over Tailscale already, so "multi-device" reduces to multiple browser
tabs hitting one server instance; "multi-user" reduces to `user_id` on rows. Offline
support rejected outright ("the ipad would have to run its own models then").
Two-level split: host owns `{app_path, state_ref}` (which app was last open), app
owns what `state_ref` means internally.

**Context assembly.** Explicitly *not* a platform concern — "remind me what exactly
the platform does?" / "runs a script with the capabilities the host grants, and
provides a render surface. that's it." Ordering, trimming, and lorebook scanning are
all app-script logic. ST parity for the trimming algorithm specifically (fixed
blocks always fit; lorebook has its own % budget with priority-ordered drops within
that budget; chat history is the only thing genuinely trimmed, newest-to-oldest) —
verified via subagent fetching an actual source rather than assumed.

**Macros.** Full 98-macro ST set gets implemented once in a library, but a card
using only `{{char}}`/`{{user}}` should not need to read or vendor that whole
system — those two (plus legacy angle-bracket and case-insensitive variants, all
still simple enough to inline) get implemented inline in the card script; only
cards that actually use the other 96 vendor the full macro library.

**Card editor layout — the "honest" framing.** After several wrong guesses, the
owner's answer: field layout should mirror **context assembly order**, not CCv2
spec order or arbitrary grouping — the editor becomes a direct visual
representation of what the model actually sees and in what order. Reordering
fields in the editor literally reorders the context. Justified because "most people
don't move system prompt and post history" — so default context order serves ~95%
of users and reordering is still available for the rest.

**Lorebook editor — explicit anti-ST-parity carve-out.** Full ST *field* parity is
required (the JSON schema, all settings), but the owner was explicit ST's editor UX
itself is bad and not to be copied: settings currently eat ~80% of row width while
keywords/content (what you actually need to see) are hidden until expanded. Landed
design: name + keywords always visible inline, content on expand, settings in a
detail panel/popover — not the row. Same projectional search as the card library
(open metadata, not a separate flat-tag system) applies to lorebook entries too;
grouping/categories were explicitly rejected as redundant with search plus a
manually-maintained field nobody asked for.

**Conversation view (mobile-first).** Top bar: nothing persistent except possibly
edit. ST's branch-viewer and checkpoint concepts are called "garbage
implementations" outright (branches duplicate full history; checkpoints reference
originals, breaking backup) — solved instead by the tree + `canonical_child_id`,
no dedicated UI needed. Touch target design was driven hard by the owner testing on
Android over Tailscale: long-press rejected as "too slow," landed on swipe-left
(left half = branch nav, elsewhere = reveal actions) as a once-learned gesture, plus
a sibling-count indicator for discoverability. Input row: single-line-expands
(~30% of remaining viewport, adaptive not fixed-line-count), send button (keyboard
submit rejected — unreliable across mobile keyboards), continue (via prefill,
provider-dependent — OpenAI doesn't support assistant-turn prefill, Claude does) and
impersonate (always a fresh generation, prefill doesn't apply) both present but
**hidden by default**, and as a **global user preference**, not per-card ("no,
every card should share the same setting for this").

## Substrate this session produced as side effects

Not RP-specific, but built mid-session because the RP design needed them, and
relevant to reuse elsewhere: `lib/tar` (pure Lua ustar r/w), lua2ts metatable
support (`__index = table` → class translation, plus `Object.setPrototypeOf`
fallback for delegation-only patterns), `lib/web/js_types.lua` (renamed from
`js.d.lua` mid-session — see below), `lib/web/reactive_dom`, `lib/widget`,
`lib/web/html` (typed DOM builders, ported from Rainbow's `html.ts`), `caps.kv`,
`caps.db`, `caps.config`. Also: the `.d.lua` → `_types.lua` naming convention
adopted repo-wide (dot-suffix files can't be expressed in dot-path `require`), and
`--:: require "..."` as the type-only declaration-import annotation, both now in
CLAUDE.md.

One real typechecker bug surfaced and fixed here: `instantiate_inner` deep-copied
types unconditionally, and using arena pointers (`ctx.types:get(tid)`) after a call
that can grow the arena (`make_table`) caused a segfault on large declaration files
(`js_types.lua`, ~2100 lines). Fixed with a `has_generic_var` fast path that skips
copying non-generic types entirely.

## Where the session self-corrected on process, not just content

Near the end the owner stopped the design work to ask "where did we go wrong" — the
named failure mode was the assistant inventing plausible-sounding mechanisms
("structured query API," "C shim," "editor as separate entrypoint," "minimum viable
macro set embedded in stdlib") confidently, forcing the owner to correct nearly
every one rather than asking first. That diagnosis got written to CLAUDE.md at the
time. Worth knowing going into any follow-up design session: this specific owner
pattern — terse corrections, "no what the fuck," refusing to accept a guess dressed
as an answer — is not hostility, it's the same enforcement the current global
CLAUDE.md formalizes ("guessing is forbidden, full stop").

## Definition of "shippable" — where it was left open

The session never reached a finish line for this question. Direct quote: *"how far
are we from having an experience at least on par with sillytavern?"* → answer at the
time: substrate (LLM providers, sandbox/caps, app format, reactive DOM, SQLite,
HTTP server, PNG/tar/compress/json/base64) was "essentially built," but *"nothing a
user could run yet"* — the conversation loop, chat history persistence, HTTP
frontend delivery, and library shell were all unimplemented. By session end, most of
the mechanical/specced pieces got delegated and landed (conversation tree,
manifest cap validation, HTTP server wiring, `caps.kv`, `caps.db`) — but two design
threads were explicitly marked **not yet designed** at handoff: the **card editor's
full interaction design** (field layout principle was settled — see above — but not
worked through field-by-field) and **settings UI** (storage split settled — see
below — but no view design). The **library shell / metadata search UI** was
flagged mid-session as "nowhere near specced out yet" and deliberately deferred so
the session wouldn't "overfocus."

Given the current `charactercardv2` state (below) already has settings, sessions,
group chat, lorebook editor, card editor, regex scripts, personas, presets, and a
mobile-responsive layout shipped — a fair amount of what this session called
undesigned has since been built in practice, likely across other sessions not
covered by this mining pass (git log shows ~100+ commits after this session's
handoff). Whether that later work actually followed the "editor mirrors context
assembly order" and "swipe gestures, hidden continue/impersonate" decisions, or
diverged, is **unverified** — would need reading the current `card-editor.js` /
`settings.js` against this doc, which this pass didn't do.

## Current state of `lib/platform/apps/charactercardv2/`

Manifest (`manifest.json`): name "Character Card v2", two entrypoints —
`server` (default) and `import`. `server` entry declares caps `server`
(http_server), `llm` (key_name "anthropic"), `conversations` (shared_db, optional,
falls back to in-memory), `create_instance` (optional — lets "New Card" spawn a
fresh app instance rather than requiring a manual PNG download/re-import). App-level
caps (available to all entries): `self` (own identity/tarball/PNG chunks),
`self_write` (optional — writes card state back into the PNG so the file stays
self-contained), `kv` (optional — presets + active session ID), `time`. No `db`
(app-scoped SQLite) cap declared — it uses `shared_db` instead, which isn't in the
cap list this mining pass read out of `lib/platform/CLAUDE.md`'s taxonomy but is
referenced directly in the manifest, consistent with `docs/platform-design.md`'s
`caps.shared_db` section (schema-conflict detection, `setup_schema()`).

Directory layout: `server.lua`/`import.lua`/`init.lua`/`presets.lua` at the app
root, `static/` (19 JS modules: `api`, `app`, `card-editor`, `card-lorebook`,
`card-state`, `chat-export`, `group`, `lorebook-entry`, `markdown`, `messages`,
`my-lorebooks`, `new-card`, `persona`, `regex`, `send`, `sessions`, `settings`,
plus `index.html`/`style.css`) with its own `static/test/` — a hand-rolled DOM +
bun test harness per git log (`feat(ccv2): frontend test harness`). `lib/` inside
the app root holds vendored copies (`formats`, `reactive`, `web`, `widget`,
`format`, `encode`, `png`, `aho_corasick`, `fp`) — this matches the "vendor
app-specific logic into the tarball, don't depend on host stdlib" decision from the
mined session.

Recent commits (most recent first) show real feature landings matching several
threads from the mined session: mobile-responsive layouts (burger menu, full-screen
overlays, single-column grid — directly answers the touch-design thread),
`create_instance` cap wiring, focus trap + destructive-action confirms, a11y passes,
linked-lorebook UI in the card editor, and a long app.js decomposition into the
current 19-module `static/` layout. The glassmorphism UI system
(`lib/glass-ui`, formerly `lib/glassmorphism`) was applied to ccv2 in a separate
pass — not something the mined session discussed, so its relationship (if any) to
the "honest field layout" / "minimal, not affordance-starved" visual language
discussed in `01805bae` is **unverified**.

## Open threads for a follow-up design pass

- Card editor: layout *principle* settled (context-assembly order), but no
  field-by-field interaction design was done. Worth checking current
  `card-editor.js` against the principle before assuming it was followed.
- Settings view: storage split settled (`caps.config` global default,
  `caps.kv` per-card override, "smart"/"gemini"-style aliases resolved at
  launch), but no UI design. Current `settings.js` exists — unverified whether it
  implements the alias-resolution or override model discussed.
- Library shell / unified metadata search (the "blonde hair AND D cups" query,
  open-metadata-per-adapter, projectional query editor, `source.list()`/
  `source.search()` adapter pattern for itch/Steam/bookmarks/Obsidian as
  additional data sources) was deliberately deferred and, per this mining pass,
  still has no first-party app in `lib/platform/apps/`. This is the single
  largest undesigned surface relative to what the mined session scoped out.
- State-driven affordances / dimmed-vs-disabled distinction (pulled from a
  referenced `busiless` session on projectional editors, not re-derived here) was
  captured as a principle but not applied to a concrete affordance list for ccv2.
