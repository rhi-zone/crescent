# Delta: batteries.md vs. synthesis.md

Cross-reference between `docs/batteries.md` (definitive ecosystem scope, ~330
libraries catalogued) and `docs/artifacts/2026-07-09-userspace-exploration/synthesis.md`
(today's 8-facet exploration + blindspots pass). Both read in full.

## 1. Things synthesis found that batteries.md doesn't cover

**Genuinely new substrate needs**, absent from batteries.md entirely:

- **Clipboard as a cap** — system.md's point that clipboard is the one inter-app
  channel that must cross cap boundaries by design. Batteries.md's capability
  model (`lib/sandbox`, `lib/platform/caps/*`) never names clipboard; no grant
  semantics discussed anywhere.
- **Debugger / REPL** (`lib/debug_adapter/`, `bin/cr repl`) — batteries.md has
  zero mention of either. development.md calls the debugger "the most
  conspicuous gap for a language ecosystem this mature," and that reads as
  correct against the full catalogue — nothing DAP-shaped or REPL-shaped exists.
- **Window management for sandboxed DOM apps** — batteries.md's `lib/platform`
  section describes cap-scoped entrypoints but never addresses multi-pane
  layout/composition between apps. system.md's "tmux/i3 control-plane over DOM
  regions" framing is new territory.
- **Multi-agent coordination primitive** — batteries.md's AI section covers
  provider dispatch and `lib/taskgraph` (single-orchestrator-calls-LLM shape)
  but never addresses multiple cooperating agents. ai-agents.md's set-based
  coordination question has no prior art in batteries.md.
- **Local LLM inference** — batteries.md's `lib/ai/providers/` is hosted-only.
  Nuance: `lib/onnx` (FFI bindings to run exported models) already exists under
  `lib/ml`, which is adjacent but not the same ask (ONNX runtime ≠ a
  `libllama.so` LLM inference tier) — worth noting as partial precedent, not a
  full false-gap.
- **Accessibility, privacy-audit UI, onboarding/discoverability of the platform
  itself, error-handling-as-UX, cross-facet workflow state, app
  discovery/composition** — all six are named in blindspots.md as unowned and
  none appear anywhere in batteries.md, including its own "logical conclusion"
  and "typed ecosystem flywheel" sections, which discuss discoverability only
  in the narrow sense of type-search finding a function by signature — not a
  new user finding the platform at all.
- **Musical-time primitive** (quantized/cycle-based clock distinct from
  `lib/easing`/`lib/interpolation`'s continuous time) — genuinely absent.
- **Replay/deterministic-input-log + sim-state-snapshot format** (`lib/replay/`)
  — batteries.md has plenty of sim libraries (`lib/behavior_tree`,
  `lib/entity_component`, `lib/steering`, etc.) but no canonical
  record/replay or snapshot format naming them as one concern.
- **Sequence CRDT** (RGA/Peritext-shaped) as distinct from generic CRDT —
  batteries.md's `lib/crdt` has exactly six types (gcounter, pncounter,
  lww_register, tpset, orset, lww_map), confirmed by direct inspection — none
  is a text-sequence CRDT. The gap synthesis names is real.
- **Determinism-as-a-cap audit** for generative libraries (`lib/noise`,
  `lib/particle`, `lib/lsystem`/`lib/lindenmayer`, WFC) — batteries.md doesn't
  discuss whether these take PRNG as an injected cap vs. reach for ambient
  `math.random()`. Worth flagging: several (`lib/dice`, `lib/genetic`,
  `lib/simulated_annealing`, `lib/noise_gen`) are explicitly seeded/deterministic
  per their catalogue entries, but this was never audited as a cross-cutting
  property the way synthesis frames it.
- **Application-domain framings not in batteries.md's vertical list**: todo/
  kanban/gantt projection, auto-scheduling (Reclaim.ai-shaped), Twine-style
  branching narrative tool, Hammerspoon/Alfred-shaped sandboxed automation
  scripting, fantasy-console-as-cap-profile. Batteries.md's "Missing —
  application verticals" section lists `lib/web`, `lib/db`, `lib/auth`,
  `lib/email`, `lib/queue`, `lib/search`, `lib/realtime`, `lib/tui`, `lib/ml`,
  `lib/logic`, and five card/board games (chess, mahjong, solitaire, spider,
  freecell) — none of these five app ideas appear there.

## 2. Things batteries.md already covers that synthesis treats as missing

- **Notification routing** — synthesis's substrate-layers section lists this
  as wanted-but-unbuilt by four facets ("nobody has verified the composition").
  Batteries.md has `lib/notify` marked **implemented**: channels
  (email/webhook/console), rule-based router, batch aggregation, rate
  limiting, retry with backoff, template rendering, 78 assertions. This is the
  single clearest false gap in the synthesis — the exact primitive it
  describes wanting already exists under that name.
- **Theming/i18n** — blindspots.md says "primitive exists, no design
  conversation anywhere," citing only a passing inventory-line mention.
  Batteries.md actually has *two* implemented libraries here: `lib/i18n`
  (translation lookup, `{{var}}` interpolation, pluralization for
  en/es/fr/de/ja/zh/ar, locale fallback) and `lib/locale` (message catalogs,
  CLDR plural rules for 15+ languages, number/currency/date formatting,
  collation). Synthesis undersells this — it's not a thin primitive, it's two
  overlapping full implementations, which is itself worth noting as its own
  minor issue (unreconciled duplication) rather than a gap.
- **Audio decode, partially** — creative.md/games.md name "audio decode
  (WAV/OGG codec)" as missing. Batteries.md has `lib/wave` implemented (WAV
  codec, PCM 8/16/32-bit mono/stereo) and `lib/midi` implemented (SMF parse/
  encode). So the WAV half of "decode" already exists; what's actually missing
  is synthesis (oscillator/envelope/mixer) and a live audio *sink*, which
  synthesis's framing conflates with decode. `lib/dsp` (signal processing,
  filters, FFT) also already exists and is closer to a synthesis substrate
  than synthesis credits.
