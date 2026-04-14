# Conversation Tree Design

How the card app migrates from a flat message list to a branching conversation tree.

## Problem

The card app (`lib/platform/apps/card/server.lua`) uses a flat model:

```lua
state.messages = { {id, role, content}, ... }      -- ordered list
state.swipes[msg_id] = { items = {{id, content}, ...}, current = N }  -- alternatives
```

This has three problems:

1. **Swipes are disconnected from the message graph.** Swiping to a different
   alternative at message N does not change messages N+1...end. The subtree below
   alternative A stays visible when you switch to alternative B. This is incoherent
   -- the conversation below an alternative was generated in the context of A, not B.

2. **Editing does not branch.** Editing message N overwrites in place. The old content
   and everything generated below it is gone. Users expect editing to fork: the old
   conversation remains accessible, and a new branch starts from the edited version.

3. **No mid-conversation regeneration.** Swiping only works at the last position
   (conceptually). Regenerating message 5 of 20 should preserve messages 6-20 as one
   branch and start a new branch from message 5's parent. The flat model cannot
   represent this.

`lib/conversation/init.lua` already implements a SQLite-backed tree model matching
the schema in `docs/platform-design.md`. The card app needs to adopt it.

## Data Model

### Current (flat)

```lua
state = {
  messages = { {id="m1", role="assistant", content="Hello"}, ... },
  swipes = { ["m1"] = { items={{id="m1",content="Hello"},{id="m2",content="Hi"}}, current=1 } },
  next_id = 2,
}
```

### Target (tree via lib/conversation)

The card app stops managing messages directly and delegates to `lib/conversation`.

```lua
state = {
  card = nil,           -- CardData (unchanged)
  lorebook = nil,       -- NormalizedEntry[] (unchanged)
  user_name = "User",   -- (unchanged)
  conv = nil,           -- lib/conversation db handle
  session_id = nil,     -- active session id (string)
}
```

Each message is a row in `lib/conversation`'s `messages` table:

```
id                 TEXT PRIMARY KEY
session_id         TEXT NOT NULL
parent_id          TEXT (NULL for root)
role               TEXT NOT NULL ('user'|'assistant'|'system')
content            TEXT NOT NULL
created_at         INTEGER NOT NULL
canonical_child_id TEXT (which child was last navigated to)
metadata           TEXT (JSON: model, tokens, timing, etc.)
```

### Key concepts

**Tree, not list.** Every message has a `parent_id`. Siblings are alternative
responses to the same parent (what swipes are today). Children are continuations.

**canonical_child_id.** Each node remembers which child the user last navigated to.
Following `canonical_child_id` from root to leaf reconstructs the "active path" --
the conversation the user currently sees. This is `db:get_canonical_path(session_id)`.

**Swipes are siblings.** If message A has children B and C, then B and C are swipes
of each other. Swiping from B to C calls `db:swipe_to("C")`, which sets A's
`canonical_child_id` to C. The active path now goes through C and C's subtree.

**Editing forks.** Editing message N creates a new child of N's parent with the
edited content. The old message N (and its subtree) remains as an unreachable branch
until you swipe back to it.

**Regenerating forks.** Regenerating message N creates a new sibling of N (same
parent). The new sibling becomes the canonical child. The old N and its subtree
remain.

### Example tree

```
root (greeting: "Hello!")
  |
  +-- user: "Tell me about cats"
  |     |
  |     +-- assistant: "Cats are..." (canonical)
  |     |     |
  |     |     +-- user: "More detail"
  |     |           |
  |     |           +-- assistant: "Specifically..."
  |     |
  |     +-- assistant: "Felines are..." (swipe alternative)
  |           |
  |           +-- user: "What about dogs?"
  |                 |
  |                 +-- assistant: "Dogs are..."
  |
  +-- user: "Tell me about dogs" (edited version of first user msg)
        |
        +-- assistant: "Dogs are great..."
```

Active path (following canonical_child_id): root -> "Tell me about cats" ->
"Cats are..." -> "More detail" -> "Specifically..."

## API Changes

### GET /api/messages

**Before:** returns the flat `state.messages` array.

**After:** returns the active path from `db:get_canonical_path(session_id)`.

