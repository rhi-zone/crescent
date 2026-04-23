# UI Design Principles

General laws for all platform app frontends. Specific applications of these
laws (and decisions about concrete ccv2 UI) live in the relevant per-app
design docs — this file is the pattern, not the instance.

These rules are derived from four lenses we use to diagnose UX:
**affordance types**, **affordance surfaces**, **affordance opacity**,
**interaction graph**. Rules that came out of those lenses live under
§"Rules from the lenses". The rules above that section are older and
equally binding.

## Layout shift is always wrong

Any UI change that moves existing content (text jumps, buttons reposition,
message list shifts) is a bug. Never accept it; never mask it with a CSS
transition.

**The fix is always structural**: content that expands/collapses must not
participate in document flow. Use `position: absolute` or `position: fixed`
overlays. Panels that appear on demand float over existing content — they do
not push it around.

`max-height` transitions delay layout shift; they do not eliminate it. Delay is
not a fix.

## Truncating error messages is always wrong

Error text must be fully visible. Never use `text-overflow: ellipsis` or
`white-space: nowrap` on error or status messages. Use `word-break: break-word`
so long URLs and technical strings wrap rather than clip.

The user cannot act on an error they cannot read.

## `position: absolute` over content is always wrong

Action buttons (Edit, Delete, etc.) that float over content via
`position: absolute` overlap and obscure it. Put them in a footer row in
document flow, controlled by CSS `:hover` on the parent. No JS required for
show/hide.

## Identical UI for different states is always wrong

Buttons with toggle state (expanded/collapsed, active/inactive) must have a
visually distinct active state. Don't make the user click to discover the
current state.

CSS class-based approach: `.toggle--active { background: var(--accent); }`.

## Button count is a design budget

Every button in a persistent toolbar spends cognitive load. Before adding one,
ask: does this need to always be visible? Can it live in a panel, overflow
menu, or keyboard shortcut instead?

Primary actions prominent. Secondary actions nearby but distinct. Everything
else behind a toolbar row, overflow menu, or shortcut. When the count passes
the threshold where the toolbar feels like "a wall of buttons", it already did
— redesign, don't keep adding.

## Names should carry scope

