# Value landscape for small-team software (speculative)

> **Status: speculative research.** Landscape evaluation grounded in publicly
> available data, not settled analysis. Estimates are guesstimation with
> reasoning, not precision. Nothing here is committed-to direction.
>
> **Provenance:** Synthesized from two independent marginal-value x tractability
> analyses that cross-referenced each other, plus the total-value landscape that
> seeded them. One analysis was derived from the total-value doc; the other was
> a cleanroom derivation from first principles and web search. Where they
> disagreed, each revised itself after comparison. This document records where
> the revised versions agree (treated as settled), where they still disagree
> (marked as open questions), and preserves the strongest evidence from each.
>
> **Replaces:** `global-software-value-landscape.md`,
> `marginal-value-landscape.md`, `marginal-value-landscape-cleanroom.md`.

## Framework

Two filters applied to every category:

1. **Marginal value** -- how much additional value would a new entrant deliver
   over what already exists? Categories with excellent existing solutions score
   low even if total value is enormous. Categories with bad, fragmented,
   nonexistent, or inaccessible solutions score high.

2. **Tractability** -- can a single developer or small team realistically build
   and ship something meaningful? Penalizes categories requiring massive
   infrastructure, regulatory compliance, network effects at scale, or data
   moats. Rewards categories where a focused local-first tool can serve people
   immediately.

The ranking is marginal value x tractability, not total addressable market.
This inverts the total-value ranking: search and communication -- the highest
total-value categories -- rank near the bottom here because current solutions
are good and competing requires scale a solo developer doesn't have.

## Calibration: what solo developers have actually built

Before ranking categories, ground tractability claims in evidence:

- **curl** -- Daniel Stenberg, solo maintainer since 1998. 20+ billion device
  installs. Ships in every OS, game console, most major apps.
- **SQLite** -- D. Richard Hipp, team of ~3. Most-deployed database in the
  world -- every phone, every browser.
- **Obsidian** -- 7-person team, zero funding. ~1.5M MAU, ~$25M ARR.
  Local-first note-taking competing with tools from companies 100x the size.
- **Redis** -- Salvatore Sanfilippo, solo creator. Became the default caching
  layer for the industry.
- **ripgrep** -- Andrew Gallop, solo. 50K+ GitHub stars, powers VS Code search
  across tens of millions of installations.
- **Nomad List** -- Pieter Levels, solo. $5.3M revenue in 2024.
- **Base44** -- Maor Shlomo, solo. 250K users, acquired for $80M in 2025.

The pattern: **local-first tools and infrastructure distributed via package
managers or direct download have the shortest path from one person to millions
of users.** No network effects gate entry; quality wins.

## Baseline numbers (2026)

- World population: ~8.2B. Internet users: 6.1B. Smartphone users: 5.8B.
- Feature phone users: ~2.1B (declining).
- Entry-level smartphone: 4 GB RAM, 64-128 GB storage, Android Go.
- Sub-Saharan Africa: ~1B people (63%) not using mobile internet despite
  coverage -- the barrier is cost, not infrastructure.
- Mobile data cost: global average $2.59/GB. India $0.27/GB. Zimbabwe
  $43.75/GB. Sub-Saharan Africa averages ~5.8% of monthly income for 1 GB
  (3x the UN affordability target of 2%).
- English is 49.3% of web content despite 19% of speakers. Hindi is under
  0.1% of web content despite India having 1.03B internet users.
- Mobile money: 2.1B registered accounts, 514M MAU, $1.7T in annual
  transactions. Runs on USSD -- no smartphone or data plan needed.
- 90%+ of businesses globally are micro-enterprises (1-9 employees). IFC
  estimates a $5.7T MSME financing gap in emerging markets.
- 55% of US court cases now have at least one self-represented party (up from
  4% in the 1990s). 92% of low-income Americans cannot get legal help.
- Mint shut down March 2025, leaving local-first personal finance essentially
  unserved.
- Women globally spend ~134 min/day on unpaid caregiving (vs 76 for men).
- 95.9% of the top 1M websites have detectable WCAG failures, averaging 56.8
  errors per homepage. Only ~3% of the internet is considered accessible.
- 2026 RAM shortage pushed DRAM prices up 50% and NAND prices up 90%. Memory
  now accounts for 43% of the bill of materials on entry-level devices.

