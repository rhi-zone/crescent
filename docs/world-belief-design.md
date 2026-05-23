# Belief Layer Design

A library over the substrate that models what each agent perceives and believes. The substrate handles ground truth; the belief layer handles partial, possibly-wrong, possibly-nested knowledge.

## Why a separate layer

The substrate stores objective world state. Many worlds need subjective state per character — Alice knows the door is locked; Bob doesn't; Charlie believes incorrectly that Bob knows. The substrate could lump this in, but it would lose generality: a city-builder world doesn't need theory of mind; an IF puzzle might need only perception filtering; an RP scene with deception needs the full stack.

Keeping belief a separate library means worlds opt in. Worlds that don't use it pay no cost.

## Two sublayers

### Perception (substrate-supported)

Events in the substrate's log carry visibility metadata: `visible_to: Query`. The substrate's log-query API filters events by recipient ref. "Events Alice can see" is `query(log, { visible_to_contains: alice_ref })`.

Perception is *literal*. It is what an agent's senses register: did they hear the conversation, see the door open, were they in the room when the bomb dropped. Decidable from world state, no inference needed.

Perception is *not* knowledge: an agent perceives an event but their interpretation of it is belief.

Authors of handlers set `visible_to` on each event they produce. Common patterns: visible to everyone in the same room, visible only to the actor, visible to everyone with line-of-sight, visible based on a custom predicate. The substrate doesn't impose a spatial model — `visible_to` is just a query.

### Belief (library)

Each agent that wants beliefs has a `beliefs` object — itself a substrate object, owned by the agent, holding the agent's model of the world.

`beliefs` mirrors the structure of the world: rooms-the-agent-knows-about, objects-they-know-about, other-agents-they-know-about. Each known thing has *believed properties* which may diverge from truth.

`beliefs` updates from perception events via a per-agent `update_belief` handler. This handler decides what to do with each perception:

- Pure-code agents: rule-based update (e.g., "I saw the key go into the chest, so I believe the key is in the chest").
- LLM agents: invoke an oracle (`update_belief_from_prose`) to interpret narration and propose belief diffs.
- Mixed: rules for structured perceptions (movement, item transfer), oracle for narration-shaped perceptions.

### Theory of mind

`beliefs` may contain a `beliefs_about: { [Ref<Agent>]: BeliefsObject }` — Alice's beliefs about what Bob believes. Recursive: Alice's beliefs about Bob's beliefs about Charlie's beliefs.

Each level is just another `beliefs` object. No new machinery. Cost is borne only by worlds that use it; most won't go past depth 2 (you can think about what someone else thinks; thinking about what someone else thinks you think is the practical ceiling).

Updates to nested beliefs come from perceptions involving the target agent: "Alice saw Bob walk in" updates Alice's beliefs *and* may update Alice's model of what-Bob-knows ("Bob now knows where I am, because he saw me here").

## Representation choice

Options considered:

- **Graph (mirror).** Each known thing is an object with believed properties. Same shape as ground truth. Cheap queries; expensive storage; clean semantics. Theory of mind composes by nesting.
- **Constraint set.** "Alice believes: X, ¬Y, P(Z)=0.4." Precise; supports probabilistic reasoning; awkward for prose generation; needs a constraint solver.
- **Prose blob.** A textual description the LLM reads. Cheap to store; impossible to query precisely; drifts.
- **Hybrid: graph-shaped containers, prose-or-data contents.** Each known object has structured slots for the things you want to query (`knows_location_of_key: true`) and prose-shaped slots for the things you want to narrate (`memory_of_encounter: "humiliating; she wouldn't meet my eyes"`). Best of both; demands taste.

Recommend the hybrid. Structure where queryability matters; prose where nuance matters. The split is per-property, decided by the author. Belief schemas are author-defined and may extend over a world's lifetime.

## Update mechanism

A perception event arrives at an agent. The agent's `update_belief` handler fires.

For pure-code agents, the handler is a rule set:

```lua
-- on perception(walk, alice, bedroom):
--   set my_beliefs.location_of[alice] = bedroom
```

For LLM agents, the handler invokes an oracle:

```lua
-- ask oracle:
--   perceived: <structured event>
--   my current beliefs about this topic: <slice>
--   my disposition and persona: <character notes>
--   output: list of belief diffs (set/unset/update)
```

The oracle returns proposed diffs. The handler validates them against the agent's belief schema (rejects diffs touching fields the agent shouldn't have access to, or with wrong types) and applies the survivors. Invalid diffs are logged for later inspection.

