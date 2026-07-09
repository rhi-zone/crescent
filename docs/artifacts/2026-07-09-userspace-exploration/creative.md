# Creative tools — exploration

Speculative design exploration. Nothing here is a commitment; it's material for
a design conversation about what "crescent as the entire computer" means for
art/music/video/writing/code/games/livecoding/animation.

## 1. What people actually do

Concrete workflows, not categories:

- **Shader golf / Shadertoy**: paste a fragment shader, see it render live,
  tweak uniforms, share a URL. No project file, no build step — the URL *is*
  the save file.
- **Livecoding music (TidalCycles, Sonic Pi, Strudel)**: edit a pattern
  expression while it plays; the change takes effect on the next cycle
  boundary, not instantly. The *scheduling model* (quantized re-evaluation) is
  the whole interaction.
- **Tracker music (Renoise, LMMS pattern mode, old trackers)**: a grid of
  note/instrument/effect columns, keyboard-driven, no mouse needed. Time is a
  spatial axis you scroll through, not a horizontal timeline you drag clips
  on.
- **Pixel art (Aseprite)**: tiny canvas, palette-locked, onion skinning for
  animation, tile/sprite-sheet export baked into the tool, not a plugin.
- **Fantasy consoles (PICO-8, TIC-80)**: the *constraint* is the product —
  128x128, 16 colors, one file containing code+sprites+sfx+map. People choose
  this over a "real" engine because the box shrinks decision space.
- **Dwitter**: 140 characters of JS driving a canvas frame function. The
  constraint is social/competitive, not technical.
- **Node graphs (Blender shader/geometry nodes, TouchDesigner, vvvv)**: build
  a transformation pipeline by wiring boxes, watch a live preview update
  per-node. People reach for this specifically to *avoid* writing loops/code.
- **Generative art / plotter art**: seed a PRNG, iterate parameters, export
  SVG for a pen plotter — determinism (same seed → same art) is load-bearing,
  not incidental.
- **Collaborative livecoding (algoraves, laptop orchestras)**: multiple
  people editing/executing code against a shared clock, projected for an
  audience who can *see the code change* as the sound changes.
- **Interactive fiction / narrative tools (Twine, Ink)**: branching text
  authored as a graph, played as a state machine, exported as a standalone
  HTML file that runs with no server.
- **Bitmap/vector hybrid design (Figma, Krita)**: real-time multiplayer
  cursors on one canvas — the "runs in the browser, syncs live" expectation
  is now table stakes for design tools, not a differentiator.

## 2. Prior art crescent's philosophy resonates with

- **thi.ng/umbrella**: hundreds of small, independently-versioned TS/JS
  packages, most under 200 lines, composed rather than framework-bound. This
  is the closest existing thing to crescent's "libraries, not tools" stance —
  worth studying its package boundaries directly, not just admiring it from a
  distance.
