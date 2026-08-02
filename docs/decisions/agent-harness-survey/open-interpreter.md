# Prior Art Survey: Open Interpreter

Survey date: 2026-08-02. Repo verified live:
<https://github.com/OpenInterpreter/open-interpreter> (Apache-2.0, 67,501 stars,
created 2023-07-14, last push 2026-08-01, GitHub-reported primary language
**Rust**).

**Read this warning first.** The repository has been through a discontinuity.
The project that this survey is about — the Python "LLMs run code on your
machine" harness with the `computer` object and the y/n confirmation prompt —
is the **historical** Open Interpreter, last released as `v0.4.2`. The code at
`main` today is a **different program**: a Rust fork of OpenAI's Codex,
self-described as "a coding agent optimized for low-cost models", with none of
the Python architecture surviving. Both are covered below and every claim is
tagged with which one it describes.

**Source confidence.** Claims are tagged where provenance matters:

- **[primary-py]** — read directly from Python source at tag `v0.4.2`
  (`interpreter/core/core.py`, `respond.py`, `llm/llm.py`,
  `computer/computer.py`, `computer/terminal/terminal.py`,
  `computer/skills/skills.py`, `utils/truncate_output.py`, `utils/scan_code.py`,
  `default_system_message.py`, `terminal_interface/terminal_interface.py`,
  `core/async_core.py`) plus the file listing of the whole `interpreter/` tree.
- **[primary-rs]** — read from the current `main` README or official docs at
  `openinterpreter.com/docs`.
- **[secondary]** — DeepWiki's generated index or third-party writeups. Not read
  from source; re-verify anything load-bearing.

No claim here was verified by running Open Interpreter.

## Overview

**[primary-py]** Open Interpreter's original thesis was the narrowest possible
one in this space: *give the model a shell and a Python REPL on the user's real
machine, and let it iterate*. The `OpenInterpreter` class docstring states the
whole design in six numbered steps:

> This class (one instance is called an `interpreter`) is the "grand central
> station" of this project. Its responsibilities are to:
> 1. Given some user input, prompt the language model.
> 2. Parse the language models responses, converting them into LMC Messages.
> 3. Send code to the computer.
> 4. Parse the computer's response (which will already be LMC Messages).
> 5. Send the computer's response back to the language model.
> The above process should repeat—going back and forth between the language
> model and the computer— until:
> 6. Decide when the process is finished based on the language model's response.

Two nouns dominate the codebase: `interpreter.llm` and `interpreter.computer`.
The entire program is a mediator between them. There is no planner, no task
queue, no agent graph, no retriever. That minimalism is the design.

**[primary-rs]** The current program shares only the name and the CLI verb. It
installs via `curl | sh`, runs `i` or `interpreter`, and its distinguishing
feature is **harness emulation**: `/harness` switches between `native`,
`claude-code`, `claude-code-bare`, `zcode`, `kimi-code`, `kimi-cli`,
`qwen-code`, `deepseek-tui`, `swe-agent`, `minimal`.

## Architecture

### Python era (v0.4.2) [primary-py]

**A single generator pipeline, three layers deep.** There is no event bus and no
scheduler; control flow is Python generators yielding dicts, composed by nesting:

```
terminal_interface(interpreter, message)      # renders, prompts for approval
  └─ interpreter.chat(display=False, stream=True)
       └─ interpreter._streaming_chat()
            └─ interpreter._respond_and_store()   # accumulates chunks → messages
                 └─ respond(interpreter)          # the actual agent loop
                      ├─ interpreter.llm.run(messages_for_llm)
                      └─ interpreter.computer.run(language, code, stream=True)
                           └─ terminal._streaming_run()
                                └─ <Language>.run(code)
```

**The `respond()` loop** is a `while True` with exactly one termination rule:
the loop runs the LLM, then checks `interpreter.messages[-1]["type"]`. If it is
`"code"`, execute and loop. If it is anything else, `break` — *"Doesn't want to
run code. We're done!"*. Turn termination is therefore inferred from message
shape, not signalled by the model.

