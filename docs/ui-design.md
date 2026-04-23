# UI Design Principles

Learned from building the ccv2 app. Applies to all platform app frontends.

## Layout shift is always wrong

Any UI change that moves existing content (makes text jump, repositions buttons, shifts
the message list) is a bug. Never accept it; never mask it with a CSS transition.

**The fix is always structural**: content that expands/collapses must not participate in
document flow. Use `position: absolute` or `position: fixed` overlays. Panels that
appear on demand float over existing content — they do not push it around.

Examples:
- Author's note panel: `position: absolute; bottom: 100%` — floats above the bar
- Modals: already overlays, correct
- Dropdowns, tooltips, popovers: always absolute

Never use `max-height` transitions as a workaround for layout shift. They delay the
shift; they do not eliminate it.

## Truncating error messages is always wrong

Error text must be fully visible. Never use `text-overflow: ellipsis` or
`white-space: nowrap` on error/status messages. Use `word-break: break-word` so long
URLs and technical strings wrap rather than clip.

The user cannot act on an error they can't read.

## Position-absolute over content is always wrong

Action buttons (Edit, Delete, etc.) that float over message text via `position: absolute`
overlap and obscure the content. Put them in a footer row that is part of document flow,
controlled by CSS `:hover` on the parent. No JS required.

## Too many buttons is a design failure

Every button added to the input area increases visual noise and cognitive load. Before
adding a button, ask: does this need to always be visible? Can it live in a panel,
overflow menu, or keyboard shortcut instead?

Current input area has ~10 buttons (Send, Continue, Impersonate, Export, Settings,
Lorebook, World Info, Card Edit, Regex, Group). This needs a design pass:
- Primary actions (Send) prominent
- Secondary actions (Continue, Impersonate) nearby but secondary
- Everything else behind a toolbar row or `⋯` overflow menu

## Identical UI for different states is always wrong

Buttons with toggle state (expanded/collapsed, active/inactive) must have a visually
distinct active state. Don't make the user click to discover the current state.

CSS class-based approach: `.toggle--active { background: var(--accent); }`.

## Lorebook and World Info UX

Both inject keyword-matched context. Lorebook is per-card; World Info is global.
Mechanically identical, different scope. Long term: consider merging into one panel
with a scope selector rather than two separate UI surfaces. The cognitive overhead of
two separate concepts with identical mechanics is not justified.
