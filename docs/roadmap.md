# Roadmap

Crescent's coverage of "the entire surface area of software" gets built by
dogfooding, not by mapping the space in advance. This document is the seed of
that plan — what the strategy is, why it's tractable, and what's still open.

## Strategy: real apps drive library coverage

Build real, useful example apps in the categories people most commonly need.
"Real" and "useful" are load-bearing — the apps should maximize actual
utility, products people want to use, not throwaway exercises kept alive only
to justify a library underneath. A demo app can be faked; a real one can't,
and it's the can't-fake property that does the work below.

Each app pays off twice:

1. **Forces libraries into existence.** Every gap hit while building the app
   — no HTTP client, no session storage, no whatever — becomes a library,
   because the app can't ship without it. This is how the roadmap for `lib/`
   gets generated: by contact with a real requirement, not by guessing what
   might be needed.
2. **Serves as a template that lowers the cost of building similar things.**
   The finished app isn't just a consumer of the libraries it forced into
   existence — it's a fork point. Someone who needs "that kind of app" forks
   the example and writes the correction terms specific to their case,
   instead of asking an AI to generate the whole thing (substrate, ceremony,
   and all) from scratch.

Both effects compound: better libraries make the next app cheaper to build,
and each app raises the floor for whatever gets forked from it next.

## Which apps

The "which apps" question is answered by three substrates, not by picking
from a list. Most apps in the same-substrate group — todo, notes, bookmarks,
contacts, habit tracker, CRM, recipe collection, and the like — are
configurations over these substrates, not separate products. This is the
thesis from `the-80-percent.md` made concrete. Which specific libraries to
build first, and the exact boundaries between the three substrates at the
library level, are still open.

## Three substrates

Three substrates emerge from existing rhi projects. Ideas import into
crescent as libraries; the project names don't follow.

1. **Capture substrate** (prior art: pad, `~/git/pad/`) — universal ingest.
   Anything in, structured, linked, searchable. Content-addressed,
   provenance-preserving, format-agnostic. pad is prior art to mine for
   design decisions, not a port target. pad is almost entirely ingestion —
   minimal UI surface.

2. **Display/control substrate** (prior art: dusklight,
   `~/git/rhizone/dusklight/`) — universal interface for external data.
   Format-agnostic rendering + control plane. Subsumes dedicated viewers
   (theoretically covers what wireshark, conky, and similar tools do). Key
   ideas to import: pattern-first rendering, reactive lenses,
   capability-based plugin architecture, control plane for arbitrary data.

3. **Creation substrate** (prior art: scribble, `~/git/rhizone/scribble/`) —
   universal composition for internal creation. Pluggable, extensible,
   composable. Can scale to zero (mspaint-level). Key ideas: append-only
   event log, content-addressed assets, layer-based composition, live
   editor-runtime dissolution. Scope is "near universal creation" — the
   creation primitives are general, domain-specific things (tiles, audio,
   GPU) are kernels that plug in.

Distinction between display and creation: dusklight is optimized for
external data (what exists elsewhere); scribble is optimized for internal
creation (what you're bringing into existence).

Library names for the imported ideas are not decided.

## Sequencing

Substrate before surface. The libraries underneath can be built now; UI
design for the actual interfaces people see is blocked on design time.
Ordered by immediate/broad usefulness to a layman: capture and display have
the broadest surface; creation is the most powerful but most optional for
most people.

## Relation to the Jevons thesis

This strategy is a direct instance of the substrate lever described in
[Jevons Paradox and Substrates](https://rhi.zone/essays/jevons-paradox-and-substrates):
an agent decomposes a task into subagents when the task "looks big," and what
makes it look big is usually encoding overhead, not the actual novel logic.
Libraries reduce that overhead for anyone building on crescent; the example
apps reduce it further by covering common use cases end-to-end, so the
starting point for a new app is a working one, not an empty one. No abstract
taxonomy of "software's surface area" is needed — the coverage hierarchy
emerges from use.
