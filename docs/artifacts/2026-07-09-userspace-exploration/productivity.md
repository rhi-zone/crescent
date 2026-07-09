# Productivity as a crescent facet

Exploring what "crescent as the entire computer" means for calendars, todos,
docs, spreadsheets, automation, and personal dashboards. Grounding in what
people actually do, what prior art got right/wrong, what crescent already
has, and where its philosophy (caps-first, zero-dep, browser-sandboxed,
composable libraries not frameworks) produces something different.

## What people actually do

- Drag a card from "In Progress" to "Done" on a kanban board (Trello,
  Linear). The drag is really: mutate a `status` field, re-render a column
  grouped by that field.
- Set "every Tuesday at 9am, remind me to submit the timesheet" — a cron
  expression wearing a friendly UI (Google Calendar recurrence, Things'
  repeating todos, systemd timers for the technical crowd).
- Write `=SUM(B2:B47)` and drag-fill it down a column, or `=VLOOKUP(...)`
  across sheets (Excel/Sheets). The formula is a DAG: cell depends on
  range, range depends on cells, recompute on change.
- Triage an inbox into "reply now / later / archive / snooze until Monday"
  (Superhuman, Gmail snooze). Snooze is really: hide-until(timestamp), a
  deferred re-surface.
- Time-box a day: block 9-11 for deep work, let the calendar refuse a
  meeting invite that overlaps it (Reclaim.ai, Motion). This needs the
  calendar to reason about *free/busy*, not just store events.
- Track a habit by tapping a checkbox once a day and watching a streak
  counter (Streaks, Loop Habit Tracker). Streak is a fold over a sorted
  date-set with a "no gap > 1 day" predicate.
- Chain "when a Slack DM contains 'invoice', save the file to Drive and
  ping me" (Zapier/IFTTT/n8n) — trigger, filter, action, all declarative.
- Run a keyboard-triggered script that resizes windows, opens a URL with
  clipboard contents interpolated in, or renames files by regex
  (Alfred/Raycast/Hammerspoon/AutoHotkey). The common shape: capture input
  (hotkey, clipboard, selection) → transform → act on OS.
