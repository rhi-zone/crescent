# Games & entertainment as a crescent facet

Exploratory. Nothing here is a commitment — it's mapping the space against
what crescent already has, to find where a crescent-native version would
actually differ from existing tools instead of just re-skinning them.

## What people actually do

- Boot a fantasy console, type code into the built-in editor, hit run,
  iterate in seconds (PICO-8, TIC-80).
- Drag tiles onto a grid, wire up collision, playtest inline (Tiled +
  a hand-rolled loop, or LÖVE + a level editor someone built).
- Open the Geometry Dash editor, place blocks on a timeline synced to a
  song, hear the beat while placing, publish to a level browser other
  players load and rate.
- Write branching dialogue in Twine's node graph, or Ren'Py's script
  format, export to something playable in a browser tab.
- Drop a `.gb`/`.nes`/`.snd` ROM into RetroArch, save-state before a hard
  section, load-state after dying, rewind a few frames.
- Install a Garry's Mod addon from the Workshop, spawn props, mess with
  physics constraints live, no code required.
- Play osu!/StepMania: chart is a timestamped list of hits, input timing
  is compared against it in real time, judged and scored.
- Record a replay (input log + seed, not a video) and upload it so others
  can watch the run deterministically reproduce.
- Scrub a podcast at 2x, jump chapters, the player remembers position
  per-episode across sessions.
- Queue an album in foobar2000/Winamp, apply a DSP chain (EQ, crossfade),
  browse by tag-derived views instead of folders.

## Prior art, categorized by what it actually constrains

- **Fantasy consoles** (PICO-8, TIC-80, Pyxel): the constraint *is* the
  product — fixed resolution, fixed palette, fixed memory, fixed
  instruction budget. This forces small scope and gives every cart a
  shared aesthetic. The constraint is load-bearing, not incidental.
- **Frameworks** (LÖVE, raylib): no constraint, just a clean 2D API
  (draw, update, input, audio) over a native runtime. You bring your own
  editor, your own asset pipeline, your own everything else.
- **Engines with editors** (Godot, Unity, RPG Maker): scene graph +
  inspector + asset import + build pipeline, bundled as one GUI app.
  RPG Maker further constrains to one genre and ships the constraint as
  templated content (tilesets, battle systems).
- **Platforms with embedded creation + distribution** (Roblox,
  Geometry Dash editor, S&Box): the editor lives *inside* the game
  clients play, and publishing is a button, not a build step. This is
  the one crescent's "tools not libraries" framing echoes most directly.
- **Narrative-specific** (Twine, Ren'Py, Bitsy): the whole tool is a
  domain-specific editor for one shape of content (branching text,
  VN script, tiny explorable rooms). Minimal engine, maximal
  authoring ergonomics for that one shape.
- **Emulation** (MAME, RetroArch, higan): the hard problem is cycle-
  accurate reproduction of hardware nobody documented well, plus a
  save-state/rewind layer that has to snapshot the *entire* emulated
  machine state, not just game-level data.
- **Media players** (VLC, mpv, Kodi, foobar2000, Winamp): decode +
  render + scrub + queue + library metadata. Kodi/foobar add a library
  layer (tags, views, plugins) on top of raw playback.

## What crescent already has

Substantial simulation/authoring substrate, almost no presentation or
distribution substrate:

- **Simulation**: `physics_2d` (semi-implicit Euler, AABB/circle, joints),
  `ecs` (SQLite-backed) + `entity_component` (in-memory, parallel),
  `steering` (Reynolds behaviors), `particle`, `behavior_tree`,
  `minimax`+MCTS, `genetic`, cellular automata, l-system, markov chain,
  wave function collapse, `astar`, `kdtree`/`quadtree`/`spatial_hash`.
- **Authoring primitives**: `tilemap`, `canvas` (PPM/PGM/BMP, no live
  frame buffer to a screen — browser side that's `lib/platform`'s DOM
  bridge), `svg`, `color`, `geom`/`geometry_3d`, `bezier`, `easing`,
  `noise`/`noise_gen`, `voronoi`.
- **Data**: `midi` (Standard MIDI File parse/encode — notes and timing,
  not sound), `dsp`, `wavelet`/`wave`.
- **Distribution-adjacent**: `lib/platform/` is the app runner (tarball
  loader, sandboxed entrypoints, cap dispatch, daemon) that Scribble apps
  and the library/system_dashboard apps already run on.

## Gaps, named as substrate, not results

- **No audio decode or playback path.** `midi` gets you note data; there
  is no `codec/wav`, no `codec/ogg`, no way to get PCM samples into a
  speaker. In the browser this is a `<audio>`/WebAudio cap crescent
  hasn't defined yet (`opts.audio_ctx` injected, per caps-first rule);
  the pure-Lua tier would be a WAV/PCM codec with no playback (playback
  is inherently host I/O, same shape as `fs`/`process`). Rhythm games
  (osu!, StepMania) are unbuildable in crescent today for this reason
  alone — chart-timing math is trivial, getting sound out is not.
- **No video decode/playback.** Same shape of gap, larger scope (VLC/mpv
  territory). Likely out of scope for "zero-dependency, pure Lua
  baseline" — video codecs are not something you hand-roll — but worth
  naming explicitly rather than silently absent, since "media playback"
  was named in scope.
- **No deterministic replay/input-recording primitive.** osu! replays,
  TAS tooling, and RetroArch rewind all rest on "record inputs + seed,
  replay against deterministic sim." Crescent has `rand` (presumably
  seedable — worth confirming) and enough sim libraries that a replay
  format is close, but there's no `lib/replay/` that says "here is the
  canonical way to log a frame of input, snapshot/diff sim state, and
  play it back." This is a real substrate gap, not a missing feature of
  any one library — it's a cross-cutting concern like `codec` or
  `observer`.
