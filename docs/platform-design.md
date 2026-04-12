# Platform Design

The crescent platform is a substrate for running sandboxed Lua scripts with explicit
capability grants. It is not LLM-specific, not character-card-specific, and has no
hardcoded knowledge of any external format (CCv2, charx, etc.). Format knowledge lives
entirely in scripts.

## Core model

An **app** is a gzipped tar archive containing a `manifest.json` and Lua source files.
It may be distributed as a raw `.tar.gz` or embedded in an image file (PNG, JPEG, WebP)
for the "distributable as an image" use case. The image is optional decoration.

The platform:
1. Loads an app (unpacks the tarball, parses the manifest)
2. Selects the appropriate entrypoint for the current host
3. Decides which capabilities to grant (operator approves declared caps)
4. Runs the entrypoint in a sandbox (`lib/sandbox`) with those capabilities

The platform has no opinion about what the script does. The script is the program.

## Capability surface

Capabilities are plain Lua tables passed to the sandbox. The platform owns the
implementations; the script receives exactly what it's granted.

```lua
-- example grant for a CCv2-style card
sandbox.run(script, sandbox.env(
  sandbox.stdlib,
  { globals = {
    png    = png_cap({ allow = {"chara", "crescent"} }),
    llm    = llm_cap(model_config),
    render = render_cap(session),
  }}
))
```

### `caps.png` — chunk access

Read and write tEXt chunks in the card's PNG file by name.

```lua
caps.png.text(name)           -- read chunk, returns string | nil
caps.png.set_text(name, val)  -- write chunk
```

The `png_cap` constructor accepts an optional allowlist:

```lua
png_cap({ allow = {"chara", "crescent"} })  -- only these chunks accessible
png_cap()                                    -- unrestricted (trusted scripts only)
```

Denied chunk access errors immediately, same as sandbox's require whitelist.
All format parsing (JSON, base64, etc.) is the script's responsibility. The platform
never interprets chunk contents.

### `caps.llm` — LLM oracle

A stateless function call. The LLM is not a participant; it is a tool.

```lua
local response = caps.llm.call(messages)  -- messages: array of {role, content}
```

Model selection, API keys, and retry logic are the capability implementation's concern.
The script assembles the messages array however it wants.

### `caps.render` — UI surface

Push content to the render surface. The render surface is defined by the host
(HTTP + reactive UI); the script pushes structured or plain content to it.

```lua
caps.render.push(content)
```

### `caps.fs` (optional) — file access

Granted only to explicitly trusted scripts. Scoped to a directory.

## Script / data separation

The script and data chunks are strictly independent:

- **Script**: pure logic. Never written by the editor, never modified by tooling.
  Reads its inputs through capabilities. The same script can run against different
  data — useful for multi-character scenarios or persona swaps.

- **Data**: content and configuration. Owned entirely by the editor. The script
  reads data through `caps.png.text("data")` (or whatever chunk it declares).

This means editors never do writeback into script source. Diffs stay clean.
Users keep their edits. Tooling that modifies script text is explicitly out of scope.

## Format agnosticism

The platform has zero knowledge of CCv2, charx, or any other card format. A script
that reads CCv2 data does so itself:

```lua
-- CCv2 knowledge lives here, in the script — not in the platform
local raw      = caps.png.text("chara")          -- CCv2 stores data in "chara" chunk
local ccv2     = json.decode(base64.decode(raw))
local name     = ccv2.data.name
local persona  = ccv2.data.description
```

CCv2 import is therefore free: the CCv2 card editor is a script that knows how to
read the `chara` chunk. The platform just provides chunk access.

The data capability is the abstraction layer. CCv2 fields are one implementation.
Crescent structured data is another. The script sees one API either way — whatever
the capability implementation returns from `caps.png.text(name)`.

## First-party applications

The platform ships two first-class editor applications as preset scripts:

### CCv2 card editor

A rich-text editor for CCv2 character cards. Reads and writes the `chara` tEXt chunk
(base64-encoded JSON). Stores additional structured data in a `crescent` extension
chunk for round-trip fidelity.

- Rich text editing of CCv2 fields (description, personality, scenario, etc.)
- `{{char}}`, `{{user}}` macros render as live inline components; cursor entry expands
  to raw macro text for editing; toggle between raw and resolved modes
- Macro replacement is the editor view — no separate preview pane
- Extension field: structured sub-blocks (sections within personality, etc.) stored in
  `extensions.crescent`, flattened to plain text for CCv2 export, reconstructed on
  re-open

### CCv2 lorebook editor

Purpose-built for CCv2 lorebook structure. Hard-optimized for CCv2's exact shape —
keyword lists, case sensitivity, scan depth, probability, priority, insertion position.
No Lua anywhere. Familiar to existing SillyTavern users, better UI.

Crescent-native context construction is arbitrary script logic, not a lorebook concept.
There is no "crescent lorebook editor" — scripts that need dynamic context injection
write it in code.

## Preset library

A preset is a starter script you copy into a card and edit. The script is
data-driven — config tables near the top, behavior derived from them below — so
customization means editing data, not restructuring code.

Presets are `.lua` files with metadata. No runtime machinery: the platform browses
the preset library, the user picks one, it drops into the card's script chunk.
Users fork presets freely; the platform has no opinion about what they do next.

## Saved state pattern

Not a library — a pattern that platform scripts implement on top of SQLite.

The core idea: every meaningful state the platform can render is addressable and
returnable. A card interaction session, the card library viewer, a specific branch in a
chat tree, a world state snapshot — all are saved states you can return to. There is no
distinction between "current app" and "saved state." The current session is itself a
saved state; reboot restores it automatically.

