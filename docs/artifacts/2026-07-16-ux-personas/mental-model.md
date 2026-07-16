# Mental Model: Consolidated Persona Analysis

Extracted from nine persona simulations: four generic/role-based (new-user,
returning-user, multi-char-scenario, card-creator) and five tool-specific
(st-migrator, chub-browser, chatgpt-casual, kobold-local,
talemate-narrative).

This is a discovery document. It reports what the personas actually
revealed — including where they contradict each other — not what to build
in response.

---

## 1. What each persona checked first

The single thing each persona reached for before anything else, before
forming any other opinion:

- **new-user** — the import button (plus icon), then whether the file
  picker was a standard OS picker. Everything else was downstream of "did
  my file get in."
- **returning-user** — whether the thread was exactly where they left it.
  Scroll position and no re-onboarding, checked in the first three
  seconds, before a single new message was typed.
- **multi-char-scenario** — "who am I even talking to." Target ambiguity
  was the first friction, before any content was evaluated.
- **card-creator** — the description field. Not the name, not the avatar —
  the field that "matters," where voice gets written.
- **st-migrator** — import *fidelity*, specifically: did the personality
  survive intact, did `{{char}}`/`{{user}}` macros get silently rewritten,
  did the lorebook come through. Checked field by field before ever
  starting a chat.
- **chub-browser** — same import-first instinct, but checked whether the
  PNG metadata parsed without mangling, immediately followed by hunting
  for a way to skip the download-then-import round trip entirely.
- **chatgpt-casual** — whether the home screen was a blank box or a
  catalog. This was clocked as strange before any character was opened:
  "this is not what chatgpt's homepage looks like at all."
- **kobold-local** — the backend connection screen. Local endpoint field,
  whether it auto-detected the loaded model. Character content was
  secondary to confirming their own hardware was actually being used.
- **talemate-narrative** — whether world/scenario and actors were modeled
  as separate structural objects or one prompt blob. Checked by reading
  the UI's panel layout before typing anything.

No two personas checked the same thing first. Casual personas check
continuity or voice; power-user/migrator personas check fidelity and
architecture; the creator checks the writing surface.

---

## 2. Where mental models converge

- **Typing/streaming indicators tied to a specific identity, not a generic
  spinner.** multi-char wants dots under the selected avatar specifically;
  talemate's indicator names which actor is "thinking"; kobold explicitly
  values token-by-token streaming as feeling "alive" versus a blank wait.
  The shared expectation isn't "show progress," it's "show who is
  producing it."
- **Regenerate/swipe as an assumed baseline, not a discovered feature.**
  returning-user, chub-browser, chatgpt-casual, and card-creator (via
  voice-testing) all reach for it without surprise that it exists — it's
  checked for, tapped once to confirm it works, then treated as settled.
- **The PNG-embedded character card as taken-for-granted infrastructure.**
  new-user, st-migrator, chub-browser, kobold-local, and card-creator all
  reference "the standard" card format without ever questioning that it
  should exist — the only question asked is whether *this* app parses it
  correctly, never whether the format itself is right.
- **First message pre-populated from the card, not generated fresh.**
  Noted with mild delight by new-user, expected without comment by
  chub-browser and chatgpt-casual.
- **In-character resilience under a deliberate curveball is the real
  quality bar.** chatgpt-casual throws a kraken reference; card-creator
  throws "I'm actually having a rough day"; kobold-local watches for
  whether a hidden system-prompt wrapper is warping the voice. All three
  are testing the same thing from different angles: does this hold up
  under pressure, or is it a thin skin over generic output.
- **Shared scene-state confirmed by testing, not by being told.**
  multi-char discovers the bard "heard" the bartender conversation only by
  deliberately probing; talemate discovers Tobin overhearing the same way.
  Neither app announces this in the UI. Both personas treat the
  confirmation as validating, and both note that a user who never runs
  this test might wrongly assume siloed conversations.

---

## 3. Where mental models conflict

- **Catalog-first vs. import-first as competing "correct" entry points.**
  chatgpt-casual treats the grid of hundreds of character cards as the
  headline feature, explicitly favorable next to ChatGPT's blank box.
  chub-browser also expects and uses a discovery tab. But st-migrator and
  kobold-local skim past onboarding entirely, hunting for the import
  button, and never mention the catalog at all — for them it's noise
  between them and their own card. card-creator never encounters a
  catalog either; they start from an empty creation form. These aren't
  reconcilable preferences about the same feature — one group's front door
  is the other group's obstacle.
- **Engine visibility.** kobold-local and st-migrator actively hunt for
  sampler settings (min-p, rep penalty, DRY, mirostat), a raw-prompt
  inspector, and template control — for st-migrator, the *absence* of full
  instruct-template rewriting is the one thing keeping them from fully
  switching. Every other persona (new-user, returning-user, multi-char,
  card-creator, chub-browser, chatgpt-casual) never looks for a settings
  page or asks what model is running — the generation engine is invisible
  to them by unanimous non-interest. Same app, and one cohort would call
  hidden sampler controls a dealbreaker while the other wouldn't notice
  they were hidden.