When two features have the same mechanism but different scope (e.g. per-object
vs per-user), the names must make scope obvious ("Card Lorebook" vs "My
Lorebook", not "Lorebook" vs "World Info"). Scope that the user has to infer
from context is cognitive overhead the UI is charging them.

## Rules from the lenses

Derived from applying the four lenses
(`~/git/rhizone/github-io/docs/affordance-types.md`, `affordance-surfaces.md`,
`affordance-opacity.md`, `interaction-graph.md`) to concrete platform-app UX.
These are platform-wide, not ccv2-specific.

### affordance types → no command-monoculture

- **T1.** Every surface is typed by affordance role. A single surface must
  not mix more than two affordance types (command / navigation / data-entry /
  ambient / gestural / directional) without visual separation.
- **T2.** Controls that *change context* (open a panel, navigate to a
  different view) must render distinctly from controls that *execute an
  action* (send a message, save, delete).
- **T3.** Controls that *execute a one-shot action* must not sit in the same
  visual group as controls that *open editors or modals*.
- **T4.** Data-entry affordances (text, sliders, pickers) must not be
  reachable only by traversing a command.

Common failure: "input row with 10 buttons" where every affordance is
rectangular-with-label regardless of type. The data model behind that row is
"commands," which biases the UI away from everything a command isn't.

### affordance surfaces → Miller and removal

- **S1.** No visible group of same-priority controls exceeds 7 items
  simultaneously. Applies at every level of a hierarchy — you cannot chunk
  your way out by having 6 groups × 8 items if all 48 are visible at once.
- **S2.** Reducing below the limit is achieved by *removal* (contextual
  hiding), not by reordering, shrinking, or demoting. Items still visible
  still occupy working-memory slots; demoting doesn't help.
- **S3.** Semantic groups — primary action / secondary action / destructive /
  navigation / create — are spatially separated. Collapsing them into a
  single strip destroys muscle memory.
- **S4.** Strategic affordances (those the platform relies on for its value
  proposition — e.g. "create a new X") are pinned on a top-level surface
  *regardless of per-user frequency*. Personal pinning-by-use would
  deprioritize them because they're rare per user; it must not. This is an
  explicit override on the "stability earned per-item" heuristic.
- **S5.** Objects with shared identity have exactly one canonical entry
  point. Two top-level buttons that both open modals editing the same
  object's data is a duplicate node.
- **S6.** Command palettes are escape hatches, not primary navigation.
  A surface where the palette *is* the primary path to a core-loop
  affordance has failed.

### affordance opacity → creation is not hidden

- **O1.** For every user role the app wants to enable, at least one
  affordance on the default surface visibly names that role's first step.
- **O2.** Nothing central to the value proposition requires a modifier key,
  a right-click, or a hover to discover.
- **O3.** Verb-first labels on role-enabling affordances. "New Thing" beats
  "Thing Editor"; the editor label reads as "edit an existing thing,"
  which is wrong for the create path.
- **O4.** Transitions between workflow stages ("I used this thing" → "I
  want to make one like it") are rendered as visible edges, not inferred
  by the user.
- **O5.** Errors and status render in full. Truncation is an opacity
  violation because the system is hiding state from the user. (Duplicates
  the stronger rule above; kept here for lens-completeness.)

### interaction graph → no dead ends, no missing edges

- **G1.** Every node a user can reach has at least one outgoing edge
  relevant to the app's core loop. Barren nodes are bugs. Card header with
  only display and no actions is a barren node.
- **G2.** Where a workflow crosses object boundaries (e.g. "this
  conversation" → "a new thing seeded from this"), there must be a direct
  edge at the point of use — not a menu-level command that operates on
  "the current selection."
- **G3.** Objects that share identity are one node with multiple affordances,
  not multiple nodes with separate subgraphs. The card-as-played, the
  card-as-edited, the card-as-exported are one node.
- **G4.** The "consume → create" edge — whatever local form it takes in a
  given app — must exist and be visible. Without it, R > 1 is structurally
  impossible for whatever the app produces.
- **G5.** Destructive affordances state what is lost and are reversible or
  confirmed. No undo means fear of exploration.
- **G6.** Common paths are direct edges. "Common operations require too
  many hops" is a missing-shortcut failure.

## Crescent-specific flavor

Rules above apply to any app. These add constraints specific to crescent's
shape:

- **Prefer many apps over one configurable app.** "One card builder"
  violates this; "many card builders, competing on style and approach" is
  the pattern. The platform is the unit of composition; apps are cheap.
  See `CLAUDE.md` → "Apps are cheap — prefer a new app over a new abstraction"
  for the platform-app variant of this rule.
- **Creation is not a separate app from consumption where that split would
  force a context switch.** Building a new instance of an object should be
  reachable from the app that plays/views that object, not behind a
  different app the user has to install and launch. (Having multiple
  creation *apps* is orthogonal — the user picks the one they prefer, but
  each must integrate into the consumption experience of its output.)
- **Ambient affordances over modal ones.** Status, read-only notices,
  capability presence/absence should show as ambient inline UI, not as
  dialogs the user has to dismiss.
- **Zero-friction import is table stakes.** Drag-drop, paste, open-with —
  the path from "I have a file" to "I am using it" is ≤1 action.

## Gaps in the lenses

Noted during derivation; these are known limits of the current lens set,
not things the lenses solve:

- **Social reproduction is unaddressed.** Attribution chains, fork
  provenance, export-and-re-share quality aren't derivable from the four
  lenses. The lenses scope to "one user in one session."
- **Phase transition from consumer to creator is unmodeled.** The lenses
  treat the user as one identity with one set of goals; the progressive
  disclosure of a creator-role affordance set is not covered.
- **Low-frequency strategic affordances need an override.** The
  "stability earned per-item by use" heuristic in `affordance-surfaces.md`
  actively deprioritizes affordances that are rare per-user but
  high-leverage for the ecosystem (e.g. "create a new X"). Rule S4 above
  is the patch; the underlying lens doesn't provide it.
- **Nomenclature is not a lens.** Several real UX failures are label
  failures ("Card Editor" reading as "edit," naked "Lorebook" without
  scope). The "names should carry scope" rule came from experience, not
  from any of the four lenses.