**Implementation.** A saved state is a SQLite row: a state reference (enough to
reconstruct the view) plus open metadata. No fixed schema — each script decides what
metadata makes sense. Tags, summaries, preview images, timestamps, relationships to
other states — all just columns or a JSON blob. Organisation is queries, not folders.

**Everything navigable is a saved state.** The card library viewer script, the card
editor, an interaction session, a chat tree branch — navigating between them is
selecting a saved state. The platform's navigation model IS this pattern; there is no
separate concept of "which app is open."

**When building the full app:** implement as a `saved_states` SQLite table with a
`state_ref` column (JSON, script-defined schema), a `metadata` column (open JSON), and
whatever indexed columns are needed for fast queries (type, created_at, tags). The
current session row is always present and updated on every navigation. On reboot, load
the most recent row and resume.

## Self-contained apps

The crescent app format is a **gzipped tar archive** containing a `manifest.json` and
arbitrary Lua files, shared libraries, and assets. The image wrapper is optional — the
core format is just the tarball.

**Distribution formats** — the platform accepts all of these:

```
myapp.tar.gz              — raw tarball, no image wrapper
myapp.png                 — PNG with lua iTXt chunk: base64(gzip(tar))
myapp.jpg / myapp.webp    — JPEG/WebP with XMP metadata: same base64(gzip(tar))
```

For image-embedded apps, the `lua` metadata key contains `base64(gzip(tar))`, following
the same convention as CCv2 (`chara` is base64-encoded JSON). The image is decoration —
the app is the tarball. gzip compression more than offsets the base64 overhead for Lua
source.

```
myapp.png
├── chara   (tEXt — base64 JSON, CCv2 format, untouched — if this app is also a CCv2 card)
└── lua     (iTXt — base64(gzip(tar)))
    ├── manifest.json
    ├── (arbitrary .lua files and assets)
    └── ...
```

### Manifest

`manifest.json` declares the app's entrypoints, capability requirements, and metadata.
JSON so that external tools (`exiftool`, `tar`, `jq`) can inspect apps without a Lua
runtime.

```json
{
  "name": "My Character",
  "version": "1.0.0",
  "caps": {
    "db": "required"
  },
  "entry": {
    "dom": {
      "main": "ui/dom.lua",
      "caps": {
        "llm_main":    { "type": "llm", "required": true },
        "llm_summary": { "type": "llm", "required": false },
        "render":      { "type": "render", "required": true }
      }
    },
    "mcp": {
      "main": "mcp/main.lua",
      "caps": {
        "llm": { "type": "llm", "required": true }
      }
    },
    "headless": {
      "main": "run/batch.lua",
      "caps": {
        "llm": { "type": "llm", "required": true },
        "fs":  { "type": "fs",  "required": false }
      }
    }
  }
}
```

**Capability declarations:**

- Top-level `caps` declares caps shared across all entrypoints (e.g. `db` above).
- Per-entrypoint `caps` declares additional caps specific to that entrypoint.
- Each cap has a `type` (the capability kind the host must provide) and `required`
  (if `false`, the cap may be absent — the script receives `nil` for that slot and
  must handle it).
- Cap names are the keys the script uses to access them (e.g. `caps.llm_main`).
  Multiple caps of the same type are supported — names disambiguate them.

**Capability protocol:**

Caps are plain Lua tables. The format makes no assumption about reactivity. If a host
wants to support live cap swapping without restarting the entrypoint (e.g. switching
which LLM backend is active), it may wrap caps in signals and pass a signal-aware env
— but this is a host/script agreement. Scripts that don't need live swapping use caps
as plain values.

Entrypoint keys are conventions the host understands; unrecognised keys are ignored.
An app need not implement all entrypoints — it declares only what it supports.

The host reads the manifest, selects the entrypoint it needs, grants the declared caps
(prompting the operator for approval if needed), and runs the entrypoint sandboxed.
Shared code between entrypoints is just files in the tarball — `require` resolves
against the tarball root via a custom loader injected into `package.loaders`.

Sharing a card shares the exact scripts that produced it. No separate install step;
the card is the complete application.

The platform can optionally upgrade embedded scripts to a newer version, but the
upgrade logic is itself a script — the platform does not hardcode any migration policy.

## Everything else is scripts

The platform is not a card management platform, an import pipeline, or a library
browser. Those are scripts that ship as first-party defaults:

| What it feels like | What it actually is |
|---|---|
| Card library / search UI | Script with `caps.fs` + `caps.render` |
| CCv2 import pipeline | Script with `caps.fs` + `caps.png` |
| Mutate-on-import logic | Script (stamps editor chunks into imported card) |
| Card editor | `editor` entrypoint in each card's tarball |
| Lorebook editor | `lorebook_editor` entrypoint in each card's tarball |
| Preset browser | Script with `caps.fs` |

These ship alongside the platform as first-party scripts. They are not platform code.
They are replaceable, forkable, and auditable — and distributed the same way as any
other card.

The platform owns exactly two things:
1. Run a script with the capabilities the host decides to grant
2. Provide a render surface

Everything else is user-land.

## What the platform does not own

- **World state model**: the script chooses its storage. If it wants SQLite it requests
  `caps.db`. If it wants in-memory tables it uses them. The platform provides
  capability implementations for common backends; scripts pick what they need.
- **Context construction**: always the script's job. No built-in prompt assembly.
- **Conversation history**: the script decides whether to accumulate, how much to keep,
  and how to structure it. Accumulation is a choice, not a default.
- **Any external format**: CCv2, charx, TOML, YAML — all parsed by scripts.
- **Card management**: no built-in library, search, tagging, or import UI. These are
  scripts with filesystem capabilities.
- **Migration policy**: upgrade logic for embedded editor scripts is a script, not a
  platform concern.