**The system message is rebuilt every iteration**, not once per session. Each
pass concatenates, in order: the base `default_system_message`; a
`system_message` attribute contributed by each registered *language class*
(languages carry their own prompt fragments); `custom_instructions`; and the
generated Computer API listing if `import_computer_api` is on. The result is
then passed through `render_message()`, which supports templating. Consequence:
adding a language to `computer.terminal.languages` automatically changes what
the model is told, with no separate prompt registry.

**Layering choice worth naming: the display *drives* the loop.** In
`_streaming_chat`, `display=True` does not wrap the generator — it *redirects*
to `terminal_interface(self, message)`, which then calls back into
`chat(display=False, stream=True)`. The comment is explicit:

> Display mode actually runs interpreter.chat(display=False, stream=True) from
> within the terminal_interface. […] Quite different from the plain generator
> stuff. So redirect to that

This is why the approval prompt lives in the *terminal interface* rather than
the core (see Sandboxing). It is the single most consequential structural
decision in the codebase, and arguably its biggest flaw.

**Server mode** is a subclass, not a mode flag: `AsyncInterpreter(OpenInterpreter)`
in `async_core.py` adds asyncio input/output queues and a FastAPI app exposing
`GET /heartbeat`, `POST /` (input), `GET/POST /settings[/{setting}]`, a
WebSocket at `/`, optional `POST /run`, `POST /upload`, `GET /download/{f}`,
and — notably — `POST /openai/chat/completions`, an **OpenAI-compatible
endpoint**, so the whole agent can be dropped in wherever a chat model was.
API-key auth is middleware over the app.

### Rust era (main) [primary-rs]

Structured around **interchangeable harnesses**. Per the harness docs: *"Harness
mode is an Open Interpreter addition. It changes the model-facing prompt, tool
schema, message conversion, and response handling while keeping the native Open
Interpreter runtime."* The runtime (execution, sandbox, session state) is fixed;
the model-facing surface is swappable. Interop is a stated product goal: it
speaks ACP (`interpreter acp`) and is drop-in compatible with the Codex exec
protocol (`new Codex({ codexPathOverride: "interpreter" })`).

## Tool-Calling Protocol

This is the section the project is famous for, and the design is a deliberate
refusal of the discrete-tool model.

### The core decision: one tool, and the tool is a language [primary-py]

The model is never handed a catalogue of `read_file` / `write_file` /
`run_command` functions. It is handed the ability to emit a code block, and the
harness executes it. The instruction, given verbatim when the model does not
support function calling:

> To execute code on the user's machine, write a markdown code block. Specify
> the language after the ```. You will receive the output. Use any programming
> language.

The default system message pushes the iterative style this implies:

> for *stateful* languages (like python, javascript, shell, but NOT for html
> which starts from 0 every time) **it's critical not to try to do everything in
> one code block.** You should try something, print information about it, then
> continue from there in tiny, informed steps. You will never get it on the
> first try, and attempting it in one go will often lead to errors you cant see.

**Function-calling models get the same thing wearing a schema.** `Llm.run`
branches to `run_tool_calling_llm` or `run_text_llm` based on
`litellm.supports_function_calling(model)`, but both funnel into the identical
LMC `type: "code"` message. The tool-calling path is a *transport* for the code
block, not a different capability model. Evidence that the harness treats the
schema as noise: `respond.py` contains cleanup for `functions.execute(...)`
wrappers, `{"language": ..., "code": ...}` JSON leaking into the code body, a
stray `executeexecute` suffix, and a leading `` `\n ``. Each is described as *"a
common hallucination"* and silently repaired, with the repaired value written
back into `interpreter.messages` *"So the LLM can see it"* — the history is
corrected so the model does not learn its own malformed output.

### The Computer API: capabilities as a library, not as tools [primary-py]

Richer capabilities exist — mouse, keyboard, display, clipboard, browser, mail,
SMS, calendar, contacts, OS, vision, files, docs, ai, skills — but they are
**not registered as tools**. They are Python objects on a `computer` module that
is pre-imported into the execution environment. The model reaches them by
*writing Python*.

