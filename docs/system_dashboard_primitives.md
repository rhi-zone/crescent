# system_dashboard primitives

Cross-reference: [`system_dashboard.md`](system_dashboard.md) for the dashboard's identity and pack format. This doc defines the *render shapes* packs may return.

## Goal

Pack actions today return strings. Strings are a floor — not a ceiling. To match the prior art (Postman, btop, Grafana, Home Assistant, Raycast, Pi-hole, Synology DSM), pack actions need **structured output**: a tagged JSON value the dashboard renders as the appropriate UI primitive. This doc proposes the minimum primitives catalogue — the contract between packs (Lua, in-process) and the dashboard frontend (web, generic). Packs do not draw pixels; they emit data of a known shape and the frontend chooses how to render it.

The catalogue is small and additive. New primitives are introduced when an existing one cannot express the data; we do not invent a primitive per use case.

## Primitives

Every primitive value is a Lua table with a `type` field (string) plus shape-specific fields. The set below is grouped by category. All primitives are values — none of them carry callbacks; interactivity is expressed by referring to pack actions by alias.

### Atomic

| Type | Fields | Example use |
|------|--------|-------------|
| `text` | `text`, `style?` (`muted`/`strong`/`error`/`success`) | One-line result. `"Tailscale is up"` |
| `code` | `text`, `lang?` (`json`/`xml`/`html`/`lua`/...) | HTTP response body, registry value dump |
| `markdown` | `text` | Long-form output (Raycast detail panels, help text) |
| `status_badge` | `label`, `state` (`ok`/`warn`/`error`/`unknown`/`info`) | Service up/down, "exit node: active" |
| `link` | `href`, `label?` | Source citation in a regedit hack alias |
| `icon` | `name`, `tone?` | Inline marker; pairs with text in lists |
| `kbd` | `keys` (string[]) | Key combos in help/markdown contexts |

### Numeric / scalar

| Type | Fields | Example use |
|------|--------|-------------|
| `single_stat` | `value`, `unit?`, `label?`, `delta?`, `state?` | "CPU 47%", "Errors 3 (+2)" |
| `gauge` | `value`, `min`, `max`, `unit?`, `thresholds?` (list of `{at, state}`) | Disk-pool capacity, battery |
| `progress_bar` | `value`, `max`, `label?`, `indeterminate?` | Long-running action progress |
| `sparkline` | `points` (number[]), `unit?` | Inline trend in a card |

### Tabular

| Type | Fields | Example use |
|------|--------|-------------|
| `table` | `columns` (`[{key,label,type,sortable?,align?}]`), `rows` (record[]), `default_sort?`, `row_actions?` (alias[]) | Process list, registry value list, HTTP headers |
| `key_value` | `pairs` (`[{key,value}]`) where `value` is a primitive | Response metadata, system facts |
| `list` | `items` (`[{title,subtitle?,icon?,trailing?,action?}]`) | Raycast-style result list, command palette hits |

`table.columns[].type` is one of `string` / `number` / `bytes` / `duration` / `timestamp` / `status` / `code` / `link` — drives formatter and sort comparator.

### Time-series

| Type | Fields | Example use |
|------|--------|-------------|
| `line_chart` | `series` (`[{name,points:[{t,v}]}]`), `unit?`, `y_min?`, `y_max?` | CPU over time, request latency |
| `bar_chart` | `series`, `unit?`, `stacked?` | Per-day request counts |
| `area_chart` | `series`, `unit?`, `stacked?` | Disk usage by pool |
| `heatmap` | `x_bins`, `y_bins`, `values` (number[][]) | Latency distribution, activity grid |
| `top_list` | `items` (`[{label,value,unit?}]`), `max?` | Pi-hole top blocked domains |

### Composite

