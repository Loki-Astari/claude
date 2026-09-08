---@diagnostic disable: undefined-global
--- Session history tree: read a Claude Code transcript as the tree it actually
--- is, show it in a popup, and jump to any node in it.
---
--- Claude Code transcripts are append-only JSONL where entries link by
--- `uuid`/`parentUuid`.  `/rewind` does not truncate the file — it starts a
--- sibling branch — so one session file holds every line of work you have ever
--- explored in it.  The active position is recorded as a separate entry:
---
---   {"type":"last-prompt","lastPrompt":"…","leafUuid":"<uuid>","sessionId":"…"}
---
--- The LAST such entry wins, which is the whole trick behind jumping: append a
--- pointer at any node and `claude --resume <session>` walks the tree from that
--- node to the root.  Nothing is destroyed by moving; every branch keeps its
--- own tip and can be jumped back to.
---
--- These entry types are undocumented internals.  Everything here degrades to
--- "no tree available" rather than throwing when the shape is unfamiliar.
local M = {}

local ns = vim.api.nvim_create_namespace('AIAgentTree')

M.view = nil  -- { win, buf, rows, session, path } while the popup is open

----------------------------------------------------------------------------
-- Reading the transcript
----------------------------------------------------------------------------

--- Locate a session's transcript.  Globbed rather than derived: the project
--- directory name is a slugified cwd whose escaping rules are Claude Code's
--- business, while a session id is unique across all of them.
---@param session_id string
---@return string|nil
function M.transcript_path(session_id)
  if not session_id or session_id == '' then return nil end
  local hits = vim.fn.glob(vim.fn.expand('~/.claude/projects/*/' .. session_id .. '.jsonl'), false, true)
  return hits[1]
end

--- Text of an entry's message, tool blocks ignored.
---@param entry table
---@return string
local function text_of(entry)
  local msg = entry.message
  if type(msg) ~= 'table' then return '' end
  local content = msg.content
  if type(content) == 'string' then return content end
  if type(content) ~= 'table' then return '' end
  local out = {}
  for _, block in ipairs(content) do
    if type(block) == 'table' and block.type == 'text' and block.text then
      table.insert(out, block.text)
    end
  end
  return table.concat(out, ' ')
end

--- Is this entry a prompt the user typed?  Prompts are the only nodes worth
--- showing: a tree of every assistant and tool message would be unnavigable.
---
--- `origin.kind` is authoritative where present.  Older transcripts predate it,
--- so fall back to the same envelope sniffing registry.human_text() uses —
--- Claude Code injects command echoes and system reminders as `user` entries.
---@param entry table
---@return boolean
local function is_turn(entry)
  if entry.type ~= 'user' or entry.isSidechain then return false end
  if type(entry.origin) == 'table' and entry.origin.kind then
    return entry.origin.kind == 'human'
  end
  local msg = entry.message
  if type(msg) == 'table' and type(msg.content) == 'table' then
    for _, block in ipairs(msg.content) do
      if type(block) == 'table' and block.type == 'tool_result' then return false end
    end
  end
  local text = vim.trim(text_of(entry))
  return text ~= '' and not text:match('^<')
end

--- An entry's parent, or nil at the root.
---
--- Two traps in one: a JSON `null` decodes to `vim.NIL` (a userdata, which is
--- TRUTHY in Lua, so a plain `if parent then` walks off the top), and nil can
--- never be a table key, so callers key the root under ROOT instead.
---@param entry table|nil
---@return string|nil
local function parent_of(entry)
  local p = entry and entry.parentUuid
  if p == nil or p == vim.NIL or p == '' then return nil end
  return p
end

--- Table key standing in for "no parent".
local ROOT = '\0root'

