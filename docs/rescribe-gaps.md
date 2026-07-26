# rescribe IR gap analysis (from crescent's use cases)

Status: research note, not a commitment.

**Corrected framing (2026-07-26), per feedback from rescribe's maintainers:**
this document was originally written on the premise that `rescribe::Document`
might become crescent's canonical document representation, with `lib/unified`
(mdast/hast) as a compatibility layer. That premise is wrong and is corrected
here rather than silently dropped:

- **`rescribe::Document` should not become crescent's canonical PDF
  representation.** There is no `pdf-fmt` crate in rescribe, PDF is not
  queued in rescribe's vertical order, and waiting on rescribe to grow
  PDF-native vocabulary (positioned text, form fields, page containers — see
  gaps 1-4 below) means waiting on a vertical that doesn't exist and isn't
  next in rescribe's own sequencing.
- **crescent's PDF models stay authoritative.** `lib/pdf/text.lua`'s `Span`
  and `lib/pdf/form.lua`'s `FormField` are the source of truth for PDF
  structure in crescent, not a stopgap awaiting replacement. They already
  solve the reference/identity problem that gap 2 below identifies (one
  field, many widgets, one shared value) — by flattening, not by leaving it
  unsolved.
- **`rescribe::Document` is an optional interchange target**, useful where a
  pipeline's non-PDF-specific parts benefit from a shared IR — e.g. a
  Markdown/HTML/DOCX conversion step that also happens to touch PDF output at
  its edges. It is a target crescent can route *through* when convenient, not
  a representation crescent's PDF libraries route *into*.
- **If a crescent pipeline does route PDF data through `rescribe::Document`**,
  attaching `crescent:x`, `crescent:y`, `crescent:reading_order_index`, etc.
  is crescent's job, per rescribe's open-extensibility model (see below) —
  not something to wait on rescribe to standardize first.
- **Two small items below are worth raising with rescribe directly**, as
  non-vertical drive-by fixes rather than as part of a PDF-vertical ask: the
  RTF `lang` namespacing collision (gap 3 — a one-line bug fix, not a feature
  request) and documenting the ID/reference convention (closing theme below)
  as a named pattern, since there's already precedent for it in rescribe's
  own codebase, just unwritten.
- **rescribe's own sequencing rule — "don't invest in level 3/4 while level 1
  has gaps" — is aimed at rescribe's maintainers deciding what to build
  next**, not at crescent. It correctly blocks new verticals (a `pdf-fmt`
  crate, a `rescribe-forms` crate) from jumping the queue. It does not block
  small, scoped fixes like the two above that don't add a vertical or expand
  scope.

The technical gap analysis below (spatial layout, form fields, accessibility,
pagination, etc.) is unchanged and still accurate — it documents what
`rescribe::Document` can and can't express today, which is useful background
for the interchange-target and drive-by-fix decisions above even though it no
longer informs an IR-evolution roadmap.

Sources read for this analysis:
- rescribe: `crates/rescribe-core/src/{document,node,properties,fidelity,resource,traits}.rs`,
  `crates/nodes/rescribe-std/src/lib.rs`, `crates/nodes/rescribe-math/src/lib.rs`,
  `CLAUDE.md`, `docs/document-model.md`, `docs/spec.md`, `FORMATS.md`,
  `docs/format-audit.md`, `TODO.md`.
- crescent: `lib/pdf/text.lua`, `lib/pdf/form.lua`, `lib/unified/hast/init.lua`,
  `lib/unified/mdast/init.lua`, `docs/roadmap-v2.md` (§2a, §2d, §4a).

## How rescribe's extensibility actually works (baseline for every gap below)

Before listing gaps, the two escape hatches that make most of them "maybe not
a gap at all" need to be named precisely, because they change the verdict for
almost every item:

1. **`NodeKind` is an open string newtype.** Any code, including crescent's,
   can construct `Node::new("crescent:text_span")` without touching rescribe's
   crates. No registration, no enum change.
2. **`Properties` is an open `HashMap<String, PropValue>`.** Same deal —
   `node.prop("crescent:x", 123.4)` works today, no rescribe change needed.
   `PropValue` itself is closed (`String | Int | Float | Bool | List | Map`,
   see `properties.rs`), which matters for a few gaps below (no native
   fixed-point/decimal, no native 2D-matrix type).

