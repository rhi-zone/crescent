# Roadmap

Crescent's coverage of "the entire surface area of software" gets built by
dogfooding, not by mapping the space in advance. This document is the seed of
that plan — what the strategy is, why it's tractable, and what's still open.

## Strategy: real apps drive library coverage

Build real, useful example apps in the categories people most commonly need.
"Real" and "useful" are load-bearing — the apps should maximize actual
utility, products people want to use, not throwaway exercises kept alive only
to justify a library underneath. A demo app can be faked; a real one can't,
and it's the can't-fake property that does the work below.

Each app pays off twice:

1. **Forces libraries into existence.** Every gap hit while building the app
   — no HTTP client, no session storage, no whatever — becomes a library,
   because the app can't ship without it. This is how the roadmap for `lib/`
   gets generated: by contact with a real requirement, not by guessing what
   might be needed.
2. **Serves as a template that lowers the cost of building similar things.**
   The finished app isn't just a consumer of the libraries it forced into
   existence — it's a fork point. Someone who needs "that kind of app" forks
   the example and writes the correction terms specific to their case,
   instead of asking an AI to generate the whole thing (substrate, ceremony,
   and all) from scratch.

Both effects compound: better libraries make the next app cheaper to build,
and each app raises the floor for whatever gets forked from it next.

## Which apps

Open question — needs actual thought before committing to a list. The
categories should be picked by asking what's most commonly vibe-coded /
reached for as a "quick app" today (todo apps, note apps, bookmark managers,
trackers, small CRMs, and the like are candidates per `the-80-percent.md`,
but the actual roadmap list is TBD, not decided here).

## Relation to the Jevons thesis

This strategy is a direct instance of the substrate lever described in
[Jevons Paradox and Substrates](https://rhi.zone/essays/jevons-paradox-and-substrates):
an agent decomposes a task into subagents when the task "looks big," and what
makes it look big is usually encoding overhead, not the actual novel logic.
Libraries reduce that overhead for anyone building on crescent; the example
apps reduce it further by covering common use cases end-to-end, so the
starting point for a new app is a working one, not an empty one. No abstract
taxonomy of "software's surface area" is needed — the coverage hierarchy
emerges from use.
