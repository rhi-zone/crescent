# Synthesis: crescent as the entire computer

Provenance: 8 facet-exploration docs (`creative.md`, `information.md`,
`communication.md`, `productivity.md`, `system.md`, `development.md`,
`ai-agents.md`, `games.md`) written in parallel by separate agents on
2026-07-09, each surveying prior art + `docs/inventory.md` for one domain,
plus one `blindspots.md` pass reviewing all 8 together. All of it is
speculative exploration — nothing here is a commitment, a plan, or a
scope decision. This doc synthesizes across the 9; it does not re-decide
anything they left open. Grounded against `docs/overview.md` and
`docs/inventory_summary.md`. Future agents: grep this file first; read a
source doc only when you need its full prior-art detail.

## 1. Substrate layers

Things ≥2 facets independently need, that should be one library, not
reinvented per app.

**Audio output/synthesis** — needed by creative.md (livecoding, trackers,
DSP), games.md (rhythm games, media playback). Have: `dsp` (signal
processing only). Missing: oscillator/envelope/mixer, a sound *sink*
(WebAudio cap in-browser, WAV-file cap for pure-Lua), audio *decode*
(WAV/OGG codec). Named by both docs as the single largest hole in the
"creative tools" and "games" facets — DSP without source/sink is half a
stack. games.md: rhythm games (osu!, StepMania) are unbuildable without it.

**Undo/redo** — flagged by blindspots.md as needed by creative.md (paint,
livecoding), development.md (editor), information.md (note editing), but
mentioned by name only once, parenthetically, in productivity.md
(`command`/`command_queue`). Every facet assumed it exists "elsewhere."
Have: `command`/`command_queue`. Missing: nobody has actually wired it
into an editing surface; unclear if the existing primitive covers
collaborative/CRDT-conflicting undo (see next item).

**Collaborative/CRDT text** — needed by creative.md (Figma-style
multiplayer canvas), communication.md (co-editing, Etherpad-shaped),
information.md (shared annotation), productivity.md (collaborative docs).
Have: `crdt` (generic primitives), `merge3`, `diff` (char-level).
Missing: a sequence CRDT (RGA/Peritext-shaped) distinct from generic
`crdt` — text-sequence semantics (tombstones, interleaving anomalies)
aren't the same as generic CRDT primitives. communication.md names this
as a genuinely open design call: does it live under `lib/crdt` or as a
sibling library (parallel to how `signals` sits next to `reactive`)? Not
decided in any doc.

**Search-across-everything** — information.md builds a full PIM search
stack from `search` (inverted index) + `tfidf` + `fuzzy_match` +
`trie`/`patricia_trie`. system.md separately wants a Spotlight/rofi-style
system-wide launcher search. blindspots.md flags these as the *same*
underlying need never cross-referenced — a system-level search surface
over files/notes/chat/settings could be the same `search` stack wearing
a different UI, not a new primitive.

**Notification routing** — wanted independently by system.md (missing
cap — "can this app interrupt me" as a permission), productivity.md
(snooze/triage re-surfacing), communication.md (@mentions), ai-agents.md
("agent finished a task"). blindspots.md: four docs want the same
primitive, none cross-referenced. Have: five reactive libraries
(`reactive`/`signals`/`reactive_var`/etc.) that a notification primitive
would likely compose from, per communication.md's observation that
presence/typing-indicators are "a reactivity problem, not a messaging
problem" — but nobody has verified the composition is actually smooth.

**Clipboard** — system.md: the one inter-app channel that must cross cap
boundaries by design, while the platform's whole architecture exists to
prevent apps reaching each other. Needs its own grant semantics (likely
"paste requires a user gesture," mirroring the browser Clipboard API's
own model, per system.md's explicit recommendation to copy the web
platform's existing answer rather than invent one). Not built.

**Sharing/export as a universal action** — creative.md ("the URL is the
save file," export SVG), information.md (export standalone HTML, Twine
model), communication.md (crosspost). blindspots.md: named independently
four times with no shared vocabulary — "take an artifact out of crescent
and hand it to someone not running crescent" is one underlying need.

**Replay / deterministic input log + save-state** — games.md: osu!
replays, TAS tooling, RetroArch rewind, emulation all need "record
inputs + seed, snapshot/restore sim state." Have: `rand` (seedable,
unconfirmed), plenty of sim libraries. Missing entirely: a `lib/replay/`
canonical format, and a "serialize an ECS world" snapshot primitive
(`persistent`/`kv_store` exist for data structures generally, nothing
targets sim-state snapshotting specifically). Named as cross-cutting like
`codec` or `observer`, not one game's problem.

