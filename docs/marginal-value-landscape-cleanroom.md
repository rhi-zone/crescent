# Marginal Value Landscape: Software Built by a Single Developer or Small Org

**Status: Speculative research.** This document is cleanroom analysis derived
from first principles and web search. Estimates are guesstimation with
reasoning, not precision claims. Proxies and assumptions are called out inline.

**Date:** 2026-07-21

**Revision note:** Updated after comparison with an independent parallel
analysis of the same question. Changes: reframed "personal knowledge
management" (originally #9) as the broader "local-first personal data tools"
and moved it to #4; added legal navigation and evidence-based mental health
as new categories; added calibration section and device regression observation.
See "Comparison notes" at the end for what changed and why.

---

## Framework

Two filters applied to every category:

1. **Marginal value** — how much additional value would a new entrant deliver
   over what already exists? Categories with excellent existing solutions score
   low even if total value is enormous. Categories with bad, fragmented,
   nonexistent, or inaccessible solutions score high.

2. **Tractability** — can a single developer or small team realistically build
   and ship something meaningful? Penalizes categories requiring massive
   infrastructure, regulatory compliance, network effects at scale, or data
   moats. Rewards categories where a focused local-first tool or narrow product
   can serve people immediately.

The ranking is **marginal value x tractability**, not total addressable market.

---

## Calibration: what solo developers have actually built

Before ranking, ground tractability claims in evidence of what small teams
have shipped:

- **curl** — Daniel Stenberg, solo maintainer since 1998. 20+ billion device
  installs. Ships in every OS, game console, most major apps.
- **SQLite** — D. Richard Hipp, team of ~3. Most-deployed database in the
  world — every phone, every browser.
- **Obsidian** — 7-person team, zero funding. ~1.5M MAU, ~$25M ARR.
  Local-first note-taking competing with tools from companies 100x the size.
- **Redis** — Salvatore Sanfilippo, solo creator. Became the default caching
  layer for the industry.
- **ripgrep** — Andrew Gallop, solo. 50K+ GitHub stars, powers VS Code search
  across tens of millions of installations.

The pattern: **local-first tools and infrastructure distributed via package
managers or direct download have the shortest path from one person to millions
of users.** No network effects gate entry; quality wins.

Rough tractability spectrum based on this evidence:

1. **Most tractable:** Libraries, CLI tools, developer infrastructure.
   Distribution via package managers. (curl, SQLite, ripgrep.)
2. **Highly tractable:** Local-first desktop/mobile apps for personal use.
   Distribution via direct download, app stores. (Obsidian, YNAB.)
3. **Moderately tractable:** Web apps for specific populations (legal self-help,
   educational content). Distribution via the web.
4. **Less tractable:** Tools requiring local content/knowledge (agriculture,
   informal economy). Require partnerships or deep domain expertise.
5. **Least tractable:** Tools requiring infrastructure (search, translation),
   network effects (communication), or regulatory compliance (healthcare).

---

## The Ranking

### Tier 1: High marginal value, high tractability

#### 1. Offline-capable tools for low-connectivity, non-English-speaking populations

**The gap:** ~5.65B smartphone users worldwide, but smartphone penetration in
Africa is 43%, India 35%. Only 40% of firms in low-income countries have
reliable broadband vs 88% in high-income countries. 75% of the world does not
speak English, yet 49.4% of internet content is in English. 72% of consumers
are more likely to buy products with information in their own language. Only 54%
of adults worldwide have basic digital skills (OECD 2023 estimate).

**Why marginal value is high:** Most software assumes reliable internet, English
literacy, and Western financial/bureaucratic systems. The billions of people
outside that envelope are not well-served by existing tools — not because
software doesn't exist in the abstract, but because it doesn't work for them in
practice. An offline-first, localized tool for a specific workflow (inventory,
accounting, crop planning, health tracking) that works on a $50 Android phone
with intermittent connectivity would serve a population that current solutions
largely fail.

**Why it's tractable:** Local-first architecture is a design choice, not a
resource problem. Localization to a few high-population languages (Hindi,
Swahili, Arabic, Bahasa, Bengali — each serving hundreds of millions) is labor
but not infrastructure. Distribution via sideloading or lightweight APKs avoids
app store gatekeeping. No regulatory moat. No network effect required — the
tool is useful to one person on day one.

