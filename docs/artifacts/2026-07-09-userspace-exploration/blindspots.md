# Blindspots — a pass across all 8 facets

Speculative, like the docs it reviews. This is not a gap in any one facet;
it's what the facet-based framing itself couldn't see because each doc was
written in isolation, one person per box.

## 1. Missing domains — nobody's box

- **Accessibility.** Zero mentions across 8 docs, in an ecosystem whose whole
  pitch is text-first, protocol-first, browser-runnable. Screen readers, ARIA,
  reduced-motion, colorblind-safe palettes (creative.md names `color` as
  substrate but never accessibility of color choices), keyboard-only
  navigation. This isn't a niche facet — it's a cross-cutting requirement
  every DOM-rendering app in `lib/platform/` either satisfies or silently
  fails, and none of the 8 docs raised it even once.
- **Privacy as a user-facing activity**, distinct from caps-as-security-model.
  Export my data, delete my account, see what an app logged about me, redact
  a field before sharing a note (information.md) or a chat log
  (communication.md). The cap system controls what an app *can* reach: it
  says nothing about what a user can *audit or revoke after the fact* — "this
  app had `fs` for three months, show me what it touched" is a UX problem
  none of the docs pose, even though system.md's audit log is named as
  existing substrate.
- **Money/finance beyond `lib/money` as a type.** Budgeting, expense
  tracking, invoicing, double-entry bookkeeping, tax prep — productivity.md
  lists `money` as substrate for currency handling, never as a facet of its
  own. This is a full domain (Mint/YNAB/Beancount-shaped) with a real
  crescent-native story (plain-text ledger a la ledger-cli/hledger is
  extremely on-brand) that nobody explored.
- **Health/fitness/quantified-self.** Habit tracking got one paragraph in
  productivity.md as "a fold over time_series," but sleep logs, workout
  programming, nutrition tracking, and biometric data (with its own privacy
  stakes) are a distinct domain with distinct prior art (Apple Health,
  Oura, TrainingPeaks) that never appeared.
- **Education/learning tools** — flashcards/spaced repetition (Anki),
  interactive tutorials, courseware. Crescent's own principle
  ("discoverability in the tool not in tutorials") is arguably an
  education-design stance and nobody connected it to the domain.
- **Science/research computing beyond information.md's note-taking angle** —
  notebooks got a nod in development.md (Observable-style), but data
  analysis, plotting/statistics as a research workflow, lab notebooks, unit
  conversion, and reproducible-computation (crescent's own zero-dep ethos is
  unusually well-suited to "reproducible research artifact") never surfaced.
- **Mapping/GIS.** `geom`/`geometry_3d`/`voronoi`/`kdtree` are all listed
  repeatedly (creative.md, games.md) but never once pointed at maps,
  routing, or geospatial data — a natural fit given the substrate already
  exists and nobody claimed it.
- **Networking/sysadmin as a user activity**, as opposed to system.md's
  "OS glue" framing — configuring a router, running a home server, managing
  DNS records, monitoring uptime for things you host. system.md covers the
  desktop side of infra; the sysadmin/homelab side (crescent running
  headless as infrastructure, not just a personal-computer facet) is absent
  everywhere, despite `lib/platform/daemon/` and the whole
  reliability-substrate list (`circuit_breaker`, `service_registry`) being
  aimed exactly there.
- **3D/CAD/manufacturing/print** — `geometry_3d` exists, physics_2d exists,
  but nobody explored CAD, 3D printing slicers, or even paged print output
  (mentioned once in system.md as "disproportionate user rage," then
  dropped).
