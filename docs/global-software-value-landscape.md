# Global software value landscape (speculative)

> **Status: speculative research.** This is a landscape evaluation grounded in
> publicly available data, not settled analysis. Estimates are guesstimation with
> reasoning, not precision. Nothing here is committed-to direction.

## What this document is

An attempt to answer: what categories of software produce the most total value
across the global population? Where are the biggest gaps between potential value
and current reality?

"Value" is measured through several proxies, stated explicitly per category:
- **Time saved** -- hours of human life reclaimed, scaled by population affected.
- **Friction removed** -- reduction in steps, confusion, or coordination cost.
- **Suffering reduced** -- health outcomes, financial hardship, safety.
- **Capability gained** -- things people can do that they couldn't before.
- **Access expanded** -- people served who were previously excluded.

The unit of comparison is rough order-of-magnitude: billions of person-hours,
millions of lives, percentage points of a population. The goal is to compare
categories to each other, not to produce precise dollar figures.

## Baseline numbers (2026)

These anchor the estimates that follow.

- World population: ~8.2 billion.
- Internet users: 6.1 billion (74% of population). 2.2 billion unconnected.
- Smartphone users: 5.8 billion (70% of population).
- Students (all levels): ~1.8 billion enrolled; 272 million children out of school.
- People lacking essential health services: 4.6 billion.
- People facing financial hardship from healthcare costs: 2.1 billion.
- People with untreated depression: ~91% of those with depression lack adequate care.
- Adults without a bank account: 1.3 billion.
- Adults lacking basic digital skills: ~35% worldwide (~2.9 billion).
- US federal paperwork burden alone: ~10 billion person-hours/year.

Sources: DataReportal Digital 2026, WHO World Health Statistics 2025, World Bank
Global Findex 2025, UNESCO World Education Statistics 2025, BLS American Time
Use Survey 2024.

---

## Tier 1: Highest total value (billions of people, daily impact)

### 1. Search and information retrieval

**Proxy: time saved, capability gained.**

~6 billion internet users search for information regularly. Before search
engines, answering a factual question required a library visit, a phone call, or
giving up. Search engines compress what was minutes-to-hours into seconds,
multiple times per day.

Rough scale: if 4 billion people save 10 minutes/day through search (modest --
this includes indirect search via embedded results, autocomplete, maps), that is
~670 million person-hours saved per day, or ~240 billion person-hours per year.
This is probably the single largest time-savings any software category delivers.

**Gap:** Search quality has degraded for many query types (product research, medical
questions, anything with commercial intent) due to SEO spam and ad saturation.
The information is there but finding trustworthy answers increasingly requires
skill. AI-assisted search is partially closing this but introduces new failure
modes (confident wrong answers).

### 2. Communication platforms (messaging, email, video calling)

**Proxy: capability gained, friction removed, access expanded.**

Messaging apps (WhatsApp alone: ~3 billion users) replaced what was previously
impossible (instant free global communication) or expensive (international
calls, postal mail). Email serves ~4.5 billion users. Video calling went from
niche to universal during COVID.

The value here is not just time saved but relationships maintained, coordination
enabled, and economic participation unlocked. A migrant worker sending money home
coordinates via WhatsApp. A rural patient consults a doctor via video. A small
business takes orders via messaging.

**Gap:** Fragmentation. Conversations split across platforms (WhatsApp, Signal,
iMessage, SMS, Slack, Teams, Discord) with no interoperability. Group
coordination across platforms is painful. End-to-end encryption is inconsistent.
Spam and scam calls remain unsolved -- billions of people receive fraudulent
calls with no effective filter.

### 3. Navigation and mapping

**Proxy: time saved, capability gained.**

~1.5 billion monthly active users on Google Maps alone. Before digital maps:
getting lost, asking for directions, paper maps, missed turns. GPS navigation
saves an estimated 10-30 minutes per trip for unfamiliar routes.

