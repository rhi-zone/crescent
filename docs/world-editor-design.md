# Editor Design

The editor is a crescent platform app over the substrate. It is not native, not separate, not a custom build of the runtime. It is one of many possible editors; the substrate has no preferred editing client.

## The bar

By the standards of Inform 7, NWN Aurora, Blender, modern IDEs (VSCode, JetBrains, Emacs). Specifically *not* RPG Maker, Ren'Py, Twine, web-form-as-editor.

Failures the editor must not replicate:

- Modal dialogs for routine edits.
- Visual editor and code editor as separate artifacts that drift apart.
- Cliff between simple (GUI) and complex (script) instead of a slope.
- No live preview; separate "run mode" that loses edit state.
- No find/replace, no rename-across-references, no jump-to-def.
- No persistent undo. No multi-select. No bulk-edit.
- Custom DSL with bespoke editor support that's worse than the host language's tooling.
- Engine and editor coupled — can't use the engine without the editor, can't use the editor with a different engine.
- Default-asset gravitational pull — the tool's identity bleeding into every work it produces.

## Anchoring decisions

**Direct manipulation as default.** Click an NPC on the map; drag; it moves. Click its name; edit inline. Click its inventory; add an item by dropping in. Modal dialogs only for genuinely modal operations.

**The editor is the running world.** No "run mode." The world is always running; edits apply live. The editor is a view onto a running world (your own, or — if caps allow — a connected one). Walk around in the editor. Talk to NPCs in the editor. The author plays the world while editing it, with author caps in hand.

**Schema-aware everywhere.** Forms are generated from types. The substrate's typechecker provides row types per object; the editor reads them and renders the right input for each field. Wrong types are rejected at edit time with useful messages. Autocomplete on references uses the typechecker's symbol table.

**Code and form edit the same artifact.** A form view of an object's `handlers` is a list of handler functions with editable bodies. Switching to code view shows the same handlers as Lua source. Edit in either; the other updates. Round-trips losslessly. The form view is not "easy mode"; it is a projection of the same artifact, with the same expressiveness.

**REPL into the running world.** A console pane attached to any object: evaluate Lua against `self`. Inspect, mutate, call handlers, list properties, walk the prototype chain. The MOO `@dump`, `@verbs`, `@properties` lineage.

**Hot reload with shape migration.** Edit a handler: applies immediately to next dispatch. Edit a property schema: prompts for migration ("how should existing instances update?"). Never restart the world to apply edits.

**Persistent, branching undo.** Backed by the substrate's event log. Undo a single op or a batch. Named checkpoints. Branch and merge. The same fork machinery players use for "what if" timelines, authors use for "what if I had designed this differently."

**Keyboard-driven.** Every operation has a hotkey (configurable). Command palette fuzzy-searches by op name and description. Power users never touch the mouse. Mouse is always available as fallback.

**Refactoring tools.** Rename a property across all uses. Find references to a handler. Extract handler. Move object to another prototype. Same tier as IDE refactoring. Sound by virtue of typechecker symbol tables.

**Multi-select, bulk-edit.** Select 20 NPCs in the map view; edit a property on all. Select a class of objects; apply a handler. The unit of edit is "the selected set," not "the focused single thing."

**Composable views.** A world can be viewed as:

