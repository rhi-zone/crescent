# ccv2 Reproduction Audit

Applied `docs/ui-design.md` rules (and the underlying lens docs) to the
ccv2 app at `lib/platform/apps/charactercardv2/` to find places where the
consumption-to-creation loop is broken. "Reproduction" here means: does a
crescent-format CCv2 card in the world cause more crescent-format CCv2 cards
to come into existence? The target is R > 1.

The rule references (T*, S*, O*, G*) are to sections in `docs/ui-design.md`.

## The reproduction paths we care about

A new crescent-format card comes into existence when:

1. **Import converts an existing CCv2 card.** A user drops an ST/Chub card
   into crescent and the import pipeline writes crescent extensions into
   it. The card they now have is crescent-format. When they re-share, the
   format propagates. The reservoir is the hundreds of thousands of cards
   already in the wild; crescent's job is to be the path of least
   resistance for editing/playing any of them.
2. **Creation via dedicated apps.** Users make new cards using purpose-built
   creation apps (CYOA builders, freeform editors, minimalist tools, etc.).
   The platform pattern: many competing creation apps, not one
   omnibus card-builder. Each produces crescent-format output by default.

Paths we explicitly do not rely on:
- LLM-generating entire cards from prompts — quality is poor and gives the
  user no agency. LLM assistance lives inside dedicated UI (enhance-this
  button, CYOA filler), not as the creation path itself.
- Cards spawning cards at runtime via embedded LLM — this is the "RPG card"
  pattern, already done less well elsewhere; dedicated UI beats it.

## Reproduction-gap audit, ranked

| # | UX element | Rules violated | Fix shape |
|---|------------|----------------|-----------|
| ~~1~~ | ~~**No "New Card" entry point anywhere**~~ in the ccv2 app. Only path to having a card is loading an already-installed app that has one baked in. | O1, O3, S4, G4 | ~~"New Card" button in card header; `POST /api/new-card` returns blank CCv2 PNG for download/import. 113bc18.~~ |
| ~~2~~ | ~~**Card header is a barren node.**~~ Name + avatar display, zero outgoing affordances. | G1, G2 | ~~Card header refactored: top row (avatar + name + New Card), fixed-height actions footer (Edit, Export) revealed on :hover via opacity toggle. 113bc18.~~ |
| ~~3~~ | ~~**10-button input row mixing three affordance types.**~~ Navigation buttons (Lorebook, Regex, Card Editor) now open the tabbed card surface — they no longer navigate to separate overlays. Residual: Send/Continue/Impersonate/Export/Settings/My Lorebooks/Card Editor/Group still on one row (~8 buttons). Full toolbar redesign (split into action vs navigation groups) is a follow-on pass. | S1, S3, T1, T3 | ~~Navigation moved into card surface (bdf83a6). Residual: toolbar still overcrowded — follow-on pass needed.~~ |
| ~~4~~ | ~~**Card Editor and Card Lorebook as separate top-level buttons.**~~ Both now open the same tabbed panel (Identity / Greetings / Lorebook / Regex). One entry point via card header Edit. | S5, G3, G6 | ~~Tabbed card surface — Identity, Greetings, Lorebook, Regex tabs. bdf83a6.~~ |
| ~~5~~ | ~~**`btn-card-edit` labeled "Card Editor"**: creation-only affordance issue.~~ Moot — New Card exists as a sibling (audit #1). Card Editor button is now one of several ways into the tabbed surface. | O3, T2 | ~~Resolved by #1 (New Card sibling). Card Editor button still present but no longer the only affordance.~~ |
| 6 | **No message-level "fork card from here" affordance.** The moment a user likes a character's reply is the exact moment to offer creation, and there's no edge. | G2, G4 | Message action menu gains a "use this as card first-message / example / greeting" affordance. Requires fork endpoint design. |
| ~~7~~ | ~~**Author's Note bar is permanently present.**~~ Removed from main layout; Author's Note fields now live inline in the Identity tab. | S1, T4 | ~~Moved into Identity tab. bdf83a6.~~ |
| ~~8~~ | ~~**Regex Scripts as top-level sibling to card.**~~ Regex now lives inside the card surface (Regex tab). | S1, G3 | ~~Regex tab in card surface. bdf83a6.~~ |
| ~~9~~  | ~~**Reset-to-Original has no confirmation.**~~ Destructive affordance with no guardrail. | G5 | ~~`window.confirm()` guard before reset fetch call. In flight.~~ |
| 10 | **Import accepts PNG/JSON but has no "Start from blank" option.** Import is the only card-introduction path and it assumes pre-existing data. | O1, G4 | Partially addressed: "New Card" button exists (downloads blank PNG). Still missing: "Blank card" option *on the import surface* itself (library app + ccv2 app import panel). |

## The import path is the dominant reproduction vector

Reproduction via the import path has the highest leverage because:

- The reservoir — hundreds of thousands of existing CCv2 cards — is already
  in the wild.
- Each existing card converts on first use in crescent (import pipeline
  writes crescent extensions into the PNG).
- The user doesn't have to intend to make a crescent card; they just have
  to *use* their existing card in crescent.
- Re-sharing their now-crescent-format card through normal channels
  (Chub, Discord as file, catbox, email, git) preserves the payload if the
  channel preserves iTXt chunks.

The forcing function is the frictionless experience:

- Drag a PNG onto the running crescent instance → it plays immediately.
- Value-add features (multi-book lorebooks, linked lorebooks, a superior
  editor, personas, regex, etc.) are available on existing cards the
  moment they're opened.
- Library integrates adjacent content — itch games, Steam entries, other
  crescent apps — so "my library" becomes the universal place, not a
  character-card silo.

Creation-from-scratch, by contrast, has lower leverage because it competes
with the creator's existing tooling. Import converts users without asking
them to change workflow; creation asks for a commitment.

## What's out of scope for this audit

- **Transmission-channel preservation of iTXt chunks** — which of Chub,
  Discord-as-file, catbox, etc. actually preserve our chunks through their
  save/re-serve paths. Needs empirical verification; not a UX question.
- **Server-side registry / share-URL infrastructure** — whatever unfurls
  nicely in chat clients, exposes "play in browser," and links to
  download-PNG. A real question but orthogonal to ccv2-app UX.
- **App/asset versioning and forking** as a platform-level design (linked
  lorebooks being one instance) — tracked separately in `TODO.md`.

## Status

This doc is a living audit. Update as fixes land — struck-through rows
once the violation is resolved, new rows as new failures surface.
