# cr-repo content-type cookbook

Non-normative examples of how to express common content types using cr-repo's primitives. None of these add new modules; they're conventions that fall out of `cr-record` + addressing modules + the open `metadata` map.

Apps that recognize a given type's conventional metadata fields can render and act on it richly; apps that don't recognize them preserve everything untouched. Same data, multiple-app readable, no central registry.

For the normative spec, see [cr-repo-spec.md](./cr-repo-spec.md). For the gentle introduction, see [cr-repo-intro.md](./cr-repo-intro.md).

---

## Sticky note (inline text)

```json
{
  "cr-type": "cr-record",
  "ref": null,
  "metadata": {
    "types": ["note"],
    "text": "remember to ask alice about the printer",
    "lang": "en"
  },
  "created": "2026-05-14T10:00:00Z"
}
```

Short text lives in `metadata.text`. Refs to nothing because the note *is* the content.

---

## Markdown document

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://example.com/posts/42.md" },
  "metadata": {
    "types": ["text/markdown", "post"],
    "title": "What I learned writing a protocol",
    "description": "Notes from a year of iteration."
  },
  "created": "2026-05-14T10:00:00Z"
}
```

The body lives at the referenced URI (or as a content-addressed blob, if hashing is loaded). `types` includes the mimetype.

---

## Image

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://example.com/img/sunset.png" },
  "metadata": {
    "types": ["image/png"],
    "title": "Sunset over the office",
    "alt": "A sunset partially obscured by a tall building.",
    "width": 1920,
    "height": 1080
  },
  "created": "2026-05-14T10:00:00Z"
}
```

`alt` for accessibility, dimensions as structured numbers, mimetype in `types`.

---

## Bookmark

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://wiby.me/" },
  "metadata": {
    "types": ["bookmark"],
    "title": "Wiby — search engine for the classic web",
    "description": "Hand-curated indie web search.",
    "id": "wiby",
    "added": "2026-05-14T10:00:00Z",
    "rating": 5,
    "read_state": "unread"
  },
  "created": "2026-05-14T10:00:00Z"
}
```

`id` enables external addressing via `cr-metadata-address`. `rating`, `read_state`, `added` are conventional fields a bookmark app indexes; another app preserving them but not understanding them does no harm.

---

## Code snippet

```json
{
  "cr-type": "cr-record",
  "ref": null,
  "metadata": {
    "types": ["code", "text/x-rust"],
    "title": "Stable sort by frequency",
    "text": "fn sort_by_freq<T: Hash + Eq>(items: &[T]) -> Vec<&T> { ... }",
    "language": "rust"
  },
  "created": "2026-05-14T10:00:00Z"
}
```

For longer code, ref a blob instead of inlining `text`. `types` carries both semantic (`code`) and mimetype (`text/x-rust`).

---

## Curated list of bookmarks

```json
{
  "cr-type": "cr-bundle",
  "records": [
    {
      "cr-type": "cr-record",
      "ref": null,
      "metadata": {
        "types": ["collection"],
        "title": "Indie web search engines",
        "description": "Alternatives to mainstream search."
      },
      "created": "2026-05-14T10:00:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": { "kind": "uri", "uri": "https://wiby.me/" },
      "metadata": { "types": ["bookmark"], "title": "Wiby", "id": "wiby" },
      "created": "2026-05-14T10:00:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": { "kind": "uri", "uri": "https://marginalia.nu/" },
      "metadata": { "types": ["bookmark"], "title": "Marginalia", "id": "marginalia" },
      "created": "2026-05-14T10:00:00Z"
    }
  ]
}
```

First record is the list's self-description (`types: ["collection"]`); subsequent records are entries. Each entry carries an `id` so external references can target it via `cr-metadata-address`.

---

## Social profile (cross-platform)

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://example.itch.io/" },
  "metadata": {
    "types": ["profile", "io.itch.profile"],
    "title": "Some Creator on itch",
    "handle": "some-creator",
    "platform": "itch.io",
    "io.itch.profile": {
      "user_id": "some-creator"
    }
  },
  "created": "2026-05-14T10:00:00Z"
}
```

Semantic type (`profile`) for generic apps; namespaced type (`io.itch.profile`) for platform-aware apps; namespaced metadata block for platform-specific structured fields.

---

