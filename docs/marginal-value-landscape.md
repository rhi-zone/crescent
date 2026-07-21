# Marginal value landscape for small-team software (speculative)

> **Status: speculative research.** This is a landscape evaluation grounded in
> publicly available data, not settled analysis. Estimates are guesstimation with
> reasoning, not precision. Nothing here is committed-to direction.
>
> A cleanroom comparison was performed against an independent analysis of the
> same question. Where the two disagreed, the reasoning was re-evaluated and
> this document was updated. The most significant correction: the original
> version bundled personal knowledge management with personal finance under
> one category and ranked it #1; these are now separated, with PKM ranked
> lower (the category is well-served) and personal finance ranked higher
> (genuinely underserved).

## What this document is

A revision of `global-software-value-landscape.md` through two different lenses:

1. **Marginal value, not total value.** The question is not "how much value
   does this category deliver" but "how much *additional* value would a new
   entrant deliver over what already exists?" Categories where current solutions
   are excellent score low even if total value is enormous. Categories where
   solutions are bad, fragmented, nonexistent, or inaccessible score high.

2. **Tractability for a single developer or small organization.** Filtered to
   what one person or a small team can realistically build and ship. Categories
   requiring massive infrastructure, regulatory compliance (HIPAA, PCI, etc.),
   network effects demanding existing scale, or data moats are less tractable.
   Categories where a well-built local-first tool or focused product can
   meaningfully serve people are more tractable.

The unit of comparison remains rough order-of-magnitude. The goal is relative
ranking across categories, not precise dollar figures.

## Calibration: what solo developers have actually built

Before ranking categories, it helps to know what the ceiling looks like.

- **curl** -- Daniel Stenberg, solo maintainer since 1998. 20+ billion device
  installs. Ships in every OS, game console, and most major apps.
- **SQLite** -- D. Richard Hipp, team of ~3. Most-deployed database in the
  world -- every phone, every browser.
- **Obsidian** -- 7-person team, zero funding. ~1.5M MAU, ~$25M ARR. Local-
  first note-taking that displaced tools from companies with 100x the headcount.
- **Redis** -- Salvatore Sanfilippo, solo creator. Became the default caching
  layer for the industry.
- **ripgrep** -- Andrew Gallop, solo. 50K+ GitHub stars, powers VS Code's
  search across tens of millions of installations.
- **Nomad List** -- Pieter Levels, solo. $5.3M revenue in 2024.
- **Base44** -- Maor Shlomo, solo. 250K users, acquired for $80M in 2025.

The pattern: **local-first tools and infrastructure distributed via package
managers or direct download have the shortest path from one person to millions
of users.** Network effects don't gate entry; quality wins. The strongest
distribution channels for solo developers are package managers (npm, pip, brew,
apt), GitHub, and the web (no-install PWAs).

## Baseline numbers (2026)

Carried forward from the total-value analysis, with additions relevant to the
marginal lens:

- World population: ~8.2 billion. Internet users: 6.1 billion.
- Smartphone users: 5.8 billion. Feature phone users: ~2.1 billion (declining).
- Entry-level smartphone: 4 GB RAM, 64-128 GB storage, Android Go. A 2026
  RAM shortage pushed DRAM prices up 50%, making cheap phones worse, not better.
- Sub-Saharan Africa: ~1 billion people (63%) not using mobile internet despite
  coverage -- the barrier is cost, not infrastructure.
- Mobile data cost: global average $2.59/GB. India $0.27/GB. Zimbabwe $43.75/GB.
  Sub-Saharan Africa averages ~5.8% of monthly income for 1 GB (3x the UN
  affordability target of 2%).
- English is 49.3% of web content despite 19% of speakers. Hindi is under 0.1%
  of web content despite India having 1.03 billion internet users.
- Mobile money: 2.1 billion registered accounts, 514 million MAU, $1.7 trillion
  in annual transactions. Runs on USSD -- no smartphone or data plan needed.
- 55% of US court cases now have at least one self-represented party (up from
  4% in the 1990s).
- 92% of low-income Americans cannot get legal help.
- Mint shut down March 2025, leaving local-first personal finance essentially
  unserved.
- 90%+ of businesses globally are micro-enterprises (1-9 employees). IFC
  estimates a $5.7 trillion MSME financing gap in emerging markets.