Sources: DataReportal Digital 2026, GSMA Mobile Economy Africa 2026, W3Techs
2025, Mappr Data Pricing 2026, GSMA Mobile Money Market Guide 2024, NCSC
Access to Justice 2025, 9to5Google RAM Shortage 2026, BankMyCell 2026,
WHO 2022, WebAIM Million 2025, IFC MSME Finance Gap, OECD Time Use Database,
Stack Overflow 2025, JetBrains Developer Survey, Lancet Digital Health 2025.

---

## Tier 1: Highest marginal value x tractability

Categories where (a) current solutions are poor, fragmented, or absent,
(b) a meaningful improvement is buildable by one person or a small team, and
(c) the affected population is large.

### 1. Personal finance and micro-business bookkeeping

Both analyses rank this in the top 2. No disagreement.

**The gap:** Mint shut down March 2025. Its successors (YNAB, Copilot) are
cloud-dependent with third-party data integrations (Plaid) that expose personal
data. There is no Obsidian-equivalent for personal finance: a local-first tool
that stores data on the user's device, syncs optionally, and doesn't require
trusting a third party with financial records.

The gap is sharper internationally. 90%+ of businesses globally are
micro-enterprises. In developing countries, most use paper ledgers or basic
spreadsheets. Existing solutions (QuickBooks, Xero, FreshBooks) cost
$15-50+/month, assume English, assume reliable internet, and are designed for
businesses with bank integrations and formal tax structures. A micro-business
owner in Lagos, Lima, or Lahore running a shop with cash transactions has
effectively zero good software options.

**Tractability:** Accounting is math on structured records. No network effects.
No regulatory compliance for personal/micro-business use. Offline-first is
natural. A single developer can build a solid double-entry bookkeeping tool
that works on a phone.

**What a new entrant would need to get right:** Data format that outlives the
app (plain files, not a proprietary database). Works offline by default.
Handles cash-based workflows, not just bank-synced ones. Runs on low-end
devices. Doesn't assume English or Western financial structures.

**Affected population:** 500M-1B micro-business operators globally who
currently track finances on paper or not at all, plus hundreds of millions
in wealthy countries dissatisfied with personal finance tools.

### 2. Bureaucratic form and paperwork assistance

Both analyses rank this #3. No disagreement on position or reasoning.

**The gap:** Americans spend an estimated 11.5 billion hours/year on federal
paperwork alone -- roughly 45 hours per adult per year. 81%+ is IRS-related.
OECD average for tax compliance: 117 hours/year. In countries with less
digitized governments, the burden is often worse, compounded by physical
queuing, repeated submissions, and opaque requirements.

Government forms are universally hated yet the software to help is either
expensive (TurboTax, H&R Block), jurisdiction-specific and unmaintained, or
nonexistent for non-US/non-EU countries. Errors on forms cause cascading
problems (rejected applications, delayed benefits, fines).

**Tractability:** Each jurisdiction's forms are public documents. A tool
doesn't need to file anything -- just help people fill out forms correctly.
Start with one jurisdiction, one form type. No regulatory barrier to providing
a structured editor. PDF parsing and form-filling is well-understood. LLM
integration for plain-language explanations is now cheap.

**Tractability caveat:** Value scales with jurisdiction coverage, which is a
long tail. But even a single well-served jurisdiction (e.g., Indian government
forms) serves hundreds of millions.

**Affected population:** ~5 billion people interact with government paperwork.
The subset poorly served by current tools is probably 3-4 billion.

### 3. Accessibility tooling and document remediation

Both analyses rank this in positions 4-5. No disagreement.

**The gap:** Screen readers are mature and high-satisfaction (NVDA 97.6%, JAWS
95.6%). The bottleneck has shifted: 95.9% of the top 1M websites have
detectable WCAG failures, averaging 56.8 errors per homepage. Only ~3% of the
internet is considered accessible.

Two complementary gaps. First, **end-user document remediation**: a tool that
takes an inaccessible PDF, Word document, or webpage and produces an accessible
version (heading structure, alt text, reading order, form labels). Existing
remediation tools are expensive enterprise products. Second, **developer-side
tooling**: tools that surface real screen-reader behavior during development,
not just ARIA-label auditing. SME accessibility tooling is the fastest-growing
segment (19.6% CAGR) as smaller companies face compliance pressure without
enterprise budgets.

**Tractability:** Document structure analysis is well-suited to current
ML/heuristic approaches. PDF remediation is a bounded technical problem. A
browser extension that improves page accessibility on the fly is buildable by
one developer. No network effects, no regulatory barrier.