- Map view (spatial: rooms, exits, contained objects).
- Tree view (containment hierarchy).
- Graph view (relationships, dialogue links, exit links).
- Sheet view (table per prototype: all NPCs as rows, properties as columns).
- Timeline view (event log, scrubbable).
- Code view (handler source, type annotations).
- Form view (single object's properties, generated from types).
- Prose view (narrated current state, or POV view through an agent's beliefs).

All views are live, all over the same data, all editable. Multiple views can be open simultaneously and sync on edit.

**Editor extensible via operations.** The editor is itself written using the operations library plus crescent UI primitives. Users can add new views, new buttons, new hotkeys, new commands by writing operations. Editor customization is world customization.

**Multiple editors over the same substrate.** A tile-grid editor for grid-shaped worlds. A node-graph editor for dialogue-heavy worlds. A prose editor for IF-style worlds. All operate on the same world format, none is privileged. Authors pick the editor that fits their world; can use multiple at once.

**Diffable world format.** The substrate's serialization is text-based and git-friendly. World edits make meaningful diffs. Branches in version control work. Merge conflicts mean what they look like they mean.

## Layout (v0)

```
+--------------------+----------------------------+--------------------+
| navigator          | main view                  | inspector          |
| - worlds           |                            | properties         |
| - rooms            |   (map / sheet / code /    | handlers           |
| - objects          |    prose / timeline / etc) | prototype chain    |
| - prototypes       |                            | recent events      |
| - roles            |                            |                    |
+--------------------+----------------------------+                    |
| repl / log / diag tabs                          |                    |
+--------------------+----------------------------+--------------------+
| status: world running | role: author | oracle: gemma-4 | peers: 0    |
+--------------------+----------------------------+--------------------+
```

- Top: command palette (Ctrl-K), checkpoint list dropdown, undo history list.
- Status bar: world state, current role / cap-set, oracle backend, connected peers (if multi-user).

## Live editing semantics

Every editor action is a substrate operation:

- Property edit → `edit_property` op → event log entry → effect applied → live.
- Handler edit → `define_handler` op → event log → next message dispatch uses new code.
- Schema migration → `define_prototype` op with migration → applied to all instances → events log this.
- Bulk edit → composite op, atomically applied, single event log entry with batch contents.
- Code-view save → diffed against current, emits the minimal set of `define_handler` / `edit_property` ops.

Editor and substrate share state; nothing is editor-only. The "editor's view" is just a query (or a stack of queries) over the substrate.

## Form generation from types

For a property of type `T`:

- `string` → text input. `string | "a" | "b"` (literal union) → enum dropdown.
- `integer` → number input. `Range<1, 100>` (if expressible) → slider.
- `boolean` → checkbox.
- `Ref<Object>` → object picker, filtered to refs of compatible types.
- `{ Ref<Object> }` → list editor with picker per slot.
- `Record<...>` → nested form.
- `Union<A, B>` → tabbed form with one tab per variant.
- `Match<...>` → form whose shape switches based on a discriminator field.
- `Opaque<T>` (typechecker nominal wrappers) → opaque renderer with a "raw" view for power users.

Form metadata (label, description, ordering, custom widgets) is optional and lives in a `Meta<T, ...>` wrapper or sidecar table. Defaults derived from field names if metadata absent. Authors writing types get good forms for free; metadata is for refinement, not necessity.

## REPL semantics

REPL is tied to a focus object (the currently inspected one). Bindings: `self` is the focus, `world` is the world, `caps` is the editor's cap set.

Commands:

- `EXPR` — evaluates Lua expression; output rendered structurally (tables get tree view).
- `:verbs` — list handlers on focus.
- `:props` — list properties.
- `:proto` — show prototype chain.
- `:refs-to` — find references to focus elsewhere in the world.
- `:log [n]` — show last n events touching focus.
- `:fire <verb> <payload>` — synthesize and dispatch a message to focus.
- `:type <name>` — show type definition.
- `:ops` — list operations the current cap set can invoke.
- `:do <op-name> <args>` — invoke an operation.

REPL operations are themselves logged as substrate events (read-only ones tagged accordingly), so the editing trail is reconstructible.

Read vs write: `EXPR` is read-only by default; write access requires the `repl_write` cap and is gated by a per-session confirmation (avoid accidental world mutations from typo'd expressions).

## Distribution

The editor is a crescent platform app. Installed via the normal app channels. Worlds being edited are separate apps (or same-app, edit-in-place — depends on world configuration). The editor can connect to any world it has caps for: local file, local app, remote app over interconnect (later).

The editor's own state (open views, layout, hotkey configuration, recent worlds, REPL history) persists in the editor app's own `db`/`kv` caps. Per-world editor state (which views are open, which checkpoints, custom commands) lives in the world's `db`.

## What v0 covers

- Navigator (tree), map view, sheet view, code view, form view, prose view.
- Inspector with REPL.
- Command palette + hotkeys.
- Hot reload of handlers and properties.
- Persistent undo via event log; named checkpoints.
- Multi-select and bulk-edit.
- Form generation from types (basic; metadata sugar comes later).
- Refactoring: rename, find-references, jump-to-def, extract-handler.
- Per-object inspector with property editing, handler editing, prototype-chain navigation.

What v0 does not cover (deferred):

- Graph view (months of polish).
- Timeline scrubbing with branch visualization.
- Voice command.
- Remote-world editing (deferred with cross-app transport).
- Visual rule editor for handlers (handlers are Lua source for now).
- Collaborative editing (two authors editing one world simultaneously).

## Why this passes the bar

The combination that makes this not-RPGM, not-Ren'Py, not-Twine:

- **Substrate-first**, with editor as a view, not the other way around. Worlds are independent artifacts; tools come and go.
- **No genre baked in.** The editor edits objects, not "actors and skills and items."
- **Type-driven UI**, sound at edit time, autocomplete that works, refactoring that doesn't break things.
- **Live world**, no edit/run distinction, hot reload that respects state shape.
- **Diffable, git-friendly format**, version control as the source of truth.
- **Extensible via operations** — the editor itself is configurable by the same machinery used to author worlds.
- **Multiple specialized editors possible** over the same substrate, so no one editor is the bottleneck.

The discipline shift from existing tools: the editor is a thin layer over a clean substrate, instead of a thick layer hiding an opinionated engine. This is the same pattern Blender uses (mesh data is the source of truth; the editor manipulates it; you can edit meshes via Python without the GUI) and the same pattern Inform 7 fails at (the IDE is the substrate; world data is illegible without it).
