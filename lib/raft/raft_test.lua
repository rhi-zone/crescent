-- lib/raft/raft_test.lua
-- Tests for the Raft consensus state machine.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local raft = require("lib.raft")

-- ---------------------------------------------------------------------------
-- Simulation helpers
-- ---------------------------------------------------------------------------

-- Create a cluster of n nodes with ids "n1", "n2", ..., "nN".
local function make_cluster(n)
  local ids = {}
  for i = 1, n do ids[i] = "n" .. i end

  local nodes = {}
  for i = 1, n do
    local peers = {}
    for j = 1, n do
      if j ~= i then peers[#peers + 1] = ids[j] end
    end
    nodes[ids[i]] = raft.node({
      id                 = ids[i],
      peers              = peers,
      election_timeout   = 10,
      heartbeat_interval = 3,
    })
  end

  -- Pending message queues per destination
  local pending = {}   -- pending[dest] = { msg, ... }

  local function enqueue(msgs)
    for _, msg in ipairs(msgs) do
      local dest = msg.to
      if not pending[dest] then pending[dest] = {} end
      pending[dest][#pending[dest] + 1] = msg
    end
  end

  local cluster = {
    nodes   = nodes,
    pending = pending,
    ids     = ids,
  }

  function cluster:tick_all()
    for _, id in ipairs(self.ids) do
      local msgs = self.nodes[id]:tick()
      enqueue(msgs)
    end
  end

  function cluster:tick_node(id)
    local msgs = self.nodes[id]:tick()
    enqueue(msgs)
  end

  function cluster:deliver_all()
    -- First, drain any messages sitting in node outboxes (e.g. from propose())
    for _, id in ipairs(self.ids) do
      local node = self.nodes[id]
      -- flush() is not exposed, but propose_msgs returns and flushes.
      -- We instead collect via a helper: nodes expose _outbox directly.
      local outbox = node._outbox
      if outbox and #outbox > 0 then
        enqueue(outbox)
        node._outbox = {}
      end
    end

    local limit = 1000
    local rounds = 0
    repeat
      local any = false
      for dest, queue in pairs(pending) do
        if #queue > 0 then
          local msg = table.remove(queue, 1)
          local node = self.nodes[dest]
          if node then
            local out = node:receive(msg)
            if out then enqueue(out) end
            any = true
          end
        end
      end
      rounds = rounds + 1
      if rounds > limit then break end
    until not any
  end

  function cluster:flush_pending(dest)
    pending[dest] = {}
  end

  function cluster:drop_from(src)
    -- Drop all pending messages FROM src
    for dest, queue in pairs(pending) do
      local keep = {}
      for _, msg in ipairs(queue) do
        if msg.from ~= src then keep[#keep + 1] = msg end
      end
      pending[dest] = keep
    end
  end

  function cluster:find_leader()
    for _, id in ipairs(self.ids) do
      if self.nodes[id]:state() == "leader" then
        return id
      end
    end
    return nil
  end

  function cluster:leader_count()
    local c = 0
    for _, id in ipairs(self.ids) do
      if self.nodes[id]:state() == "leader" then c = c + 1 end
    end
    return c
  end

  return cluster
end

-- Run ticks and deliver until a leader exists or max_ticks exceeded.
local function wait_for_leader(cluster, max_ticks)
  max_ticks = max_ticks or 50
  for _ = 1, max_ticks do
    cluster:tick_all()
    cluster:deliver_all()
    if cluster:find_leader() then return cluster:find_leader() end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("raft", function()

  -- -------------------------------------------------------------------------
  T.describe("single-node cluster", function()

    T.it("becomes leader after election timeout", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 5, election_jitter = 0 })
      T.eq(node:state(), "follower")
      -- Tick until election fires (5 ticks)
      for _ = 1, 5 do node:tick() end
      T.eq(node:state(), "leader")
    end)

    T.it("leader sends no heartbeats with no peers", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 1, heartbeat_interval = 1, election_jitter = 0 })
      node:tick()  -- becomes leader
      local msgs = node:tick()  -- heartbeat tick
      T.eq(#msgs, 0)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("3-node cluster: election", function()

    T.it("exactly one leader is elected", function()
      local c = make_cluster(3)
      local leader = wait_for_leader(c, 50)
      T.ok(leader ~= nil)
      T.eq(c:leader_count(), 1)
    end)

    T.it("leader knows its own id", function()
      local c = make_cluster(3)
      local leader = wait_for_leader(c, 50)
      T.ok(leader ~= nil)
      T.eq(c.nodes[leader]:leader_id(), leader)
    end)

    T.it("followers know the leader", function()
      local c = make_cluster(3)
      local leader = wait_for_leader(c, 50)
      T.ok(leader ~= nil)
      -- Deliver a few more rounds so followers hear heartbeats
      for _ = 1, 5 do
        c:tick_all()
        c:deliver_all()
      end
      for _, id in ipairs(c.ids) do
        local node = c.nodes[id]
        -- Leaders and nodes that have received heartbeats know the leader
        if node:state() ~= "candidate" then
          T.eq(node:leader_id(), leader)
        end
      end
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("heartbeats", function()

    T.it("leader produces AppendEntries to all peers after heartbeat interval", function()
      -- Single node becomes leader immediately, then we add peers after the fact
      -- by creating a pre-configured leader node
      local node = raft.node({
        id                 = "n1",
        peers              = {"n2", "n3"},
        election_timeout   = 1,
        heartbeat_interval = 3,
      })
      -- Tick once to trigger election (becomes leader, 0 peers responded but single-step)
      -- Actually with 2 peers it needs majority=2. Use a simulated cluster instead.
      local c = make_cluster(3)
      local leader = wait_for_leader(c, 50)
      T.ok(leader ~= nil)

      -- Tick the leader enough to trigger a heartbeat
      local leader_node = c.nodes[leader]
      local hb_interval = leader_node.heartbeat_interval
      local found_ae = false
      for _ = 1, hb_interval + 1 do
        local msgs = leader_node:tick()
        for _, msg in ipairs(msgs) do
          if msg.type == "append_entries" then
            found_ae = true
          end
        end
      end
      T.ok(found_ae)
    end)

    T.it("heartbeat AppendEntries has correct term and empty entries", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      local leader = c.nodes[leader_id]
      local term = leader:current_term()

      -- Force heartbeat by ticking past interval
      local msgs = {}
      for _ = 1, leader.heartbeat_interval + 1 do
        for _, m in ipairs(leader:tick()) do msgs[#msgs + 1] = m end
      end

      local ae_msgs = {}
      for _, m in ipairs(msgs) do
        if m.type == "append_entries" then ae_msgs[#ae_msgs + 1] = m end
      end

      T.ok(#ae_msgs > 0)
      for _, m in ipairs(ae_msgs) do
        T.eq(m.term, term)
        T.eq(m.from, leader_id)
        T.eq(#m.entries, 0)
      end
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("vote rules", function()

    T.it("follower rejects vote request with lower term", function()
      local node = raft.node({ id = "n1", peers = {"n2"}, election_timeout = 100 })
      -- Advance node's term
      node:receive({ type = "append_entries", from = "n2", term = 5,
                     prev_log_index = 0, prev_log_term = 0, entries = {}, commit_index = 0 })
      T.eq(node:current_term(), 5)

      -- Send vote_request with lower term
      local msgs = node:receive({ type = "vote_request", from = "n2", term = 3,
                                   last_log_index = 0, last_log_term = 0 })
      T.ok(#msgs == 1)
      T.eq(msgs[1].type, "vote_response")
      T.eq(msgs[1].granted, false)
    end)

    T.it("follower rejects vote if candidate log is behind", function()
      local node = raft.node({ id = "n1", peers = {"n2"}, election_timeout = 100 })
      -- Give node some log entries via append_entries
      node:receive({
        type           = "append_entries",
        from           = "n2",
        term           = 2,
        prev_log_index = 0,
        prev_log_term  = 0,
        entries        = { { term = 1, data = "a" }, { term = 2, data = "b" } },
        commit_index   = 0,
      })
      T.eq(#node:log(), 2)

      -- Candidate has empty log (last_log_index=0, last_log_term=0) — behind
      local msgs = node:receive({
        type           = "vote_request",
        from           = "n3",
        term           = 3,
        last_log_index = 0,
        last_log_term  = 0,
      })
      T.ok(#msgs == 1)
      T.eq(msgs[1].granted, false)
    end)

    T.it("follower grants vote when log is at least as up-to-date", function()
      local node = raft.node({ id = "n1", peers = {"n2"}, election_timeout = 100 })
      -- Grant vote when candidate has same or better log
      local msgs = node:receive({
        type           = "vote_request",
        from           = "n2",
        term           = 1,
        last_log_index = 0,
        last_log_term  = 0,
      })
      T.ok(#msgs == 1)
      T.eq(msgs[1].granted, true)
    end)

    T.it("follower does not double-vote in same term", function()
      local node = raft.node({ id = "n1", peers = {"n2", "n3"}, election_timeout = 100 })
      -- Grant vote to n2
      local msgs1 = node:receive({
        type = "vote_request", from = "n2", term = 1,
        last_log_index = 0, last_log_term = 0,
      })
      T.eq(msgs1[1].granted, true)

      -- n3 asks for same term
      local msgs2 = node:receive({
        type = "vote_request", from = "n3", term = 1,
        last_log_index = 0, last_log_term = 0,
      })
      T.eq(msgs2[1].granted, false)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("log replication", function()

    T.it("propose on non-leader returns error", function()
      local node = raft.node({ id = "n1", peers = {"n2"}, election_timeout = 100 })
      local ok, err = node:propose("data")
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)

    T.it("propose on leader replicates to followers and commits", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      local leader = c.nodes[leader_id]
      local ok, err = leader:propose("hello")
      T.eq(ok, true)
      T.eq(err, nil)

      -- Deliver replication messages
      c:deliver_all()

      -- Leader should have committed
      T.eq(leader:commit_index(), 1)

      -- All nodes should have the log entry
      for _, id in ipairs(c.ids) do
        local log = c.nodes[id]:log()
        T.eq(#log, 1)
        T.eq(log[1].data, "hello")
      end
    end)

    T.it("take_committed returns committed entries and drains queue", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      local leader = c.nodes[leader_id]
      leader:propose("entry1")
      leader:propose("entry2")
      c:deliver_all()

      local committed = leader:take_committed()
      T.ok(#committed >= 2)
      T.eq(committed[1].data, "entry1")
      T.eq(committed[2].data, "entry2")

      -- Second call returns empty
      local committed2 = leader:take_committed()
      T.eq(#committed2, 0)
    end)

    T.it("followers apply committed entries", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      local leader = c.nodes[leader_id]
      leader:propose("value")
      c:deliver_all()

      -- All nodes should have commit_index=1 after heartbeats propagate commit
      -- (followers learn commit via commit_index in AppendEntries)
      -- Send another round of heartbeats
      for _ = 1, leader.heartbeat_interval + 1 do
        c:tick_all()
        c:deliver_all()
      end

      for _, id in ipairs(c.ids) do
        T.eq(c.nodes[id]:commit_index(), 1)
      end
    end)

    T.it("log consistency check rejects mismatched prev_log", function()
      local node = raft.node({ id = "n1", peers = {"n2"}, election_timeout = 100 })
      -- First append succeeds
      node:receive({
        type = "append_entries", from = "n2", term = 1,
        prev_log_index = 0, prev_log_term = 0,
        entries = {{ term = 1, data = "a" }},
        commit_index = 0,
      })
      T.eq(#node:log(), 1)

      -- Second append with wrong prev_log_term fails
      local msgs = node:receive({
        type = "append_entries", from = "n2", term = 1,
        prev_log_index = 1, prev_log_term = 99,  -- wrong term
        entries = {{ term = 1, data = "b" }},
        commit_index = 0,
      })
      T.ok(#msgs == 1)
      T.eq(msgs[1].success, false)
      T.eq(#node:log(), 1)  -- unchanged
    end)

    T.it("conflicting entries are truncated on append", function()
      local node = raft.node({ id = "n1", peers = {"n2"}, election_timeout = 100 })
      -- Append two entries
      node:receive({
        type = "append_entries", from = "n2", term = 1,
        prev_log_index = 0, prev_log_term = 0,
        entries = {{ term = 1, data = "a" }, { term = 1, data = "b" }},
        commit_index = 0,
      })
      T.eq(#node:log(), 2)

      -- Leader sends conflicting entry at index 2 with higher term
      node:receive({
        type = "append_entries", from = "n2", term = 2,
        prev_log_index = 1, prev_log_term = 1,
        entries = {{ term = 2, data = "c" }},
        commit_index = 0,
      })
      T.eq(#node:log(), 2)
      T.eq(node:log()[2].data, "c")
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("term updates and step-down", function()

    T.it("higher-term message causes leader to step down", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      local leader = c.nodes[leader_id]
      local old_term = leader:current_term()

      -- Deliver a message with higher term
      leader:receive({
        type = "vote_request", from = "n99", term = old_term + 5,
        last_log_index = 0, last_log_term = 0,
      })

      T.eq(leader:state(), "follower")
      T.eq(leader:current_term(), old_term + 5)
    end)

    T.it("append_entries with higher term causes step-down", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      local leader = c.nodes[leader_id]
      local old_term = leader:current_term()

      leader:receive({
        type = "append_entries", from = "n99", term = old_term + 3,
        prev_log_index = 0, prev_log_term = 0,
        entries = {}, commit_index = 0,
      })

      T.eq(leader:state(), "follower")
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("re-election after partition", function()

    T.it("new leader elected when old leader stops sending heartbeats", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      -- Simulate partition: stop delivering any messages from leader
      -- by setting leader's heartbeat timer very high (we just won't tick it)
      -- Instead we tick the other two nodes only
      local others = {}
      for _, id in ipairs(c.ids) do
        if id ~= leader_id then others[#others + 1] = id end
      end

      -- Drain any pending messages first
      c:deliver_all()

      -- Drop all pending heartbeats from leader
      c:drop_from(leader_id)

      -- Tick only the followers until one starts an election and wins
      local new_leader = nil
      for _ = 1, 60 do
        for _, id in ipairs(others) do
          local msgs = c.nodes[id]:tick()
          for _, msg in ipairs(msgs) do
            -- Only deliver to non-leader nodes
            local dest = msg.to
            if dest ~= leader_id and c.nodes[dest] then
              local out = c.nodes[dest]:receive(msg)
              if out then
                for _, m in ipairs(out) do
                  if m.to ~= leader_id and c.nodes[m.to] then
                    c.nodes[m.to]:receive(m)
                  end
                end
              end
            end
          end
        end
        -- Check if one of the followers became leader
        for _, id in ipairs(others) do
          if c.nodes[id]:state() == "leader" then
            new_leader = id
            break
          end
        end
        if new_leader then break end
      end

      T.ok(new_leader ~= nil)
      T.ok(new_leader ~= leader_id)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("node API", function()

    T.it("state() returns correct state string", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 100 })
      T.eq(node:state(), "follower")
    end)

    T.it("current_term() starts at 0", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 100 })
      T.eq(node:current_term(), 0)
    end)

    T.it("leader_id() is nil initially", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 100 })
      T.eq(node:leader_id(), nil)
    end)

    T.it("log() starts empty", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 100 })
      T.eq(#node:log(), 0)
    end)

    T.it("commit_index() starts at 0", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 100 })
      T.eq(node:commit_index(), 0)
    end)

    T.it("invalid message returns error", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 100 })
      local result, err = node:receive({ type = "unknown_type" })
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("receive nil returns error", function()
      local node = raft.node({ id = "n1", peers = {}, election_timeout = 100 })
      local result, err = node:receive(nil)
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("multiple proposals", function()

    T.it("multiple entries replicated in order", function()
      local c = make_cluster(3)
      local leader_id = wait_for_leader(c, 50)
      T.ok(leader_id ~= nil)

      local leader = c.nodes[leader_id]
      leader:propose("first")
      leader:propose("second")
      leader:propose("third")
      c:deliver_all()

      T.eq(leader:commit_index(), 3)
      local log = leader:log()
      T.eq(log[1].data, "first")
      T.eq(log[2].data, "second")
      T.eq(log[3].data, "third")

      local committed = leader:take_committed()
      T.eq(#committed, 3)
      T.eq(committed[1].data, "first")
      T.eq(committed[3].data, "third")
    end)

  end)

end)
