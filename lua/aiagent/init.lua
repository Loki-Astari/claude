---@diagnostic disable: undefined-global
local M = {}

-- Default configuration
M.config = {
  width = 0.4,         -- Width as percentage (0-1) or columns (>1)
  auto_resize = true,  -- Re-apply the agent column's screen share when the terminal is resized
  min_width = 20,      -- Columns the agent column (and the rest of the layout) may never drop below
  default_agent = "claude", -- Symbolic agent name to use on startup
  auto_send_context = false, -- Automatically send new buffer context when entering terminal
  agent_startup_delay = 1500, -- Milliseconds to wait before sending /color command on startup
  show_header = true,         -- Show the keybind instruction header above the terminal
  scroll_start_line = 9,      -- Line to jump to when first entering scroll mode
  idle_timeout_ms = 8000,     -- ms of silence after activity before flagging (0 = disabled)
  idle_notify     = false,    -- also fire vim.notify when flagging attention
  mcp_max_width   = 35,       -- max statusline columns for MCP display before scrolling
  mcp_scroll      = true,     -- scroll MCP display when wider than mcp_max_width
  -- Keys inside the PR review viewer (|aiagent-pr-review|).  Set any to false
  -- to leave it unmapped.  These deliberately avoid `gc`: Neovim 0.10+ maps
  -- `gc`/`gcc` as the built-in comment operator, and in a read-only diff pane
  -- that errors with E21 instead of doing anything useful.  `]c`/`[c` are left
  -- alone too — in a diff they are next/previous change, which is worth more
  -- here than another binding of ours.
  pr_keys = {
    comment      = 'ca',   -- comment on the cursor line (visual: on the selection)
    comment_file = 'cf',   -- comment on the whole file
    summary      = 'cr',   -- edit the review summary
    submit       = 'cs',   -- submit the review
    next_file    = ']f',
    prev_file    = '[f',
    next_comment = ']r',
    prev_comment = '[r',
    accept       = 'a',    -- comment list only
    delete       = 'd',    -- comment list only
    edit         = 'e',    -- comment list only
    close        = 'q',
  },
  -- function(entry) -> string[]|nil : command that raises another instance's
  -- terminal pane, overriding the built-in tmux/iTerm2/kitty/wezterm detection.
  -- Return nil to fall through to the built-in handling.
  focus_cmd       = nil,
  -- Must be colours Claude Code itself accepts: the plugin injects "/color <name>"
  -- at startup, and an unknown name is rejected by the agent.
  colors = { "red", "blue", "orange", "green", "yellow", "pink", "cyan", "purple" },
  -- Map of symbolic names to CLI executables. Extend this in setup() for custom agents.
  known_agents = {
    claude  = "claude",        -- Anthropic Claude Code
    cursor  = "cursor-agent",  -- Cursor AI
    aider   = "aider",         -- Aider (aider-chat)
    gemini  = "gemini",        -- Google Gemini CLI
    codex   = "codex",         -- OpenAI Codex CLI
    goose   = "goose",         -- Block's Goose agent
    plandex = "plandex",       -- Plandex
    cody    = "cody",          -- Sourcegraph Cody
    amp     = "amp",           -- Amp
  },
}

-- Track agents and windows
M.agents = {}           -- { name = { buf, job_id, scroll_mode, scroll_pos, agent_type, command, sent_files, color, worktree, git_root, slug, attention_needed, last_output_time, line_count_at_visit, task, started } }
M.current_agent = nil   -- name of active agent
M.current_agent_type = "claude"  -- symbolic agent name used for new agents
M.win = nil             -- shared terminal window
M.header_buf = nil      -- shared header buffer
M.header_win = nil      -- shared header window
M.prev_win = nil        -- Window to return to when exiting terminal mode
M.color_index = 0       -- Counter for cycling through colors
M.idle_timer = nil      -- repeating timer for idle attention detection

--- Get file paths of all open buffers (excluding special buffers)
---@return string[] List of absolute file paths
local function get_open_buffer_files()
  local files = {}
  local seen = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
      -- Only include normal file buffers (not terminals, help, etc.)
      if buftype == "" then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" and not seen[name] then
          -- Check if it's an actual file (not a directory or special path)
          local stat = vim.uv.fs_stat(name)
          if stat and stat.type == "file" then
            seen[name] = true
            table.insert(files, name)
          end
        end
      end
    end
  end
  return files
end

--- Get list of open buffer files not yet sent to an agent
---@param agent_name string Agent name
---@return string[] List of new file paths
local function get_unsent_buffer_files(agent_name)
  local agent = M.agents[agent_name]
  if not agent then
    return {}
  end

  local sent = agent.sent_files or {}
  local all_files = get_open_buffer_files()
  local new_files = {}

  for _, file in ipairs(all_files) do
    if not sent[file] then
      table.insert(new_files, file)
    end
  end

  return new_files
end

--- Send text to the terminal (types it as if user typed it)
---@param agent_name string Agent name
---@param text string Text to send
---@return boolean success
local function send_to_terminal(agent_name, text)
  local agent = M.agents[agent_name]
  if not agent or not agent.job_id then
    return false
  end
  local ok, result = pcall(vim.fn.chansend, agent.job_id, text)
  if not ok or result == 0 then
    vim.notify("Failed to send to agent '" .. agent_name .. "' terminal", vim.log.levels.WARN)
    return false
  end
  return true
end

--- Get the current visual selection
---@return string[] lines, string filetype
local function get_visual_selection()
  -- Get the visual selection marks
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  -- Get the lines
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

  -- Handle partial line selection for visual mode (not line-wise)
  local mode = vim.fn.visualmode()
  if mode == "v" then
    -- Character-wise visual mode
    local start_col = start_pos[3]
    local end_col = end_pos[3]
    if #lines == 1 then
      lines[1] = string.sub(lines[1], start_col, end_col)
    else
      lines[1] = string.sub(lines[1], start_col)
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end
  end
  -- For 'V' (line-wise) and '<C-v>' (block), we keep full lines

  local filetype = vim.bo.filetype
  return lines, filetype
end

--- Force cleanup of a single agent
---@param name string Agent name to clean up
local function cleanup_agent(name)
  local agent = M.agents[name]
  if not agent then return end

  -- Stop the job first
  if agent.job_id ~= nil then
    local job = agent.job_id
    agent.job_id = nil  -- Clear first to prevent on_exit callback issues
    -- Close the channel (more reliable than jobstop for terminals)
    pcall(vim.fn.chanclose, job)
    pcall(vim.fn.jobstop, job)
    -- Wait for the job to actually terminate
    pcall(vim.fn.jobwait, { job }, 500)
  end

  -- Delete buffer
  if agent.buf ~= nil and vim.api.nvim_buf_is_valid(agent.buf) then
    pcall(vim.api.nvim_buf_delete, agent.buf, { force = true, unload = false })
  end

  -- Withdraw from the cross-instance registry.  A crash skips this; read_all()
  -- prunes by process liveness, so nothing is left stranded either way.
  pcall(function() require('aiagent.registry').unpublish(name) end)

  M.agents[name] = nil
end

--- Force cleanup of all agents and windows
local function force_cleanup()
  -- Stop the idle attention timer
  if M.idle_timer then
    M.idle_timer:stop()
    M.idle_timer:close()
    M.idle_timer = nil
  end

  -- Clean up all agents
  for name, _ in pairs(M.agents) do
    cleanup_agent(name)
  end
  M.agents = {}
  M.current_agent = nil
  M._hidden_win_width = nil
  M._hidden_win_height = nil
  M._hidden_columns = nil
  M._width_ratio = nil

  -- Close windows
  if M.win ~= nil and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_close, M.win, true)
    M.win = nil
  end
  if M.header_win ~= nil and vim.api.nvim_win_is_valid(M.header_win) then
    pcall(vim.api.nvim_win_close, M.header_win, true)
    M.header_win = nil
  end

  -- Delete header buffer
  if M.header_buf ~= nil and vim.api.nvim_buf_is_valid(M.header_buf) then
    pcall(vim.api.nvim_buf_delete, M.header_buf, { force = true, unload = false })
    M.header_buf = nil
  end
end