- Women globally spend ~134 minutes/day on unpaid caregiving (vs 76 for men).
- 95.9% of the top 1 million websites have detectable WCAG failures, averaging
  56.8 errors per homepage. Only ~3% of the internet is considered accessible.

Sources: DataReportal Digital 2026, GSMA Mobile Economy Africa 2026, W3Techs
2025, Mappr Data Pricing 2026, GSMA Mobile Money Market Guide 2024, NCSC
Access to Justice 2025, 9to5Google RAM Shortage 2026, BankMyCell 2026,
WHO 2022, WebAIM Million 2025, IFC MSME Finance Gap, OECD Time Use Database.

---

## Tier 1: Highest marginal value x tractability

Categories where (a) current solutions are poor, fragmented, or absent,
(b) a meaningful improvement is buildable by one person or a small team, and
(c) the affected population is large.

### 1. Personal finance and micro-business bookkeeping

**Why the marginal value is high:**

Mint (the most popular free personal finance tool in the US) shut down in March
2025. Its successors (YNAB, Copilot) are cloud-dependent with third-party data
integrations (Plaid) that a 2025 analysis flagged for exposing personal data.
There is no Obsidian-equivalent for personal finance: a local-first tool that
stores data on the user's device, syncs optionally, and doesn't require
trusting a third party with financial records.

The gap is sharper internationally. 90%+ of businesses globally are micro-
enterprises (1-9 employees). In developing countries, most use paper ledgers or
basic spreadsheets. In developed countries, existing solutions (QuickBooks,
Xero, FreshBooks) cost $15-50+/month, assume English, assume reliable internet,
and are designed for businesses with bank integrations and formal tax
structures. A micro-business owner in Lagos, Lima, or Lahore running a shop
with cash transactions has effectively zero good software options.

**Why it's tractable:**