--- Tokens this entry sent to the model: the whole prompt of one API call,
--- cached or not, which is what `input + cache_creation + cache_read` adds up
--- to.  Returned tokens are deliberately not counted.
---
--- ONE API RESPONSE SPANS SEVERAL ENTRIES.  Claude Code writes an entry per
--- content block (see `apiBlockIndex`) and repeats the *same* `usage` on each,
--- so summing entries double-counts — measured at ~1.8x on a real session (525
--- assistant entries, 289 distinct requests).  `counted` is the caller's
--- per-turn set of requests already charged; a response is charged once.
---@param entry table|nil
---@param counted table<string,true>
---@return number
local function sent_tokens(entry, counted)
  if type(entry) ~= 'table' then return 0 end
  local msg = entry.message
  if type(msg) ~= 'table' then return 0 end
  local u = msg.usage
  if type(u) ~= 'table' then return 0 end
  -- Fall back to the message id and then the entry uuid, so an entry with no
  -- request id still counts once rather than being dropped or charged twice.
  local req = entry.requestId
  if type(req) ~= 'string' then req = msg.id end
  if type(req) ~= 'string' then req = entry.uuid end
  if type(req) ~= 'string' or counted[req] then return 0 end
  counted[req] = true
  local function n(v) return type(v) == 'number' and v or 0 end
  return n(u.input_tokens) + n(u.cache_creation_input_tokens) + n(u.cache_read_input_tokens)
end

--- Parse a transcript into its raw node table plus the recorded active leaf.
---@param path string
---@return { nodes: table<string,table>, order: string[], leaf: string|nil, leaf_pos: number }|nil
function M.parse(path)
  local fh = io.open(path, 'r')
  if not fh then return nil end
  local nodes, order, leaf, leaf_pos = {}, {}, nil, 0
  for line in fh:lines() do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == 'table' then
      -- The last pointer in the file is the live one.  Its position matters as
      -- much as its target: entries appended after it are newer than it is.
      if entry.type == 'last-prompt' and entry.leafUuid then
        leaf = entry.leafUuid
        leaf_pos = #order
      end
      local uuid = entry.uuid
      if uuid and not nodes[uuid] then
        nodes[uuid] = entry
        table.insert(order, uuid)
      end
    end
  end
  fh:close()
  if #order == 0 then return nil end
  return { nodes = nodes, order = order, leaf = leaf, leaf_pos = leaf_pos }
end

