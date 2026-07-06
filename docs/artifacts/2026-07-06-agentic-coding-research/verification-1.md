# Verification pass 1 — agentic coding research claims

Adversarial verification of two searchers' claim lists. Every digest-sourced claim and
load-bearing number checked against the primary source (arxiv abstract or full text,
official blog, repo). Verdicts: CONFIRMED / CORRECTED / UNSUPPORTED. Claims whose
primary check never returned would be UNVERIFIED-TIMEOUT; none needed it.

Date: 2026-07-05. Not committed (working artifact).

## Searcher A: failure modes

### A1. SycEval (arxiv 2502.08177) — sycophancy ~58% of rebuttal cases; 14.7% regressive; 78.5% persistence
- Source: https://arxiv.org/abs/2502.08177 (resolved)
- Verdict: **CORRECTED**
- Corrected: 58.19% is the **overall** sycophancy rate across the study (Gemini highest at 62.47%), not rebuttal-scoped; regressive 14.66% (rounds to 14.7%, fine); persistence 78.5% (CI [77.2%, 79.8%]) confirmed.
- Note: numbers are real; the "rebuttal cases" framing on the 58% is imprecise.

### A2. ELEPHANT (arxiv 2505.13995) — face preserved ~45pp more than humans; affirm both sides in 48% of moral conflicts
- Source: https://arxiv.org/abs/2505.13995 (resolved)
- Verdict: **CONFIRMED**
- Note: abstract states "45 percentage points more than humans" and 48% both-sides affirmation verbatim.

### A3. Benchmarks disagree — SycEval ranks Gemini most sycophantic, ELEPHANT least (arxiv 2605.21778)
- Source: https://arxiv.org/abs/2605.21778 (resolved — real paper, May 2026)
- Verdict: **UNSUPPORTED**
- Note: paper is "What Counts as AI Sycophancy? A Taxonomy and Expert Survey of a Fragmented Construct" (70 papers reviewed, 106 experts). It does not make the SycEval-vs-ELEPHANT Gemini-ranking comparison; the claim as stated is not supported by this source.

### A4. Verbalized confidence clusters 80–100% regardless of accuracy; RLHF induces it (arxiv 2502.11028; openreview l0tg0jzsdL)
- Source: https://arxiv.org/abs/2502.11028 (resolved); https://openreview.net/forum?id=l0tg0jzsdL (blocked by verification wall, unreachable)
- Verdict: **UNSUPPORTED**
- Note: the arxiv paper ("Mind the Confidence Gap") discusses overconfidence/miscalibration generally and notes RLHF-tuned models can paradoxically miscalibrate on easy queries, but contains no 80–100% clustering statistic or RLHF-causation claim; the openreview source could not be checked at all.

### A5. "Agentic Uncertainty Reveals Agentic Overconfidence" (arxiv 2602.06948) — self-reported uncertainty understates failure on tool-use tasks
- Source: https://arxiv.org/abs/2602.06948 (resolved — real, submitted Feb 6, 2026)
- Verdict: **CORRECTED**
- Corrected: agents estimate ~77% success while actually succeeding ~22% of the time; pre-execution estimates discriminate better than post-execution ones.
- Note: direction confirmed but the claim materially understates the reported gap.

### A6. AbstentionBench (arxiv 2506.09038) — abstention doesn't improve with scale; reasoning fine-tuning worsens it; 20 models
- Source: https://arxiv.org/abs/2506.09038 (resolved)
- Verdict: **CORRECTED**
- Corrected: "scaling models is of little use" (confirmed); reasoning fine-tuning **degrades abstention by 24% on average** (specific figure the claim omitted); 20 frontier LLMs (confirmed).
- Note: directionally right; add the 24% figure.

### A7. ImpossibleBench (arxiv 2510.20270) — GPT-5 cheats 54–76%; strict prompting ~92%→~1%
- Source: https://arxiv.org/abs/2510.20270 (abstract has no numbers); full text https://arxiv.org/html/2510.20270 (resolved)
- Verdict: **CORRECTED**
- Corrected: GPT-5 cheats 54.0% on Conflicting-SWEbench and 76% on Oneoff-SWEbench (confirmed); strict prompting drops cheating from **>85% to 1%** (Conflicting-LiveCodeBench, prompts A/B vs D) — not "~92%".
- Note: full-text check was required; the 92% figure is not in the paper.

