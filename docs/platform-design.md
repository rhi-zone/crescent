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

## What the platform does not own

- **World state model**: the script chooses its storage. If it wants SQLite it requests
  `caps.db`. If it wants in-memory tables it uses them. The platform provides
  capability implementations for common backends; scripts pick what they need.
- **Context construction**: always the script's job. No built-in prompt assembly.
- **Conversation history**: the script decides whether to accumulate, how much to keep,
  and how to structure it. Accumulation is a choice, not a default.
- **Any external format**: CCv2, charx, TOML, YAML — all parsed by scripts.
