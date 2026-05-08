-- lib/raft/init.lua
-- Pure Lua state-machine implementation of the Raft consensus algorithm.
-- No networking — callers feed messages and ticks, node produces outbound messages.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function log_term(log, index)
  if index == 0 then return 0 end
  local entry = log[index]
  if not entry then return 0 end
  return entry.term
end

local function majority(n)
  return math.floor(n / 2) + 1
end

-- ---------------------------------------------------------------------------
-- Node constructor
-- ---------------------------------------------------------------------------

--:: Node = { id: string, peers: { string }, election_timeout: number, heartbeat_interval: number, state: string, current_term: number, voted_for: string|nil, log: { { term: number, data: unknown } }, commit_index: number, last_applied: number, votes_granted: number, election_timer: number, heartbeat_timer: number, leader_id: string|nil, next_index: { [string]: number }, match_index: { [string]: number }, outbox: { unknown }, committed_queue: { unknown } }

function M.node(opts)
  if not opts then return nil, "opts required" end
  if not opts.id then return nil, "opts.id required" end
  if not opts.peers then return nil, "opts.peers required" end
  local peers_arr = opts.peers
  local id_str = opts.id

  local election_timeout   = (opts.election_timeout   or 10) --[[: number]]
  local heartbeat_interval = (opts.heartbeat_interval or 3) --[[: number]]
  -- jitter: random extra ticks added to election timer to avoid split votes.
  -- Default: election_timeout/2 so timers spread over [timeout, 1.5*timeout].
  local election_jitter = opts.election_jitter
  if election_jitter == nil then
    election_jitter = math.floor(election_timeout / 2)
  end
  election_jitter = election_jitter --[[: integer]]

  local function rand_election_timer()
    if election_jitter > 0 then
      return election_timeout + math.random(0, election_jitter)
    end
    return election_timeout
  end

  local self = {
    id                  = opts.id,
    peers               = opts.peers,
    election_timeout    = election_timeout,
    heartbeat_interval  = heartbeat_interval,
    election_jitter     = election_jitter,

    -- persistent state
    _state              = "follower" --[[: string]],
    _current_term       = 0,
    _voted_for          = nil --[[: string | nil]],
    _log                = {} --[[: { [integer]: { term: integer, data: unknown } }]],         -- 1-indexed: {term, data}

    -- volatile state
    _commit_index       = 0,
    _last_applied       = 0,
    _leader_id          = nil --[[: string | nil]],

    -- candidate state
    _votes_granted      = 0,

    -- timers (countdown in ticks)
    _election_timer     = rand_election_timer(),
    _heartbeat_timer    = heartbeat_interval,

    -- leader state
    _next_index         = {} --[[: { [string]: integer }]],   -- peer → next log index to send
    _match_index        = {} --[[: { [string]: integer }]],   -- peer → highest replicated index

    -- output queues
    _outbox             = {} --[[: { [integer]: unknown }]],
    _committed_queue    = {} --[[: { [integer]: unknown }]],
  }

  -- -------------------------------------------------------------------------
  -- Private helpers
  -- -------------------------------------------------------------------------

  --: (msg: unknown) -> nil
  local function emit(msg)
    self._outbox[#self._outbox + 1] = msg
  end

  local function flush()
    local msgs = self._outbox
    self._outbox = {}
    return msgs
  end

  local function become_follower(term)
    self._state        = "follower"
    self._current_term = term
    self._voted_for    = nil
    self._election_timer = rand_election_timer()
    self._votes_granted = 0
  end

  local function advance_commit()
    -- Leader: find highest N > commit_index where majority have match_index >= N
    -- and log[N].term == current_term.
    if self._state ~= "leader" then return end
    local log = self._log
    local n_peers = #self.peers
    local cluster_size = n_peers + 1  -- include self

    -- Search from current commit_index+1 up to last log index
    for n = #log, self._commit_index + 1, -1 do
      if log[n] and log[n].term == self._current_term then
        local count = 1  -- leader itself
        for _, peer in ipairs(self.peers) do
          if (self._match_index[peer] or 0) >= n then
            count = count + 1
          end
        end
        if count >= majority(cluster_size) then
          self._commit_index = n
          break
        end
      end
    end

    -- Apply newly committed entries
    while self._last_applied < self._commit_index do
      self._last_applied = self._last_applied + 1
      self._committed_queue[#self._committed_queue + 1] = self._log[self._last_applied]
    end
  end

  local function send_append_entries(peer)
    local ni   = self._next_index[peer] or (#self._log + 1)
    local prev_index = ni - 1
    local prev_term  = log_term(self._log, prev_index)

    -- Collect entries to send (may be empty for heartbeat)
    local entries = {}
    for i = ni, #self._log do
      entries[#entries + 1] = self._log[i]
    end

    emit({
      type           = "append_entries",
      to             = peer,
      from           = self.id,
      term           = self._current_term,
      prev_log_index = prev_index,
      prev_log_term  = prev_term,
      entries        = entries,
      commit_index   = self._commit_index,
    })
  end

  local function become_leader()
    self._state      = "leader"
    self._leader_id  = self.id
    -- Initialize leader bookkeeping
    for _, peer in ipairs(self.peers) do
      self._next_index[peer]  = #self._log + 1
      self._match_index[peer] = 0
    end
    self._heartbeat_timer = 0  -- send heartbeats immediately
  end

  local function start_election()
    self._state        = "candidate"
    self._current_term = self._current_term + 1
    self._voted_for    = self.id
    self._votes_granted = 1  -- vote for self
    self._election_timer = rand_election_timer()  -- restart with jitter
    self._leader_id    = nil

    local last_index = #self._log
    local last_term  = log_term(self._log, last_index)

    for _, peer in ipairs(self.peers) do
      emit({
        type           = "vote_request",
        to             = peer,
        from           = self.id,
        term           = self._current_term,
        last_log_index = last_index,
        last_log_term  = last_term,
      })
    end

    -- Single-node cluster: already a majority
    if #self.peers == 0 then
      become_leader()
    end
  end

  -- -------------------------------------------------------------------------
  -- Message handlers
  -- -------------------------------------------------------------------------

  --: (msg: { type: string, term: integer, from: string, last_log_index: integer, last_log_term: integer, ... }) -> nil
  local function handle_vote_request(msg)
    -- Reject if lower term
    if msg.term < self._current_term then
      emit({
        type    = "vote_response",
        to      = msg.from,
        from    = self.id,
        term    = self._current_term,
        granted = false,
      })
      return
    end

    if msg.term > self._current_term then
      become_follower(msg.term)
    end

    -- Check if we can grant the vote
    local already_voted = self._voted_for ~= nil and self._voted_for ~= msg.from
    local my_last_index = #self._log
    local my_last_term  = log_term(self._log, my_last_index)

    -- Raft log up-to-date check: candidate's log must be at least as up-to-date
    local log_ok = (msg.last_log_term > my_last_term) or
                   (msg.last_log_term == my_last_term and msg.last_log_index >= my_last_index)

    local granted = (not already_voted) and log_ok

    if granted then
      self._voted_for    = msg.from
      self._election_timer = rand_election_timer()  -- reset on granting vote
    end

    emit({
      type    = "vote_response",
      to      = msg.from,
      from    = self.id,
      term    = self._current_term,
      granted = granted,
    })
  end

  --: (msg: { type: string, term: integer, from: string, granted: boolean, ... }) -> nil
  local function handle_vote_response(msg)
    if self._state ~= "candidate" then return end
    if msg.term > self._current_term then
      become_follower(msg.term)
      return
    end
    if msg.term < self._current_term then return end

    if msg.granted then
      self._votes_granted = self._votes_granted + 1
      local cluster_size = #self.peers + 1
      if self._votes_granted >= majority(cluster_size) then
        become_leader()
      end
    end
  end

  --: (msg: { type: string, term: integer, from: string, prev_log_index: integer, prev_log_term: integer, entries: { [integer]: { term: integer, data: unknown } }, commit_index: integer, ... }) -> nil
  local function handle_append_entries(msg)
    -- Reject stale terms
    if msg.term < self._current_term then
      emit({
        type        = "append_entries_response",
        to          = msg.from,
        from        = self.id,
        term        = self._current_term,
        success     = false,
        match_index = 0,
      })
      return
    end

    -- Higher/equal term from a leader → become/stay follower
    if msg.term > self._current_term then
      become_follower(msg.term)
    else
      -- Same term: reset election timer and record leader
      self._election_timer = rand_election_timer()
      if self._state == "candidate" then
        self._state = "follower"
        self._votes_granted = 0
      end
    end
    self._leader_id = msg.from

    -- Log consistency check
    if msg.prev_log_index > 0 then
      local entry = self._log[msg.prev_log_index]
      if not entry or entry.term ~= msg.prev_log_term then
        emit({
          type        = "append_entries_response",
          to          = msg.from,
          from        = self.id,
          term        = self._current_term,
          success     = false,
          match_index = 0,
        })
        return
      end
    end

    -- Append new entries (delete any conflicting entries first)
    local insert_at = msg.prev_log_index + 1
    for i, entry in ipairs(msg.entries) do
      local idx = insert_at + i - 1
      if self._log[idx] then
        if self._log[idx].term ~= entry.term then
          -- Delete from here onward
          for j = idx, #self._log do
            self._log[j] = nil
          end
        end
      end
      self._log[idx] = entry
    end

    -- Advance commit index
    if msg.commit_index > self._commit_index then
      self._commit_index = math.min(msg.commit_index, #self._log)
    end

    -- Apply newly committed entries
    while self._last_applied < self._commit_index do
      self._last_applied = self._last_applied + 1
      self._committed_queue[#self._committed_queue + 1] = self._log[self._last_applied]
    end

    local match_index = msg.prev_log_index + #msg.entries
    emit({
      type        = "append_entries_response",
      to          = msg.from,
      from        = self.id,
      term        = self._current_term,
      success     = true,
      match_index = match_index,
    })
  end

  --: (msg: { type: string, term: integer, from: string, success: boolean, match_index: integer, ... }) -> nil
  local function handle_append_entries_response(msg)
    if self._state ~= "leader" then return end
    if msg.term > self._current_term then
      become_follower(msg.term)
      return
    end
    if msg.term < self._current_term then return end

    if msg.success then
      self._match_index[msg.from] = math.max(self._match_index[msg.from] or 0, msg.match_index)
      self._next_index[msg.from]  = self._match_index[msg.from] + 1
      advance_commit()
    else
      -- Decrement next_index and retry
      local ni = self._next_index[msg.from] or 1
      self._next_index[msg.from] = math.max(1, ni - 1)
      send_append_entries(msg.from)
    end
  end

  -- -------------------------------------------------------------------------
  -- Public API
  -- -------------------------------------------------------------------------

  function self:tick()
    if self._state == "leader" then
      self._heartbeat_timer = self._heartbeat_timer - 1
      if self._heartbeat_timer <= 0 then
        self._heartbeat_timer = self.heartbeat_interval
        for _, peer in ipairs(self.peers) do
          send_append_entries(peer)
        end
      end
    else
      self._election_timer = self._election_timer - 1
      if self._election_timer <= 0 then
        start_election()
      end
    end
    return flush()
  end

  function self:receive(msg)
    if not msg or not msg.type then return nil, "invalid message" end
    local t = msg.type
    if t == "vote_request" then
      handle_vote_request(msg)
    elseif t == "vote_response" then
      handle_vote_response(msg)
    elseif t == "append_entries" then
      handle_append_entries(msg)
    elseif t == "append_entries_response" then
      handle_append_entries_response(msg)
    else
      return nil, "unknown message type: " .. tostring(t)
    end
    return flush()
  end

  function self:propose(data)
    if self._state ~= "leader" then
      return nil, "not leader"
    end
    self._log[#self._log + 1] = { term = self._current_term, data = data }
    -- Replicate immediately to peers
    for _, peer in ipairs(self.peers) do
      send_append_entries(peer)
    end
    -- Single-node: commit immediately
    advance_commit()
    -- Flush outbox (already drained by caller via return value, but we still
    -- want them — callers may ignore return value of propose)
    return true, nil
  end

  -- Propose that also returns outbound messages for callers who need them
  function self:propose_msgs(data)
    if self._state ~= "leader" then
      return nil, "not leader"
    end
    self._log[#self._log + 1] = { term = self._current_term, data = data }
    for _, peer in ipairs(self.peers) do
      send_append_entries(peer)
    end
    advance_commit()
    return flush()
  end

  function self:state()
    return self._state
  end

  function self:current_term()
    return self._current_term
  end

  function self:leader_id()
    return self._leader_id
  end

  function self:log()
    return self._log
  end

  function self:commit_index()
    return self._commit_index
  end

  function self:take_committed()
    local q = self._committed_queue
    self._committed_queue = {}
    return q
  end

  return self
end

return M