**Affected population:** 2-4 billion people, conservatively. The population
with smartphones but without software that works well for their context
(language, connectivity, financial system) is enormous.

**Concrete examples:** Offline bookkeeping for market vendors. Crop calendar /
weather integration for smallholder farmers. Inventory tracking for small shops.
Medication / health record tracking. Local-language document templates for
common bureaucratic tasks.

---

#### 2. Personal/household bookkeeping and micro-business accounting

**The gap:** 90%+ of businesses globally are micro-enterprises (1-9 employees).
In developing countries, most use paper ledgers or basic spreadsheets. In
developed countries, existing solutions (QuickBooks, Xero, FreshBooks) cost
$15-50+/month, assume English, assume reliable internet, and are designed for
businesses with bank integrations and formal tax structures. The vast majority
of the world's economic activity happens in cash-heavy, informal, or
semi-formal contexts these tools don't address.

**Why marginal value is high:** Existing accounting software is either (a) too
expensive, (b) too complex, (c) too English-centric, (d) too
internet-dependent, or (e) designed for formal Western business structures. A
micro-business owner in Lagos, Lima, or Lahore running a shop with cash
transactions has effectively zero good software options. Even in wealthy
countries, personal bookkeeping software is surprisingly bad — Mint shut down,
YNAB went subscription, and most alternatives are either abandonware or
surveillance-funded.

**Why it's tractable:** Accounting is math on structured records. The core
logic is simple. No network effects needed. No regulatory compliance required
for personal/micro-business use (you're not filing taxes for them, you're
helping them track money). Offline-first is natural. A single developer can
build a solid double-entry bookkeeping tool that works on a phone.

**Affected population:** Perhaps 500M-1B micro-business operators globally who
currently track finances on paper or not at all, plus hundreds of millions of
individuals in wealthy countries dissatisfied with personal finance tools.

---

#### 3. Bureaucratic form and paperwork assistance

**The gap:** Americans spend an estimated 11.5 billion hours per year on
federal paperwork alone — roughly 45 hours per adult per year. 81%+ of that is
IRS-related. The OECD average for tax compliance alone is 117 hours/year. This
is just the US/OECD — in countries with less digitized governments, the burden
is often worse, compounded by physical queuing, repeated submissions, and
opaque requirements.

**Why marginal value is high:** Government forms are one of the most universally
hated interactions humans have with bureaucracy, yet the software to help is
either (a) expensive (TurboTax, H&R Block), (b) jurisdiction-specific and
unmaintained, or (c) nonexistent for non-US/non-EU countries. The pain is not
just time — errors on forms cause cascading problems (rejected applications,
delayed benefits, fines). A tool that helps people understand what a form asks,
validates entries before submission, and pre-fills from prior submissions would
save enormous aggregate time and reduce errors.

**Why it's tractable:** Each jurisdiction's forms are public documents. A tool
doesn't need to file anything — just help people fill out forms correctly.
Start with one jurisdiction, one form type. No regulatory barrier to helping
someone fill out a form (you're not providing legal or tax advice, you're
providing a structured editor). PDF parsing and form-filling is well-understood
technically. LLM integration for plain-language explanations of form fields is
now cheap.

**Tractability caveat:** The value scales with jurisdiction coverage, which is a
long tail. But even a single well-served jurisdiction (e.g., a tool that helps
Indian citizens fill out common government forms) serves hundreds of millions.

**Affected population:** Virtually every adult — ~5 billion people interact
with government paperwork. The subset poorly served by current tools is
probably 3-4 billion.

---

#### 4. Local-first personal data tools (beyond notes)

**The gap:** The dominant tools for personal data — finances, health, habits,
tasks — are cloud-locked, require accounts, and monetize through subscriptions
or data harvesting. When Mint (the most popular free personal finance tool in
the US) shut down in March 2025, its successors (YNAB, Copilot) are
cloud-dependent with third-party data integrations that expose personal data.
Health trackers are overwhelmingly surveillance-funded. Task managers are
subscription-locked.

Obsidian proves the local-first model works: 7 people, zero funding, 1.5M MAU,
~$25M ARR — competing against Notion (100M+ accounts, hundreds of employees).
But Obsidian covers notes. The adjacent personal data categories (finance,
health tracking, habit tracking, task management) remain cloud-locked. There is
no Obsidian-equivalent for personal finance — a local-first tool that stores
data on the user's device, syncs optionally, and doesn't require trusting a
third party with financial or health records.