| Type | Fields | Example use |
|------|--------|-------------|
| `card` | `title?`, `subtitle?`, `body` (primitive), `footer?` (primitive) | NAS storage card: gauge body + link footer |
| `grid` | `cells` (primitive[]), `columns?` | Synology-style overview |
| `panel` | `title`, `body` (primitive), `actions?` (alias[]) | Grouped detail panel |
| `tabs` | `tabs` (`[{label,body:primitive}]`) | Postman request/response/headers split |
| `split` | `direction` (`row`/`col`), `parts` (primitive[]) | Master-detail |

Composites are recursive — a `card.body` may be a `gauge`, a `grid.cells[i]` may be a `card`. The frontend recurses; packs do not need to know the layout system.

### Streaming

Streams are returned as a primitive plus an iterator handle on the action result envelope (see Pack output schema). The primitive describes the *shape of one frame*; the dashboard appends frames as they arrive.

| Type | Fields | Example use |
|------|--------|-------------|
| `log_stream` | `frame_type` = `log`, `columns?` (default `[time, level, message]`) | `journalctl -f`, app logs |
| `live_table` | `frame_type` = `table`, `columns`, `key` (column name for upsert) | `top`/`htop` processes (upsert by pid) |
| `event_stream` | `frame_type` = `event` | SSE feeds, Tailscale netmap updates |

### Hierarchical

| Type | Fields | Example use |
|------|--------|-------------|
| `tree` | `root` (`{label, children?, value?, icon?}`) | Process tree, registry key tree, fs view |
| `json_view` | `value` (any), `expand_depth?` | Postman response body, raw API result |
| `diff` | `before`, `after`, `lang?` | Config-file edit preview |

### Action

Actions are how the dashboard drives back into pack-land. They reference an alias by name; the cap system enforces what runs.

| Type | Fields | Example use |
|------|--------|-------------|
| `button` | `label`, `alias`, `args?`, `confirm?`, `style?` (`primary`/`danger`) | "Toggle exit node" |
| `form` | `fields` (`[{name,label,type,required?,default?,options?}]`), `submit_alias`, `submit_label?` | "Set default PDF viewer" picker |
| `confirm` | `prompt`, `alias`, `args?`, `danger?` | Inline confirmation before destructive action |
| `action_menu` | `items` (`[{label,alias,args?}]`) | Row-level menu in a table |

`form.fields[].type`: `text` / `password` / `number` / `bool` / `select` / `multiselect` / `path` / `host`.

## Pack output schema

A pack action returns a single envelope. The envelope is a tagged value; `body` is one primitive (often a composite).

```lua
-- ok envelope
{
  ok = true,
  body = { type = "table", columns = {...}, rows = {...} },
  -- optional channels
  stream = nil,         -- iterator handle when body.type is a *_stream
  cite = {              -- transparency: what was actually touched
    { kind = "registry", path = "HKCU\\Control Panel\\Desktop\\..." },
    { kind = "http", method = "GET", url = "http://localhost:41112/..." },
  },
  ttl_ms = 5000,        -- optional: frontend may auto-refresh
}

-- err envelope
{ ok = false, error = "...", body? = primitive }
```

`cite` mirrors the transparency principle in `system_dashboard.md` — the rendered output names the literal operation. The frontend shows it next to the result.

### Examples

**Tailscale status** (composite):

```lua
{
  ok = true,
  body = { type = "card", title = "Tailscale", body = {
    type = "grid", columns = 2, cells = {
      { type = "single_stat", label = "State",     value = "Running",  state = "ok" },
      { type = "single_stat", label = "Exit node", value = "us-nyc-01" },
      { type = "key_value", pairs = {
        { key = "IPv4",  value = { type = "text", text = "100.64.0.5" } },
        { key = "Peers", value = { type = "text", text = "12" } },
      } },
      { type = "button", label = "Toggle exit node", alias = "tailscale.toggle_exit",
        confirm = true, style = "primary" },
    },
  } },
  cite = { { kind = "http", method = "GET", url = "http://localhost:41112/v0/status" } },
}
```

**Process list** (live table, streamed):

