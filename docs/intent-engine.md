# Intent Engine

Captures a design conversation from 2026-07-09. This is a lens on why the
crescent ecosystem matters, not a restatement of crescent's purpose — see the
scope note at the end.

## The problem

Current computer interaction sucks. Everywhere. Changing a setting is hard.
Saving a webpage so you can find it again is hard. Editing a photo takes too
many steps. Why does anyone have issues using a computer, at all?

The problem is friction, and it isn't localized to one bad app or one bad
workflow — it's everywhere. Every single thing you do on a computer is harder
than it should be. The gap between "I want this" and "it's done" is filled
with steps that aren't about what you're trying to do.

## The framing: intent engine

An intent engine is a system that makes the path from "I want to do this" to
actually doing it as direct, obvious, and simple to find as possible. That's
the target to design toward.

## LLMs are a lossy channel

The obvious move today is to point an LLM at the problem: describe your
intent in natural language, let the model figure out the steps. This is
inherently lossy. Every round-trip through natural language loses structure,
precision, intent. The LLM is a lossy channel — that's not a criticism of any
particular model, it's a property of the channel itself.

The current AI tool approach (Cursor and similar) is wrong not because the
implementations are bad, but because the architecture puts the lossy channel
as the *entire path*. Every action goes through the lossy stage, so every
action inherits the lossy stage's error rate and ambiguity.

The fix isn't a better LLM. It's minimizing how much of the path goes
through the lossy channel at all. Direct paths come first: typed
composition, cap-gated actions, structured UI — anything that lets intent
become action without a natural-language round-trip. When the lossy channel
*is* needed, it should operate on the typed, verified, cap-bounded substrate
that already exists. It picks from a structured space, not an open-ended
one — narrowing what the model has to get right, rather than asking it to
freehand the whole path.

## Lightshot

The concrete example: Lightshot, a screenshot tool, is the favorite image
editor here. Not Photoshop, not Krita. One hotkey to start, select, annotate,
ctrl+c or ctrl+s, done. It deleted all the steps that weren't about what you
were trying to do. That's the feel the whole system should have — not just
for screenshots, for everything.

## How batteries-included connects

This is where the ecosystem strategy earns its keep. Every typed, composable
library is one more thing the lossy channel doesn't have to hallucinate.
Ecosystem breadth isn't just convenience for library authors — it's what
makes the intent engine work. The more of the path is covered by direct,
typed, cap-gated composition, the less of the path has to pass through a
channel that loses information every time it's used.

## Scope note

This is not a reframing of crescent's purpose. Crescent doesn't have a
single goal. The intent engine property is one lens on why the ecosystem
matters, but the OS-in-Lua design, batteries-included scope, zero-dependency
constraint, and cap model all have independent standing on their own terms.
"Intent engine" is a consequence of building crescent well — not the reason
crescent is being built.
