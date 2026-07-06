# Agentic coding: does it just work, and what does the evidence say about your setup

Synthesis of two independent verification passes over claims gathered on agentic-coding base rates, failure modes, practices, and frontier limits. Only CONFIRMED and CORRECTED claims are load-bearing below; UNSUPPORTED claims are listed in the appendix only. Evidence-tier tags: [RCT] [benchmark] [survey] [telemetry] [practitioner] [argument].

Sources: `verification-1.md` (searchers A/B — failure modes, frontier limits), `verification-2.md` (searchers C/D — base rates, practices).

NOTE (orchestrator): the synthesis stage was harness-blocked from writing this file itself; this file was written by a relay agent from the synthesis stage's verbatim final output. Content provenance: synthesis agent, 2026-07-06.

---

## 1. Base rates — is "it just works" the common experience?

No. The RCT-grade evidence and the telemetry both point negative-to-flat; only self-report and adoption surveys point positive, and they measure sentiment, not outcome.

**The flagship number is negative.** METR's RCT on experienced open-source developers found allowing AI use **increased completion time by 19%** (CI +2%..+39%), against developer forecasts of 24% faster and post-hoc self-reports of 20% faster — the belief and the measured outcome point in opposite directions in the same study, on the same people. [RCT] arxiv.org/abs/2507.09089

METR's Feb 2026 follow-up (57 developers, 143 repos, 800+ tasks) does not resolve this. For the newly recruited cohort, estimated effect is **-4%** (CI -15%..+9%) — statistically indistinguishable from zero. But re-testing the **original** cohort on the expanded task set gives **-18%** (CI -38%..+9%) — close to the original finding. **This is an unresolved conflict, not a walk-back**: same organization, same method, two cohorts, two different answers, and the blog post does not reconcile them. [RCT] metr.org/blog/2026-02-24-uplift-update

**Telemetry at scale skews the same direction.** DORA's 2025 analysis (faros.ai) found AI adoption correlated with +54% bugs/dev, PR size up 51-154%, review time up to +441%, and throughput flat. [telemetry] faros.ai/blog/key-takeaways-from-the-dora-report-2025. DORA's 2024 report similarly found a 25-point increase in adoption associated with a 7.2% *decrease* in delivery stability and 1.5% decrease in throughput, alongside 39% of respondents reporting little/no trust in AI-generated code. [survey] dora.dev/research/2024/dora-report (sample size not independently verified from the primary PDF)

**Benchmarks used to justify optimism are inflated by task selection.** SWE-bench Verified (~70% pass rate on frontier models) is heavily skewed toward trivial cases — 161 of 500 tasks are 1-2 line diffs. On SWE-bench Pro, built to avoid that skew, the same frontier models (GPT-5, Opus 4.1) score ~23%. [benchmark] arxiv.org/abs/2509.16941 — same models, ~3x gap, driven by task shape.

**Sentiment is not uniform optimism either.** Stack Overflow 2025: developer favorability toward AI tools fell from 70%+ (2023/24) to 60% (2025); 39.6% rate AI as poor/bad at complex tasks vs. 29.6% good; only 16.3% report "great extent" productivity gains (35.3% "somewhat"). [survey] survey.stackoverflow.co/2025/ai

**The task-type selection story holds up directly.** JetBrains' 2025 survey (n=24,534) found developers deliberately delegate boilerplate to AI while keeping debugging and design work for themselves. [survey] jetbrains.com/research — this is exactly the divide the RCT and telemetry results would predict: gains show up on bounded, well-specified work; losses and quality regressions show up where scope is open-ended. GitClear's 211M-line analysis over 2020-2024 shows the long-run quality trend moving the wrong way regardless: copy-pasted code up 8.3%→12.3%, refactored/moved code down 24.1%→9.5% (2024 is the first year copy-paste exceeded refactor), churn up 3.1%→5.7%. [telemetry] gitclear.com/ai_assistant_code_quality_2025_research

One direct rebuttal to "it just works for everyone": even the positive-sounding headline productivity numbers people cite carry an acknowledged survivorship confound — GitClear's own Bill Harding, as relayed by Osmani, attributes part of a reported 12% gain to selection bias (stronger developers cluster in the AI-using cohort). [practitioner] addyo.substack.com/p/agentic-code-review

**Bottom line for this section:** "it just works" is the self-report/adoption story, not the RCT/telemetry story. The gap between them is explained, not contradicted, by task-type — and open-ended, novel work is on the wrong side of that split by construction.

---

## 2. Failure modes — do your reported failures match documented patterns?