--- Return true if child is exactly parent or is directly under it.
--- Guards against false positives where parent is a byte-prefix of an unrelated sibling
--- (e.g. "/tmp/nvim-agent-foo" must not match "/tmp/nvim-agent-foobar/file").
---@param child string Absolute path (no trailing slash)
---@param parent string Absolute path (no trailing slash)
---@return boolean
local function is_under(child, parent)
  if #child < #parent then return false end
  if child:sub(1, #parent) ~= parent then return false end
  return #child == #parent
    or parent:sub(-1) == "/"  -- parent already ends with separator (e.g. root "/")
    or child:sub(#parent + 1, #parent + 1) == "/"
end

--- Set the active agent type for subsequent AgentOpen calls
---@param symbolic_name string Symbolic agent name (e.g. "claude", "cursor", "aider")
function M.set(symbolic_name)
  local cmd = M.config.known_agents[symbolic_name]
  if not cmd then
    local available = table.concat(vim.tbl_keys(M.config.known_agents), ", ")
    vim.notify(
      "Unknown agent '" .. symbolic_name .. "'. Known agents: " .. available,
      vim.log.levels.WARN
    )
    return
  end
  M.current_agent_type = symbolic_name
  vim.notify("Agent set to: " .. symbolic_name .. " (" .. cmd .. ")", vim.log.levels.INFO)
end

--- Set the color of the current agent and notify the CLI
---@param color string Color name (must be in M.config.colors)
function M.set_color(color)
  local name = M.current_agent
  if not name then
    vim.notify("No agent active", vim.log.levels.WARN)
    return
  end
  local agent = M.agents[name]
  if not agent then
    vim.notify("No agent active", vim.log.levels.WARN)
    return
  end
  local known = false
  for _, c in ipairs(M.config.colors) do
    if c == color then known = true; break end
  end
  if not known then
    vim.notify("Unknown color '" .. color .. "'. Known: " .. table.concat(M.config.colors, ", "), vim.log.levels.WARN)
    return
  end
  agent.color = color
  if agent.job_id then
    pcall(vim.fn.chansend, agent.job_id, "/color " .. color .. "\r")
  end
  update_header()
  vim.notify("Agent color set to: " .. color, vim.log.levels.INFO)
end

-- Forward declarations for functions defined later in the file.
-- M.setup() references these in closures (ColorScheme autocmd, idle timer);
-- declaring them here lets Lua capture them as upvalues rather than globals.
local setup_tab_highlights
local update_winbar

--- Setup the plugin with user options
---@param opts table|nil Configuration options
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M.current_agent_type = M.config.default_agent

  -- Single augroup for all plugin autocmds — cleared on each setup() call so
  -- reloading the module (`:lua package.loaded['aiagent'] = nil`) never
  -- accumulates duplicate handlers.
  local augroup = vim.api.nvim_create_augroup("AIAgent", { clear = true })

  -- Keep the agent column proportional across terminal resizes (e.g. unplugging
  -- an external monitor). VimResized re-applies the remembered share; WinResized
  -- records the user's own adjustments, and is ignored when the screen width
  -- changed because that resize is Neovim's redistribution, not the user's.
  if M.config.auto_resize then
    M._last_columns = vim.o.columns

    vim.api.nvim_create_autocmd("VimResized", {
      group = augroup,
      callback = function() M.resize() end,
      desc = "Keep the AIAgent column proportional when the terminal is resized",
    })

    vim.api.nvim_create_autocmd("WinResized", {
      group = augroup,
      callback = function()
        if vim.o.columns ~= M._last_columns then return end
        M._record_width_ratio()
      end,
      desc = "Remember the AIAgent column's share of the screen after a manual resize",
    })
  end

  -- Re-derive tab highlight groups when the colorscheme changes.
  -- (Initial setup happens lazily inside update_winbar(), after bufferline has loaded.)
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      setup_tab_highlights()
      update_winbar()
    end,
    desc = "Re-derive AIAgent tab highlight groups after colorscheme change",
  })

  -- Track whether the user just ran an explicit :e/:edit command.
  -- CmdlineLeave fires before the command executes, so we set the flag here
  -- and consume it in the BufEnter that follows.
  -- IMPORTANT: also reset on non-matching commands (including <Esc>) so a
  -- cancelled `:e` doesn't leave the flag set and spuriously redirect the
  -- next unrelated BufEnter.
  local e_cmd_pending = false
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = augroup,
    pattern = ":",
    callback = function()
      local cmd = vim.fn.getcmdline()
      -- Match :e or :edit with a filename argument (optional !)
      if cmd:match("^%s*e!?%s") or cmd:match("^%s*edit!?%s") then
        e_cmd_pending = true
      else
        e_cmd_pending = false
      end
    end,
    desc = "Detect explicit :e/:edit commands for worktree redirect",
  })

  -- When :e X is run and X is already open in a buffer, Neovim switches
  -- straight to that buffer without firing BufNew.  Catch it here, but ONLY
  -- when the user explicitly ran :e (flag above), so that normal buffer
  -- navigation (switching windows, <C-\><C-n>, bufferline, etc.) is unaffected.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      if not e_cmd_pending then return end
      e_cmd_pending = false

      local buftype = vim.api.nvim_get_option_value("buftype", { buf = args.buf })
      if buftype ~= "" then return end

      local filepath = vim.api.nvim_buf_get_name(args.buf)
      if filepath == "" then return end

      local agent = M.agents[M.current_agent]
      if not agent or not agent.worktree or not agent.git_root then return end

      if is_under(filepath, agent.worktree) then return end  -- already in worktree
      if not is_under(filepath, agent.git_root) then return end  -- different repo

      local rel_path = filepath:sub(#agent.git_root + 2)
      local wt_path  = agent.worktree .. "/" .. rel_path
      local buf      = args.buf

      vim.schedule(function()
        if vim.api.nvim_get_current_buf() ~= buf then return end
        vim.cmd("edit " .. vim.fn.fnameescape(wt_path))
        -- BufNew fires for wt_path but returns early (path already in worktree),
        -- so tag the buffer here if needed.
        local new_buf = vim.api.nvim_get_current_buf()
        if not vim.b[new_buf].aiagent_name then
          vim.b[new_buf].aiagent_name = M.current_agent
          vim.notify("Worktree [" .. M.current_agent .. "]: " .. rel_path, vim.log.levels.INFO)
        end
      end)
    end,
    desc = "Redirect :e of already-open buffer to the active agent's worktree",
  })

  -- When a new buffer is created via :e, redirect to the worktree version if the
  -- current agent has a worktree and the file exists there.
  -- Renaming the buffer in BufNew (before the file is read) means Neovim reads
  -- the worktree file directly — no double-load, no visible flash.
  -- Use :noautocmd e <file> to bypass this redirect when needed.
  vim.api.nvim_create_autocmd("BufNew", {
    group = augroup,
    callback = function(args)
      local filepath = args.file
      if filepath == "" then return end

      local agent = M.agents[M.current_agent]
      if not agent or not agent.worktree or not agent.git_root then return end

      -- Already inside the worktree — don't redirect
      if is_under(filepath, agent.worktree) then return end

      -- Only redirect files that live under the same git root
      if not is_under(filepath, agent.git_root) then return end

      -- Compute the equivalent worktree path and redirect unconditionally.
      -- If the file doesn't exist in the worktree yet, the buffer opens as a
      -- new file there — saving it will create it in the worktree.
      local rel_path = filepath:sub(#agent.git_root + 2)
      local wt_path  = agent.worktree .. "/" .. rel_path

      -- Rename the buffer before Neovim reads it; the read will use the new path.
      -- Tag it with the agent name so bufferline_name_formatter can prefix the tab.
      vim.api.nvim_buf_set_name(args.buf, wt_path)
      vim.b[args.buf].aiagent_name = M.current_agent
      vim.notify("Worktree [" .. M.current_agent .. "]: " .. rel_path, vim.log.levels.INFO)
    end,
    desc = "Redirect :e to the active agent's worktree when applicable",
  })

  -- Handle quit commands - clean up before Neovim checks for running jobs
  vim.api.nvim_create_autocmd("QuitPre", {
    group = augroup,
    callback = function()
      if next(M.agents) ~= nil then
        force_cleanup()
      end
    end,
    desc = "Close agent terminals before quit check",
  })

  -- Also handle VimLeavePre as a fallback
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      force_cleanup()
    end,
    desc = "Close agent terminals before exiting Neovim",
  })

  -- Idle attention detection timer: checks background agents for silence after activity.
  -- Restart on each setup() call to pick up new idle_timeout_ms config.
  if M.idle_timer then
    M.idle_timer:stop()
    M.idle_timer:close()
    M.idle_timer = nil
  end
  if M.config.idle_timeout_ms > 0 then
    M.idle_timer = vim.uv.new_timer()
    M.idle_timer:start(3000, 3000, vim.schedule_wrap(function()
      local now = vim.uv.now()
      local updated = false
      for agent_name, agent in pairs(M.agents) do
        if agent.attention_needed then goto continue end
        if not agent.buf or not vim.api.nvim_buf_is_valid(agent.buf) then goto continue end
        if not agent.last_output_time then goto continue end

        -- Suppress flagging only when the terminal window is the actively focused
        -- window *and* it is showing this agent.  M.current_agent alone is not
        -- sufficient because the user may have returned to their code editor while
        -- the terminal still "selects" this agent.
        local user_watching = M.win
          and vim.api.nvim_win_is_valid(M.win)
          and vim.api.nvim_get_current_win() == M.win
          and agent_name == M.current_agent
        if user_watching then goto continue end

        -- Only flag when new lines have appeared since the user last visited.
        -- This is the primary guard against false re-alerts: cursor redraws and
        -- prompt updates don't add lines, so line_count stays at the visit baseline.
        local current_lines = vim.api.nvim_buf_line_count(agent.buf)
        local baseline = agent.line_count_at_visit or current_lines
        if current_lines <= baseline then goto continue end

        local elapsed = now - agent.last_output_time
        if elapsed >= M.config.idle_timeout_ms then
          agent.attention_needed = true
          updated = true
          if M.config.idle_notify then
            vim.notify("Agent '" .. agent_name .. "' is waiting for input", vim.log.levels.INFO)
          end
        end
        ::continue::
      end
      if updated then update_winbar() end
    end))
  end
end

--- Clamp a desired agent-column width so neither it nor the rest of the layout
--- is squeezed out of existence. On a very narrow screen the floor drops to half
--- the screen rather than making the clamp unsatisfiable.
---@param width number
---@return number
local function clamp_width(width)
  local floor = math.min(M.config.min_width, math.max(1, math.floor(vim.o.columns / 2)))
  return math.max(floor, math.min(math.floor(width), vim.o.columns - floor))
end

--- Calculate the window width based on config
---@return number
local function get_width()
  local width = M.config.width
  if width > 0 and width <= 1 then
    -- Percentage of total width
    return clamp_width(vim.o.columns * width)
  else
    -- Absolute column count
    return clamp_width(width)
  end
end

-- Proportional resize state.
--
-- M._width_ratio is the agent column's share of the screen. It is seeded from
-- config.width when the layout is created and re-recorded whenever the user
-- resizes the pane by hand, so a terminal resize restores the proportion
-- actually in use rather than the configured default.
--
-- M._last_columns lets the WinResized handler tell a manual resize (screen width
-- unchanged) from Neovim's own redistribution of windows during a terminal
-- resize (screen width changed) — only the former should update the ratio.
--
-- applying_resize suppresses recording while we are setting the width
-- ourselves, so our own rounding is never fed back into the ratio.
M._width_ratio  = nil
M._last_columns = nil
local applying_resize = false

--- Record the agent column's current share of the screen.
--- On M rather than a local: setup() is defined earlier in the file and its
--- WinResized callback has to reach it.
function M._record_width_ratio()
  if applying_resize then return end
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
  local w = vim.api.nvim_win_get_width(M.win)
  if vim.o.columns > 0 and w > 0 then
    M._width_ratio = w / vim.o.columns
  end
end

--- Re-apply the remembered proportion to the current screen size.
--- Safe to call when no agent window is open (does nothing).
function M.resize()
  M._last_columns = vim.o.columns
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end

  local ratio = M._width_ratio
  if not ratio then
    ratio = get_width() / math.max(1, vim.o.columns)
    M._width_ratio = ratio
  end

  applying_resize = true
  pcall(vim.api.nvim_win_set_width, M.win, clamp_width(vim.o.columns * ratio + 0.5))
  -- The header has winfixheight, but a shrinking screen can still squeeze it;
  -- restore it to exactly the number of lines it holds.
  if M.header_win and vim.api.nvim_win_is_valid(M.header_win)
      and M.header_buf and vim.api.nvim_buf_is_valid(M.header_buf) then
    local lines = vim.api.nvim_buf_line_count(M.header_buf)
    pcall(vim.api.nvim_win_set_height, M.header_win, lines)
  end
  -- Released on the next tick: WinResized for our own set_width fires first and
  -- must still see the guard set.
  vim.schedule(function() applying_resize = false end)
end

--- Get the CLI executable for the current agent type
---@return string
local function get_command()
  local cmd = M.config.known_agents[M.current_agent_type]
  return cmd or M.current_agent_type  -- fallback: treat symbolic name as executable
end

--- Get list of agent names
---@return string[]
local function get_agent_names()
  local names = {}
  for name, _ in pairs(M.agents) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Get a resolved highlight attribute (follows links)
