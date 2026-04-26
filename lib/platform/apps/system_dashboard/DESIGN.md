# system_dashboard

A system configuration and navigation app. The answer to "how do I configure X" without setup, documentation hunting, or knowing where to look.

## Motivation

The gap this fills: every OS has configuration scattered across settings panels, registries, config files, command-line flags, and buried menus. Finding the right place requires knowledge the user doesn't have yet. "How do I enable focus-follows-mouse on Windows" is a question with an answer — the answer just requires knowing where to look.

The goal is zero setup to reach any system configuration. You open the dashboard, you find the thing, you change it. No prior knowledge required.

## Core: Command Palette

The primary interface is a command palette. Two retrieval modes:

**Fuzzy search** — manually curated aliases. Each alias maps a human description to a concrete system action (registry key, config file path, command, etc.). Fast, deterministic, works offline.

**RAG retrieval** (optional, when opened) — for queries that don't match a known alias. Searches a local index of documentation, Stack Overflow answers, system documentation. Slower but covers the long tail.

The palette is the answer to "I don't know what this is called." You describe what you want in plain language; the palette finds it.

## Alias Packs

Aliases are the genome-free part. No central canonical list — users create their own alias packs for their OS, jurisdiction, language, setup. Each pack is a small data file mapping descriptions to actions.

Packs are:
- Shareable as plain files or embedded in the standard app PNG format
- Pullable directly from git repos (`crescent run github:user/my-aliases`)
- Composable — you layer multiple packs, local overrides win

Virality: you solve "how do I do X" for yourself, you share your alias pack, everyone with the same problem has the solution. No blog post required — just the working, runnable pack.

**Security**: alias packs declare exactly which caps they need. A pack that modifies registry keys requires `registry` cap with explicit path scoping. The user sees exactly what will be touched before anything runs. Malicious packs can't operate outside their declared scope.

## `registry` Cap (new, Windows-only)

Pattern follows existing caps (`fs`, `db`):

```
opts.root        : (required) registry path prefix, e.g. "HKCU\\Control Panel"
opts.allow_write : boolean, default false
```

All key paths are relative to `opts.root`. Traversal outside root is blocked. Multiple named `registry` caps can be declared for different root paths — granularity comes from declaring the right scope, not from a single broad cap.

This is consistent with `fs`: scoped to a root, read-only by default, write opt-in.

## Cap Consistency Audit

All caps should follow the same pattern for read/write access. Current state:

- `fs` — `opts.allow_write: boolean` ✓
- `db` — `opts.readonly: boolean` (inverted naming vs `fs` — worth normalizing to `allow_write`)
- `registry` (new) — `opts.allow_write: boolean` (follow `fs` convention)
- `http_client` — read/write not applicable (requests are always both)
- `kv` — no read/write distinction currently

Naming convention to standardize: `allow_write: boolean, default false`. Opt-in to write, never opt-in to read. `db.readonly` should be aliased or migrated to `allow_write` for consistency.

## Scope

Intentionally unbounded. The dashboard covers whatever system configuration exists. No feature is "out of scope" — if a person needs to configure something to function, the dashboard should eventually reach it.

Alias packs are how the scope grows without the core growing: each pack adds coverage for its domain. The core stays small; the ecosystem does the rest.

## Distribution

Standard platform app: `.tar.gz` or PNG-embedded. Ships with a minimal default alias pack. Users add more packs as needed. Forkable — your fork is your alias pack plus whatever customization you want.

## Non-goals

- Not a general file manager (that's a different app)
- Not a terminal emulator
- Not a settings UI for crescent itself (that's the admin app)
- Not a replacement for OS-native tooling — a surface over it