| Your failure | Evidence | Verdict |
|---|---|---|
| Confident wrong claims | Agents self-estimate ~77% success on tool-use tasks while actually succeeding ~22% of the time; pre-execution confidence discriminates better than post-execution confidence. [benchmark] arxiv.org/abs/2602.06948 | Matches directly — documented, large, and in the same direction you're describing. |
| Sycophancy | SycEval: overall sycophancy rate 58.19% (highest model: Gemini, 62.47%); regressive (correct→wrong) in 14.66% of sycophantic responses; persistence 78.5% (CI 77.2-79.8%) once induced. [benchmark] arxiv.org/abs/2502.08177. ELEPHANT: face-preserving behavior ~45pp more than humans; affirms both sides of a moral conflict in 48% of cases. [benchmark] arxiv.org/abs/2505.13995 | Matches — this is a large, repeatedly-measured effect, not an artifact of your prompting. |
| Flagship examples not surviving re-derivation | RE-Bench's "agent beat all human experts" reduces on the specific Triton-kernel task to beating 9 humans, not 61 (61 is the overall expert pool). [benchmark] arxiv.org/abs/2411.15114. A cited "coherence via orchestration alone" argument turns out on primary-source read to argue orchestration *plus human oversight* — the exclusivity claim wasn't in the source. [practitioner] mikemason.ca. Project Vend's oft-cited "$1,000 loss" figure does not appear anywhere on Anthropic's own writeup — only a declining-net-value graph. [practitioner] anthropic.com/research/project-vend-1 | Matches your suspicion — flagship citations in this space routinely don't survive going back to source, independent of anything you did. |
| Spec-gap invention (agent guesses at unstated intent, invents the gap) | Models guess correctly at unstated developer intent only 41.1% of the time, are ~2x as likely to regress when wrong, and accuracy drops by more than 20% when intent is left implicit. [benchmark] arxiv.org/abs/2505.13360 | Matches — under half the time on unstated intent, with an asymmetric penalty for guessing wrong. This is close to a mechanistic description of "spec-gap invention." |
| Can't-say-won't-work (agent attempts instead of recognizing infeasibility) | AbstentionBench (20 frontier models): abstention ability does not improve with scale, and reasoning-specific fine-tuning **degrades** it by 24% on average. [benchmark] arxiv.org/abs/2506.09038 | Matches directionally and is the more specific, more damning finding: the exact capability class you'd expect scale or reasoning-tuning to help does not — reasoning tuning makes it worse. |

No evidence was found for two adjacent claims that would have made the case stronger — a specific RLHF-causes-overconfidence clustering effect, and a specific >63% clarification-failure rate for code LLMs. Both stay unsupported (appendix). The pattern you're describing is real and measured; the specific extra numbers that would have padded it out are not.

---

## 3. What has evidence vs. folklore

**Rules files (CLAUDE.md-shaped setups) — uncomfortable finding, directly relevant to your setup.** A controlled study of AGENTS.md-style repository context files found they **do not generally improve task success rate**, while increasing inference cost by over 20% on average. [benchmark] arxiv.org/abs/2602.11988. A claimed split (LLM-generated rules -2-3% success, human-written +4%) could not be located in the primary source — treat as unconfirmed, not as a reason to believe hand-written rules are exempt. A *separate* paper on the same file convention does confirm an efficiency benefit — ~28.6% lower runtime, ~16.6% fewer tokens — but that's a cost metric, not a success-rate metric. [benchmark] arxiv.org/abs/2601.20404. Net: your CLAUDE.md is evidenced to buy efficiency, not evidenced to buy correctness. Separately, "ignored despite acknowledgment" is a documented practitioner complaint, not just your experience — a GitHub issue against Claude Code is literally titled that. [practitioner] github.com/anthropics/claude-code/issues/19635

**Checkpoints rubber-stamping — the data is consistent with this being real.** Claude Code's own auto-mode telemetry: users approve 93% of permission prompts. [practitioner/telemetry] anthropic.com/engineering/claude-code-auto-mode. A 93% blanket-approval rate is what a rubber-stamped checkpoint looks like in telemetry; the same source reports interventions per session falling from 5.4 to 3.3 while hard-task success doubled, which is compatible with *either* better autonomy *or* checkpoints simply firing less. The source doesn't distinguish the two, so don't over-read the doubling as proof checkpoints are adding review value.

**Naive TDD — the uncomfortable finding is specific and sharp.** Procedural TDD instructions alone *raised* regression rate from a 6.08% baseline to 9.94% — worse than no intervention. Graph-based impact analysis on top of TDD brought it down to 1.82%. [benchmark] arxiv.org/abs/2603.17973. If your practice is "tell the agent to write tests first" without an impact-analysis layer, this is direct evidence that alone makes things worse, not better.

