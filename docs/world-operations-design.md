# Operations Library Design

The operations library is the value layer. The substrate is small and finished; the operations library grows forever and is what makes the product feel deep.

## What an operation is

A named callable with:

- `name: string` — stable identifier (used in UIs, hotkeys, scripts).
- `description: string` — human-readable purpose.
- `caps_required: { [CapName]: CapSpec }` — which caps the caller must hold.
- `params: SchemaOfParams` — typed, validatable, editor-renderable.
- `oracle: "none" | "optional" | "required"` — whether an oracle is invoked.
- `effects_produced: { EffectKind }` — declared subset of substrate effects this op may emit.
- `run: (world, caps, params) -> { Effect }` — the actual function.
- `examples?: { ExampleInvocation }` — for docs and editor previews.
- `tests?: { TestCase }` — at least one for any non-trivial op.

Operations are themselves substrate objects with handlers. They are stored in the world; users can list them, inspect them, invoke them. Adding an operation is creating an object with the right shape.

## Why operations as a frame

Authoring and playing collapse to "invoke operations you have caps for."

- Player caps grant `walk`, `look`, `say`, `take`, `give`, `put`.
- Author caps additionally grant `create_object`, `edit_property`, `retcon`, `flesh_out`.
- GM caps fall between, with custom configurations per world.

Every UI affordance — buttons, hotkeys, command palette entries, chat commands, forms, voice — is a view onto operations. The editor reads operation declarations and renders affordances; the substrate enforces cap checks at invocation.

The substrate does not know about "authoring" or "playing." It knows about operations and caps. Roles are emergent from cap distribution.

## Categories

### Pure-world ops (no oracle)

Deterministic effect on world state. Examples:

- `walk(direction)`, `look()`, `say(text)`, `take(object)`, `give(object, to)`, `put(object, into)`.
- `create_object(prototype, properties)`, `edit_property(target, key, value)`, `link_rooms(a, b, exit_name, reverse_exit_name)`.
- `move_to(target, location)`, `rename(target, new_name)`, `delete(target)`.
- `define_prototype(name, parent, fields)`, `define_interface(name, verbs)`, `define_handler(target, verb, source)`.
- `attach_handler(target, verb, source)`, `detach_handler(target, verb)`.

### Oracle-invoking ops

Wrap an oracle call into world effects. Examples:

- `flesh_out(target)` — given a sparsely-defined NPC/room, propose properties to fill in.
- `expand(target, dimension)` — describe `target` along `dimension` (history, motivations, look, smell).
- `propose_n(target, situation, n)` — generate n plausible responses/actions.
- `narrate(scene)` — render a scene to prose from current state and recent events.
- `describe_from_pov(scene, agent)` — render through an agent's beliefs, not ground truth.
- `generate_npc(prompt)` — extrude a full NPC object from a description.
- `extract_state_delta(prose, world)` — given prose narrating events, propose state changes.
- `suggest_handler(target, verb, intent)` — propose handler source for a given verb on a given object.
- `summarize_history(scope, since)` — generate a recap of events in scope since a time.

**Rule: every oracle op has a pure-code counterpart.** `flesh_out` has `clone_and_edit`. `narrate` has `template_render`. `generate_npc` has `instantiate_from_template`. Authors without oracle access never hit a wall. The oracle is an accelerator, never a gatekeeper.

### Belief ops

- `what_does_x_know(agent, topic)`, `update_belief(agent, diff)`, `propagate_perception(event)`.
- `theory_of_mind_diff(holder, target)`, `set_belief(agent, key, value)`, `reset_belief(agent, scope)`.
- `decay_beliefs(agent, age)`, `sync_belief_to_truth(agent, scope)`, `audit_beliefs(agent)`.
- `predict_action(agent, situation)`, `explain_action(agent, action)`.

### Meta-ops

- `fork(at_event_index)`, `replay_from(index)`, `diff_worlds(a, b)`, `undo(n)`.
- `checkpoint(label)`, `restore(label)`, `list_checkpoints()`, `delete_checkpoint(label)`.
- `merge_subworld(source, mount_point)`, `extract_subworld(scope) -> subworld`.

### Authoring ops (broader caps)

- `retcon(event_index, new_payload)` — rewrite a past event; downstream replay re-derives.
- `splice_event(at, event)` — insert an event in the past; downstream re-derives.
- `rebase_world(onto)` — apply local divergence on top of another world's timeline.
- `import_object(from, scope)`, `export_object(target, scope)`.
- `define_role(name, caps)`, `grant_cap(target, cap)`, `revoke_cap(target, cap)`, `attenuate(target, cap, restriction)`.
- `audit_caps(scope)`, `lint_world(checks)`.

## Oracle adapter

A single interface, multiple backends:

```lua
oracle: {
  ask: (prompt: Prompt) -> string,
  ask_structured: (prompt: Prompt, schema: Schema) -> any,
  rank: (prompt: Prompt, options: { string }) -> integer,
  embed: (text: string) -> { float },
}
```

Backends:

