# Platform Design

The crescent platform is a substrate for running sandboxed Lua scripts with explicit
capability grants. It is not LLM-specific, not character-card-specific, and has no
hardcoded knowledge of any external format (CCv2, charx, etc.). Format knowledge lives
entirely in scripts.

## Core model

A **card** is a PNG file containing:
- An image (the visual representation / avatar)
- A `script` tEXt chunk — pure Lua logic, never modified by tooling
- A `data` tEXt chunk — structured content, owned by the editor
- Any other tEXt chunks the script declares it needs

The platform:
1. Loads a card (reads PNG chunks via `lib/png`)
2. Decides which capabilities to grant the script
3. Runs the script in a sandbox (`lib/sandbox`) with those capabilities
4. Provides the render surface (HTTP server + reactive UI)

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

## Bookmarks

Bookmarks are a first-class platform primitive — not an afterthought. Every meaningful
state the platform can render is addressable and returnable: a card interaction session,
the card library viewer, the lorebook editor, a specific branch in a chat tree, a world
state snapshot. There is no distinction between "current app" and "saved state."

The current session is itself a bookmark. Reboot restores it automatically.

**Open metadata.** A bookmark carries arbitrary user-defined metadata — tags, summaries,
preview images, timestamps, relationships to other bookmarks, custom fields. Tags are
one type of metadata. Relations are another. There is no fixed schema; each bookmark
carries what makes sense for it. Organisation (filtering, grouping, searching) is
queries over metadata — not folders, not a fixed hierarchy.

**Everything is a bookmark.** The card library viewer is a script — it is also a
bookmark. Switching from editing a card to running it is navigating between bookmarks.
The platform's navigation model is the bookmark system; there is no separate concept
of "which app is open."

## Self-contained cards

Every CCv2-compatible card imported by the platform has the editor scripts embedded
directly in it as zTXt chunks:

```
card.png
├── chara                    (original CCv2 JSON, untouched)
├── crescent:data            (structured data layer)
├── crescent:ui              (interaction loop)
├── crescent:editor          (card editor)
└── crescent:lorebook_editor (lorebook editor)
```

The platform loads whichever chunk the user invokes — run mode uses `crescent:ui`,
edit mode uses `crescent:editor`. Same file, same capabilities, different entry point.

Sharing a card shares the exact editor version that produced it. No separate editor
install step; the card is the complete application.

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
| Card editor | Script embedded in each card |
| Lorebook editor | Script embedded in each card |
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
