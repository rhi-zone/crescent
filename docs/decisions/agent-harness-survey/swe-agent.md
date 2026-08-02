# SWE-agent (Princeton NLP / SWE-agent org)

Prior-art survey for the crescent agent harness. Researched 2026-08-02 against
the live repo, docs site, and the NeurIPS 2024 paper. Everything below is
sourced; items that are my inference rather than a stated claim are marked
**(inference)**.

## Overview

SWE-agent is an open-source harness that lets a language model autonomously
operate a computer to solve software-engineering tasks (GitHub issues,
SWE-bench, CTF-style security tasks via the EnIGMA mode). It originated at
Princeton Language and Intelligence; the repo has since moved from
`princeton-nlp/SWE-agent` to `github.com/SWE-agent/SWE-agent` (the old URL
redirects). The paper is *SWE-agent: Agent-Computer Interfaces Enable Automated
Software Engineering* (arXiv 2405.15793, NeurIPS 2024).

Its thesis is a design claim, not an engineering one: **LM agents are a new
class of end user, and interfaces built for humans (the Linux shell, an IDE)
are the wrong interface for them.** The system's contribution is the
*agent-computer interface* (ACI) — a small curated command set plus a
disciplined feedback format — and the empirical demonstration that ACI design,
with the model held fixed, moves task success by ~10 percentage points.

Headline numbers from the paper: 12.47% resolved on full SWE-bench and 18.00%
on SWE-bench Lite with GPT-4 Turbo, versus 11.00% Lite for the same model given
only a raw shell, and 2.67% for non-interactive retrieval-augmented generation.
87.7% pass@1 on HumanEvalFix. These are 2024 numbers on 2024 models; treat them
as evidence about *interface deltas*, not about current attainable performance.

An important later data point from the same team: **mini-swe-agent**, a
deliberate ~100x simplification that removes the custom ACI entirely (bash
only, stateless `subprocess.run`, linear unprocessed message history) and
reports >74% on SWE-bench Verified. The authors state plainly that they
questioned whether the complex architecture was still necessary as models
improved. The ACI thesis and its own authors' retraction-in-practice are both
part of the prior art, and the tension between them is the most decision-
relevant thing in this survey.

## Architecture

Control flow, per the architecture doc and `sweagent/agent/agents.py`:

- **CLI entry (`sweagent`)** constructs a `SWEEnv` and an `Agent` from stacked
  YAML config files (`--config a.yaml --config b.yaml`, merged nested).
- **`SWEEnv`** wraps a **SWE-ReX** *deployment* — a container or remote machine
  — plus a persistent bash session, repo clone, and reset/hard-reset lifecycle.
- **`DefaultAgent`** runs the loop. Layers, outermost to innermost:
  - `run()` — loops until `step_output.done`.
  - `step()` — bookkeeping: trajectory append, history update, hooks.
  - `forward_with_handling()` — error-recovery layer implementing *requery*.
  - `forward()` — query model, parse output into (thought, action), execute.
- **`handle_action()`** checks a blocklist, executes via `env.communicate()`
  with a timeout, and checks for submission (patch extracted from
  `/root/model.patch`), setting `done`.
- **Hooks** (`AbstractAgentHook`, `CombinedEnvHooks`) provide observability at
  `on_step_start`, `on_model_query`, `on_action_executed`, deployment startup,
  etc. — integration without touching core logic.

The distinctive control-flow decision is the **requery layer**. Rather than
letting a malformed or blocked model output enter history as a turn, the
harness catches it and re-prompts with a targeted error template, bounded by
`max_requeries` (default 3):

| Condition | Template | Counts against requery budget |
|---|---|---|
| `FormatError` (unparseable action) | `format_error_template` | yes |
| `_BlockedActionError` (blocklist) | `blocklist_error_template` | yes |
| `BashIncorrectSyntaxError` | `shell_check_error_template` | yes |
| `RETRY_WITH_OUTPUT_TOKEN` in observation | `next_step_template` | yes |
| `RETRY_WITHOUT_OUTPUT_TOKEN` | same | **no** |
| content-policy violation | resample | yes |

Note the direction of control: a *tool* can emit a magic token
(`RETRY_WITH_OUTPUT_TOKEN`, `EXIT_FORFEIT_TOKEN`) in its stdout and thereby
drive the harness's control flow. Tools are not pure observation producers;
they are participants in the loop.