But the value goes beyond personal navigation. Ride-hailing (serving hundreds of
millions), delivery services (food, packages), and emergency response all depend
on mapping infrastructure. Maps enabled entire economic categories that didn't
exist before.

**Gap:** Indoor navigation remains unsolved (hospitals, airports, malls). Transit
information is fragmented and often inaccurate in developing countries. Offline
functionality matters enormously for the 2.2 billion without reliable internet
but is an afterthought for most mapping products.

### 4. Financial transaction software (payments, banking, transfers)

**Proxy: friction removed, access expanded, time saved.**

Digital payments save time on every transaction (tap vs. count cash, online
payment vs. mailing a check). But the transformative value is in access
expansion: mobile money (M-Pesa and successors) brought financial services to
hundreds of millions of previously unbanked people. 1.3 billion adults remain
unbanked, mostly in sub-Saharan Africa and South Asia.

Remittances: migrants send ~$650 billion/year to developing countries. Digital
transfer services reduced costs from ~10% to ~3-6%, saving tens of billions of
dollars annually for some of the world's poorest families.

**Gap:** Cross-border payments remain slow and expensive. 1.3 billion unbanked
people still lack access. Identity verification requirements exclude people
without formal documentation. Fee structures are regressive (percentage-based
fees punish small transactions that poor people make).

### 5. Translation and language tools

**Proxy: access expanded, capability gained.**

~7,000 languages exist; most of the world's information is in ~10 languages.
Machine translation (Google Translate: ~1 billion users) gives partial access to
information, services, and communication across language barriers. The value is
hard to overstate for the billions of people whose primary language has limited
online content.

**Gap:** Quality drops sharply outside major language pairs. Most of the world's
languages have no machine translation at all. Real-time spoken translation is
improving but not yet reliable enough to replace interpreters in high-stakes
contexts (medical, legal). Sign languages are almost entirely unserved.

---

## Tier 2: High value, large populations, significant gaps

### 6. Healthcare decision support and access

**Proxy: suffering reduced, access expanded.**

4.6 billion people lack access to essential health services. 91% of people with
depression lack adequate treatment. The gap between what medical knowledge exists
and what reaches patients is enormous.

Current state: electronic health records exist but are fragmented, rarely
patient-accessible, and don't cross borders or even hospital systems. Telehealth
expanded during COVID but remains limited by regulatory barriers and broadband
access. Diagnostic AI shows promise but is unevenly deployed.

**Potential value:** Software that accurately triages symptoms, suggests when to
seek care, tracks chronic conditions, and connects patients to available
providers could meaningfully improve outcomes for billions. The key word is
"accurately" -- bad health advice is worse than no health advice.

Scale of the gap: WHO estimates that scaling proven digital health interventions
could avert millions of deaths annually in low- and middle-income countries.
Mental health is the starkest example: software-delivered therapy (CBT apps,
guided self-help) has evidence of efficacy but reaches a tiny fraction of the
population that could benefit.

### 7. Education and skill-building software

**Proxy: capability gained, access expanded.**

1.8 billion students enrolled worldwide. 272 million children out of school.
Sub-Saharan Africa tertiary enrollment: 9% vs. global average of 43%. 35% of
adults lack basic digital skills; 92% of jobs require them.

Existing software (Khan Academy, Duolingo, Coursera) demonstrates that high-
quality instruction can be delivered at near-zero marginal cost. The gap is not
the existence of educational software but its penetration, quality for non-
English speakers, and integration with credentialing systems that employers
recognize.

**Potential value:** Adaptive tutoring that adjusts to individual pace, in local
languages, on low-bandwidth connections, with credentialing that translates to
employment. The 272 million out-of-school children and the 2.9 billion adults
without basic digital skills represent a population larger than any single
country. Each person who gains functional literacy and numeracy through software
gains access to the entire digital economy.

**Gap:** Most educational software assumes reliable internet, a modern device,
and English proficiency. Offline-first, low-bandwidth, multilingual educational
tools are rare. Credential portability across borders is nearly nonexistent.