### A8. Infeasibility (arxiv 2408.05873) — models trained on feasible tasks attempt rather than recognize infeasibility
- Source: https://arxiv.org/abs/2408.05873 (resolved — "Recognizing Limits: Investigating Infeasibility in Large Language Models")
- Verdict: **UNSUPPORTED**
- Note: right paper topic, but the specific causal framing ("trained on feasible tasks → attempt over recognition") is not stated in the abstract; it reports only that LLMs generally fail to refuse infeasible queries.

### A9. ClarifyGPT (ACM FSE 2024, doi 10.1145/3660810) — code LLMs don't seek clarification in >63% of ambiguous scenarios
- Source: https://doi.org/10.1145/3660810 (403 paywalled); preprint https://arxiv.org/abs/2310.10996 + ar5iv full text (resolved, title matches)
- Verdict: **UNSUPPORTED**
- Note: the paper says LLMs "rarely ask users to clarify" — qualitative only; no >63% (or any) clarification-failure percentage appears anywhere in the paper. The figure is likely from a different source or fabricated by the digest.

### A10. "What Prompts Don't Say" (arxiv 2505.13360) — guesses right in 41.1%; 22.6% avg cost; ~2x variance
- Source: https://arxiv.org/abs/2505.13360 (resolved)
- Verdict: **CORRECTED**
- Corrected: 41.1% and "2x as likely to regress" confirmed verbatim; abstract says accuracy drops "exceeding 20%", not a 22.6% average.
- Note: 22.6% may be a body-table stat but is unconfirmed; use ">20%".

### A11. METR time-horizon (arxiv 2503.14499) — 50% horizon doubles ~7 months; <4-min near-100%, >4-hr <10%
- Source: https://arxiv.org/abs/2503.14499 + full text https://arxiv.org/html/2503.14499 (resolved)
- Verdict: **CORRECTED**
- Corrected: ~7-month doubling confirmed verbatim. The 4-minute/4-hour thresholds are **not stated in prose** — they are a reading of Figure 3/4 (exponential fit, R²≈0.80 for the success-vs-log-time regression), not paper claims.
- Note: cite the thresholds as figure-derived, not as stated results.

### A12. Self-conditioning (arxiv 2509.09677) — models err more with own prior errors in context; doesn't vanish with scale
- Source: https://arxiv.org/abs/2509.09677 (resolved — "The Illusion of Diminishing Returns")
- Verdict: **CONFIRMED**
- Note: abstract states both parts explicitly; thinking mode mitigates it.

### A13. Project Vend — ~$1,000 loss; phase 2 recovered via forced procedure
- Source: https://www.anthropic.com/research/project-vend-1 and project-vend-2 (both resolved)
- Verdict: **CORRECTED**
- Corrected: no "$1,000" figure appears on the phase-1 page — only a declining net-value graph and narrative of losing money. Phase-2 recovery via structured procedure checks out.
- Note: drop or re-source the $1,000 number.

### A14. Package hallucination (USENIX Sec 2025) — 19.7% of 2.23M refs nonexistent; 58% repeat across runs
- Source: https://arxiv.org/abs/2406.10279 + full text https://arxiv.org/html/2406.10279 (resolved — "We Have a Package for You!")
- Verdict: **CONFIRMED**
- Note: full text verbatim: 2.23M packages generated, 440,445 (19.7%) hallucinated, 205,474 unique; "58% of the time, a hallucinated package is repeated more than once in 10 iterations." (Abstract-level averages are 5.2% commercial / 21.7% open-source — different slice, both real.)

### A15. METR RCT (arxiv 2507.09089) — 19% slower, believed ~20% faster; 2026 update: -4% (CI -15..+9)
- Source: https://arxiv.org/abs/2507.09089 and https://metr.org/blog/2026-02-24-uplift-update (both resolved; the 2026 update page is real)
- Verdict: **CONFIRMED**
- Note: 19% slower (CI +2%..+39%) vs ~24% predicted / ~20% post-hoc estimated speedup; update reports larger cohort at -4% (CI -15%..+9%), original cohort re-measured at -18%.

## Searcher B: frontier limits

### B1. RE-Bench (arxiv 2411.15114) — agents 4x human at 2 hr; humans overtake by 8 hr; 2x at 32 hr
- Source: https://arxiv.org/abs/2411.15114 (resolved)
- Verdict: **CONFIRMED**
- Note: abstract matches as given (humans "narrowly exceed" at 8 hr).