Termination is a rich enumerated **exit status**, not a boolean: `submitted`,
`exit_command`, `exit_command_timeout` (N consecutive execution timeouts),
`exit_total_execution_time`, `exit_context` (context window exceeded),
`exit_cost`, `exit_format` (requery budget exhausted), `exit_api`,
`exit_environment_error`, `exit_error`. Exhausting the requery or cost budget
triggers **autosubmission** of whatever edits exist rather than discarding the
run — a deliberate "partial work is still work" choice.

## Tool-Calling Protocol

This is the deepest part of the design and the part most worth studying.

### The ACI thesis

From the paper (§2), four stated design principles:

1. **Actions should be simple and easy to understand for agents.** Bash
   commands carry dozens of options and pages of documentation; a small command
   with a few options and concise docs reduces the need for demonstrations or
   fine-tuning.
2. **Actions should be compact and efficient.** Consolidate a high-order
   operation (navigate, edit) into *one* action. A design with many primitive
   actions that must be composed across turns is explicitly called out as poor.
3. **Environment feedback should be informative but concise.** Substantive
   state after the action, no incidental detail. Humans can skim irrelevant
   output; for an LM every token has fixed memory and compute cost and
   distracting context measurably harms performance.
4. **Guardrails mitigate error propagation and hasten recovery.** A syntax
   checker in the edit path catches self-inflicted errors before they cascade.

The ACI was arrived at by two methods, both stated: manual inspection of agent
trajectories to find difficulties, and a grid search over window size, history
processing, and temperature.

### The curated command set

Built *on top of* bash (raw shell remains available), not replacing it:

- **Search/navigation**: `find_file` (filenames), `search_file` (string in
  file), `search_dir` (string in a directory). Results are a *summary* — file
  plus match count — capped at 50 results; over the cap the agent is told to
  refine the query rather than shown the results.
- **File viewer**: `open`, `scroll_up`, `scroll_down`, `goto`. Shows a window
  of at most 100 lines with the full path, total line count, count of lines
  omitted above and below, and a line number prepended to every visible line.
- **File editor**: `edit <start>:<end>` with replacement text — one command
  replaces a line range in the open file, and the viewer *automatically
  redisplays the updated region* so the agent sees the effect without a second
  action. A linter runs on every edit; invalid edits are **discarded**, and the
  agent is shown the errors plus a before/after snippet and asked to retry.
- **Empty output is never silent**: "Your command ran successfully and did not
  produce any output."

### The ablations — why each choice, with numbers

SWE-bench Lite, GPT-4 Turbo; chosen configuration is 18.0%.

| Axis | Variant | Resolved |
|---|---|---|
| Editor | `edit` **with linting** (chosen) | **18.0** |
| | `edit` without linting | 15.0 (−3.0) |
| | No edit tool (bash `sed`/redirection) | 10.3 (−7.7) |
| Search | **Summarized** (chosen) | **18.0** |
| | No search tools (bash only) | 15.7 (−2.3) |
| | Iterative (`next`/`prev`, IDE-style) | 12.0 (−6.0) |
| File viewer | 30-line window | 14.3 (−3.7) |
| | **100-line window** (chosen) | **18.0** |
| | Full file | 12.7 (−5.3) |
| Context | **Last 5 observations** (chosen) | **18.0** |
| | Full history | 15.0 (−3.0) |
| | Without demonstration | 16.3 (−1.7) |

The iterative-search result is the sharpest finding in the paper: an interface
copied directly from what works for humans (Vim/VSCode incremental search)
performed **worse than having no search tool at all**, because agents
exhaustively call `next` through every match until the cost budget or context
window is gone. A human's ability to abandon a search mid-way is not a property
the interface can assume.

The file-viewer result establishes that the failure is two-sided: too little
context and too much context both cost ~4-5 points. There is a real optimum,
and it was found by sweep, not by reasoning.

### Action parsing: many protocols, pluggable