```lua
-- Before
local result = {}
for _, msg in ipairs(state.messages) do
  result[#result + 1] = msg_response(state, msg)
end

-- After
local path, err = state.conv:get_canonical_path(state.session_id)
if not path then return json_err(res, 500, err) end
local result = {}
for _, msg in ipairs(path) do
  local siblings, serr = state.conv:get_children(msg.parent_id)
  local sibling_count = siblings and #siblings or 1
  local sibling_index = 0
  if siblings then
    for i, s in ipairs(siblings) do
      if s.id == msg.id then sibling_index = i - 1; break end
    end
  end
  result[#result + 1] = {
    id = msg.id,
    role = msg.role,
    content = msg.content,
    parent_id = msg.parent_id,
    sibling_index = sibling_index,   -- 0-based, replaces swipe_index
    sibling_count = sibling_count,   -- replaces swipe_total
  }
end
return json_ok(res, { messages = result })
```

The response shape changes: `swipe_index` -> `sibling_index`, `swipe_total` ->
`sibling_count`, and `parent_id` is now included.

### POST /api/message

**Before:** appends user message + assistant message to `state.messages`.

**After:** adds user message as child of current leaf, then adds assistant message as
child of the user message.

```lua
-- Find current leaf (last node in canonical path)
local path = state.conv:get_canonical_path(state.session_id)
local leaf_id = path[#path] and path[#path].id or nil

-- Add user message as child of leaf
local user_msg = state.conv:add_message(
  state.session_id, leaf_id, "user", text
)

-- Build context from the path ending at user_msg
-- (get_canonical_path now includes user_msg since add_message updates canonical)
local context = build_context_from_path(state)

local response, err = caps.llm.call(context)
if not response then
  -- Rollback: delete user_msg (not yet implemented in lib/conversation -- see open questions)
  return json_err(res, 502, "LLM error: " .. tostring(err))
end

-- Add assistant message as child of user message
local asst_msg = state.conv:add_message(
  state.session_id, user_msg.id, "assistant", response
)
```

### POST /api/message/stream

Same as POST /api/message but with SSE streaming. No structural change to the tree
operations -- the only difference is when the assistant message is added (after the
stream completes).

### POST /api/continue

**Before:** appends to last assistant message content, or adds a new assistant message.

**After:** same logic, but operates on the leaf of the canonical path.

```lua
local path = state.conv:get_canonical_path(state.session_id)
local leaf = path[#path]
if leaf.role == "assistant" then
  -- Update content in place (lib/conversation needs an update_message method)
  state.conv:update_message(leaf.id, { content = leaf.content .. response })
else
  state.conv:add_message(state.session_id, leaf.id, "assistant", response)
end
```

### POST /api/swipe/new (renamed: POST /api/branch/new)

**Before:** generates a new swipe for a message, adds to swipes table.

**After:** generates a new sibling. The new message has the same parent_id as the
target message. The parent's `canonical_child_id` is updated to the new sibling.

```lua
local msg = state.conv:get_message(msg_id)
if not msg then return json_err(res, 404, "message not found") end

-- Build context up to (but not including) this message
local parent_path = build_path_to(state, msg.parent_id)
local context = build_context_from_msgs(state, parent_path)

local response, err = caps.llm.call(context)
if not response then return json_err(res, 502, err) end

-- Add as sibling (same parent)
local new_msg = state.conv:add_message(
  state.session_id, msg.parent_id, msg.role, response
)
-- add_message already updates parent's canonical_child_id

-- Return sibling info
local siblings = state.conv:get_children(msg.parent_id)
return json_ok(res, {
  id = new_msg.id,
  role = new_msg.role,
  content = new_msg.content,
  sibling_index = #siblings - 1,
  sibling_count = #siblings,
})
```

### GET /api/swipes (renamed: GET /api/siblings)

**Before:** returns swipe alternatives from `state.swipes[msg_id]`.

**After:** returns all children of the message's parent (i.e., all siblings).

```lua
local msg = state.conv:get_message(msg_id)
if not msg then return json_err(res, 404, "message not found") end

local siblings = state.conv:get_children(msg.parent_id)
local result = {}
local current_index = 0
for i, s in ipairs(siblings) do
  result[#result + 1] = { id = s.id, content = s.content, index = i - 1 }
  if s.id == msg_id then current_index = i - 1 end
end
return json_ok(res, { siblings = result, current = current_index })
```

### POST /api/swipe/navigate (new endpoint)