**Why marginal value is high:** The gap is not "no tools exist" but "no tools
respect user sovereignty over personal data in categories beyond notes." This
matters more each year as data breaches increase and subscription fatigue grows.
64% of Americans don't use a password manager; the average person's relationship
with their own personal data is one of passive surrender to whatever cloud
service they signed up for. A local-first personal finance or health tracker
that worked as well as Obsidian works for notes would serve tens to hundreds
of millions with meaningfully better privacy, resilience, and ownership.

**Why it's tractable:** No network effects. No regulatory barriers. A single
developer can build a local-first app with optional sync and ship via direct
download or app stores. The core technical challenge (conflict-free sync without
a central server) has mature solutions (CRDTs, Automerge, Yjs). Data format
that outlives the app (plain files, not a proprietary database) is a design
choice, not a technical barrier.

**Why this is #4, not #1:** The affected population — people who use software
for personal data and actively want local-first ownership — is hundreds of
millions, not billions. The billions of people in categories #1-3 don't have
working software at all; this population has working software but with
sovereignty and privacy problems. Per-person marginal value may be comparable,
but the population difference is roughly 10x.

**Affected population:** Hundreds of millions in wealthy countries dissatisfied
with cloud-locked personal data tools. Potentially larger if combined with
offline-first design for low-connectivity populations (overlap with #1).

---

#### 5. Accessibility tooling and document remediation

**The gap:** 1.3 billion people (16% of world population) experience
significant disability (WHO 2022). 95.9% of the top 1 million websites have
detectable WCAG failures, averaging 56.8 errors per homepage. Only ~3% of the
internet is considered accessible. Screen readers exist (NVDA, VoiceOver,
JAWS) and are mature — NVDA has 97.6% user satisfaction, JAWS 95.6% (WebAIM
Survey #10). The bottleneck has shifted: the assistive technology is good, but
the content it reads is overwhelmingly inaccessible.

**Why marginal value is high:** Two complementary gaps exist. First,
**end-user remediation**: a tool that takes an inaccessible PDF, Word document,
or webpage and produces an accessible version (proper heading structure, alt
text, reading order, form labels) would serve 1.3B people directly. Existing
remediation tools are expensive enterprise products ($thousands/year) or
require manual expertise. Second, **developer-side tooling**: tools that surface
real screen-reader behavior during development — not just "does this element
have an aria-label" but "what does a screen reader user actually experience on
this page." SME accessibility tooling is the fastest-growing segment (19.6%
CAGR) as smaller companies face compliance pressure without enterprise budgets.

**Why it's tractable:** Document structure analysis is well-suited to current
ML/heuristic approaches. PDF accessibility remediation is a bounded technical
problem. A browser extension that improves page accessibility on the fly is
buildable by one developer. Developer tooling can integrate with existing
browser devtools or CI pipelines. No network effects. No regulatory barrier.

**Affected population:** 1.3 billion people with disabilities, plus ~1 billion
aged 60+ with declining vision/hearing/motor control. Developer-side tooling
has leverage: one developer using better tooling produces software used by
thousands.

---

### Tier 2: High marginal value, moderate tractability

#### 6. Caregiver coordination and household logistics

**The gap:** Women globally spend ~134 minutes/day on unpaid caregiving (vs 76
for men). Household logistics — scheduling, meal planning, medication tracking,
school coordination, eldercare management — consume enormous time and are
mostly managed in people's heads, on paper, or via fragmented apps (one for
groceries, one for calendar, one for medications, none of which talk to each
other).

**Why marginal value is high:** Calendar apps exist but don't model household
complexity (recurring but irregular tasks, delegation, dependencies between
household members, context about preferences and constraints). No good
integrated tool exists for "running a household" as a first-class domain.
Existing apps treat each sub-problem in isolation.

**Why it's tractable:** No infrastructure requirements. Local-first is natural.
No regulatory barriers. The challenge is design — modeling the right
abstractions for household logistics is hard, and the design space is littered
with failed attempts that were either too simple (just a shared list) or too
complex (project management software for families).

