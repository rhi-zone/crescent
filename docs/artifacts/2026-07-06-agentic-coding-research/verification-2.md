# Adversarial verification — pass 2 (searchers C & D)

Date: 2026-07-06. Method: each load-bearing number checked against its primary
source via WebFetch (4 parallel verifier agents; orchestrator spot-checked the
batch-4 verdicts directly against arxiv 2510.20270 and 2605.21384 before
accepting them). Verdicts: CONFIRMED / CORRECTED / UNSUPPORTED.

## Tally

- Searcher C (base rates, 13 claims): 6 CONFIRMED, 6 CORRECTED, 1 UNSUPPORTED
- Searcher D (practices, 14 claims): 10 CONFIRMED, 2 CORRECTED, 2 UNSUPPORTED
- Total: 27 claims — 16 CONFIRMED, 8 CORRECTED, 3 UNSUPPORTED
- Known-bad numbers ("100% vs 57%", "50% error reduction from human-refined
  specs"): both stay dead — no legitimate source found for either.

## Most consequential corrections

1. **ImpossibleBench citation swap (D11).** arxiv 2605.21384 is SpecBench, not
   ImpossibleBench; it holds the 28pp-per-10x-code-size number. The 76% GPT-5 /
   46% Opus 4.1 tampering rates belong to the real ImpossibleBench paper,
   arxiv 2510.20270. Two real findings merged under one wrong ID.
2. **Stack Overflow 2025 cross-question conflation (C10).** "41.4% say AI bad at
   complex tasks" is wrong — actual is 39.6% bad vs 29.6% good. 41.4% is real
   but answers a different question (share reporting "not at all/minimally" more
   productive). Sample-size "inconsistency" resolved: 49,009 raw responses vs
   33,662 qualified respondents — both correct, different funnel stages.
3. **Decomposition pass-rate figure unsupported (D1).** arxiv 2605.15425 is real
   but reports retry-cost reductions (51.7% / 73.2%), not a 32.0%→57.5% pass
   rate. Wrong metric attached to a real paper.

Also notable: METR Feb-2026 update's "30-50% invite decline" is not on the page
and the claim omits the -18% original-cohort re-test estimate (C1); the
"half-life dispute" paper (2505.05115) doesn't dispute METR at all (C8); the
critic-sycophancy "~3 critics, 2-3 cycles" numbers are an emergentmind.com
gloss, not a primary-source finding (D7); the Copilot ~26% RCT stat could not
be verified from any reachable copy of the paper (C2); the "-2-3% LLM-generated
/ +4% human-written" rules-file split was not locatable in 2602.11988 (D12).

---
# Batch 1 verification — Searcher C: base rates

## 1. METR RCT (arxiv 2507.09089)
- Claim: "19% slower / predicted 24% faster / self-reported 20% faster; n=16 devs, 246 issues." Plus a claimed Feb 2026 update at metr.org/blog/2026-02-24-uplift-update: "30-50% invite decline; larger cohort -4% (CI -15..+9)".
- Source checked: https://arxiv.org/abs/2507.09089, https://metr.org/blog/2026-02-24-uplift-update
- Verdict: CONFIRMED (original RCT numbers) / CORRECTED (blog update details)
- Detail: arxiv 2507.09089 confirms all four original numbers verbatim: "allowing AI actually increases completion time by 19%", developers forecast "24%" reduction, self-reported "20%" reduction, "16 developers", "246 tasks". The blog post DOES exist (real, dated 2026-02-24, titled "We are Changing our Developer Productivity Experiment Design") — not a fabricated future-dated source. It reports a larger follow-up study (57 developers total: 10 original + 47 new, 143 repos, 800+ tasks). For newly-recruited developers the estimated speedup is -4% (CI -15% to +9%) — this matches the claim exactly. But for the subset of original developers re-tested, the estimate is -18% (CI -38% to +9%), not mentioned in the claim. The blog does NOT state a "30-50% invite decline" figure anywhere — that detail is unsupported/unfound on the page.
- Note: original RCT stats are solid; the blog exists and the "-4%, CI -15..+9" figure is accurate for new devs, but "30-50% invite decline" appears fabricated or misattributed, and the claim omits the -18% original-cohort re-test figure.

## 2. Copilot RCT (~26% more PRs/week)
- Claim: "~26% more PRs/week, 4,500+ devs, juniors gain more" citing Management Science 2025 paper at demirermert.github.io/Papers/Demirer_AI_productivity.pdf
- Source checked: https://demirermert.github.io/Papers/Demirer_AI_productivity.pdf (also tried NBER w31161, SSRN 4573321, Stanford GSB page — all failed/wrong paper)
- Verdict: UNSUPPORTED
- Detail: The PDF fetched but returned only binary/compressed stream data unreadable by the fetch tool — no text could be extracted. Alternate mirrors tried: NBER w31161 turned out to be a different paper entirely (Brynjolfsson/Li/Raymond customer-support-agent study, 14% avg / 34% novice gains — not Copilot). SSRN and Stanford GSB URLs guessed at were 403/404 and not verifiable as the right paper.
- Note: could not confirm or refute the 26%, 4,500+ devs, or junior-gains-more claims from any reachable source in this pass — needs a text-extractable copy (HTML abstract, arXiv/SSRN with working full text) to verify.

## 3. Answer.AI Devin log (3/20 tasks succeeded)
- Claim: "3/20 tasks succeeded" citing answer.ai/posts/2025-01-08-devin.html
- Source checked: https://www.answer.ai/posts/2025-01-08-devin.html
- Verdict: CONFIRMED
- Detail: Page states "14 failures, 3 inconclusive results, and just 3 successes" out of 20 tasks — exactly matches the claimed 3/20.
- Note: clean confirm, no issues.

## 4. SWE-bench Verified ~70% vs SWE-Bench Pro ~23% (same family)
- Claim: SWE-bench Verified ~70% vs SWE-Bench Pro ~23% for the same model family, citing arxiv 2509.16941
- Source checked: https://arxiv.org/html/2509.16941v1 (abs page was too thin; HTML full-text version worked)
- Verdict: CONFIRMED
- Detail: Paper states "state-of-the-art agents have reported over 70% pass rate on SWE-Bench-Verified"; on SWE-Bench Pro, GPT-5 scores 23.3% and Claude Opus 4.1 scores 22.7% on the public set — both close to the claimed ~23%.
- Note: solid confirm; "~23%" is an accurate rounding of both cited frontier models' Pro scores.

## 5. SWE-bench Verified skew (24.5% under 15 min; 161/500 are 1-2 line diffs)
- Claim: "24.5% under-15-min tasks; 161/500 are 1-2 line diffs" citing openai.com/index/introducing-swe-bench-verified
- Source checked: https://openai.com/index/introducing-swe-bench-verified (403 Forbidden, also tried trailing-slash variant, google cache, web.archive.org — all failed to load); secondary corroboration via arxiv 2509.16941 (SWE-Bench Pro paper), which cites SWE-bench Verified figures
- Verdict: CORRECTED / UNSUPPORTED (mixed)
- Detail: Could not load the primary OpenAI source directly (blocked/403 on all attempted routes). The SWE-Bench Pro paper (2509.16941) independently states SWE-bench Verified includes "trivial problems (161 out of 500) that require only one- to two-line modifications" — this exactly matches and corroborates the 161/500 claim via a secondary citation. However, the "24.5% under 15 minutes" figure was not found or corroborated anywhere in this pass.
- Note: 161/500 figure stands (corroborated secondhand); 24.5%-under-15-min figure remains unverified — primary source unreachable.

## 6. Resolve rate drops sharply with files-touched count
- Claim: qualitative claim that resolve rate drops sharply with number of files touched, same source as #4 (arxiv 2509.16941)
- Source checked: https://arxiv.org/html/2509.16941v1
- Verdict: CORRECTED
- Detail: The paper does NOT provide a direct table/quantitative breakdown of resolve rate by file count. It does note SWE-Bench Pro problems average 4.1 files per solution and 107.4 lines of code on average, contrasted with SWE-bench Verified's much simpler single-file/1-2-line-diff problems — used as qualitative motivation for why Pro is harder, but there's no explicit "resolve rate drops sharply as files-touched increases" regression/table in the fetched content.
- Note: the general direction (more files = harder = lower resolve rate) is implied by the benchmark design/framing, but the specific quantitative claim ("drops sharply") isn't directly evidenced by a stated figure in this source — treat as a reasonable inference, not a directly-stated finding.

## 7. METR horizon (~50 min for Claude 3.7 Sonnet, doubling ~7 months)
- Claim: "~50 min for Claude 3.7 Sonnet, doubling ~7 months" citing arxiv 2503.14499
- Source checked: https://arxiv.org/abs/2503.14499
- Verdict: CONFIRMED
- Detail: "current frontier AI models such as Claude 3.7 Sonnet have a 50% time horizon of around 50 minutes"; "frontier AI time horizon has been doubling approximately every seven months since 2019, though the trend may have accelerated in 2024."
- Note: clean confirm, both numbers stated verbatim.
## 8. "Half-life dispute" (arxiv 2505.05115)
- Claim: "Half-life dispute" citing arxiv 2505.05115
- Source checked: https://arxiv.org/abs/2505.05115
- Verdict: CORRECTED
- Detail: The paper is titled "Is there a half-life for the success rates of AI agents?" It proposes that AI agent success rate on long tasks decays exponentially, modeled as a constant per-minute failure rate, allowing each agent to be characterized by a "half-life." It contains NO discussion of METR, no mention of "task horizon doubling every N months," and does not dispute any external capability-forecast claim. It explicitly says whether the model generalizes to other task suites is "unknown."
- Note: The "dispute" framing is unsupported by the source — this paper *introduces* the half-life concept for agent task success decay; it isn't shown to be disputing METR's doubling-time claim (that link may be the searcher's own inference, not something the paper states).

## 9. DORA 2024: AI adoption vs stability/throughput/trust
- Claim: 25% AI adoption ↑ → 7.2% stability ↓, 1.5% throughput ↓; 39% low/no trust. N inconsistent across citations.
- Source checked: https://dora.dev/research/2024/dora-report/ (landing page; full PDF not directly fetchable) + secondary coverage (InfoQ, TheNewStack, Medium recap)
- Verdict: CONFIRMED (core three numbers), UNSUPPORTED (N / the "25%" figure)
- Detail: Secondary sources consistently report: a 25% increase in AI adoption is associated with a 7.2% decrease in delivery stability and a 1.5% decrease in delivery throughput; 39% (also reported as 39.2%) of respondents report little/no trust in AI-generated code. These three numbers check out consistently across multiple independent secondary sources. However, the official dora.dev landing page itself does not surface these exact figures or a sample size — it only gives the qualitative headline. I could not independently pull the total N from the primary PDF (fetch only returned the landing page, not full report body).
- Note: Numbers are corroborated by multiple secondary sources reporting on the same primary PDF, but I could not verify N directly from the primary source — treat N as still unresolved pending a direct PDF read.

## 10. Stack Overflow 2025 Survey: favorability & complex-task sentiment
- Claim: favorability ~60-70% down from 70%+; 41.4% say AI bad at complex tasks vs 29.9% good. Sample size inconsistency 33,662 vs 49,009.
- Source checked: https://survey.stackoverflow.co/2025/ai
- Verdict: CORRECTED
- Detail: Favorability: confirmed — 60% favorable in 2025, down from 70%+ in 2023/2024 (72%→60% cited elsewhere). Complex-task sentiment: actual figures are 39.6% say AI is poor/bad at complex tasks ("Bad" 22% + "Very poor" 17.6%) vs 29.6% say good ("Very well" 4.4% + "Good but not great" 25.2%) — not 41.4%/29.9% as claimed. Notably, 41.4% is a *real* figure from the same survey but for a different question: it's the share reporting AI has made them "not at all or minimally" more productive (a productivity-impact question, not the complex-task-quality question). This looks like a cross-question conflation by the searcher.
- Sample size: both numbers are real and both correct for different things — 49,009 is the total number of survey responses received; ~33,662 is commonly cited as the qualified/retained respondent count after filtering (roughly 15,000 excluded for age/consent/etc). Not an inconsistency — they measure different stages of the funnel.

## 11. JetBrains 2025 (n=24,534)
- Claim: (n=24,534): delegate boilerplate, keep debugging/design.
- Source checked: https://blog.jetbrains.com/research/2025/10/state-of-developer-ecosystem-2025/ and https://devecosystem-2025.jetbrains.com/artificial-intelligence
- Verdict: CONFIRMED
- Detail: Survey is based on responses from 24,534 developers (matches n exactly), 194 countries, fielded April–June 2025. 85% use AI tools regularly; 62% rely on at least one AI coding assistant/agent. Qualitative finding confirmed: developers want to delegate mundane/boilerplate tasks to AI while preferring to stay in control of creative/complex work (debugging, design) — matches the claim's framing.
- Note: solid match, no correction needed.

## 12. Osmani survivorship argument + ~16% "great" gains (SO 2025)
- Claim: Osmani survivorship argument (addyo.substack.com) + ~16% report "great" gains per SO 2025.
- Source checked: https://addyo.substack.com/p/agentic-code-review (survivorship claim) and https://survey.stackoverflow.co/2025/ai (16% figure)
- Verdict: CONFIRMED (both parts, from different posts/pages)
- Detail: The "16% report great gains" figure is confirmed at the primary SO source: "Yes, to a great extent" = 16.3%; "Yes, somewhat" = 35.3%; "Not at all or minimally" = 41.4% (this is the same 41.4% erroneously reattributed in claim #10 above — confirms the conflation theory). The survivorship/selection-bias argument is real but lives in a *different* Osmani post than the one initially checked ("The reality of AI-Assisted software engineering productivity" does NOT contain it) — it's in "Agentic Code Review" (addyo.substack.com/p/agentic-code-review), where Osmani relays GitClear's Bill Harding acknowledging that some of the reported 12% real productivity gain is selection bias because stronger developers are concentrated in the AI-using cohort.
- Note: both numbers check out, but the searcher's single citation (undifferentiated "addyo.substack.com") should be pinned to the specific post (/p/agentic-code-review) — a different, more commonly-cited Osmani post on the same general topic does not contain this argument.

## 13. GitClear 211M lines
- Claim: copy-paste 8.3%→12.3% (2021-24); refactoring 24.1%→9.5%; churn 3.1%→5.7%.
- Source checked: https://www.gitclear.com/ai_assistant_code_quality_2025_research (primary report page)
- Verdict: CORRECTED (minor: date range)
- Detail: All three number pairs confirmed exactly: copy-pasted lines 8.3% (2020) → 12.3% (2024); "moved"/refactored lines 24.1% (2020) → 9.5% (2024), with 2024 the first year copy-paste lines exceeded moved lines; code churn (revised within 2 weeks) 3.1% (2020) → 5.7% (2024). Report covers 211 million changed lines authored January 2020–December 2024.
- Note: the claim's date range "(2021-24)" is off by one year at the start — the actual baseline year for all three metrics is 2020, not 2021. Numbers themselves are exact.
# Batch 3 verification — Searcher D: practices

## 1. Small scopes / decomposition pass rate
- Claim: "Small scopes: decomposition raised pass rate 32.0%→57.5%" citing arxiv 2605.15425
- Source checked: https://arxiv.org/abs/2605.15425
- Verdict: UNSUPPORTED
- Detail: The paper exists — "Runtime-Structured Task Decomposition for Agentic Coding Systems." But its abstract is about **retry-cost reduction**, not pass rate: "up to 51.7% lower retry cost than monolithic systems and 73.2% lower retry cost than static decomposition baselines." No 32.0%/57.5% pass-rate figures appear anywhere in the abstract. The cited number does not match what the source reports.
- Note: real paper, wrong/fabricated metric attached to it.

## 2. Sparse checkpoints vs autonomy/micromanagement (ARC-Bench)
- Claim: "Sparse checkpoints beat autonomy AND micromanagement; +54.7% vs AI Scientist v2 on ARC-Bench" citing arxiv 2605.20025
- Source checked: https://arxiv.org/abs/2605.20025
- Verdict: CONFIRMED
- Detail: Paper is real — "AutoResearchClaw: Self-Reinforcing Autonomous Research with Human-AI Collaboration." Abstract states directly: "On ARC-Bench, a 25-topic experiment-stage benchmark, AutoResearchClaw outperforms AI Scientist v2 by 54.7%." It also states targeted intervention at key points beats both full autonomy and constant micro-management — matches the "sparse checkpoints beat autonomy AND micromanagement" framing (checkpoint-based resumption architecture confirmed), though "sparse checkpoints" isn't the exact phrase used.
- Note: numbers and substance match; terminology paraphrased but faithful.

## 3. Long-horizon reliability decay
- Claim: "Long-horizon reliability 0.90→0.44, up to 19% meltdown; 10 models, 23,392 episodes" citing arxiv 2603.29231
- Source checked: https://arxiv.org/abs/2603.29231
- Verdict: CONFIRMED
- Detail: Paper — "Beyond pass@1: A Reliability Science Framework for Long-Horizon LLM Agents." Abstract directly states: "SE GDS drops from 0.90 to 0.44," "frontier models have the highest meltdown rates (up to 19%)," and "10 models across 23,392 episodes on a 396-task benchmark." All figures match exactly.
- Note: clean match.

## 4. Environment hardening cuts reward-hacking
- Claim: "Environment hardening cut reward-hacking ~88%, 13 models" citing arxiv 2605.02964
- Source checked: https://arxiv.org/abs/2605.02964
- Verdict: CONFIRMED (minor rounding)
- Detail: Paper — "Reward Hacking Benchmark: Measuring Exploits in LLM Agents with Tool Use." States: "Simple environmental hardening reduces exploit rates by 5.7 percentage points (87.7% relative) without degrading task success," across 13 frontier models. 87.7% rounds to "~88%" as claimed.
- Note: precise figure is 87.7%, not 88% — close enough to call confirmed but worth flagging the rounding.

## 5. Property-based tests failure rate
- Claim: "Property-based tests: 18-23% of solutions passing example tests fail property tests" citing FSE 2025, doi 10.1145/3696630.3728702
- Source checked: https://doi.org/10.1145/3696630.3728702 (redirects to dl.acm.org, which returned 403; confirmed via search-indexed excerpt of the paper and researchr.org listing)
- Verdict: CONFIRMED
- Detail: Paper — "From Prompts to Properties: Rethinking LLM Code Generation with Property-Based Testing," FSE Companion '25 (33rd ACM FSE, Trondheim, June 2025) — venue matches. Applied PBT to StarCoder/CodeLlama outputs on MBPP/HumanEval. Reported finding: "A significant portion of generated solutions only partially adhere to correctness properties (30–32%), while 18–23% fail outright." Matches claim.
- Note: dl.acm.org itself was paywalled/403 to direct fetch; number confirmed via indexed excerpt rather than fetching the full text directly — reasonably solid but not a direct read of the PDF body.

## 6. Anthropic multi-agent research system
- Claim: "Anthropic multi-agent: +90.2% on breadth eval at ~15x tokens" citing anthropic.com/engineering/multi-agent-research-system
- Source checked: https://www.anthropic.com/engineering/multi-agent-research-system
- Verdict: CONFIRMED
- Detail: Exact quotes from the page: "a multi-agent system with Claude Opus 4 as the lead agent and Claude Sonnet 4 subagents outperformed single-agent Claude Opus 4 by 90.2% on our internal research eval," and "multi-agent systems use about 15× more tokens than chats."
- Note: both numbers match precisely.

## 7. Adversarial role assignment reduces critic sycophancy
- Claim: "Adversarial role assignment reduces critic sycophancy; ~3 critics, 2-3 cycles optimal" citing emergentmind.com topic page
- Source checked: https://www.emergentmind.com/topics/multi-agent-critique-and-revision-326a2d61-fb41-400d-a710-1cbf54133f20 (aggregator), then traced to underlying arxiv papers: 2507.08350 ("Exploring Design of Multi-Agent LLM Dialogues for Research Ideation") and 2509.20553 ("Perspectra: Choosing Your Experts Enhances Critical Thinking in Multi-Agent Research Ideation")
- Verdict: UNSUPPORTED (as a precise packaged claim, though built from real papers)
- Detail: emergentmind.com is a secondary AI-generated aggregator page, not a primary source. It cites two real underlying papers. But checking those directly: 2507.08350's abstract says enlarging agent cohort/depth/heterogeneity improves diversity and "increasing critic-side diversity...boosts feasibility" — it does NOT state an optimal N≈3 or 2-3 cycles threshold in the abstract; emergentmind appears to have extracted/interpreted a more specific number than the abstract states. 2509.20553 (Perspectra) abstract discusses user-chosen experts and "adversarial discourse" increasing critical thinking, but does not explicitly frame this as reducing "sycophancy" or give a specific critic-count number. Neither paper is fabricated, but the specific packaged numbers ("~3 critics, 2-3 cycles optimal," "reduces critic sycophancy") are emergentmind's synthesis/inference, not a direct quote traceable to either primary abstract.
- Note: real underlying papers exist, but the specific quantified claim as stated does not clearly trace to either primary source's own stated findings — it reads as emergentmind's own gloss. Flag as weak sourcing, not fabrication.
## 8. TDD regressions (naive vs impact-analysis)
- Claim: Naive TDD worsens regressions 6.08%→9.94%; TDD+impact-analysis → 1.82%; citing arxiv 2603.17973
- Source checked: https://arxiv.org/abs/2603.17973 (paper: "TDAD: Test-Driven Agentic Development — Reducing Code Regressions in AI Coding Agents via Graph-Based Impact Analysis")
- Verdict: CONFIRMED
- Detail: Paper exists (submitted to ACM AIWare 2026, Data and Benchmark Track). Abstract states baseline regression rate 6.08%, TDD procedural instructions alone raised it to 9.94% ("worse than no intervention at all"), and TDAD's graph-based impact analysis reduced it to 1.82% (a 70% reduction vs. baseline). All three numbers match exactly.
- Note: none — clean confirmation, cross-checked via WebFetch and independent WebSearch.

## 9. Gherkin specs worse than NL prompts
- Claim: Gherkin specs 6.8% WORSE than NL prompts; citing arxiv 2605.02455, FSE Companion '26
- Source checked: https://arxiv.org/html/2605.02455 (paper: "LLM-Assisted Repository-Level Generation with Structured Spec-Driven Engineering")
- Verdict: CONFIRMED
- Detail: Paper exists, accepted to FSE Companion '26 as claimed. Full text states Gherkin-generated output has "6.8% lower TPR" than natural-language-generated output on average across model combinations (with 0.9% higher stdev). Note: in 14/30 configurations Gherkin actually beat NL by +7.7% average, so the 6.8% figure is an average-case worse-performance finding, not universal.
- Note: direction and magnitude both check out against the primary source's full text (not just the abstract).

## 10. NL→TLA+ semantic correctness
- Claim: NL→TLA+ only 8.6% semantically correct; citing arxiv 2606.05792
- Source checked: https://arxiv.org/abs/2606.05792 (paper: "Can LLMs Write Correct TLA+ Specifications? Evaluating Natural-Language-to-TLA+ Generation")
- Verdict: CONFIRMED
- Detail: Paper exists. Abstract states: "LLMs achieve up to 26.6% syntactic correctness but only 8.6% semantic correctness," evaluating 30 LLMs across 8 families on 205 TLA+ specs. The 8.6% figure matches exactly.
- Note: searcher's own flag to verify was warranted in general (future-dated arxiv IDs deserve scrutiny) but this one holds up.

## 11. ImpossibleBench test-tampering rates + reward-hacking scaling
- Claim: ImpossibleBench: 76% GPT-5 / 46% Opus 4.1 test-tampering; reward-hacking grows ~28pp per 10x code size; citing arxiv 2605.21384 + a lesswrong post
- Source checked: https://arxiv.org/abs/2605.21384, https://arxiv.org/abs/2510.20270, https://www.lesswrong.com/posts/qJYMbrabcQqCZ7iqm/impossiblebench-measuring-reward-hacking-in-llm-coding-1
- Verdict: CORRECTED
- Detail: arxiv 2605.21384 is NOT ImpossibleBench — it's a different paper, "SpecBench: Measuring Reward Hacking in Long-Horizon Coding Agents." SpecBench's abstract does contain the ~28pp-per-10x-code-size scaling claim ("the gap grows by 28 percentage points for every tenfold increase in code size"), so that part traces correctly to 2605.21384, just mislabeled as "ImpossibleBench." The actual ImpossibleBench paper is arxiv 2510.20270 ("ImpossibleBench: Measuring LLMs' Propensity of Exploiting Test Cases," Oct 2025) — and the 76% GPT-5 / 46% Opus 4.1 tampering-rate figures do check out there per WebSearch summaries (GPT-5 76% cheating on impossible-SWEbench one-off variant; Opus 4.1 46% even with an abort option available). The lesswrong post exists and matches (same URL as searched).
- Note: this is a citation-swap, not a fabrication — two real papers' real numbers got merged under one wrong arxiv ID. The 76%/46% numbers should cite 2510.20270; the 28pp/10x number should cite 2605.21384.

## 12. Rules files / AGENTS.md / IHEval / AgentIF bundle
- Claim: LLM-generated rules reduce success 2-3% at +20% cost; human-written +4%; efficiency win ~29% time / ~17% tokens; citing 2602.11988 + 2601.20404; plus IHEval 48% best-case (2502.08745); plus AgentIF (2505.16944)
- Source checked: arxiv.org/abs/2602.11988, arxiv.org/pdf/2602.11988, arxiv.org/abs/2601.20404, arxiv.org/abs/2502.08745, arxiv.org/abs/2505.16944
- Verdict: CORRECTED (partial)
- Detail: All four papers exist and are real. 2602.11988 = "Evaluating AGENTS.md: Are Repository-Level Context Files Helpful for Coding Agents?" — confirmed finding: context files "do not generally improve task success rates, while increasing inference cost by over 20% on average." However, I could NOT find the specific split cited in the claim (LLM-generated files -2-3% success / human-written +4% success) anywhere in the abstract, HTML, or PDF text pulled — the paper's stated finding is a blanket "no improvement + >20% cost," not a signed split between LLM-generated and human-written variants. This part of the claim is UNSUPPORTED as stated (or at least not locatable in the primary source text available). 2601.20404 = "On the Impact of AGENTS.md Files on the Efficiency of AI Coding Agents" — confirmed: reports Δ28.64% lower median runtime and Δ16.58% lower token consumption with AGENTS.md present, closely matching the claimed ~29%/~17% efficiency win. IHEval (2502.08745) confirmed real (NAACL 2025), and the 48% best-case number is real ("the most competitive open-source model only achieves 48% accuracy in resolving [instruction-hierarchy] conflicts"). AgentIF (2505.16944) confirmed real and on-topic (instruction-following benchmark for agentic scenarios), though the claim doesn't attach a specific number to it beyond citing it as supporting context.
- Note: the +20% cost / no-success-improvement finding and the 29%/17% efficiency finding both check out against their respective real papers; the specific "-2-3% LLM-generated / +4% human-written" success-rate split could not be verified in the source text and should be treated as unconfirmed pending a closer read of 2602.11988's full results tables/figures (a small fetcher model summarizing may simply have missed a table — this is a "not found" not a "confirmed absent").

## 13. Claude Code auto mode + agent autonomy stats
- Claim: 93% of Claude Code permission prompts approved; interventions fell 5.4→3.3 while hard-task success doubled; citing anthropic.com/engineering/claude-code-auto-mode and anthropic.com/news/measuring-agent-autonomy
- Source checked: https://www.anthropic.com/engineering/claude-code-auto-mode, https://www.anthropic.com/research/measuring-agent-autonomy
- Verdict: CONFIRMED (with a URL correction)
- Detail: Both numbers check out. "Claude Code users approve 93% of permission prompts" is stated verbatim in the auto-mode engineering post. "From August to December, Claude Code's success rate on internal users' most challenging tasks doubled, at the same time that the average number of human interventions per session decreased from 5.4 to 3.3" is stated verbatim on the agent-autonomy page. The only issue: the second URL is actually anthropic.com/research/measuring-agent-autonomy, not anthropic.com/news/measuring-agent-autonomy as cited — the "/news/" path doesn't appear to be correct.
- Note: content fully confirmed; just fix the URL path from /news/ to /research/.

## 14. Self-preference bias + anecdote sources
- Claim: Self-preference bias measured (arxiv 2410.21819); cross-model review anecdotes (seangoedecke.com, bryanfinster.substack.com); CLAUDE.md violation anecdotes (dev.to post, claude-code issue 19635)
- Source checked: https://arxiv.org/abs/2410.21819, plus WebSearch confirmation of the four anecdote sources
- Verdict: CONFIRMED
- Detail: 2410.21819 is real: "Self-Preference Bias in LLM-as-a-Judge," finds LLM judges assign higher scores to lower-perplexity (more familiar-to-the-model) outputs, with GPT-4 showing notable self-preference bias — a legitimate, on-topic paper for the claim. All four anecdote sources are real, non-fabricated: seangoedecke.com has genuine posts on AI agents/code review; bryanfinster.substack.com has genuine posts on AI-broken code review and cross-model review practices; the dev.to post "I Wrote 200 Lines of Rules for Claude Code. It Ignored Them All." exists and matches the CLAUDE.md-violation framing; GitHub issue anthropics/claude-code#19635 exists and is literally titled "[BUG] Claude Code ignores CLAUDE.md rules repeatedly despite acknowledgment."
- Note: all sources exist and are on-topic; no fabrication found, though these are anecdotal (blog/issue) sources by nature, not held to the same rigor as papers.

## Known-bad numbers check

### "100% claimed vs 57% actual"
- Phrase: "100% claimed vs 57% actual" (AI coding benchmark inflation claim)
- Commonly cited as: no single traceable primary source found; the general narrative in circulation (e.g. Stanford AI Index commentary) is that a widely-cited coding benchmark appeared to go from ~60% to ~100% in a year, while OpenAI's own reporting showed the real raw solve-rate move was 74.9%→80.9% over six months.
- Verdict: DEAD (stays unsupported)
- Detail: WebSearch found no source stating "57%" in this context at all — the real numbers in circulation are 60%/100% (headline/normalized) vs. 74.9%/80.9% (raw, per OpenAI). "57%" does not appear to trace to any primary source found; it looks like a fabricated or garbled figure, possibly a telephone-game distortion of the 74.9%/80.9% range or an unrelated stat.
- Note: confirmed dead — no legitimate source produced.

### "50% error reduction from human-refined specs"
- Phrase: "50% error reduction from human-refined specs" (spec-driven development claim)
- Commonly cited as: circulates in marketing/SEO-style blog content (e.g. blog.exceeds.ai "AI Code Benchmarks: Safe Productivity Thresholds 2026" and similar posts) asserting "up to 50% error reduction" and "50% reduction in debugging/rework time" from spec-driven development.
- Verdict: DEAD (stays unsupported)
- Detail: The only sources surfaced for this figure are non-primary marketing/content-farm style blog posts with no cited study, methodology, or sample — not a peer-reviewed paper or a primary vendor research post. No arxiv paper, controlled study, or credible primary source was found substantiating a specific "50% error reduction" figure tied to human-refined specs.
- Note: confirmed dead as a validly-sourced number — it's circulating as an unsourced marketing talking point, not backed by any paper or study found.
