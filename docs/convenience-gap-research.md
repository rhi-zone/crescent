# Convenience gap research (speculative)

> **Status: speculative/incubating.** These are research findings and early thinking,
> not settled decisions. Nothing here is committed-to direction.

## Framing

Almost all essential programs — the ones people can't go back to living without — are
convenience layers over things people were already doing. Email over letters, search over
looking things up, maps over finding directions, online shopping over buying things. They
didn't create new needs; they made existing ones frictionless enough that the old way
became unthinkable.

The question: what are the biggest remaining convenience gaps — areas where people spend
significant time or deal with significant friction that don't have good software solutions
yet?

## Research findings (2025-2026)

### Personal finance opacity

Subscription creep (losing track of recurring charges), unexplained payment declines, no
way to verify promised refunds arrived. The information exists but is scattered across
provider portals with no unified view.

### Shared expenses

Irregular group costs beyond splitting a dinner tab — ongoing shared obligations (housing,
utilities, group trips, shared subscriptions) still tracked manually in spreadsheets.
Existing tools (Splitwise etc.) cover the simple case but not the ongoing/irregular one.

### Caregiving coordination

Scheduling, medical updates, cost-sharing for aging parents done via phone calls and
email chains. No purpose-built coordination layer. The problem is inherently
multi-stakeholder and crosses communication, scheduling, and finance.

### Chronic health tracking

Condition-specific symptom/medication/diet correlation tracking done in spreadsheets.
Generic health apps exist but don't support the kind of structured, condition-specific
logging and correlation that people with chronic conditions actually need.

### Customer support tracking

No unified view of "what did I ask, what was promised, did it happen" across providers.
Each company has its own ticket system; the customer has nothing.

### Gig worker taxes

Estimation still manual and error-prone. Existing tax software handles filing but not
the ongoing estimation/categorization/set-aside that gig workers need throughout the year.

### Legacy system integration

Enterprises taping together incompatible tools with no clean integration layer. Not a
consumer problem but a pervasive one.

## Ruled out

Healthcare interfaces were identified as a major gap but ruled out for a solo developer
due to compliance overhead (HIPAA, medical device regulation, liability).

## Pattern

Most gaps aren't about flashy new features. They're about systems that should be simple
but are fragmented across providers with no incentive to interoperate. The user's data
exists — it's just scattered, siloed, and inaccessible in aggregate.

## Relation to crescent

These could be built as crescent applications. Not necessarily all as one product, not
necessarily all separate apps — the form follows from what each problem actually needs.
Crescent already has the substrate (HTTP, websocket, SQLite, filesystem) to build any of
these as local-first tools.

No decisions made here about which to pursue or in what form.

## Sources

- Forbes: "20 Real-World Problems Tech Could (And Should) Be Solving" (2025)
- BigIdeasDB: "30 App Ideas That Solve Real Problems (2026): Backed by 1M+ Complaints"
- IT Brew: "Tech friction is ruining our workdays" (2026)
- Forbes: "Fintech Friction: Common UX Pain Points" (2026)
- CIO: "The 8 biggest issues IT faces today"