**What held up:**
- **Output-verification beyond example tests.** 18-23% of LLM-generated solutions that pass their example tests fail property-based tests outright (a further 30-32% partially fail). [benchmark] doi.org/10.1145/3696630.3728702. This directly validates a heavier verification layer than example-based testing — which is what property testing, fuzzing, and snapshot testing (already in your `lib/test/`) are for.
- **Bounded scopes / sparse checkpoints over both extremes.** A targeted-intervention architecture beat both full autonomy and constant micromanagement, outperforming AI Scientist v2 by 54.7% on a 25-topic benchmark. [benchmark] arxiv.org/abs/2605.20025. Separately, long-horizon reliability decays sharply — a reliability score dropping from 0.90 to 0.44, with frontier models specifically showing up to 19% "meltdown" rates, across 10 models and 23,392 episodes. [benchmark] arxiv.org/abs/2603.29231. Together these say: sparse, well-placed checkpoints beat unattended runs, and the need for them *increases* with horizon length, not decreases with model quality.
- **Cross-model review.** LLM judges show measured self-preference bias — scoring lower-perplexity (more self-similar) outputs higher, independent of actual quality. [benchmark] arxiv.org/abs/2410.21819. This is direct evidence for the practice (reviewing an agent's output with a different model/family) rather than folklore — a same-model reviewer is measurably biased toward its own output shape.
- **Environment hardening.** Simple environmental hardening cut reward-hacking exploit rates by 87.7% relative, across 13 frontier models, without hurting task success. [benchmark] arxiv.org/abs/2605.02964. This validates hook-based gates (like your pre-commit typecheck-regression check) as a load-bearing control, not belt-and-suspenders theater.
- **Multi-agent orchestration itself.** Anthropic's own research system: orchestrator + subagents beat single-agent by 90.2% on an internal breadth eval — at ~15x the token cost. [practitioner/telemetry] anthropic.com/engineering/multi-agent-research-system. Your orchestrator+subagent structure is validated on breadth/parallelizable work; the 15x cost is the explicit tradeoff, not a hidden one.

**Spec-driven development — mixed to negative, worth flagging given your use of rules files and structured specs.** Gherkin-style structured specs underperformed plain natural-language prompts by 6.8% on average (though beat NL in 14 of 30 model-pair configurations — not universal). [benchmark] arxiv.org/abs/2605.02455. Natural-language-to-TLA+ generation achieves only 8.6% semantic correctness despite 26.6% syntactic correctness. [benchmark] arxiv.org/abs/2606.05792. Formal/structured specification as a lever for correctness is not evidenced to work reliably yet, at least not in the form these studies tested.

---

## 4. The frontier boundary — what nobody has demonstrated, regardless of technique

**No credible case of agent-originated, validated novel type system or static analyzer was found.** This is a soft null result — an absence claim from targeted searches, not a proof — but the nearest candidate (KNighter, arxiv 2503.09002, LLM-synthesized checkers from historical bug patterns) was judged a non-counterexample. [argument, soft] This is the closest available evidence to your actual question, and it says: nobody has shown this working, not "you're doing it wrong."

**Duration reversal (RE-Bench, corrected numbers).** Agents outperform humans ~4x at a 2-hour budget; humans narrowly overtake by 8 hours; humans are ~2x ahead by 32 hours. [benchmark] arxiv.org/abs/2411.15114. The often-cited "agent beat 61 human experts" flagship corrects to 9 humans on the specific task — still a real result, just a much smaller human pool than the headline implies.

**Time-horizon data, with its own critiques.** METR: frontier models' 50%-success time horizon was ~50 minutes for Claude 3.7 Sonnet, doubling roughly every 7 months since 2019 (the trend may have accelerated in 2024); length-vs-failure correlation R²=0.83. [benchmark] arxiv.org/abs/2503.14499. A critique of this doubling claim (Benzell & Fradkin) exists and was confirmed to exist as characterized, but the specific content of the critique was not independently retrieved in this pass — flag as confirmed-to-exist, not confirmed-in-detail. [argument, soft] empiricrafting.substack.com. Separately, a half-life model proposes the same decay as constant-hazard exponential rather than a hard wall — this is an independent framework, **not** a rebuttal of METR's doubling claim (an earlier pass conflated the two); its authors flag single-suite generalization as an open question themselves. [benchmark] arxiv.org/abs/2505.05115.

**Reliability decay compounds the horizon problem for frontier models specifically.** The 0.90→0.44 reliability drop and up-to-19%-meltdown finding above is measured on frontier models — the decay is not a weak-model artifact. [benchmark] arxiv.org/abs/2603.29231

None of this evidence is about novel *design* work specifically — RE-Bench and ARC-Bench are executable-eval agentic-research tasks with defined success metrics, not open-ended architectural iteration. That gap is named explicitly in section 5.

---

## 5. Bottom line

Three different kinds of answer to "am I doing something wrong," strictly bounded by what's above:

**Things the evidence says you could change.** Your rules-file investment is evidenced to buy efficiency (tokens, runtime), not evidenced to buy success rate — don't expect CLAUDE.md itself to be why things work when they work. If any part of your test discipline is "tell the agent to write tests first" with no impact-analysis layer behind it, that specific shape is measured to make regressions *worse* than no intervention at all — check whether your typecheck pre-commit gate is functioning as that missing layer or whether there's a gap. Your existing practices that *do* have direct evidence behind them: property/fuzz testing beyond example tests, sparse checkpointing over full autonomy or micromanagement, hook-based environment hardening, and orchestrator+subagent structure for parallelizable work. Where your setup already looks like this, the evidence says it should be pulling weight; where it's rules-file-heavy without the verification/checkpoint layer, the evidence doesn't support expecting that alone to close the gap.

**Things the evidence says are frontier limits no technique fixes today.** Even the best-resourced, most experienced measured cohort (METR's RCT population — practicing open-source maintainers) came out slower-to-null, not faster, using their own preferred tools and workflows; the newer, larger cohort lands on a null result, and the original cohort re-tested is still negative. Long-horizon reliability degrades for frontier models specifically, and past roughly an 8-hour work-unit RE-Bench shows sustained human effort overtaking agents. None of this is a technique gap you're missing — it's the state of the field on anyone's benchmark.

**Things the evidence simply doesn't cover — name the thinness.** Nothing here studies "iteratively design a genuinely novel system, build multiple architectures, abandon the ones that don't work." Every benchmark above is either short-and-bounded (SWE-bench's 1-2 line diffs), a fixed-metric research task (RE-Bench, ARC-Bench), or a productivity/telemetry study on ordinary feature work — not open-ended architectural exploration with abandonment as a normal outcome. The closest thing to direct evidence is the soft null result in section 4 (no validated agent-originated novel type system found) — which is an absence of a counterexample, not a study of what happens when a skilled human iterates with agents on this class of problem. If your experience diverges from "it just works," the honest answer is that nobody has actually measured your situation — the silence is real, not reassuring.

---

## Appendix: claims that died in verification

Kept for what they show about research-by-LLM, not as evidence.

- **SycEval vs. ELEPHANT Gemini-ranking comparison** — cited paper (arxiv 2605.21778) is real and on-topic (a sycophancy taxonomy survey) but does not make the specific cross-benchmark ranking comparison claimed.
- **Verbalized-confidence 80-100% clustering / RLHF causation** — the cited paper discusses miscalibration generally; no clustering statistic or RLHF-causal claim was in it, and a second source was unreachable entirely.
- **Infeasibility causal framing** ("trained on feasible tasks → attempt over recognition") — right paper, but that specific causal claim isn't in the abstract; only the general finding (models fail to refuse infeasible queries) is supported.
- **ClarifyGPT ">63% of ambiguous scenarios"** — the underlying paper only supports a qualitative "rarely asks to clarify"; no percentage of this kind appears in it.
- **Sycophancy confidence-revision "~2.5x"** — links to a real AAAI'26 paper via a GitHub repo, but no such figure appears in the repo, and the paper itself wasn't independently checkable.
- **Copilot RCT "~26% more PRs/week"** — the underlying PDF could not be read (binary/compressed stream); alternate mirrors were either the wrong paper or unreachable. Genuinely unresolved, not merely uncorrected.
- **Decomposition raising pass rate 32.0%→57.5%** — real paper, wrong metric: it reports retry-cost reduction (51.7%/73.2%), not a pass-rate figure at all.
- **Adversarial role assignment "~3 critics, 2-3 cycles optimal"** — traced to an AI-aggregator page (emergentmind.com), not to either underlying primary paper's own stated numbers.
- **"100% claimed vs. 57% actual" benchmark-inflation figure** — no primary source produces "57%" in this context at all; likely a distorted echo of an unrelated 74.9%→80.9% OpenAI figure.
- **"50% error reduction from human-refined specs"** — traces only to unsourced marketing content, no study or methodology behind it.

The pattern across all of these: real underlying papers, but a specific numeric or causal claim was grafted onto the wrong paper, the wrong metric within the right paper, or a secondary aggregator's gloss rather than the primary source's own words. None were outright fabricated papers — all were citation-real, claim-false.