## Steam game

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://store.steampowered.com/app/220/" },
  "metadata": {
    "types": ["link", "com.steam.app"],
    "title": "Half-Life 2",
    "com.steam.app": {
      "appid": 220,
      "launch_uri": "steam://run/220"
    },
    "wishlist": true,
    "rating": 5
  },
  "created": "2026-05-14T10:00:00Z"
}
```

A Steam-aware client uses `com.steam.app.launch_uri` to actuate via the steam:// protocol. A non-Steam-aware client falls back to opening the URI. Both are valid.

---

## itch game

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://creator.itch.io/cool-game" },
  "metadata": {
    "types": ["link", "io.itch.game"],
    "title": "Cool Game",
    "io.itch.game": {
      "creator": "creator",
      "slug": "cool-game"
    }
  },
  "created": "2026-05-14T10:00:00Z"
}
```

Same pattern. An itch-aware client could launch the itch desktop app; non-itch-aware falls back to URL.

---

## Discord channel / server reference

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://discord.com/channels/123/456" },
  "metadata": {
    "types": ["link", "com.discord.channel"],
    "title": "#general in Some Server",
    "com.discord.channel": {
      "guild_id": "123",
      "channel_id": "456"
    }
  },
  "created": "2026-05-14T10:00:00Z"
}
```

Deep-linkable via the Discord app on systems where it's installed; falls back to the URL otherwise.

---

## Typed edges between records

Edges express relations between records without inventing a new primitive — they're just records whose `ref` points at one record and whose `metadata` declares the relation to another.

### "B was derived from A"

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "metadata", "in": "<bundle-ref>", "match": { "id": "B" } },
  "metadata": {
    "types": ["edge"],
    "relation": "derived_from",
    "from": { "kind": "metadata", "in": "<bundle-ref>", "match": { "id": "A" } }
  },
  "created": "2026-05-14T10:00:00Z"
}
```

`ref` is the edge's *target* (the new record); `from` is the source. `relation` is a freeform string the consumer interprets — common conventions include `derived_from`, `references`, `reply_to`, `sketch_of`, `inspired_by`, `responds_to`.

### "C supersedes B"

Use `cr-revision` for this case — it's a blessed module specifically because supersession needs uniform semantics across consumers (the latest unrevised record is the current one). For other edge types where consumers can differ, use the generic edge pattern above.

---

## Cross-walled-garden mixed list

```json
{
  "cr-type": "cr-bundle",
  "records": [
    {
      "cr-type": "cr-record",
      "ref": null,
      "metadata": { "types": ["collection"], "title": "Cozy evening stuff" },
      "created": "2026-05-14T10:00:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": { "kind": "uri", "uri": "https://store.steampowered.com/app/367520/" },
      "metadata": {
        "types": ["link", "com.steam.app"],
        "title": "Hollow Knight",
        "com.steam.app": { "appid": 367520, "launch_uri": "steam://run/367520" }
      },
      "created": "2026-05-14T10:00:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": { "kind": "uri", "uri": "https://creator.itch.io/a-short-hike" },
      "metadata": {
        "types": ["link", "io.itch.game"],
        "title": "A Short Hike",
        "io.itch.game": { "creator": "creator", "slug": "a-short-hike" }
      },
      "created": "2026-05-14T10:00:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": { "kind": "uri", "uri": "https://www.youtube.com/watch?v=..." },
      "metadata": { "types": ["bookmark", "media"], "title": "lo-fi study mix" },
      "created": "2026-05-14T10:00:00Z"
    },
    {
      "cr-type": "cr-record",
      "ref": null,
      "metadata": {
        "types": ["note"],
        "text": "put the kettle on first"
      },
      "created": "2026-05-14T10:00:00Z"
    }
  ]
}
```

One bundle, four heterogeneous refs (Steam app, itch game, YouTube video, free-floating note). A fully-equipped client launches each in its native context. A minimally-equipped client falls back to the underlying URI. Both work; neither breaks the other.

This is the form that doesn't exist anywhere in the centralized-platform world. It's what cr-repo is for.

---

## Provenance: where this came from

```json
{
  "cr-type": "cr-record",
  "ref": { "kind": "uri", "uri": "https://www.goodreads.com/book/show/12345" },
  "metadata": {
    "types": ["bookmark", "book"],
    "title": "Some Book",
    "rating": 4,
    "cr-provenance": {
      "source": { "kind": "uri", "uri": "https://www.goodreads.com/user/show/me/shelf/read" },
      "captured_via": "import-goodreads",
      "captured_at": "2026-05-14T09:30:00Z",
      "notes": "Imported during the Goodreads migration."
    }
  },
  "created": "2026-05-14T10:00:00Z"
}
```

The `cr-provenance` block records where the entry originated (the Goodreads shelf URL), how it was captured (the import method), when, and a free-form note. Useful when the original source dies, or when reconciling duplicates across import sources.