- **PICO-8 / TIC-80**: a *fantasy console* is a capability boundary made
  literal — fixed memory, fixed palette, fixed input. Crescent's cap-sandbox
  is the same move (bound what's reachable) applied to security instead of
  nostalgia. Worth asking whether a crescent "fantasy console" cap profile
  (fixed canvas size, fixed palette, no network) is a natural preset rather
  than a new product.
- **TidalCycles/Strudel**: pattern algebra (`~`, `.`, cycle-based
  scheduling) is a small composable DSL over time, not a DAW. Crescent
  already has `reactive`/`signals`/`event`/`event_emitter` — none of them
  model *musical time* (cycles, quantized re-evaluation, swing). That's a
  gap, not a redundancy — it's a different primitive (logical/quantized time)
  from what `easing`/`interpolation` give you (continuous parametric time).
- **Sonic Pi**: OSC-driven, live-reloadable Ruby, designed for teaching —
  errors don't crash the performance, they just silence that voice. Failure
  isolation *per pattern/voice* is a design lesson independent of the
  language.
- **Dwitter/Bytebeat**: entire pieces expressed as one pure function of
  `t` (frame or sample count). This is the degenerate/extreme case of
  "capabilities injected, nothing ambient" — a bytebeat function has *zero*
  capabilities, just a number in, a number out. Worth having as a literal
  example of the caps-first philosophy taken to its floor.
- **Blender geometry nodes / vvvv**: node graphs are, structurally, a
  serialization format for function composition with a live-preview
  requirement at every intermediate node. If crescent ever had a node editor,
  it would need to be a *view* over ordinary composed library calls, not a
  parallel execution model — otherwise it becomes exactly the kind of
  "framework code in lib/" the constraints forbid.
- **Twine/Ink**: the artifact *is* the runtime — a Twine export is a single
  HTML file with the story and the player fused. That's precisely the
  `lib/platform/` promise (app = capability-sandboxed bundle) already applied
  to narrative content instead of code.

## 3. What crescent already covers

From the inventory, the *substrate* for creative tools is unusually
complete already:

- **Visual**: canvas (PPM/PGM/BMP + browser), svg, color + color science,
  geometry/geom/geometry_3d, bezier, voronoi, l-system/lindenmayer,
  cellular_automata/automata_2d, noise/noise_gen, wave function collapse,
  particle, physics_2d, tilemap, steering, ecs/entity_component.
- **Time/motion**: easing, interpolation, wavelet/wave.
- **Procedural/generative**: markov, genetic, gradient_descent, simulated_annealing,
  l-system, WFC, noise — a real toy box for generative art already exists
  without anyone building a "generative art library."
- **Audio-adjacent**: dsp, midi (under the automata/sim family, not audio
  proper).
- **Interaction/state**: reactive + signals (two parallel implementations),
  event/event_emitter, behavior_tree, fsm (five parallel implementations),
  expression evaluators.
- **Text/authoring**: markdown, template engines, html builder.
- **Delivery**: `lib/platform/` — sandboxed, cap-dispatched, browser-runnable
  app bundles, which is exactly the "no install, runs in browser" promise
  every fantasy console / Twine / Shadertoy shares.

The raw material for creative coding is arguably crescent's *strongest*
existing area — it's cross-cutting math/sim/visual libraries that just
haven't been pointed at a creative-tool frame yet.

## 4. Gaps and design questions

- **No musical-time primitive.** `easing`/`interpolation` model continuous
  parametric time (0..1 → value). Livecoding needs *logical, quantized,
  re-evaluated* time (cycle N, beat, swing, scheduled-at-boundary
  re-execution). This is a genuine substrate gap, not a naming collision with
  `reactive`/`signals` — those are push/pull data-flow, not a clock model.
  Building it requires deciding what "cycle" means as a cap-injected clock
  (who owns wall-clock time — audio callback? animation frame? a fake
  deterministic clock for tests?).
- **No audio synthesis/playback primitive at all.** `dsp` exists (signal
  processing) but nothing generates or plays sound. Every one of Sonic
  Pi/TidalCycles/trackers/LMMS needs an oscillator + envelope + mixer + output
  device, minimally. This is the single largest hole relative to "creative
  tools" as a facet — DSP without a sound *source* and a sound *sink* is half
  a stack. Whether output is a browser Web Audio cap, a WAV-file cap, or both
  is an open design question (mirrors the "canvas outputs to browser vs PPM
  file" split that already exists).
- **Five FSM implementations, two reactive implementations, two automata
  families** — the inventory itself already flags these as
  unconsolidated. A "creative tools" push should not add a *sixth* animation
  state machine; it should force the consolidation the inventory already
  calls out, driven by an actual use case (sprite animation state, e.g.)
  instead of picking abstractly.
- **Determinism as a cap, not an accident.** Generative art (WFC, l-system,
  noise, particle) plus plotter/export workflows need "same seed in → same
  artifact out" to be *guaranteed*, which means every generative library's
  PRNG must be an injected cap (explicit seed source), never `math.random()`
  reached for ambiently. Worth auditing `noise`/`particle`/`l-system`/`wfc`
  specifically for this — caps-first is a stated hard constraint but
  generative-art code is exactly where "just call math.random" is tempting.
- **Node-graph editors are framework code.** `lib/` explicitly forbids
  generic dispatch/routing layers and framework code. A visual node editor
  for composing library calls (Blender-nodes-style) is *tool*-shaped, which
  the philosophy already has an answer for ("people use tools, not
  libraries") — it would live in `lib/platform/` as an app built *from*
  libraries, not as a new library itself. Worth naming explicitly so nobody
  builds a "graph execution engine" library by mistake when what's wanted is
  an app.
- **Collaborative/shared-canvas is a networking + CRDT question, not a
  creative-tools question.** Figma-style live multiplayer wants conflict
  resolution over shared visual state. Crescent likely has CRDT-adjacent
  primitives elsewhere in the inventory (not confirmed here — would need a
  grep of `docs/inventory.md` before claiming either way) — flagging as an
  open question rather than a gap, since it may already exist under a
  different facet.

## 5. What "crescent-native" would look like

The philosophy's two sharpest edges — capability injection and "same
libraries make many different tools" — cut against the grain of how creative
tools are normally built (usually a monolithic app with ambient access to
GPU/audio/filesystem). A few consequences if taken seriously:

- **A bytebeat/dwitter-style toy is the natural "hello world."** A pure
  function `t -> sample` or `t -> pixel` with literally zero injected caps is
  the smallest possible creative-tool demo and doubles as a caps-first
  teaching example — "here is a creative tool that needs *no* capabilities at
  all, and here is the one that needs exactly `canvas` and nothing else."
- **The fantasy-console constraint becomes a cap *profile*, not a separate
  product.** Instead of building a bespoke PICO-8-alike, a "fantasy console"
  is just `lib/platform/` handed a cap set restricted to (fixed-size canvas,
  fixed palette, no network, no fs) — the same sandbox mechanism that secures
  every other crescent app, reused as a creative constraint instead of a
  security boundary. That reuse is the philosophy's clearest payoff in this
  facet.
- **Livecoding's re-evaluation model wants the sandbox to support hot-swap
  of a running cap-bounded closure**, not just cold-start dispatch. Today's
  `lib/platform/` framing (tarball loader + entrypoints) is unclear on
  whether "replace the running program's next-cycle behavior without
  restarting the sandbox" is in scope — that's a real open question for
  whoever owns platform design, not something to answer by assumption here.
- **"Same libraries, many tools" predicts that a tracker, a livecoding REPL,
  and a node-graph editor should all bottom out in the *same*
  pattern/scheduling primitive**, differing only in their front-end
  (grid UI vs text REPL vs boxes-and-wires), the same way `canvas` backs both
  a paint app and a generative-art export script today. If the musical-time
  primitive above gets built, this is the test of whether it was designed
  right: can a tracker UI and a Tidal-style text REPL both drive it without
  either one needing special support baked into the primitive itself.