**Determinism-as-a-cap for generative work** — creative.md: every
generative library (`noise`, `particle`, `l-system`, `wfc`) needs its PRNG
to be an injected cap, never ambient `math.random()`, for "same seed in
→ same artifact out" to be guaranteed. Flagged as an audit item, not
confirmed done or broken.

## 2. Application domains

Grouped roughly by how much substrate already exists vs. is missing.

**Mostly-buildable today (composition gap only):**
- *PIM/notes/Zettelkasten* (information.md) — `kv_store`/`sqlite`/`crdt`
  for storage, `search`+`tfidf`+`fuzzy_match` for retrieval, `graph` for
  backlinks, `markdown`+`unified` for content. Open question: does a note
  store plain-markdown-files-on-disk (Obsidian-shaped, greppable outside
  crescent) or `kv_store`/`sqlite` rows (better query, worse "just open it
  in a text editor")? Not decided; framed as a real tradeoff crescent
  hasn't taken a position on for *any* data-holding library.
- *Todo/task tracking, kanban/gantt projections* (productivity.md) — one
  record shape + pure projection functions (`group_by_status`,
  `to_gantt_bars` via `graph` for critical path). Open question: does
  `spreadsheet` become the canonical backing store (rows=tasks, get
  kanban/gantt/calendar as views "for free"), or does a dedicated `task`
  record type win because the typechecker can hold onto it? Not decided.
- *Auto-scheduling* (productivity.md, Reclaim.ai-shaped) — `calendar` +
  `constraint_solver`/`interval_tree` + `scheduler` compose into a pure
  `schedule(tasks, busy_intervals, prefs) -> placements` function nobody
  else ships decoupled from a hosted calendar. Named as genuinely
  buildable and valuable, not just gap-filling.
- *VN/branching-narrative tool* (games.md, Twine-shaped) — buildable today
  from existing text/graph substrate, no named gap.
- *Sandboxed automation scripting* (Alfred/Hammerspoon-shaped,
  productivity.md) — cap-manifest model makes this *safer* than any
  incumbent (Hammerspoon/AHK run with full ambient privilege; a crescent
  script's manifest declares exactly clipboard/notify/fs-scoped access).
  Named as the sharpest philosophy fit in that doc.
- *Delta-Chat-shaped E2E chat over SMTP/IMAP* (communication.md) —
  `lib/smtp`+`lib/imap`(wip)+`blake2`/`chacha20`/`argon2` compose into
  Autocrypt-style E2E chat with no new protocol. Called "the most
  crescent-shaped precedent in the whole survey."
- *Browser-native IDE panels* (development.md) — LSP daemon, `diff`/
  `merge3` for VCS UI, `lib/test` for a results panel already exist as
  composable pieces on `lib/platform/`.

**Needs one real new substrate piece:**
- *Livecoding/tracker/musical tools* (creative.md) — needs the musical-time
  primitive (quantized, cycle-based, re-evaluated clock, distinct from
  `easing`/`interpolation`'s continuous parametric time) AND the audio
  substrate above. Design question: who owns wall-clock time (audio
  callback vs animation frame vs fake deterministic clock for tests)? Not
  decided.
- *Fantasy console* (creative.md, games.md) — both docs converge
  independently: this is a cap *profile* (fixed canvas, fixed palette, no
  network/fs) applied to `lib/platform/`, not a bespoke product. games.md
  is explicit this would be "one app among many," not a platform-level
  decision.
- *Debugger* (development.md) — `debug.sethook` + coroutines could build a
  from-scratch DAP server (`lib/debug_adapter/`), presented as "a
  coroutine you can single-step," Lisp-machine-style. Named the most
  conspicuous gap for a language ecosystem this mature.
- *REPL* (development.md) — no `bin/cr repl` exists; an nREPL-shaped
  long-lived process over `lib/jsonrpc` would let LSP/browser-IDE/terminal
  share one live state.
- *Rhythm-game / chart editor* (games.md) — `tilemap`+`midi`+`canvas`
  cover placement/timing; playback (the audio gap) is the only missing
  piece.
- *RAG chunking pipeline* (ai-agents.md) — `lib/embed/` (storage) +
  `lib/ai/` (generation) exist independently; no chunking/embedding-glue
  connects a document to a queryable index. ai-agents.md suggests this
  wants to be a *preset* (task type) rather than a new library, given
  "no framework code in lib/."
- *Eval/comparison harness for LLM presets* (ai-agents.md, PromptFoo/Arena
  shaped) — ties into existing `lib/test/` fixture/snapshot infra rather
  than needing new machinery.

**Large, mostly-unclaimed:**
- *Window management for sandboxed browser apps* (system.md) — the
  hardest open question in that doc: crescent apps aren't independent
  OS-level surfaces, so a WM can't be i3-style; the reframing is
  "tmux/i3's control-plane idea applied to DOM panes" — a WM cap owning a
  tree of DOM regions, queryable/mutable, apps requesting a pane the way
  they request an `fs` cap. Explicitly not answered whether this is worth
  building before a real consumer needs it.
- *Multi-agent coordination* (ai-agents.md) — no crescent story; the
  design thesis (`docs/agent-design.md`) argues most existing multi-agent
  frameworks are "chronological accumulation with extra steps," but what
  a set-based multi-agent primitive looks like (separate sets per role,
  explicit note-passing) is an open design question, not addressed
  anywhere.
- *Local LLM inference* (ai-agents.md) — every `lib/ai/providers/` entry
  is hosted; a vendored `libllama.so`-per-platform FFI tier would be
  consistent with crescent's own `dep/` vendoring pattern but is "a real
  build-and-vendor undertaking, not a quick add."

## 3. Cross-cutting concerns (from blindspots.md)

- **Accessibility** — zero mentions across all 8 facet docs. Every
  DOM-rendering `lib/platform/` app either satisfies or silently fails
  ARIA/reduced-motion/colorblind-safe/keyboard-only requirements; nobody
  assigned it. Status: unowned. "Solved" looks like: a named cap or
  convention checked the way caps-first checks I/O today, not an
  afterthought per-app.
- **Privacy as user-facing audit/revocation** — distinct from caps-as-
  security-model. Caps control what an app *can* reach; nothing lets a
  user ask "this app had `fs` for three months, show me what it touched"
  even though system.md names an audit log as existing substrate. Status:
  substrate (audit log) exists, UI/query layer over it does not.
- **Theming/appearance and i18n** — `i18n`/`locale` listed as substrate in
  productivity.md's inventory line and never discussed again in any doc,
  even though every user-facing app in every facet needs it. Status:
  primitive exists, no design conversation anywhere.
- **Onboarding/discoverability of the platform itself** — every doc
  describes a tool once built; none asks how a user discovers crescent
  has 300+ libraries and can become any of these tools. `docs/overview.md`'s
  own stated principle ("discoverability in the tool not in tutorials")
  is never tested against "how do I find the tool at all" — a prior,
  harder problem. Status: unaddressed.
- **Error handling as user-facing UX** — not the `(nil, errmsg)` library
  convention (settled, in CLAUDE.md) but what a user sees when a cap is
  denied, a network call times out, a sandboxed app crashes mid-task.
  system.md gets closest (frames cap denial as security) but nobody asks
  "what does the error screen look like."
- **Import/migration from incumbents** — nearly every doc names the
  incumbent crescent would compete with (Obsidian, Slack, Trello, VS Code,
  SillyTavern); only ai-agents.md names an actual import path
  (SillyTavern card import). Nobody else asks how an existing vault/board/
  mailbox gets in.
- **Cross-facet workflow state** — a real session touches five "facets"
  at once (code + chat + agent notes + todo, one continuous task); each
  facet doc was scoped in isolation and none asks how state (open file,
  chat context, note, todo) moves between apps in the same session.
  Status: structurally invisible given the facet-per-agent framing itself.
- **App discovery/composition** — every doc independently proposes new
  `lib/platform/apps/*`; nobody asks how a user goes from "I have a goal"
  to "here's the composed set of apps/libraries," or how two crescent apps
  discover and talk to each other (vs. how one app reaches an external
  cap). The clipboard discussion (system.md) is the only near-miss, and
  it's framed as security, not composition.

## 4. Philosophy tensions

Genuine design problems crescent's stated principles create — not gaps,
tensions.

- **"No framework code in lib/" vs. chat/dispatch shapes.**
  communication.md: is a `lib/chat` (client-agnostic thread/message/
  reaction model over an injected transport cap) in scope, or does it
  violate the no-dispatch-layer rule the same way a routing layer would?
  Genuinely unclear from the stated rules; flagged as a direct question
  for whoever owns scope, not resolved.
- **E2E encryption vs. federation.** communication.md, citing Signal's
  design lesson: these are in real tension (federated key-management UX
  has never worked — Matrix cross-signing, PGP's 25-year unusability).
  Caps-first composability doesn't dissolve this; MLS (RFC 9420) is the
  IETF's attempt and it's a substantial state machine, not a wrapper.
  Whether it's in scope is a `docs/batteries.md` scoping question, left
  open.
- **"Pure Lua is the baseline" vs. WebRTC/video.** communication.md and
  games.md both hit this: voice/video and WebRTC have no pure-Lua tier —
  they're inherently browser-API-only, cutting against "target LuaJIT,
  don't require it" as a portability floor. Not resolved whether these
  are in scope at all.
- **Real-time performance guarantees are unaddressed.** blindspots.md:
  "target LuaJIT, don't require it" is a portability stance, not a
  performance guarantee — nobody has checked whether the pure-Lua
  fallback tier is usable for the actually-timing-critical facets that
  need it most (audio scheduling for livecoding/rhythm games, netcode).
  This could silently break creative.md's and games.md's core premise.
- **Browser-tab sandboxing vs. native OS integration.** blindspots.md:
  every doc assumes "browser tab" as deployment target without asking
  what's lost relative to a native app with full-disk access, background
  execution, global hotkeys, system tray, share-sheet integration.
  system.md gets closest (window-management tension) but doesn't
  generalize to "what can crescent apps never do because they're
  sandboxed in a tab."
- **Caps say nothing about identity.** blindspots.md: oauth2/jwt/keyring
  are used constantly across facets but "who is the user granting this
  cap" is never designed — capability (what an app can touch) and
  identity (who's on the other end of a session) are conflated by every
  doc that assumes single-user, single-device, single-session.
- **No philosophical answer for retention/deletion.** Caps control
  access, not retention or deletion guarantees — a GDPR-shaped "delete my
  data" request, or a HIPAA-shaped health-data facet (itself missing, see
  §5), has no story anywhere in CLAUDE.md or the overview.
- **Zero-dependency/no-hosted-service removes the incentive that funds
  unglamorous work.** blindspots.md, citing productivity.md's own
  observation about Notion bundling for multiplayer-sync reasons, not
  conceptual ones: when the incumbent's business-model constraint is
  simply absent, is that uniformly liberating, or does it mean nobody has
  a reason to build support/onboarding/moderation? Open, not answered.

## 5. What's NOT in scope

Explicitly named as non-goals, with reasoning, by the source docs
(strongest, most-argued exclusions — not a blanket claim every listed
item is permanently excluded):

- **CI/CD orchestration** (development.md) — "no framework code in lib/"
  directly forbids the dispatch/routing shape CI orchestration requires;
  `.github/workflows/*.yml` is already the right layer.
- **Containerization / a Docker wrapper** (development.md) — crescent's
  whole pitch (zero-dependency, vendored binaries, `git clone` and run) is
  "arguably a rebuttal to needing containers for this ecosystem
  specifically"; a `lib/dev_env` wrapping Docker would import the exact
  dependency weight crescent exists to avoid.
- **Zapier/n8n-style hosted connector catalogs** (productivity.md) — "the
  entire product is the connector catalog," which is out of scope for a
  zero-dependency ecosystem per CLAUDE.md's ban on framework code and
  adapter-layer dispatch. What crescent *can* offer (trigger/filter/action
  as a plain composable library) is a different, smaller thing.
- **Video decode/playback** (games.md, tentative) — "likely out of scope
  for zero-dependency, pure-Lua baseline — video codecs are not something
  you hand-roll" — but flagged as worth naming explicitly rather than
  silently absent, since media playback was named in-scope generally.
- **Leaderboard/scoreboard services, rollback netcode** (games.md) — named
  as real but narrow/hard problems (GGPO-style netcode especially) that
  the doc flags as gaps without proposing crescent build them; leaderboard
  specifically judged "thin enough it doesn't need to exist as its own
  library" (schema + query_builder glue over existing `http`/`sqlite`/
  oauth is enough).
- **A visual node-graph editor as a library** (creative.md) — explicitly
  named as tool-shaped, not library-shaped; if built, it belongs in
  `lib/platform/apps/` as an app composed *from* libraries, never as a
  "graph execution engine" library, to avoid becoming exactly the
  generic-dispatch framework code the constraints forbid.

## 6. Open questions index

Every open question explicitly flagged across the 9 docs, collected
verbatim in intent, with source.

- Musical-time primitive: who owns wall-clock time (audio callback,
  animation frame, or fake deterministic clock for tests)? — creative.md
- Does collaborative/shared-canvas CRDT already exist under a different
  crescent facet, or is it a real gap? — creative.md
- Is a node-graph editor correctly scoped as an app (not a library) in
  every case, or are there compositional cases where it'd need to be
  substrate? — creative.md
- Does livecoding's hot-swap-of-a-running-cap-bounded-closure model fit
  `lib/platform/`'s tarball-loader + cold-start-dispatch framing at all?
  — creative.md
- Storage format for a note: plain markdown files on disk (greppable,
  no lock-in) vs. `kv_store`/`sqlite` rows (better query)? — information.md
- Where does a rebuilt-vs-incrementally-maintained backlink index live,
  and which discipline does it follow? — information.md
- Is annotation-anchored-to-a-text-range-that-survives-edits solvable via
  `diff`-based re-anchoring, or is it a genuinely unsolved hard problem?
  — information.md
- Is a `lib/chat` (thread/message/reaction model over an injected
  transport cap) in scope, or does it violate the no-framework-code rule?
  — communication.md
- Does a sequence CRDT for collaborative text belong under `lib/crdt` or
  as its own sibling library? — communication.md
- Is voice/video in scope at all, given WebRTC has no pure-Lua tier?
  — communication.md
- Does `spreadsheet` become the canonical backing store for kanban/gantt/
  calendar views, or does a dedicated typed `task` record win? —
  productivity.md
- Is real-time collaborative editing (crdt + merge3) already sufficient
  substrate for a real-time collaborative doc, or does it need more?
  — productivity.md (flagged as unclaimed, not designed)
- Whether a crescent "window manager" cap is worth building before any
  app actually needs multi-pane layout. — system.md
- Whether clipboard/notification caps belong in `lib/platform/caps/`
  now, or wait for a consuming app. — system.md
- Whether "terminal emulator" (PTY-grid model) is in scope at all, or
  whether the existing ANSI/TUI layer under `lib/web/` already covers
  what crescent needs. — system.md
- Whether `lib/agent/`'s preset system should let a preset declare its
  own cap manifest independent of its hosting app (cap-minimality
  enforced per-task-type, not per-agent-instance) — genuinely novel
  relative to every other agent framework if pursued. — ai-agents.md
- What a set-based multi-agent coordination primitive looks like
  (separate sets per role, explicit note-passing) — no design exists.
  — ai-agents.md
- Whether "same libraries, many tools" ever actually fails — i.e., is
  there a facet need that can't be satisfied by recomposing existing
  primitives, where "just compose libraries" would be a cop-out for a
  missing primitive? (audio is the one case honestly flagged as real
  rather than assumed away). — blindspots.md
- How does state move between apps in the same session (cross-facet
  workflows), given no doc modeled more than one facet at a time?
  — blindspots.md
- How does a user go from "I have a goal" to a composed set of apps/
  libraries that satisfies it — app discovery/composition has no owner.
  — blindspots.md
- Does crescent's philosophy ever need to flex per-domain (e.g., does a
  chat primitive need *some* dispatch shape despite the no-framework-code
  rule), or is the philosophy treated as unconditionally authoritative by
  every doc that cites it? — blindspots.md
- What does multi-tenancy/identity mean on top of a caps model that only
  describes access, not "who is the user"? — blindspots.md
- What does federation/trust between two independently-run, mutually
  untrusted crescent instances look like — addressed only for chat
  (communication.md), nowhere else, despite export/sync/multiplayer all
  running into the same problem. — blindspots.md
