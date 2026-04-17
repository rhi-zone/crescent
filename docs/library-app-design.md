# Library app design — lessons from SillyTavern

The crescent library app is the entry-point UI that lists chat cards and
lets users search, filter, tag, and launch them. It replaces
SillyTavern's character browser.

ST at 23k cards is unusable: multi-second freezes on every keystroke,
browser hangs on basic operations, 16 MB payloads for a tag click.
Investigating the root causes surfaced a clear set of rules the
crescent library app must follow. This doc records what ST does wrong
and the corresponding prescription. Cross-reference:
[`daemon-transport.md`](daemon-transport.md) for transport-layer
decisions.

All file:line pointers below refer to SillyTavern at
`/mnt/ssd/ai/SillyTavern`.

## Payload shape pathologies

### `/api/characters/all` — 45 MB, no pagination

`src/endpoints/characters.js:1318` readdirs every PNG and returns the
lot in one JSON. 98% of bytes per card are `data.creator_notes` (median
~19 KB, worst case 337 KB). There is no `?limit`, no `?since`, no
filter parameter. "Shallow mode" exists but still ships
`creator_notes`.

### `/api/settings/get` — 16 MB, refetched on demand

15.5 MB of the blob is one JSON-encoded `settings` string. Inside:

- `tag_map` 8.87 MB — `{avatar → [tag_uuids]}`, O(cards × avg_tags).
- `tags` 1.97 MB — 9,291 tag registry entries.
- Everything else combined < 300 KB.

Two calls per page load is structural: `public/scripts/world-info.js:2062`
and `public/scripts/extensions/quick-reply/index.js:56` each refetch the
whole 16 MB to pluck one field (`world_names`, `quickReplyPresets`).

### Prescription

- **Paginated listing**:
  `GET /cards?limit=200&offset&q&tag&sort=...` → 80–120 B per row
  `{id, name, avatar_url, fav, date_added, date_last_chat, chat_size, tags:[id…]}`.
  No `creator_notes`, no `data.*`. 200 rows ≈ 20 KB.
- **Full card body only on demand**: `GET /cards/:id`.
- **Tag membership is a join**: `card_tags(card_id, tag_id)` in SQLite.
  Never ship a `tag_map` blob. Filter by tag is `WHERE tag_id=?`.
- **Tag registry**: `GET /tags` with ETag. Fetched once, 304 thereafter.
- **Thumbnails**: `GET /cards/:id/thumb?size=128` → raw bytes with
  long `Cache-Control`. Never base64 into JSON.
- **Split settings per domain**: `/settings/ui`,
  `/settings/presets/openai`, `/world-info/names`, `/quick-reply/sets`.
  Each ETagged. A UI action that needs `world_names` fetches ~1 KB.
- **Incremental refresh**: `GET /cards?since=<mtime>` for delta sync.

## UI freeze pathologies

### Search: 5–15 s freeze per keystroke

`public/scripts/filters.js:317-322` — every keystroke calls
`fuzzySearchCharacters/Groups/Tags`. Each of those
(`public/scripts/power-user.js:2119`) does
`new Fuse(characters, {keys: 11 fields, threshold 0.2}).search(q)`.

Fuse's index is rebuilt from scratch every keystroke over 23k cards ×
11 string keys (many multi-KB incl. `description`, `mes_example`,
`first_mes`). Then `printCharacters` (`public/script.js:989`) fully
re-renders the DOM. `setFilterData` (`filters.js:351`) also does
`JSON.stringify(oldData) !== JSON.stringify(data)` on every call.

Per-keystroke cost: **O(N · K · L)** ≈ gigabytes of string scanning.

**"Insane disk usage" during search is almost certainly swap/compressed-memory
pressure** — Fuse allocates a tokenized copy of every indexed string
per call, GC-pressuring a tab already holding ~1.5 GB of parsed card
data. Confirming this needs devtools Memory + `iotop`; cannot tell from
source alone.

### Chat close: 5–15 s freeze

`public/script.js:10641 closeCurrentChat` → `select_rm_characters()` →
`printCharacters(doFullRefresh)`. `printCharacters` (lines 989–1079)
calls `getEntitiesList` which with `bogus_folders=true` runs
`filterByTagState` twice plus `entitiesFilter.applyFilters` per tag
entity (lines 1173–1190), plus `printTagFilters` 3× (lines 1005–1007),
each doing `Object.values(tag_map).flat()` (`tags.js:1554,1567`) —
O(cards × tags_per_card) flattening + `.includes()` per tag.
Closing a chat should be a 2-field state flip; the list view should not
re-render at all.

### Tag edit: 5–15 s freeze