`sweagent/tools/parsing.py` ships eleven parsers, selected per-config:
`ActionParser` (first word must be a known command), `ThoughtActionParser`
(prose then a fenced block — the classic ReAct format), `XMLThoughtActionParser`
(`<command>` tags), `XMLFunctionCallingParser` (`<function=bash><parameter>`),
`FunctionCallingParser` (native LiteLLM `tool_calls`), `JsonParser`,
`BashCodeBlockParser`, `SingleBashCodeBlockParser`, `EditFormat`,
`ActionOnlyParser`, `Identity`. All raise `FormatError` into the requery layer.
The default config now uses native function calling; the alternatives exist
because the harness must run models that lack it. **(inference)** The parser is
treated as an interchangeable wire format over a stable internal
(thought, action) representation — the protocol is a config choice, not an
architectural commitment.

### Tools as filesystem bundles

Tools are not Python callables registered in-process. A **tool bundle** is a
directory: `bin/` with executables, `config.yaml` declaring
`signature` / `docstring` / `arguments` (name, type, description, required),
`install.sh`, `pyproject.toml`, `README.md`. Bundles are installed into the
sandbox and invoked as real commands. The JSON schema shown to the model and
the executable the shell runs come from the same bundle.

Two consequences worth noting: (a) the agent can invoke a tool via a raw bash
line even when the schema path is not used, since the tool is genuinely on
`PATH`; (b) adding a capability requires no harness code change.

### `state_command` — out-of-band state

A configured command (e.g. `_state`) runs **after every action** and returns
JSON, which is interpolated into the next-step prompt template. This is how
"current working directory" and "currently open file" reach the model without
the agent having to spend an action asking. Tool state persists across
invocations through a registry file in the sandbox, since each tool invocation
is a separate process.

## Context/Memory Management

Managed by a pipeline of composable **history processors**
(`sweagent/agent/history_processors.py`), applied to the message list before
every model call:

- `DefaultHistoryProcessor` — identity.
- `LastNObservations(n, ...)` — elide all but the last *n* observations,
  replacing each elided one with a one-line summary stating how many lines and
  images were omitted. Supports `always_remove_output_for_tags` /
  `always_keep_output_for_tags` so specific tool outputs can be pinned or
  always dropped.
- `TagToolCallObservations(tags, function_names)` — tags observations by which
  tool produced them, feeding the above.
- `ClosedWindowHistoryProcessor` — tracks file windows across the trajectory
  and replaces *superseded* views of a file with a summary, keeping only the
  most recent window per file. Directly targets the "agent is looking at a
  stale version of the file it already edited" failure.
- `CacheControlHistoryProcessor(last_n_messages=2, tagged_roles=[user, tool])`
  — inserts Anthropic prompt-cache breakpoints.
- `RemoveRegex(remove, keep_last)` — pattern-based scrubbing.
- `ImageParsingHistoryProcessor` — converts base64 images embedded in tool
  output into multimodal message parts.

Design decisions embedded here:

- **Elide observations, keep actions.** The agent's own plan and action
  sequence stay intact; only the bulky environment output is collapsed. The
  paper's stated rationale: preserve the plan and action history, drop the
  content, gain more interaction cycles, and avoid showing outdated file
  information.
- **Error messages are deduplicated**: after a malformed generation, all past
  error messages except the first are dropped from history.
- **Observations are hard-truncated** at `max_observation_length` (100K chars
  default) before any processor runs.
- Context management is a **config-level pipeline**, not code. Swapping the
  strategy is a YAML edit.

Budget enforcement is explicit and multi-dimensional: per-instance cost limit,
total cost limit, consecutive-execution-timeout count, total execution time,
and the model's context window (which surfaces as its own exit status).

## Sandboxing & Permissions

Execution is delegated wholesale to **SWE-ReX**, a separate library by the same
team. Its stated purpose is that agent code stays identical whether running
locally or remotely.

- **Backends**: local, Docker (default, Python 3.11 image), AWS remote
  machines, Modal, Fargate; Daytona in development.
- **Session model**: persistent interactive shell sessions — it can drive
  `ipython`, `gdb`, and other interactive tools, detecting command completion
  and extracting output plus exit code. Multiple parallel sessions supported.
- **Parallelism** is a headline feature: the README demonstrates 30 SWE-bench
  instances running concurrently.
- **Timeouts**: 25s default per command, 500s for post-startup commands.
- **Reset semantics**: `reset()` restores the repo to its base commit;
  `hard_reset()` restarts the whole deployment.

