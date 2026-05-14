# cr-repo protocol — draft v0.7

A protocol family for local-first, optionally-signed, optionally-content-addressed repositories. No central anything; no privileged module; interop emerges from intersection of advertised module sets.

The `cr-` prefix is a placeholder pending naming.

---

# Part 1 — Framework

This part is not a module. It describes how modules compose, what invariants they must respect, and the operational mechanisms (references, capability advertisement, resolution) they share. An implementation does not "implement Part 1"; it implements a set of modules from Part 2 that observe these rules.

## Modules

A module is a named, self-contained unit that contributes some combination of:

- A reference kind.
- A content shape (a JSON or byte structure with a documented schema).
- A reserved metadata key.
- An operational endpoint, protocol, or algorithm.
- A behavioral rule clients honor when the module is loaded.

Every module declares:

- Its name, in the `cr-<name>` form.
- The other modules it depends on, if any.
- What it contributes (kinds, content shapes, reserved keys, endpoints, behavior).

Implementations are free to load any combination of modules. Two implementations interoperate only on the intersection of their loaded module sets, which may be empty. The spec mandates no module. There is no "core." There is no recommended loadout.

A module that an implementation does not load is *opaque* to that implementation:

- Unknown reference kinds are storable and forwardable but not dereferenceable.
- Unknown content shapes are storable and forwardable but not interpretable.
- Unknown reserved metadata keys are preserved on re-serialization but ignored at decision points.
- Unknown endpoints are not called.

## References

A reference is a tagged identifier:

```
Ref = { kind: string, ... }
```

`kind` is a short ASCII string naming an addressing scheme. The remaining fields are kind-specific and contributed by the module that defines the kind. The framework does not enumerate kinds.

A consumer encountering a `Ref` whose kind it does not understand treats the value as opaque.

## Capability advertisement

Implementations advertise their loaded modules through one or more of these channels, as relevant to the implementation's role:

- **In-content declaration.** A content-producing implementation MAY embed a capability list in content it produces. Modules contributing such content shapes specify the form (e.g. `cr-identity` defines a `cr-capabilities` record producers MAY include in their logs).
- **Endpoint declaration.** A serving implementation that exposes operational endpoints (HTTP or otherwise) MAY publish a capabilities endpoint or document. Modules contributing endpoints specify the form (e.g. `cr-host` defines `GET /capabilities`).
- **Resolution-time declaration.** A resolution-mediated implementation MAY include capabilities in resolution announcements. Modules contributing resolution mechanisms specify the form.
- **Out-of-band declaration.** Implementations exposed as libraries or in-process APIs declare capabilities through whatever in-language mechanism they offer; the framework does not constrain this.

A capability declaration is a list of module names. Module versions, if relevant, are appended with `@<version>` (e.g. `cr-record@1`). Absence of a version implies "any."

## Content shape type marker

Every JSON content shape contributed by a module MUST include a top-level key:

```
cr-type: "<shape-name>"
```

`<shape-name>` is the name a module uses to identify the shape it contributes (e.g. `"cr-record"`, `"cr-bundle"`, `"cr-page"`). A consumer reading any JSON content from the protocol family identifies its shape by this field before applying any interpretation.

`cr-type` is distinct from the unprefixed `types` convention inside record metadata: `cr-type` names the *structural* shape (record vs. bundle vs. page); `metadata.types` names the *semantic* content classification (bookmark vs. note vs. image). They live at different paths and serve different purposes.

Using `cr-type` for any purpose other than structural shape identification — for example, repurposing it inside an unrelated JSON object that happens to share a hosting context — is undefined behavior. The framework does not police the key, but any structure containing `cr-type` will be interpreted by participating implementations as a content shape, and divergent uses will produce interop failures rather than errors.

A consumer encountering a `cr-type` value it does not recognize treats the content as opaque per the module-opacity rule.

## Reference resolution