Navigate to an existing sibling without generating a new one. This is what the
frontend calls when the user swipes left/right between existing alternatives.

```lua
-- body: { message_id = "target_sibling_id" }
local ok, err = state.conv:swipe_to(body.message_id)
if not ok then return json_err(res, 400, err) end

-- Return the new active path from this point down
local msg = state.conv:get_message(body.message_id)
return json_ok(res, {
  id = msg.id,
  role = msg.role,
  content = msg.content,
  -- The frontend should reload messages below this point
  reload_below = true,
})
```

The `reload_below = true` flag tells the frontend that everything below this message
has changed (different subtree). The frontend should re-fetch the full path via
GET /api/messages, or the API could return the new sub-path.

### POST /api/message/edit

**Before:** updates message content in place.

**After:** creates a new sibling with the edited content. The old message and its
subtree are preserved as an alternative branch.

```lua
local msg = state.conv:get_message(msg_id)
if not msg then return json_err(res, 404, "message not found") end

-- Create edited version as a new sibling (same parent, same role)
local edited = state.conv:add_message(
  state.session_id, msg.parent_id, msg.role, new_content
)
-- add_message updates parent's canonical_child_id to the new message

return json_ok(res, {
  id = edited.id,
  role = edited.role,
  content = edited.content,
  -- Everything below this message is now empty (new branch, no children yet)
  reload_below = true,
})
```

After an edit, the messages below the edited message disappear (the new branch has no
children yet). The frontend should remove them and allow the user to continue the
conversation. The old branch is still accessible by swiping back.

### POST /api/message/delete

**Before:** truncates `state.messages` from the target onward.

**After:** This needs careful design. Options:

- **Delete subtree:** remove the message and all its descendants. The parent's
  `canonical_child_id` switches to a surviving sibling (or nil).
- **Prune path:** delete from this message to the current leaf, preserving sibling
  branches.
- **Soft delete:** mark as deleted, hide from UI, but keep in tree for undo.

