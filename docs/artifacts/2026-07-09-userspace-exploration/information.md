# Information management as a crescent facet

Exploring what "crescent as the entire computer" means for PIM: notes,
bookmarks, knowledge bases, search, reading, curation, tagging, linking,
outlining, journaling, annotation, clipping.

## 1. What people actually do

- Clip a paragraph from a webpage while reading, tag it, forget about it for
  six months, then search for "that thing about mycelium networks" and find
  it because full-text search doesn't need the tag to have been right.
- Keep a running daily journal, half log/half scratchpad, and periodically
  grep it for a date or a keyword instead of navigating a calendar UI.
- Build a Zettelkasten: atomic notes, each with a permanent ID, linked to
  other notes by ID, no folders — the link graph *is* the organization.
- Research a paper: dump PDFs and web pages into a folder, highlight
  passages, extract citations, then write with the highlights open in a
  side pane, pulling quotes back into the draft.
- Maintain a reading queue (Pocket/Instapaper style): save now, read later,
  archive when done, occasionally re-surface via "on this day" or tag.
- Outline a project: nested bullets that collapse/expand, each bullet
  independently referenceable and re-orderable (Workflowy/LogSeq style),
  where the outline structure itself carries meaning, not just prose.
- Annotate a shared document: margin comments anchored to a text range that
  survive the document being edited around them.
- File-manage: browse a tree, rename/move/tag, preview without opening,
  batch-operate on a selection — this is PIM too, just at the OS layer
  (Finder/Nautilus/ranger/lf), and crescent already touches it via `fs`/`path`.

The common shape underneath all of this: **capture something small, attach
light metadata, and later retrieve it by a query you didn't know you'd ask.**
The retrieval side (full text, tags, links, fuzzy half-memory) matters more
than the capture UI. Every one of these tools is, underneath, a database with
opinions about the write path.

## 2. Prior art, briefly

- **Obsidian / LogSeq / Roam** — plain Markdown files + `[[wikilinks]]`,
  bidirectional link graph computed from parsing, local-first, no server.
  This is the closest existing shape to "what would crescent do" — files on
  disk, a link index rebuilt from source, no proprietary format.
- **TiddlyWiki** — the whole wiki is one HTML file with an embedded JS
  runtime; every "tiddler" (note) is a self-contained unit, storage and app
  are the same artifact. Structurally close to crescent's browser pack model
  (a pack *is* the app *is* the data, shippable as one file).
