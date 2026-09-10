---@diagnostic disable: undefined-global
-- aiagent.prompthistory — browse the prompt -> code-change history captured by
-- hooks/prompt_snapshot.sh.
--
-- Layout (opened in its own tabpage so the Claude terminal in M.win is never
-- disturbed; closing the tab returns you to the chat):
--
--   +---------+-----------------+-----------------+
--   | prompts |  before         |  after          |   native :diffthis pair
--   | (list)  |                 |                 |
--   +---------+-----------------+-----------------+
--   | changed |  full prompt text                 |
--   | files   |                                   |
--   +---------+-----------------------------------+
--
-- Move the cursor in the prompt list to pick a prompt; move it in the files
-- list to pick a file. Diffs are reconstructed from the stored git trees with
-- `git show <tree>:<path>` (never `git diff` for content — that would invoke a
-- configured external difftool).

local M = {}

local gitdiff = require('aiagent.gitdiff')

M.state = nil  -- nil when closed; a table while the viewer tab is open

-- Sentinel embedded as the first line of a primer built by M.build_primer. When
-- the user submits the primer, hooks/prompt_snapshot.sh sees this token in the
-- prompt and skips recording the turn (we are replaying history, not making it).
-- KEEP IN SYNC with PRIMER_MARKER in hooks/prompt_snapshot.sh.
M.PRIMER_MARKER = "<!-- AIAGENT_PROMPT_HISTORY_PRIMER: loaded from history; do not re-record -->"

-- ---------------------------------------------------------------------------
-- Data access
-- ---------------------------------------------------------------------------

--- Absolute path to the shared .prompt-history dir for the repo containing dir.
--- Anchored on the common git dir so every worktree resolves to one location.
---@param dir string  A path inside the repo (or worktree)
---@return string|nil hist_dir, string|nil main_root
local function history_dir(dir)
  local common = vim.fn.systemlist(
    { "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir" })[1]
  if vim.v.shell_error ~= 0 or not common or common == "" then return nil, nil end
  local main_root = vim.fn.fnamemodify(common, ":h")
  return main_root .. "/.prompt-history", main_root
end

--- Read and parse one session's JSONL log into a list of records.
---@param hist_dir string
---@param session string
---@return table[] records (chronological order, as written)
local function read_session(hist_dir, session)
  local path = hist_dir .. "/sessions/" .. session .. ".jsonl"
  local records = {}
  local f = io.open(path, "r")
  if not f then return records end
  for line in f:lines() do
    if line ~= "" then
      local ok, rec = pcall(vim.fn.json_decode, line)
      if ok and type(rec) == "table" then table.insert(records, rec) end
    end
  end
  f:close()
  return records
end

--- List sessions for the repo containing dir, newest first.
---@param dir string
---@return table[] sessions  { id, started, turns, first_prompt }
function M.list_sessions(dir)
  local hist_dir = history_dir(dir or vim.fn.getcwd())
  if not hist_dir then return {} end
  local files = vim.fn.glob(hist_dir .. "/sessions/*.jsonl", false, true)
  local sessions = {}
  for _, file in ipairs(files) do
    local id = vim.fn.fnamemodify(file, ":t:r")
    local recs = read_session(hist_dir, id)
    if #recs > 0 then
      table.insert(sessions, {
        id = id,
        started = recs[1].started or "?",
        turns = #recs,
        first_prompt = recs[1].prompt or "",
        mtime = vim.fn.getftime(file),
      })
    end
  end
  table.sort(sessions, function(a, b) return a.mtime > b.mtime end)
  return sessions
end

--- Read the active-session override for the repo containing dir, or nil if unset.
---@param dir string
---@return string|nil
function M.active_session(dir)
  local hist_dir = history_dir(dir or vim.fn.getcwd())
  if not hist_dir then return nil end
  local path = hist_dir .. "/active-session"
  local f = io.open(path, "r")
  if not f then return nil end
  local id = f:read("*l")
  f:close()
  return (id and id ~= "") and id or nil
end

--- Set or clear the active-session override.
---@param dir string
---@param session_id string|nil  nil to clear (revert to default)
function M.set_active_session(dir, session_id)
  local hist_dir = history_dir(dir or vim.fn.getcwd())
  if not hist_dir then return end
  local path = hist_dir .. "/active-session"
  if session_id then
    vim.fn.mkdir(hist_dir, "p")
    local f = io.open(path, "w")
    if f then f:write(session_id .. "\n"); f:close() end
  else
    os.remove(path)
  end
end

--- File contents at a given tree, as lines. Empty list if the path is absent
--- (added/deleted side) or the tree-ish does not resolve.
---@param root string  git root to run in
---@param tree string  tree SHA
---@param path string|nil
---@return string[]
local function git_show(root, tree, path)
  return gitdiff.show(root, tree, path)