- **Collaborative CRDT substrate** — communication.md correctly notes `crdt`/
  `merge3`/`diff` exist and flags the sequence-CRDT gap as real (see §1) — this
  one is *not* a false gap, listed here only to contrast with notify/i18n
  which are.
- **PIM/notes stack** — information.md's "mostly-buildable today" list
  (kv_store/sqlite, search, tfidf, fuzzy_match, graph, markdown) is exactly
  batteries.md's own worked example (Lumen, the first motivating target in
  the doc). Synthesis independently re-derives what batteries.md already
  built as its flagship proof case, without citing it.
- **Delta-Chat-shaped E2E chat** — communication.md cites `lib/smtp` +
  `lib/imap`(wip) + `blake2`/`chacha20`/`argon2`. Batteries.md has `lib/smtp`,
  `lib/email` (SMTP+MIME), `blake2`, `chacha20`, `argon2` all **implemented**
  — but no `lib/imap` appears anywhere in batteries.md's exhaustive catalogue
  (confirmed by direct grep, not inference). Whether IMAP exists uncatalogued
  or communication.md is describing aspirational substrate is unclear from
  either document — flagged here rather than assumed either way.

## 3. Where they disagree or have tension

- **Async I/O / event loop — the sharpest disagreement.** Batteries.md names
  this "the single change that unlocks the most use cases," ranks it literal
  priority #1 ("Async I/O / event loop — unlocks: concurrent HTTP servers,
  multiplexed connections, everything network-bound. Largest single gap"),
  and every other item on its priority list (datetime, CLI, logging, jsonrpc,
  lsp, uuid, toml, regex, compression, crypto) is now marked implemented in
  the same document — meaning async I/O is the *last remaining* item from
  batteries.md's own stated priority order. Synthesis never mentions an event
  loop, async I/O, io_uring, or epoll anywhere across all 8 facets or the
  blindspots pass, despite several facets (communication.md's real-time chat,
  system.md's notification routing, ai-agents.md's multi-agent coordination)
  implicitly depending on concurrent I/O working well. This is the most
  load-bearing gap named by the older document and the most conspicuous
  silence in the newer one.