The permission model, such as it is, is **coarse and static**: the container is
the boundary, and within it there is an action **blocklist** checked before
execution (violations route into the requery layer with an explanatory
template). There is no per-tool capability grant, no interactive approval, no
notion of a read-only vs. write tool. This follows from the target use case —
fully autonomous benchmark runs with no human in the loop — where an approval
prompt would have nothing to prompt. **(inference)** For any harness with a
human present, this is the least transferable part of the design.

## Multi-Agent Support

There is no peer-to-peer or role-specialized multi-agent system (no
planner/coder/reviewer team in the MetaGPT sense). What exists is
**multi-attempt with model-based selection**, in `RetryAgent` and
`sweagent/agent/reviewer.py`:

- `RetryAgent` wraps N sequential `DefaultAgent` attempts, resetting the
  environment between them.
- `AbstractReviewer` scores a single submission; `AbstractRetryLoop` decides
  whether to retry and which submission wins.
- **`ScoreRetryLoop`**: a reviewer model scores each submission, multiple
  review samples averaged with an optional standard-deviation penalty; the
  highest score wins, ties broken by fewest API calls. Stops on max attempts,
  cost limit, insufficient remaining budget, or enough accepted submissions.
- **`ChooserRetryLoop`**: a chooser model sees all submissions and picks one,
  with an optional preselector to narrow the field first.
- Budget is shared and dynamically re-divided: the per-instance limit of the
  next attempt is clamped to the remaining global budget.

Reviewer prompts are Jinja2 templates over the trajectory, with options to omit
specific action outputs or keep only recent steps — i.e. the reviewer gets its
own context-management policy, separate from the actor's.

**(inference)** The framing is best-of-N sampling with a learned selector, not
collaboration. The unit of parallelism is the *whole task*, not a subtask, and
the composition operator is "pick one", never "merge".

## Notable Design Decisions

1. **Curate the action space; do not expose the raw substrate as the primary
   interface.** The strongest single claim, with the strongest single
   counter-evidence (iterative search underperforming no search) showing the
   claim is really "curate *for the agent*", not merely "curate".
2. **Human-optimal interfaces are not agent-optimal.** Demonstrated
   empirically, not asserted. IDE-style incremental search was worse than
   nothing.
3. **Guardrails belong inside the action, not after it.** The linter rejects
   the edit and the edit does not happen — the agent never has to undo. 51.7%
   of trajectories hit at least one failed edit; recovery probability drops
   from 90.5% to 57.2% after a single failed edit, which is precisely why
   preventing the bad state beats detecting it.
4. **Feedback is part of the tool's contract.** `edit` redisplays the file;
   empty output is explicitly announced; search over 50 results returns advice
   instead of data. The observation format is designed with the same care as
   the command signature.
5. **Malformed output is not a turn.** Requery with a targeted template,
   bounded, and don't let the failure pollute history.
6. **Tools are filesystem artifacts, not code.** A bundle is a directory of
   executables plus a schema, installed into the sandbox. Schema and
   implementation cannot drift apart.
7. **Everything behavioral is config.** Prompts, tool sets, parsers, history
   processors, model, limits — all YAML, stackable and merged. The stated
   motivation is research reproducibility and hackability.
8. **Out-of-band state injection** (`state_command`) rather than making the
   agent spend actions on orientation.
9. **Partial results are preserved.** Budget exhaustion autosubmits.
10. **Execution is a separate library** with a uniform interface across local,
    Docker, and three cloud backends.
11. **The authors' own successor abandons (1).** mini-swe-agent: bash only,
    `subprocess.run` per action with no persistent shell, linear unprocessed
    history — explicitly because stateless execution sandboxes more easily
    (Docker, Singularity, Bubblewrap) and linear history is easier to debug and
    fine-tune on. >74% SWE-bench Verified. The claim is not that the ACI thesis
    was wrong in 2024 but that the deficits it compensated for were model
    deficits, and models moved.

## Relevance to Crescent

Observations relevant to `lib/ai` and a future agent app under
`lib/platform/apps/`. These are readings of the prior art, not
recommendations — the calls below are open.

**Where crescent stands today.** `lib/ai/tools.lua` (79 lines) is a bounded
tool loop: `max_rounds` (default 10), handler table keyed by tool name,
`pcall` around each handler with errors returned to the model as a JSON
`{"error": ...}` payload, and messages appended verbatim with no processing.
Structurally this is closest to mini-swe-agent's model, not SWE-agent's.