```lua
{
  ok = true,
  body = {
    type = "live_table", frame_type = "table", key = "pid",
    columns = {
      { key = "pid",  label = "PID",  type = "number",   sortable = true },
      { key = "cmd",  label = "Cmd",  type = "string" },
      { key = "cpu",  label = "CPU",  type = "number",   align = "right" },
      { key = "mem",  label = "Mem",  type = "bytes",    align = "right" },
    },
    row_actions = { "proc.kill", "proc.signal" },
  },
  stream = <iter handle>,
  cite = { { kind = "exec", argv = { "ps", "axo", "pid,comm,%cpu,rss" } } },
}
```

**Regedit hack** (atomic + cite):

```lua
{
  ok = true,
  body = { type = "key_value", pairs = {
    { key = "MenuShowDelay", value = { type = "single_stat", value = 0, unit = "ms" } },
  } },
  cite = { { kind = "registry", path = "HKCU\\Control Panel\\Desktop\\MenuShowDelay" } },
}
```

## Dusklight reuse

Dusklight (`~/git/rhizone/dusklight`) ships an adjacent design with overlap and divergence:

| Dusklight provides | Adoption for system_dashboard |
|--------------------|-------------------------------|
| `Source` / `Parser` / `Pattern` / `Renderer` plugin model | Not adopted directly — packs are not parsers; pack actions emit primitives, no recognition pipeline. |
| `ReactiveLens<S, A>` + optics (`lens.field`, `traversal.each`) | Not adopted in pack output — packs emit values, not lenses. The frontend may use lenses internally to bind primitives to live state. |
| Layout primitives (`HStack`/`VStack`/`ZStack`/`Grid`/`ForEach`/`Spacer`) | **Adopt for composites.** Our `grid`/`split`/`tabs`/`card` map onto these; we expose a curated subset rather than the full layout DSL. |
| Marinada expressions for action dispatch | Not adopted — actions are alias references resolved by pack name, not Marinada exprs. The cap system is the authority model. |
| Capability objects (`Cap<T>`) | Same shape as crescent's existing cap taxonomy; nothing new to build. |
| Pattern-driven renderer selection (heuristic, ranked) | Optional later. Pack output is explicitly tagged, so no ranking is needed in v1. |

**What we adopt:** the philosophical shape — *data emits, frontend renders*; capability-bounded actions; composable layout. **What we build new:** the closed primitives catalogue above (Dusklight is open-set; packs benefit from a closed contract so any pack renders correctly in any frontend), the streaming-frame envelope, and the `cite` channel for transparency.

If Dusklight ships a TypeScript renderer-set that maps cleanly to these primitives, the frontend can vendor it. Until then the catalogue is the contract.

## Open questions

- **CSS / theming**: the catalogue says nothing about colors, spacing, fonts. Frontend owns theming. Should `style?` enums (`primary`/`danger`/`muted`/...) be the entire surface area packs touch? Likely yes.
- **Localisation / formatting**: who formats `bytes`, `duration`, `timestamp` — pack or frontend? Lean frontend (locale-aware), pack supplies raw values + column type.
- **Streaming transport**: how does `stream = <iter>` cross the in-process / browser boundary? Probably SSE or a websocket envelope when the dashboard is remote; direct iterator when same-process. Out of scope here.
- **Real-time updates without streams**: should `ttl_ms` be the only refresh signal, or a dedicated `subscribe` envelope for push updates?
- **Where does rendering live?** — current dashboard is server-rendered HTML. The primitives are JSON-friendly so a future SPA frontend can consume them unchanged; the v1 server can ship a renderer per primitive.
- **Action arg validation**: `form` field types are listed; do we need a richer schema (regex, range, async-validate-from-pack)? Probably yes, but staged.
- **Custom primitives**: should packs be able to register a new primitive type with a renderer plugin (Dusklight-style), or is the catalogue strictly closed? Default: closed; revisit when a real pack needs something not expressible.
- **Pagination / virtualisation**: `table` / `live_table` need cursor / windowing fields once row counts get large. Not in v1.
- **Empty / loading states**: should every primitive carry an explicit `loading` / `empty` slot, or is that the frontend's default behaviour for missing data? Lean frontend default.