**Tractability caveat:** Shared household tools have mild network effects
(value increases when family members also use it), but the tool is useful to a
single person managing a household alone.

**Affected population:** ~2 billion adults who manage households, weighted
toward women. The primary caregiving population (those managing care for
children, elderly, or disabled family members) is perhaps 1-1.5 billion.

---

#### 7. Legal navigation for self-represented litigants

**The gap:** 55% of US court cases now have at least one self-represented
party — up from 4% in the 1990s. Pro se litigants are 6.5x more likely to
lose: only 3% of pro se plaintiffs get favorable judgments vs 40% for
represented defendants. 92% of low-income Americans cannot get legal help.
~$5B in legal tech investment in 2024 went overwhelmingly to Big Law and
corporate tools.

**Why marginal value is high:** Existing tools (LegalZoom, Rocket Lawyer)
prepare documents but don't help people understand or navigate proceedings.
The courtroom-facing side — helping a tenant understand an eviction process,
a parent navigate a custody filing, a debtor respond to a collection suit — is
nearly empty. The difference between understanding the process and not
understanding it is often the difference between winning and losing a case
that determines housing, custody, or financial survival.

**Why it's tractable:** Court procedures are public record. Forms, deadlines,
and filing requirements are published. The gap is not access to information but
translation into plain language, sequenced into a workflow someone without
legal training can follow. A single developer could build jurisdiction-specific
procedural guides for high-volume case types (housing, family, small claims,
debt collection) and ship as a web app.

**Tractability caveat:** Jurisdiction fragmentation — procedures vary by state,
county, and court. Building for one jurisdiction is tractable; all of them is a
content scaling problem. Liability concerns (must be clear the tool provides
information, not legal advice). LLM-generated legal guidance risks confident
wrong answers in a high-stakes domain.

**Affected population:** Millions of people navigate court proceedings alone
each year in the US alone. Similar patterns exist worldwide. US-specific data
is the most readily available; the global population of people navigating legal
systems without representation is likely tens of millions.

---

#### 8. Local-first document and data tools (spreadsheet/database hybrid)

**The gap:** Spreadsheets are the most widely used "programming" tool in the
world. Google Sheets requires internet. Excel requires a license. LibreOffice
Calc is capable but heavy. None of them handle structured data well — people
use spreadsheets as databases because actual databases are inaccessible to
non-programmers. Airtable and Notion exist but are cloud-dependent, expensive
at scale, and English-centric.

**Why marginal value is high:** The gap between "spreadsheet" and "database"
is where enormous amounts of real-world data management happens — inventory
lists, student records, project tracking, contact management, event planning.
People force these into spreadsheets because the alternative is enterprise
software they can't afford or understand. A local-first structured-data tool
with spreadsheet-like UX and database-like capabilities (types, relations,
views, queries) would serve a huge population.

**Why it's tractable:** SQLite exists. The core engine is solved. The challenge
is UX — making structured data manipulation accessible to non-programmers. No
cloud infrastructure needed. No network effects for individual use. One
developer can build a usable tool.

**Affected population:** Hundreds of millions of knowledge workers, students,
small business operators, and community organizers who currently wrangle data
in spreadsheets. Billions if you include the population that currently uses
paper because spreadsheets are inaccessible.

---

#### 9. Developer tooling: documentation and codebase understanding

**The gap:** Stack Overflow 2025 survey: top developer frustration is AI
answers that are "almost right but not quite" (66%); trust in AI answers
dropped to 29%. Tool sprawl remains persistent — average company runs 101+
apps. Integration between tools (36% of IT teams cite this as top frustration)
and siloed information (32%) are major pain points. JetBrains surveys (65K+
respondents) identify persistent frustrations with technical debt management
and fragmented build systems.

**Why marginal value is high:** Despite the abundance of developer tools, the
specific gap of "understanding an unfamiliar codebase" remains poorly served.
Existing tools are either too shallow (grep, ctags) or too opinionated
(AI assistants that hallucinate). A tool that builds and navigates a
structural map of a codebase — call graphs, data flow, module boundaries,
dependency relationships — without requiring cloud upload or AI inference would
be high value. Documentation generation that's actually useful (not just
auto-generated API docs) is also notably absent.