**Mechanisms with no counterpart in `lib/ai/tools.lua`:**

- *Format-error requery.* Currently an unparseable or unknown tool call becomes
  a `tool` message saying "unknown tool: X" and consumes a round. SWE-agent's
  distinction — errors that count against a *separate* requery budget and are
  deduplicated out of history — is a cheap addition to a loop this size.
- *History processing.* The loop appends unboundedly until `max_rounds`. The
  `LastNObservations` and `ClosedWindowHistoryProcessor` ideas are the two
  highest-value ones, and the second (stale file views) is specific to a
  harness that edits files.
- *Exit status as an enumeration.* `lib/ai/tools.lua` currently returns
  `(nil, "max rounds exceeded")` — a string. SWE-agent's ten-way exit status is
  what makes a run classifiable after the fact, which matters if `lib/taskgraph`
  is going to schedule and evaluate agent runs.
- *Cost/time budgets.* No cost accounting exists. SWE-agent enforces four
  independent budgets.
- *State injection after each action.* Relevant to the caps-first rule: state
  would come from an injected cap, not a global.

**Tension crescent has to resolve explicitly.** The ACI-vs-bash question is
live prior art with evidence on both sides *from the same authors*, three years
apart. Adopting either without deciding which is a guess. The relevant crescent
constraint is that the codebase already has ~2 dozen library categories in
`docs/inventory.md` — a curated command set over crescent's own libraries is a
different proposition from a curated command set over a Python repo, and the
paper's evidence does not transfer to it directly.

**Where the conventions align and clash.**

- Bundles-as-directories fits crescent's module conventions but conflicts with
  zero-dependency + no-build-step if bundles need install scripts.
- SWE-agent's config-is-YAML stance would land in crescent as
  config-is-Lua-table; the underlying decision (behavior is data, not code) is
  the transferable part.
- The container-as-boundary permission model does **not** transfer. Crescent's
  caps-first rule is a strictly finer-grained mechanism and already exists;
  SWE-agent has nothing to contribute here beyond the blocklist idea.
- Tools emitting control tokens that steer the harness loop is a coupling that
  crescent's low-coupling rule would likely reject. **(inference)** Worth
  naming as a rejected pattern rather than rediscovering it.

**Open questions this survey does not answer** (they need a decision, not a
default):

- Curated ACI vs. shell-plus-model-judgment for crescent's target models.
- Whether the agent app's execution boundary is a process, a cap set, or a
  container — SWE-agent assumes container and crescent has no such assumption.
- Whether multi-attempt best-of-N belongs in `lib/ai` or in `lib/taskgraph`.
  SWE-agent puts it in the agent layer (`RetryAgent`); crescent already has an
  orchestration layer that could own it instead.

## Sources

- [SWE-agent repository](https://github.com/SWE-agent/SWE-agent) (redirected
  from `princeton-nlp/SWE-agent`)
- [SWE-agent: Agent-Computer Interfaces Enable Automated Software
  Engineering](https://arxiv.org/abs/2405.15793) — arXiv 2405.15793v3, NeurIPS
  2024. Full text extracted and read; §2 design principles, §3 ACI components,
  Tables 1-3, §5.1-5.2 analysis.
- [NeurIPS 2024 poster page](https://neurips.cc/virtual/2024/poster/93753)
- [docs/background/aci.md](https://github.com/SWE-agent/SWE-agent/blob/main/docs/background/aci.md)
- [docs/background/architecture.md](https://github.com/SWE-agent/SWE-agent/blob/main/docs/background/architecture.md)
- [docs/config/tools.md](https://github.com/SWE-agent/SWE-agent/blob/main/docs/config/tools.md)
- [docs/config/config.md](https://github.com/SWE-agent/SWE-agent/blob/main/docs/config/config.md)
- `sweagent/agent/agents.py`, `sweagent/agent/history_processors.py`,
  `sweagent/agent/reviewer.py`, `sweagent/environment/swe_env.py`,
  `sweagent/tools/parsing.py`, `config/default.yaml` (read from `main`)
- [SWE-ReX](https://github.com/SWE-agent/SWE-ReX)
- [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent)
- [Documentation site](https://swe-agent.com) (host was unreachable from this
  machine; content read from the equivalent files in the repo)
