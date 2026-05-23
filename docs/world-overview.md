# World Substrate Overview

A genre-neutral substrate for building worlds — narrative games, interactive fiction, RP environments, social sims, narrative essays, anything where persistent state, characters, and reactive behavior matter. Built as a library plus platform apps on crescent.

## What this is, and isn't

It is: a small core (objects with properties, messages with handlers, structured effects, an event log) plus libraries that compose into authoring tools, runtime worlds, and end-user experiences. The core is MOO-shaped (LambdaMOO, 1990) — a design pattern that has held up for 36 years and is not the interesting part.

It is not: a game engine with opinionated primitives (RPGM, Ren'Py). It is not a wrapper around an LLM. It is not a "platform" in the SaaS sense.

## Pieces

1. **Substrate** (`world-substrate-design.md`) — objects, messages, handlers, effects, event log, fork, capability refs. Pure Lua, leans on the crescent typechecker.
2. **Belief layer** (`world-belief-design.md`) — per-object beliefs, perception filtering, theory of mind. Library over substrate.
3. **Operations library** (`world-operations-design.md`) — the catalog of named operations that act on world state. Pure-code and oracle-invoking ops, cap-gated.
4. **Editor** (`world-editor-design.md`) — direct-manipulation editing of running worlds, schema-aware forms, code/form round-trip, REPL. The editor is itself a platform app.

## Anchoring stances

**LLM as oracle, not agent.** An LLM is a single-shot function `prompt -> text`. It has no memory, no identity, no agency. Continuity, identity, memory all live in the world (objects). A handler that needs a string asks an oracle the same way it might roll a die or call a database — as an effect. There is no "AI character"; there is a character object whose handler invokes an oracle when it needs to generate a line.

**Operations, not workflows.** Authoring and playing are not separate modes. Both are "act on the world via operations you have caps for." A player has caps to walk, talk, take. An author has caps to create rooms, edit handlers, retcon events. Same substrate, same operations, different cap set. The same operation library serves both.

**Non-oracle authoring is best-in-class on its own.** Every operation that uses an oracle has a manual counterpart. The product offline-with-no-LLM is complete, by the standards of Inform 7 / NWN Aurora / Blender. Oracle ops are accelerators, not substitutes.

**Genre-neutral primitives.** The substrate knows about objects and messages. It does not know about HP, dialogue, rooms, NPCs, or quests. Those are patterns built on top, and any pattern that isn't broadly useful does not belong in the substrate.

**Composition, not configuration.** There is no "RP mode" vs "sim mode" switch. There are primitives that compose into programs. RP is one program. A city-builder is another. A narrative essay is another. The substrate does not anticipate use cases.

## What's novel, what isn't

Not novel: the substrate model itself (MOO, 1990; defocus, today). BDI agents (Bratman, 1987) for the belief layer. Strategy pattern for oracle adapters. Sandboxed app distribution (NWN modules, 2002). Capability security (Hydra/KeyKOS, 1970s; E language, 1990s). Event sourcing.

Plausibly novel at the level of integration, not invention:
- Statically-typed substrate (crescent's typechecker including effect tracking) over a MOO-shaped core. Inform 7 is typed-ish but genre-locked; NWN is genre-neutral but untyped. Both at once is unusual.
- Editor and runtime as one app: edit the running world directly; forms generated from types; code and form are projections of one artifact.
- "LLM as oracle, never as agent" as a load-bearing design rule rather than a slogan.

The contribution, if any, is integration discipline. None of the pieces are research.

## Layering on crescent

The substrate runs as a Lua library inside a crescent platform app. A "world" is a platform app: manifest, entry point, caps requested (`db` for persistence, `llm` if oracles are used, `http_server` if there's a frontend, etc.). The app boots, loads its substrate state from `db`, exposes a frontend if configured, and runs the world loop. Distribution, sandboxing, capability enforcement, multi-user routing — all provided by crescent.

The editor is *also* a crescent app. It connects to a world (its own, or — if caps allow — another's). The editor uses the same substrate library as the world it edits. No special-casing.

Multi-world is multi-app: separate worlds are separate apps, daemon routes between them. Cross-world object refs are deferred; not needed for v1.

## Scope reality

- Substrate library v0: weeks.
- Belief library v0: weeks. Open research at the prose-update edge.
- Operations library v0 (50ish ops): weeks to months. Open-ended growth thereafter.
- Editor v0 (the bar that makes the product feel premium): months. The longest single piece of work.
- Cross-app transport: deferred.

A usable single-author single-player v1 in 3–6 months of focused work. "Best-in-class" status is a 1–2 year horizon. Nothing is architecturally blocked; the time is in volume, polish, and the editor specifically.

## Why crescent

- **Capability sandbox** — worlds load untrusted character packs, world definitions, handlers without compromising the host.
- **Caps as the only I/O channel** — natural fit for substrate refs (rows of allowed methods, revocable, attenuable).
- **Daemon multiplexes apps** — worlds are apps; distribution and routing are free.
- **Persistence (`db`, `kv`, `self_write`)** — substrate state lives in cap-scoped storage.
- **`llm` cap** — oracle is a first-class capability, not a bolt-on.
- **Typechecker** — substrate primitives express as row types, match types, and effect rows without typechecker extension.
- **Zero external dependencies** — the entire stack ships in one tree.

## Why not novel research

The conversation that produced these docs surveyed the prior art (MOO/LambdaMOO, BDI agents, NWN modules, E language, Inform 7, RPGM/Ren'Py failure modes) and concluded the substrate, belief model, oracle adapter, and app distribution are all well-trodden individually. The work is integration — picking the right pieces, gluing them with discipline, and not letting an opinionated product sneak in underneath. That integration produces something whose feel is genuinely fresh because most contemporary attempts make different (worse) choices.

The pieces that are arguably open research live in the belief layer (prose-to-belief-diff reliability with small models) and in operations (oracle prompt construction discipline). Both are tractable engineering, not theory gaps.