local function get_hl(name, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl then return hl[attr] end
end

-- Background colors for each named agent color.
-- Active tab: bold white text.  Inactive tab: dimmed text, same background.
local TAB_COLORS = {
  blue    = "#1e3a5f",
  green   = "#1a4a2a",
  yellow  = "#4a3c10",
  red     = "#5c1e1e",
  pink    = "#5c1e4a",
  cyan    = "#1e4a4a",
  orange  = "#5c3010",
  purple  = "#381e5c",
}

--- Define highlight groups for the agent tab winbar.
--- Called lazily (inside update_winbar) so bufferline is guaranteed to be loaded.
--- Matches bufferline's own approach: separator fg = fill color, bg = tab's own bg.
setup_tab_highlights = function()
  vim.api.nvim_set_hl(0, "AIAgentTabFill", { link = "BufferLineFill" })
  local fill_bg = get_hl("BufferLineFill", "bg")

  -- Per-color groups: active = bold white, inactive = dimmed text, same bg
  for color, bg in pairs(TAB_COLORS) do
    vim.api.nvim_set_hl(0, "AIAgentTabActive_"    .. color, { fg = "#ffffff", bg = bg, bold = true })
    vim.api.nvim_set_hl(0, "AIAgentTabInactive_"  .. color, { fg = "#888888", bg = bg })
    vim.api.nvim_set_hl(0, "AIAgentTabAttention_" .. color, { fg = "#ffffff", bg = bg })
    vim.api.nvim_set_hl(0, "AIAgentSep_"          .. color, { fg = fill_bg,  bg = bg })
  end

  -- Fallback groups for any color not in TAB_COLORS
  local active_bg   = get_hl("BufferLineBufferSelected", "bg")
  local inactive_bg = get_hl("BufferLineBackground",     "bg")
  vim.api.nvim_set_hl(0, "AIAgentTabActive",    { link = "BufferLineBufferSelected" })
  vim.api.nvim_set_hl(0, "AIAgentTabInactive",  { link = "BufferLineBackground" })
  vim.api.nvim_set_hl(0, "AIAgentTabAttention", { fg = "#ffffff", bg = inactive_bg })
  vim.api.nvim_set_hl(0, "AIAgentSepActive",    { fg = fill_bg, bg = active_bg })
  vim.api.nvim_set_hl(0, "AIAgentSepInactive",  { fg = fill_bg, bg = inactive_bg })
end

-- Slant separator characters — exact codepoints bufferline uses for "slant" style
-- U+E0BC: left-side slant  (placed before each tab's content)
-- U+E0BE: right-side slant (placed after each tab's content)
local SEP_L = "\xee\x82\xbc"
local SEP_R = "\xee\x82\xbe"

--- Build the winbar string showing one tab per agent with slant separators.
local function build_winbar()
  local names = get_agent_names()
  if #names == 0 then return "" end

  local parts = {}
  table.insert(parts, "%#AIAgentTabFill# ")

  for _, name in ipairs(names) do
    local agent     = M.agents[name]
    local color     = agent and agent.color
    local is_active = (name == M.current_agent)
    local attention = agent and agent.attention_needed

    local tab_hl, sep_hl
    if color and TAB_COLORS[color] then
      local kind
      if is_active then
        kind = "AIAgentTabActive_"
      elseif attention then
        kind = "AIAgentTabAttention_"
      else
        kind = "AIAgentTabInactive_"
      end
      tab_hl = "%#" .. kind .. color .. "#"
      sep_hl = "%#AIAgentSep_" .. color .. "#"
    else
      if is_active then
        tab_hl = "%#AIAgentTabActive#"
        sep_hl = "%#AIAgentSepActive#"
      elseif attention then
        tab_hl = "%#AIAgentTabAttention#"
        sep_hl = "%#AIAgentSepInactive#"
      else
        tab_hl = "%#AIAgentTabInactive#"
        sep_hl = "%#AIAgentSepInactive#"
      end
    end

    local label = attention and (name .. " ●") or name
    table.insert(parts, sep_hl .. SEP_L)
    table.insert(parts, tab_hl .. " " .. label .. " ")
    table.insert(parts, sep_hl .. SEP_R)
  end

  table.insert(parts, "%#AIAgentTabFill#")
  return table.concat(parts, "")
end

--- Update the winbar on the terminal window with current agent tabs.
--- setup_tab_highlights() is called here (not at startup) so bufferline is guaranteed loaded.
update_winbar = function()
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then return end
  setup_tab_highlights()
  vim.api.nvim_set_option_value("winbar", build_winbar(), { win = M.win })
end

-- Forward declaration: ensure_layout() below is defined before the layout
-- builder it calls, and without this the name would resolve as a (nil) global.
-- Every existing caller happened to hit the early return, so the break only
-- showed up the first time ensure_layout() ran with no column open.
local create_window_layout

--- Ensure the agent column exists, without ever leaving a half-built one.
---
--- create_window_layout() unconditionally creates BOTH panes, so calling it
--- while a stale header pane is still open orphans that pane on screen.  Any
--- leftover header is closed first.
local function ensure_layout()
  if M.is_open() then return end
  if M.header_win ~= nil and vim.api.nvim_win_is_valid(M.header_win) then
    pcall(vim.api.nvim_win_close, M.header_win, true)
  end
  M.header_win = nil
  if M.header_buf ~= nil and vim.api.nvim_buf_is_valid(M.header_buf) then
    pcall(vim.api.nvim_buf_delete, M.header_buf, { force = true, unload = false })
  end
  M.header_buf = nil
  create_window_layout()
end

--- Update the header with keybind instructions and refresh the agent tab winbar.
--- The winbar lives on M.win (not the header), so it is always updated even when
--- show_header = false and no header buffer exists.
local function update_header()
  update_winbar()

  if M.header_buf == nil or not vim.api.nvim_buf_is_valid(M.header_buf) then
    return
  end

  local lines = {
    "<C-\\><C-n> exit | <C-\\><C-s> scroll | <C-\\><C-v> paste reg",
    "<C-\\><C-c> send context | <C-\\><C-a> cycle agents",
    "<C-\\><C-d> diff | <C-\\><C-r> search | <C-\\><C-l> all agents",
    "<C-\\><C-t> history tree | <C-\\><C-f> find session",
  }

  vim.api.nvim_set_option_value("modifiable", true, { buf = M.header_buf })
  vim.api.nvim_buf_set_lines(M.header_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = M.header_buf })

  -- Height is set by update_header() based on the lines array size
  if M.header_win and vim.api.nvim_win_is_valid(M.header_win) then
    vim.api.nvim_win_set_height(M.header_win, #lines)
  end
end

--- Check if the agent window is currently open
---@return boolean
function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Switch to an existing agent by name
---@param name string Agent name to switch to
function M.switch(name)
  local agent = M.agents[name]
  if not agent then
    vim.notify("Agent '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  if not M.is_open() then
    vim.notify("Agent window not open", vim.log.levels.ERROR)
    return
  end

  M.current_agent = name
  if not pcall(vim.api.nvim_win_set_buf, M.win, agent.buf) then
    return
  end
  update_header()

  -- Focus and enter insert mode (unless in scroll mode)
  vim.api.nvim_set_current_win(M.win)
  if not agent.scroll_mode then
    vim.cmd("startinsert")
  end

  pcall(function() require('aiagent.registry').publish_all() end)
end

--- Cycle to the next agent
function M.next_agent()
  local names = get_agent_names()
  if #names <= 1 then
    return
  end

  local current_idx = 1
  for i, name in ipairs(names) do
    if name == M.current_agent then
      current_idx = i
      break
    end
  end

  local next_idx = (current_idx % #names) + 1
  M.switch(names[next_idx])
end

--- Create the window layout (optional header + terminal area)
--- (declared local above, so ensure_layout() can reach it.)
function create_window_layout()
  -- Remember the current window to return to later
  M.prev_win = vim.api.nvim_get_current_win()

  -- Create a vertical split on the right
  vim.cmd("botright vsplit")
  local main_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(main_win, get_width())

  if M.config.show_header then
    -- Top pane: keybind instruction header
    M.header_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.header_buf })
    vim.api.nvim_win_set_buf(main_win, M.header_buf)
    M.header_win = main_win

    vim.api.nvim_set_option_value("number",         false, { win = M.header_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = M.header_win })
    vim.api.nvim_set_option_value("signcolumn",     "no",  { win = M.header_win })
    vim.api.nvim_set_option_value("winfixheight",   true,  { win = M.header_win })

    -- Bottom pane: terminal (split below the header)
    vim.cmd("belowright split")
    M.win = vim.api.nvim_get_current_win()

  else
    -- No header — the single split is the terminal directly
    M.win = main_win
  end

  -- Terminal window options (common to both layouts).
  -- Explicitly override inherited global settings that are distracting or
  -- meaningless in a terminal buffer.
  vim.api.nvim_set_option_value("number",         false, { win = M.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.win })
  vim.api.nvim_set_option_value("signcolumn",     "no",  { win = M.win })
  vim.api.nvim_set_option_value("list",           false, { win = M.win })
  vim.api.nvim_set_option_value("spell",          false, { win = M.win })
  vim.api.nvim_set_option_value("colorcolumn",    "",    { win = M.win })

  -- Restore exact dimensions saved by hide() to prevent terminal reflow.
  -- If the screen changed width while hidden, the saved width is stale — scale
  -- it to keep the same share of the screen instead.
  if M._hidden_win_width then
    local width = M._hidden_win_width
    if M._hidden_columns and M._hidden_columns > 0 and M._hidden_columns ~= vim.o.columns then
      width = vim.o.columns * (width / M._hidden_columns)
    end
    vim.api.nvim_win_set_width(M.win, clamp_width(width))
    M._hidden_win_width = nil
    M._hidden_columns = nil
  end
  if M._hidden_win_height then
    vim.api.nvim_win_set_height(M.win, math.min(M._hidden_win_height, vim.o.lines))
    M._hidden_win_height = nil
  end

  M._last_columns = vim.o.columns
  M._record_width_ratio()
end

--- Create an agent's terminal buffer and start its job.
---@param name string
---@param cwd string|nil
---@param opts table|nil { command: string|nil, color: string|nil }
---   command - override the configured executable (used for `--resume`)
---   color   - reuse a specific colour instead of taking the next in the cycle;
---             a restart keeps the agent's identity, and the colour is baked
---             into the deferred `/color` the agent is sent, so it cannot be
---             corrected after the fact.
local function create_agent(name, cwd, opts)
  opts = opts or {}
  local cmd = opts.command or get_command()
  local agent_type = M.current_agent_type

  -- Pick the next color from the cycle, unless one was handed in.  The cycle
  -- only advances for a genuinely new agent, so restarts do not shift the
  -- colours future agents will get.
  local color = opts.color
  if not color then
    local colors = M.config.colors
    M.color_index = M.color_index + 1
    color = colors[((M.color_index - 1) % #colors) + 1]
  end

  -- Create a new buffer for the terminal
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options before starting terminal
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })

  -- Store agent before starting terminal (so on_exit can find it)
  M.agents[name] = {
    buf = buf,
    job_id = nil,
    scroll_mode = false,
    scroll_pos = nil,
    agent_type = agent_type,
    command = cmd,
    sent_files = {},  -- Track which files have been sent as context
    color = color,
    worktree = nil,
    git_root = nil,
    attention_needed = false,
    last_output_time = nil,
    line_count_at_visit = nil,
  }

  -- Show buffer in window and switch to it before starting terminal
  -- (termopen runs in the current window, so we must be in M.win)
  vim.api.nvim_win_set_buf(M.win, buf)
  vim.api.nvim_set_current_win(M.win)

  -- Build termopen options
  local term_opts = {
    on_exit = function()
      if M.agents[name] then
        M.agents[name].job_id = nil
      end
      pcall(M.close, name)
    end,
  }
  if cwd and cwd ~= "" then
    term_opts.cwd = cwd
  end

  -- Start the terminal with the AI agent
  local job_id = vim.fn.termopen(cmd, term_opts)
  if not job_id or job_id <= 0 then
    vim.notify(
      "Failed to start agent '" .. name .. "' (command: " .. cmd .. ")",
      vim.log.levels.ERROR
    )
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    M.agents[name] = nil
    return nil
  end

  M.agents[name].job_id = job_id

  -- High scrollback prevents history loss when the window is hidden and re-shown
  -- (libvterm reflows content on resize, which can exceed the default 10000 limit).
  vim.api.nvim_set_option_value("scrollback", 100000, { buf = buf })

  -- Track output to detect when a background agent finishes and needs attention.
  -- on_lines fires whenever the terminal buffer content changes (i.e. new output).
  vim.api.nvim_buf_attach(buf, false, {
    -- Update last_output_time whenever the terminal buffer gains new lines.
    -- new_lastline > lastline means lines were added (real output); cursor movement
    -- and in-place redraws have new_lastline == lastline and are ignored so they
    -- don't push last_output_time forward and delay the idle threshold.
    on_lines = function(_, _, _, _, lastline, new_lastline)
      local agent = M.agents[name]
      if not agent then return true end  -- detach when agent is gone
      if new_lastline <= lastline then return end  -- no new lines; skip cursor/redraw noise
      agent.last_output_time = vim.uv.now()
      if agent.attention_needed then
        agent.attention_needed = false
        vim.schedule(update_winbar)
      end
    end,
  })

  -- Send /color command after the agent has had time to start.
  -- Delay is configurable via M.config.agent_startup_delay (default 1500ms).
  vim.defer_fn(function()
    if M.agents[name] and M.agents[name].job_id then
      vim.fn.chansend(M.agents[name].job_id, "/color " .. color .. "\r")
    end
  end, M.config.agent_startup_delay)

  -- Set buffer name for identification
  vim.api.nvim_buf_set_name(buf, "agent:" .. name)

  -- Auto-enter insert mode when entering this buffer (unless in scroll mode)
  -- Also optionally auto-send context for new buffers
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      local agent = M.agents[name]
      if agent then
        agent.attention_needed = false
        -- Record the line count at the time of this visit.  The timer only flags
        -- when the current line count exceeds this baseline, so idle cursor redraws
        -- (which don't add lines) can never re-trigger attention after a visit.
        agent.line_count_at_visit = vim.api.nvim_buf_line_count(agent.buf)
      end
      if agent and not agent.scroll_mode then
        -- Auto-send context if enabled
        if M.config.auto_send_context then
          M.send_context(name)
        end
        vim.cmd("startinsert")
      end
    end,
    desc = "Auto-enter terminal mode when focusing agent window",
  })

  -- Exit terminal mode (or scroll mode) and return to the previous editing window.
  -- Mapped in both t-mode and n-mode so the key works consistently regardless of
  -- whether the user is typing in the terminal or has entered scroll mode.
  local function exit_to_prev_win()
    local agent = M.agents[name]
    if agent then
      agent.scroll_mode = false
    end
    if M.prev_win and vim.api.nvim_win_is_valid(M.prev_win) then
      vim.api.nvim_set_current_win(M.prev_win)
    end
  end

  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-n>", "", {
    noremap = true,
    callback = function()
      vim.cmd("stopinsert")
      exit_to_prev_win()
    end,
  })

  -- Same key from scroll mode (already in normal mode, so no stopinsert needed).
  -- Yank text first, then press <C-\><C-n> to jump to your editing window and paste.
  vim.api.nvim_buf_set_keymap(buf, "n", "<C-\\><C-n>", "", {
    noremap = true,
    callback = exit_to_prev_win,
  })

  -- Add keymap to enter scroll mode (stay in agent window)
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-s>", "", {
    noremap = true,
    callback = function()
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = true
      end
      local win = vim.api.nvim_get_current_win()
      vim.cmd("stopinsert")
      vim.schedule(function()
        if agent and agent.scroll_pos then
          -- Re-entering: restore last scroll position
          pcall(vim.api.nvim_win_set_cursor, win, agent.scroll_pos)
        else
          -- First time: go to top of buffer
          pcall(vim.api.nvim_win_set_cursor, win, { M.config.scroll_start_line, 0 })
        end
      end)
    end,
  })

  -- Add keymap to exit scroll mode and resume terminal interaction
  vim.api.nvim_buf_set_keymap(buf, "n", "i", "", {
    noremap = true,
    callback = function()
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = false
        local pos = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
        agent.scroll_pos = { pos[1], pos[2] }
      end
      vim.cmd("startinsert")
    end,
  })

  -- Add keymap to cycle agents
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-a>", "", {
    noremap = true,
    callback = function()
      M.next_agent()
    end,
  })

  -- Add keymap to send buffer context
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-c>", "", {
    noremap = true,
    callback = function()
      local count = M.send_context(name)
      if count > 0 then
        vim.notify("Sent " .. count .. " file(s) as context", vim.log.levels.INFO)
      else
        vim.notify("No new files to send", vim.log.levels.INFO)
      end
    end,
  })

  -- Paste the unnamed register into the terminal input.
  -- <C-r> in terminal mode falls through to the shell (reverse-history search),
  -- so we handle paste at the plugin level via chansend instead.
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-v>", "", {
    noremap = true,
    callback = function()
      local text = vim.fn.getreg('"')
      if text ~= "" then
        send_to_terminal(name, text)
      end
    end,
  })

  -- Open the prompt-history diff viewer for the current session.
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-d>", "", {
    noremap = true,
    callback = function()
      M.prompt_history_open()
    end,
  })

  -- Open the machine-wide agent list (every agent in every Neovim instance).
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-l>", "", {
    noremap = true,
    callback = function()
      M.show_all()
    end,
  })

  -- Open the session history tree (jump to any point in this session).
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-t>", "", {
    noremap = true,
    callback = function()
      M.history_open()
    end,
  })

  -- Find a past session and load it back into this agent.
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-f>", "", {
    noremap = true,
    callback = function()
      -- Out of insert mode first: the finder is a normal-mode UI, and
      -- telescope's prompt inherits a terminal-mode keymap stack otherwise.
      vim.cmd("stopinsert")
      vim.schedule(function() M.find_session() end)
    end,
  })

  return buf