Accounting is math on structured records. The core logic is simple. No network
effects. No regulatory compliance required for personal/micro-business use
(you're helping people track money, not filing taxes for them). Offline-first
is natural -- financial records should survive an internet outage. A single
developer can build a solid double-entry bookkeeping tool that works on a phone.

**What a new entrant would need to get right:**

Data format that outlives the app (plain files, not a proprietary database).
Works offline by default. Handles cash-based workflows, not just bank-synced
ones. Runs on low-end devices. Doesn't assume English or Western financial
structures.

**Affected population:** Perhaps 500M-1B micro-business operators globally who
currently track finances on paper or not at all, plus hundreds of millions of
individuals in wealthy countries dissatisfied with personal finance tools after
Mint's death.

### 2. Legal navigation for self-represented litigants

**Why the marginal value is high:**

55% of US court cases now have at least one self-represented party -- up from
4% in the 1990s. Pro se litigants are 6.5x more likely to lose: only 3% of
pro se plaintiffs get favorable judgments vs. 40% for represented defendants.
92% of low-income Americans cannot get legal help.

The existing tools (LegalZoom, Rocket Lawyer) prepare documents but don't help
people understand or navigate proceedings. Top complaints: opaque upselling,
subscription traps, and the fundamental limitation that they produce forms but
not comprehension. ~$5B in legal tech investment in 2024 went overwhelmingly to
Big Law and corporate tools. The courtroom-facing side -- helping a tenant
understand an eviction process, a parent navigate a custody filing, a debtor
respond to a collection suit -- is nearly empty.

The affected population is not small or niche: it is now the majority of
litigants in many US court systems, and similar patterns exist worldwide.

**Why it's tractable:**

Court procedures are public record. Forms, deadlines, and filing requirements
are published by courts. The gap is not access to the information but
translation of that information into plain language, sequenced into a workflow
someone without legal training can follow. This is a content-and-UX problem,
not an infrastructure problem. A single developer could build jurisdiction-
specific procedural guides for high-volume case types (housing, family, small
claims, debt collection) and ship as a web app with no install step.

**What limits tractability:**

Jurisdiction fragmentation -- procedures vary by state, county, and court.
Building for one jurisdiction is tractable; building for all of them is a
content scaling problem. Liability concerns (must be clear the tool provides
information, not legal advice). LLM-generated legal guidance risks confident
wrong answers in a high-stakes domain.

**Estimate of marginal value:** High. Millions of people navigate court
proceedings alone each year. The difference between understanding the process
and not understanding it is often the difference between winning and losing a
case that determines housing, custody, or financial survival. Current tools
don't address this.

### 3. Bureaucratic form and paperwork assistance

**Why the marginal value is high:**

Americans spend an estimated 11.5 billion hours per year on federal paperwork
alone -- roughly 45 hours per adult per year. 81%+ of that is IRS-related. The
OECD average for tax compliance alone is 117 hours/year. In countries with less
digitized governments, the burden is often worse, compounded by physical
queuing, repeated submissions, and opaque requirements.

Government forms are one of the most universally hated interactions humans have
with bureaucracy, yet the software to help is either expensive (TurboTax, H&R
Block), jurisdiction-specific and unmaintained, or nonexistent for non-US/non-EU
countries. The pain is not just time -- errors on forms cause cascading problems
(rejected applications, delayed benefits, fines).

**Why it's tractable:**

Each jurisdiction's forms are public documents. A tool doesn't need to file
anything -- just help people fill out forms correctly. Start with one
jurisdiction, one form type. No regulatory barrier to helping someone fill out a
form (you're providing a structured editor, not legal or tax advice). PDF
parsing and form-filling is well-understood technically. LLM integration for
plain-language explanations of form fields is now cheap.

**Tractability caveat:** The value scales with jurisdiction coverage, which is a
long tail. But even a single well-served jurisdiction (e.g., a tool that helps
Indian citizens fill out common government forms) serves hundreds of millions.

**Affected population:** Virtually every adult -- ~5 billion people interact
with government paperwork. The subset poorly served by current tools is probably
3-4 billion.

### 4. Accessibility tooling and document remediation

**Why the marginal value is high:**

Screen readers themselves are mature and high-satisfaction (NVDA 97.6%, JAWS
95.6% per WebAIM Survey #10). The gap has shifted: the bottleneck is not screen
reader quality but that the documents and websites people need to use are
inaccessible. 95.9% of the top 1 million websites have detectable WCAG
failures, averaging 56.8 errors per homepage. Only ~3% of the internet is
considered accessible.

Two distinct gaps exist. First, developer-facing tools: automated accessibility
scanners catch only a fraction of real-world issues, and developers rarely test
with actual screen readers. A tool that surfaces real screen-reader behavior
during development would address the root cause. Second, document remediation: a
tool that takes an inaccessible PDF, Word document, or webpage and produces an
accessible version (proper heading structure, alt text, reading order, form
labels) would directly serve 1.3B people with disabilities. Existing
remediation tools are expensive enterprise products ($thousands/year) or require
manual expertise.

SME accessibility tooling is the fastest-growing segment (19.6% CAGR) as
smaller companies face compliance pressure (WCAG, ADA, EAA) without enterprise
budgets.

**Why it's tractable:**

Document structure analysis is well-suited to current ML/heuristic approaches.
PDF accessibility remediation is a bounded technical problem. A browser
extension that improves page accessibility on the fly is buildable by one
developer. Developer-facing tools integrate with browser devtools or CI
pipelines and distribute via the same channels that work for other dev tools.
No network effects, no regulatory barrier (you're improving compliance, not
requiring it).

**What limits tractability:**

Screen reader behavior is platform-specific and under-documented. Testing
across JAWS, NVDA, VoiceOver, and TalkBack requires multiple platforms.
Multi-language support for document remediation (alt text generation, reading
order heuristics) adds complexity.

**Affected population:** 1.3 billion people with disabilities, plus ~1 billion
aged 60+ with declining vision/hearing/motor control. Organizations that need
to make documents accessible (schools, small governments, nonprofits) are also
underserved.

### 5. Developer tools and infrastructure libraries

**Why the marginal value is high:**

This category is perpetually high-marginal-value because the field continuously
creates new pain points. JetBrains surveys (65K+ respondents) identify
persistent frustrations: technical debt management, slow/fragmented build
systems, poor cross-language interop. AI coding tools (Cursor: 1M+ developers,
1000% YoY growth) are creating new categories of pain around trust and
correctness. 44% of profitable SaaS products are now run by a single founder --
doubled since 2018 -- meaning more solo developers need better tooling.

The tractability ceiling is proven: curl, SQLite, Redis, ripgrep, Homebrew.
Infrastructure that gets embedded transitively means one user pulling it in
gives thousands of downstream users. Package managers provide free
distribution at global scale.

**Why it's tractable:**

No category has a stronger track record of solo-developer success. The tools
run locally, quality is legible (faster, more correct, easier to use), and
distribution through package managers and GitHub is free and global. No network
effects, no regulatory barriers, no data moats.

**Estimate of marginal value:** Moderate-to-high. The per-person value is
moderate (developer productivity), but the affected population (~30M developers
worldwide, plus transitive users of infrastructure) is large, and the space
continuously generates new gaps as technology evolves. The marginal value of
any individual tool is high if it addresses a genuine pain point; the category
as a whole always has room for well-built entries.

### 6. Data format conversion and interoperability

**Why the marginal value is high:**

The backbone tools for format conversion are old, powerful, and miserable to
use. FFmpeg (audio/video) has a flag syntax that is a running joke in the
developer community. Pandoc (documents) produces variable-quality output
depending on the format pair. ImageMagick has had serious security
vulnerabilities. All are CLI-only, inaccessible to non-technical users.

On the other end, consumer-facing converters (CloudConvert, Zamzar) are cloud-
dependent, rate-limited, upload your files to third-party servers, and charge
subscriptions. Gartner estimates poor data quality -- including conversion
failures -- costs organizations $12.9M/year on average.

Everyone encounters this: convert a DOCX to PDF, resize images, extract audio
from video, merge PDFs, convert CSV to JSON. The gap is a single, local-first,
privacy-respecting tool that handles the common conversions well, with a
discoverable interface. A "convertr" CLI recently appeared wrapping Pandoc +
FFmpeg + LibreOffice + ImageMagick behind smart routing, signaling unmet demand.

**Why it's tractable:**

The hard conversion logic already exists in open-source libraries. The value
a solo developer adds is the integration layer: routing between converters,
handling edge cases, providing a usable interface (CLI for developers, GUI or
web for everyone else). No network effects. No data moat. The tool runs
locally -- nothing to host.

**Estimate of marginal value:** Moderate. Affects hundreds of millions of
people who convert files regularly. The per-instance value is small (minutes
saved, privacy preserved), but the frequency is high and every existing option
has significant drawbacks. Good tools (pandoc, ffmpeg) do exist -- the gap is
in the UX layer, not the capability layer. This lowers the marginal value
compared to categories where no adequate tool exists at all.

---

## Tier 2: High marginal value, moderate tractability

Categories where the gap is large and the affected population is significant,
but building and shipping a solution faces real (not insurmountable) obstacles.

### 7. Offline-first educational tools for individual learners

**Why the marginal value is high:**

2.6 billion people lack reliable internet. Existing offline educational tools
(Kolibri, Learning Passport, iDream Education) are institution-deployed:
they require schools, NGOs, or governments to set up and distribute. There is
almost nothing that works as a self-directed offline learning tool a single
learner can pick up on their own device. The content exists (Khan Academy's
library, Wikipedia, open textbooks), but packaging it for offline individual
use with good UX on a low-end phone is an unsolved problem.

272 million children are out of school. 2.9 billion adults lack basic digital
skills. The population that could benefit from self-paced offline education is
larger than any country.

**Why it's moderately tractable:**

The content licensing is often open (CC-BY). The technical challenge is
packaging and compression: fitting useful educational content into the storage
and bandwidth constraints of entry-level devices ($0.27-$43.75 per GB of mobile
data; 4 GB RAM). PWAs are viable on Android Go (Chrome 40+, service worker
support), enabling no-install distribution that bypasses app store gatekeeping.
A small team could build a PWA that caches a focused curriculum (literacy,
numeracy, digital skills) for offline use.

**What limits tractability:**

Content localization is labor-intensive -- 7,000 languages, and machine
translation introduces errors that are unacceptable in educational content.
The target users may have low digital literacy, demanding careful UX design.
Distribution without institutional partners is harder (how does a learner
without internet access discover and download the tool?). Testing requires
real devices and real contexts, not emulators.

**Estimate of marginal value:** High. The gap between "educational content
exists" and "educational content is accessible to a person without reliable
internet, on a cheap phone, in their language" is enormous. Any tool that
closes part of this gap serves a population in the billions. But the
localization and distribution challenges mean a single developer's impact is
likely regional (one language group, one curriculum area) rather than global.

### 8. Caregiver coordination and household logistics

**Why the marginal value is high:**

Women globally spend ~134 minutes/day on unpaid caregiving (vs 76 for men).
Household logistics -- scheduling, meal planning, medication tracking, school
coordination, eldercare management -- consume enormous time and are mostly
managed in people's heads, on paper, or via fragmented apps (one for groceries,
one for calendar, one for medications, none of which talk to each other).

Calendar apps exist but don't model household complexity: recurring but
irregular tasks, delegation, dependencies between household members, context
about preferences and constraints. No good integrated tool exists for "running a
household" as a first-class domain. Existing apps treat each sub-problem in
isolation.

**Why it's moderately tractable:**

No infrastructure requirements. Local-first is natural. No regulatory barriers.
The challenge is design -- modeling the right abstractions for household
logistics is hard, and the design space is littered with failed attempts that
were either too simple (just a shared list) or too complex (project management
software for families).

**What limits tractability:**

Shared household tools have mild network effects (value increases when family
members also use it), though the tool is useful to a single person managing a
household alone. The design problem -- finding the right level of abstraction
between a to-do list and a project management tool -- has defeated many
attempts. The population is large but the willingness to adopt yet another
organizational tool may be limited.

**Affected population:** ~2 billion adults who manage households, weighted
toward women. The primary caregiving population (those managing care for
children, elderly, or disabled family members) is perhaps 1-1.5 billion.

### 9. Local-first structured data tools (spreadsheet-database hybrid)

**Why the marginal value is high:**

Spreadsheets are the most widely used "programming" tool in the world. Google
Sheets requires internet. Excel requires a license. LibreOffice Calc is capable
but heavy. None of them handle structured data well -- people use spreadsheets
as databases because actual databases are inaccessible to non-programmers.
Airtable and Notion databases exist but are cloud-dependent, expensive at
scale, and English-centric.

The gap between "spreadsheet" and "database" is where enormous amounts of
real-world data management happens -- inventory lists, student records, project
tracking, contact management, event planning. People force these into
spreadsheets because the alternative is enterprise software they can't afford or
understand.

**Why it's moderately tractable:**

SQLite exists. The core engine is solved. The challenge is UX -- making
structured data manipulation accessible to non-programmers with spreadsheet-like
interaction and database-like capabilities (types, relations, views, queries).
No cloud infrastructure needed. No network effects for individual use. One
developer can build a usable tool.

**Affected population:** Hundreds of millions of knowledge workers, students,
small business operators, and community organizers who currently wrangle data in
spreadsheets. Billions if you include the population that currently uses paper
because spreadsheets are inaccessible.

### 10. Privacy and security integration for non-technical users

**Why the marginal value is high:**

The individual privacy tools are good: Signal (85M MAU), Bitwarden (10% US
password manager share), Proton (100M accounts). The gap is not the tools
themselves but the integration layer. A non-technical person who wants to be
reasonably private and secure needs to install and configure 4-5 separate
tools (encrypted messaging, email, VPN, password manager, 2FA) with no unified
onboarding, no guidance on what matters most, and no way to verify they set
things up correctly.

A 2025 study across 18,628 websites found privacy controls buried in multiple
layers with inconsistent terminology. Academic research consistently finds
average users find privacy tools "complex and difficult to decipher." The
result: 64% of Americans don't use a password manager; most people use
unencrypted email; VPN adoption is driven by streaming geo-bypass rather than
privacy.

**Why it's moderately tractable:**

A solo developer can't build Signal or Proton from scratch. But a tool that
assesses a user's current privacy posture, recommends specific actions in
priority order, walks them through setup, and verifies the result -- this is a
content, UX, and integration problem, not an infrastructure problem. It could
be a web app, a browser extension, or a desktop app. No network effects, no
data moat.

**What limits tractability:**

The tool touches security, which means getting it wrong is actively harmful
(false sense of security is worse than no sense of security). The threat model
varies enormously by user (journalist vs. teenager vs. domestic abuse survivor).
Platform fragmentation (Windows, macOS, iOS, Android, Linux) multiplies the
surface area.

**Estimate of marginal value:** Moderate-to-high. Hundreds of millions of
people would benefit from basic privacy hygiene. The per-person value ranges
from inconvenience-prevention (spam, data broker profiling) to safety-critical
(stalking, political persecution). No one owns this problem end-to-end.

### 11. Mental health self-help tools (evidence-based)

**Why the marginal value is high:**

Over 90% of mental health apps on the market have no clinical evidence. The
two dominant consumer apps (Calm: $210M revenue, declining 24% YoY; Headspace:
$39M revenue) are content libraries (meditation recordings), not therapy. The
evidence-based tools that exist (Woebot: FDA Breakthrough Device Designation,
14 RCTs; Wysa: 2024 RCT showing meaningful depression reduction) have limited
reach. A 2025 Lancet Digital Health meta-analysis (92 RCTs, 16,728
participants) confirmed that standalone apps can produce moderate clinical
improvement, with personalization and engagement features mattering most.

Meanwhile, 91% of people with depression worldwide lack adequate treatment.
The gap between "software-delivered therapy has clinical evidence" and "the
people who need it can access it" is vast.

**Why it's moderately tractable:**

CBT-based interventions have well-documented protocols that can be implemented
in software. A small team can build an app that delivers structured CBT
exercises, mood tracking, and psychoeducation. The clinical evidence base
exists -- the problem is reaching people, not inventing the intervention.

**What limits tractability:**

Clinical validation takes time and expertise (even if the intervention itself
is evidence-based, demonstrating that *your* implementation works requires an
RCT or at minimum a clinical study). Subscription fatigue is real in this
category -- both Calm and Headspace are declining. Liability concerns if users
are in crisis. The hardest-to-reach populations (low-income, non-English-
speaking) are also the ones most difficult to serve via an app.

**Estimate of marginal value:** High per-person (for those who engage),
moderate aggregate (engagement and retention are the binding constraint, not
availability). The gap is more distribution and trust than technology.

### 12. Personal knowledge management and note-taking

**Why the marginal value is moderate:**

Obsidian (~1.5M MAU, $25M ARR), Logseq, Notion (100M+ accounts), Apple Notes,
Google Keep, Bear, Joplin -- the category is crowded. For English-speaking,
technically-inclined users, the problem is well-served. Obsidian in particular
proves that local-first, small-team note-taking can win.

The remaining gaps are real but narrower than in the categories above:
non-English speakers are underserved, most tools assume technical literacy, and
true local-first data ownership (not just local storage with cloud sync
required for key features) is still rare outside Obsidian and Logseq.

**Why it's highly tractable:**

Text files, search, and linking are solved problems. Very tractable for a solo
developer. The challenge is taste and restraint in design -- doing less, better,
for a specific underserved population rather than competing head-on with
Obsidian for the same users.

**Estimate of marginal value:** Moderate. The underserved subset is those who
find existing tools too complex, too expensive, or unavailable in their
language. This is a real population but not as large or as acutely underserved
as the categories ranked above.

---

## Tier 3: High marginal value, low tractability for a solo developer

These categories have large gaps and large affected populations, but the
barriers to entry make them poor fits for a single developer or small team.
Included for completeness and because the reasons they're intractable are
instructive.

### 13. Agricultural information for smallholders

**Gap:** 500 million smallholder farms, only 33 million African smallholders
currently reached by digital tools. Farmer.Chat (250K users), PlantVillage
(~15M farmers via multiple channels), Farmerline's Darli (110K users).
Personalized mobile recommendations show 7-10% yield increases. Most tools
require smartphones and connectivity that farmers don't have.

**Why it's less tractable:** The target users are on feature phones using USSD
and SMS, not apps. Locally relevant agronomic advice requires local agronomic
knowledge (crop varieties, soil types, pest species vary by region). The
content problem dominates the software problem. Distribution requires
relationships with agricultural extension services, telecoms, or NGOs. Only 14
empirical studies on mobile ag-service adoption in SSA exist (2010-2024) --
the evidence base for what works is thin.

### 14. Small business tools for informal economies

**Gap:** IFC estimates a $5.7 trillion MSME financing gap in emerging markets.
WhatsApp is the de facto operating system for informal commerce (~90M women use
it for income-generating activity across Kenya, Nigeria, India, Pakistan).
Startups (Imali, Syncli) are building WhatsApp-native bookkeeping and
inventory tools, but the ecosystem is fragmented.

**Why it's less tractable:** The interface is WhatsApp, not a standalone app --
meaning you're building on a platform you don't control. The users operate in
USSD/SMS-native environments. Payment reconciliation requires integration with
local mobile money systems (M-Pesa, MTN MoMo, etc.), each with its own API
and requirements. Building for one market (one country, one mobile money
system) is tractable; building broadly requires local partnerships and
integrations a solo developer can't easily maintain.

### 15. Government service navigation (beyond forms)

**Gap:** US federal paperwork alone: ~10 billion person-hours/year. Globally,
plausibly 50-100 billion person-hours/year on government forms, permits, tax
filings, benefit applications. Some countries (Estonia, Singapore) have
digitized; most have not.

**Why it's less tractable:** The bottleneck is institutional adoption, not
software. Government APIs, when they exist, are unreliable and poorly
documented. Forms and procedures change without notice. Note: the tractable
subset (helping people fill out specific forms) is captured in category 3
above. What remains here is the broader problem of digitizing government
services end-to-end, which requires institutional cooperation a solo developer
can't compel.

### 16. Healthcare decision support

**Gap:** 4.6 billion people lack access to essential health services. Software-
delivered triage and chronic condition management has evidence of efficacy but
minimal deployment in the populations that need it most.

**Why it's less tractable:** Regulatory barriers (HIPAA in the US, similar
frameworks elsewhere). Liability for incorrect medical guidance. Clinical
validation requires institutional partnerships. The populations most in need
are on low-end devices with expensive data in non-English languages --
compounding the difficulty. A solo developer building a health app faces
regulatory, liability, and trust barriers that don't exist for a notes app.

### 17. Search and information retrieval

**Gap:** Search quality has degraded for many query types (SEO spam, ad
saturation). AI-assisted search is partially closing this but introduces
confident wrong answers.

**Why it's less tractable:** Web search requires a crawl index -- infrastructure
that costs millions to build and maintain. Local/specialized search (searching
your own files, a specific corpus) is tractable for a solo developer, but
competing with Google on web search is not. The marginal value of improving
search is enormous in aggregate but requires scale that a solo developer
doesn't have.

### 18. Communication platforms

**Gap:** Fragmentation across WhatsApp, Signal, iMessage, SMS, Slack, Teams,
Discord with no interoperability. Spam and scam calls remain unsolved.

**Why it's less tractable:** Communication tools are defined by network effects.
A better messaging app with zero users has zero value. Interoperability
requires cooperation from incumbents who have no incentive to cooperate (though
the EU's Digital Markets Act may force some opening). The marginal value of a
new entrant is near zero without an existing user base.

### 19. Translation and language tools

**Gap:** Quality drops sharply outside major language pairs. Most of the
world's 7,000 languages have no machine translation at all.

**Why it's less tractable:** Modern translation requires large language models
trained on parallel corpora -- infrastructure and data that a solo developer
doesn't have. The languages most in need of translation tools are those with
the least available training data. A solo developer could build tools *around*
existing translation APIs (better UX, offline caching, domain-specific
glossaries) but can't build the translation models themselves.

---

## Cross-cutting observations

### The assumptions gap

The binding constraint across most underserved categories is not "software
doesn't exist" but that existing software assumes resources the target users
don't have: bandwidth, storage, English literacy, app store access, a modern
device, a stable identity, a bank account. The highest marginal value often
comes not from building something new but from rebuilding something that exists
under radically different assumptions.

Mobile money via USSD -- not apps -- is the most successful technology
deployment to underserved populations in history. It succeeded because it met
people where they were: no smartphone, no data plan, no app store. Software
designed for the global majority needs to reason from similar starting points.

### The 2026 device regression

Entry-level phones are getting worse, not better. The 2026 RAM shortage pushed
DRAM prices up 50% and NAND prices up 90%. Memory now accounts for 43% of the
bill of materials on entry-level devices. Software targeting these users needs
to be getting lighter, not heavier. This is a tailwind for minimal, local-first
tools and a headwind for anything that assumes growing device capabilities.

### The "just good enough" trap

Many categories appear well-served because solutions exist that work for the
vocal, English-speaking, technically-literate minority that dominates online
discourse. This creates a distorted picture: software satisfaction surveys
overwhelmingly sample people who already have software that mostly works for
them. The 3-4 billion people whose needs are unmet don't show up in NPS
surveys or Product Hunt discussions. Assessing marginal value from
English-language reviews and tech press systematically understates the gaps
in categories that serve (or fail to serve) non-English-speaking populations.

### The complexity tax

Software complexity costs the US economy an estimated ~$1 trillion/year and
drains ~7% of annual revenue at the average company (Freshworks). 60% of
employees experience frustration with new software (Gartner). UK firms regret
~20% of software purchases; companies use only 49% of provisioned licenses.
There is a structural opportunity in building tools that do less, but do it
well -- tools that a non-technical person can use without training, that don't
require an IT department to deploy, that don't demand integration with 15 other
systems. In many categories, the highest-marginal-value entrant is not the one
with the most features but the one with the fewest.

### Where network effects don't matter

The categories where solo developers have the most impact are those where the
product runs locally, adoption spreads through quality and word-of-mouth (not
requiring friends to also use it), and switching costs are low. Developer tools,
local productivity software, format converters, privacy tools, educational
content. In these categories, a single developer building something better
actually wins users from worse alternatives.

### The tractability spectrum

The research suggests a rough ordering of tractability for a solo developer:

1. **Most tractable:** Libraries, CLI tools, developer infrastructure.
   Distribution via package managers. curl, SQLite, ripgrep.
2. **Highly tractable:** Local-first desktop/mobile apps for personal use.
   Distribution via direct download, app stores. Obsidian, YNAB.
3. **Moderately tractable:** Web apps for specific populations (legal
   self-help, privacy guidance, educational content). Distribution via the web.
4. **Less tractable:** Tools requiring local content/knowledge (agriculture,
   informal economy). Require partnerships or deep domain expertise.
5. **Least tractable:** Tools requiring infrastructure (search, translation),
   network effects (communication), or regulatory compliance (healthcare,
   finance).

---

## Summary: marginal value x tractability ranking

Ordered by estimated marginal value (how much better would a new entrant make
things) weighted by tractability (can a solo developer or small team actually
build and ship it):

| Rank | Category | Marginal value | Tractability | Key constraint |
|------|----------|----------------|--------------|----------------|
| 1 | Personal finance / micro-business bookkeeping | High | High | UX + offline + non-Western workflows |
| 2 | Legal navigation (self-represented) | High | High | Jurisdiction fragmentation |
| 3 | Bureaucratic form / paperwork assistance | High | High | Jurisdiction long tail |
| 4 | Accessibility tooling + document remediation | High | High | Cross-platform screen reader testing |
| 5 | Developer tools / infra libraries | Moderate-high | Very high | Finding the right gap |
| 6 | Data format conversion | Moderate | Very high | Integration + edge cases |
| 7 | Offline-first education (individual) | High | Moderate | Localization + distribution |
| 8 | Caregiver coordination / household logistics | High | Moderate | Design problem (abstraction level) |
| 9 | Local-first structured data tools | High | Moderate | UX for non-programmers |
| 10 | Privacy/security integration | Moderate-high | Moderate | Platform fragmentation |
| 11 | Evidence-based mental health | High (per-person) | Moderate | Clinical validation |
| 12 | Personal knowledge management | Moderate | Very high | Category is crowded |
| 13 | Agricultural info (smallholders) | High | Low-moderate | Content + distribution |
| 14 | Informal economy tools | High | Low-moderate | Platform dependency |
| 15 | Government services (beyond forms) | High | Low | Institutional barriers |
| 16 | Healthcare decision support | Very high | Low | Regulatory + liability |
| 17 | Search / information retrieval | Moderate | Very low | Infrastructure cost |
| 18 | Communication platforms | Moderate | Very low | Network effects |
| 19 | Translation / language tools | High | Very low | Model training at scale |

The top of this list looks very different from a total-value ranking. Search
and communication -- the highest total-value categories -- rank near the bottom
on marginal value x tractability because current solutions are good and
competing requires scale a solo developer doesn't have. Categories like legal
navigation and personal finance rise because current solutions are poor, the
affected population is large, and a solo developer can build something
meaningfully better.

The most actionable insight: **the highest-leverage position for a small team
is building local-first tools that work under constrained assumptions** --
offline, low-bandwidth, low-storage, non-English, cheap devices. This is where
current solutions fail most completely and where the absence of network effects
means quality alone can drive adoption.