So the real question per gap is never "can I express this at all" — the
properties bag makes everything expressible. It's:

- **(a) Convention only** — crescent can just start using a `crescent:`
  namespace today, no rescribe involvement needed. Not a gap in rescribe's
  IR; a gap in *documented, shared vocabulary* at most.
- **(b) Missing standard vocabulary** — the construct is common enough across
  formats/consumers that it belongs in `rescribe-std` (or a new
  `rescribe-a11y` / `rescribe-forms` crate) as a named constant, the way
  `style:*` and `layout:*` already are, so two independent consumers don't
  invent two different property names for the same thing. Low cost, no IR
  structural change.
- **(c) Structural gap** — the tree/property model itself can't express the
  relationship (e.g. a non-tree reference, a typed geometric value, a
  per-node numeric array with defined semantics) without everyone
  reinventing an ad hoc encoding inside a string or `PropValue::List`.

Every gap below is tagged with one of these three, plus which crescent use
case it blocks and how badly.

## 1. Spatial / geometric text layout (PDF text extraction)

**What crescent has:** `lib/pdf/text.lua` produces `Span = { text, x, y,
font_name }` per text-showing operation, in PDF user-space coordinates
(post-CTM, post-text-matrix, section 9.4 of ISO 32000-1), plus
`M.spans_to_reading_order` which groups spans into `Line = { y, spans }` by a
fixed Y-tolerance and sorts each line left-to-right. This is the entire
reading-order reconstruction: there is no upstream "layout engine" — order is
*derived from geometry*, per-page, per-span.

**What rescribe models:** Nothing geometric. `Node.span: Option<Span>` exists
but `Span { start: usize, end: usize }` (`node.rs`) is a *source byte range*
for error reporting, not a page position — same field name, unrelated
concept. There is no x/y, no page-space matrix, no font size at the node
level (`style:size` exists as a `PropValue`, i.e. an opaque number with no
unit contract). `layout:page_break`, `layout:column`, `layout:float` exist as
property *keys* but are unimplemented placeholders — no reader or writer in
the audited code sets or reads them.

**Verdict: (b) for the simple case, (c) for the general case.**
- A `Span`-per-node model — `crescent:x`, `crescent:y`, `crescent:font_size`
  as flat `Float` props on a `paragraph` or a new `text_run` node kind — fits
  today's `Properties` bag with zero IR change. This covers what
  `lib/pdf/text.lua` currently produces.
- What doesn't fit cleanly: PDF text is naturally **pre-reading-order** —
  spans arrive in content-stream order, and *reconstructing* reading order
  from (x, y) is domain logic crescent already owns
  (`spans_to_reading_order`). rescribe's `Node` tree has no way to represent
  "these children are positioned, order not yet resolved" vs. "this is the
  logical reading order" as two different states of the same subtree. If
  rescribe's PDF reader is expected to do what crescent's does — walk a
  content stream and hand back semantically-ordered blocks — the geometry
  that justified that ordering decision gets thrown away unless it's kept as
  a property on each node. There's no modeled concept of "this node's
  position is provisional / derived" vs. "this node's position is the
  authored layout" (relevant for RTF/DOCX where explicit layout is authored,
  vs. PDF where layout *is* the only signal there is).
- Also missing (b): page dimensions (MediaBox), and *which page* a node
  belongs to. `Document.content: Node` is one tree with no first-class page
  boundary concept — a `page` node kind doesn't exist in `rescribe-std`. A
  `page` block containing positioned children is a reasonable node-kind
  addition; nothing in the IR currently distinguishes "this content belongs
  to a page" the way `lib/pdf/text.lua`'s `document_to_text` returns one
  result array element per page.

**Priority:** Not blocking — crescent's PDF text-extraction path
(`lib/pdf/text.lua`) stays on its own `Span` records; it does not route
through `rescribe::Document`. This gap only matters for the optional case
where a pipeline chooses to interchange PDF-derived data through rescribe
(e.g. feeding extracted text into a Markdown/HTML conversion step) and wants
to carry position/reading-order alongside it — in that case, attaching
`crescent:x`/`crescent:y`/`crescent:reading_order_index` per the open
`Properties` model is crescent's job, not a rescribe IR ask.