Recommendation: **delete subtree** is the simplest and matches user expectation ("I
don't want this branch"). The `lib/conversation` module needs a `delete_subtree`
method.

```lua
-- New method needed in lib/conversation:
db_mt.delete_subtree = function(self, message_id)
  -- Recursive CTE to find all descendants, delete them, then delete the message.
  -- Update parent's canonical_child_id if it pointed to the deleted message.
end
```

### POST /api/impersonate

No structural change. Builds context from the canonical path, generates as user.
The response is not added to the tree -- it is returned for the user to review and
optionally send (which would go through POST /api/message or a new endpoint).

### Endpoint summary

| Old endpoint              | New endpoint               | Change                                        |
|---------------------------|----------------------------|-----------------------------------------------|
| GET /api/card             | GET /api/card              | No change                                     |
| GET /api/messages         | GET /api/messages          | Returns canonical path with sibling info      |
| POST /api/message         | POST /api/message          | Adds to tree instead of flat list             |
| POST /api/message/stream  | POST /api/message/stream   | Same as above, with SSE                       |
| POST /api/continue        | POST /api/continue         | Operates on canonical path leaf               |
| GET /api/swipes           | GET /api/siblings          | Queries tree children                         |
| POST /api/swipe/new       | POST /api/branch/new       | Creates sibling in tree                       |
| *(none)*                  | POST /api/branch/navigate  | Switches canonical_child_id to existing sibling|
| POST /api/message/edit    | POST /api/message/edit     | Creates new sibling (fork), not in-place edit |
| POST /api/message/delete  | POST /api/message/delete   | Deletes subtree                               |
| POST /api/impersonate     | POST /api/impersonate      | No structural change                          |

## Context Assembly

`build_context` currently reads `state.messages` (flat array). After migration, it
reads the canonical path instead:

```lua
local function build_context(state, caps)
  local path, err = state.conv:get_canonical_path(state.session_id)
  if not path then return nil, err end
  -- path is already root-to-leaf, same shape as the old state.messages
  -- (each entry has .role and .content)
  -- Feed into context_mod.assemble() unchanged.
  return context_mod.assemble({
    card = state.card,
    history = path,   -- was: state.messages
    ...
  })
end
```

For generating a sibling (POST /api/branch/new), context is built from the path up
to the target message's parent:

```lua
local function build_context_to_parent(state, caps, parent_id)
  -- Walk from root to parent_id following the tree
  local path = {}
  local current = parent_id
  -- Walk up to root, then reverse
  while current do
    local msg = state.conv:get_message(current)
    path[#path + 1] = msg
    current = msg.parent_id
  end
  -- Reverse: root first
  local reversed = {}
  for i = #path, 1, -1 do reversed[#reversed + 1] = path[i] end
  return context_mod.assemble({ card = state.card, history = reversed, ... })
end
```

## Persistence

### Current

State is serialized as JSON to `caps.kv.set("card_state", ...)`:

```lua
{ messages = [...], swipes = {...}, next_id = N }
```

### Target

The conversation tree lives in SQLite via `lib/conversation`. The card app opens a
database file (path from caps or a default location):

```lua
local conv = require("lib.conversation")
-- Path comes from caps.db or a default
local db_path = get_db_path(caps)
state.conv = conv.open(db_path)
```

Session tracking (`session_id`) is stored in `caps.kv`:

```lua
caps.kv.set("active_session", session_id)
```

On startup:

```lua
local session_id = caps.kv and caps.kv.get("active_session")
if session_id then
  local session = state.conv:get_session(session_id)
  if session then state.session_id = session_id end
end
if not state.session_id then
  local session = state.conv:create_session(app_id)
  state.session_id = session.id
  if caps.kv then caps.kv.set("active_session", session.id) end
end
```

### When caps.kv and SQLite are unavailable

The card app must work without persistence (headless, MCP, etc.). In this case, the
tree is held in memory. `lib/conversation` uses `sqlite.open(":memory:")` and the
tree works identically but is lost on exit. This matches the current behavior where
no `caps.kv` means no persistence.

## Migration Strategy

Existing users have state in `caps.kv.get("card_state")` as a flat JSON blob. The
migration runs once on startup when the SQLite database is empty but kv state exists.

```lua
local function migrate_flat_to_tree(state, caps)
  local raw = caps.kv and caps.kv.get("card_state")
  if not raw then return false end
  local ok, data = pcall(json.decode, raw)
  if not ok or not data or not data.messages then return false end

  -- Check if we already have messages in the tree
  local path = state.conv:get_canonical_path(state.session_id)
  if path and #path > 0 then return false end  -- already migrated

  -- Insert messages as a linear chain (no branches)
  local parent_id = nil
  for _, msg in ipairs(data.messages) do
    local new_msg = state.conv:add_message(
      state.session_id, parent_id, msg.role, msg.content
    )
    parent_id = new_msg.id
  end

  -- Migrate swipes: for each message that had swipe alternatives, insert
  -- them as siblings (same parent).
  -- This requires re-walking the chain to match old IDs to new IDs.
  -- (The old msg.id values map to positions in the chain.)

  return true
end
```

Swipe migration detail: the old `state.swipes` maps old message IDs to alternatives.
During migration, we track the mapping from old ID to new tree node. For each old
message with swipes, the non-active alternatives are inserted as siblings of the
corresponding tree node (same parent_id).

After successful migration, the old kv state can be cleared:

```lua
caps.kv.set("card_state", nil)  -- or leave it as a backup
```

## lib/conversation Changes Needed

The existing `lib/conversation/init.lua` needs these additions:

1. **`db:update_message(id, fields)`** -- update content (for continue) and/or
   metadata. Currently there is no way to modify a message after creation.

2. **`db:delete_subtree(message_id)`** -- delete a message and all its descendants.
   Must update the parent's `canonical_child_id` if it pointed to the deleted message.
   Use a recursive CTE:
   ```sql
   WITH RECURSIVE subtree(id) AS (
     SELECT id FROM messages WHERE id = ?
     UNION ALL
     SELECT m.id FROM messages m JOIN subtree s ON m.parent_id = s.id
   )
   DELETE FROM messages WHERE id IN (SELECT id FROM subtree)
   ```

3. **`db:get_siblings(message_id)`** -- convenience for getting all children of a
   message's parent. Currently achievable via `get_message` + `get_children` but a
   single method is cleaner.

4. **`db:get_path_to(message_id)`** -- walk from a message up to root, return
   reversed (root-first). Needed for building context to an arbitrary point in the
   tree (not just the canonical leaf).

## Frontend Changes

### app.js data model

The `swipeCache` Map is replaced. Each message in the DOM carries its `parent_id`
and the server provides `sibling_index` / `sibling_count` with every message.

```js
// Before
// msg: {id, role, content, swipe_index, swipe_total}

// After
// msg: {id, role, content, parent_id, sibling_index, sibling_count}
```

### Message rendering

The swipe UI (`<` `1/3` `>`) works the same visually. The data source changes:

- **Before:** swipe left/right navigates `swipeCache[id]`, a local array.
- **After:** swipe left/right calls `GET /api/siblings?message_id=ID` to get the
  list, then `POST /api/branch/navigate` to switch. The server responds with the
  new canonical path; the frontend re-renders everything below the swipe point.

### Branch indicator

Show `sibling_index+1 / sibling_count` on every message that has siblings
(`sibling_count > 1`). This is the same visual as the current swipe indicator but
applies to all messages, not just the last assistant message.

### Subtree reload on swipe

When the user swipes to a different sibling at position N, every message below N
changes (it is a different subtree). The frontend must:

1. Call `POST /api/branch/navigate` with the target sibling ID.
2. Remove all message DOM elements after position N.
3. Call `GET /api/messages` to get the new full path (or have the navigate endpoint
   return the sub-path below the swipe point).
4. Render the new messages.

This is the main UX change. Currently swiping only changes one message's content.
Now it changes the entire conversation below that point.

### Edit behavior

Editing a message no longer updates it in place. Instead:

1. User edits message N, hits save.
2. Frontend calls `POST /api/message/edit` with the new content.
3. Server creates a new sibling, returns `reload_below: true`.
4. Frontend updates message N's content and ID, increments sibling count, removes
   all messages below N (the new branch has no children yet).
5. If the edited message was a user message, the user can then send a new message
   or regenerate to continue the new branch.

### Delete behavior

Deleting a message removes it and its entire subtree. The frontend removes the
message and everything below it from the DOM. If the deleted message had siblings,
the parent's canonical child switches to a surviving sibling and the frontend
reloads from that point.

## Open Questions

1. **Greeting handling.** The current greeting (first_mes + alternate_greetings) is
   special-cased: the greeting is message[1] and alternate greetings are swipes.
   In the tree model, the greeting becomes the root message and alternate greetings
   become siblings of the root (children of a synthetic "session root" node, or
   root-level messages with parent_id = NULL that are siblings of each other). Which
   approach? Having multiple root messages (parent_id = NULL) is simpler but
   `get_canonical_path` currently assumes a single root.

2. **Rollback on LLM failure.** When `POST /api/message` fails after adding the user
   message to the tree, the user message needs to be removed. `lib/conversation` has
   no `delete_message` (only `delete_session`). `delete_subtree` would work but is
   heavier than needed. Add a simple `delete_message(id)` for leaf nodes?

3. **Continue semantics.** Continue appends to the last assistant message's content.
   This is an in-place mutation, not a branch. `lib/conversation` needs
   `update_message` for this. Should continue create a new sibling instead of
   mutating? (SillyTavern mutates in place.)

4. **Session management endpoints.** The current API has no concept of sessions.
   Eventually need: `POST /api/session/new`, `GET /api/sessions`,
   `POST /api/session/switch`. Out of scope for the initial tree migration -- defer
   to a follow-up.

5. **Performance.** `get_canonical_path` does N queries (one per hop). For long
   conversations (hundreds of messages), this could be slow. Consider a single
   recursive CTE query that walks the canonical chain in one round-trip. Not blocking
   for v1 -- optimize when measured.

6. **Frontend state management.** The current frontend is stateless (fetches
   everything from the server on init). With tree navigation, the frontend needs to
   handle partial reloads (subtree below a swipe point). Two approaches:
   - Always re-fetch the full path via `GET /api/messages` after any navigation.
     Simple, slightly wasteful.
   - Have navigation endpoints return only the changed sub-path. More efficient,
     more complex frontend logic.
   Recommendation: start with full re-fetch. Optimize later if needed.

7. **Old endpoint names.** Should `GET /api/swipes` and `POST /api/swipe/new` be
   renamed to `siblings`/`branch` immediately, or keep old names as aliases during
   transition? Renaming is cleaner but breaks any existing clients. Since the card
   app frontend is the only client, renaming is safe.