`public/scripts/tags.js:796-797, 831-832` —
`addTagsToEntity` / `removeTagFromMap` call `printCharactersDebounced`
(same re-render as above) **and** `saveSettingsDebounced`. The save
(`public/script.js:7951`, payload 7969–7994) POSTs a single JSON blob
containing full `tags` (9291), full `tag_map` (23649), all of
`power_user`, `extension_settings`, world_info, every API setting —
the entire 16 MB settings file is rewritten server-side per tag
toggle.

### "Enable Tags as Folder": indefinite browser hang

`public/scripts/power-user.js:3908` toggles `#bogus_folders`. With it
enabled, `getEntitiesList` (`public/script.js:1152-1216`) adds every
folder-tag as an entity (~9k), then sub-entities loop runs
`filterByTagState` twice + `applyFilters` per folder-tag.
`filterByTagState` (`public/script.js:369`) iterates all entities and
tests tag membership.

Cost: **O(F² · E) ≈ 9k · 9k · 32k ≈ 2.6×10¹² lookups**. Not a freeze —
a genuine algorithmic wall.

### Prescription

- **Persistent inverted index, not rebuild-per-keystroke.** Build
  token→rowid bitsets (or trigrams) once at load; search = bitset
  intersection, O(query + hits). SQLite FTS5 is the natural
  implementation — available via `lib.sqlite` and already in use for
  the app index. Search happens server-side, returns rowids; client
  fetches the page.
- **Mutations touch only affected rows.** A tag edit is a 1-row insert
  or delete in `card_tags`. Never rewrite "all settings" to persist a
  tag change.
- **Views are derived incrementally.** Closing a chat does not refresh
  the list. Editing a tag updates the affected row in the rendered
  list, nothing else.
- **Folder view is a GROUP BY, precomputed.** `SELECT tag_id,
  COUNT(*) FROM card_tags GROUP BY tag_id` feeds the folder tree.
  Rendered virtualized (only visible rows in DOM).
- **Virtualize the DOM.** At 23k rows the list must render only what's
  visible. Non-negotiable.
- **Debounce is not a fix.** ST debounces these calls — the freeze is
  the underlying algorithm, not the call frequency. Fix the algorithm.

## Cross-cutting principle

ST conflates "state changed" with "rebuild everything." One function
(`printCharacters`) re-enumerates all entities, re-filters, re-sorts,
and re-renders on every mutation — even though pagination later slices
to one page, the whole 32k set gets processed first.

The crescent rule: **mutations touch only affected rows; views are
derived incrementally.** If an action requires O(N) work where N is
the library size, that action is wrong. A library browser that works
at 23k cards must work at 230k and 2.3M with the same architecture —
only the dataset size changes, not the algorithms.

## Pagination and latency

Pagination introduces round-trips, so the instinctive worry is
"pagination is laggier on WAN." The opposite is true — pagination is
strictly faster on WAN, for every metric that matters.

### Initial paint

- Full list: 10 MB compressed over a 25 Mbps link ≈ 3 s transfer +
  parse + render.
- Paginated: 20 KB first page arrives in ~1 RTT (~200 ms on
  Tailscale intercontinental).

Pagination wins time-to-interactive by an order of magnitude.

### Scroll

Each page boundary costs 1 RTT. Mitigation: **prefetch page N+1 when
the user enters page N's last 20%**. As long as scroll speed ×
row_height < bandwidth, the RTT is fully hidden. Generous page size
(200–500 rows) keeps boundaries rare.

### Search (the real latency risk)

Keystroke → query → 200 ms RTT feels sluggish if every character
round-trips. Fixes:

1. **Debounce 150–200 ms.** Users don't type faster than that on a
   phrase, so one RTT per debounce-window naturally masks the latency.
2. **Server response must be sub-5 ms** so `query_time + RTT ≈ RTT`.
   FTS5 over 23k rows is well under 1 ms, so this holds.
3. **Send on `keydown`, not `keyup`** — steals a few ms per keystroke.

### Connection reuse

HTTP/1.1 keep-alive is load-bearing here. Without it every page fetch
pays a TLS handshake (~1 extra RTT). With it, sequential page fetches
are one RTT each. This is the one place transport work has leverage;
HTTP/2 multiplexing would also let prefetch and foreground fetches
share a connection without head-of-line, but keep-alive captures
most of the win for sequential access. See
[`daemon-transport.md`](daemon-transport.md) for the broader
HTTP/2/3 discussion — the conclusion there still stands.

### What ST got wrong

ST's failure isn't "chose not to paginate." It's that ST **faked
pagination by slicing a fully-computed list**, paying the compute cost
of the full set every render and none of the bandwidth savings on the
wire. The architecture has to paginate *end-to-end* — server query,
network payload, client render — or it doesn't help.

## How to use this doc

Before adding an endpoint, UI action, or mutation to the library app,
check: does the hot path scale with library size? If yes, it's wrong —
re-derive against SQLite indexes / FTS5 / bitset intersection before
implementing. Add new pathologies here if ST-style anti-patterns reach
the PR review.