- **What "sandboxed" deployment means.** Blindspots.md assumes "browser tab"
  as the universal crescent-app deployment target and critiques it for losing
  native-app capabilities (background execution, global hotkeys, tray, full
  disk access). Batteries.md's own "portable application substrate" and
  "distribution thesis" sections describe a different model: a ~12MB
  self-contained tarball/LuaJIT artifact users `git clone` or download and
  *run*, with a Lua HTTP server + browser frontend for UI — closer to a
  locally-running native app that happens to render through a browser than a
  sandboxed tab with no filesystem access. The two documents are describing
  different deployment shapes without reconciling them.
- **"The entire computer" means different things in each doc.** Batteries.md's
  "logical conclusion" targets the OS-userspace axis: coreutils, a shell, a
  service manager, a text editor — replacing what sits above the kernel line.
  Synthesis's title claims the same phrase but its facets are entirely
  application-layer: PIM, chat, games, IDE, agents — replacing Obsidian/Slack/
  SillyTavern/VS Code. Both are legitimate readings of "the entire computer"
  but they're not the same claim, and neither document notices the other axis.
- **Priority disagreement on what's "the largest hole."** Synthesis
  (blindspots.md, explicitly) singles out audio as "the one case honestly
  flagged as real rather than assumed away" — i.e., the one thing composition
  of existing libraries can't produce. Batteries.md doesn't rank audio in its
  priority list at all (the list predates or simply doesn't weight creative/
  games facets); its #1 is async I/O, which synthesis never raises. Neither
  document treats the other's top pick as a priority.

## 4. Synthesis of the two

Merged, the two documents describe a genuinely large but unevenly-audited
ecosystem. Batteries.md is the ground truth for *what exists*: ~330
implemented libraries covering nearly every data structure, codec, protocol,
and algorithm a general-purpose stdlib could want, plus five complete app
verticals (web, db, auth, email, queue, search, realtime, tui, ml, logic,
five card/board games) and a working flagship app (Lumen). Synthesis is the
ground truth for *what an application builder actually reaches for first* —
and it shows that even with ~330 libraries cataloged, six facets converge on
wanting things (notifications, i18n) that already exist under names the
facet-writing agents didn't search for, which is itself the finding: the
inventory is large enough that composition-not-discovery is now the bottleneck
for at least two false gaps found here. `docs/inventory.md` ("grep before
designing or implementing anything reusable," per CLAUDE.md) evidently wasn't
grepped hard enough for `notify` or `i18n`/`locale` before those were flagged
missing.

Where synthesis earns its keep is exactly the seven or so substrate needs that
survive scrutiny as real (clipboard, debugger/REPL, sequence CRDT, audio
synthesis+sink, window management, multi-agent coordination, replay/snapshot
format) plus the cross-cutting concerns no facet doc would have surfaced
in isolation (accessibility, platform discoverability, identity-vs-capability,
retention/deletion) — none of which appear anywhere in batteries.md's ~2246
lines. These are the exploration's genuine contribution.

The one place both documents independently converge without citing each
other is Lumen/PIM: batteries.md built it as proof-of-concept, information.md
re-derived the same stack from scratch. That convergence is reassuring (two
independent passes agree on the substrate), but it also means synthesis
under-leverages batteries.md as a source — several of its "missing" and
"mostly-buildable" claims would have been sharper with a grep pass first.

The starkest unresolved tension is async I/O: batteries.md's own priority
list says it's the one gap everything else depends on, and it is the one
thing today's 8-facet, 9-document exploration never once mentions needing.
Whether that's because synthesis's facets happen not to need it, or because
none of the eight parallel agents thought to check, is not something either
document answers — and is the most important open question this delta
surfaces.
