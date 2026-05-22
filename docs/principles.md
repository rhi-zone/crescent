# Principles

The ecosystem's north star, beneath the architectural rules in `CLAUDE.md` and
the scope in `batteries.md`.

## Make the computer small

The whole machine should be knowable end-to-end. Not "small codebase" — small as
a thing a person holds in their head. No hidden surface area, no capabilities
that only exist if you happen to read the right forum post.

A user who sits down with crescent and never opens a browser should be able to
reach every capability the system offers.

## Make interactive anything small

The same bar applies to artifacts built *with* crescent. A game, a document, a
tool, a toy — if it is interactive, it should be legible to its user without
external scaffolding. Crescent libraries exist to make this achievable; an
authoring tool in crescent that produces opaque artifacts has betrayed the
principle.

## Discoverability is in the tool, not in tutorials

A tool whose use requires external tutorials has failed. Affordances over
appendices. The help guide, even when shipped (CHMs, man pages), was always an
afterthought — the actual learning path lived in books, videos, Discord
servers. That is the regression to fix, not to recreate.

The tool itself teaches what it can do as the user uses it. Reference material
ships with the binary, but reference material is the floor, not the ceiling.

## No online resources in the loop

Not for install. Not for help. Not for learning. Not for activation, telemetry,
license check, "first-run experience," or any other euphemism. A bare clone on
an air-gapped machine is the supported configuration, for the tool and for
everything built with it.

Even Microsoft Word — the universal example of usable software — now points F1
at a server by default. The industry has decided the internet is part of the
install. Crescent disagrees.