### 8. Government services and bureaucratic automation

**Proxy: time saved, friction removed, access expanded.**

In the US alone, citizens spend ~10 billion hours/year on federal paperwork.
Globally, the number is harder to estimate but plausibly 50-100 billion person-
hours/year spent on government forms, permits, tax filings, benefit
applications, court filings, and identity documentation.

Some countries (Estonia, Singapore, South Korea) have digitized most government
interactions. Most have not. The gap is not technology but implementation: the
software to replace paper forms with digital workflows is straightforward, but
institutional inertia, legacy systems, and political incentives impede adoption.

**Potential value:** If half of global government paperwork time could be
eliminated through digitization, that is 25-50 billion person-hours/year
reclaimed -- comparable to the value of search engines. The value is also
equity-related: bureaucratic burden falls disproportionately on the poor (who
rely more on government services and have less capacity to navigate complex
systems). In many developing countries, obtaining a birth certificate, land
title, or business permit requires multiple in-person visits, bribes, and weeks
of waiting -- software can compress this if institutional barriers are removed.

### 9. Agricultural decision support

**Proxy: suffering reduced, capability gained, access expanded.**

~500 million smallholder farms feed ~2 billion people. Most operate without
access to weather forecasts, soil data, market prices, or pest identification
tools that large farms take for granted. Precision agriculture technology exists
but adoption among smallholders in developing countries is minimal.

**Potential value:** A smallholder farmer with access to accurate 5-day weather
forecasts, pest identification via phone camera, and real-time market prices
could plausibly increase yields 10-30% and reduce post-harvest losses. At the
scale of 500 million farms feeding 2 billion people, this is one of the highest-
leverage software interventions possible. The constraint is less "does the
software exist" and more "can it run on a low-end phone with intermittent
connectivity in a local language."

---

## Tier 3: Significant value, smaller or more specialized populations

### 10. Disaster warning and emergency coordination

**Proxy: suffering reduced.**

Natural disasters affect ~160 million people/year. Early warning systems
(tsunami alerts, earthquake notifications, flood predictions) demonstrably save
lives. Software that coordinates emergency response (shelter locations, supply
distribution, missing person tracking) reduces suffering after disasters.

**Gap:** Warning systems exist for some disaster types in some countries but
coverage is uneven. Cell broadcast emergency alerts (like the US Wireless
Emergency Alerts system) are not universal. Coordination tools used in disaster
response are ad-hoc and fragmented.

### 11. Legal information and dispute resolution

**Proxy: access expanded, friction removed.**

Most people cannot afford lawyers. Legal information (tenant rights, employment
rights, family law, immigration procedures) is written in language that requires
legal training to parse. Online dispute resolution exists (eBay's system handles
60+ million disputes/year) but is not generalized.

**Gap:** Software that translates legal rights into plain language, helps fill
out legal forms, and provides low-stakes dispute resolution could expand access
to justice for billions. Current tools are jurisdiction-specific, English-
centric, and limited in scope.

### 12. Supply chain and logistics optimization

**Proxy: time saved, friction removed (indirect -- reduces costs passed to consumers).**

Global supply chains move $20+ trillion in goods annually. Software that
optimizes routing, inventory, and demand forecasting operates at scale but
primarily serves large enterprises. Small businesses and informal-economy
participants (a large fraction of workers in developing countries) lack access to
these tools.

**Gap:** The efficiency gains from logistics software flow disproportionately to
large companies. Small merchants, informal traders, and last-mile delivery in
areas without address systems remain underserved.

---

## Tier 4: High per-person value, smaller affected populations

### 13. Assistive technology

**Proxy: capability gained, access expanded.**

~1.3 billion people live with some form of disability. Screen readers, voice
control, switch access, and communication devices are life-changing for
individual users but adoption is limited by cost, complexity, and poor
integration with mainstream software.

**Gap:** Accessibility features are often afterthoughts. AI-powered tools
(automatic captioning, image description, voice synthesis) are improving rapidly
but unevenly available. The gap is largest in developing countries and for
non-English languages.