**Why it's tractable:** Static analysis is well-understood. Language-specific
parsers exist (tree-sitter). The core technical problem — parse code, build
graphs, render navigable views — is squarely in single-developer territory.
No infrastructure needed. Developers are willing to install CLI tools. The
category has the strongest track record of solo-developer success (curl,
SQLite, Redis, ripgrep).

**Tractability caveat:** Multi-language support is a long tail. Starting with
one or two popular languages and doing them well is realistic.

**Affected population:** ~30 million professional developers, plus a larger
population of students and hobbyist programmers. The developer population is
small relative to global population but has outsized economic impact and
willingness to pay.

---

#### 10. Evidence-based mental health self-help tools

**The gap:** Over 90% of mental health apps on the market have no clinical
evidence. The dominant consumer apps (Calm, Headspace) are content libraries
(meditation recordings), not therapy — and both are declining in revenue.
Evidence-based tools exist (Woebot: FDA Breakthrough Device Designation, 14
RCTs; Wysa: 2024 RCT showing meaningful depression reduction) but have limited
reach. A 2025 Lancet Digital Health meta-analysis (92 RCTs, 16,728
participants) confirmed that standalone apps can produce moderate clinical
improvement. Meanwhile, 91% of people with depression worldwide lack adequate
treatment.

**Why marginal value is high:** The gap between "software-delivered therapy has
clinical evidence" and "the people who need it can access it" is vast. CBT-
based interventions have well-documented protocols implementable in software.
The problem is reaching people, not inventing the intervention.

**Why it's moderately tractable:** A small team can build an app delivering
structured CBT exercises, mood tracking, and psychoeducation. No network
effects for individual use.

**Tractability caveats:** Clinical validation takes time and expertise — even
with evidence-based interventions, demonstrating that a specific implementation
works requires study. Subscription fatigue is real in this category. Liability
concerns if users are in crisis. The hardest-to-reach populations (low-income,
non-English-speaking) are also the most difficult to serve via an app. The gap
is more distribution and trust than technology.

**Affected population:** High per-person for those who engage. The binding
constraint is engagement and retention, not availability.

---

### Tier 3: Moderate marginal value, high tractability

#### 11. File format conversion and document processing

**The gap:** PDF manipulation, format conversion (docx to pdf, image to text,
video format conversion), and batch document processing are tasks that
virtually every computer user encounters. Existing solutions are either (a)
online services that upload your files to unknown servers, (b) expensive
desktop software, or (c) command-line tools (ffmpeg, ImageMagick, pandoc) that
require technical knowledge.

**Why marginal value is moderate:** Good tools exist (pandoc, ffmpeg,
LibreOffice) but they're inaccessible to non-technical users. The marginal
value is in the UX layer — wrapping existing capabilities in interfaces that
non-programmers can use, running locally (no file upload), and handling the
common cases well. Gartner estimates poor data quality — including conversion
failures — costs organizations $12.9M/year on average.

**Why it's tractable:** The underlying libraries exist. The work is UI/UX, not
algorithms. A desktop app or local web app wrapping pandoc/ffmpeg/etc. with a
drag-and-drop interface is very buildable.

**Affected population:** Billions of computer users, but existing solutions do
serve most of them (just with friction). The population truly blocked (not just
annoyed) is smaller — perhaps hundreds of millions who can't use command-line
tools and won't upload sensitive documents to web services.

---

### Tier 4: Categories with deceptively low marginal value or low tractability

These are categories where the total value is enormous but a new entrant from a
single developer would struggle to add meaningful marginal value.

#### Communication tools (messaging, email, video)

Total value is astronomical, but existing solutions (WhatsApp, Signal, Zoom,
email) are good-to-excellent and have overwhelming network effects. A better
tool that nobody uses has zero value. **Low marginal value, low tractability.**

#### Healthcare software

Enormous total value, but HIPAA/GDPR compliance, liability concerns, and
integration with existing medical systems make this largely intractable for a
solo developer. The exception is personal health tracking (fitness, medication
reminders), which is well-served by existing apps. **High total value, low
tractability.**

#### Education platforms (LMS, courseware)

Crowded market (Khan Academy, Coursera, Duolingo, countless others). Network
effects matter (students go where courses are). Content creation is the
bottleneck, not software. The gap for offline-first individual learning tools
is real (2.6 billion people lack reliable internet, 272 million children out of
school) but the distribution and localization challenges are severe — how does
a learner without internet access discover and download the tool?
**Moderate marginal value, low-moderate tractability.**

