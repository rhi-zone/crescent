# Shell Design

> **Status: early sketch.** The library view shape is roughed out but not fully
> specced — adapter API, facet composition rules, grid/list item design, and
> keyboard navigation all need a dedicated design pass before implementation.
> The card app design takes priority.

The shell is a first-party crescent app (tarball format, same as any card) that
browses and launches other apps. It is not part of the platform — it's replaceable
and forkable like any other app.

## Library view

The primary screen. Full viewport — no sidebars, no panels competing for space.

**Search bar** — always visible, always the entry point. Searches across all metadata
fields exposed by the source adapter. Matched fields surface as pinnable facets —
click to lock a filter, click again to remove. One search bar for both views; the
view toggle doesn't reset it.

**View toggle** — grid ↔ list. Button in the toolbar + keyboard shortcut (e.g. `v`).

### Grid view

Character portrait + title + tagline + tags. Last-opened indicator (subtle — e.g.
a dot or timestamp) for cards you've interacted with. Description on hover/expand,
not always visible — too much text at grid scale.

### List view

Denser. Same fields but laid out horizontally — portrait thumbnail, title, tagline,
tags, last-opened. Keyboard-navigable: arrow keys move selection, Enter launches.

## Projectional filter editor

The search bar produces a `Signal<Query>` — a structured value built from the text
input + pinned facets. Results are `computed(() => caps.db.query(to_sql(query.get())))`.
Reactive and instant. The shell holds a read-only `caps.db` handle to the platform
metadata db.

Facets are any metadata field — not just tags. Pinned facets compose with AND;
within a facet, multiple values compose with OR.

**Metadata schema is open and author-defined.** Each card has a metadata object
in its manifest with whatever key-value pairs the author chooses: `hair.color`,
`species`, `setting`, `tags`, `rating`, etc. No fixed schema. The projectional
search indexes whatever is there. Tags are just one conventional field — not
special, not required. Cards imported from chub/itch carry their source tags in
this object automatically via the adapter.

## Navigation

From the library, launching a card opens its `dom` entrypoint. The shell has no
knowledge of what the card shows — it just launches `dom` and the card handles its
own routing (conversation, editor, settings, etc.).

Back navigation returns to the library at the same scroll position and filter state
(persisted in `caps.kv`).

## User settings

Accessible from the shell (not from within cards). Covers: LLM backend configuration,
theme, global presets, global lorebooks, user account (multi-user host). Implemented
as an internal view of the shell app, not a separate entrypoint.