- **Single-target addressing vs. autonomous multi-actor progression.**
  multi-char-scenario is satisfied by a single-select model — tap one
  avatar, that character responds, everyone else stays silent until
  selected — and treats "address the room" as a workaround, not a missing
  mode. talemate-narrative wants more: it explicitly tests whether the
  system will bring in a *second* actor unprompted ("I want to see if
  auto-progress decides HE should react too... nothing happens. it's
  sitting there waiting on me. mild disappointment"). One persona's
  correct design is the other persona's stalled director layer.
- **Remote catalog integration.** chub-browser wants to paste a chub.ai
  link and skip local file handling entirely — the download-then-import
  round trip is flagged as "the annoying part." st-migrator and
  kobold-local show no such expectation; drag-and-drop of a local file is
  simply the correct interaction to them, with no reach for a URL-based
  alternative.

---

## 4. The gap each persona's home platform leaves open

- **st-migrator (home: SillyTavern).** ST supplies full control over the
  instruct/story-string template, rewritable from scratch. This app
  supplies presets with a raw-prompt *viewer* but, as far as the persona
  can tell, no from-scratch template rewrite — noted as "the one thing
  that makes me go 'hm,'" not disqualifying, but the reason a full
  migration doesn't happen in one session.
- **chub-browser (home: chub.ai catalog).** chub.ai lets them browse and
  grab cards directly. This app's import only accepts local files — no
  paste-a-link path from chub.ai itself — so the discovery convenience of
  the home platform doesn't carry over; the persona is left doing "the
  download-then-import shuffle" every time.
- **chatgpt-casual (home: ChatGPT).** ChatGPT's strength, per this
  persona's own account, is not in question here — it is not being tested
  for memory or persistence in this single session at all. What the
  persona names, repeatedly and specifically, is that ChatGPT roleplay
  "eventually hits this wall where it goes back to being The Assistant" —
  breaks character, apologizes, summarizes "like it's writing meeting
  notes." The gap this app fills is sustained in-character behavior under
  a direct test (the kraken line), not persistence. The persona's own
  words: "the stiffness you'd been feeling on the other app wasn't you
  doing it wrong the whole time" — a character problem, not a memory one.
- **kobold-local (home: koboldcpp + assorted local frontends).** Local
  frontends are trusted for raw, unwrapped model output but often fumble
  advanced samplers or hide behind "auto." This app clears the min-p and
  mirostat bar the persona uses as a filter, but leaves three things
  unresolved by session end: no DRY sampling found, no confirmation that
  a settings change actually took effect (no toast, unclear if it's live),
  and no confirmation of per-character vs. global presets.
- **talemate-narrative (home: Talemate).** The persona arrives on the
  pitch "better memory management" than Talemate and confirms structural
  world/actor separation and a relationship-graph field exist. What isn't
  confirmed: whether the auto-progress "director" can *ever* initiate a
  second actor's turn without an explicit direct-mode nudge, and whether
  world-state grounding (the guild/tariff tension) survives once a
  transcript is long enough to require summarization — both are named as
  open, unresolved by this session, requiring a longer sitting to test.
- **new-user, returning-user, multi-char-scenario, card-creator.** No
  named home platform to compare against — these four are evaluating the
  app on its own terms, not against an incumbent. This absence is itself
  informative: the gap-naming behavior only appears in personas who
  arrive with an existing tool's habits already formed.

---

## 5. Latent expectations

Assumptions personas acted on without ever asking for them — the
strongest signal, because nobody had to request these; their absence
would only surface as silent disappointment or misuse.

- **Structural fields should be mechanically real, not decorative.**
  talemate's sharpest observation: "so many of these apps have a field
  that LOOKS structural but is secretly just string-interpolated into a
  system prompt... I want it to matter mechanically." The persona doesn't
  ask whether this is true — it tests for it, unprompted, as if
  mechanical realism were owed.
- **Macros and markup should survive import unmangled and un-"helped."**
  st-migrator explicitly checks that `{{char}}`/`{{user}}` rendered as raw
  text rather than being silently converted, calling out that other apps
  "helpfully" rewrite this and break greetings. Nobody else even mentions
  macros — this is a narrow but load-bearing assumption for the one
  persona who'd notice its absence.
- **A lorebook/world-info attachment should be wired into generation, not
  just cosmetically present.** st-migrator confirms this by deliberately
  triggering a keyword rather than trusting that the entries "being there"
  means they're used.
- **Shared scene coherence is assumed correct, not exceptional.** Both
  multi-char and talemate treat confirmed cross-character awareness as
  the system working as it *should*, not as a bonus — disappointment
  (talemate) or filed-away uncertainty (multi-char) is the reaction when
  it's ambiguous, not gratitude when it's present.
- **No persona, across all nine, asks about cost, usage caps, or rate
  limits.** Total absence, casual and power-user personas alike.
- **No persona expects to be told which model is running unless they
  already came from a tooling context that makes this visible (kobold,
  st).** For the other seven, not asking isn't a gap they'd notice — it's
  an assumption the engine doesn't matter.
- **Cross-app export format fragmentation is assumed, not expected to be
  solved.** card-creator halts specifically because they assume JSON and
  PNG-embedded aren't always mutually compatible across apps "even when
  both call it a 'character card'" — nobody in any persona assumes a
  single unified standard exists; the fragmentation itself is the baseline
  expectation.