Belief updates are themselves substrate events on the `beliefs` object. So the substrate's event log captures the entire belief history, supporting "Alice used to think X" narration and replay.

## Divergence management

Over hundreds of turns, beliefs drift. Mechanisms to keep them sane:

- **Periodic re-sync** for properties that should match truth when an agent has direct perception. "Alice has been in this room for 10 turns; refresh her beliefs about the room's visible contents from ground truth." Op: `sync_belief_to_truth(agent, scope)`.
- **Belief lifetime / decay.** Old beliefs can be marked stale, prompting the agent to verify before relying. Op: `decay_beliefs(agent, age)`.
- **Explicit author override.** The author can directly correct an agent's beliefs at any time. Op: `set_belief(agent, key, value)`. Useful for setup, recovery, and forcing scenes.
- **Belief-vs-truth diff queries.** Author tooling surfaces every agent's divergence from truth, ranked by impact. Op: `audit_beliefs(agent)`.

The author is the final arbiter. Drift that the author wants kept (Alice misremembers; Charlie holds a false conviction) is preserved; drift that's a mistake gets corrected.

## Multi-agent example

Scene: Alice tells Bob the door is locked. Charlie overhears.

Substrate events:
- `say(alice, "the door is locked")`, `visible_to`: anyone in the room (Alice, Bob, Charlie).

Belief updates fire on each perceiver:
- Alice's handler: no change (Alice already believed this — she said it).
- Bob's handler: now believes door is locked (or: now believes Alice claims door is locked, depending on rule).
- Charlie's handler: now believes door is locked.

If Alice's beliefs include `beliefs_about[bob]`, her handler may also update *her model of Bob*: "Bob now knows the door is locked (because he heard me)." If she's a deceiver, this is the lever for her plans.

If Charlie's beliefs include `beliefs_about[alice]`, his handler may update: "Alice apparently believes the door is locked." Whether Charlie believes Alice — vs believes Alice is lying — depends on his rules / persona.

This is straightforward to model in the library; the hard part is keeping update rules consistent and interesting, not the data structure.

## Open research

- **Prose-to-belief-diff reliability.** The LLM-driven update handler is the hardest piece. Small models hallucinate diffs; large models are slow. Likely needs structured-output techniques (JSON-schema-constrained generation, function-call APIs) and per-character fine-tuning of the update prompt. Anchor target: a Gemma-class model producing valid diffs ≥95% of the time on a curated test set.
- **Theory-of-mind cost.** Maintaining Alice's model of Bob's model of Charlie's beliefs is expensive in both storage and oracle-call count. Probably needs to be *lazy* (computed on demand when asked "what does Alice think Bob thinks?") and *shallow* by default (depth 2 unless explicitly opted in). The substrate's event log supports lazy reconstruction.
- **Belief versioning and history.** When does an old belief get archived vs overwritten? Useful for "Alice used to think X, now thinks Y" narration. The substrate's event log already provides this if belief updates are events; the convention is "always overwrite the current state; the log is the history."
- **Belief schemas as evolving artifacts.** A world's belief schema may extend mid-play (new properties, new categories). Schema migration for beliefs follows the same pattern as substrate prototype evolution — old instances get migrated when their schema is updated, with author-supplied default values.

## Substrate touch points

The belief layer needs from the substrate:

- Event log with visibility metadata (substrate provides).
- Object spawn for `beliefs` objects (substrate provides).
- Oracle adapter for LLM-driven updates (operations library provides).
- Capability gating: an agent's beliefs are owned by the agent; only the agent's handlers (and authors with cap) can mutate them. (Substrate refs + attenuation provide.)

No substrate extension needed. Belief is a pattern of substrate use.

## What ships in v0

- `beliefs` object prototype with hybrid (graph + prose) representation.
- Per-agent `update_belief` handler hook with both rule-based and oracle-based variants.
- Theory of mind support (lazy, depth-limited).
- Standard belief ops: `what_does_x_know`, `update_belief`, `set_belief`, `sync_belief_to_truth`, `decay_beliefs`, `audit_beliefs`, `theory_of_mind_diff`.
- Documentation with worked examples (single-agent, multi-agent, theory-of-mind, deception).

What v0 punts on:

- Probabilistic belief (P(X) = 0.3 style). Bool-or-prose only; add later if needed.
- Cross-world belief (Alice in world A knows about world B). Out of scope.
- Automated consistency repair (the author has to notice and fix). Could be tooled later.