- **Zettelkasten (Luhmann's paper slip-box)** — atomic notes, permanent IDs,
  manual associative links, no hierarchy. The method predates software; any
  software implementing it is just ID assignment + backlink index + search.
- **DEVONthink / Zotero** — heavier reference managers: full-text index over
  PDFs, AI-assisted "see also," citation graphs. DEVONthink's classify
  feature is essentially tf-idf similarity — crescent has `tfidf` and
  `search` already.
- **Pinboard / Raindrop.io** — bookmarking as tags + full-text of the saved
  page, nothing more. Pinboard's entire value proposition is "boring,
  reliable, exportable" — the anti-lock-in bookmarking tool.
- **Apple Notes / OneNote** — freeform canvas + rich text + sync, optimized
  for capture speed over structure. Proprietary format, sync-locked.
- **Muse / Kosmik / Milanote** — spatial canvases: notes as cards on an
  infinite 2D plane, position and proximity *are* the organization scheme,
  no folders or tags required.
- **org-mode** — plain text, but with a markup language expressive enough to
  encode TODO states, scheduling, tables, code blocks, and outlining in one
  file format, plus an entire query language (org-ql) over it.
- **Memex (Vannevar Bush, 1945)** — the ur-text: associative trails through a
  microfilm archive, the origin of "hyperlink." Worth naming because it
  frames linking-as-navigation as the original design goal, before search
  engines made full-text retrieval competitive with following links.

## 3. What crescent already covers

Substantial substrate already exists, scattered:

- **Storage**: `kv_store`, `sqlite` (FFI), `columnar`, `persistent`,
  `event_sourcing`, `crdt` — any of these could back a note store; `crdt` in
  particular gives offline-first multi-device sync for free if a note is
  modeled as a CRDT document.
- **Search**: `search` (inverted index, boolean/phrase/fuzzy/prefix/wildcard
  queries, tokenize/stem/highlight), `tfidf`, `fuzzy_match`, `levenshtein`,
  `trie`/`patricia_trie` (prefix lookup), `bloom` family (existence checks).
  This is a working full-text search stack, not a gap.
- **Linking/graph**: `graph` (5 modules — traversal, algorithms), `trie`,
  `patricia_trie` for backlink/prefix structures.
- **Content formats**: `markdown` (+ `markdown_it`), `html`, `unified`
  pipeline (remark/rehype-style transforms), `diff` (Myers + char-level),
  `merge3` — enough to parse, transform, and three-way-merge note content.
- **Text**: `word_wrap`, `text_stats`, `text_justify`, `porter_stemmer`,
  `soundex`, `nat_lang`, `template`.
- **Sync substrate**: `crdt`, `event_sourcing`, `merge3` — the pieces for
  offline-editable, sync-without-a-server notes exist independently but
  nothing composes them into "a note."
- **Platform**: `lib/platform/` runs apps in-browser with capability
  sandboxing; `lib/platform/apps/library` is literally a "collection
  browser" app already — closest existing app to a PIM tool.

**Notably absent as a named concept**: there is no `note`, `bookmark`,
`outline`, `annotation`, `zettel`, or `journal` library. Every ingredient
exists; the composition doesn't. This matches the inventory's general shape
— crescent is deep on primitives, shallow on "things a person recognizes as
a tool."

## 4. What's missing, and the design questions crescent's philosophy raises

**Storage format for a note is a real open question.** Obsidian and LogSeq
both chose "plain Markdown file per note" — legible, greppable, no lock-in,
but weak for structured metadata (tags/backlinks bolted on via frontmatter
or a separate index that can drift from the files). Crescent could instead
choose "note = row in `kv_store`/`sqlite` with a markdown body field" —
better for query, worse for "just open it in any text editor." Given the
zero-dependency, git-clone philosophy, plain files on disk that also happen
to be greppable outside crescent is the on-brand choice, but it's a real
tradeoff crescent hasn't stated a position on for *any* data-holding
library — this is a case where the batteries-included stance meets "what
does the file on disk look like when crescent isn't running."

**Backlinks are a derived index, not source of truth — where does it live,
and does it regenerate or is it maintained incrementally?** `graph` gives
the data structure; nothing today defines "rebuild backlink graph from a
directory of notes" as an operation. This is a composition gap, not a
primitive gap.

**Caps-first PIM means the note store is injected, never a fixed path.**
Every existing prior-art tool assumes it owns `~/Notes` or a proprietary
sync cloud. A crescent-native notes library would take its storage cap
(`fs`-backed, `kv_store`-backed, or IndexedDB-backed in-browser) as an
argument — the same library runs as a CLI tool over a directory and as a
browser pack over IndexedDB, because the cap is swapped, not the library.
This is the one place crescent's philosophy produces something the prior
art structurally cannot: Obsidian is a filesystem app; Notion is a server
app; a crescent note library is neither, it's a function of its injected
cap, so "sync to a server" and "stay fully local" are the same code with a
different cap wired in — no separate self-hosted-vs-cloud fork.

**Annotation-anchored-to-a-range surviving edits is a real unsolved
problem** even in mature tools (web highlighters break when pages change
DOM). Crescent has `diff` (char-level) and could in principle re-anchor an
annotation by diffing old/new content and mapping the offset through the
diff — but nothing does this today. Worth flagging as a genuine hard
problem rather than a missing CRUD wrapper.

**Search-as-you-half-remember is what `fuzzy_match` + `search`'s fuzzy query
+ `tfidf` similarity already do individually** — the missing piece is
ranking that blends recency, tag match, and text relevance into one score,
which is a policy decision (what a note-search tool would encode), not a
new primitive.

**The browser-first constraint reframes "sync."** Because
`lib/platform/` apps must work fully in-browser without a backend, a
crescent PIM tool's sync story is IndexedDB-local by default, with `crdt`
giving multi-tab/multi-device merge if a sync transport (any HTTP endpoint,
even a static file host with conflict resolution client-side) is later
injected as a cap — sync becomes optional plumbing, not an architectural
commitment the tool makes on day one.

## 5. What a crescent-native version could look like

Not a proposal to build — a shape sketch of what composition would look
like if the gap above were closed:

- A `note` library: `note.create(cap, body, opts)` /
  `note.search(cap, query)` / `note.backlinks(cap, id)`, storage cap
  injected (fs directory of markdown+frontmatter, or `kv_store`, or
  IndexedDB via a browser cap) — same library, three runtimes, per the
  caps-first rule already in `CLAUDE.md`.
- Backlink index built via `unified`/`markdown` parse → wikilink extraction
  → `graph` adjacency, rebuilt or incrementally maintained, stored
  alongside notes via the same injected cap (never assumes a database
  exists that the notes don't).
- Search over notes: thin wrapper composing `search.index` +
  `tfidf` for ranking + `fuzzy_match` for half-remembered queries — this is
  assembly, not new algorithm work.
- A browser pack (`lib/platform/apps/notes` or similar, following the
  existing `library` app's pattern) as the "tool, not library" surface —
  matches "people use tools, not libraries."
- Annotation-on-arbitrary-content as a separate, harder library building on
  `diff` for re-anchoring — flagged above as unsolved, not slotted in as if
  solved.

The overall finding: crescent's gap in this facet is *composition*, not
*primitives*. The interesting design question the philosophy actually
raises is the storage-cap question — whether a note's "home" is a fact
about the library or a fact about what's injected — because every existing
PIM tool answers it by fiat (a filesystem, a cloud) and crescent's caps
model is structurally capable of not answering it at all.