**Tractability limits:** Screen reader behavior is platform-specific and
under-documented. Multi-language support for document remediation adds
complexity.

**Affected population:** 1.3B people with disabilities, plus ~1B aged 60+
with declining vision/hearing/motor control. Developer-side tooling has
leverage: one developer using better tooling produces software used by
thousands.

### 4. Developer tools and infrastructure libraries

Both analyses include developer tools in Tier 1-2 but scope them differently.
The derived version is broad ("developer tools / infra libraries," #5); the
cleanroom is narrower ("documentation and codebase understanding," #9). Both
agree on high tractability.

**The gap:** The category is perpetually high-marginal-value because the field
continuously creates new pain points. JetBrains surveys (65K+ respondents)
identify persistent frustrations: technical debt management, slow/fragmented
build systems, poor cross-language interop. AI coding tools are creating new
categories of pain around trust and correctness (Stack Overflow 2025: trust in
AI answers dropped to 29%). 44% of profitable SaaS products are now run by a
single founder -- doubled since 2018 -- meaning more solo developers need
better tooling.

**Tractability:** No category has a stronger track record of solo-developer
success. Tools run locally, quality is legible, distribution through package
managers and GitHub is free and global. No network effects, no regulatory
barriers, no data moats.

**Marginal value:** Moderate-to-high. The per-person value is moderate
(developer productivity), but the affected population (~30M developers plus
transitive users) is large, and the space continuously generates new gaps. The
marginal value of any individual tool depends on finding a genuine pain point;
the category always has room for well-built entries.

### 5. Data format conversion and interoperability

Both analyses include this with similar assessment. No disagreement.

**The gap:** The backbone tools (FFmpeg, Pandoc, ImageMagick) are powerful and
miserable to use. Consumer-facing converters (CloudConvert, Zamzar) are
cloud-dependent, rate-limited, upload files to third-party servers. Gartner
estimates poor data quality costs organizations $12.9M/year on average.

Everyone encounters this: convert DOCX to PDF, resize images, extract audio
from video, merge PDFs. The gap is a local-first, privacy-respecting tool that
handles common conversions well with a discoverable interface.

**Tractability:** The hard conversion logic already exists in open-source
libraries. The value is the integration layer: routing, edge cases, usable
interface. No network effects. Nothing to host.

**Marginal value:** Moderate. Good tools exist -- the gap is in the UX layer,
not the capability layer. High frequency, small per-instance value.

---

## Tier 2: High marginal value, moderate tractability

Categories where the gap is large and the population significant, but building
and shipping faces real (not insurmountable) obstacles.

### 6. Offline-first educational tools for individual learners

Both analyses include education with similar caveats. The cleanroom places the
offline education gap under its #1 meta-category; the derived version ranks it
#7 in Tier 2.

**The gap:** 2.6 billion people lack reliable internet. Existing offline
educational tools (Kolibri, Learning Passport) are institution-deployed --
they require schools or NGOs to set up. There is almost nothing for a single
learner on their own device. 272 million children are out of school. 2.9
billion adults lack basic digital skills.

**Tractability:** Content licensing is often open (CC-BY). PWAs are viable on
Android Go. A small team could build a PWA that caches a focused curriculum
for offline use.

**Tractability limits:** Content localization is labor-intensive (7,000
languages; machine translation introduces errors unacceptable in educational
content). Target users may have low digital literacy. Distribution without
institutional partners is harder -- how does a learner without internet
discover and download the tool?

**Affected population:** Billions could benefit, but a single developer's
impact is likely regional (one language group, one curriculum area).

### 7. Caregiver coordination and household logistics

Both analyses include this with similar reasoning. The cleanroom ranks it #6;
the derived version #8.

**The gap:** Women globally spend ~134 min/day on unpaid caregiving (vs 76 for
men). Household logistics -- scheduling, meal planning, medication tracking,
school coordination, eldercare -- consume enormous time and are managed in
people's heads, on paper, or via fragmented apps that don't talk to each other.

Calendar apps exist but don't model household complexity: recurring but
irregular tasks, delegation, dependencies between household members, context
about preferences and constraints. No integrated tool exists for "running a
household" as a first-class domain.

**Tractability:** No infrastructure requirements. Local-first is natural. No
regulatory barriers. The challenge is design -- modeling the right abstractions
is hard, and the design space is littered with failed attempts (too simple or
too complex).

**Tractability limit:** Mild network effects (value increases with family
members), though useful for a single person. The design problem has defeated
many attempts.

**Affected population:** ~2B adults who manage households, weighted toward
women.

### 8. Local-first structured data tools (spreadsheet-database hybrid)

Both analyses include this. No disagreement on reasoning.

**The gap:** Spreadsheets are the most widely used "programming" tool in the
world. Google Sheets requires internet. Excel requires a license. LibreOffice
Calc is capable but heavy. None handle structured data well -- people use
spreadsheets as databases because actual databases are inaccessible to
non-programmers. Airtable and Notion are cloud-dependent, expensive at scale,
and English-centric.

**Tractability:** SQLite exists. The core engine is solved. The challenge is
UX -- making structured data manipulation accessible to non-programmers. No
cloud infrastructure needed. No network effects for individual use.

**Affected population:** Hundreds of millions of knowledge workers, students,
small business operators. Billions if including those who use paper because
spreadsheets are inaccessible.

### 9. Privacy and security integration for non-technical users

Present in the derived analysis (#10) but not as a standalone category in the
cleanroom.

**The gap:** Individual privacy tools are good (Signal, Bitwarden, Proton).
The gap is the integration layer. A non-technical person who wants reasonable
privacy needs 4-5 separate tools with no unified onboarding, no guidance on
priorities, no way to verify setup. 64% of Americans don't use a password
manager. Privacy controls are buried in multiple layers with inconsistent
terminology.

**Tractability:** A tool that assesses privacy posture, recommends actions in
priority order, walks through setup, and verifies the result. Content, UX,
and integration problem, not infrastructure.

**Tractability limits:** Getting it wrong is actively harmful (false sense of
security). Threat models vary enormously. Platform fragmentation multiplies
surface area.

### 10. Evidence-based mental health self-help tools

Both analyses include this after cross-comparison with similar assessment.

**The gap:** Over 90% of mental health apps have no clinical evidence. The
dominant consumer apps (Calm, Headspace) are content libraries, not therapy --
and both are declining. Evidence-based tools (Woebot: FDA Breakthrough Device
Designation, 14 RCTs; Wysa: 2024 RCT) have limited reach. A 2025 Lancet
Digital Health meta-analysis (92 RCTs, 16,728 participants) confirmed
standalone apps can produce moderate clinical improvement. 91% of people with
depression worldwide lack adequate treatment.

**Tractability:** CBT-based interventions have well-documented protocols. A
small team can build structured CBT exercises, mood tracking, psychoeducation.

**Tractability limits:** Clinical validation takes time. Subscription fatigue
is real. Liability concerns if users are in crisis. The gap is more
distribution and trust than technology.

**Marginal value:** High per-person for those who engage. The binding
constraint is engagement and retention, not availability.

### 11. Personal knowledge management and note-taking

**The gap is narrower here than in categories above.** Obsidian (~1.5M MAU,
$25M ARR), Logseq, Notion (100M+ accounts), Apple Notes, Google Keep, Bear,
Joplin -- the category is crowded for English-speaking, technically-inclined
users.

The remaining gaps: non-English speakers are underserved, most tools assume
technical literacy, and true local-first data ownership (not just local storage
with cloud sync required for key features) is still rare outside Obsidian.

**Tractability:** Text files, search, and linking are solved problems. Very
tractable. The challenge is taste and restraint -- doing less, better, for a
specific underserved population rather than competing head-on with Obsidian.

**Note on framing:** The cleanroom analysis expanded this into "local-first
personal data tools (beyond notes)" covering finance, health, habits, and
tasks. The finance component is captured in #1. The broader framing -- that
the local-first model Obsidian proved for notes has not been replicated for
other personal data categories -- is a valid observation, but those categories
are better evaluated individually than bundled.

---

## Tier 3: High marginal value, low tractability for a solo developer

Large gaps, large populations, but the barriers make these poor fits for a
single developer or small team.

### Legal navigation for self-represented litigants

**The gap:** 55% of US court cases now have at least one self-represented
party -- up from 4% in the 1990s. Pro se litigants are 6.5x more likely to
lose: only 3% of pro se plaintiffs get favorable judgments vs. 40% for
represented defendants. 92% of low-income Americans cannot get legal help.

Existing tools (LegalZoom, Rocket Lawyer) prepare documents but don't help
people understand or navigate proceedings. ~$5B in legal tech investment in
2024 went overwhelmingly to Big Law and corporate tools. The courtroom-facing
side -- helping a tenant understand an eviction process, a parent navigate a
custody filing -- is nearly empty.

**Why it's Tier 3:** Liability concerns are decisive. Incorrect legal guidance
in high-stakes domains (eviction, custody, criminal proceedings) creates
personal liability for the builder regardless of disclaimers. Court procedures
are public record and the technical translation to plain language is tractable,
but the legal risk makes this a poor fit for a solo developer. Jurisdiction
fragmentation (procedures vary by state, county, court) compounds this. Even
well-intentioned guidance risks confident wrong answers that expose the builder
to liability.

### Agricultural information for smallholders

500M smallholder farms, only 33M African smallholders reached by digital tools.
Personalized mobile recommendations show 7-10% yield increases. But target
users are on feature phones using USSD, locally relevant advice requires local
agronomic knowledge, distribution requires institutional relationships, and
the evidence base for what works is thin (only 14 empirical studies on mobile
ag-service adoption in SSA, 2010-2024).

### Small business tools for informal economies

$5.7T MSME financing gap in emerging markets. WhatsApp is the de facto OS for
informal commerce (~90M women use it for income-generating activity across
Kenya, Nigeria, India, Pakistan). But the interface is WhatsApp (platform you
don't control), payment reconciliation requires local mobile money
integrations, and building broadly requires local partnerships a solo developer
can't maintain.

### Government service navigation (beyond forms)

The tractable subset (helping people fill out forms) is captured in #2 above.
What remains is digitizing government services end-to-end, which requires
institutional cooperation a solo developer can't compel.

### Healthcare decision support

4.6B people lack access to essential health services. But regulatory barriers
(HIPAA and equivalents), liability for incorrect medical guidance, clinical
validation requirements, and the compounding difficulty of serving low-end
devices in non-English languages make this largely intractable for a solo
developer.

### Search and information retrieval

Web search requires a crawl index costing millions. Local/specialized search
is tractable, but competing with Google on web search is not.

### Communication platforms

Network effects are defining. A better messaging app with zero users has zero
value. The EU's Digital Markets Act may force some opening, but the marginal
value of a new entrant is near zero without an existing user base.

### Translation and language tools

Quality drops sharply outside major language pairs. Modern translation requires
large language models trained on parallel corpora -- infrastructure and data a
solo developer doesn't have. Building tools *around* existing APIs is
tractable; building the models is not.

---

## Cross-cutting observations

### Offline-first and non-English as a multiplier (not a category)

Offline-first architecture and non-English language support are not standalone
categories but cross-cutting properties that multiply marginal value across all
categories above. The single strongest predictor of underserved populations is
whether a tool can function offline in a non-English context. Every category in
Tiers 1-2 -- personal finance, forms, legal navigation, accessibility,
education, household logistics, structured data tools -- has significantly
higher marginal value when designed for low-connectivity, non-English-speaking
users.

The distinction: "offline bookkeeping" is bookkeeping (category #1) with an
architectural constraint, not a separate category from bookkeeping. This is why
offline-first is a property multiplier, not a category sibling. Readers should
weight entries higher in the ranking if they serve these populations; the
calibration evidence and baseline numbers support treating this as a
cross-cutting amplifier.

### The assumptions gap

The binding constraint across most underserved categories is not "software
doesn't exist" but that existing software assumes resources the target users
don't have: bandwidth, storage, English literacy, app store access, a modern
device, a stable identity, a bank account. The highest marginal value often
comes from rebuilding something that exists under radically different
assumptions.

Mobile money via USSD -- not apps -- is the most successful technology
deployment to underserved populations in history. It succeeded because it met
people where they were: no smartphone, no data plan, no app store.

### The 2026 device regression

Entry-level phones are getting worse, not better. The 2026 RAM shortage pushed
DRAM prices up 50% and NAND prices up 90%. Memory now accounts for 43% of the
bill of materials on entry-level devices. Software targeting these users needs
to be getting lighter, not heavier. Tailwind for minimal, local-first tools;
headwind for anything assuming growing device capabilities.

### The "just good enough" trap

Many categories appear well-served because solutions exist that work for the
vocal, English-speaking, technically-literate minority that dominates online
discourse. Software satisfaction surveys overwhelmingly sample people who
already have software that mostly works for them. The 3-4 billion people whose
needs are unmet don't show up in NPS surveys or Product Hunt discussions.
Assessing marginal value from English-language reviews systematically
understates the gaps in categories serving non-English-speaking populations.

### The complexity tax

Software complexity costs the US economy an estimated ~$1T/year and drains
~7% of annual revenue at the average company (Freshworks). 60% of employees
experience frustration with new software (Gartner). UK firms regret ~20% of
software purchases; companies use only 49% of provisioned licenses. There is a
structural opportunity in building tools that do less, but do it well -- tools
a non-technical person can use without training, that don't require an IT
department to deploy, that don't demand integration with 15 other systems. In
many categories, the highest-marginal-value entrant is the one with the fewest
features, not the most.

### The tractability spectrum

Based on the calibration evidence:

1. **Most tractable:** Libraries, CLI tools, developer infrastructure.
   Distribution via package managers. (curl, SQLite, ripgrep.)
2. **Highly tractable:** Local-first desktop/mobile apps for personal use.
   Distribution via direct download, app stores. (Obsidian, YNAB.)
3. **Moderately tractable:** Web apps for specific populations (legal self-help,
   privacy guidance, educational content). Distribution via the web.
4. **Less tractable:** Tools requiring local content/knowledge (agriculture,
   informal economy). Require partnerships or deep domain expertise.
5. **Least tractable:** Tools requiring infrastructure (search, translation),
   network effects (communication), or regulatory compliance (healthcare).

### Where network effects don't matter

The categories where solo developers have the most impact are those where the
product runs locally, adoption spreads through quality (not requiring friends
to also use it), and switching costs are low. Developer tools, local
productivity software, format converters, privacy tools, educational content.
In these categories, quality alone wins users from worse alternatives.

---

## Summary ranking

| Rank | Category | Marginal value | Tractability | Key constraint | Affected pop. |
|------|----------|---------------|-------------|----------------|---------------|
| 1 | Personal finance / micro-business bookkeeping | High | High | UX + offline + non-Western workflows | 500M-1B |
| 2 | Bureaucratic form / paperwork assistance | High | High | Jurisdiction long tail | 3-4B |
| 3 | Accessibility tooling + document remediation | High | High | Cross-platform screen reader testing | 1.3B+ |
| 4 | Developer tools / infra libraries | Moderate-high | Very high | Finding the right gap | 30M+ |
| 5 | Data format conversion | Moderate | Very high | Integration + edge cases | 500M+ |
| 6 | Offline-first education (individual) | High | Moderate | Localization + distribution | 2-3B |
| 7 | Caregiver coordination / household logistics | High | Moderate | Design problem (abstraction level) | 1-2B |
| 8 | Local-first structured data tools | High | Moderate | UX for non-programmers | 500M+ |
| 9 | Privacy/security integration | Moderate-high | Moderate | Platform fragmentation | 100M+ |
| 10 | Evidence-based mental health | High (per-person) | Moderate | Clinical validation + trust | varies |
| 11 | Personal knowledge management | Moderate | Very high | Category is crowded | 100M+ |

*Legal navigation (self-represented litigants) moved to Tier 3 due to liability concerns for solo developers.

Population estimates are rough order-of-magnitude of people currently
underserved, not total potential users.

**The most actionable insight, agreed on by both analyses:** The
highest-leverage position for a small team is building local-first tools that
work under constrained assumptions -- offline, low-bandwidth, low-storage,
non-English, cheap devices. This is where current solutions fail most
completely and where the absence of network effects means quality alone can
drive adoption.

---

## Data sources

DataReportal Digital 2026, GSMA Mobile Economy Africa 2026, W3Techs 2025,
Mappr Data Pricing 2026, GSMA Mobile Money Market Guide 2024, NCSC Access to
Justice 2025, 9to5Google RAM Shortage 2026, BankMyCell 2026, WHO 2022, WebAIM
Million 2025, IFC MSME Finance Gap, OECD Time Use Database, Stack Overflow
2025, JetBrains Developer Survey, Lancet Digital Health 2025, Gartner,
Freshworks, Harvard/Linux Foundation, American Action Forum.

**Key caveats:**
- "Affected population" estimates are proxies derived from connectivity,
  language, and device statistics -- not direct measurements of software need.
- Software satisfaction data is inherently biased toward populations that
  already use software.
- Legal data is predominantly US-sourced; global self-representation population
  is likely much larger but less well-measured.
- Time-use data is predominantly from OECD countries.
- All population projections are 2025-2026 estimates.
