# Roadmap — 2026-07-08

## Overarching: crescent as the entire computer

The general-purpose libraries compose into whatever you need, AND there are actual tools built from them that people reach for. People use tools, not libraries.

Ideas from other rhi projects (scribble, dusklight, etc.) lose their special names when imported — they become core ecosystem capabilities, libraries, and apps. The names are project shells; the ideas are what matter.

Capabilities are first-class across the entire ecosystem, not just lib/platform/. Libraries don't reach for globals — they receive what they need.

Tools should work 100% in the browser without needing a backend. lib/platform/ already serves UI through the browser; a service worker gives offline without a server.

## Priority 1: Scribble ideas → crescent

"A tool people just reach for to make art, interactive or not."

- The old scribble design doc (~/git/rhizone/scribble/docs/design.md) is a snapshot of past thinking and partially wrong. Don't cargo-cult primitives from it.
- The "editor" is just another platform app. Don't make libraries specifically for it — libraries should be generally useful.
- Inspiration: thi.ng/umbrella, afterbeat, Geometry Dash, JSAB, Roblox, S&Box, Garry's Mod, Chrome Music Lab, Dwitter — but don't tunnel-vision on just those.
- "Not special and not the only thing of its kind" — the same libraries that make a game editor also make a music tool, a dwitter-like, a Geometry Dash clone. If they can't, the libraries are too specific.
- What the right primitives are needs to be figured out fresh. Design pass needed.

## Priority 2: AI RP frontend

"SOTA AI RP frontend — non-conversational context."

- Present in `lib/platform/apps/charactercardv2/` (character card v2 app) with supporting adapter at `lib/platform/apps/sillytavern/`
- Sorely needs design
- There is almost certainly a previous session worth mining via `normalize sessions`
- Paused due to typechecker work

## Priority 3: Taskgraph

"Beyond SOTA agent harness by deleting the concept of an agent."

- Core so far: `lib/taskgraph/`
- The agent harness itself would probably be a platform app, pending design

## Parked: typechecker / verification engine

Findings from the toy checker sketch (docs/artifacts/2026-07-08-toy-checker-findings/notes.md):
- Mode proliferation: static modes are the wrong scheduling primitive
- The constraint structure is a graph, not a flat pool
- Edge direction through shared variables is dynamic — the open hard problem
- Parked, not abandoned. Resume with the graph-structure insight as the starting point.

## Dusklight ideas → crescent

Dusklight (~/git/rhizone/dusklight/) is a universal UI client for arbitrary data with a control plane. Like scribble, its ideas import into crescent — the project shell stays separate.

Key ideas to import:
- Pattern-first rendering (data shape → visualization)
- Reactive lenses (read/write, no asymmetry)
- Capability-based plugin architecture
- Control plane for arbitrary data

Design pass needed to figure out what the right crescent libraries are.

## Imported ideas (not yet placed as libraries)

From scribble:
- Append-only event log as canonical format
- Content-addressed assets
- Layer-based composition
- Live editor-runtime boundary dissolution

Marinada (~/git/rhizone/marinada/, extracted from dusklight) stays as its own thing — it's specifically designed (algebraic effects, linear types, specific reactive model), not a generic "the expr" for crescent. Where it would live relative to the crescent ecosystem (vendored dep? standalone tool? crescent-native port?) is an open question.