Dereferencing a `Ref` to bytes is a client-side algorithm. The framework specifies its shape; each module supplies the operational details for the kinds it contributes.

A reference is either **location-bearing** (the kind carries enough information to locate bytes directly — typically URIs and paths) or **location-free** (the kind names an identity but not a location — typically hashes, pubkeys-as-mutable-pointers). The contributing module declares which.

For a location-bearing ref, dereferencing is direct: use the location.

For a location-free ref, the consumer tries sources in order, accepting the first whose returned bytes satisfy the ref's verification rule (if any):

1. Local cache, indexed by the same ref.
2. Hints adjacent to the ref in its context (e.g. the `cr-mirrors` reserved key on the same record, if `cr-mirrors` is loaded).
3. Hints from the enclosing context (containing record, signed wrapper, etc.).
4. Consumer-configured sources for the relevant kind (e.g. known `cr-host` endpoints for hash refs).
5. Resolution adapters loaded by the consumer (e.g. `cr-resolve` backends).
6. Failure: the ref is unresolvable in the current session. Adjacent metadata remains usable.

When the returned bytes do not match the ref's verification rule, the consumer discards the source and continues. When a source returns a container (e.g. a bundle when the ref names a record inside one), the consumer extracts the addressed object by matching identity inside the container.

This algorithm is unilateral and uncoordinated. Two consumers reach the same content through different sources; equality (when the addressing kind allows verification) ensures they see the same bytes.

## Invariants

These hold across every module. New modules MUST NOT violate them.

- **No global view.** The protocol has no notion of network-wide state. No global ranking, search, popularity, or aggregation. Any such feature is a client-side computation or a separate optional service built atop the family.
- **Local-first.** A consumer with a local copy operates fully offline; network is for synchronization and discovery, not read-time authoritative lookup.
- **No central anything.** Identity, when used, is keypair-rooted. Moderation is the follow / curate graph. Discovery has multiple competing adapter backends; none is privileged.
- **Algorithm agility.** No hash, key, or signature appears in any wire format without an algorithm tag. Modules introducing such values use the `{alg, bytes}` shape. Post-quantum migration is the adoption of new `alg` values, not a protocol change.
- **Append-only.** Modules that introduce logs or chains do not mutate past entries. Retraction is advisory.
- **Pluggable addressing.** References use tagged kinds. No module assumes a particular kind without declaring the dependency.
- **Capability advertisement.** Implementations declare loaded modules; consumers degrade gracefully on unknown modules.
- **No mandate.** The framework mandates no module. Every concrete behavior is opt-in.
- **Software-authoring ergonomics are a tooling concern, not a protocol concern.** The protocol is shaped by composability and correctness. "What's easy to type" never justifies a protocol change. Tools wrap whatever complexity the spec requires.
- **Non-software authoring of some useful subset must remain possible without loss of featureset.** A consumer must be able to compose a meaningful module set that authors only need pen, paper, and a text editor for — i.e. no module that requires computation (hashes, signatures, machine-only encodings) is in the path. Featureset is preserved because the computation-requiring modules are themselves opt-in: skipping them yields a smaller but still self-coherent stack, not a degraded one. New modules MUST respect this: if a module makes a previously-hand-authorable artifact require computation, the module is malformed.

---

# Part 2 — Module catalog

Each module below is self-contained. Order is roughly dependency-first for readability; it does not imply privilege.

---

## `cr-canonical-json`

**Depends on:** nothing.

**Contributes:** a canonical JSON encoding suitable for stable hashing.

Canonical JSON per RFC 8785 (JCS). Sort keys, no insignificant whitespace, no duplicate keys, well-defined number representation. Modules that hash structured JSON data depend on this module (or an alternative canonical-encoding module) for stability across encoders.

Storage and transit MAY use non-canonical JSON; verification re-canonicalizes.

---

## `cr-content-address`

**Depends on:** nothing.

**Contributes:** the `hash` reference kind.