--- The entry the conversation actually stands on.
---
--- The `last-prompt` pointer is NOT rewritten for every turn — a resumed session
--- may never write one at all — so it goes stale as soon as new turns are
--- appended, and trusting it blindly reports the branch point as "here" while
--- the turns just added look like an abandoned branch.
---
--- Whichever is newer in file order wins: the pointer when nothing has been
--- appended after it (a jump not yet used), otherwise the last entry in the
--- file, which necessarily belongs to the branch in use.
---@param parsed table
---@return string|nil uuid
function M.head(parsed)
  if not parsed then return nil end
  local leaf = parsed.leaf
  if leaf and parsed.nodes[leaf] and (parsed.leaf_pos or 0) >= #parsed.order then
    return leaf
  end
  return parsed.order[#parsed.order]
end

--- Build the turn tree: one node per typed prompt, with each turn's assistant
--- and tool traffic folded into its summary.
---@param parsed table|nil
---@return table|nil tree { turns, children, parent, meta, active, leaf, root }
function M.build(parsed)
  if not parsed then return nil end
  local nodes, order = parsed.nodes, parsed.order

  local kids = {}
  for _, uuid in ipairs(order) do
    local key = parent_of(nodes[uuid]) or ROOT
    kids[key] = kids[key] or {}
    table.insert(kids[key], uuid)
  end

  local turns, is_t = {}, {}
  for _, uuid in ipairs(order) do
    if is_turn(nodes[uuid]) then
      table.insert(turns, uuid)
      is_t[uuid] = true
    end
  end
  if #turns == 0 then return nil end

  -- Parent turn = nearest ancestor that is itself a turn.
  local parent, children, meta = {}, {}, {}
  for _, uuid in ipairs(turns) do
    local cur = parent_of(nodes[uuid])
    while cur and not is_t[cur] do cur = parent_of(nodes[cur]) end
    parent[uuid] = cur
    local key = cur or ROOT
    children[key] = children[key] or {}
    table.insert(children[key], uuid)

    -- Walk this turn's own subtree (stopping at the next turn) for its summary
    -- and for the entry a jump should land on.
    local tools, files, seen, last = 0, {}, {}, uuid
    local tokens, counted = 0, {}
    local stack = vim.deepcopy(kids[uuid] or {})
    while #stack > 0 do
      local v = table.remove(stack)
      if not is_t[v] then
        last = v
        local msg = nodes[v].message
        tokens = tokens + sent_tokens(nodes[v], counted)
        if type(msg) == 'table' and type(msg.content) == 'table' then
          for _, block in ipairs(msg.content) do
            if type(block) == 'table' and block.type == 'tool_use' then
              tools = tools + 1
              local fp = type(block.input) == 'table' and block.input.file_path
              if fp then
                local base = vim.fn.fnamemodify(fp, ':t')
                if not seen[base] then
                  seen[base] = true
                  table.insert(files, base)
                end
              end
            end
          end
        end
        for _, k in ipairs(kids[v] or {}) do table.insert(stack, k) end
      end
    end
    meta[uuid] = {
      prompt = vim.trim(text_of(nodes[uuid]):gsub('%s+', ' ')),
      time = nodes[uuid].timestamp,
      tools = tools,
      files = files,
      tokens = tokens,
      -- Jumping to a turn means "the conversation through the end of this
      -- turn", so the pointer lands on its last entry, not the prompt itself.
      leaf = last,
    }
  end

  local head = M.head(parsed)

  -- The turn you are *in*: the one whose subtree holds that entry.  It is never
  -- the turn's own last entry, so raw uuid comparison would say "not here".
  local current, cur = nil, head
  while cur do
    if is_t[cur] then current = cur break end
    cur = parent_of(nodes[cur])
  end

  -- The active path: every turn between that entry and the root.
  local active
  active, cur = {}, head
  while cur do
    if is_t[cur] then active[cur] = true end
    cur = parent_of(nodes[cur])
  end
  -- No pointer recorded (or it names a pruned entry): fall back to the newest
  -- turn's ancestry so the popup still shows a sensible "you are here".
  if not next(active) then
    cur = turns[#turns]
    current = cur
    while cur do
      active[cur] = true
      cur = parent[cur]
    end
  end

  return {
    nodes = nodes, turns = turns, parent = parent, children = children,
    meta = meta, active = active, leaf = parsed.leaf, current = current,
    roots = children[ROOT] or {},
  }
end

--- Read a session straight through to a tree.
---@param session_id string
---@return table|nil tree, string|nil path
function M.load(session_id)
  local path = M.transcript_path(session_id)
  if not path then return nil, nil end
  return M.build(M.parse(path)), path
end

----------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------

local function ensure_highlights()
  vim.api.nvim_set_hl(0, 'AIAgentTreeHere',   { link = 'Special' })
  vim.api.nvim_set_hl(0, 'AIAgentTreeOn',     { link = 'Identifier' })
  vim.api.nvim_set_hl(0, 'AIAgentTreeOff',    { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AIAgentTreeGraph',  { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AIAgentTreeDim',    { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AIAgentTreePrompt', { link = 'Normal' })
end

--- Seconds this machine is ahead of UTC, so ISO stamps can be read as local.
---@return number
local function utc_offset()
  local now = os.time()
  ---@diagnostic disable-next-line: param-type-mismatch
  return os.difftime(now, os.time(os.date('!*t', now)))
end

--- Clock time for a turn, widening to weekday and then date as it ages.
---@param stamp string|nil
---@return string
local function when(stamp)
  if type(stamp) ~= 'string' then return '' end
  local y, mo, d, h, mi = stamp:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+)')
  if not y then return '' end
  local t = os.time({ year = tonumber(y) or 1970, month = tonumber(mo) or 1, day = tonumber(d) or 1,
                      hour = tonumber(h) or 0, min = tonumber(mi) or 0, sec = 0 })
  if not t then return '' end
  t = t + utc_offset()
  local diff = os.difftime(os.time(), t)
  local fmt = (diff < 43200 and '%H:%M') or (diff < 604800 and '%a %H:%M') or '%b %d'
  return tostring(os.date(fmt, t))
end

local function truncate(text, width)
  if width < 2 then return '' end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  return vim.fn.strcharpart(text, 0, width - 1) .. '…'
end

--- Token cell: tokens sent, at a glance rather than to the digit.  A turn runs
--- to millions (every agentic step re-sends the conversation), so the exact
--- figure is both wide and useless — 4.8M is the whole message.
---@param n number|nil
---@return string
local function count(n)
  if type(n) ~= 'number' or n <= 0 then return '—' end
  if n >= 1e6 then return string.format('%.1fM', n / 1e6) end
  if n >= 1e4 then return string.format('%.0fk', n / 1e3) end
  if n >= 1e3 then return string.format('%.1fk', n / 1e3) end
  return tostring(math.floor(n))
end

--- Summary cell: what this turn actually did.
---@param m table
---@return string
local function summary(m)
  if #m.files > 0 then
    local shown = table.concat(vim.list_slice(m.files, 1, 2), ', ')
    if #m.files > 2 then shown = shown .. ' +' .. (#m.files - 2) end
    return shown
  end
  if m.tools > 0 then return m.tools .. (m.tools == 1 and ' tool' or ' tools') end
  return '—'
end

--- Display width of the fixed cells to the right of the prompt:
--- time(8) + gap(2) + tokens(6) + gap(2) + summary(22).
local RIGHT_W = 40

--- Build display lines, highlight ranges, and the row→turn mapping.
---
--- Depth does NOT indent: a long linear session would walk off the right edge.
--- Only forks indent, exactly as `git log --graph` keeps its trunk in a fixed
--- gutter.  The active branch always continues the trunk.
---
--- Every turn gets a row.  Nothing is rolled up — the popup scrolls instead.
---
--- Pure, so it is unit tested without a window.
---@param tree table
---@param opts table|nil { width }
---@return string[] lines, table[] highlights, table[] rows  -- rows[i].uuid or nil
function M.render(tree, opts)
  opts = opts or {}
  local width = opts.width or 100
  local lines, hls, rows = {}, {}, {}

  local function emit(uuid, gutter, mark, mark_hl, text_hl)
    local m = tree.meta[uuid]
    -- The token cell is right-aligned by DISPLAY width, not with `%6s`: Lua
    -- pads to a byte count and the em-dash for "nothing sent" is three bytes,
    -- so `%6s` would leave that one row a column short.
    local tok = count(m.tokens)
    tok = string.rep(' ', math.max(0, 6 - vim.fn.strdisplaywidth(tok))) .. tok
    local right = string.format('%8s  %s  %s', when(m.time), tok, truncate(summary(m), 22))
    local lead = gutter .. mark .. ' '
    -- Budget the right block at its FULL width even when this row's summary is
    -- short, so the time and token cells land at the same column on every row.
    -- Sizing from the actual string instead right-aligns the block, and a row
    -- summarised as "—" then shoves both cells 21 columns right — which no
    -- longer merely looks untidy now that one of them is a number.
    local avail = math.max(10, width - vim.fn.strdisplaywidth(lead) - RIGHT_W - 2)
    local prompt = truncate(m.prompt ~= '' and m.prompt or '(empty prompt)', avail)
    local pad = string.rep(' ', math.max(0, avail - vim.fn.strdisplaywidth(prompt)))
    local line = lead .. prompt .. pad .. '  ' .. right

    local i = #lines + 1
    -- Highlight columns are BYTE offsets (extmarks) while padding above is in
    -- DISPLAY width — the marks are multi-byte, single-cell, so the two differ.
    if #gutter > 0 then
      table.insert(hls, { line = i - 1, col = 0, end_col = #gutter, group = 'AIAgentTreeGraph' })
    end
    table.insert(hls, { line = i - 1, col = #gutter, end_col = #gutter + #mark, group = mark_hl })
    local pcol = #lead
    table.insert(hls, { line = i - 1, col = pcol, end_col = pcol + #prompt, group = text_hl })
    table.insert(hls, { line = i - 1, col = #line - #right, end_col = #line, group = 'AIAgentTreeDim' })

    table.insert(lines, line)
    table.insert(rows, { uuid = uuid })
  end

  local function plain(text)
    table.insert(hls, { line = #lines, col = 0, end_col = #text, group = 'AIAgentTreeGraph' })
    table.insert(lines, text)
    table.insert(rows, {})
  end

  --- Render a chain from `uuid` downwards; the active child keeps the trunk.
  local function chain(uuid, gutter)
    -- Collect the run of turns that continue this lane before emitting, so the
    -- tail is known when the run ends (leaf epitaph vs fork).
    local run = {}
    local cur = uuid
    while cur do
      table.insert(run, cur)
      local ch = tree.children[cur] or {}
      if #ch ~= 1 then break end
      cur = ch[1]
    end

    for _, node in ipairs(run) do
      local on = tree.active[node]
      local mark, mhl
      if node == tree.current then mark, mhl = '▶', 'AIAgentTreeHere'
      elseif on then mark, mhl = '●', 'AIAgentTreeOn'
      else mark, mhl = '○', 'AIAgentTreeOff' end
      emit(node, gutter, mark, mhl, on and 'AIAgentTreePrompt' or 'AIAgentTreeOff')
    end

    -- The run ended either at a leaf or at a fork.
    local tail = run[#run]
    local ch = tree.children[tail] or {}
    if #ch == 0 then
      if not tree.active[tail] then
        plain(gutter .. '   ╰ tip · ' .. #run .. (#run == 1 and ' turn' or ' turns'))
      end
      return
    end

    local main
    for _, k in ipairs(ch) do
      if tree.active[k] then main = k break end
    end
    main = main or ch[1]
    for _, k in ipairs(ch) do
      if k ~= main then
        plain(gutter .. '├─╮')
        chain(k, gutter .. '│ ')
      end
    end
    plain(gutter .. '│')
    chain(main, gutter)
  end

  for _, root in ipairs(tree.roots) do chain(root, '') end
  return lines, hls, rows
end

----------------------------------------------------------------------------
-- Jumping
----------------------------------------------------------------------------

--- Decide what selecting a turn means.  Selecting where you already are is a
--- no-op; anything else is a jump, on the active path or off it alike (one
--- mechanism, because repointing the leaf at an ancestor *is* a rewind).
---@param tree table
---@param uuid string|nil
---@return table { kind: 'none'|'noop'|'jump', leaf: string|nil, prompt: string|nil, on_path: boolean }
function M.plan(tree, uuid)
  if not uuid or not tree.meta[uuid] then return { kind = 'none' } end
  if uuid == tree.current then
    return { kind = 'noop', on_path = true }
  end
  local m = tree.meta[uuid]
  return { kind = 'jump', leaf = m.leaf, prompt = m.prompt, on_path = tree.active[uuid] or false }
end

--- A v4-shaped uuid for synthetic entries.
local seeded = false
local function new_uuid()
  if not seeded then
    math.randomseed(tonumber(tostring(vim.uv.hrtime()):sub(-9)) or os.time())
    seeded = true
  end
  local hex = '0123456789abcdef'
  local function h(n)
    local out = {}
    for _ = 1, n do
      local i = math.random(16)
      out[#out + 1] = hex:sub(i, i)
    end
    return table.concat(out)
  end
  return h(8) .. '-' .. h(4) .. '-4' .. h(3) .. '-a' .. h(3) .. '-' .. h(12)
end

--- A minimal entry that can hang off any node without contributing to context.
--- Modelled on the `stop_hook_summary` entries Claude Code writes itself; an
--- existing one from the same transcript is preferred as the template so the
--- shape always matches the version that wrote the file.
---@param nodes table<string,table>
---@return table
local function anchor_template(nodes)
  for _, entry in pairs(nodes) do
    if entry.type == 'system' and entry.subtype == 'stop_hook_summary' then
      local t = vim.deepcopy(entry)
      t.hookCount = 0
      t.hookInfos = {}
      t.hookErrors = {}
      t.hookAdditionalContext = {}
      t.toolUseID = nil
      return t
    end
  end
  return {
    type = 'system', subtype = 'stop_hook_summary', isSidechain = false,
    hookCount = 0, hookInfos = {}, hookErrors = {}, hookAdditionalContext = {},
    preventedContinuation = false, stopReason = '', hasOutput = false,
    level = 'suggestion', userType = 'external', entrypoint = 'cli',
  }
end

--- Move the session's active position to `leaf`.
---
--- The caller MUST have stopped the agent first: a live session writes its own
--- `last-prompt` at the end of every turn and would clobber this one.
---
--- **A pointer is only honoured when it names an actual leaf.** Resume selects
--- among the transcript's leaves; a pointer at a node that still has children
--- is silently ignored and the newest leaf is resumed instead — which is every
--- rewind, so a jump back up the current path would appear to work and then
--- continue the old conversation linearly.
---
--- So when the target has children, a synthetic anchor entry is appended as its
--- child first and the pointer names that. The target becomes a genuine fork
--- point, the resumed session reads the path through it, and its new turns hang
--- off the anchor as a real branch.
---@param path string Transcript path
---@param session_id string
---@param leaf string Target entry uuid
---@param prompt string|nil Prompt text of the target turn (cosmetic)
---@return boolean ok, string|nil err
function M.set_leaf(path, session_id, leaf, prompt)
  local parsed = M.parse(path)
  if not parsed then return false, 'cannot read ' .. path end

  local pointer, anchor = leaf, nil
  local has_children = false
  for _, entry in pairs(parsed.nodes) do
    if parent_of(entry) == leaf then
      has_children = true
      break
    end
  end

  if has_children then
    anchor = anchor_template(parsed.nodes)
    anchor.uuid = new_uuid()
    anchor.parentUuid = leaf
    anchor.timestamp = os.date('!%Y-%m-%dT%H:%M:%S.000Z')
    anchor.sessionId = session_id
    anchor.session_id = session_id
    pointer = anchor.uuid
  end

  local fh, err = io.open(path, 'a')
  if not fh then return false, err or ('cannot write ' .. path) end

  local function write(tbl)
    local ok, encoded = pcall(vim.json.encode, tbl)
    if not ok then return false end
    fh:write(encoded .. '\n')
    return true
  end

  if anchor and not write(anchor) then
    fh:close()
    return false, 'cannot encode anchor entry'
  end
  if not write({
        type = 'last-prompt',
        lastPrompt = prompt or '',
        leafUuid = pointer,
        sessionId = session_id,
      }) then
    fh:close()
    return false, 'cannot encode leaf pointer'
  end
  fh:close()
  return true
end

----------------------------------------------------------------------------
-- A small menu
----------------------------------------------------------------------------

--- Pick one of a few options in a floating menu.
---
--- Deliberately NOT `vim.ui.select`: a user's select handler is often a
--- filtering picker (telescope-ui-select puts a text input above the list,
--- where typing filters rather than choosing, and <CR> on no match cancels
--- silently), which is the wrong shape for a two-or-three-way decision.  The
--- builtin `vim.ui.input`/`vim.ui.select` cmdline prompts are worse still next
--- to a busy agent terminal — easy to miss entirely, so an action looks like a
--- dead keybinding.  This matches the plugin's other popups instead.
---
--- Number keys pick directly, <CR> takes the row under the cursor, q/<Esc>
--- cancel.  `on_choice` is called with the index, or nil when cancelled.
---@param items string[]
---@param opts table|nil { title: string|nil }
---@param on_choice fun(idx: integer|nil)
function M.menu(items, opts, on_choice)
  opts = opts or {}
  if #items == 0 then return on_choice(nil) end

  local lines = {}
  for i, item in ipairs(items) do
    lines[i] = string.format('  %d. %s  ', i, item)
  end
  local title = opts.title and (' ' .. opts.title .. ' ') or nil
  local width = title and vim.fn.strdisplaywidth(title) or 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.min(width + 1, vim.o.columns - 4)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'aiagentmenu', { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = #lines,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  })
  vim.api.nvim_set_option_value('cursorline', true, { win = win })

  -- One-shot: the WinClosed fallback must not fire after a real choice.
  local answered = false
  local function finish(idx)
    if answered then return end
    answered = true
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    -- Scheduled so the caller runs with the menu gone and focus settled.
    vim.schedule(function() on_choice(idx) end)
  end

  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for i = 1, math.min(#items, 9) do
    map(tostring(i), function() finish(i) end)
  end
  map('<CR>', function() finish(vim.api.nvim_win_get_cursor(win)[1]) end)
  map('q', function() finish(nil) end)
  map('<Esc>', function() finish(nil) end)

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() finish(nil) end,
  })
end

----------------------------------------------------------------------------
-- The popup
----------------------------------------------------------------------------

function M.close_view()
  local v = M.view
  M.view = nil
  if not v then return end
  if v.win and vim.api.nvim_win_is_valid(v.win) then
    pcall(vim.api.nvim_win_close, v.win, true)
  end
  if v.buf and vim.api.nvim_buf_is_valid(v.buf) then
    pcall(vim.api.nvim_buf_delete, v.buf, { force = true })
  end
end

--- Show the history tree for a session in a floating window.
--- <CR> jumps to the turn under the cursor, f forks a new agent from it,
--- q closes.
---@param opts table|nil { session }
function M.show(opts)
  opts = opts or {}
  M.close_view()

  local aiagent = require('aiagent')
  local session = opts.session
  if not session then
    local current = aiagent.current_session()
    session = current and current.id
  end
  if not session then
    vim.notify('No live agent session to show history for', vim.log.levels.WARN)
    return
  end

  local tree, path = M.load(session)
  if not tree then
    vim.notify('No history tree available for session ' .. session, vim.log.levels.WARN)
    return
  end

  ensure_highlights()
  -- 118, not 110: the token cell costs 8 columns and the prompt column should
  -- not pay for it.  Still bounded by the screen, so a narrow window just
  -- squeezes the prompt as before.
  local width = math.min(118, vim.o.columns - 8)
  local lines, hls, rows = M.render(tree, { width = width })
  local title = ' History  (<CR> jump · f fork · q close) '

  local w = vim.fn.strdisplaywidth(title)
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  w = math.min(w + 2, vim.o.columns - 4)
  -- Tall enough for the whole history, capped at 60 rows — or at 80% of the
  -- screen when the screen cannot spare 60.  Anything longer scrolls.
  local height = math.max(1, math.min(#lines, math.min(60, math.floor(vim.o.lines * 0.8))))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.col,
      { end_col = h.end_col, hl_group = h.group })
  end
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'aiagenttree', { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    width = w,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  })
  vim.api.nvim_set_option_value('cursorline', true, { win = win })

  M.view = { win = win, buf = buf, rows = rows, tree = tree, session = session, path = path }

  -- Start on the current position, parked at the bottom of the viewport, so a
  -- history taller than the window scrolls back into the past from where you are.
  for i, row in ipairs(rows) do
    if row.uuid and row.uuid == tree.current then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
      pcall(vim.api.nvim_win_call, win, function() vim.cmd('normal! zb') end)
      break
    end
  end

  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('q', M.close_view)
  map('<Esc>', M.close_view)
  map('<CR>', function()
    local v = M.view
    if not v then return end
    local row = v.rows[vim.api.nvim_win_get_cursor(v.win)[1]]
    local plan = M.plan(v.tree, row and row.uuid)
    if plan.kind == 'none' then return end
    local target_path, target_session = v.path, v.session
    M.close_view()
    if plan.kind == 'noop' then
      vim.notify('Already at that point in the history', vim.log.levels.INFO)
      return
    end
    aiagent.history_jump({
      session = target_session,
      path = target_path,
      leaf = plan.leaf,
      prompt = plan.prompt,
    })
  end)

  -- Fork a new agent from the node under the cursor, leaving this agent alone.
  -- Unlike a jump, the current node is a legitimate target: forking from where
  -- you are is how you branch off the conversation you are having.
  map('f', function()
    local v = M.view
    if not v then return end
    local row = v.rows[vim.api.nvim_win_get_cursor(v.win)[1]]
    if not row or not row.uuid then return end
    local m = v.tree.meta[row.uuid]
    local from = { session = v.session, path = v.path, leaf = m.leaf, prompt = m.prompt }
    M.close_view()
    -- Prompt on the NEXT tick, out of insert mode.  Closing the float returns
    -- focus to the agent terminal, whose BufEnter autocmd puts it back into
    -- insert mode; asking in that same tick leaves the builtin vim.ui.input's
    -- cmdline prompt unrendered, silently swallowing the keys typed at it.
    vim.schedule(function()
      vim.cmd('stopinsert')
      aiagent.history_fork(from)
    end)
  end)

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() M.view = nil end,
  })
end

M._is_turn = is_turn
M._when = when

return M
