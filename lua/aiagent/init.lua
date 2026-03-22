---@diagnostic disable: undefined-global
local M = {}

-- Default configuration
M.config = {
  width = 0.4,         -- Width as percentage (0-1) or columns (>1)
  default_agent = "claude", -- Symbolic agent name to use on startup
  auto_send_context = false, -- Automatically send new buffer context when entering terminal
  agent_startup_delay = 1500, -- Milliseconds to wait before sending /color command on startup
  show_header = true,         -- Show the keybind instruction header above the terminal
  scroll_start_line = 9,      -- Line to jump to when first entering scroll mode
  idle_timeout_ms = 8000,     -- ms of silence after activity before flagging (0 = disabled)
  idle_notify     = false,    -- also fire vim.notify when flagging attention
  mcp_max_width   = 35,       -- max statusline columns for MCP display before scrolling
  mcp_scroll      = true,     -- scroll MCP display when wider than mcp_max_width
  colors = { "red", "blue", "orange", "green", "yellow", "magenta", "cyan", "purple" },
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
M.agents = {}           -- { name = { buf, job_id, scroll_mode, scroll_pos, agent_type, command, sent_files, color, worktree, git_root, slug, attention_needed, last_output_time, line_count_at_visit } }
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

--- Calculate the window width based on config
---@return number
local function get_width()
  local width = M.config.width
  if width > 0 and width <= 1 then
    -- Percentage of total width
    return math.floor(vim.o.columns * width)
  else
    -- Absolute column count
    return math.floor(width)
  end
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
  magenta = "#5c1e4a",
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
    "<C-\\><C-r> search input",
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
local function create_window_layout()
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
end

--- Create a new agent
---@param name string Agent name
---@param cwd string|nil Working directory (defaults to current)
local function create_agent(name, cwd)
  local cmd = get_command()
  local agent_type = M.current_agent_type

  -- Pick the next color from the cycle
  local colors = M.config.colors
  M.color_index = M.color_index + 1
  local color = colors[((M.color_index - 1) % #colors) + 1]

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
    local display = t:sub(1, 1):upper() .. t:sub(2)
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

--- Toggle the AI agent window
---@param name string|nil Agent name (defaults to "AIAgent")
function M.toggle(name)
  local agent_name = name or "AIAgent"

  -- If this specific agent is open and visible, close it
  if M.is_open() and M.current_agent == agent_name then
    M.close(agent_name)
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

-- Expose internals needed for testing (prefixed with _ by convention)
M._is_under = is_under

return M