end

--- Return the consistent worktree path for an agent slug (in the system temp dir).
--- Resolves $TMPDIR symlinks so the path matches what git stores (macOS: /var -> /private/var).
--- Includes the repo name to avoid clashes across different repositories.
---@param slug string
---@param repo_name string Slugified repo name (basename of git root)
---@return string
local function worktree_path_for(slug, repo_name)
  local tmpdir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  return vim.fn.resolve(tmpdir) .. "/nvim-agent-" .. repo_name .. "-" .. slug
end

--- Find an existing worktree path for an agent slug by parsing `git worktree list --porcelain`.
--- Matches on the branch name `agent/{slug}` rather than the directory path.
---@param slug string
---@return string|nil path
local function find_existing_worktree(slug)
  local target_branch = "refs/heads/agent/" .. slug
  local output = vim.fn.system("git worktree list --porcelain 2>/dev/null")
  -- Porcelain format: each entry has "worktree <path>", "HEAD <hash>", "branch <ref>",
  -- separated by blank lines. Track the current entry's path and match on branch.
  local current_path = nil
  for line in output:gmatch("[^\n]+") do
    local path = line:match("^worktree (.+)$")
    if path then
      current_path = path
    elseif line:match("^branch (.+)$") == target_branch then
      return current_path
    end
  end
  return nil
end

--- Create (or reconnect to) a git worktree; returns path and git root, or nil, nil on failure.
--- Derives the branch name and default directory from wt_name.
--- If directory is provided and the worktree already exists, that is an error.
---@param wt_name string Worktree display name (branch/dir derived from this)
---@param directory string|nil Explicit directory for a new worktree (nil = auto-generate)
---@return string|nil, string|nil
local function create_worktree(wt_name, directory)
  local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("\n", "")
  if vim.v.shell_error ~= 0 or git_root == "" then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return nil, nil
  end

  local slug = wt_name:lower():gsub("[^%w]", "-")
  local repo_name = vim.fn.fnamemodify(git_root, ":t"):lower():gsub("[^%w]", "-")
  local branch_name = "agent/" .. slug

  -- Reconnect if the worktree already exists
  local existing = find_existing_worktree(slug)
  if existing then
    if directory and directory ~= "" then
      vim.notify("Worktree '" .. wt_name .. "' already exists at '" .. existing .. "'; cannot specify a directory", vim.log.levels.ERROR)
      return nil, nil
    end
    vim.notify("Reconnected to existing worktree: " .. existing, vim.log.levels.INFO)
    return existing, git_root
  end

  -- Worktree doesn't exist — use the provided directory or auto-generate one in TMPDIR
  local worktree_path
  if directory and directory ~= "" then
    worktree_path = vim.fn.expand(directory)  -- resolve ~, relative paths, env vars
  else
    worktree_path = worktree_path_for(slug, repo_name)
  end

  -- Branch may already exist (worktree was removed but branch kept); try without -b first
  vim.fn.system("git show-ref --verify --quiet refs/heads/" .. vim.fn.shellescape(branch_name) .. " 2>&1")
  local result
  if vim.v.shell_error == 0 then
    -- Branch exists — add worktree without creating a new branch
    result = vim.fn.system(
      "git worktree add " .. vim.fn.shellescape(worktree_path)
      .. " " .. vim.fn.shellescape(branch_name) .. " 2>&1"
    )
  else
    -- Fresh: create branch and worktree together
    result = vim.fn.system(
      "git worktree add -b " .. vim.fn.shellescape(branch_name)
      .. " " .. vim.fn.shellescape(worktree_path) .. " HEAD 2>&1"
    )
  end

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to create worktree:\n" .. result, vim.log.levels.ERROR)
    return nil, nil
  end

  vim.notify("Worktree created: " .. worktree_path .. " (branch: " .. branch_name .. ")", vim.log.levels.INFO)
  return worktree_path, git_root
end

--- Check whether an agent has a persistent worktree from a previous session (without -worktree flag)
---@param agent_name string
---@return string|nil worktree_path, string|nil git_root
local function find_agent_worktree(agent_name)
  local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("\n", "")
  if vim.v.shell_error ~= 0 or git_root == "" then return nil, nil end
  local slug = agent_name:lower():gsub("[^%w]", "-")
  local existing = find_existing_worktree(slug)
  if existing then return existing, git_root end
  return nil, nil
end

--- Open an AI agent in a right-side split.
--- Syntax: :AgentOpen [Name [WTName [directory]]]
---   Name      - agent name (default: "AIAgent")
---   WTName    - worktree name; "-" is shorthand for using the agent name
---   directory - explicit directory for a new worktree (error if worktree already exists)
--- When WTName is omitted, auto-reconnects to an existing worktree named after the agent.
---@param name string|nil Agent name
---@param wtname string|nil Worktree name ("-" = use agent name)
---@param directory string|nil Explicit worktree directory (new worktrees only)
function M.open(name, wtname, directory)
  local agent_name = name or "AIAgent"

  -- If agent already exists, switch to it
  if M.agents[agent_name] then
    if not M.is_open() then
      create_window_layout()
    end
    M.switch(agent_name)
    return
  end

  -- "-" is shorthand for using the agent name as the worktree name
  if wtname == "-" then
    wtname = agent_name
  end

  local cwd = nil
  local worktree_path = nil
  local worktree_git_root = nil
  local worktree_slug = nil

  if wtname and wtname ~= "" then
    -- WTName provided: create or reconnect to the named worktree
    worktree_path, worktree_git_root = create_worktree(wtname, directory)
    if not worktree_path then return end
    cwd = worktree_path
    worktree_slug = wtname:lower():gsub("[^%w]", "-")
  else
    -- No WTName: auto-reconnect to an existing worktree named after the agent
    worktree_path, worktree_git_root = find_agent_worktree(agent_name)
    if worktree_path then
      cwd = worktree_path
      worktree_slug = agent_name:lower():gsub("[^%w]", "-")
      vim.notify("Reconnected to existing worktree for " .. agent_name, vim.log.levels.INFO)
    end
  end

  -- Create window layout if not open
  if not M.is_open() then
    create_window_layout()
  end

  if not create_agent(agent_name, cwd) then return end
  M.current_agent = agent_name

  if worktree_path and M.agents[agent_name] then
    M.agents[agent_name].worktree = worktree_path
    M.agents[agent_name].git_root = worktree_git_root
    M.agents[agent_name].slug = worktree_slug
  end

  -- Announce to other Neovim instances.  Deferred so the agent's job pid and
  -- the shell's cwd have settled before the sidecar is written.
  vim.defer_fn(function()
    pcall(function() require('aiagent.registry').publish_all() end)
  end, 200)

  update_header()
  vim.cmd("startinsert")
end

--- Close a specific agent or the current one
---@param name string|nil Agent name to close (defaults to current)
function M.close(name)
  local agent_name = name or M.current_agent

  if not agent_name then
    -- No agents, just clean up window
    force_cleanup()
    return
  end

  -- Clean up the specific agent
  cleanup_agent(agent_name)

  -- If that was the current agent, switch to another or close window
  if agent_name == M.current_agent then
    local remaining = get_agent_names()
    if #remaining > 0 then
      M.switch(remaining[1])
    else
      -- No agents left, close the window
      M.current_agent = nil
      if M.win ~= nil and vim.api.nvim_win_is_valid(M.win) then
        pcall(vim.api.nvim_win_close, M.win, true)
        M.win = nil
      end
      if M.header_win ~= nil and vim.api.nvim_win_is_valid(M.header_win) then
        pcall(vim.api.nvim_win_close, M.header_win, true)
        M.header_win = nil
      end
      if M.header_buf ~= nil and vim.api.nvim_buf_is_valid(M.header_buf) then
        pcall(vim.api.nvim_buf_delete, M.header_buf, { force = true, unload = false })
        M.header_buf = nil
      end
    end
  else
    -- Just update header to reflect removed agent
    update_header()
  end
end

--- Close all agents and window
function M.close_all()
  force_cleanup()
end

--- bufferline name_formatter callback.
--- Returns "AgentName: filename" for worktree-redirected buffers, nil otherwise.
--- Usage in bufferline setup:
---   options = { name_formatter = require('aiagent').bufferline_name_formatter, ... }
---@param buf { name: string, path: string, bufnr: number }
---@return string|nil
function M.bufferline_name_formatter(buf)
  local ok, agent_name = pcall(function() return vim.b[buf.bufnr].aiagent_name end)
  if ok and agent_name then
    local agent = M.agents[agent_name]
    local prefix = agent and agent.slug
    if not prefix then return nil end
    return prefix .. ": " .. vim.fn.fnamemodify(buf.path, ":t")
  end
end

--- lualine branch component helper.
--- Returns the branch of the active agent's worktree when one is active,
--- nil otherwise (caller should fall back to the regular branch).
--- Usage in lualine setup:
---   lualine_b = { { function() return require('aiagent').lualine_branch() or vim.b.gitsigns_head or '' end }, ... }
---@return string|nil
function M.lualine_branch()
  local name = M.current_agent
  local agent = name and M.agents[name]
  if agent and agent.buf == vim.api.nvim_get_current_buf() then
    local src = ''
    if agent.worktree then
      src = '-C ' .. vim.fn.shellescape(agent.worktree);
    end
    local branch = vim.fn.system('git ' .. src .. ' branch --show-current 2>/dev/null'):gsub('\n', '')

    if branch ~= '' then return branch end
  end
end

--- MCP server lualine helpers.
--- Each server gets its own slot (lualine_mcp_server(n) / lualine_mcp_color(n)).
--- Empty string return causes lualine to hide the component automatically.
--- Usage in lualine setup (add as many slots as you expect servers):
---   { function() return require('aiagent').lualine_mcp_server(1) end,
---     color = function() return require('aiagent').lualine_mcp_color(1) end },

local _mcp_cache        = nil  -- list of { name, connected } populated from config files
local _mcp_last_read    = 0
local _mcp_cwd          = nil  -- cwd used for last read; cache invalidates on change
local _mcp_scroll_pos   = 0    -- raw ever-incrementing counter
local _mcp_scroll_timer = nil
local _mcp_hl_defined   = false

local function _ensure_mcp_hl()
  if _mcp_hl_defined then return end
  vim.api.nvim_set_hl(0, 'AiAgentMcpLabel', { fg = '#60a5fa', default = true })  -- blue
  vim.api.nvim_set_hl(0, 'AiAgentMcpOk',    { fg = '#22c55e', default = true })  -- green
  vim.api.nvim_set_hl(0, 'AiAgentMcpErr',   { fg = '#ef4444', default = true })  -- red
  _mcp_hl_defined = true
end

--- Returns the working directory Claude was started in for the current agent.
local function _mcp_cwd_for_agent()
  local agent = M.current_agent and M.agents[M.current_agent]
  if agent and agent.worktree then return agent.worktree end
  return vim.fn.getcwd()
end

--- Reads a JSON file; returns decoded table or nil on failure.
local function _read_json(path)
  local f = io.open(vim.fn.expand(path), 'r')
  if not f then return nil end
  local ok, data = pcall(vim.fn.json_decode, f:read('*a'))
  f:close()
  return ok and type(data) == 'table' and data or nil
end