- **No save-state / serialization-for-sim primitive.** Emulation and
  "load-state after dying" both need "snapshot arbitrary sim state,
  restore it." `lib/persistent/` and `lib/kv_store/` exist for data
  structures; nothing targets "serialize an ECS world."
- **No leaderboard/scoreboard service shape.** This is arguably not a
  library problem — it's a backend + auth problem (crescent has `http`,
  `sqlite`, OAuth). A `lib/leaderboard/` would mostly be schema +
  query_builder glue, likely thin enough it doesn't need to exist as its
  own library.
- **No multiplayer transport beyond raw primitives.** `websocket`,
  `net`, `wire` framing exist; there's no rollback-netcode or
  client-prediction library. That's a legitimately hard, narrow thing
  (GGPO-style) — flagging it as a gap, not proposing crescent build it.

## The LÖVE question

LÖVE gives you a clean imperative API (`love.draw`, `love.update`,
`love.keypressed`) over a compiled native runtime with real audio/video/
window management, and you bring your own everything-else. Crescent
inverts that: rich everything-else (sim, data structures, ML, codecs)
and a *browser* runtime instead of a native window — which is exactly
where the audio/video gap above bites, because the browser already has
audio/video decode built in and crescent hasn't defined the cap to reach
it yet. The differentiator isn't "better game loop" (LÖVE's is fine) —
it's that a crescent game and a crescent DSP tool and a crescent data
dashboard would share `ecs`, `canvas`, `color`, `geom` instead of each
tool reinventing a rect-intersection function. That's the "same
libraries make a game editor and a music tool" framing from the Scribble
fold-in, and it's real: `particle`+`color`+`easing` already serve a
game's VFX and a generative-art tool identically.

## The fantasy-console question

Fantasy consoles' constraint (fixed resolution/palette/token budget) is
a *design* choice for a specific aesthetic and a specific "small enough
to finish" discipline — it is not a technical limitation crescent
inherits by being browser-first or zero-dependency. Crescent could ship
a fantasy-console-shaped *app* (fixed canvas size, curated subset of
libraries, a cart format) on top of `lib/platform/`, the way Scribble
apps already are opinionated surfaces over the same libraries. But that
would be one app among many, not a property of crescent itself — nothing
here forces the constraint the way PICO-8's whole identity is the
constraint. Worth being explicit that this is a possible *app*, not a
platform-level decision, since the two read very differently in scope.

## Browser-first as the actual constraint

The real constraint isn't rendering (canvas/SVG cover 2D fine) — it's
that "tools work 100% in browser without backend" pushes every I/O
surface through a capability the sandbox defines, and audio/video are
I/O. A crescent rhythm game or media player is gated on `lib/platform`
defining an audio cap (WebAudio-backed) the same deliberate way it
presumably defines `fs`/`net` caps today — worth checking
`lib/platform/apps/*/`'s existing cap surface before assuming this is
greenfield.

## What a crescent-native version might look like

Speculative, not a plan:

- A **level/chart editor app** (Geometry-Dash-shaped: timeline synced to
  MIDI/audio, block placement) is close to buildable today except for
  the audio gap — `tilemap` + `midi` + `canvas` cover placement and
  timing data, playback is the missing piece.
- A **VN/branching-narrative tool** (Twine-shaped) is *already*
  buildable with existing text/graph substrate (no obvious gap) and
  would share nothing-new with games beyond the app shell.
- A **replay-driven puzzle/sandbox** (deterministic sim + shareable
  input log) is the case that most directly needs the named
  replay/save-state substrate — and would be the strongest proof that
  "same libraries, different app" works, since it's ecs + astar +
  cellular-automata territory crescent already owns.