#### Social media and content platforms

Pure network effects. A better platform with no users is worthless. **Zero
marginal value without scale, near-zero tractability.**

#### Search and information retrieval

Web search requires a crawl index costing millions to build and maintain.
Local/specialized search (your own files, a specific corpus) is tractable, but
competing with Google on web search is not. **High total value, very low
tractability.**

---

## Cross-cutting observations

### The non-English, non-urban multiplier

The single biggest predictor of whether a software category has high marginal
value is whether it serves populations outside the English-speaking,
reliably-connected, formally-banked demographic. 75% of the world does not
speak English. 60% of the world lives in Asia. Africa's population is 1.4
billion and growing rapidly with increasing smartphone adoption (43%
penetration and rising). Hindi is under 0.1% of web content despite India
having 1.03 billion internet users. Almost every category above gains its
highest marginal value from serving these populations.

This is not "localization" in the sense of translating a Western app. It's
building for fundamentally different contexts: cash-based economies, irregular
connectivity, different bureaucratic systems, different household structures,
different agricultural cycles.

### The offline-first multiplier

Reliable broadband is available to 88% of firms in high-income countries but
only 40% in low-income countries. Mobile data is expensive relative to income
in most of the developing world — Sub-Saharan Africa averages ~5.8% of monthly
income for 1 GB (3x the UN affordability target of 2%). Mobile data cost ranges
from $0.27/GB in India to $43.75/GB in Zimbabwe. Any tool that requires
constant connectivity excludes billions of potential users. Offline-first is
not a feature — it's an accessibility requirement for the majority of the
world's population.

### The 2026 device regression

Entry-level phones are getting worse, not better. A 2026 RAM shortage pushed
DRAM prices up 50% and NAND prices up 90%. Memory now accounts for 43% of the
bill of materials on entry-level devices. Software targeting the global
majority needs to be getting lighter, not heavier. This is a tailwind for
minimal, local-first tools and a headwind for anything that assumes growing
device capabilities.

### The "just good enough" trap

Many categories appear well-served because solutions exist that work for the
vocal, English-speaking, technically-literate minority that dominates online
discourse. This creates a distorted picture: software satisfaction surveys
overwhelmingly sample people who already have software that mostly works for
them. The 3-4 billion people whose needs are unmet don't show up in NPS
surveys or Product Hunt discussions.

### The complexity tax

Software complexity costs the US economy an estimated ~$1 trillion/year and
drains ~7% of annual revenue at the average company (Freshworks). 60% of
employees experience frustration with new software (Gartner). UK firms regret
~20% of software purchases; companies use only 49% of provisioned licenses.
There is a structural opportunity in building tools that do less, but do it
well — tools that a non-technical person can use without training, that don't
require an IT department to deploy, that don't demand integration with 15 other
systems.

---

## Summary ranking

| Rank | Category | Marginal value | Tractability | Key population |
|------|----------|---------------|-------------|----------------|
| 1 | Offline-capable tools for low-connectivity, non-English populations | Very high | High | 2-4B |
| 2 | Micro-business / personal bookkeeping | Very high | High | 500M-1B |
| 3 | Bureaucratic form / paperwork assistance | High | High | 3-4B |
| 4 | Local-first personal data tools (beyond notes) | High | High | 100M-500M |
| 5 | Accessibility tooling and document remediation | High | High | 1.3B+ |
| 6 | Caregiver coordination / household logistics | High | Moderate | 1-2B |
| 7 | Legal navigation (self-represented litigants) | High | Moderate | 10M+ |
| 8 | Local-first document / data tools | High | Moderate | 500M+ |
| 9 | Developer tooling: codebase understanding | Moderate-high | High | 30M+ |
| 10 | Evidence-based mental health self-help | High (per-person) | Moderate | varies |
| 11 | File format conversion (local, accessible UX) | Moderate | Very high | 500M+ |

Population estimates are rough order-of-magnitude. "Affected population" means
people currently underserved by existing solutions, not total potential users.

---

## Comparison notes

This document was revised after reading a parallel analysis
(`marginal-value-landscape.md`) that reached different conclusions from
non-cleanroom research. Key points of divergence and resolution:

**Where the parallel analysis was more right:**