### 14. Scientific research tools

**Proxy: capability gained (indirect -- accelerates discovery).**

Research software (simulation, data analysis, visualization, collaboration)
serves ~10 million active researchers directly but its downstream effects --
drug discovery, materials science, climate modeling -- affect billions. The gap
is in accessibility: most research software is expensive, requires specialized
training, and runs only on high-end hardware.

### 15. Creative tools

**Proxy: capability gained, access expanded.**

Software that enables creation (music, visual art, writing, video, design) has
democratized creative output. A teenager with a phone can now produce and
distribute music or video globally. The per-person value is high (self-
expression, economic opportunity, cultural participation) and the population is
growing as device access expands.

---

## Cross-cutting themes

### The offline-first gap

2.2 billion people are not connected to the internet. Many more have
intermittent or expensive connections. Most high-value software assumes always-on
broadband. The gap between "software exists" and "software works for people
without reliable connectivity" accounts for a large fraction of the unrealized
value across every category above.

### The language gap

Most software of consequence is English-first. Machine translation partially
bridges this but introduces errors that range from inconvenient (a mistranslated
menu item) to dangerous (a mistranslated medical instruction). Software that is
natively multilingual -- not translated as an afterthought -- reaches more people
at higher quality.

### The literacy and digital skills gap

35% of adults worldwide lack basic digital skills. Software that assumes users
can read, type, and navigate menus excludes billions. Voice interfaces, visual
interfaces, and simplified workflows can expand access, but most software
development optimizes for the already-skilled.

### The institutional gap

Many categories above (healthcare, government, education) are limited not by
technology but by institutional willingness to adopt it. The software exists or
could be built, but deployment requires navigating regulation, legacy systems,
procurement processes, and organizational inertia. This is not a software
problem per se, but it determines how much of the potential value actually
reaches people.

---

## Summary: rough ranking by total value

Ordered by estimated aggregate value (population affected x per-person impact),
with the proxy used:

| Rank | Category | Pop. affected | Per-person impact | Primary proxy |
|------|----------|---------------|-------------------|---------------|
| 1 | Search/information retrieval | ~5B daily | Minutes/day | Time saved |
| 2 | Communication platforms | ~5B daily | Relationships, coordination | Capability |
| 3 | Navigation/mapping | ~2B regularly | Minutes/trip | Time saved |
| 4 | Financial transactions | ~5B | Access to economy | Access |
| 5 | Translation/language tools | ~3B potential | Access to information | Access |
| 6 | Healthcare decision support | ~4.6B underserved | Life-years | Suffering |
| 7 | Education/skill-building | ~3B underserved | Lifetime earnings | Capability |
| 8 | Government/bureaucratic automation | ~4B+ | Hours/year | Time saved |
| 9 | Agricultural decision support | ~2B (food chain) | Yield, income | Suffering |
| 10 | Disaster warning | ~160M/year | Life-saving | Suffering |
| 11 | Legal information access | ~5B underserved | Rights awareness | Access |
| 12 | Supply chain/logistics | ~8B (indirect) | Cost reduction | Friction |
| 13 | Assistive technology | ~1.3B | Independence | Capability |
| 14 | Scientific research tools | ~10M direct | Discovery (indirect) | Capability |
| 15 | Creative tools | ~1B+ | Expression, income | Capability |

The largest gaps between current and potential value are in categories 6-9:
healthcare, education, government services, and agriculture. These affect
billions of people, the technology to help them largely exists, and the barriers
are deployment, localization, and institutional adoption rather than invention.

The categories that currently deliver the most realized value (1-4) are also the
most mature -- search, communication, maps, and payments work well for most of
their users most of the time. Incremental improvements here are still valuable
at scale but the ratio of potential-to-realized is smaller.

The cross-cutting gaps (offline access, language, digital literacy) are
multipliers: closing any one of them amplifies the value of every category
above.
