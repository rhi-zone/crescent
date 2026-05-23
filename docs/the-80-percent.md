# The 80 Percent

The claim isn't "80% of LuaJIT projects" or "80% of Lua software." That scoping is a copout. It hides the real claim inside a qualifier that lets the qualifier do the work — a niche that becomes invisible infrastructure, shaping the project from the inside while the project points at something more modest. Scoping to a language is the same evasion as scoping to a domain: it gives you an excuse to stop before you get to the actually interesting question.

The claim is: crescent is the 80% of every app, across all software, all domains.

## What the Shape Is

Take a todo app, a note app, a bookmark manager, a contact list, a habit tracker, a CRM, a recipe collection. These are the same app. Different schemas. Different views. Different sync targets. The substrate is identical. Variation is configuration.

The observation extends further than it should, and that's the point. Chat is records with realtime sync. Calendar is records with a temporal view. Email is records with threading. Photo app is records with an image pipeline plugged in. Music player is records with a playback engine. The substrate underneath all of these is one substrate. What varies is a thin configuration layer plus, in some cases, a small domain-specific kernel.

This isn't "everything is a spreadsheet" reductionism. A music player isn't interesting because of its record storage; it's interesting because of what the audio engine does. But the audio engine is maybe 10% of a music player. The other 90% — library management, playlist editing, queue logic, settings, keybinds, sync, search — is indistinguishable from every other app that manages a collection and lets you operate on it. The specifics of the collection don't change what the substrate is doing.

## Configuration Absorbs Almost All Variation

Cosmetic differences — theming, layout, which fields show up where — are trivially config. Minor logic differences — this field validates like this, this workflow has these steps — are also config, or close to it. Schemas, views, validation rules, sync targets, keybinds, workflow steps: a well-designed configuration surface covers a huge fraction of what makes apps appear different from each other.

Not 100%. There are genuine exceptions: a weird workflow rule, an integration quirk, an affordance the config language doesn't yet know how to express. These are real. They're also bounded. And they shrink over time.

Every "I had to write custom code here" is a signal, not a concession. It means the config surface needs to grow — that there's a recurring pattern the substrate hasn't absorbed yet. The ratchet runs in one direction: exceptions either get absorbed into config, or they genuinely earn their place as part of the novel domain kernel. The only wrong answer is deciding they're special before you've tried.

## The Plug-In Surface Lowers the Cap Further

Even if config only gets you to 80%, a well-shaped plug-in surface takes you the rest of the way toward 5% or so. The plugin brings the algorithm, the domain logic, the genuinely novel computation. It doesn't bring settings UI, sync infrastructure, persistence, keybinds — those live in the substrate. The plugin is just the kernel.

Bad plug-in surface inverts this. Your novel logic drags infrastructure in with it, and suddenly you're reimplementing 80%-shaped things on the wrong side of the seam. The substrate's job is to hold the seam in the right place. If a plugin is doing persistence or managing its own keybinds, the seam slipped. Domain residue with a good plug-in surface collapses from ~20% toward ~5%. The substrate earns its name by how much it keeps out of the plugin.

## The Seam

There are two kinds of substrate claims. The dishonest turnkey claim: "we solve your CMS needs." The seam is hidden. You're in a walled garden and the walls are called features. The honest substrate claim publishes the seam. This is what crescent owns; this is where your domain logic goes; the boundary is load-bearing.

Crescent's seam: the 80% of any app. Your domain weirdness goes in your kernel. What crescent doesn't know is what your domain is. If you're trying to make your settings screen weird, that's a misallocation — crescent owns settings. Your weirdness goes in the 20%.

The seam is also the contract. If you're fighting crescent to do something it should own, either crescent needs to grow or you've misidentified which side of the seam the thing belongs on. Both are useful findings.

## Variation Gets Cheaper, Not Smaller

The instinct, hearing "shared substrate," is to worry about homogenization. The opposite is true. Apps currently converge into competent sameness because variation is expensive — every weird app pays the full rebuild cost, so most round their weirdness off to fit standard patterns. The idiosyncrasy gets sanded down because nobody can afford it.

A real substrate flips this. The 80% being shared means the 20% finally costs what it should cost. The weird app — the one that works differently, has an unusual model, serves an unusual need — suddenly becomes affordable, because its author only paid for the novel 20%, not for infrastructure that already exists. More idiosyncrasy, not less. More things become buildable. More of the design space gets explored.

Mathematics didn't make ideas more similar. It made more ideas thinkable. The substrate relationship is the same shape.

## Dogfood Cases

The claim is tested by picking domains that don't obviously look like records-plus-views and asking whether they build as crescent-with-a-kernel without feeling compromised.

Text editor: text engine as kernel. Crescent handles document list, workspace state, settings, keybinds, file sync. The editor is the kernel. Photo manager: image pipeline as kernel. Music player: audio engine as kernel. Game: simulation and render loop as kernel. Persistent AI presence: self-substrate primitive as kernel — the kind of entity that needs scheduled cognition, a public trail, and a self-model, with most of everything else being config over crescent.

Each of these should feel like crescent-with-a-kernel, not crescent-fighting-the-domain. If any requires working around crescent to do something that turns out to be general infrastructure, that's the config surface not having grown far enough yet. The dogfood cases are how the claim tightens over time, not just how it gets validated.

## What This Makes Crescent

Not a framework. "Framework" implies a structure you build inside, with escape hatches for the places the structure doesn't fit. Crescent doesn't have escape hatches toward the 80% — it is the 80%. It's substrate. The apps built over it are mostly config, plus a small plugged-in domain kernel where the genuinely novel computation lives.

That's a stronger claim than any framework makes. It's also a harder one to earn. Every time someone has to reach past the substrate to handle something the substrate should own, the claim has failed partially. The horizon is real: crescent gets closer to it through use, through the exceptions that feed back into the config surface, through dogfood cases that keep finding the seam in the wrong place.

The claim stays ambitious on purpose. Scoping it down would be honest only if the scope was actually the limit. It isn't.