## 2. Interactive form fields (PDF AcroForm)

**What crescent has:** `lib/pdf/form.lua`'s `FormField` record: `name`
(dot-qualified field-tree path), `type` (`text | checkbox | radio | choice |
signature | pushbutton | unknown`), `value`/`default_value` (arbitrary PDF
object, not just strings — could be a name, a stream ref, etc.), `flags`
(raw `/Ff` bitfield), `page`, `rect` (four numbers, widget bounding box),
`field_num`/`field_gen` (identity for round-trip filling). Critically: one
field can have **multiple widgets** (radio groups, a checkbox repeated
across pages) sharing one logical value — the module documents this
explicitly and flattens to one record per widget rather than nesting.

**What rescribe models:** Nothing. No form-field node kind exists in
`rescribe-std`, `rescribe-math`, or core. Grepping the vocabulary in
`lib.rs`: no `text_input`, `checkbox`, `radio`, `choice`, `signature`, no
`prop::CHECKED`-equivalent for form state (there is a `prop::CHECKED` but its
doc comment says "Task list item checked state" — Markdown `- [x]` checkbox,
a different concept from an AcroForm widget's `/AS` appearance state).

**Verdict: (b), with one structural wrinkle (c).**
- Field type, name, value as a `Node` kind (`form_field` or split kinds per
  type) with `Properties` (`crescent:field_type`, `crescent:default_value`,
  `crescent:flags`) fits the open model fine — this is exactly the kind of
  vocabulary gap `rescribe-std` exists to fill incrementally (compare:
  `math` got its own crate rather than overloading `rescribe-core`; forms
  plausibly deserve the same, since the vocabulary is sizeable — field
  types, validation, appearance state names).
- The wrinkle: **one field, multiple widgets, one shared value** is a
  many-node-share-one-identity relationship. A `Node` tree has no reference
  type — nodes only relate by parent/child. crescent's own model sidesteps
  this by flattening (each widget is a full record repeating the field's
  attributes) rather than solving it structurally. rescribe could do the
  same (repeat field-level props on every widget node) and that's probably
  fine for read-only extraction — but it breaks for **round-trip
  filling**, where setting one field's value must update every widget's
  node consistently. Pandoc-style tree mutation assumes each semantic fact
  lives in exactly one place; AcroForm's field/widget split violates that.
  This isn't blocking today (crescent's own `fill_fields` walks the PDF
  object graph directly, not through any AST), but if rescribe's IR is
  meant to be the *editable* representation forms round-trip through, the
  one-fact-many-nodes problem needs an answer — likely an ID/reference
  convention (`crescent:field_id` shared across widget nodes) documented as
  a pattern, since `Properties` can carry an ID but the IR has no built-in
  notion that two nodes with the same ID-prop are the same logical entity.
- Signature fields: crescent's form module explicitly refuses to fill them
  (cryptographic signing is out of scope) but still reports them as a
  distinct type. No IR-level concept blocks this — `type: "signature"` as a
  string prop is enough. Non-issue.