- **LLM backend** — wraps the crescent `llm` cap. Configurable model, sampling, system prompt template.
- **Code backend** — runs a Lua function. Used for deterministic ops, tests, fallback when no LLM.
- **Human backend** — routes the prompt to a user via HTTP and waits for response. Lets a human "be" an oracle. Useful for: a player playing an NPC, a GM filling in for the LLM, mixed human/AI casts.
- **Cached backend** — replays a previously-recorded oracle response. Used during event-log replay to maintain determinism.

Oracle backend is selected at op-invocation time. The same op can be invoked with different oracles, including from the same world. Caps mediate access — only some agents can route to the human-oracle channel.

Oracle calls are logged in the event log so replay can use the cached backend automatically. Forking past an oracle call may either reuse the cached response or re-invoke for genuine divergence; the fork op selects.

## Prompt construction discipline

Oracle prompts are not strings; they are values built from world state. Standard shape:

```lua
{
  task: string,                    -- what the oracle is being asked to produce
  context: { ContextSlice },       -- world-state slices: relevant objects, beliefs, history
  exemplars: { Exemplar },         -- few-shot examples of the desired output
  constraints: { Constraint },     -- output format, length, style
  output_schema: Schema,           -- for ask_structured
}
```

The substrate provides helpers for assembling context slices (object summaries, scene snapshots, belief slices, recent-event narratives). Operations that invoke oracles compose these helpers.

This is also where "fitting variety" lives. The discipline is: assemble prompts that constrain the *axes* the small model needs to vary on, then let sampling provide variety on the right axes. The prompt-construction layer is the practical answer to "why does a small model produce in-character output reliably."

## Cap-gated dispatch

When a user invokes an op, the substrate checks caps. Missing cap → op rejected with a useful error ("you need `edit_property` to retcon; only authors have this by default"). The editor surfaces only invokable ops in menus (UI-level filtering, for usability); the substrate enforces (security-level filtering, for correctness).

Caps are crescent caps. Distribution of caps is per-world configuration: a world declares which roles exist and which caps each role holds. Standard roles (player, author, GM) ship as templates; world authors can define custom roles.

## Composition

Operations call other operations. `flesh_out` may call `create_object` and `edit_property`. `retcon` may call `replay_from` and `splice_event`. Composability is what makes the catalog scale.

To prevent abuse: a called op runs with the calling op's caps, not the user's. So `flesh_out` can do whatever `flesh_out`'s manifest declares, regardless of who invoked it. Caps are attenuated, not amplified, by composition. A user without `edit_property` can still trigger `flesh_out` (which does call `edit_property` internally) if `flesh_out`'s cap manifest grants `edit_property` to itself — but `flesh_out` is then responsible for what it does.

## Catalog discipline

The operations library is documentation-as-product. Conventions:

- **Naming.** `verb_noun` for actions on a target (`flesh_out`, `edit_property`). `noun_verb` is reserved for queries (`scene_describe` etc.) — usually verb_noun is fine.
- **Parameter shape.** Structured records, never positional args past two.
- **Each op has** a docstring, at least one example (callable from the editor), at least one test.
- **Each op declares** its `effects_produced` precisely. The editor can show "this op may modify these properties."
- **Deprecated ops** stay listed with a "see X instead" note. World authors may depend on them.
- **Versioning.** Op signature changes are breaking. Use new op names for breaking changes; deprecate old.

## Buttons, hotkeys, forms, voice, CLI, scripts

All view layers on operations. The editor reads operation declarations and:

- **Forms** — renders a form per op (params → input widgets, generated from types).
- **Hotkeys** — generates a scheme (configurable per user, persists across sessions).
- **Command palette** — fuzzy search by name and description.
- **Voice** — maps templated grammars to ops.
- **CLI/REPL** — exposes with autocomplete (driven by params schema).
- **Scripts** — exposes as plain Lua functions in the substrate sandbox.

Adding an op makes it available across all view layers at once. No per-view registration.

## Sketch of what v0 ships

Roughly 50 ops covering:

- **~15 pure-world basics:** walk, look, say, take, give, put, edit_property, create_object, link_rooms, rename, delete, move_to, define_prototype, define_handler, attach_handler.
- **~10 oracle-invoking:** flesh_out, expand, propose_n, narrate, describe_from_pov, generate_npc, extract_state_delta, suggest_handler, summarize_history, transcribe_voice.
- **~10 belief:** what_does_x_know, update_belief, set_belief, reset_belief, sync_belief_to_truth, decay_beliefs, audit_beliefs, theory_of_mind_diff, predict_action, explain_action.
- **~15 meta + authoring:** fork, replay_from, diff_worlds, undo, checkpoint, restore, retcon, splice_event, merge_subworld, import_object, export_object, define_role, grant_cap, revoke_cap, lint_world.

Each is a few-to-tens of lines. The catalog grows from there based on what real worlds need. Operations contributed by world authors live in the world; operations broadly useful get promoted into the library.

## Where prompt-construction patterns live

Each oracle-invoking op embeds its prompt-construction logic. Common patterns (assembling persona context, scene context, belief slices, exemplar selection) live in shared helpers in the operations library.

A "prompt library" sub-doc may eventually be needed if the patterns grow complex. For v0, the helpers can be a single file with documented functions.