local function _ensure_mcp_cache()
  local now = vim.uv.now()
  local cwd = _mcp_cwd_for_agent()
  if _mcp_cache and (now - _mcp_last_read) < 30000 and _mcp_cwd == cwd then return end
  _mcp_last_read = now
  _mcp_cwd = cwd

  local claude  = _read_json('~/.claude.json') or {}
  local proj    = (claude.projects or {})[cwd] or {}

  -- Servers explicitly disabled for this project
  local disabled_set = {}
  for _, name in ipairs(proj.disabledMcpServers or {}) do
    disabled_set[name] = true
  end

  -- Servers that recently failed auth (15-min TTL stored in cache file as epoch ms)
  local needs_auth_set = {}
  local auth_cache = _read_json('~/.claude/mcp-needs-auth-cache.json') or {}
  local now_ms = os.time() * 1000
  for name, entry in pairs(auth_cache) do
    if type(entry.timestamp) == 'number' and (now_ms - entry.timestamp) < 900000 then
      needs_auth_set[name] = true
    end
  end

  local servers = {}
  local seen    = {}

  local function add(raw_name)
    if seen[raw_name] then return end
    seen[raw_name] = true
    local display = raw_name:gsub('^claude%.ai%s+', '')
    if disabled_set[raw_name] then
      table.insert(servers, { name = display, connected = false })
    elseif not needs_auth_set[raw_name] then
      table.insert(servers, { name = display, connected = true })
    end
    -- needs-auth servers are silently excluded (same as before)
  end

  -- claude.ai auto-discovered servers: only those that have ever connected
  for _, name in ipairs(claude.claudeAiMcpEverConnected or {}) do add(name) end

  -- Manually configured global servers (e.g. github)
  for name, _ in pairs(claude.mcpServers or {}) do add(name) end

  _mcp_cache = servers
  vim.schedule(function() require('lualine').refresh() end)
end

local function _mcp_start_scroll()
  if _mcp_scroll_timer then return end
  _mcp_scroll_timer = vim.uv.new_timer()
  _mcp_scroll_timer:start(300, 300, vim.schedule_wrap(function()
    _mcp_scroll_pos = _mcp_scroll_pos + 1
    if _mcp_scroll_pos > 100000 then _mcp_scroll_pos = 0 end
    require('lualine').refresh()
  end))
end

local function _mcp_stop_scroll()
  if _mcp_scroll_timer then
    _mcp_scroll_timer:stop()
    _mcp_scroll_timer:close()
    _mcp_scroll_timer = nil
    _mcp_scroll_pos   = 0
  end
end

--- Extract a colored lualine string from segments for the character window [pos, pos+width).
--- segs: list of { text=string, hl=string|nil } — hl=nil means inherit the previous segment's hl.
--- Highlight groups are switched only at boundaries (no %* resets needed).
--- A %#HlGroup# is always emitted at the very first visible character so that the
--- output is self-contained and does not inherit the caller's active highlight.
local function _colored_window(segs, pos, width)
  local result    = ''
  local char_pos  = 0
  local taken     = 0
  local active_hl = nil
  local need_hl   = true   -- force hl emission at the first visible character

  for _, seg in ipairs(segs) do
    if taken >= width then break end
    local seg_len = vim.fn.strchars(seg.text)
    local seg_end = char_pos + seg_len

    if seg_end > pos then
      local new_hl = seg.hl or active_hl
      local from   = math.max(0, pos - char_pos)
      local vis    = vim.fn.strcharpart(seg.text, from, width - taken)
      local vlen   = vim.fn.strchars(vis)
      if vlen > 0 then
        if new_hl and (need_hl or new_hl ~= active_hl) then
          result    = result .. '%#' .. new_hl .. '#'
          active_hl = new_hl
        end
        need_hl = false
        result  = result .. vis
        taken   = taken + vlen
      end
    end

    if seg.hl then active_hl = seg.hl end
    char_pos = seg_end
  end

  return result
end