The tool "schema" is generated by reflection over those objects
(`_get_all_computer_tools_signature_and_description`, using `inspect.signature`
and `__doc__`) and pasted into the system message as a code block:

```
# THE COMPUTER API
A python `computer` module is ALREADY IMPORTED, and can be used for many tasks:
```python
computer.browser.search(query) # Searches the web for the specified query …
computer.calendar.create_event(title: str, start_date: …, …) -> str # Creates …
```
Do not import the computer module, or any of its sub-modules. They are already imported.
```

So: **the docstring is the tool description, the signature is the schema, and
the call syntax is Python.** Adding a method to a Computer submodule adds a
capability with zero registration. There is no JSON Schema anywhere in this
path.

The pre-import is enforced defensively — `respond.py` rewrites the model's code
to strip `import computer`, `import computer.x as y`, and `from computer import
a, b` into assignments off the live object, because the model keeps writing the
imports it was told not to write.

**Consequences of this choice**, stated plainly since they cut both ways:

- Composition is free. Loops, conditionals, variables, error handling, and
  combining five capabilities in one call cost one round trip instead of five.
- State persists. Language runtimes are cached in `Terminal._active_languages`
  and reused, so a variable defined in one block exists in the next.
- The token cost of the tool catalogue is a single generated code block.
- But: the argument surface is unvalidated. There is no schema to check against
  and no structured error — a wrong call is a Python traceback.
- And: **the capability boundary and the security boundary are the same
  boundary, i.e. there is none.** Exposing `computer.mouse` and exposing
  `os.system` are indistinguishable once the model can write Python.

### LMC: the message protocol [primary-py, corroborated secondary]

Open Interpreter extends OpenAI's message format with a third role and a type
system. A message is `{role, type, format, content}`:

- `role` ∈ `user` | `assistant` | **`computer`** | `system`
- `type` ∈ `message` | `code` | `console` | `image` | `confirmation` | `review`
- `format` — for `code`, the language; for `console`, `output` or `active_line`;
  for `image`, `path` / `base64` / `description`

The `computer` role is the notable addition: execution results are a
**first-class speaker in the conversation**, not a `role: "tool"` reply keyed to
a call id. There is no `tool_call_id` and no request/response pairing — the
transcript is a three-party dialogue in temporal order. Conversion to
OpenAI-shaped messages happens once, at the LLM boundary
(`convert_to_openai_messages`), so LMC is the internal truth and the OpenAI
format is a serialization of it.

Two chunk types are **ephemeral** — streamed to the UI but never stored in
history (`is_ephemeral` in `_respond_and_store`): `format: "active_line"` (which
line is currently executing, for live highlighting) and `type: "review"` (a code
review emitted by specialized models). Streaming also synthesizes `start: True`
/ `end: True` flag chunks around each run of same-shaped chunks, so a consumer
can bracket blocks without parsing content.

## Context/Memory Management

**[primary-py]** There is no compaction, no summarization of history, and no
retrieval. The strategy is entirely **truncation at the edges**, applied at four
distinct points:

1. **Output truncation, tail-biased.** `truncate_output` keeps the **last**
   `max_output` characters (default **2800** — very small) and prefixes a
   message that tells the model what to do about it: *"Output truncated. Showing
   the last 2800 characters. You should try again and use
   `computer.ai.summarize(output)` over the output, or break it down into
   smaller steps."* When the Computer API is on, it appends
   *"Run `get_last_output()[0:2800]` to see the first page."* — i.e. **pagination
   offered as a callable rather than as harness state**. The function also
   detects and strips its own previously-inserted banner before re-truncating,
   so banners do not stack.
2. **Image eviction, keep-ends.** In `Llm.run`, if the model has vision: in OS
   mode keep only the last 2 images; otherwise keep the first and last 2 and
   delete the middle ones. Deletion is in-place mutation of the message list. A
   commented-out alternative in source notes *"we could set detail: low for the
   middle messages, instead of deleting them"*.