```
HashRef = { kind: "hash", alg: string, bytes: <opaque> }
```

`alg` is a short ASCII string. The framework does not enumerate algorithms; conventional values include `"blake3"` and `"sha256"`.

A `HashRef` identifies bytes by the hash of those bytes under the named algorithm. The address is location-free; resolution per Part 1 applies.

A `HashRef`'s verification rule: hash the candidate bytes under `alg`; compare to `bytes`.

When hashing structured data (e.g. a JSON record), the bytes hashed are the canonical encoding under whichever encoding module the content's defining module specifies.

---

## `cr-uri-address`

**Depends on:** nothing.

**Contributes:** the `uri` reference kind.

```
UriRef = { kind: "uri", uri: string }
```

`uri` is a URI per RFC 3986. The address is location-bearing; resolution is direct fetch using whichever scheme the URI names.

No verification rule. The consumer trusts the URI per their own policy (TLS, signed enclosing context, etc.).

---

## `cr-path-address`

**Depends on:** nothing.

**Contributes:** the `path` reference kind.

```
PathRef = { kind: "path", scope: "repo" | "fs", path: string }
```

- `scope: "repo"` — relative to the local cr-repo store root. Portable: another consumer resolves against their own root.
- `scope: "fs"` — absolute filesystem path. Machine-local, not portable.

Paths use forward slashes regardless of host OS. The address is location-bearing for the local consumer; cross-consumer portability depends on scope.

No verification rule.

---

## `cr-blob`

**Depends on:** nothing.

**Contributes:** the convention that opaque byte sequences are first-class content.

A blob is a sequence of bytes. It has no internal structure required by this module. Blobs are referenced by whatever addressing modules the consumer's stack supports — typically by `cr-content-address` (`HashRef` over the bytes) or `cr-uri-address` (a URL to the bytes).

This module is little more than a name: it lets other modules declare "this `Ref` is expected to dereference to a blob" without inventing the term inline.

---

## `cr-record`

**Depends on:** `cr-canonical-json` (for hash-stable serialization).

**Contributes:** the record content shape and reserved metadata conventions.

A record is a JSON object:

```
{
  cr-type:  "cr-record",
  ref:      Ref | null,
  metadata: { ... },
  created:  <rfc3339-timestamp>,
}
```

- `ref`: an address this record describes or relates to, or `null` for metadata-only records.
- `metadata`: open map; see below.
- `created`: advisory RFC 3339 timestamp string (e.g. `"2026-05-14T10:00:00Z"`).

A record's identity, when addressed via `cr-content-address`, is the hash of its canonical JSON encoding under the chosen `alg`. Records are first-class addressable.

### Metadata conventions

`metadata` is open. Unknown keys MUST be preserved on re-serialization. Reserved keys are namespaced (`cr-*`). Conventional unprefixed keys (`title`, `description`, `types`, `nsfw`, `lang`, `size`) are documented as conventions, not enforced. Domain-specific structured fields SHOULD use reverse-DNS or other clearly-owned namespaces (`com.example.foo`).

`created` is advisory across all uses. Consumers SHOULD NOT trust it for ordering when a stronger signal is available.

Timestamps in this protocol family use RFC 3339 strings (e.g. `"2026-05-14T10:00:00Z"`). Modules introducing new timestamp fields SHOULD follow this convention. RFC 3339 is chosen for hand-authoring readability and unambiguous timezone semantics; the cost of a few extra bytes versus an integer is irrelevant next to the ergonomic invariant.

### Filtering and querying

Filtering is a consumer concern. The protocol's contribution is keeping metadata structured and preserved across re-serialization. Consumers compose predicates over arbitrary fields. The `types` field is a coarse type-tag list and does not carry the burden of being the sole filtering axis.

---

## `cr-mirrors`

**Depends on:** `cr-record`.

**Contributes:** the reserved metadata key `cr-mirrors`.

A record MAY carry:

```
metadata: {
  cr-mirrors: [ Ref, ... ],
  ...
}
```

Each entry is an alternative reference that resolves to the same content as the record's primary `ref`. Mirrors are pure hints: they do not participate in addressing equality. A consumer MAY consult them per the resolution algorithm.

A mirror MAY be a container (e.g. a bundle whose records include the addressed record). In that case, resolution extracts the addressed object from the container, verifying when the addressing scheme allows.

---

## `cr-bundle`

**Depends on:** `cr-record`, `cr-canonical-json`.

**Contributes:** the bundle content shape.

A bundle is a JSON object grouping multiple records into a single addressable artifact:

```
{
  cr-type: "cr-bundle",
  records: [ <record>, ... ],
}
```

A bundle has no top-level metadata field. Metadata *about* a bundle is published as a separate record whose `ref` is the bundle's address.

`cr-bundle` does not define how records inside a bundle are independently addressed. Whether such addressing is possible at all depends on the addressing modules the consumer has loaded:

- With `cr-content-address`: a record's hash is its address; to locate a record inside a bundle by hash, the consumer canonical-encodes each entry and matches.
- With `cr-uri-address`: records may have their own URLs separate from the bundle's URL, if the publisher chose to host them that way. The bundle and per-record URLs are independent artifacts.
- With neither, and no other addressing scheme that can identify records: records are not independently addressable. The consumer addresses whole bundles. Publishers wanting record-level granularity publish records as singletons or load a richer addressing module.