- **Legal/compliance/contracts** — e-signatures, document versioning with
  legal weight, non-repudiation (communication.md raises non-repudiation
  only to note chat apps *don't* want it, never asks who does).

## 2. Cross-cutting concerns — spanned by all, owned by none

- **Undo/redo.** `command`/`command_queue` is named once (productivity.md,
  parenthetically, as "undo-redo") and never mentioned again — not in
  creative.md (a paint/livecoding tool without undo is unusable), not in
  development.md (an editor without undo is unusable), not in
  information.md (editing a note). Every facet needs it; every facet
  assumed it exists elsewhere.
- **Search, as a universal cross-app expectation**, not just information.md's
  PIM search. Spotlight/Alfred-style "search everything on this machine" —
  files, notes, chat history, settings — got a glance in system.md
  (rofi/dmenu as a launcher) but never connected to information.md's search
  stack as the same underlying need wearing a system-level UI.
- **Theming/appearance and internationalization.** i18n/locale is listed as
  existing substrate in productivity.md's inventory line and never discussed
  again in any doc — not as a design question for any facet, even though
  every user-facing app in every facet would need it.
- **Onboarding / discoverability of the platform itself.** Every doc
  describes what a *tool* would look like once built. None asks how a user
  finds out crescent has 300+ libraries and can become any of these tools —
  the overview's own stated principle ("discoverability in the tool not in
  tutorials") is never tested against "how do I find the tool at all,"
  which is a prior, harder problem.
- **Error handling as a user-facing experience** — not the `(nil, errmsg)`
  library convention (that's covered exhaustively in CLAUDE.md), but what a
  *user* sees when a cap is denied, a network call times out, a sandboxed
  app crashes mid-task. system.md gets closest (audit log, cap denial) but
  frames it as security, never as UX — nobody asks "what does the error
  screen look like."
- **Import/migration from incumbent tools.** Nearly every doc names the
  incumbent crescent would compete with (Obsidian, Slack, Trello, VS Code,
  SillyTavern) but only ai-agents.md mentions an actual import path
  (SillyTavern card import). Nobody else asks how a user's existing Obsidian
  vault, Trello board, or IMAP mailbox gets in.
- **Notifications as a single cross-cutting primitive**, not five different
  facet-local reinventions. system.md names it as a missing cap; productivity.md
  needs it for snooze/triage; communication.md needs it for @mentions;
  ai-agents.md needs it for "agent finished a task" — four docs independently
  want the same primitive and none cross-referenced the others.
- **Sharing / export as a universal action.** "Share a URL" (creative.md,
  Shadertoy), "export SVG" (creative.md), "export standalone HTML"
  (information.md, Twine), "crosspost" (communication.md) are all one
  underlying need — take an artifact out of crescent and hand it to someone
  who isn't running crescent — described independently four times with no
  shared vocabulary.

## 3. Shared assumptions worth questioning

- **All 8 assume single-user, single-device, one-session-at-a-time**, except
  where a doc explicitly names multiplayer (creative.md's Figma cursors,
  communication.md's whole point). Nobody asked what it means for the *same
  crescent instance* to be used by two people at once outside those two
  docs — e.g., does a shared family calendar (productivity.md) or a shared
  note vault (information.md) assume multi-user from day one, or is that an
  afterthought bolted on later?
- **All 8 assume the user is sighted, using a pointer or keyboard, on a
  screen roughly laptop-sized.** No doc considers voice interfaces, small
  screens/mobile touch, or screen-reader-only use as a first-class input
  mode, despite "the entire computer" as the framing.
- **All 8 implicitly assume good-faith, competent, single-tenant use** — no
  doc considers hostile input, abuse (spam, harassment in communication.md's
  chat, malicious cards in ai-agents.md's SillyTavern import), or
  moderation. A "communication" facet with zero mention of spam/abuse
  handling is a real gap given it's the single most consequential failure
  mode of every real chat product.
- **Text-primacy is assumed almost everywhere** even in "creative" and
  "games" — canvas/SVG/audio are treated as *outputs* of a text/code-driven
  process (shaders, livecoding, generative seeds), never as a primary
  *input* modality (drawing with a tablet, recording with a mic as the
  starting point rather than the destination).
- **All 8 assume a benevolent, static philosophy document is authoritative**
  — every doc cites CLAUDE.md/`docs/overview.md` as settled ground truth and
  never asks whether the philosophy itself might need to flex for a given
  domain (e.g., communication.md flags E2E-vs-federation tension but still
  treats "no framework code in lib/" as unquestionable even where a chat
  primitive arguably needs some dispatch shape).
- **Every doc assumes "browser tab" is the deployment target** without
  asking what's lost relative to a native app users already trust with
  full-disk access, background execution, or OS-level integration
  (global hotkeys, system tray, share-sheet integration) — system.md gets
  closest by naming the window-management tension but doesn't generalize it
  to "what can crescent apps never do because they're sandboxed in a tab."

## 4. Structural blindspots from the facet framing itself

- **Cross-facet workflows are invisible by construction.** A real session
  looks like: write code (development.md) while chatting about it in a
  side panel (communication.md) with an AI agent (ai-agents.md) that takes
  notes (information.md) and schedules a follow-up (productivity.md) — one
  continuous task touching five "facets" that were assigned to five
  separate agents who never talked to each other. None of the 8 docs asks
  how state (the open file, the chat context, the note, the todo) moves
  between apps in the same session, because each was scoped to pretend the
  other seven don't exist simultaneously.
- **App discovery and composition has no owner.** Every doc independently
  proposes new `lib/platform/apps/*` — a note app, a chat app, a kanban app,
  an IDE, a fantasy console. Nobody asks how a user goes from "I have a
  goal" to "here is the composed set of apps/libraries that satisfies it,"
  or how two apps *within* crescent discover and talk to each other (as
  opposed to how one app reaches an external cap). The clipboard discussion
  in system.md is the only place this gets close, and it's framed as a
  security question, not a composition/discovery one.
- **The "same libraries, many tools" thesis is asserted by nearly every doc
  and never stress-tested against a case where it fails.** Every doc finds
  confirming evidence (canvas backs a paint app and a generative-art
  script; ecs backs a game and a simulation). None asks what a facet needs
  that *can't* be satisfied by recomposing existing primitives — i.e.,
  where "just compose libraries" is actually a cop-out for "we didn't find
  the missing primitive." Audio (creative.md, games.md) is the one place
  this gets flagged honestly as a real gap rather than assumed away.
- **No doc asks what crescent does *badly* on purpose** — every facet is
  framed as "gaps to fill," never "here's a domain crescent's philosophy
  is structurally the wrong tool for and should explicitly not chase."
  development.md is the only doc that names real non-goals (CI orchestration,
  containers); the other seven treat every gap as eventually closeable,
  which reads as scope creep dressed as thoroughness.
- **Each doc was assigned a noun-shaped category** (creative, information,
  communication...) rather than a verb-shaped one (capturing, deciding,
  scheduling, showing-to-others). The result is that facets converge on
  near-identical primitives from different angles (five docs independently
  want a notification cap; three independently want CRDT-backed sync; three
  independently want a "todo/task" shape) without anyone assigned to notice
  the convergence, because the org chart of the exploration — not the
  domain — produced the seams.

## 5. Where the philosophy has nothing to say

- **Multi-tenancy and identity** (who is "the user" when a cap is granted,
  what does an account mean, how does auth compose across apps) is used
  constantly (oauth2/jwt named as substrate in communication.md,
  ai-agents.md's keyring) but never designed — caps say what an app can
  touch, not who the human on the other end of a session is, and none of
  the docs notice this is a real gap between "capability" and "identity."
- **Real-time performance/latency guarantees.** Caps-first composability
  says nothing about whether a pure-Lua-baseline library can hit the <20ms
  frame budgets creative.md's livecoding and games.md's rhythm-game timing
  actually require — "target LuaJIT, don't require it" is a portability
  stance, not a performance guarantee, and nobody checks whether the
  pure-Lua fallback tier is even usable for the timing-critical facets that
  need it most (audio scheduling, netcode).
- **Federation/trust between independent crescent instances** run by
  different people (communication.md's federation discussion is the only
  place this gets addressed, and only for chat) — zero-dependency and
  caps-first both describe a *single* instance's internal discipline and
  say nothing about how two untrusted crescent deployments agree on
  anything, which is exactly the problem every "share this with someone
  else" workflow (export, sync, federation, multiplayer) runs into.
- **Regulatory/compliance surface** (GDPR-shaped data deletion, HIPAA-shaped
  health data, financial recordkeeping) has no philosophical answer anywhere
  in CLAUDE.md or the overview — caps-first controls *access*, not
  *retention or deletion guarantees*, and a health/finance facet (missing
  above, section 1) would immediately need one.
- **Monetization / sustainability** as it shapes tool design. Nearly every
  incumbent named across the 8 docs (Notion, Slack, Superhuman, Zapier) is
  the shape it is because of a business model, and several docs note this
  explicitly (productivity.md: "Notion bundles because of multiplayer sync,
  not because the concepts are one thing"). But none asks what shape a
  *free, zero-dependency, no-hosted-service* ecosystem's incentive-free
  design produces when the incumbent's constraint (needing recurring
  revenue) is simply absent — is that uniformly liberating, or does it mean
  nobody has a reason to build the unglamorous 90% (support, onboarding,
  content moderation) that a business model usually funds?