--- Returns a coloured carousel string for connected/disabled MCP servers.
--- Truncation/scrolling is computed on plain text; colour markup is applied after.
--- MCP label: blue. Connected servers: green. Disabled servers: red.
---@return string
function M.lualine_mcp()
  _ensure_mcp_cache()
  if not _mcp_cache or #_mcp_cache == 0 then
    _mcp_stop_scroll()
    return ''
  end

  _ensure_mcp_hl()

  -- Build segments: each has plain text and its highlight group name.
  -- Separators between entries have hl=nil (inherits previous segment's colour).
  local segs = {}
  local plain_parts = {}
  for i, server in ipairs(_mcp_cache) do
    if i > 1 then
      table.insert(segs,        { text = '  ', hl = nil })
      table.insert(plain_parts, '  ')
    end
    local icon = server.connected and '\u{2713}' or '\u{2717}'
    local hl   = server.connected and 'AiAgentMcpOk' or 'AiAgentMcpErr'
    local text = icon .. ' ' .. server.name
    table.insert(segs,        { text = text, hl = hl })
    table.insert(plain_parts, text)
  end

  local prefix      = 'MCP: '
  local server_text = table.concat(plain_parts)
  local full        = prefix .. server_text

  -- Helper: apply colour markup to the full segment list (no clipping).
  local function colorize_full()
    local out = '%#AiAgentMcpLabel#' .. prefix
    local cur_hl = 'AiAgentMcpLabel'
    for _, seg in ipairs(segs) do
      local hl = seg.hl or cur_hl
      if hl ~= cur_hl then
        out    = out .. '%#' .. hl .. '#'
        cur_hl = hl
      end
      out = out .. seg.text
    end
    return out
  end

  if not M.config.mcp_scroll or vim.fn.strdisplaywidth(full) <= M.config.mcp_max_width then
    _mcp_stop_scroll()
    return colorize_full()
  end

  -- Scrolling: compute plain-text window first, then colorize the same region.
  local scroll_width = M.config.mcp_max_width - vim.fn.strdisplaywidth(prefix)
  local loop_sep     = '   '
  local loop_text    = server_text .. loop_sep
  local loop_len     = vim.fn.strchars(loop_text)
  local pos          = _mcp_scroll_pos % loop_len

  -- Plain window for padding (width calculation only).
  local plain_win = vim.fn.strcharpart(loop_text .. server_text, pos, scroll_width)
  local pad       = scroll_width - vim.fn.strdisplaywidth(plain_win)

  -- Double the segments to match loop_text .. server_text.
  local doubled = {}
  for _, s in ipairs(segs) do table.insert(doubled, s) end
  table.insert(doubled, { text = loop_sep, hl = nil })
  for _, s in ipairs(segs) do table.insert(doubled, s) end

  local colored_win = _colored_window(doubled, pos, scroll_width)
  if pad > 0 then colored_win = colored_win .. string.rep(' ', pad) end

  _mcp_start_scroll()
  return '%#AiAgentMcpLabel#' .. prefix .. colored_win
end

---@return table|nil
function M.lualine_mcp_color()
  -- Colours are handled entirely via inline highlight groups; only grey while loading.
  if not _mcp_cache then return { fg = '#94a3b8' } end
  return nil
end

--- Force an immediate MCP status refresh (e.g. after changing claude config).
function M.mcp_refresh()
  _mcp_cache     = nil
  _mcp_last_read = 0
  _ensure_mcp_cache()
end

--- Model lualine helper.
--- Reads the model from Claude Code's session JSONL:
---   ~/.claude/sessions/{pid}.json  → sessionId + cwd
---   ~/.claude/projects/{escaped-cwd}/{sessionId}.jsonl  → last assistant message → message.model
---
--- Usage in lualine setup:
---   { function() return require('aiagent').lualine_model() end }

local _model_cache     = nil   -- string (model name) or nil when unavailable
local _model_last_read = 0
local _model_pid       = nil   -- pid used for last read; cache invalidates on pid change

--- Escape a filesystem path the way Claude Code does for its project directory names.
--- Rule: replace every character that is not a letter, digit, or hyphen with '-'.
local function _cwd_to_project_dir(cwd)
  return cwd:gsub('[^%w%-]', '-')
end

--- Read the last `nbytes` of a file synchronously; returns string or nil on failure.
local function _read_tail(path, nbytes)
  local fd = vim.uv.fs_open(path, 'r', 0)
  if not fd then return nil end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then vim.uv.fs_close(fd); return nil end
  local offset = math.max(0, stat.size - nbytes)
  local data = vim.uv.fs_read(fd, nbytes, offset)
  vim.uv.fs_close(fd)
  return data
end

--- Look up the model string from Claude Code's JSONL for a running process PID.
local function _model_from_pid(pid)
  local session = _read_json(vim.fn.expand('~/.claude/sessions/' .. pid .. '.json'))
  if not session or not session.sessionId or not session.cwd then return nil end

  local project_dir = _cwd_to_project_dir(session.cwd)
  local jsonl_path = vim.fn.expand(
    '~/.claude/projects/' .. project_dir .. '/' .. session.sessionId .. '.jsonl'
  )

  -- Read the last 8 KB — enough to contain the most recent assistant message.
  local tail = _read_tail(jsonl_path, 8192)
  if not tail then return nil end

  -- Scan backwards through lines for the last assistant entry that has message.model.
  local lines = vim.split(tail, '\n', { plain = true })
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line ~= '' then
      local ok, entry = pcall(vim.fn.json_decode, line)
      if ok and type(entry) == 'table'
         and entry.type == 'assistant'
         and type(entry.message) == 'table'
         and type(entry.message.model) == 'string' then
        return entry.message.model
      end
    end
  end
  return nil
end

local function _ensure_model_cache()
  local agent = M.current_agent and M.agents[M.current_agent]
  if not agent or not agent.job_id then
    _model_cache = nil
    return
  end
  local pid = vim.fn.jobpid(agent.job_id)
  if not pid or pid == 0 then
    _model_cache = nil
    return
  end
  local now = vim.uv.now()
  if _model_pid == pid and (now - _model_last_read) < 10000 then return end
  _model_last_read = now
  _model_pid       = pid
  _model_cache     = _model_from_pid(pid)
end

--- lualine component: the model used by the active Claude agent.
--- Returns a short name (e.g. "sonnet-4-6") or "" when unavailable.
function M.lualine_model()
  _ensure_model_cache()
  if not _model_cache then return '' end
  -- Strip the "claude-" vendor prefix for a compact display.
  return (_model_cache:gsub('^claude%-', ''))
end

--- lualine component helpers for section A.
--- When the current buffer is an agent terminal, returns the label and color
--- to display. Returns nil for both when not in an agent buffer.
--- Usage in lualine setup:
---   lualine_a = { { require('aiagent').lualine_label, color = require('aiagent').lualine_color } }
---@return string|nil
function M.lualine_label()
  local name = M.current_agent
  local agent = name and M.agents[name]
  if agent and agent.buf == vim.api.nvim_get_current_buf() then
    local t = agent.agent_type or name
    local display = t:sub(1, 1):upper() .. t:sub(2) .. ":" .. M.lualine_model()
    if agent.scroll_mode then
      return 'Scroll Mode: ' .. display
    end
    return 'Agent: ' .. display
  end
end

---@return table|nil
function M.lualine_color()
  local name = M.current_agent
  local agent = name and M.agents[name]
  if agent and agent.buf == vim.api.nvim_get_current_buf() then
    if agent.scroll_mode then
      return { bg = '#7c3aed', fg = '#ffffff' }
    end
    return { bg = '#0891b2', fg = '#ffffff' }
  end
end

--- Get list of running agents
---@return string[]
function M.list()
  return get_agent_names()
end

--- Print list of running agents
function M.print_list()
  local names = get_agent_names()
  if #names == 0 then
    vim.notify("No agents running", vim.log.levels.INFO)
  else
    local current = M.current_agent or ""
    local lines = {}
    for _, name in ipairs(names) do
      local marker = (name == current) and " *" or ""
      local agent = M.agents[name]
      local agent_type = agent and agent.agent_type or "?"
      table.insert(lines, name .. marker .. " [" .. agent_type .. "]")
    end
    vim.notify("Agents:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
  end
end

--- Set the one-line task label shown for an agent in the global list.
--- Overrides the label derived from the session's last prompt; an empty string
--- clears it and falls back to the derived one.
---@param text string Task description
---@param name string|nil Agent name (defaults to current)
function M.set_task(text, name)
  local agent_name = name or M.current_agent
  local agent = agent_name and M.agents[agent_name]
  if not agent then
    vim.notify("No agent active", vim.log.levels.WARN)
    return
  end
  text = vim.trim(text or "")
  agent.task = (text ~= "") and text or nil
  pcall(function() require('aiagent.registry').publish(agent_name) end)
  if agent.task then
    vim.notify(agent_name .. ": " .. agent.task, vim.log.levels.INFO)
  else
    vim.notify(agent_name .. ": task label cleared", vim.log.levels.INFO)
  end
end

--- Every live agent published on this machine, across all Neovim instances.
---@return table[]
function M.list_all()
  return require('aiagent.registry').read_all()
end

--- Show the machine-wide agent list in a floating window.
function M.show_all()
  require('aiagent.registry').show()
end

--- Hide the agent window without killing any agents.
--- The terminal buffers and jobs stay alive; toggle or open will restore the window.
function M.hide()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    M._hidden_win_width = vim.api.nvim_win_get_width(M.win)
    M._hidden_win_height = vim.api.nvim_win_get_height(M.win)
    M._hidden_columns = vim.o.columns
    pcall(vim.api.nvim_win_close, M.win, true)
    M.win = nil
  end
  if M.header_win and vim.api.nvim_win_is_valid(M.header_win) then
    pcall(vim.api.nvim_win_close, M.header_win, true)
    M.header_win = nil
  end
  if M.header_buf and vim.api.nvim_buf_is_valid(M.header_buf) then
    pcall(vim.api.nvim_buf_delete, M.header_buf, { force = true, unload = false })
    M.header_buf = nil
  end
  if M.prev_win and vim.api.nvim_win_is_valid(M.prev_win) then
    vim.api.nvim_set_current_win(M.prev_win)
  end
end

--- Toggle the AI agent window
---@param name string|nil Agent name (defaults to "AIAgent")
function M.toggle(name)
  local agent_name = name or "AIAgent"

  -- If window is open and showing this agent, hide it (keep session alive)
  if M.is_open() and M.current_agent == agent_name then
    M.hide()
  else
    M.open(agent_name)
  end
end

--- Send open buffer context to the current agent
--- Uses @file syntax for Claude Code to read the files
---@param agent_name string|nil Agent name (defaults to current)
---@return number Number of new files sent
function M.send_context(agent_name)
  local name = agent_name or M.current_agent
  if not name then
    vim.notify("No agent active", vim.log.levels.WARN)
    return 0
  end

  local agent = M.agents[name]
  if not agent or not agent.job_id then
    vim.notify("Agent '" .. name .. "' not running", vim.log.levels.WARN)
    return 0
  end

  local new_files = get_unsent_buffer_files(name)
  if #new_files == 0 then
    return 0
  end

  -- Build @file references for Claude Code
  local refs = {}
  for _, file in ipairs(new_files) do
    table.insert(refs, "@" .. file)
  end

  -- Send file references to the terminal; only mark as sent on success so that
  -- a closed channel doesn't silently drop files from future sends.
  local text = table.concat(refs, " ") .. " "
  if not send_to_terminal(name, text) then
    return 0
  end

  for _, file in ipairs(new_files) do
    agent.sent_files[file] = true
  end

  return #new_files
end

--- Get count of unsent buffer files for the current agent
---@param agent_name string|nil Agent name (defaults to current)
---@return number
function M.pending_context_count(agent_name)
  local name = agent_name or M.current_agent
  if not name then
    return 0
  end
  return #get_unsent_buffer_files(name)
end

--- Reset sent files tracking for an agent (to re-send all context)
---@param agent_name string|nil Agent name (defaults to current)
function M.reset_context(agent_name)
  local name = agent_name or M.current_agent
  if not name then
    return
  end
  local agent = M.agents[name]
  if agent then
    agent.sent_files = {}
    vim.notify("Context reset for agent '" .. name .. "'", vim.log.levels.INFO)
  end
end

--- Internal: send selection lines to a running agent
---@param name string Agent name
---@param lines string[] Selected lines
---@param filetype string Filetype of the source buffer
local function send_selection_to_agent(name, lines, filetype)
  local agent = M.agents[name]
  if not agent or not agent.job_id then
    vim.notify("Agent '" .. name .. "' not running", vim.log.levels.ERROR)
    return
  end

  -- Format as markdown code block
  local ft = filetype ~= "" and filetype or "text"
  local code_block = "```" .. ft .. "\n" .. table.concat(lines, "\n") .. "\n```\n"

  -- Send to terminal
  send_to_terminal(name, code_block)

  -- Switch to the agent and enter insert mode
  M.current_agent = name
  vim.api.nvim_win_set_buf(M.win, agent.buf)
  vim.api.nvim_set_current_win(M.win)
  update_header()
  vim.cmd("startinsert")
end

--- Send visual selection to the agent terminal
--- Opens the agent if not already open
---@param agent_name string|nil Agent name (defaults to current or "AIAgent")
function M.send_selection(agent_name)
  -- Get selection before we switch windows (marks may change)
  local lines, filetype = get_visual_selection()
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    vim.notify("No text selected", vim.log.levels.WARN)
    return
  end

  -- Determine which agent to use
  local name = agent_name or M.current_agent or "AIAgent"

  -- Open agent if not running
  if not M.agents[name] then
    M.open(name)
    -- Give terminal time to initialize
    vim.defer_fn(function()
      send_selection_to_agent(name, lines, filetype)
    end, 100)
    return
  end

  -- If window isn't open, open it
  if not M.is_open() then
    M.open(name)
  end

  send_selection_to_agent(name, lines, filetype)
end

--- Send LSP diagnostics for the current buffer to the agent terminal
--- Opens the agent if not already open
---@param agent_name string|nil Agent name (defaults to current or "AIAgent")
---@param line1 number|nil First line of range (1-indexed, inclusive); nil = whole buffer
---@param line2 number|nil Last line of range (1-indexed, inclusive); nil = whole buffer
function M.send_diagnostics(agent_name, line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local all_diags = vim.diagnostic.get(bufnr)

  -- Filter to selected line range when one is given (diagnostic lnum is 0-indexed)
  local diags
  if line1 and line2 then
    diags = vim.tbl_filter(function(d)
      return d.lnum + 1 >= line1 and d.lnum + 1 <= line2
    end, all_diags)
  else
    diags = all_diags
  end

  if #diags == 0 then
    local scope = (line1 and line2) and ("lines " .. line1 .. "-" .. line2) or "current buffer"
    vim.notify("No diagnostics for " .. scope, vim.log.levels.INFO)
    return
  end

  local severity_labels = { "ERROR", "WARN", "INFO", "HINT" }

  -- Collect active LSP clients and their compiler/init options
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local client_info = {}
  for _, client in ipairs(clients) do
    local info = { name = client.name }
    -- Prefer explicit compiler/language settings; fall back to init_options
    if client.config.settings and next(client.config.settings) ~= nil then
      info.options = client.config.settings
    elseif client.config.init_options and next(client.config.init_options) ~= nil then
      info.options = client.config.init_options
    end
    table.insert(client_info, info)
  end

  -- Sort diagnostics by line, then column
  table.sort(diags, function(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.col < b.col
  end)

  -- Build the message
  local parts = {}

  table.insert(parts, "I have LSP errors in the following file that I would like you to analyse and suggest fixes for.")
  table.insert(parts, "")
  table.insert(parts, "**File:** " .. filename)
  table.insert(parts, "")

  if #client_info > 0 then
    table.insert(parts, "**Language Server(s) and compiler options:**")
    for _, c in ipairs(client_info) do
      table.insert(parts, "- " .. c.name)
      if c.options then
        table.insert(parts, "  ```json")
        table.insert(parts, "  " .. vim.json.encode(c.options))
        table.insert(parts, "  ```")
      end
    end
    table.insert(parts, "")
  end

  table.insert(parts, "**Errors:**")
  table.insert(parts, "```<Errors>")
  for _, d in ipairs(diags) do
    local sev = severity_labels[d.severity] or "INFO"
    local source = d.source and (" (" .. d.source .. ")") or ""
    table.insert(parts, string.format("[%s] line %d, col %d: %s%s",
      sev, d.lnum + 1, d.col + 1, d.message, source))
  end
  table.insert(parts, "```")
  table.insert(parts, "")
  table.insert(parts, "Please analyse these errors and explain what is wrong and how to fix each one.")

  local text = table.concat(parts, "\n")

  local name = agent_name or M.current_agent or "AIAgent"

  local function do_send()
    local agent = M.agents[name]
    if not agent or not agent.job_id then
      vim.notify("Agent '" .. name .. "' not running", vim.log.levels.ERROR)
      return
    end
    -- ESC normalises any vim mode (no-op if already normal), then 'i' enters insert
    send_to_terminal(name, "\x1bi")
    send_to_terminal(name, text)
    M.current_agent = name
    vim.api.nvim_win_set_buf(M.win, agent.buf)
    vim.api.nvim_set_current_win(M.win)
    update_header()
    vim.cmd("startinsert")
  end

  if not M.agents[name] then
    M.open(name)
    vim.defer_fn(do_send, 100)
    return
  end

  if not M.is_open() then
    M.open(name)
  end

  do_send()
end

--- The Claude session id + working dir for the current agent, resolved from
--- its PID via ~/.claude/sessions/<pid>.json (same lookup the model statusline
--- uses). Returns nil when no agent is running or the session can't be read.
---@return { id: string, cwd: string }|nil
function M.current_session()
  local agent = M.current_agent and M.agents[M.current_agent]
  if not agent or not agent.job_id then return nil end
  local pid = vim.fn.jobpid(agent.job_id)
  if not pid or pid == 0 then return nil end
  local session = _read_json(vim.fn.expand('~/.claude/sessions/' .. pid .. '.json'))
  if not session or not session.sessionId then return nil end
  return { id = session.sessionId, cwd = session.cwd or vim.fn.getcwd() }
end

--- Open the session history tree in a popup (default: the current agent's
--- session).  See |aiagent-history-tree|.
---@param session string|nil Claude session id
function M.history_open(session)
  require('aiagent.history').show({ session = session })
end

--- An agent's command with any resume flags from an earlier jump, fork or load
--- stripped, so repeated moves do not accumulate them.
---@param agent table|nil  nil falls back to the configured executable
---@return string
local function base_command(agent)
  local cmd = (agent and agent.command) or get_command()
  return (cmd:gsub("%s+%-%-resume%s+%S+", ""):gsub("%s+%-%-fork%-session", ""))
end

--- Replace the current agent's process in place, keeping its panes, its name
--- and its whole identity — colour, worktree, git root, slug, task, sent files.
--- Only the process changes.
---
--- `prepare` runs with the old job already stopped and before the new one
--- starts, which is the only safe window for writing to the session transcript:
--- a live session writes its own `last-prompt` at the end of every turn and
--- would clobber anything written underneath it.  Returning false aborts.
---
--- The old agent is gone by then either way, so an aborted relaunch leaves no
--- agent running — the caller reports and stops.
---@param name string
---@param command_of fun(base: string): string  builds the new command line
---@param prepare fun(): boolean, string|nil
---@return boolean ok
local function relaunch_agent(name, command_of, prepare)
  local agent = M.agents[name]
  if not agent then return false end

  -- Carry the agent's identity across the restart.
  local keep = {
    color = agent.color,
    worktree = agent.worktree,
    git_root = agent.git_root,
    slug = agent.slug,
    task = agent.task,
    sent_files = agent.sent_files,
    agent_type = agent.agent_type,
  }
  local base = base_command(agent)
  local cwd = agent.worktree

  -- Detach from the plugin's bookkeeping BEFORE stopping the job.  The
  -- terminal's on_exit calls M.close(name), which tears the whole column down
  -- when no agents remain — with the agent already gone from M.agents and no
  -- longer current, that call finds nothing to do and the panes survive.
  local old_buf = agent.buf
  local job = agent.job_id
  M.agents[name] = nil
  M.current_agent = nil

  if job ~= nil then
    pcall(vim.fn.chanclose, job)
    pcall(vim.fn.jobstop, job)
    pcall(vim.fn.jobwait, { job }, 500)
  end
  pcall(function() require('aiagent.registry').unpublish(name) end)

  if prepare then
    local ok, err = prepare()
    if not ok then
      vim.notify(err or "Could not prepare the session", vim.log.levels.ERROR)
      return false
    end
  end

  -- Free the "agent:<name>" buffer name before recreating: the old buffer must
  -- stay alive (deleting it while it is the only one in M.win would take the
  -- window with it) but nvim_buf_set_name() fails with E95 on a duplicate.
  if old_buf ~= nil and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_set_name, old_buf, "agent:" .. name .. ":retired:" .. old_buf)
  end

  -- Restart INTO the existing panes.  create_agent() swaps the new terminal
  -- buffer into M.win, so the header pane and the column are untouched.
  ensure_layout()
  if not create_agent(name, cwd, {
        command = command_of(base),
        color = keep.color,
      }) then
    return false
  end
  M.current_agent = name
  for k, v in pairs(keep) do M.agents[name][k] = v end

  -- The window is showing the new buffer now, so dropping the old one cannot
  -- take the window with it.
  if old_buf ~= nil and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_delete, old_buf, { force = true, unload = false })
  end

  vim.defer_fn(function()
    pcall(function() require('aiagent.registry').publish_all() end)
  end, 200)

  update_header()
  vim.cmd("startinsert")
  return true
end

--- Move the current agent to another point in its session history.
---
--- One mechanism for every jump, backwards along the current path or sideways
--- onto a branch that was rewound away: append a `last-prompt` pointer naming
--- the target entry, then resume.  Repointing the leaf at an ancestor *is* a
--- rewind, so `/rewind` (which has no programmatic entry point anyway) is not
--- needed.
---
--- Order matters.  The job is stopped BEFORE the pointer is written: a live
--- session writes its own `last-prompt` at the end of every turn and would
--- clobber ours.  That is also why the agent necessarily restarts.
---@param target table { session: string, path: string, leaf: string, prompt: string|nil }
---@return boolean ok
function M.history_jump(target)
  local name = M.current_agent
  local agent = name and M.agents[name]
  if not agent then
    vim.notify("No active agent to move", vim.log.levels.WARN)
    return false
  end
  if agent.agent_type ~= "claude" then
    vim.notify("History jump is only supported for Claude agents", vim.log.levels.WARN)
    return false
  end

  local ok = relaunch_agent(name,
    function(base) return base .. " --resume " .. target.session end,
    function()
      local moved, err = require('aiagent.history').set_leaf(
        target.path, target.session, target.leaf, target.prompt)
      if not moved then
        return false, "Could not move the history pointer: " .. (err or "unknown error")
      end
      return true
    end)
  if not ok then return false end

  vim.notify("Jumped to: " .. (target.prompt or target.leaf), vim.log.levels.INFO)
  return true
end

--- Fork a new agent from a point in another agent's history.
---
--- `--fork-session` resumes a session under a NEW id, and Claude Code copies the
--- walked path into the new transcript (rewriting every entry's sessionId), so
--- the fork is a genuinely independent session rather than a reference into the
--- source.  Combined with a leaf pointer it can start from any node in the tree.
---
--- The source agent is never stopped.  Its on-disk position does move while the
--- fork reads the file, so the previous head is restored once the fork has
--- started; that restore is best-effort by design, because the source agent's
--- own next turn appends newer entries which supersede any stale pointer anyway.
---@param target table { session, path, leaf, prompt } the node to fork from
---@param opts table|nil { name, wtname, source } (prompts interactively when absent)
function M.history_fork(target, opts)
  opts = opts or {}
  local source_name = opts.source or M.current_agent
  local source = source_name and M.agents[source_name]
  if not source then
    vim.notify("No agent to fork from", vim.log.levels.WARN)
    return
  end
  if source.agent_type ~= "claude" then
    vim.notify("Forking is only supported for Claude agents", vim.log.levels.WARN)
    return
  end

  local history = require('aiagent.history')

  --- Everything below runs once the name and worktree choice are known.
  local function spawn(name, cwd, worktree, git_root, slug)
    -- Remember where the source stood before its pointer is moved.
    local restore = history.head(history.parse(target.path))

    local ok, err = history.set_leaf(target.path, target.session, target.leaf, target.prompt)
    if not ok then
      vim.notify("Could not set the fork point: " .. (err or "unknown error"),
        vim.log.levels.ERROR)
      return
    end

    local base = base_command(source)
    ensure_layout()
    if not create_agent(name, cwd, {
          command = base .. " --resume " .. target.session .. " --fork-session",
        }) then
      return
    end
    M.current_agent = name
    local agent = M.agents[name]
    agent.worktree = worktree
    agent.git_root = git_root
    agent.slug = slug
    if target.prompt and target.prompt ~= "" then
      agent.task = "fork: " .. target.prompt:sub(1, 60)
    end

    -- Restore the source's pointer once the fork has read the transcript, which
    -- has happened by the time it has a session file of its own.  Give up after
    -- a few seconds and restore regardless: waiting longer protects nothing.
    local tries = 0
    local function restore_source()
      tries = tries + 1
      local forked = M.agents[name]
      local pid = forked and forked.job_id and vim.fn.jobpid(forked.job_id)
      local started = false
      if pid and pid > 0 then
        local info = _read_json(vim.fn.expand('~/.claude/sessions/' .. pid .. '.json'))
        started = info ~= nil and info.sessionId ~= nil and info.sessionId ~= target.session
      end
      if started or tries > 40 then
        if restore then
          pcall(history.set_leaf, target.path, target.session, restore, "")
        end
        return
      end
      vim.defer_fn(restore_source, 250)
    end
    vim.defer_fn(restore_source, 250)

    vim.defer_fn(function()
      pcall(function() require('aiagent.registry').publish_all() end)
    end, 200)

    update_header()
    vim.cmd("startinsert")
    vim.notify("Forked " .. name .. " from: " .. (target.prompt or target.leaf),
      vim.log.levels.INFO)
  end

  --- Ask what to do, then spawn.
  ---
  --- Uses the plugin's own menu (see `history.menu`) rather than vim.ui.select:
  --- a filtering picker is the wrong shape for a three-way choice, and the
  --- builtin cmdline prompts are easy to miss beside a busy agent terminal.  A
  --- name is derived up front, so only the rename path prompts for text.
  local function ask(name)
    local slug = name:lower():gsub("[^%w]", "-")
    local where = source.worktree
      and vim.fn.fnamemodify(source.worktree, ":t") or "this repo"
    local choices = {
      'Fork as "' .. name .. '" in ' .. where .. " (shared with " .. source_name .. ")",
      'Fork as "' .. name .. '" in a new worktree (agent/' .. slug .. ")",
      "Choose a different name…",
    }
    local label = target.prompt or ""
    if #label > 46 then label = label:sub(1, 45) .. "…" end
    require('aiagent.history').menu(choices, { title = "Fork from: " .. label }, function(idx)
      if not idx then
        vim.notify("Fork cancelled", vim.log.levels.INFO)
        return
      end
      if idx == 1 then
        spawn(name, source.worktree, source.worktree, source.git_root, source.slug)
      elseif idx == 2 then
        local path, root = create_worktree(name)
        if not path then return end
        spawn(name, path, path, root, slug)
      else
        vim.ui.input({ prompt = "Fork agent name: ", default = name }, function(text)
          if not text or vim.trim(text) == "" then
            vim.notify("Fork cancelled", vim.log.levels.INFO)
            return
          end
          text = vim.trim(text)
          if M.agents[text] then
            vim.notify("An agent named '" .. text .. "' already exists", vim.log.levels.WARN)
            return
          end
          ask(text)
        end)
      end
    end)
  end

  -- Explicit arguments (`:AgentFork name [worktree]`) skip the prompts entirely:
  -- an empty worktree means "share the source agent's".
  if opts.name and opts.name ~= "" then
    if opts.wtname == nil then
      ask(opts.name)
    elseif opts.wtname == "" then
      spawn(opts.name, source.worktree, source.worktree, source.git_root, source.slug)
    else
      local path, root = create_worktree(opts.wtname)
      if path then
        spawn(opts.name, path, path, root, opts.wtname:lower():gsub("[^%w]", "-"))
      end
    end
    return
  end

  -- Default name: the source plus a free counter, so repeated forks do not clash.
  local default, n = source_name .. "-fork", 1
  while M.agents[default] do
    n = n + 1
    default = source_name .. "-fork" .. n
  end
  ask(default)
end

--- Fork a new agent from where the current agent stands right now.
--- To fork from an earlier point, press `f` on it in |:AgentTree|.
---@param name string|nil Agent name (prompts when absent)
---@param wtname string|nil Worktree name; "" reuses the source's (prompts when absent)
function M.fork_here(name, wtname)
  local agent_name = M.current_agent
  local agent = agent_name and M.agents[agent_name]
  if not agent then
    vim.notify("No agent active", vim.log.levels.WARN)
    return
  end
  local session = M.current_session()
  if not session then
    vim.notify("Cannot resolve the current agent's session", vim.log.levels.WARN)
    return
  end
  local history = require('aiagent.history')
  local path = history.transcript_path(session.id)
  if not path then
    vim.notify("No transcript found for session " .. session.id, vim.log.levels.WARN)
    return
  end
  local parsed = history.parse(path)
  local head = history.head(parsed)
  if not head then
    vim.notify("Session transcript is empty", vim.log.levels.WARN)
    return
  end
  local tree = history.build(parsed)
  local prompt = tree and tree.current and tree.meta[tree.current].prompt or ""
  M.history_fork({ session = session.id, path = path, leaf = head, prompt = prompt },
    { name = name, wtname = wtname })
end

--- Find a past session anywhere on this machine and load it back.
---
--- Every session Claude Code has ever run is still on disk, so the one whose
--- terminal you closed is recoverable.  See |aiagent-find-session|.
---@param opts table|nil { all: boolean|nil }  all=true also lists promptless stubs
function M.find_session(opts)
  require('aiagent.sessions').pick(opts)
end

--- Load a past session into an agent, replacing the current agent's process.
---
--- Resumed with `--fork-session`, which starts the conversation again under a
--- NEW session id and copies the walked path into a new transcript.  So the
--- archive is never written to and can be loaded again, as often as you like —
--- and two agents can be loaded from the same past session at once.
---
--- No `last-prompt` pointer is written either: with none, resume takes the
--- session's newest leaf, which is exactly "carry on from where I left off".
--- Starting from an EARLIER point is |AgentTree|'s job — open the tree on this
--- session (`<C-t>` in the finder) and fork from the turn you want.
---
--- With an agent running, the load happens in place: same panes, same name,
--- same worktree, only the process and its history change.  With none, a fresh
--- agent is opened in the current directory.
---@param entry table { id: string, title: string|nil, cwd: string|nil }
---@param opts table|nil { name: string|nil }
---@return boolean ok
function M.session_load(entry, opts)
  opts = opts or {}
  if type(entry) == "string" then entry = { id = entry } end
  if not entry or not entry.id or entry.id == "" then
    vim.notify("No session to load", vim.log.levels.WARN)
    return false
  end

  -- Loading a session that is still being written to is safe (the fork only
  -- reads it), but it is rarely what was meant, so say so.
  if entry.live then
    vim.notify("That session is live in a running agent; loading a fork of it",
      vim.log.levels.INFO)
  end

  local label = entry.title or entry.prompt or entry.id
  local function command_of(base)
    return base .. " --resume " .. entry.id .. " --fork-session"
  end

  local name = M.current_agent
  local agent = name and M.agents[name]

  if agent then
    if agent.agent_type ~= "claude" then
      vim.notify("Loading a session is only supported for Claude agents",
        vim.log.levels.WARN)
      return false
    end
    if not relaunch_agent(name, command_of, nil) then return false end
    -- The label is what the finder searched on, so it is the useful thing to
    -- carry into the agent list as this agent's task.
    M.agents[name].task = "loaded: " .. label:sub(1, 60)
    vim.notify("Loaded session into " .. name .. ": " .. label, vim.log.levels.INFO)
    return true
  end

  -- Nothing running: open a fresh agent straight onto the session.
  local new_name = opts.name or "AIAgent"
  if M.agents[new_name] then
    vim.notify("An agent named '" .. new_name .. "' already exists", vim.log.levels.WARN)
    return false
  end
  ensure_layout()
  if not create_agent(new_name, nil, { command = command_of(base_command(nil)) }) then
    return false
  end
  M.current_agent = new_name
  M.agents[new_name].task = "loaded: " .. label:sub(1, 60)
  vim.defer_fn(function()
    pcall(function() require('aiagent.registry').publish_all() end)
  end, 200)
  update_header()
  vim.cmd("startinsert")
  vim.notify("Loaded session into " .. new_name .. ": " .. label, vim.log.levels.INFO)
  return true
end

--- Open the prompt-history diff viewer for a session (default: the current
--- agent's live session). The git object store is shared across worktrees, so
--- the agent's cwd serves as both the git root and the .prompt-history anchor.
---@param session string|nil Explicit session id (nil = resolve current agent)
function M.prompt_history_open(session)
  local ph = require('aiagent.prompthistory')
  local cur = M.current_session()
  local cwd = (cur and cur.cwd) or vim.fn.getcwd()
  session = session or ph.active_session(cwd) or (cur and cur.id)
  if not session then
    vim.notify("AgentDiff: no active session; pass a session id (:AgentDiff <id>)",
      vim.log.levels.ERROR)
    return
  end
  if ph.state then ph.close() end  -- refresh: pick up newly captured prompts
  ph.open_for(session, cwd, cwd)
end

--- Build a primer from a session's prompt history (prompts + changed files +
--- diffs) and TYPE it into the running agent's prompt without submitting, so the
--- user can review and press Enter. This re-orients the agent on a previous
--- session's intent; it is not a conversation replay (assistant turns are not
--- captured), which is why it is deliberately not called "resume".
---@param session string  prompt-history session id to load
---@param agent_name string|nil  defaults to the current/AIAgent agent
function M.prompt_history_load_context(session, agent_name)
  local ph = require('aiagent.prompthistory')
  local cur = M.current_session()
  local cwd = (cur and cur.cwd) or vim.fn.getcwd()
  local text, err = ph.build_primer(session, cwd)
  if not text then
    vim.notify("AgentSessions: " .. (err or "could not build primer"), vim.log.levels.ERROR)
    return
  end

  local name = agent_name or M.current_agent or "AIAgent"

  local function do_send()
    local agent = M.agents[name]
    if not agent or not agent.job_id then
      vim.notify("Agent '" .. name .. "' not running", vim.log.levels.ERROR)
      return
    end
    -- ESC normalises any vim mode (no-op if already normal), then 'i' enters insert.
    send_to_terminal(name, "\x1bi")
    send_to_terminal(name, text)
    M.current_agent = name
    if M.win then
      vim.api.nvim_win_set_buf(M.win, agent.buf)
      vim.api.nvim_set_current_win(M.win)
    end
    update_header()
    vim.cmd("startinsert")
  end

  if not M.agents[name] then
    M.open(name)
    vim.defer_fn(do_send, 100)
    return
  end
  if not M.is_open() then
    M.open(name)
  end
  do_send()
end

--- Pick a prompt-history session. By default this selects the session to
--- continue capturing into (writes .prompt-history/active-session so the capture
--- hook appends new prompts there). With load_context=true (the `:AgentSessions!`
--- bang) the chosen session's prompt history is instead loaded into the running
--- agent's context via M.prompt_history_load_context.
---@param load_context boolean|nil
function M.prompt_history_list(load_context)
  local cur = M.current_session()
  local cwd = (cur and cur.cwd) or vim.fn.getcwd()
  local ph = require('aiagent.prompthistory')
  local sessions = ph.list_sessions(cwd)
  if #sessions == 0 then
    vim.notify("No prompt-history sessions found", vim.log.levels.INFO)
    return
  end

  local active_id = ph.active_session(cwd)

  local items = {}
  -- The "default" pseudo-entry only makes sense for capture selection; loading
  -- context requires a concrete session, so omit it in that mode.
  if not load_context then
    table.insert(items, { label = "(default — use Claude's session ID)", id = nil })
  end
  for _, s in ipairs(sessions) do
    local prompt = s.first_prompt:gsub("\n", " ")
    if #prompt > 40 then prompt = prompt:sub(1, 37) .. "..." end
    local marker = (active_id and s.id == active_id) and " *" or ""
    table.insert(items, {
      label = string.format("%d turns  %s  %s%s", s.turns, s.started, prompt, marker),
      id = s.id,
    })
  end

  vim.ui.select(items, {
    prompt = load_context and "Select session to load into agent context:"
      or "Select session to continue:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    if load_context then
      M.prompt_history_load_context(choice.id)
      return
    end
    ph.set_active_session(cwd, choice.id)
    if choice.id then
      vim.notify("Prompt history will continue session: " .. choice.id, vim.log.levels.INFO)
    else
      vim.notify("Prompt history will use the default session", vim.log.levels.INFO)
    end
    -- If the diff viewer is open, follow the selection so it shows the chosen
    -- session. "Default" resolves to the live Claude session, matching open.
    if ph.state then
      local target = choice.id or (cur and cur.id)
      if target then ph.reload(target) end
    end
  end)
end

--- Close the prompt-history viewer and return to the chat terminal.
function M.prompt_history_close()
  require('aiagent.prompthistory').close()
end

--- Absolute path to this plugin's root directory (resolved from this file's
--- own location: lua/aiagent/init.lua -> root).
local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)  -- strip leading '@'
  return vim.fn.fnamemodify(src, ':p:h:h:h')       -- absolute, then up to root
end

--- Wire the prompt_snapshot.sh capture hooks into the user's Claude Code
--- settings.json. Idempotent: an event already referencing prompt_snapshot.sh
--- is left untouched. The merge is done with jq so unrelated settings (and the
--- JSON `[]` vs `{}` distinction) are preserved; a `.bak` is written first.
---@param opts { settings: string|nil }|nil
---@return string[] changes Human-readable description of each event's outcome
---@return boolean wrote   Whether settings.json was modified
function M.install_hooks(opts)
  opts = opts or {}
  local path = vim.fn.expand(opts.settings or '~/.claude/settings.json')
  if vim.fn.executable('jq') == 0 then
    return { 'jq not found on PATH — wire hooks manually (see reference/install.md)' }, false
  end

  local existing = (_read_json(path) or {}).hooks or {}
  local events = {
    { event = 'UserPromptSubmit', cmd = plugin_root() .. '/hooks/prompt_snapshot.sh pre' },
    { event = 'Stop',             cmd = plugin_root() .. '/hooks/prompt_snapshot.sh post' },
  }

  local changes, to_add = {}, {}
  for _, e in ipairs(events) do
    local present = false
    for _, group in ipairs(existing[e.event] or {}) do
      for _, h in ipairs(group.hooks or {}) do
        if type(h.command) == 'string' and h.command:find('prompt_snapshot.sh', 1, true) then
          present = true
        end
      end
    end
    if present then
      table.insert(changes, e.event .. ': already wired')
    else
      table.insert(to_add, e)
      table.insert(changes, e.event .. ': added ' .. e.cmd)
    end
  end
  if #to_add == 0 then return changes, false end

  -- Back up an existing file; seed an empty object when there is none.
  if vim.fn.filereadable(path) == 1 then
    vim.fn.writefile(vim.fn.readfile(path), path .. '.bak')
  else
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    vim.fn.writefile({ '{}' }, path)
  end

  local filter = '.hooks //= {} | .hooks[$event] //= [] '
    .. '| .hooks[$event] += [{hooks:[{type:"command",command:$cmd}]}]'
  for _, e in ipairs(to_add) do
    local out = vim.fn.system({ 'jq', '--arg', 'event', e.event, '--arg', 'cmd', e.cmd, filter, path })
    if vim.v.shell_error ~= 0 then
      vim.notify('AIAgent: jq failed updating ' .. path .. ':\n' .. out, vim.log.levels.ERROR)
      return changes, false
    end
    vim.fn.writefile(vim.split(out, '\n', { trimempty = true }), path)
  end
  return changes, true
end

--- Install the bundled prompt-history skill into the user's Claude skills
--- directory. Copies the skill files, substituting the placeholder
--- `__AIAGENT_HOOKS_DIR__` with this install's actual hooks path so the
--- inspect-script and hook-setup references resolve correctly. Then offers to
--- wire the capture hooks (see |aiagent.install_hooks()|), without which there
--- is nothing for the skill to show.
---@param opts { force: boolean|nil, dest: string|nil, hooks: boolean|nil, settings: string|nil }|nil
---  hooks: true = wire without asking, false = skip, nil = prompt (default)
---@return boolean installed
function M.install_skill(opts)
  opts = opts or {}
  local name = opts.name or 'prompt-history'
  local src = plugin_root() .. '/skills/' .. name
  if vim.fn.isdirectory(src) == 0 then
    vim.notify('AIAgent: no bundled skill named ' .. name .. ' (looked in ' .. src .. ')',
      vim.log.levels.ERROR)
    return false
  end

  local dest = vim.fn.expand(opts.dest or ('~/.claude/skills/' .. name))
  if vim.fn.isdirectory(dest) == 1 and not opts.force then
    vim.notify('AIAgent: skill already installed at ' .. dest
      .. ' — use :AgentInstallSkill! to overwrite', vim.log.levels.WARN)
    return false
  end

  local hooks_dir = plugin_root() .. '/hooks'
  local count = 0
  for _, path in ipairs(vim.fn.globpath(src, '**/*', false, true)) do
    if vim.fn.isdirectory(path) == 0 then  -- files only; mkdir creates the dirs
      local out = dest .. '/' .. path:sub(#src + 2)  -- strip "src/"
      vim.fn.mkdir(vim.fn.fnamemodify(out, ':h'), 'p')
      local lines = vim.fn.readfile(path)
      for i, line in ipairs(lines) do
        lines[i] = line:gsub('__AIAGENT_HOOKS_DIR__', hooks_dir)
      end
      vim.fn.writefile(lines, out)
      count = count + 1
    end
  end

  local report = { ('installed %s skill (%d files) to %s'):format(name, count, dest) }

  -- Only the prompt-history skill needs the capture hooks; every other bundled
  -- skill is self-contained, so it installs and stops there.
  if name ~= 'prompt-history' then
    vim.notify('AIAgent: ' .. table.concat(report, '\n'), vim.log.levels.INFO)
    return true
  end

  local wire = opts.hooks
  if wire == nil then
    wire = vim.fn.confirm(
      'Wire the prompt_snapshot.sh capture hooks into ~/.claude/settings.json now?\n'
      .. 'Required for capture; a .bak backup is written first.',
      '&Yes\n&No', 1) == 1
  end

  if wire then
    local changes, wrote = M.install_hooks({ settings = opts.settings })
    for _, c in ipairs(changes) do table.insert(report, '  hook ' .. c) end
    if wrote then
      table.insert(report, '  settings.json updated (backup at .bak); restart Claude Code to load the hooks')
    end
  else
    table.insert(report, '  capture hooks NOT wired — see reference/install.md in the skill to do it by hand')
  end

  vim.notify('AIAgent: ' .. table.concat(report, '\n'), vim.log.levels.INFO)
  return true
end

--- Names of the skills bundled with this plugin.
---@return string[]
function M.bundled_skills()
  local out = {}
  for _, path in ipairs(vim.fn.globpath(plugin_root() .. '/skills', '*', false, true)) do
    if vim.fn.isdirectory(path) == 1 then
      table.insert(out, vim.fn.fnamemodify(path, ':t'))
    end
  end
  table.sort(out)
  return out
end

--- Open the PR review viewer.  With no number, pick from the open PRs.
---
--- The review worktree is created on branch `agent/pr-<n>`, which is exactly
--- the branch |AgentOpen| derives from the worktree name `pr-<n>` — so
--- `:AgentOpen review pr-123` afterwards puts an agent in the same tree, with
--- the PR checked out, ready to read the code under review.
---@param number string|integer|nil
function M.pr_open(number)
  local pr = require('aiagent.prreview')
  if number == nil or number == '' then
    pr.pick()
  else
    pr.open(number)
  end
end

--- Close the review viewer.  The draft is kept.
function M.pr_close()
  require('aiagent.prreview').close()
end

--- Submit the open review draft.
function M.pr_submit()
  require('aiagent.prreview').submit_flow()
end

--- Throw away the open review draft, after confirming — it is unrecoverable.
function M.pr_discard()
  local pr = require('aiagent.prreview')
  local s = pr.state
  if not s then
    vim.notify('AgentPR: no review open', vim.log.levels.WARN)
    return
  end
  local n = #s.draft.comments
  local choice = vim.fn.confirm(
    string.format('Discard the draft review of #%s (%d comment(s))? This cannot be undone.',
      tostring(s.draft.number), n), '&Discard\n&Keep', 2)
  if choice ~= 1 then return end
  pr.discard(s.draft)
  pr.close()
  vim.notify('AgentPR: draft discarded', vim.log.levels.INFO)
end

--- Brief the agent on a PR and let it propose review comments.
---
--- The primer is TYPED into the agent's prompt without being submitted (the
--- same path as |AgentSendDiagnostics|), so the user reads it and presses Enter.
--- Anything the agent then proposes lands in the draft as a proposal only —
--- see |aiagent.prreview.propose|.
---@param number string|integer|nil  defaults to the open review
---@param agent_name string|nil
function M.pr_review(number, agent_name)
  local pr = require('aiagent.prreview')

  local draft = pr.state and pr.state.draft or nil
  if not draft and number and number ~= '' then
    local root = pr.git_root()
    local rem = root and pr.remote_for(root)
    if rem then
      rem.number = tonumber(number) or number
      draft = pr.load(rem)
    end
  end
  if not draft then
    vim.notify('AgentPR: no review open — run :AgentPR <n> first', vim.log.levels.ERROR)
    return
  end

  local text, err = pr.build_primer(draft, pr.state and pr.state.files or nil)
  if not text then
    vim.notify('AgentPR: ' .. (err or 'could not build the primer'), vim.log.levels.ERROR)
    return
  end

  local name = agent_name or M.current_agent or "AIAgent"

  local function do_send()
    local agent = M.agents[name]
    if not agent or not agent.job_id then
      vim.notify("Agent '" .. name .. "' not running", vim.log.levels.ERROR)
      return
    end
    -- ESC normalises any vim mode (no-op if already normal), then 'i' enters insert.
    send_to_terminal(name, "\x1bi")
    send_to_terminal(name, text)
    M.current_agent = name
    if M.win then
      vim.api.nvim_win_set_buf(M.win, agent.buf)
      vim.api.nvim_set_current_win(M.win)
    end
    update_header()
    vim.cmd("startinsert")
  end

  -- The viewer owns its own tabpage; the agent lives in the previous one.
  if pr.state then pr.close() end

  if not M.agents[name] then
    M.open(name)
    vim.defer_fn(do_send, 100)
    return
  end
  if not M.is_open() then
    M.open(name)
  end
  do_send()
end

--- Record an agent-proposed review comment.  This is the |--remote-expr| target
--- an agent calls; it returns a one-line string for the agent to read back
--- (never nil — `--remote-expr` errors on a nil result).
---@param spec table  { path, side?, line?, start_line?, body, subject_type?, number? }
---@return string
function M.pr_comment(spec)
  local ok, res = pcall(function()
    return require('aiagent.prreview').propose(spec)
  end)
  return ok and tostring(res) or ('error: ' .. tostring(res))
end

-- Expose internals needed for testing (prefixed with _ by convention)
M._is_under = is_under
-- Exposed for tests: the resume/fork flag stripping behind every relaunch.
M._base_command = function(agent) return base_command(agent) end
M._plugin_root = plugin_root

return M