**Priority:** Not blocking — crescent's forms path (`lib/pdf/form.lua`) and
2d's form/document structure work stay on crescent's PDF-native `FormField`
records, which already solve the field/widget identity wrinkle above by
flattening. This section is retained because it's the clearest illustration
of the closing theme below (a reference/ID convention rescribe hasn't named),
not because rescribe needs a `rescribe-forms` crate before crescent can
proceed — that would be exactly the kind of new-vertical ask rescribe's own
sequencing rule (level 1 gaps before level 3/4 investment) correctly defers.

## 3. Accessibility metadata (WCAG, tagged PDF, alt text, reading order, language)

**What crescent needs (from roadmap 2d, 4a):** heading hierarchy validation,
alt-text presence, form label association, reading-order annotations
independent of visual layout, per-element language tags, WCAG role mapping
(PDF's `/StructTree` tag types: `H1`-`H6`, `P`, `L`/`LI`, `Table`/`TR`/`TD`,
`Figure`, `Caption`, etc. — ISO 32000's tagged-PDF structure, not yet
implemented in crescent but named as a target).

**What rescribe models:**
- **Alt text: present.** `prop::ALT` exists, used on `image`. Good — direct
  hit, no gap.
- **Language: absent as general vocabulary, present as one-off inline
  node.** `rtf-fmt`'s IR mapping produces `Inline::Lang` → (per `TODO.md`)
  "language tags... LCID→BCP-47 adapter" flowing into the IR, but grepping
  `rescribe-std`'s `prop` module directly: there's no `prop::LANG` constant.
  So *a* format's adapter established a convention ad hoc; it isn't
  standardized where a second format (or crescent's HTML/PDF path) would
  discover and reuse it. This is exactly the "vocabulary gap, not structural
  gap" case — cheap to fix (add `prop::LANG`), currently unfixed. **This is
  one of the two items worth raising with rescribe directly** (see corrected
  framing at top): `rtf-fmt` producing an unnamespaced `Inline::Lang` node
  outside the `prop::*` convention every other format's adapter follows is a
  namespacing bug in `rtf-fmt` itself, not a request for new rescribe
  vocabulary — a one-line fix (route it through `prop::LANG`, adding that
  constant), independent of any PDF vertical.
- **WCAG/structural role (heading semantics, list semantics, table
  semantics): implicit via node kind, not explicit as a role.** `heading` +
  `level` already carries H1-H6 semantics; `list`/`list_item`,
  `table`/`table_row`/`table_cell` already carry WCAG-relevant structure.
  This is *better* than raw HTML in one sense (a `heading` node kind is
  intrinsically the right ARIA role, no attribute to infer) but has no
  explicit "this is a landmark/region" or "this is decorative and should be
  hidden from assistive tech" concept — HTML's `role="presentation"` /
  `aria-hidden` equivalent doesn't exist as vocabulary. `node::HIDDEN`
  exists but its doc comment says "present in document but not displayed" —
  a rendering concept (RTF's `\v` hidden text), not an accessibility-tree
  concept. Different semantics wearing the same word; a real collision risk
  if both meanings get used without a documented split.
- **Reading order independent of visual/tree order: absent.** This is the
  same gap as §1's "provisional vs. authored order" — tagged PDF's whole
  point is that the *logical structure tree* can differ from the *content
  stream's paint order*, and a remediation tool's job is often to construct
  or correct the logical tree without changing the visual one. rescribe's
  `Node.children: Vec<Node>` is a single order — there's no second,
  independent ordering a reader/writer round-trips separately. Representable
  today only by inventing an `crescent:reading_order_index` prop (a workaround
  that then needs every consumer to know to sort by it instead of trusting
  tree order — the kind of shared vocabulary gap in (b), except the
  underlying reason it's needed is the structural gap in §1).
- **Form label association (`<label for>` / PDF `/TU` tooltip-as-label):
  absent.** No property carries "this text node names that form-field
  node." Same reference-vs-tree-position problem as §2's field/widget split
  — labels-for-fields is another many-to-one relationship a pure tree can't
  express positionally (a label is rarely the field's parent or child in
  either HTML or PDF).

**Verdict:** Mostly (b) — add `prop::LANG`, a documented `role`/`aria_hidden`
distinction from the existing `HIDDEN` kind, and a `crescent:for`-style
labeling-reference convention. One real (c): logical vs. visual reading
order needs either a second explicit ordering mechanism or an accepted
convention that node order in tagged/remediated documents means logical
order and geometry (§1's x/y props) is the only place visual order lives —
which is a workable convention, but it's a design decision rescribe hasn't
made, not one crescent can silently assume it made.

**Priority:** Not blocking for PDF — 4a (accessibility tooling) and 2d's
WCAG-check work run against crescent's own PDF/HTML structures, not a
rescribe `Document`. This gap only matters if a future pipeline chooses to
route accessibility-relevant data through rescribe as an interchange
target — in which case the language/role/label-association vocabulary here
would need to be crescent-side `crescent:*` props (per the open `Properties`
model) rather than a rescribe standardization ask, with the one exception
already called out above (`prop::LANG` as a genuine drive-by fix, since it's
a one-constant addition fixing an existing namespacing inconsistency, not new
vertical scope).

## 4. Page breaks / pagination

**What rescribe has:** `prop::LAYOUT_PAGE_BREAK` — a key exists, but no
reader or writer in the audited crates sets or consumes it (grep of
`format-audit.md`/`FORMATS.md` shows no pagination column). It's a
placeholder, not a working feature.

**What crescent needs:** `lib/pdf/text.lua`'s `document_to_text` already
partitions results into one array entry per page — pagination is not a
"maybe someday" for PDF, it's the top-level unit results come back in today.
A remediated/generated PDF (roadmap 2a's still-open "no PDF generation from
scratch" item) will need explicit page objects with dimensions, not just
break markers between flowing content.

**Verdict: (b) for a break-marker model (already half-exists, just unused);
(c) if crescent needs actual page *objects* (dimensions, per-page resources,
explicit page membership) rather than a break marker in a flow — which
matches PDF's actual model (pages are containers, not a stream with break
markers) better than the flow-with-breaks model implied by
`layout:page_break`'s naming. This is the same page-node gap named in §1.

**Priority:** Not blocking — 2a's text-extraction path already produces
per-page grouping on its own `Span`/document model and any future PDF-writing
path stays on crescent's own PDF object model, not a rescribe `Document`.
Relevant only to the optional-interchange case.

## 5. Embedded media (audio, video)

**What rescribe has:** Nothing. No `audio`/`video` node kind in
`rescribe-std`. `Resource` (binary blob + MIME type + metadata) is fully
general-purpose and already handles arbitrary embedded binaries (images,
fonts) — extending to audio/video is just adding a node kind that references
a `ResourceId`, exactly like `image` does via `prop::RESOURCE_ID`.

**Verdict: (b), trivial.** No crescent use case in the audited docs
currently needs this (not mentioned in roadmap 2a/2d/4a), so this is a
non-gap in practice — flagged only because the task asked about it
explicitly. Low priority, easy if/when needed.

## 6. Annotations / comments

**What rescribe has:** Nothing modeled. `docx:comment` is listed as an
*example* format-specific `NodeKind` string in `document-model.md`'s
illustrative code, but there's no evidence it's actually implemented
anywhere (not in `rescribe-std`, not mentioned in `format-audit.md`).

**What crescent might need:** Not currently — `lib/pdf/form.lua` and
`lib/pdf/text.lua` don't touch PDF annotations beyond Widget annotations
(form fields, which §2 already covers) and don't touch review comments/
sticky notes. Not named in roadmap 2a/2d/4a.

**Verdict: (b), speculative — no concrete crescent need surfaced in the
sources read.** Worth flagging because "docx:comment" appearing only as
prose example, not as a real implemented kind, is itself a small signal:
rescribe's comment support may be aspirational documentation, not built
vocabulary. Confirm against `rescribe-read-docx` directly before relying on
it if a future crescent use case needs comment round-trip.

## 7. Mathematical content (MathML / LaTeX math)

**What rescribe has:** A dedicated `rescribe-math` crate — genuinely
thorough: `math_inline`/`math_display`, structural (`fraction`, `root`,
sub/superscript variants), containers (`matrix`, `fenced`, `math:table`),
semantic leaves (`operator`, `identifier`, `number`), decorations (`accent`,
`brace`, `strike`, `enclosed`), plus `math:format`/`math:source` for raw
preservation. This is the most complete, purpose-built vocabulary area in
rescribe among everything audited.

**What crescent needs:** `lib/unified/rehype_katex/` exists (KaTeX
rendering for hast), `remark_math/` exists (mdast math nodes) — so crescent
already has a working math AST path in its own vocabulary. Not audited
node-by-node against `rescribe-math` in this pass, but the shapes look
structurally compatible (both distinguish inline/display, both have
fraction/root/sub/sup concepts) — this looks like the smallest gap of any
area covered here, likely just needs a field-by-field mapping check, not new
rescribe substrate.

**Verdict: no gap identified.** Flagged as the one area to spot-check for
mapping fidelity rather than to request new IR work.

## 8. Fixed-point / decimal numeric precision

**Not asked for explicitly but surfaced by reading `properties.rs`:**
`PropValue` has `Int(i64)` and `Float(f64)` only — no decimal/fixed-point
variant. crescent's `lib/decimal` and `lib/finance` (roadmap 2c,
bookkeeping) exist specifically because `f64` loses precision for money.
This isn't a document-structure gap in the sense the task asked about, but
if a future crescent use case represents a *table of monetary values* as a
`rescribe::Document` (e.g. bank-statement PDF → structured table via 2a/2c),
`style:size`-style `Float` props would silently reintroduce the exact
precision bug `lib/decimal` was built to avoid. Worth a one-line flag: no
action needed unless/until bookkeeping data crosses through this IR.

**Verdict: (c), narrow — `PropValue`'s enum is closed over `String | Int |
Float | Bool | List | Map`; a `Decimal(String)` (store as canonical decimal
string, format-agnostic) would need a core enum change, not just new
vocabulary, since callers can't extend `PropValue`'s variants themselves the
way they can extend `NodeKind` or property *keys*. Only relevant if 2c
(bookkeeping) ever needs to move monetary tables through this IR — not
currently in scope for anything audited.**

## Summary table

Per the corrected framing at the top, none of these actually block a crescent
roadmap item — crescent's PDF models stay native. The "Relevant if
interchanged" column names what would need `crescent:*` props (or, for the
two starred rows, an actual rescribe-side fix) only in the optional case
where a pipeline routes PDF-derived data through `rescribe::Document`.

| Gap | Kind | Relevant if interchanged | Fix cost |
|---|---|---|---|
| Positioned text (x/y, font size, page-space) | (b) props; (c) provisional-vs-authored order | text extraction | Low for props; open design question for ordering |
| Page as a first-class container/boundary | (b)/(c) | future PDF writing | Low-medium — new node kind |
| Form fields (type/name/value/rect) | (b) | forms, doc structure | Low — new vocabulary, maybe new crate |
| Field↔widget shared identity (1 field, N widgets) | (c) | round-trip form filling only | Needs a reference/ID convention, not core-type change |
| Language tag as standard prop | (b) | accessibility, WCAG | *Trivial — add `prop::LANG` (drive-by fix, see top) |
| Explicit accessibility role / aria-hidden vs. `HIDDEN` | (b), naming collision risk | accessibility | Low — needs disambiguation, not new machinery |
| Logical (tagged) reading order vs. visual order | (c) | accessibility, remediation | Needs a second ordering mechanism or documented convention |
| Label↔field association | (c), same shape as field/widget | form labels | *Same reference-convention need as above (drive-by doc fix, see top) |
| Embedded audio/video | (b) | none identified yet | Trivial, low priority |
| Annotations/comments | (b), possibly not even built yet | none identified yet | Unclear — verify `rescribe-read-docx` first |
| Math | none found | — | Spot-check mapping only |
| Decimal-precision property value | (c), core enum | none identified yet | Only if bookkeeping data ever crosses this IR |

## The one structural theme across most (c) items

Every genuinely structural gap here — provisional vs. authored reading
order, field/widget identity sharing, label/field association — is the same
underlying shape: **rescribe's `Node` tree assumes one node's position in
the tree is its only relationship to the rest of the document.** That's true
for Pandoc-style prose (a paragraph's meaning doesn't depend on some other
non-adjacent node) but false for exactly the constructs crescent's PDF work
deals with: PDF form fields are graph-shaped (shared field, multiple
widgets, associated label, associated page), and tagged-PDF/WCAG remediation
needs a logical structure that's allowed to diverge from paint order.
crescent's own `FormField` model already answers this for its own purposes
(flatten one record per widget, no shared-reference machinery needed) — the
open question is only whether rescribe wants a *named* answer for its own
consumers.

A `Properties`-carried ID/reference convention can paper over this without a
core-type change, but it's currently undocumented — every consumer that
needs it would invent its own key name unless rescribe names one first, the
same problem `style:*`/`layout:*` namespacing already solved for style and
layout. **This is the second of the two items worth raising with rescribe
directly** (alongside the `prop::LANG` / RTF namespacing fix above): not as
a PDF-forms feature request, but as "document the ResourceId-style
ID/reference pattern as a named convention" — there's already precedent for
exactly this shape in rescribe's own codebase (`ResourceId` linking a node to
a `Resource`), it just hasn't been generalized and written down as a pattern
other node kinds can reuse. That's a documentation-and-naming task rescribe's
maintainers can pick up independent of any vertical sequencing, not a
structural IR change and not something crescent needs before proceeding —
crescent's PDF models don't need rescribe to name this convention in order to
keep working.
