# lib/unified — Ecosystem Completeness

Port of the [unified.js](https://unifiedjs.com/) ecosystem to Lua. All packages live
under `lib/unified/` and are require-able as `lib.unified.<name>`.

## Core

| Package | JS reference | Status | Notes |
|---|---|---|---|
| `unified` | [unified](https://github.com/unifiedjs/unified) | ✅ done | parse/run/stringify/process, freeze/clone, plugin chain |

Not ported (intentional):
- **vfile** — virtual file abstraction. Lua scripts don't need I/O decoupled via a vfile object; processors store metadata on `root.data` instead.

## Markdown (mdast / remark)

| Package | JS reference | Status | Notes |
|---|---|---|---|
| `mdast` | [mdast](https://github.com/syntax-tree/mdast) | ✅ done | CommonMark parser; setext/blockquotes/list-items 100%; lists 96%; emphasis 95%; links 88%; images 59% |
| `remark` | [remark](https://github.com/remarkjs/remark) | ✅ done | Markdown preset (parse + stringify) |
| `remark_rehype` | [remark-rehype](https://github.com/remarkjs/remark-rehype) | ✅ done | mdast→hast bridge plugin |
| `remark_gfm` | [remark-gfm](https://github.com/remarkjs/remark-gfm) | ✅ done | tables, strikethrough, task lists, autolinks |
| `remark_math` | [remark-math](https://github.com/remarkjs/remark-math) | ✅ done | `$...$` inline, `$$...$$` block; pre-parse placeholder trick for backslashes |
| `remark_directive` | [remark-directive](https://github.com/remarkjs/remark-directive) | ✅ done | `:name`, `::name`, `:::name` (tight + loose containers) |
| `remark_footnotes` | [remark-footnote](https://github.com/remarkjs/remark-footnote) | ✅ done | `[^ref]` references + `[^ref]: text` definitions |
| `remark_frontmatter` | [remark-frontmatter](https://github.com/remarkjs/remark-frontmatter) | ✅ done | YAML (`---`) and TOML (`+++`) |
| `remark_toc` | [remark-toc](https://github.com/remarkjs/remark-toc) | ✅ done | TOC list inserted after marker heading |
| `remark_emoji` | [remark-emoji](https://github.com/rhysd/remark-emoji) | ✅ done | ~55 shortcodes; ASCII emoticon opt-in |
| `remark_breaks` | [remark-breaks](https://github.com/remarkjs/remark-breaks) | ✅ done | softBreak → hardBreak |
| `remark_squeeze_paragraphs` | [remark-squeeze-paragraphs](https://github.com/remarkjs/remark-squeeze-paragraphs) | ✅ done | removes empty/whitespace-only paragraphs |

Not yet ported:
- **remark-lint** — linting framework + rule suite (~60 rules). Large surface; skip until there's a real use case.
- **remark-inline-links** — convert reference links to inline. Minor utility.
- **remark-defsplit** — convert inline links to references. Minor utility.
- **remark-github** — auto-link GitHub references (`#123`, `@user`, `org/repo`). Useful for repo-related tooling.
- **remark-abbr** — `*[abbr]: expansion` abbreviation syntax.
- **remark-attr** — add HTML attributes to markdown elements (`{.class #id key=val}`).
- **remark-code-title** — ```` ```js title.js ```` fenced code title extraction.

## HTML (hast / rehype)

| Package | JS reference | Status | Notes |
|---|---|---|---|
| `hast` | [hast](https://github.com/syntax-tree/hast) | ✅ done | HTML AST; `from_mdast`, `to_html`. Uses `tag`/`props` (not `tagName`/`properties`) |
| `rehype` | [rehype](https://github.com/rehypejs/rehype) | ✅ done | HTML preset; stub parser + hast serializer |
| `rehype_slug` | [rehype-slug](https://github.com/rehypejs/rehype-slug) | ✅ done | id attributes on h1–h6 |
| `rehype_autolink_headings` | [rehype-autolink-headings](https://github.com/rehypejs/rehype-autolink-headings) | ✅ done | wrap/prepend/append anchor links |
| `rehype_external_links` | [rehype-external-links](https://github.com/rehypejs/rehype-external-links) | ✅ done | target/rel on external hrefs |
| `rehype_sanitize` | [rehype-sanitize](https://github.com/rehypejs/rehype-sanitize) | ✅ done | allowlist XSS filter; GitHub-flavored default schema |
| `rehype_highlight` | [rehype-highlight](https://github.com/rehypejs/rehype-highlight) | ✅ done | syntax highlighting; lua/js/python/json/bash tokenizers |
| `rehype_format` | [rehype-format](https://github.com/rehypejs/rehype-format) | ✅ done | pretty-print with configurable indent |
| `rehype_minify` | [rehype-minify](https://github.com/rehypejs/rehype-minify) | ✅ done | whitespace collapsing; preserves `<pre>` |
| `rehype_shift_heading` | [rehype-shift-heading](https://github.com/rehypejs/rehype-shift-heading) | ✅ done | shift heading levels ±N, clamped h1–h6 |
| `rehype_add_classes` | [rehype-add-classes](https://github.com/nicktindall/rehype-add-classes) | ✅ done | add CSS classes to matched tag names |
| `rehype_figure` | [rehype-figure](https://github.com/josestg/rehype-figure) | ✅ done | standalone `<img>` → `<figure><figcaption>` |
| `rehype_section` | [rehype-section](https://github.com/mattdesl/rehype-section) | ✅ done | wrap heading+content in `<section>` |
| `rehype_document` | [rehype-document](https://github.com/rehypejs/rehype-document) | ✅ done | wrap in `<!doctype html><html><head><body>` |
| `rehype_accessible_emojis` | [rehype-accessible-emojis](https://github.com/GaiAma/Coding4GaiAma/tree/master/packages/rehype-accessible-emojis) | ✅ done | emoji → `<span role="img" aria-label>` |
| `rehype_urls` | [rehype-urls](https://github.com/brechtcs/rehype-urls) | ✅ done | transform href/src/action/data via callback |
| `rehype_infer_title` | [rehype-infer-title](https://github.com/rehypejs/rehype-infer-title) | ✅ done | `root.data.title` from first heading |
| `rehype_infer_description` | [rehype-infer-description](https://github.com/rehypejs/rehype-infer-description) | ✅ done | `root.data.description` from first paragraph |
| `rehype_katex` | [rehype-katex](https://github.com/remarkjs/remark-math/tree/main/packages/rehype-katex) | ✅ done | math nodes → span/div wrappers; browser renders via KaTeX/MathJax |
| `rehype_raw` | [rehype-raw](https://github.com/rehypejs/rehype-raw) | ✅ done | parse `{type="html"}` raw strings into hast elements |
| `rehype_meta` | [rehype-meta](https://github.com/rehypejs/rehype-meta) | ✅ done | inject title/meta/og/twitter into `<head>` |
| `rehype_remove_comments` | [rehype-remove-comments](https://github.com/rehypejs/rehype-remove-comments) | ✅ done | strip comment nodes; opts.preserve callback for selective retention |
| `rehype_xast` | [rehype-xast](https://github.com/rehypejs/rehype-xast) | ✅ done | hast→xast bridge; raw→text (no XML round-trip); boolean props as name=name |

Not yet ported:
- **rehype-parse** — full HTML string → hast parser. `rehype_raw` covers the most common case (embedded HTML in Markdown). A full HTML parser is a larger project (`lib/html` or similar).
- **rehype-prism** / **rehype-shiki** / **rehype-starry-night** — alternative syntax highlighters. `rehype_highlight` covers the common case with a built-in tokenizer; these require bundling external grammars.
- **rehype-rewrite** — rewrite hast nodes via selector API. Requires `unist-util-select` equivalent.
- **rehype-toc** — rehype-side TOC (inserts `<nav>` from headings). Overlaps with `remark_toc`; lower priority.
- **rehype-responsive-table** — wrap tables in a scrollable container. Trivial.

## Natural Language (nlcst / retext)

| Package | JS reference | Status | Notes |
|---|---|---|---|
| `nlcst` | [nlcst](https://github.com/syntax-tree/nlcst) | ✅ done | Root/Paragraph/Sentence/Word/Punctuation/Whitespace/Text node constructors + `to_text` |
| `retext` | [retext](https://github.com/retextjs/retext) | ✅ done | NL processing preset; frozen, clone-on-use |
| `retext_english` | [retext-english](https://github.com/retextjs/retext/tree/main/packages/retext-english) | ✅ done | English tokenizer; paragraph→sentence→word/punct/whitespace |
| `retext_readability` | [retext-readability](https://github.com/retextjs/retext-readability) | ✅ done | Flesch, Flesch-Kincaid, Gunning Fog; naive syllable counting |
| `retext_keywords` | [retext-keywords](https://github.com/retextjs/retext-keywords) | ✅ done | TF extraction; 100-word stopword list |
| `retext_sentiment` | [retext-sentiment](https://github.com/retextjs/retext-sentiment) | ✅ done | AFINN-111 scoring; comparative normalization |
| `retext_passive` | [retext-passive](https://github.com/retextjs/retext-passive) | ✅ done | be-verb + past participle; gap-word variant |
| `retext_simplify` | [retext-simplify](https://github.com/retextjs/retext-simplify) | ✅ done | ~50 complex→simple word suggestions |
| `retext_equality` | [retext-equality](https://github.com/retextjs/retext-equality) | ✅ done | ~40 biased/insensitive term flags |
| `retext_contractions` | [retext-contractions](https://github.com/retextjs/retext-contractions) | ✅ done | missing apostrophe detection; smart/straight quote opts |
| `retext_repeated_words` | [retext-repeated-words](https://github.com/retextjs/retext-repeated-words) | ✅ done | consecutive repeated word detection; punctuation resets chain |
| `retext_indefinite_article` | [retext-indefinite-article](https://github.com/retextjs/retext-indefinite-article) | ✅ done | a/an checker; silent-h table; you-sound u-words; abbreviation letter-sounds |
| `retext_intensify` | [retext-intensify](https://github.com/retextjs/retext-intensify) | ✅ done | 45-word weasel-word list; opts.ignore |
| `retext_sentence_spacing` | [retext-sentence-spacing](https://github.com/retextjs/retext-sentence-spacing) | ✅ done | inter-sentence whitespace check; opts.preferred (default 1) |

Not yet ported:
- **retext-spelling** — spell checking. Requires a word list (~100K entries). Worth doing once `lib/compress` exists (to ship a compressed dictionary).
- **retext-overuse** — word overuse detection. Overlaps with `retext_keywords`.
- **retext-quotes** — check quote style (straight vs curly). Mostly covered by `retext_contractions`.
- **retext-diacritics** — suggest diacritics (café vs cafe). Needs a lookup table.
- **retext-dutch** / **retext-latin** — non-English language parsers. Stretch goal.

## XML (xast)

| Package | JS reference | Status | Notes |
|---|---|---|---|
| `xast` | [xast](https://github.com/syntax-tree/xast) | ✅ done | element/text/comment/doctype/instruction/cdata constructors + `to_xml` serializer |
| `xast_util_to_xml` | [xast-util-to-xml](https://github.com/syntax-tree/xast-util-to-xml) | ✅ done | standalone serializer; quote/self-closing/xml-declaration opts |

Not yet ported:
- **xast-util-from-xml** — XML string → xast parser. Requires a full XML parser (`lib/xml` or similar).
- **xast-util-visit** — tree visitor for xast. See unist-util-visit below.

## Unist utilities (shared tree utilities)

| Package | JS reference | Status | Notes |
|---|---|---|---|
| `unist_util_visit` | [unist-util-visit](https://github.com/syntax-tree/unist-util-visit) | ✅ done | depth-first visitor; SKIP/EXIT/REMOVE signals; with_parents variant |
| `unist_util_find` | [unist-util-find](https://github.com/syntax-tree/unist-util-find) | ✅ done | find first node matching type or predicate |
| `unist_util_filter` | [unist-util-filter](https://github.com/syntax-tree/unist-util-filter) | ✅ done | filter tree to matching nodes, returning new tree |
| `unist_util_map` | [unist-util-map](https://github.com/syntax-tree/unist-util-map) | ✅ done | map over tree nodes returning new tree |
| `unist_util_remove` | [unist-util-remove](https://github.com/syntax-tree/unist-util-remove) | ✅ done | remove matching nodes in-place |
| `unist_util_select` | [unist-util-select](https://github.com/syntax-tree/unist-util-select) | low | CSS-selector-like queries on AST nodes |
| `unist_util_position` | [unist-util-position](https://github.com/syntax-tree/unist-util-position) | low | position info utilities |


## Known gaps and limitations

### hast field naming
The crescent hast implementation uses `tag` and `props` rather than the spec's `tagName` and `properties`. This is an intentional deviation (shorter, more Lua-idiomatic), but it means any JS plugin ported without reading `lib/unified/hast/init.lua` first will use the wrong field names. Noted in each plugin's commit.

### mdast fixture coverage
`lib/unified/mdast` as of 2026-04-10:

| Section | Score | Notes |
|---|---|---|
| Setext headings | 27/27 (100%) | |
| Block quotes | 25/25 (100%) | |
| List items | 48/48 (100%) | |
| Lists | 26/26 (100%) | |
| Emphasis/Strong | 132/132 (100%) | |
| Links | 90/90 (100%) | |
| Images | 22/22 (100%) | |

`lib/unified/remark_math` works around one mdast limitation (backslash stripping in inline parsing) using a pre-parse placeholder technique.

### rehype parser stub
`lib/unified/rehype/init.lua` registers a stub parser (`{type="root", children={}, raw=source}`) because a real HTML→hast parser is a substantial project. `rehype_raw` covers the most common use case (embedded HTML in Markdown). A full HTML parser would go in `lib/html` or `lib/unified/rehype_parse`.

### retext syllable counting
`retext_readability` uses naive vowel-group counting for syllables, which is ~80% accurate for English. A proper syllable counter requires the CMU Pronouncing Dictionary or similar; deferred until `lib/compress` exists to ship compressed data.

### retext-spelling missing
Spell checking requires a large word list. Deferred on the same dependency (`lib/compress`).

### remark-lint not ported
The linting framework has ~60 rules and a complex rule-runner architecture. Not ported because no current consumer needs it. Worth building if the card platform or a future editor needs document quality checks.
