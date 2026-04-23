# UI Design Principles

General laws for all platform app frontends. Specific applications of these
laws (and decisions about concrete ccv2 UI) live in the relevant per-app
design docs — this file is the pattern, not the instance.

## Layout shift is always wrong

Any UI change that moves existing content (text jumps, buttons reposition,
message list shifts) is a bug. Never accept it; never mask it with a CSS
transition.

**The fix is always structural**: content that expands/collapses must not
participate in document flow. Use `position: absolute` or `position: fixed`
overlays. Panels that appear on demand float over existing content — they do
not push it around.

`max-height` transitions delay layout shift; they do not eliminate it. Delay is
not a fix.

## Truncating error messages is always wrong

Error text must be fully visible. Never use `text-overflow: ellipsis` or
`white-space: nowrap` on error or status messages. Use `word-break: break-word`
so long URLs and technical strings wrap rather than clip.

The user cannot act on an error they cannot read.

## `position: absolute` over content is always wrong

Action buttons (Edit, Delete, etc.) that float over content via
`position: absolute` overlap and obscure it. Put them in a footer row in
document flow, controlled by CSS `:hover` on the parent. No JS required for
show/hide.

## Identical UI for different states is always wrong

Buttons with toggle state (expanded/collapsed, active/inactive) must have a
visually distinct active state. Don't make the user click to discover the
current state.

CSS class-based approach: `.toggle--active { background: var(--accent); }`.

## Button count is a design budget

Every button in a persistent toolbar spends cognitive load. Before adding one,
ask: does this need to always be visible? Can it live in a panel, overflow
menu, or keyboard shortcut instead?

Primary actions prominent. Secondary actions nearby but distinct. Everything
else behind a toolbar row, overflow menu, or shortcut. When the count passes
the threshold where the toolbar feels like "a wall of buttons", it already did
— redesign, don't keep adding.

## Names should carry scope

When two features have the same mechanism but different scope (e.g. per-object
vs per-user), the names must make scope obvious ("Card Lorebook" vs "My
Lorebook", not "Lorebook" vs "World Info"). Scope that the user has to infer
from context is cognitive overhead the UI is charging them.