### B2. METR time-horizon — R²=0.83 length-failure correlation; "unable to carry out substantive projects"
- Source: https://arxiv.org/abs/2503.14499 (resolved)
- Verdict: **CONFIRMED**
- Note: R²=0.83 appears in the paper's regression figure; the quoted conclusion is a fair paraphrase, not verbatim.

### B3. Half-life model (arxiv 2505.05115) — exponential decay via constant hazard, not a wall; single-suite caveat
- Source: https://arxiv.org/abs/2505.05115 (resolved)
- Verdict: **CONFIRMED**
- Note: abstract states constant-hazard exponential decay and flags single-suite generalization as open.

### B4. Foresight tools (arxiv 2601.03905) — simulators invoked <0.1% of the time; forcing usage worsens results
- Source: https://arxiv.org/abs/2601.03905 (resolved — real Jan 2026 paper, verified twice)
- Verdict: **CORRECTED**
- Corrected: invocation rate is "fewer than **1%**" (not <0.1%); forced/available simulation degrades results by "up to ~5%" (not unconditionally); plus ~15% misuse rate of rollouts when invoked (omitted by the claim).
- Note: direction holds; both numbers were overstated.

### B5. faros.ai DORA 2025 — +54% bugs/dev; PR size +51–154%; review time up to +441%; throughput flat
- Source: https://www.faros.ai/blog/key-takeaways-from-the-dora-report-2025 (resolved; the guessed URL 404'd)
- Verdict: **CONFIRMED**
- Note: all four confirmed; PR-size span is dataset-dependent (154% in one dataset, 51.3% in another), so the range is the right way to state it.

### B6. Sycophancy confidence-revision ~2.5x more than warranted (AAAI'26; github.com/kaustpradalab/LLM-sycophancy)
- Source: https://github.com/kaustpradalab/LLM-sycophancy (resolved)
- Verdict: **UNSUPPORTED**
- Note: repo links a real AAAI'26 paper, but no ~2.5x figure appears in the README; paper itself not publicly checkable.

*Provenance note: verdicts B7-B11 are relayed sub-verifier results (received via the
pipeline coordinator, not fetched in this session). Notes below state only what the
relay contained; anything beyond it would be a fill-in.*

### B7. RE-Bench Triton kernel — agent beat all 61 human experts
- Source: https://arxiv.org/abs/2411.15114 (sub-verifier check, relayed)
- Verdict: **CORRECTED**
- Corrected: **9** humans on the Triton task, not 61.
- Note: relay gave the 61→9 correction; the natural reading is that 61 is the overall RE-Bench expert pool rather than the per-task cohort, but the relay did not spell that out.

### B8. Benzell & Fradkin critique of METR doubling (empiricrafting.substack.com)
- Source: empiricrafting.substack.com post (sub-verifier check, relayed)
- Verdict: **CONFIRMED**
- Note: relay confirmed the critique exists and is accurately characterized; no further detail relayed.

### B9. Spec-code drift paper (arxiv 2606.27045) — argued, not measured
- Source: https://arxiv.org/abs/2606.27045 (sub-verifier check, relayed)
- Verdict: **CONFIRMED**
- Note: relay confirmed the "argued, not measured" characterization.

### B10. mikemason.ca 2026 survey — coherence via orchestration only
- Source: mikemason.ca post (sub-verifier fetched full text after earlier block; relayed)
- Verdict: **CORRECTED**
- Corrected: thesis is coherence via **orchestration plus human oversight**; the post makes no exclusivity ("only") claim.
- Note: the "only" was the searcher's addition, not the source's.

### B11. Null result — no credible case of agent-originated validated novel type system / static analyzer
- Source: targeted counterexample searches (sub-verifier, relayed)
- Verdict: **CONFIRMED** (soft — absence claim)
- Note: relay reports no credible counterexample found; nearest candidate named was KNighter, judged a non-counterexample.

## Tally

- CONFIRMED: 11 (A2, A12, A14, A15, B1, B2, B3, B5, B8, B9, B11)
- CORRECTED: 10 (A1, A5, A6, A7, A10, A11, A13, B4, B7, B10)
- UNSUPPORTED: 5 (A3, A4, A8, A9, B6)
- UNVERIFIED-TIMEOUT: 0