end

--- Changed files between two trees, with the path on each side resolved so we
--- can reconstruct content even across renames.
---@param root string
---@param before string
---@param after string
---@return table[]  { status, path, before_path, after_path }
local function changed_files(root, before, after)
  return gitdiff.changed_files(root, before, after)
end

--- Unified diff for one turn, between its before/after trees. Uses
--- --no-ext-diff so a user's external difftool cannot hijack the output (the
--- same safety rule as content reconstruction elsewhere in this module).
---@param root string  git root holding the shared object store
---@param before string|nil
---@param after string|nil
---@return string[]
local function turn_diff(root, before, after)
  return gitdiff.unified(root, before, after, nil, 3)
end

--- Build a context primer for a session: its prompts (USER-side only), each
--- annotated with the files it changed and the unified diff it produced. Meant
--- to be typed into a running agent to re-orient it on prior intent. It is NOT
--- a conversation replay — assistant replies, reasoning, and tool calls are not
--- captured — which is why this is deliberately not called "resume".
---@param session string
---@param dir string  any path inside the repo (resolves the shared history dir)
---@return string|nil text, string|nil err
function M.build_primer(session, dir)
  local hist_dir, main_root = history_dir(dir or vim.fn.getcwd())
  if not hist_dir or not main_root then return nil, "not in a git repo" end
  local recs = read_session(hist_dir, session)
  if #recs == 0 then return nil, "no records for session " .. session end

  local parts = {}
  -- Sentinel: this prompt is rebuilt FROM the capture log, so the capture hook
  -- (prompt_snapshot.sh) must NOT record it again. The hook greps the submitted
  -- prompt text for this exact token — keep the two in sync.
  table.insert(parts, M.PRIMER_MARKER)
  table.insert(parts, "# Context from a previous session")
  table.insert(parts, "")
  table.insert(parts, string.format(
    "Below are the %d prompts from a previous prompt-history session (%s), in order. "
    .. "These are the USER's prompts only — the assistant's replies, reasoning, and "
    .. "tool calls were not captured, so this is a re-orientation aid, not a "
    .. "conversation replay. Each prompt is annotated with the files it changed and "
    .. "the diff it produced. Use it to understand what was being worked on and why; "
    .. "the files currently on disk remain the source of truth.",
    #recs, session))
  table.insert(parts, "")

  for i, rec in ipairs(recs) do
    local prompt = (rec.prompt or ""):gsub("%s+$", "")
    table.insert(parts, string.format("## Turn %d", i))
    table.insert(parts, "")
    table.insert(parts, "Prompt:")
    table.insert(parts, prompt ~= "" and prompt or "(empty)")
    table.insert(parts, "")

    local files = changed_files(main_root, rec.before_tree, rec.after_tree)
    if #files == 0 then
      table.insert(parts, "Changed files: (none)")
    else
      table.insert(parts, "Changed files:")
      for _, fl in ipairs(files) do
        table.insert(parts, string.format("  %s  %s", fl.status, fl.path))
      end
      local diff = turn_diff(main_root, rec.before_tree, rec.after_tree)
      if #diff > 0 then
        table.insert(parts, "")
        table.insert(parts, "```diff")
        for _, l in ipairs(diff) do table.insert(parts, l) end
        table.insert(parts, "```")
      end
    end
    table.insert(parts, "")
  end

  return table.concat(parts, "\n"), nil
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Build a fresh scratch buffer holding lines, with filetype inferred from path.
local function make_diff_buf(lines, path)
  return gitdiff.make_buf(lines, path)
end

--- Render the before/after diff for the currently selected file.
local function render_diff()
  local s = M.state
  local file = s.files[s.file_idx]
  local rec = s.records[s.idx]

  local before_lines, after_lines, bpath, apath
  if file then
    before_lines = git_show(s.git_root, rec.before_tree, file.before_path)
    after_lines  = git_show(s.git_root, rec.after_tree, file.after_path)
    bpath, apath = file.before_path, file.after_path
  else
    before_lines = { "(no files changed by this prompt)" }
    after_lines  = { "(no files changed by this prompt)" }
  end

  if not gitdiff.show_pair(s.wins,
        { lines = before_lines, path = bpath },
        { lines = after_lines,  path = apath }) then
    return
  end

  local pos = file and string.format(" (%d/%d)", s.file_idx, #s.files) or ""
  vim.wo[s.wins.before].winbar = "BEFORE  " .. (bpath or "—")
  vim.wo[s.wins.after].winbar  = "AFTER  " .. (apath or "—") .. pos
end

--- Render the changed-files list for the current prompt; place cursor on the
--- currently selected file.
local function render_files()
  local s = M.state
  if not vim.api.nvim_win_is_valid(s.wins.files) then return end
  local buf = vim.api.nvim_win_get_buf(s.wins.files)
  local lines = {}
  if #s.files == 0 then
    lines = { "(no files changed)" }
  else
    for _, f in ipairs(s.files) do
      table.insert(lines, string.format("%s  %s", f.status, f.path))
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if #s.files > 0 then
    pcall(vim.api.nvim_win_set_cursor, s.wins.files, { s.file_idx, 0 })
  end
end

--- Render the prompt list; place cursor on the current prompt.
local function render_list()
  local s = M.state
  if not vim.api.nvim_win_is_valid(s.wins.list) then return end
  local buf = vim.api.nvim_win_get_buf(s.wins.list)
  local lines = {}
  for i, rec in ipairs(s.records) do
    local prompt = (rec.prompt or ""):gsub("\n", " ")
    table.insert(lines, string.format("%3d [%2s] %s", i, rec.changed_files or "?", prompt))
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_win_set_cursor, s.wins.list, { s.idx, 0 })
end

--- Render the full prompt text for the currently selected prompt.
local function render_prompt_detail()
  local s = M.state
  if not vim.api.nvim_win_is_valid(s.wins.prompt) then return end
  local buf = vim.api.nvim_win_get_buf(s.wins.prompt)
  local rec = s.records[s.idx]
  local text = rec and rec.prompt or ""
  local lines = vim.split(text, "\n", { plain = true })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Load prompt i: compute its changed files, reset to the first file, redraw.
local function load_prompt(i)
  local s = M.state
  if i < 1 or i > #s.records then return end
  s.idx = i
  local rec = s.records[i]
  s.files = changed_files(s.git_root, rec.before_tree, rec.after_tree)
  s.file_idx = 1
  render_files()
  render_diff()
  render_prompt_detail()
end

-- ---------------------------------------------------------------------------
-- Navigation (exposed for keymaps)
-- ---------------------------------------------------------------------------

function M.next_file()
  local s = M.state; if not s or #s.files == 0 then return end
  s.file_idx = math.min(s.file_idx + 1, #s.files)
  render_files(); render_diff()
end

function M.prev_file()
  local s = M.state; if not s or #s.files == 0 then return end
  s.file_idx = math.max(s.file_idx - 1, 1)
  render_files(); render_diff()
end

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

--- Create a scratch buffer for the list/files panes.
local function make_panel_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

-- Key-combo cheatsheet shown in the instructions pane. The return-to-chat key
-- comes first: it is the one a human most needs and most easily forgets.
local INSTRUCTIONS = {
  "PROMPT HISTORY",
  "q       back to chat (then resume typing)",
  "j / k    move between prompts",
  "]f / [f  next / prev changed file",
}

--- Build the layout in a new tabpage:
---   left column (30%): instructions, prompts, files (stacked top→bottom)
---   right column top (70%): before | after diff
---   right column bottom: full prompt text
--- Returns the window handles.
local function build_layout()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()

  -- The initial window becomes the right-hand diff area; carve the left column
  -- off it on the far left.
  local diff_area = vim.api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  local instructions = vim.api.nvim_get_current_win()

  -- Stack prompts then files below the instructions, all within the left column.
  vim.cmd("belowright split")
  local list = vim.api.nvim_get_current_win()
  vim.cmd("belowright split")
  local files = vim.api.nvim_get_current_win()

  -- Right column: split into top (diff) and bottom (prompt detail).
  vim.api.nvim_set_current_win(diff_area)
  vim.cmd("belowright split")
  local prompt = vim.api.nvim_get_current_win()

  -- Top right: split the diff area into before | after.
  vim.api.nvim_set_current_win(diff_area)
  local before = diff_area
  vim.cmd("rightbelow vsplit")
  local after = vim.api.nvim_get_current_win()

  -- Buffers + per-window options.
  vim.api.nvim_win_set_buf(instructions, make_panel_buf("prompt-history://help"))
  vim.api.nvim_win_set_buf(list, make_panel_buf("prompt-history://prompts"))
  vim.api.nvim_win_set_buf(files, make_panel_buf("prompt-history://files"))
  vim.api.nvim_win_set_buf(prompt, make_panel_buf("prompt-history://prompt"))

  for _, w in ipairs({ instructions, list, files }) do
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].winfixwidth = true
  end
  vim.wo[list].cursorline = true
  vim.wo[list].winbar = "PROMPTS"
  vim.wo[files].cursorline = true
  vim.wo[files].winbar = "CHANGED FILES"
  vim.wo[prompt].number = false
  vim.wo[prompt].relativenumber = false
  vim.wo[prompt].wrap = true
  vim.wo[prompt].linebreak = true
  vim.wo[prompt].winbar = "PROMPT"

  -- Sizing: left column 30% of screen; instructions and files fixed height so
  -- the prompt list absorbs the slack. Prompt detail fixed at 8 lines.
  vim.api.nvim_win_set_width(instructions, math.floor(vim.o.columns * 0.30))
  vim.api.nvim_win_set_height(instructions, #INSTRUCTIONS)
  vim.wo[instructions].winfixheight = true
  vim.api.nvim_win_set_height(files, 10)
  vim.wo[files].winfixheight = true
  vim.api.nvim_win_set_height(prompt, 8)
  vim.wo[prompt].winfixheight = true

  -- Equalize the free dimensions: before|after to the same width and the
  -- prompt list to the leftover height. winfixwidth/winfixheight above keep the
  -- left column at 30% and the instructions/files panes at their fixed heights.
  vim.cmd("wincmd =")

  return { tab = tab, instructions = instructions, list = list,
           before = before, after = after, files = files, prompt = prompt }
end

--- Fill the instructions pane (static content).
local function render_instructions(win)
  local buf = vim.api.nvim_win_get_buf(win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, INSTRUCTIONS)
  vim.bo[buf].modifiable = false
end

--- Set buffer-local keymaps on a viewer panel buffer.
local function set_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", function() M.close() end, opts)
  vim.keymap.set("n", "]f", function() M.next_file() end, opts)
  vim.keymap.set("n", "[f", function() M.prev_file() end, opts)
end

-- ---------------------------------------------------------------------------
-- Public entry points
-- ---------------------------------------------------------------------------

--- Open the viewer for a session.
---@param session string  session id whose log to show
---@param git_root string  repo root to run git in (object store is shared across worktrees)
---@param dir string  a path inside the repo, used to locate .prompt-history
function M.open_for(session, git_root, dir)
  local hist_dir = history_dir(dir)
  if not hist_dir then
    vim.notify("prompt-history: not in a git repo", vim.log.levels.ERROR)
    return
  end
  local records = read_session(hist_dir, session)
  if #records == 0 then
    vim.notify("prompt-history: no records for session " .. session, vim.log.levels.WARN)
    return
  end

  local source_win = vim.api.nvim_get_current_win()
  local wins = build_layout()

  M.state = {
    session = session,
    git_root = git_root,
    records = records,
    idx = #records,        -- start on the most recent prompt
    file_idx = 1,
    files = {},
    wins = wins,
    source_win = source_win,
    guard = false,         -- re-entrancy guard for CursorMoved
  }

  for _, w in pairs({ wins.instructions, wins.list, wins.before, wins.after, wins.files, wins.prompt }) do
    set_keymaps(vim.api.nvim_win_get_buf(w))
  end
  render_instructions(wins.instructions)

  -- CursorMoved in the list selects a prompt; in the files pane selects a file.
  local group = vim.api.nvim_create_augroup("AIAgentPromptHistory", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      local s = M.state; if not s or s.guard then return end
      local w = vim.api.nvim_get_current_win()
      if w == s.wins.list then
        local row = vim.api.nvim_win_get_cursor(w)[1]
        if row ~= s.idx then
          s.guard = true
          load_prompt(row)
          s.guard = false
        end
      elseif w == s.wins.files then
        local row = vim.api.nvim_win_get_cursor(w)[1]
        if #s.files > 0 and row ~= s.file_idx then
          s.guard = true
          s.file_idx = math.min(row, #s.files)
          render_diff()
          s.guard = false
        end
      end
    end,
  })

  render_list()
  load_prompt(#records)
  vim.api.nvim_set_current_win(wins.list)
end

--- Switch the open viewer to a different session, reusing its windows so the
--- user's focus and tab are preserved. No-op (returns false) when the viewer is
--- closed or already showing this session; warns and keeps the current view
--- when the new session has no records.
---@param session string
---@return boolean switched
function M.reload(session)
  local s = M.state
  if not s or session == s.session then return false end
  local hist_dir = history_dir(s.git_root)
  local records = hist_dir and read_session(hist_dir, session) or {}
  if #records == 0 then
    vim.notify("prompt-history: no records for session " .. session, vim.log.levels.WARN)
    return false
  end
  s.session = session
  s.records = records
  s.idx = #records
  s.file_idx = 1
  s.files = {}
  render_list()
  load_prompt(#records)
  return true
end

--- Close the viewer tab and return to the chat window.
function M.close()
  local s = M.state
  if not s then return end
  M.state = nil
  pcall(vim.api.nvim_del_augroup_by_name, "AIAgentPromptHistory")
  if s.wins.tab and vim.api.nvim_tabpage_is_valid(s.wins.tab) then
    -- Close every window in the viewer tab.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(s.wins.tab)) do
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if s.source_win and vim.api.nvim_win_is_valid(s.source_win) then
    pcall(vim.api.nvim_set_current_win, s.source_win)
  end
end

return M