- **Category framing of personal data tools.** The parallel analysis framed
  this as "local-first personal data management" covering finance, health,
  habits, and tasks — not just notes. This document originally narrowed it to
  "personal knowledge management and note-taking" and dismissed it as crowded
  (Obsidian, Logseq, Notion). The narrowing was wrong. Notes *are* well-served;
  local-first tools for personal finance, health, and task data are not. Updated.

- **Calibration evidence.** The parallel analysis opened with concrete examples
  of solo-developer successes (curl, SQLite, Obsidian, Redis, ripgrep) with
  real numbers. This grounds tractability in evidence rather than assertion.
  Added.

- **Legal navigation.** This document originally omitted self-represented
  litigants entirely. The data (55% of US cases, 6.5x worse outcomes, 92% of
  low-income Americans unable to get legal help) identifies a real, large,
  poorly-served population. Added.

- **Mental health tools.** Originally omitted. The Lancet meta-analysis (92
  RCTs) and the 91% treatment gap are strong evidence of marginal value. Added
  with tractability caveats.

- **Device regression.** The 2026 RAM/NAND price increases making cheap phones
  worse is a material fact that strengthens the case for lightweight tools.
  Added to cross-cutting observations.

**Where this document was more right:**

- **Weight given to non-English, low-connectivity populations.** The parallel
  analysis puts offline/low-connectivity tools in Tier 3 (low tractability),
  prioritizing wealthy-world privacy concerns at #1. For a question about the
  *global* population, the 2-4 billion people without working software rank
  above the hundreds of millions who have working software but want it
  local-first. This document's weighting is maintained.

- **Bureaucratic form assistance.** The parallel analysis ranked government
  service navigation #11 (Tier 3, low tractability), arguing the bottleneck is
  institutional adoption. This document distinguishes form-filling assistance
  (tractable — the tool helps people fill out public forms correctly) from
  government system integration (intractable). The distinction matters: you
  don't need government APIs to help someone fill out a form. Ranking maintained
  at #3.

- **Caregiver coordination.** The parallel analysis omitted this entirely.
  134 min/day unpaid caregiving for women globally, 1-2B affected, is a
  significant underserved population. Maintained.

- **Broader accessibility framing.** The parallel analysis focused on developer
  tooling (helping developers build accessible software). This document also
  covers end-user document remediation (making existing inaccessible content
  usable), which has higher direct marginal value because it doesn't require
  changing developer behavior. Both angles now included.

**On the PKM ranking specifically (#1 in theirs vs #4 here):**

The parallel analysis's #1 ranking reflects a valid insight about the category
being broader than notes. But its population estimate ("hundreds of millions")
is 10x smaller than the populations in #1-3 here. For a question about marginal
value across the global population, the billions of people without working
software at all have higher marginal utility than the hundreds of millions who
have working software but want better sovereignty. #4 is the honest position:
it's a real, high-value gap, not a crowded space — but it's not the largest gap.

---

## Data sources and caveats

Population and connectivity data: DemandSage, SQMagazine, ElectroIQ, OECD,
Gitnux, WorldMetrics, WEF, DataReportal Digital 2026, GSMA Mobile Economy
Africa 2026. Time-use data: OECD Time Use Database, BLS American Time Use
Survey 2024, American Action Forum. Software satisfaction: Gartner, Freshworks,
SpeakWise, IT Pro. Agriculture and small business: ScienceDirect, CFIB, US
Chamber of Commerce, MDPI. Open source: Harvard/Linux Foundation estimates,
DevX. Accessibility: WHO 2022, WebAIM, BeAccessible. Developer surveys: Stack
Overflow 2025, JetBrains Developer Survey. Legal: NCSC Access to Justice 2025.
Mental health: Lancet Digital Health 2025.

**Key caveats:**
- English internet content share (49.4%) from W3Techs-adjacent sources; exact
  methodology varies.
- "Affected population" estimates are proxies derived from connectivity,
  language, and device statistics — not direct measurements of software need.
- Time-use data is predominantly from OECD countries; developing-world time
  allocation may differ substantially.
- Software satisfaction data is inherently biased toward populations that
  already use software.
- Legal data is predominantly US-sourced. The global self-representation
  population is likely much larger but less well-measured.
- All population projections are 2025-2026 estimates.
