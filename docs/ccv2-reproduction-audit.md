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
| 1 | **No "New Card" entry point anywhere** in the ccv2 app. Only path to having a card is loading an already-installed app that has one baked in. | O1, O3, S4, G4 | Top-level affordance with a verb-first label that opens a blank editor. Reachable in ≤1 click from the chat view. |
| 2 | **Card header is a barren node.** Name + avatar display, zero outgoing affordances. | G1, G2 | Card header becomes the primary navigation hub for card-scoped operations: edit, fork, export. |
| 3 | **10-button input row mixing three affordance types.** Send/Continue/Impersonate (action), Export (export), Settings/Card Lorebook/My Lorebooks/Card Editor/Regex/Group (navigation into editors) — all rendered identically. ~5× over Miller's 7. | S1, S3, T1, T3 | Split into semantic groups: primary action (Send), composition (Continue, Impersonate), navigation (moved off the input row entirely). |
| 4 | **Card Editor and Card Lorebook as separate top-level buttons**, both editing the same object (the loaded card). | S5, G3, G6 | One card surface with tabs (Identity, Lorebook, Greetings, Regex); one entry point. |
| 5 | **`btn-card-edit` labeled "Card Editor"**: the only creation-adjacent affordance in the UI, but its label reads as *edit the current card*, not *make a new one*. | O3, T2 | Creation affordance is a sibling with its own verb label — not a mode inside the editor. |
| 6 | **No message-level "fork card from here" affordance.** The moment a user likes a character's reply is the exact moment to offer creation, and there's no edge. | G2, G4 | Message action menu gains a "use this as card first-message / example / greeting" affordance. |
| 7 | **Author's Note bar is permanently present.** Data-entry affordance for card runtime context competing for top-level attention. | S1, T4 | Collapse into the card surface; no persistent bar. |
| 8 | **Regex Scripts as top-level sibling to card.** Card-scoped state treated as a distinct top-level object. | S1, G3 | Regex lives inside the card surface, as a tab alongside Lorebook. If user-scoped regex exists separately, it goes under a "My …" surface parallel to My Lorebooks. |
| 9 | **Reset-to-Original has no confirmation.** Destructive affordance with no guardrail. | G5 | Confirm dialog stating exactly what is lost, or make the action undoable. |
| 10 | **Import accepts PNG/JSON but has no "Start from blank" option.** Import is the only card-introduction path and it assumes pre-existing data. | O1, G4 | "Blank card" as a first-class option on the import surface, same weight as "Import PNG" / "Import JSON". |

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