- Build a Gantt chart by hand-estimating task durations and dependencies,
  then watching the critical path shift when one task slips (MS Project,
  Linear's roadmap view, `org-mode` with `:LOGBOOK:` clocking).
- `org-agenda` in Emacs: pull todos with `SCHEDULED:`/`DEADLINE:` across
  many files into one virtual view, filtered/sorted on the fly — the
  view is computed, not stored.
- Taskwarrior: `task add proj:crescent +urgent due:tomorrow`, then `task
  next` computes an urgency score from due date, priority, age, blocking
  status — a pure function over task metadata, no manual sort.

## Prior art, what it got right and where it strains

- **Org-mode agenda** is the strongest precedent for crescent's style:
  plain text is the storage format, the agenda view is a *query* over
  files on disk, recomputed on demand. No database, no sync service
  required for single-machine use. Crescent's `template`/`markdown` +
  `csv`/`kv_store` already cover this shape.
- **Taskwarrior** proves urgency/priority computation is just a scoring
  function over structured records — no reason this needs a SaaS.
- **Notion/Airtable** conflate three things that should be separable:
  (1) a schema'd table (spreadsheet + schema validator), (2) multiple
  *views* over the same rows (kanban/calendar/gallery — projections), (3)
  a rich-text document editor. Crescent already has the pieces
  disaggregated (`spreadsheet`, `schema_validator`, `reactive_db`
  live-queries, `markdown`); Notion bundles them behind a server because
  it needs multiplayer sync, not because the concepts are inherently one
  thing.
- **Zapier/n8n** are "if this then that" over *other people's* APIs — the
  entire product is the connector catalog, which is explicitly out of
  scope for a zero-dependency ecosystem (CLAUDE.md bans framework code
  and adapter-layer dispatch in `lib/`). What crescent *can* offer is the
  trigger/filter/action composition primitive as a plain library
  (`workflow`, `pipeline_dsl`, `event`) that a user wires by hand to
  whatever caps they've injected — no hosted connector directory needed.
- **Excel** formulas are a spreadsheet-specific DAG language; crescent
  already has `reactive`/`signals` (auto-tracking) which is the same
  dependency-graph-with-recompute shape, just not spreadsheet-flavored
  yet. The interesting question is whether `spreadsheet` should be built
  *on* `signals` rather than reinventing recalculation.
- **Reclaim.ai/Motion** need "free/busy + auto-scheduling" — that's a
  constraint solver over intervals, and crescent already has
  `interval`/`interval_tree` and `constraint_solver`. Auto-scheduling
  tasks into calendar gaps is a real, non-trivial feature nobody in this
  space has cleanly composed from primitives that small.
- **Alfred/Raycast/Hammerspoon** are OS automation with a plugin
  ecosystem; crescent's sandboxed browser cap model is a natural fit for
  the *safe* version of this (scripts declare which caps — clipboard,
  fs, notify — they need, sandbox enforces it) instead of Hammerspoon's
  ambient full-Lua-access-to-your-Mac model.

## What crescent already has

From the inventory: `calendar`, `cron` + `cron_parser`, `datetime`/
`duration`/`time`/`time_series`, `spreadsheet`, `csv` (+query/transform),
`json`, `template`/`template_engine`, `markdown` (x2), `html`, reactive
signals (`reactive`/`signals`), `state`/`state_machine` (5 FSM impls —
pick one), `workflow`, `task_queue`/`task_runner`, `scheduler`,
`command`/`command_queue` (undo-redo), `schema_validator` (one of 5
overlapping), `money`, `i18n`/`locale`, `humanize`, `pagination`,
`reactive_db` (live queries), `pipeline`/`pipeline_dsl`, `notify`,
`event`/`event_emitter`, `iCalendar` codec, `kv_store`, `search`,
`inverted_index`, `merge3`/`diff` (useful for doc conflict resolution).

This is already most of the *substrate* for a personal productivity stack.
What's absent is the assembly: no todo-list library, no kanban/gantt
projection helpers, no habit-tracker, no time-tracker, no inbox-triage
primitive, no auto-scheduler tying `calendar` + `constraint_solver`
together.

## Missing pieces and design questions

- **Todo/task library doesn't exist as such.** `task_queue`/`task_runner`
  are execution-queue concepts (background jobs), not "things a human
  hasn't done yet." A `todo` library needs: status enum, due/scheduled
  dates (`datetime`), recurrence (`cron_parser`), priority/urgency
  scoring (Taskwarrior-style pure function), and *tags* — not a new
  storage engine, just a record shape plus scoring/filtering functions
  over `kv_store` or plain tables.
- **Kanban/Gantt are views, not stores.** The crescent-native move is: one
  task/event record shape, N pure projection functions (`group_by_status`,
  `to_gantt_bars` computing critical path from dependency edges via
  `graph`, `to_calendar_grid`). This avoids ever building "a kanban
  library" that owns data — it stays a rendering function over whatever
  the caller already has, callable from `lib/web/reactive_dom` or a TUI.
  Question worth surfacing, not deciding here: does `spreadsheet` become
  the canonical backing store for these (rows = tasks, columns = fields,
  get kanban/gantt/calendar "for free" as views over any table), or does
  a dedicated `task` record type outperform a general spreadsheet cell
  model for this? That's a real tradeoff — spreadsheet gives formula
  power and familiarity, a typed task record gives the typechecker
  something to hold onto — and it's the kind of call that should be made
  once, deliberately, not drift from whichever gets built first.
- **Auto-scheduling (Reclaim-style) is unclaimed and composable today.**
  `calendar` (busy intervals) + `constraint_solver` or `interval_tree`
  (find gaps) + `scheduler` (place tasks) is a real, small, valuable
  library nobody else ships as a pure algorithm — everyone bundles it
  with a hosted calendar sync. Crescent could ship the *algorithm* as a
  pure function `schedule(tasks, busy_intervals, prefs) -> placements`
  and let the caller wire it to whatever calendar cap they have.
- **Inbox triage** (email/notifications) is a filter+action pipeline over
  a message stream. `bayesian_filter` (already in numerics/ML) plus
  `pipeline_dsl` plus IMAP/SMTP (wip/stub per inventory — `imap` is
  listed stub or broken) gets most of the way there once IMAP matures.
  Snooze is just `notify` + `scheduler` re-surfacing a hidden item at a
  timestamp — no new primitive needed.
- **Habit tracking** is a tiny fold over `time_series`: a sorted set of
  completion dates, streak = longest run with gap ≤ 1 day, already
  expressible with existing date/duration types. Doesn't need a library,
  needs an example.
- **Automation/scripting (Alfred/Hammerspoon-alike) is the sharpest
  philosophy fit.** The sandbox cap model means a user-authored automation
  script is *safe by construction* the way a Hammerspoon `.lua` file
  never is — the manifest declares "this script gets clipboard read +
  notify + fs write to ~/Downloads," sandbox enforces it, no ambient
  access to the rest of the machine. Nobody else in this space (Alfred
  workflows, Raycast extensions, AHK scripts) has capability-scoped
  automation; they all run with full user privilege by default. This is
  the one place where "browser sandbox + injected caps" isn't just an
  implementation detail forced by the deploy target — it's a feature the
  incumbents structurally can't offer, because none of them started from
  a cap system.
- **Documents/presentations are the weakest fit today.** `markdown` +
  `html` + `template` cover static docs; there's no rich-text editing
  model (cursor/selection/collaborative-edit) and no slide/presentation
  concept anywhere in the inventory. `merge3`/`diff` exist, which is the
  hard part of collaborative editing (CRDT is also listed!) — `crdt` +
  `merge3` might already be enough substrate for a real-time collaborative
  doc, which would be notable since that's usually the part that forces
  people onto a hosted backend. Worth flagging as unclaimed, not
  designing here.

## What a crescent-native version looks like

Not a Notion clone with a Lua backend — a set of small libraries a script
composes: task records scored by a pure `urgency(task, now) -> number`
function (Taskwarrior's insight, generalized); calendar/kanban/gantt as
projection functions over one record shape, not three separate stores;
automation scripts that declare their caps in a manifest and run sandboxed
in-browser with zero install; an auto-scheduler that's a pure algorithm
over intervals, decoupled from any specific calendar service. The
recurring shape across this whole facet: prior art bundles "algorithm"
with "hosted sync service" because that's the business model; crescent's
opportunity is shipping the algorithm alone and letting caps supply
whatever storage/sync the user already has.