3. **Image→text degradation for non-vision models.** If `supports_vision` is
   false, each image message is replaced by a caption produced by
   `computer.vision.query` **plus** an OCR pass, concatenated into one text
   message with an explicit hedge (*"this may or may not be relevant. If it's
   not relevant, ignore this"*) and, when the Computer API is on, a pointer
   telling the model how to ask further questions about the original image. The
   message's `format` is flipped to `description` so it is not re-processed.
4. **Token-window trimming** via the `tokentrim` library, budgeted as
   `context_window - max_tokens - 25` (the 25 is annotated `# arbitrary
   buffer`). The system message is passed separately and thus protected. When
   the context window is unknown it defaults to 8000 and *tells the user in
   prose how to set it*. If trimming itself throws, the code reunites the system
   message and proceeds — *"Better not to fail until `messages` is too big, just
   for frustrations sake"*.

**Persistence** is one JSON file per conversation under
`~/.../conversations/<first_few_words>__<Month_DD_YYYY_HH-MM-SS>.json`, rewritten
in full after every exchange. The filename is derived from the first 25
characters of the first message (with a separate branch for scripts without word
separators, e.g. Chinese). It is a whole-file dump, not an append log — there is
no rollout, no fork, no bookmark.

**Model-side context window discovery**: for Ollama models it queries
`/api/show` and scans `model_info` keys for anything containing `context_length`;
otherwise `litellm.get_model_info`. `max_tokens` defaults to `0.2 *
context_window`.

### Skills: memory as generated source code [primary-py]

The most unusual context mechanism. A "skill" is not a prompt fragment or an
embedding — it is a **`.py` file on disk defining a function**, and skills are
loaded by concatenating every `*.py` in the skills directory and **executing
them in the live Python runtime**. If the batch import produces a traceback it
falls back to importing them one at a time and prints which file is broken. Hard
cap: 100 MB of skills.

Skills are *taught interactively*, and the teaching protocol is implemented as
**prompts printed from inside tool return values**. `computer.skills.new_skill.create()`
prints instructions telling the model to ask the user for a name; the `name`
setter prints the next four-step instruction block; `add_step` prints it again.
The control flow of the teaching session lives in stdout that the model reads as
console output. (The prompts include `YOU MUST FOLLOW THESE 4 INSTRUCTIONS
**EXACTLY**. I WILL TIP YOU $200.` — an artifact of 2024-era prompting, but the
*mechanism* — a tool steering the agent by what it prints — is the point.)

The saved artifact is a Python function whose body is a **step dispatcher**:
`skill(step=0)` prints step 0 and then instructs *"After completing the above, I
need you to run `skill(step=1)` immediatly."* A skill is thus a self-driving
prompt chain disguised as a function call, and steps are stored as natural
language + code, executed by the model "flexibly … swapping out parts as
necessary" rather than replayed verbatim.

## Sandboxing & Permissions

**[primary-py] There is no sandbox. This is explicit, not an oversight.** The
default system message tells the model:

> When you execute code, it will be executed **on the user's machine**. The user
> has given you **full and complete permission** to execute any code necessary to
> complete the task. Execute the code. You can access the internet. Run **any
> code** to achieve the goal […] You can install new packages.

The entire safety model is **one human confirmation per code block**, plus an
optional static scan.

**The confirmation mechanism** is a cooperative-generator handshake, and it is
genuinely clever:

1. `respond()` yields `{"role": "computer", "type": "confirmation", "format":
   "execution", "content": {code…}}` **before** executing, wrapped in
   `try: … except GeneratorExit: break`. The comment: *"Yield a message, such
   that the user can stop code execution if they want to. […] The user might
   exit here. We need to tell python what we (the generator) should do if they
   exit."*
2. `_respond_and_store` treats `confirmation` specially — it *"neither triggers a
   flag or creates a message"*, is never stored in history, and is forwarded
   only when `auto_run == False`.
3. `terminal_interface` receives it, blocks on `input("  Would you like to run
   this code? (y/n)")`, and **approval is expressed by resuming the generator;
   denial is expressed by closing it**, which raises `GeneratorExit` inside
   `respond()` at exactly the pre-execution point.

Three properties fall out of this: approval is *structurally* prior to execution
(the code is downstream of the yield), the decision requires no return channel,
and the core carries no UI. Its cost is the layering inversion noted above — the
policy lives in the terminal front-end, so a non-terminal embedder gets no
approval gate for free.

**Editing before approval.** Answering `e` opens the code in `$EDITOR` (default
`vim`), and the edited text is written back into `interpreter.messages[-1]`.
`respond()` then **re-reads the code from messages after the yield returns** —
`code = [m for m in interpreter.messages if m["type"] == "code"][-1]["content"]`
with the comment *"They may have edited the code! Grab it again"*. Human-in-the-
loop here means *amend*, not merely *veto*.

**Safe mode** is a three-value setting `off` / `ask` / `auto` **[primary-py]**.
When not `off`, the code is written to a temp file and scanned with
`semgrep scan --config auto --quiet --error` before the run prompt. It is
advisory only: findings are printed to the terminal, and a `TODO` in source
concedes *"it would be great if we could capture any vulnerabilities identified
by semgrep and add them to the conversation history"* — the model never sees the
scan result, and a failing scan does not block execution.

**`auto_run`** removes the prompt entirely, and there is no gradation: no
per-command policy, no allowlist, no path restriction, no network control, no
first-time-vs-repeat distinction. It is a global boolean.

**Anti-safety in the execution path**, worth recording honestly: `Terminal.run`
intercepts shell code beginning with `apt install` and, if the unprivileged
install fails, calls `getpass.getpass("Enter sudo password: ")` and pipes it to
`sudo -S`. The harness solicits the user's root password on the model's behalf.

**Telemetry** is on by default (`anonymous_telemetry = not disable_telemetry and
not offline`), sending event names and error strings but explicitly *"Only send
message type, no content"*. `contribute_conversation` opts into sharing full
conversations; using the hosted model `i` prints *"Conversations with this model
will be used to train our open-source model."*

**[primary-rs]** The Rust rewrite reverses the central position: the README's
first listed feature is *"Runs commands inside native sandboxing on macOS,
Linux, and Windows"*, and it supports *"exec, MCP, skills, hooks, permissions,
and AGENTS.md"*. The project moved from "no sandbox, ask the human" to "OS
sandbox + permissions" — and needed a native-language rewrite to do it. That
trajectory is itself the finding.

## Multi-Agent Support

**[primary-py] None.** Verified by listing every path under `interpreter/` at
`v0.4.2`: there is no file or directory matching `agent`, `spawn`, `swarm`, or
`multi`, and no spawn/delegate/wait primitive in the core. Open Interpreter is
strictly single-agent, single-threaded per conversation.

Three things sit adjacent to it and are worth distinguishing from it:

- **`computer.ai`** — an LLM callable *from inside executed code*:
  `computer.ai.chat(text)`, `computer.ai.summarize(...)`. Implemented as
  `fast_llm`, which temporarily swaps `llm.interpreter.system_message`, makes a
  call, and restores it, plus map-reduce chunking helpers
  (`split_into_chunks`, `chunk_responses`, `query_map_chunks`). It is a
  sub-*call*, not a sub-*agent*: no tools, no loop, no own history. It exists
  mainly so the model can summarize output it just truncated.
- **Multiple `OpenInterpreter` instances** can be constructed in one Python
  process (the class is instantiable and takes a `computer=` injection), so
  multi-agent is achievable *by the embedder* — but the harness provides no
  coordination, no message passing, and no shared state.
- **`sync_computer`** — bidirectional state sync between the host's `Computer`
  object and the one inside the child Python runtime, done by serializing
  `computer.to_dict()` to JSON, `exec`-ing a `load_dict` call in the child, then
  reading the child's dict back out through `print(json.dumps(...))` and parsing
  stdout. It is the codebase's only cross-process state mechanism, it is
  best-effort (`except: print("Failed to sync … Continuing.")`), and a comment
  elsewhere abandons a related idea with *"no… this is a huge time sink…"`.

**Non-blocking chat** exists (`chat(blocking=False)` spawns a `threading.Thread`
and `interpreter.wait()` polls `self.responding` every 0.2 s) but that is
concurrency for a single agent, not multiple agents.

## Notable Design Decisions

1. **The tool is a programming language, not a set of functions.** One
   capability — "execute code in language X" — subsumes file I/O, process
   control, networking, and package installation. Discrete tools are re-derived
   by the model as library calls. Composition, control flow, and state come from
   the language for free instead of being invented in the protocol.
2. **Capabilities are a pre-imported library whose docstrings are the schema.**
   `computer.*` is reflected into the system message via `inspect.signature` +
   `__doc__`. Adding a method adds a capability; there is no registry, no JSON
   Schema, and no dispatch table.
3. **The transcript has three speakers, not two-plus-tool-results.** The
   `computer` role makes execution output a peer utterance rather than a reply
   keyed to a call id. OpenAI's format is a serialization at the boundary, not
   the internal model.
4. **Function-calling support is a transport detail.** Both the tool-calling and
   plain-text paths produce the same LMC `type: "code"` message, so provider
   capability differences never reach the loop.
5. **Model malformations are repaired into history, not just tolerated.** Known
   hallucination shapes are normalized and the *stored* message is overwritten
   "so the LLM can see it" — the harness edits the past to keep the model's
   self-examples clean.
6. **Approval is a generator suspension point; denial is `GeneratorExit`.** The
   permission gate needs no return channel and is structurally impossible to
   execute past, because execution is literally downstream of the `yield`.
7. **Approval includes amendment.** `e` drops the user into `$EDITOR` and the
   loop re-reads the code from history afterwards. The human can rewrite what
   the model proposed rather than only accept or reject it.
8. **Truncation talks back to the model.** The truncation banner names a
   specific remedy (`computer.ai.summarize`, `get_last_output()[0:N]`) — the
   context-management failure is surfaced to the agent as an actionable
   instruction instead of silently discarded.
9. **Pagination is offered as a callable, not held as harness state.**
   `get_last_output()` is defined *into the child runtime* so the model can
   scroll. (Source concedes this is partly broken: the truncated text is what
   got stored, so the full output is not always recoverable.)
10. **Skills are executable source files, taught interactively, replayed
    flexibly.** Long-term memory is `.py` on disk, `exec`'d into the live
    runtime, produced by a teaching session whose control flow is carried in
    tool *stdout*, and consumed as natural-language steps the model adapts
    rather than replays.
11. **A tool can steer the agent by what it prints.** Return values contain
    imperative instructions for the model. Powerful, and the same channel an
    untrusted output would arrive on — the injection surface is structural.
12. **The system prompt is assembled per iteration from contributing
    components.** Language classes carry prompt fragments, so registering a
    language changes the instructions with no separate prompt registry.
13. **Language runtimes are persistent and lazily created**, cached in
    `_active_languages`, with `stop()`/`terminate()` fanning out to all of them.
    Statefulness across code blocks is the reason the "tiny informed steps"
    prompt strategy works.
14. **`active_line` is streamed and deliberately never stored.** UI-grade
    telemetry is separated from conversational state by an explicit
    `is_ephemeral` predicate rather than by a parallel channel.
15. **The server exposes an OpenAI-compatible completions endpoint**, letting
    the entire agent be substituted anywhere a chat model was expected.
16. **Explicit refusal to sandbox, compensated by a per-block human gate.** The
    system prompt asserts *"full and complete permission"*; the confirmation
    prompt is the only boundary; `auto_run` removes it wholesale with no middle
    setting. Its later Rust rewrite reversed this and needed a native language
    to do so.
17. **[primary-rs] Harness emulation as a product.** Prompt, tool schema,
    message conversion, and response handling are a swappable unit, on the
    thesis that cheap models perform best when driven by the harness their
    provider tuned for. The harness is treated as a *per-model tunable*, not a
    fixed asset.
18. **[primary-rs] Portability as a stated product goal.** `AGENTS.md`,
    `.agents/skills`, MCP, ACP, and Codex-exec-protocol compatibility, with
    product-specific storage under `~/.openinterpreter` explicitly limited to
    *"configuration and runtime state that does not yet have a practical shared
    standard."*

## Relevance to Crescent

Observations only. Each names a branch point; none is a recommendation.

**Where crescent stands today** (read from source): `lib/ai/tools.lua` is a
79-line loop — copy messages, call `ai.generate`, return if `res.tool_calls` is
absent or empty, else append an assistant message and one `role = "tool"`
message per call with `tool_call_id`/`name`, repeat to `max_rounds` (default 10),
error `"max rounds exceeded"` on exhaustion. Handlers are a
`{ [string]: (args) -> string }` table invoked under `pcall`; failures become
`{"error": …}` JSON strings fed back to the model. There is no approval hook, no
sandbox, no persistence, no truncation, and no context management.
`lib/platform/apps/` has no agent app.

**The central question this survey poses to crescent** is whether the agent
app's primary affordance is *discrete tools* (what `lib/ai/tools.lua` already
assumes) or *"here is a Lua interpreter"*. Crescent is unusually well placed for
the second — it *is* a Lua runtime with a large indexed library
(`docs/inventory.md`), so "the model writes Lua against `lib.*`" is closer to
free here than "the model writes Python against `computer.*`" was for Open
Interpreter. Both are workable and they differ concretely:

- *Discrete tools*: argument validation possible, per-tool permission granularity
  possible, capability surface enumerable and auditable, but composition costs a
  round trip each and the tool catalogue costs tokens linearly.
- *Code-as-tool*: composition and state are free, the catalogue is one generated
  block, but there is no argument validation, errors are tracebacks, and — the
  load-bearing part — **per-capability permission becomes impossible**, because
  once the model can write Lua it can reach anything the interpreter can reach.
  Open Interpreter's answer to that was "ask the human every time".

That last point interacts directly with crescent's **caps-first rule**. A
caps-injected library is auditable precisely because a caller cannot reach I/O
except through injected caps — and an unrestricted `load()` of model-authored
Lua destroys that property, since the generated chunk can `require` whatever it
likes. A middle position exists that Open Interpreter did not take: execute
model code in a **restricted environment table** carrying only injected caps, so
"the model writes code" and "capabilities are explicitly granted" coexist. That
is a real design option, not a settled answer, and its cost is that the model's
code cannot use the ambient stdlib it expects.

**Directly transferable, cheap:**

- *Reflection-generated tool descriptions.* Crescent's `--:` / `--::`
  annotations already carry signature types, and `docs/conventions.md` requires
  names that predict their signature. Generating a capability listing from
  annotations + doc comments is the same move as
  `_get_all_computer_tools_signature_and_description`, with better type data.
- *Truncation banners that name a remedy.* One string, large effect on loop
  quality. Crescent has no output truncation at all yet.
- *Ephemeral vs. stored chunk classification.* Deciding up front which stream
  events enter history is far cheaper than retrofitting it.
- *Approval-includes-amendment.* The `e` branch is a few lines and changes the
  human's role from gatekeeper to editor.

**Structurally interesting, larger:**

- *Approval as coroutine suspension.* Open Interpreter's `yield`/`GeneratorExit`
  handshake maps onto Lua coroutines almost exactly, and onto `lib/taskgraph`'s
  frontier suspension in a second, different way. The open question mirrors the
  one raised in the Codex survey: is an approval gate a coroutine yield inside
  the agent loop, or a suspended taskgraph node? Building it in both places is
  the failure mode.
- *Where the approval policy lives.* Open Interpreter's placement of the prompt
  in `terminal_interface` is the clearest cautionary tale in this survey: the
  core became structurally unable to enforce its own safety property, so
  `AsyncInterpreter` and the server inherited a loop with no gate. If crescent's
  agent app is one front end among several, the gate belongs below the front end
  — and that is a decision to make before the second front end exists, not after.
- *Skills as source files vs. skills as data.* Crescent has no analogue.
  Executable-file skills give flexibility and cost an arbitrary-code-load path;
  data-file skills invert both.
- *Three-speaker transcript vs. tool-call pairing.* `lib/ai/tools.lua` already
  committed to the OpenAI `role = "tool"` + `tool_call_id` shape. LMC's
  `computer` role is the alternative, and the choice determines whether the
  internal representation is provider-shaped or provider-neutral. Given
  `lib/ai/providers` exists to abstract providers, an internal format that is
  already one provider's wire format is worth examining deliberately.

**Substrate limits to state plainly:**

- Neither program offers a pure-Lua-reachable sandbox. The Python version had
  none by design; the Rust version needed native code for OS sandboxing. As with
  Codex, crescent's pure-Lua tier can offer *approval-gating and environment
  restriction*, not a security boundary — an approval prompt is not a sandbox,
  and a restricted `_ENV` is a capability boundary against honest code, not
  against adversarial code that has `string.dump`/`load` or FFI in scope.
- Open Interpreter's persistent-language-runtime model assumes long-lived child
  processes it can stream from and terminate. Whether crescent's agent app owns
  such processes, and through which cap, is unresolved and prior to any of the
  above.

**One anti-pattern to name explicitly:** tool return values containing
imperative instructions to the model (the skills teaching flow) is an elegant
trick and an injection channel. Any crescent tool whose output can contain
untrusted bytes — HTTP bodies, file contents, command stdout — is on that same
channel. Deciding whether harness-authored instructions and tool output share a
representation is a protocol decision, and cheaper before there are tools than
after.

## Sources

Primary — Python source, read at tag `v0.4.2` via
`raw.githubusercontent.com/OpenInterpreter/open-interpreter/v0.4.2/…`:

- `interpreter/core/core.py` — `OpenInterpreter` class, chat/streaming,
  `_respond_and_store`, ephemerality, confirmation handling, persistence
- `interpreter/core/respond.py` — the agent loop, system-message assembly,
  hallucination repair, confirmation yield, `sync_computer`, loop messages
- `interpreter/core/llm/llm.py` — provider dispatch via LiteLLM, function/vision
  detection, image eviction, image→text degradation, `tokentrim` budgeting
- `interpreter/core/default_system_message.py` — permission assertion, "tiny
  informed steps"
- `interpreter/core/computer/computer.py` — Computer submodules, reflected tool
  listing, generated Computer API system message
- `interpreter/core/computer/terminal/terminal.py` — language registry,
  persistent runtimes, computer-API/skills import, `apt install`/sudo path
- `interpreter/core/computer/skills/skills.py` — skill import/exec, teaching
  protocol prompts, generated step-dispatcher skill files
- `interpreter/core/computer/ai/ai.py` — `fast_llm`, chunking/map-reduce
- `interpreter/core/utils/truncate_output.py` — tail truncation, remedy banner
- `interpreter/core/utils/scan_code.py` — semgrep invocation, advisory-only TODO
- `interpreter/terminal_interface/terminal_interface.py` — approval prompt, safe
  mode branches, `$EDITOR` amendment
- `interpreter/core/async_core.py` — `AsyncInterpreter`, FastAPI/WebSocket
  routes, OpenAI-compatible endpoint, API-key middleware
- Full `interpreter/` path listing via the GitHub trees API at `v0.4.2` — used
  to establish the *absence* of any agent/spawn/multi-agent module

Primary — current `main` (Rust) and official docs:

- <https://github.com/OpenInterpreter/open-interpreter> — repo metadata
  (Rust, 67.5k stars, pushed 2026-08-01) and `README.md` at `main`: harness
  list, native sandboxing, ACP/Codex-protocol compatibility, portability goal
- <https://www.openinterpreter.com/docs/terminal/harness> — definition of
  harness mode and what switching changes

Secondary:

- <https://deepwiki.com/OpenInterpreter/open-interpreter> — generated
  architecture index (respond loop, LLM/Computer split, server/OS mode)
- Search-surfaced summaries of LMC messages and the Computer API
  (`docs.openinterpreter.com/protocols/lmc-messages`, now redirecting to
  `openinterpreter.com/docs/terminal`) and the "New Computer Update" changelog
  entries at `changes.openinterpreter.com` — used only to corroborate LMC role/
  type/format vocabulary already observed in source

Local files read for the Relevance section: `lib/ai/tools.lua`, `lib/ai/` and
`lib/taskgraph/` listings, `lib/platform/apps/` listing,
`docs/decisions/agent-harness-survey/codex-cli.md` (for survey format).