This is an intentional consequence of modular addressing: sub-container granularity is a feature each addressing scheme contributes (or doesn't), not a universal protocol guarantee.

---

## `cr-identity`

**Depends on:** `cr-canonical-json`.

**Contributes:** the `pubkey` reference kind, cryptographic primitives, signed records, maker logs.

### Cryptographic primitives

```
Pubkey    = { alg: string, bytes: <opaque> }
Sig       = { alg: string, bytes: <opaque> }
PubkeyRef = { kind: "pubkey", alg: string, bytes: <opaque> }
```

Conventional algorithm values: `"ed25519"`, `"ml-dsa-65"`, `"slh-dsa-128s"`. Unknown values are opaque.

A `PubkeyRef` is the reference form of a `Pubkey`. A consumer dereferencing a `PubkeyRef` is asking "give me the current state of this maker" — typically the maker's log head, resolved via `cr-resolve` or a known host.

### Pages

A page is a signed JSON object attributed to a maker:

```
{
  cr-type:  "cr-page",
  maker:    Pubkey,
  prev:     Ref | null,
  created:  <rfc3339-timestamp>,
  records:  [ <record>, ... ],
  sig:      Sig,
}
```

`sig` is over the canonical JSON encoding of the page with `sig` omitted.

`prev` is any `Ref` that dereferences to the previous page in this maker's log. In practice it is almost always a `HashRef` (under `cr-content-address`) because content addresses are stable and let consumers verify chain integrity without trusting the publisher. The protocol does not mandate this. Verification properties are inherited from the chosen addressing scheme.

A maker's pages form a linked log. Genesis pages have `prev: null`.

### Invariants

- `sig` verifies against `maker`.
- `prev` is `null` or dereferences to an existing page by the same maker.
- A maker has exactly one genesis page.

A page violating any invariant is rejected; the maker's log ends at the last valid page. When `prev` uses an addressing scheme the consumer does not support, the consumer cannot validate the chain at that point and treats subsequent pages as unverified.

### Addressing-scheme agility within a log

A maker MAY publish a page whose `prev` uses a different `Ref` kind, or a different `alg` within the same kind, than the prior page's natural self-address. The chain is valid as long as the prior page, addressed under the new scheme, matches `prev`. Practical migration: publish under both schemes during transition.

### Capability records

A maker MAY include `cr-capabilities` records in their log declaring which modules they produce content under:

```
{
  ref:      null,
  metadata: {
    types:        [ "cr-capabilities" ],
    capabilities: [ "cr-record", "cr-identity", "cr-multi-device", ... ],
  },
  created:  <rfc3339-timestamp>,
}
```

Latest such record in the log is authoritative.

---

## `cr-multi-device`

**Depends on:** `cr-identity`.

**Contributes:** relaxation of the page log to a DAG, allowing concurrent publication from multiple devices owned by the same maker.

### Snowflake sequence

Pages add a field:

```
seq: <uint64>     // high bits unix-ms, low bits per-device random/counter
```

Strictly increasing per device; globally unordered across devices of the same maker.

### Merge pages

`prev` widens to a list:

```
prev: [ Ref, Ref, ... ] | null
```

Genesis remains `prev: null`. A page with `len(prev) > 1` is a **merge page**, declaring observation of multiple concurrent heads and collapsing them.

Single-device implementations may continue to emit `prev: <Ref>` (singular) for forward compatibility; consumers loading `cr-multi-device` accept both forms.

### Head selection

- **Tips**: pages with no successor in the local view.
- **Effective head**: tip with highest `seq`; ties broken by a stable comparison on the tip's address (lexicographic on `bytes` for hash refs, on `uri` for URI refs, etc.).

Tips converge once the maker publishes merge pages.

---

## `cr-attestation`

**Depends on:** `cr-identity`.

**Contributes:** a sign-once content shape, independent of any maker log.

```
{
  cr-type:  "cr-attestation",
  ref:      Ref,
  signer:   Pubkey,
  created:  <rfc3339-timestamp>,
  metadata: { ... },
  sig:      Sig,
}
```

`sig` is over the canonical encoding with `sig` omitted. No chain, no `prev`. `ref` may be any kind contributed by a loaded addressing module — a bundle hash, a record hash, a URI, a pubkey (endorsing another maker), etc.

Attestations let a signer endorse arbitrary content without committing to a long-lived log.

---

## `cr-metadata-address`

**Depends on:** `cr-record`.

**Contributes:** the `metadata` reference kind, addressing a record inside a container by matching one of its metadata fields.

```
MetadataRef = { kind: "metadata", in: Ref, match: { <string>: <string>, ... } }
```

`match` is a map of metadata-key to expected string value. Resolution dereferences `in` (the container — typically a bundle or page), iterates its records, and returns the unique record for which every `key: value` pair in `match` satisfies `metadata[key] == value` by string equality. The matched fields MUST themselves be strings in the record's metadata; records whose targeted fields are not strings or are missing fail to match.

Example hand-authored form:

```
{ kind: "metadata", in: <some-bundle-ref>, match: { id: "my-bookmark-42" } }
```

Multiple keys narrow the match (intersection); the producer chooses how many keys to use based on what guarantees uniqueness within the container. A single-key match suffices when one key is unique; multi-key allows disambiguation when no single key is.

If no record matches, the ref is unresolvable. If more than one matches, the publisher has violated their uniqueness responsibility; consumers MAY return any matching record, or treat as unresolvable. The framework does not specify which.

The producer is responsible for choosing a metadata key suitable for stable addressing within the container — typically a key whose value they keep unique and unchanging across container revisions for the lifetime of any external reference. Common producer choices include `id`, `slug`, `name`; the module reserves no specific key.

`cr-metadata-address` makes records inside containers addressable without requiring `cr-content-address`. The hand-authorable subset gains record-level granularity: a producer writing a bundle by hand can assign `metadata.id` (or any other key) to entries, and external citations / retractions / revisions reference them via `MetadataRef`.

This kind is location-bearing in the sense that `in` carries the location; the inner lookup is structural equality, not hashing.

---

## `cr-host`

**Depends on:** `cr-content-address` and `cr-identity`.

**Contributes:** an HTTP adapter for hash and pubkey addressing — the two addressing schemes among the common ones that do not carry location information.

URI refs already carry their location; path refs are local. Neither uses `cr-host`. HTTP adapters for other addressing schemes, if wanted, would be sibling modules (`cr-host-foo`), not extensions of this one.

### Endpoints

```
GET /by-hash/<alg>/<hex>           # bytes addressed by hash
GET /head/by-pubkey/<alg>/<hex>    # current head page for a maker
GET /tips/by-pubkey/<alg>/<hex>    # tip refs (cr-multi-device)
GET /capabilities                   # JSON list of loaded modules
```

`GET /by-hash/...` returns any hash-addressed object — blob, record, bundle, page, attestation, future content kinds. The host does not interpret the object; clients identify content by what they asked for. Range requests on blobs supported.

Content types: `application/json` for structured JSON content; `application/octet-stream` for blobs; `application/json` for `/capabilities`.

No auth, no query parameters, no write API. Static file hosting satisfies the requirement exactly: lay out files at the indicated paths.

### Enumeration

`cr-host` does not standardize enumeration ("what's served here"). Hosts wanting to be discoverable beyond known addresses MAY publish enumeration documents at host-chosen URLs; the convention is left to host operators.

---

## `cr-resolve`

**Depends on:** `cr-identity`.

**Contributes:** an abstract mechanism mapping a `Pubkey` to current host URLs and head pointer, with pluggable backend adapters.

### Announcement

```
{
  cr-type:      "cr-resolve-announcement",
  maker:        Pubkey,
  head:         Ref,                 // or `tips: [Ref, ...]` with cr-multi-device
  hosts:        [ string, ... ],
  capabilities: [ string, ... ],     // optional; loaded modules of the announcing implementation
  created:      <rfc3339-timestamp>,
  expires:      <rfc3339-timestamp>,
  sig:          Sig,
}
```

Signed by the maker. Consumers merge announcements from any backend, preferring highest `created` with valid signature and unexpired.

### Adapter interface

```
resolve(pubkey)        → [ Announcement, ... ]
announce(announcement) → ()
```

The adapter is a transport; it does not inspect or modify announcements. Concrete adapters live as sibling modules:

- `cr-resolve-dht-mainline` — BitTorrent mainline DHT via BEP-44.
- `cr-resolve-dht-libp2p` — libp2p Kademlia.
- `cr-resolve-https` — HTTPS rendezvous, GET / POST against a known URL.
- `cr-resolve-static` — JSON file at a well-known URL listing announcements.
- `cr-resolve-nostr` — announcements encoded as Nostr events on relays.

A consumer may load any subset.

---

## `cr-host-announcement`

**Depends on:** `cr-identity`.

**Contributes:** an in-log record type for advertising host URLs without going through `cr-resolve`.

```
{
  ref:      <PubkeyRef of the maker themselves>,
  metadata: {
    types:   [ "cr-host-announcement" ],
    hosts:   [ "https://...", ... ],
    expires: <rfc3339-timestamp>,
  },
  created:  <rfc3339-timestamp>,
}
```

A consumer holding any recent page from the maker consults the most-recent unexpired `cr-host-announcement` for fetching. Falls back to `cr-resolve` if none are present or all expired.

---

## `cr-retraction`

**Depends on:** `cr-identity`.

**Contributes:** advisory retraction.

```
{
  ref:      <Ref to the record being retracted>,
  metadata: {
    types:  [ "cr-retraction" ],
    reason: <string?>,
  },
  created:  <rfc3339-timestamp>,
}
```

Clients SHOULD hide the retracted record from default views. Honored only when issued by the same maker who originally published the retracted record (verified via the containing page's signature). Not deletion: bytes persist; mirrors may continue to serve. No enforcement.

The retraction is meaningful only when the referenced record can be unambiguously identified as the same maker's — typically by `HashRef` to the record's canonical encoding.

---

## `cr-revision`

**Depends on:** `cr-identity`.

**Contributes:** explicit supersession between records, for cases where "the latest in the log wins" is insufficient.

```
{
  ref:      <Ref to the new record>,
  metadata: {
    types:    [ "cr-revision" ],
    replaces: <Ref to the old record>,
  },
  created:  <rfc3339-timestamp>,
}
```

A revision links a new record to one it replaces. Consumers presenting "current state" follow revision chains; the most-recent unrevised record is the current version. Edit timestamps are the new record's `created`.

Revisions are honored only when issued by the same maker who issued the replaced record.

---

## `cr-provenance`

**Depends on:** `cr-record`.

**Contributes:** the reserved metadata key `cr-provenance` for capturing how content came into existence.

A record MAY carry:

```
metadata: {
  cr-provenance: {
    source:       <Ref?>,           // where the content came from (URL, prior record, etc.)
    captured_at:  <rfc3339?>,       // when it was captured (may differ from `created`)
    captured_via: <string?>,        // freeform method: "manual", "scrape", "import-goodreads", ...
    derived_from: [ Ref, ... ]?,    // prior records this was derived or transformed from
    notes:        <string?>,        // freeform additional context
  },
  ...
}
```

All fields are optional; producers fill in what they have. The block is descriptive, not load-bearing for verification — consumers MAY use it for display, deduplication-with-history, re-fetch-on-bitrot, or filtering, but the protocol does not require any specific behavior.

Provenance is distinct from authorship: a signed page's maker is the authorial identity; `cr-provenance` records the content's origin trail independent of who is publishing it. The same external article ingested by two makers will share provenance (same `source`) while having different authors (different signing keys).

For richer provenance graphs — recording each transformation as its own event record linked by edges — use record-records-as-edges (see content-type cookbook) rather than packing arbitrarily-deep history into a single block.

---

## `cr-encryption`

**Depends on:** `cr-record`.

**Contributes:** conventions for ciphertext content.

A record referencing encrypted bytes includes:

```
metadata: {
  cr-encryption: {
    algo:    "xchacha20-poly1305",
    nonce:   <base64 bytes>,
    key_ref: <opaque>,
  },
  ...
}
```

`key_ref` is an opaque application-defined hint for locating the key. Key distribution is explicitly out of scope.

The encrypted bytes are `AEAD(plaintext, key, nonce)`. The record's `created` and other metadata fields remain plaintext.

---

## `cr-successor`

**Depends on:** `cr-identity`.

**Contributes:** record types for declaring key rotation and algorithm migration.

In the old maker's log:

```
{
  ref:      <PubkeyRef of new maker>,
  metadata: { types: [ "cr-successor" ] },
  created:  <rfc3339-timestamp>,
}
```

In the new maker's genesis page (recommended for mutual confirmation):

```
{
  ref:      <PubkeyRef of old maker>,
  metadata: { types: [ "cr-predecessor" ] },
  created:  <rfc3339-timestamp>,
}
```

Mutual declaration prevents one-sided hijack claims. A `cr-successor` alone is a *claim*; client policy decides whether to honor unconfirmed claims.

---

# Open questions

- Final module-prefix decision (`cr-` vs. successor name).
- Whether to introduce a composite reference kind that fuses location and verification (e.g. `{kind: "hashed-uri", uri, alg, bytes}`) instead of always expressing it as `HashRef` + `cr-mirrors: [UriRef, ...]`. Current draft: no composite kind. Can be added if the unsweetened form proves awkward.
- A content-type cookbook (sticky notes, markdown, images, bookmarks, code, curated lists, game references, social profiles) — non-normative; not yet drafted.
- Whether `cr-resolve` should specify a minimum announcement retention / re-announce cadence, or leave entirely to adapters. Current draft: leaves to adapters.
- Whether `cr-blob` should exist at all, or is so thin that opaque bytes are simply "what content addressed via any scheme yields when the consumer doesn't load a structuring module." Current draft: exists, as a name.
