# Prior Art Survey: Aider

Survey of [Aider](https://github.com/Aider-AI/aider) as prior art for an AI agentic
harness. Focus is on the *decisions* Aider made and the stated reasons, not a feature
list. All structural claims below were checked against the source at `main` (files
fetched from `raw.githubusercontent.com`) rather than taken from documentation prose;
where a claim rests only on Aider's own blog/benchmark writing, that is stated.

## Overview

Aider is a terminal-based "AI pair programming" tool: a REPL where the user adds files
to a chat, states a request, and the LLM replies with edits that Aider applies to the
working tree and commits to git. Repo verified live: `Aider-AI/aider`, Apache-2.0,
Python, ~47.9k stars / ~4.8k forks, last push recorded `2026-05-22` at time of survey.

The defining posture, stated by the author on the SWE-Bench Lite result, is that Aider
reached SOTA "via existing features for static code analysis, reliable LLM code editing,
and pragmatic UX for AI pair programming. Without RAG, vector search, LLM tools, web
search and other strongly agentic behaviors." Aider is deliberately *not* a maximal
agent. It is a tight human-in-the-loop edit applicator with one very good context
heuristic (the repo map) and one very good output protocol (search/replace blocks).

That framing matters for a survey: much of what a modern harness spends its complexity
budget on (tool registries, sandboxing, sub-agents, planners) Aider simply does not
have, and in several cases has explicitly rejected with benchmark evidence.

## Architecture

### The Coder strategy hierarchy

The central abstraction is `Coder` (`aider/coders/base_coder.py`, ~2500 lines).
Concrete subclasses are selected by an `edit_format` string and differ only in how they
parse and apply the model's reply. The interface each subclass implements is small:

- `get_edits()` — parse the LLM response into edit operations
- `apply_edits(edits)` — write them to the filesystem
- `apply_edits_dry_run(edits)` — validate without writing

Each coder is paired with a `*Prompts` class (`EditBlockPrompts`, `WholeFilePrompts`, …)
holding the system prompt, few-shot example conversation, and a "system reminder"
restating the format rules. Format instructions and format parser are therefore
co-located per strategy, not spread across a generic layer.

The `aider/coders/` directory contains 38 files — roughly a dozen live coders plus
their prompt modules: `editblock`, `editblock_fenced`, `udiff`, `udiff_simple`,
`patch`, `wholefile`, the three `editor_*` variants used under architect mode, and the
non-editing modes `ask`, `help`, `context`. Several `*_func_coder.py` files (OpenAI
function-calling based) survive as deprecated legacy — see Tool-Calling Protocol.

### Control flow

The loop is small and readable (`base_coder.py`):

```
run()                       # REPL: read input, call run_one, repeat
  run_one(user_message)
    init_before_message()   # reset per-turn state; record HEAD sha
    preproc_user_input()    # slash commands, file-mention detection, URL detection
    while message:
      send_message(message)
      if not self.reflected_message: break
      if self.num_reflections >= self.max_reflections: warn and stop
      num_reflections += 1; message = self.reflected_message
```

`send_message` assembles the prompt, streams the completion, then in sequence:

1. `apply_updates()` — parse and apply edits; on `ValueError` from the parser, set
   `self.reflected_message` to the diagnostic and return
2. `auto_commit(edited)`
3. if `auto_lint`: lint edited files, commit the lint fixes as a separate commit, and
   if errors remain, `confirm_ask("Attempt to fix lint errors?")` → set
   `reflected_message = lint_errors`
4. `run_shell_commands()` — offer to run any ```bash blocks the model emitted
5. if `test_cmd`: run tests, and on failure `confirm_ask("Attempt to fix test errors?")`
   → set `reflected_message = test_errors`

**The key structural decision: there is no agent loop in the usual sense.** There is a
*reflection* loop, capped at `max_reflections = 3`, and the only things that can trigger
another turn are (a) a malformed edit, (b) the model asking for files it wasn't given,
(c) lint failure, (d) test failure. The model cannot decide to keep going. Every
iteration is caused by an external, verifiable failure signal, and the cap is hard.

Aider also exposes `run(with_message=...)` for one-shot scripted use and `run_stream()`
as a generator, so the same object serves REPL, `--message`, and library embedding.

### Multi-model roles

`Model` carries not one model but a small role bundle: `main_model`, `editor_model`
(with `editor_edit_format`), a weak model for commit messages and history summarization,
and per-model `edit_format` defaults. The framework's opinion is that different steps
of the same task deserve different models, chosen by the framework rather than the user.

## Tool-Calling Protocol

**Aider does not use tool calling for file edits, and this is its single most
consequential decision.** On the base `Coder`, `functions = None`; the field is threaded
through `send()` but no live coder populates it. The `*_func_coder.py` modules that did
use the OpenAI functions API are retained only as deprecated legacy.

The rationale is benchmarked, not aesthetic. Aider ran 133 coding exercises across
Claude 3.5 Sonnet, DeepSeek Coder V2, and two GPT-4o variants, asking for code as a
JSON/tool-call payload versus a markdown fenced block. Every model scored worse in
JSON. Two failure modes were identified: escaping errors (quotes and special characters
inside JSON strings producing unterminated literals and mangled indentation), and — more
interestingly — a quality drop beyond syntax, suggesting the formatting burden consumes
problem-solving capacity. OpenAI's "strict" JSON mode, which guarantees structurally
valid JSON, did not close the gap: valid JSON is not the same as valid *code inside*
JSON. An earlier benchmark round reached the same conclusion, with the functions API
underperforming plain whole-file replies for every model tested.

### The edit formats

Instead the model writes edits in prose-adjacent formats inside markdown fences:

- **`whole`** — return the complete updated file. Simplest for the model, highest token
  cost, bounded by file size. Used for weak models.
- **`diff`** (default for most models) — SEARCH/REPLACE blocks:

  ```
  path/to/file.py
  <<<<<<< SEARCH
  original lines
  =======
  replacement lines
  >>>>>>> REPLACE
  ```

  A block with an empty SEARCH section creates a new file; an empty REPLACE deletes
  code. The filename sits on the line before the fence.
- **`udiff`** / **`udiff-simple`** — a simplified unified diff, no line numbers.
- **`patch`** — a custom patch envelope format.
- **`diff-fenced`** — SEARCH/REPLACE with the filename inside the fence (Gemini-family
  models were observed to prefer this).

The udiff work is where the design principles are stated explicitly. The four criteria
were: **familiar** (unified diff is everywhere in the training corpus), **simple** (no
escaping, no brittle line numbers), **high-level** (edit whole coherent blocks, not
surgical single lines), and **flexible** (apply permissively). The reported effect was
`gpt-4-1106-preview` going from 20% to 61% on the benchmark, with "lazy" placeholder
comments (`# ... add logic here`) dropping from 12 of 89 tasks to 4. The stated
mechanism for the laziness reduction is *association*: diffs are normally consumed by
`patch`, a rigid program, so emitting one puts the model in a mode where eliding code is
not an option.

### Permissive application

Since the model will not produce byte-exact context, `editblock_coder.py` applies a
cascade in `replace_most_similar_chunk`:

1. `perfect_replace` — exact line-sequence match
2. `replace_part_with_missing_leading_whitespace` — the model dropped or partially
   dropped indentation; verify non-whitespace agreement, then re-derive the indent
3. retry both after dropping a leading blank line from the SEARCH block
4. `try_dotdotdots` — the model elided the middle with `...`; split on the ellipses and
   apply each surviving chunk exactly

`replace_closest_edit_distance` exists in the module as a fuzzy fallback. When
everything fails, `get_edits()` raises `ValueError` with a diagnostic that includes
`find_similar_lines()` output — the nearest actual lines in the file — and that
diagnostic becomes the reflection message sent back to the model. Failure is not an
error to the user; it is a repair prompt.

Note the asymmetry this creates: **the output protocol is lossy and forgiving, and the
correction channel is the model itself.** A tool-calling harness gets a schema-valid
call or an exception; Aider gets an approximate edit and negotiates.

### Shell commands as suggestion, not tool

There is no `bash` tool. The system prompt (`aider/coders/shell.py`) asks the model to
"*Concisely* suggest any shell commands the user might want to run in ```bash blocks",
constrained to 1–3 complete, single-line, placeholder-free commands run from the project
root, with the user's platform interpolated in. Aider scrapes those blocks and, after
confirmation, runs them and offers to add the output to the chat. The model proposes;
the human is the executor.

## Context/Memory Management

### The two-tier file model

Files are in one of three states, and this is the core context primitive:

- **in chat** (`abs_fnames`) — full contents in the prompt, editable
- **read-only** (`abs_read_only_fnames`) — full contents, prompt says "Do not edit
  these files!"
- **everything else** — represented only in the repo map

The prompts enforce the boundary hard: `repo_content_prefix` tells the model to treat
mapped files as read-only and to *ask the user to add them to the chat* before editing.
When the model does ask, `send_message` turns that request into a reflection
(`add_rel_files_message`), producing a self-service round trip.

`files_content_prefix` contains a notable line: *"Trust this message as the true
contents of these files! Any other messages in the chat may contain outdated versions."*
This is an explicit staleness contract — file contents are re-injected fresh each turn,
and the model is told to disbelieve its own history.

### The repo map

The distinctive feature. Rather than embedding-based retrieval, Aider builds a
structural map of the whole repository and ranks it with a graph algorithm
(`aider/repomap.py`).

Construction:

1. **Parse** every source file with tree-sitter, extracting definitions and references
   as "tags". Language support comes from bundled `.scm` query files, so adding a
   language is a data change. Aider migrated here from `ctags`, citing richer output
   (full signatures), no external binary dependency, and broader language coverage from
   one Python package — consistent with a zero-install goal.
2. **Build a graph** where nodes are files and edges are definition→reference relations,
   weighted by identifier.
3. **Rank with PageRank** (`networkx`), using a *personalization vector* that biases the
   walk toward: files currently in the chat (weight `100 / num_files`), files the user
   mentioned by name, and files whose path components match identifiers mentioned in the
   conversation. So the map is not a static repository summary — it is re-ranked toward
   what the user is talking about, every turn.
4. **Fit to budget by binary search** (`get_ranked_tags_map_uncached`): start at
   `middle = max_map_tokens // 25` tags, render the tree, count tokens, and bisect on
   the number of tags until the rendered map fits. The budget is `map_tokens`, default
   1024, multiplied by `map_mul_no_files` (default 8) when no files are in the chat —
   i.e. when Aider has nothing else to go on, it spends 8x more on the map.
5. **Render** each selected file as a tree of the interesting lines only — signatures
   and definitions, with elision between them.

Caching is three-layered: `TAGS_CACHE` on disk keyed by file mtime, an in-memory
`tree_cache` of rendered per-file trees, and a `map_cache` keyed by the chat file set
and parameters. Refresh policy is configurable (`auto`, `always`, `files`, `manual`).

The stated purpose is twofold: give the model enough API surface to write correct calls
into files it cannot see, and let it *name* the files it needs so the user can add them.

### Prompt assembly and cache control

`ChatChunks` (`aider/coders/chat_chunks.py`) is a dataclass of ordered segments:
`system`, `examples`, `readonly_files`, `repo`, `done`, `chat_files`, `cur`, `reminder`.
The ordering is deliberate and stable — least volatile first — because
`add_cache_control_headers()` stamps `cache_control: {type: "ephemeral"}` breakpoints at
the end of the examples (or system), the repo/readonly chunk, and the chat files chunk.
**Prompt structure is organized by rate of change so provider prompt caching can work.**
Aider also runs "cache warming pings" (`num_cache_warming_pings`) to keep the prefix hot
between turns.

Two further details: the format rules are repeated as a trailing `reminder` chunk, not
only in the system prompt (recency defense against format drift); and for models without
system-prompt support the system text is emitted as a `user`/`assistant` "Ok." pair.

### History compaction

`aider/history.py` implements `ChatSummary`: when history exceeds
`max_chat_history_tokens`, split it, summarize the older half with the *weak* model
against a fixed summarization prompt, and recurse if the result is still too large. It
tries each model in a list and raises if all fail. Summarization is recursive and
model-driven, not a sliding window.

## Sandboxing & Permissions

Aider has **no sandbox**. It runs with the user's full privileges in the working
directory. The safety model is entirely (a) confirmation prompts and (b) git.

### Confirmation gates

`allowed_to_edit(path)` in `base_coder.py` is the file-write gate, in order:

1. Already in chat → allowed (after a dirty-commit check)
2. Matches gitignore → **refused outright**, no prompt
3. Does not exist → `confirm_ask("Create new file?")`
4. Exists but not in chat → `confirm_ask("Allow edits to file that has not been added
   to the chat?")`

Anything approved is then added to `abs_fnames`, so approval is per-session-sticky, not
per-edit.

Shell execution (`handle_shell_commands`) is gated by `confirm_ask` with three
significant flags: `explicit_yes_required=True`, `allow_never=True`, and a
`ConfirmGroup`. `explicit_yes_required` is the important one — reading `aider/io.py`,
that flag makes the blanket `--yes-always` setting **not** apply (the auto-answer path
returns `"n"` rather than `"y"` when it is set) and disables the "(A)ll" group answer.
So the global auto-confirm flag deliberately does not extend to running shell commands.
Adding command output to the chat is a second, separate prompt.

(Note for anyone reading secondary sources on this: web search surfaced claims that
Aider blocks dangerous command patterns — `rm -rf /`, `sudo`, `curl|bash` — with no
override. **That is not in the source.** No such denylist exists in `base_coder.py`,
`io.py`, or `run_cmd`; those claims appear to be bleed-through from write-ups of other
CLI tools. The gate is the confirmation prompt, nothing more.)

`allow_never` records a `never_prompts` entry so a declined class of prompt stops
recurring — a per-session "don't ask again", held in memory, not persisted policy.

### Git as the safety net

This is the actual containment mechanism, and it is load-bearing:

- **Auto-commit** after every successful edit set (`auto_commits=True` by default), with
  a commit message generated by the weak model.
- **Attribution** via author/committer metadata and `Co-authored-by` trailers, so
  AI-authored commits are distinguishable in history.
- **Dirty-commit**: if a file about to be edited has uncommitted user changes, Aider
  commits those first (`check_for_dirty_commit` / `need_commit_before_edits`), so the
  user's work and the AI's are never mixed in one commit and never lost together.
- **`/undo`** reverts the last Aider commit; `commit_before_message` records HEAD at
  turn start.
- Lint fixes land as their own commit (`context="Ran the linter"`).

The trade is explicit: instead of preventing bad writes, make every write trivially
reversible and clearly attributed. This also means Aider is substantially degraded
outside a git repo — the safety story simply is not there.

## Multi-Agent Support

No multi-agent system, no sub-agent spawning, no parallelism, no message bus. What
exists is one narrow, deliberate two-model composition.

**Architect/Editor mode** (`aider/coders/architect_coder.py`, ~45 lines) works like
this: `ArchitectCoder` subclasses `AskCoder` — it has *no* edit format and cannot touch
files. It replies in natural language describing the solution. Then `reply_completed()`
asks `confirm_ask("Edit the files?")` (unless `auto_accept_architect`), constructs a
second `Coder` via `Coder.create(from_coder=self)` using `editor_model` and
`editor_edit_format`, clears its history (`cur_messages = []`, `done_messages = []`),
and calls `editor_coder.run(with_message=content, preproc=False)` — passing the
architect's prose as the editor's entire input. It then folds the result back with
`move_back_cur_messages("I made those changes to the files.")` and takes over the
editor's cost total and commit hashes.

Several things are notable in that small file. The editor is created with
`suggest_shell_commands=False`, `map_tokens=0`, and `cache_prompts=False` — the editor
gets *no repo map and no shell capability*, only the architect's text and the chat
files. It is a pure transducer from prose to edits. And the parent's conversation
absorbs a single summary line rather than the editor's transcript, so the architect
never sees the mechanics.

The stated rationale: models must normally solve the problem *and* conform to an output
format simultaneously, and those compete. Splitting them lets a strong reasoning model
reason and a format-reliable model transcribe. Reported result was 85% on the benchmark
pairing o1-preview (architect) with DeepSeek or o1-mini (editor), with gains also when a
model is paired *with itself* in the two roles — which, if it holds, isolates the effect
to the role separation rather than model diversity.

Other modes (`/ask`, `/help`, `/context`) are single-coder alternates selected by slash
command, not agents.

## Notable Design Decisions

1. **Reject tool calling for code payloads, on measured grounds.** Not "we haven't got
   round to it" — benchmarked, published, and structurally embedded. JSON transport
   degrades the code inside it, and strict-mode JSON validity does not fix it.

2. **Choose the output format for familiarity in the training corpus.** Unified diff and
   SEARCH/REPLACE were chosen because models have seen millions of them. The protocol is
   designed around the model's priors rather than around parser convenience.

3. **Format choice is per-model configuration, not a global constant.** Weak models get
   `whole`, strong models get `diff`, Gemini-family gets `diff-fenced`. Capability
   variance is handled by swapping strategy, not by lowest-common-denominator design.

4. **Apply edits permissively; on failure, reflect rather than fail.** The whitespace /
   blank-line / ellipsis cascade plus a diagnostic containing the nearest real lines.
   The parser's job is to succeed if the intent is recoverable, and to write a good
   error prompt if not.

5. **Iteration is driven by external failure signals, capped at 3.** Malformed edit,
   missing file, lint error, test error. The model does not decide to continue. This is
   the sharpest contrast with open-ended agent loops.

6. **The context problem is solved structurally, not by retrieval.** Tree-sitter tags +
   PageRank with a per-turn personalization vector + binary-search token fitting. No
   embeddings, no vector store, no similarity search. Deterministic, inspectable
   (`/map`), and cacheable.

7. **Sharp editability boundary, and make the model negotiate it.** Read-only map vs
   in-chat editable, with the model instructed to *request* files and that request
   automatically becoming the next turn.

8. **Order the prompt by volatility to exploit prompt caching**, and warm the cache
   between turns. Prompt layout is a performance/cost decision, not just a content one.

9. **Separate reasoning from formatting when it pays** — one 45-line coder, a confirm
   prompt, and a stripped-down child coder. Cheapest possible expression of the idea.

10. **Git is the permission model.** Auto-commit, attribution trailers, pre-emptive
    dirty commits, `/undo`. Reversibility instead of restriction.

11. **`--yes-always` deliberately does not cover shell execution.** A blanket
    auto-confirm that still holds one line: `explicit_yes_required` marks the prompts
    that no global setting can pre-answer.

12. **Verification is built into the turn.** `auto_lint` on by default and `test_cmd`
    optional, both feeding failures straight back as reflections. Correctness signal
    comes from the project's own tools, not from the model's self-assessment.

13. **Small, orthogonal control surface.** `/add`, `/drop`, `/read-only`, `/run`,
    `/test`, `/lint`, `/commit`, `/undo`, `/ask`, `/code`, `/architect`, `/map`,
    `/tokens`, `/web`, `/copy-context`. Every one maps to a state change the user can
    predict. `/copy-context` and the copy/paste web-chat workflow reflect a stance that
    the harness should not be the only way to reach the model.

14. **The weak model does the chores.** Commit messages, history summarization. Role
    specialization by cost, decided by the framework.

## Relevance to Crescent

Observations against the current state of `lib/ai` (a provider registry plus
`lib/ai/tools.lua`, a JSON tool-call loop over `ai.generate`) and `lib/taskgraph`. These
are findings and open tensions, not recommendations — the calls belong to the design
session.

**The edit protocol question is a real branch point.** `lib/ai/tools.lua` currently
routes everything through provider-native tool calls with JSON arguments — precisely the
arrangement Aider benchmarked and rejected *for code payloads*. Aider's evidence does
not say tool calling is bad in general; it says code inside JSON is. That suggests a
possible split (structured calls for control operations, a text edit format for file
content) rather than a wholesale choice, but the split itself is a design decision with
no obviously-correct answer. Worth noting: a text edit format needs a permissive matcher
(Aider's is ~600 lines in `editblock_coder.py`), which is real, testable, pure-Lua work
with no dependencies — it fits crescent's constraints well, and is exactly the kind of
thing crescent's fuzz/property-test infrastructure in `lib/test/` would cover.

**Reflection cap vs. open loop.** `tools.lua` uses `max_rounds` (default 10) where the
model drives continuation. Aider's `max_reflections = 3` is triggered only by external
failure. These are different control philosophies with different failure modes — Aider's
cannot wander but also cannot pursue a multi-step plan; the tool loop can do both. If
`lib/taskgraph` is to own multi-step orchestration, Aider's argument is that the
per-turn loop should then be the narrow, failure-driven kind, with the graph holding the
plan. That interaction is undecided and should be decided explicitly rather than
inherited by default.

**The repo map has no Lua analogue yet, and building one has a substrate question
underneath it.** Aider's map is tree-sitter tags → reference graph → PageRank →
binary-search token fit. Crescent has a full typechecker (`lib/type/`) that already
builds definition and reference information for Lua, which is a *stronger* source than
tree-sitter tags — but whether that information is exposed in a form a map builder could
consume is unknown to this survey and needs checking before anything is planned on it.
The ranking and budget-fitting layers are small and self-contained either way. Note the
zero-dependency angle: Aider left ctags for tree-sitter partly to drop an external
binary; crescent would be resolving the same pressure from its own analyzer.

**Prompt assembly deserves an explicit structure.** `ChatChunks` is a small dataclass
with a fixed segment order chosen so cache breakpoints land on stable boundaries. If
crescent's provider layer is to support prompt caching across Anthropic/OpenAI/Google,
the segment ordering needs to be a first-class concept in `lib/ai`, not something each
caller assembles ad hoc.

**Caps-first fits Aider's permission model unusually well.** Aider's gates are
`confirm_ask` calls scattered through the coder — effective in a REPL, but the policy is
implicit in call sites. Crescent's caps-first rule points the other way: the ability to
write a file or run a command is an injected capability, and the confirmation policy
lives in the cap. Aider's *content* is still directly reusable — the specific gates
(create-file, edit-unadded-file, run-shell, add-output-to-chat), the gitignore hard
refusal, the "never again" per-session memory, and especially the observation that a
global auto-confirm must not cover shell execution.

**Git-as-safety-net is a cheap, high-value primitive.** Auto-commit with attribution,
pre-emptive dirty commits so user and AI work never merge into one commit, and `/undo`.
Crescent already has strong commit discipline in CLAUDE.md; an agent app that commits its
own edits with clear attribution would extend the existing habit rather than introduce a
new mechanism.

**Two-model role separation is nearly free to implement.** `ArchitectCoder` is 45 lines.
If `lib/ai` supports named model roles (main / editor / weak) in its config rather than a
single `model` string, the pattern becomes available without dedicated machinery — and
the weak-model-for-chores idea (commit messages, summarization) comes along with it.

**What Aider does not answer.** It has no sandbox, no isolation, no parallelism, no
sub-agents, no persistent policy, and no cross-session memory. Any crescent design
needing those must look to other prior art in this survey directory; Aider's contribution
is the edit protocol, the repo map, and the discipline of a small failure-driven loop.

## Sources

Primary (source read directly at `main`):

- `aider/coders/base_coder.py` — control flow, reflection loop, `allowed_to_edit`,
  `handle_shell_commands`, `format_chat_chunks`, `apply_updates`, `auto_commit`
- `aider/coders/chat_chunks.py` — prompt segmentation and cache-control placement
- `aider/coders/editblock_coder.py` — SEARCH/REPLACE parsing and the matching cascade
- `aider/coders/editblock_prompts.py` — format instructions and few-shot examples
- `aider/coders/base_prompts.py` — file-content prefixes, read-only framing, laziness
  and over-eagerness prompts
- `aider/coders/architect_coder.py` — architect/editor composition
- `aider/coders/shell.py` — shell-command suggestion prompt
- `aider/repomap.py` — tree-sitter tags, PageRank personalization, binary-search fitting,
  caching
- `aider/history.py` — recursive `ChatSummary`
- `aider/io.py` — `confirm_ask`, `explicit_yes_required`, `allow_never`, `never_prompts`
- GitHub API `repos/Aider-AI/aider` — license, stars, forks, last push

Documentation and write-ups:

- [Aider repository](https://github.com/Aider-AI/aider)
- [Unified diffs make GPT-4 Turbo 3X less lazy](https://aider.chat/docs/unified-diffs.html)
- [LLMs are bad at returning code in JSON](https://aider.chat/2024/08/14/code-in-json.html)
- [Building a better repository map with tree sitter](https://aider.chat/2023/10/22/repomap.html)
- [Separating code reasoning and editing](https://aider.chat/2024/09/26/architect.html)
- [Edit formats](https://aider.chat/docs/more/edit-formats.html)
- [GPT code editing benchmarks](https://aider.chat/docs/benchmarks.html)
- [In-chat commands](https://aider.chat/docs/usage/commands.html)
- [Options reference](https://aider.chat/docs/config/options.html)
- [Scripting aider](https://aider.chat/docs/scripting.html)
- [DeepWiki: Edit format implementations](https://deepwiki.com/Aider-AI/aider/3.1-edit-format-implementations)
- [DeepWiki: Repository integration](https://deepwiki.com/Aider-AI/aider/4-repository-integration)
- [Paul Gauthier on SWE-Bench Lite without agentic behaviors](https://x.com/paulgauthier/status/1794447750442226047)
