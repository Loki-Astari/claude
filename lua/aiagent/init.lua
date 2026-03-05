---@diagnostic disable: undefined-global
local M = {}

-- Default configuration
M.config = {
  width = 0.4,         -- Width as percentage (0-1) or columns (>1)
  command = "claude",  -- Command to run (default: "claude")
  named_commands = {
    Cursor = "cursor-agent",
  },
}

-- Track agents and windows
M.agents = {}           -- { name = { buf, job_id, scroll_mode, command } }
M.current_agent = nil   -- name of active agent
M.win = nil             -- shared terminal window
M.header_buf = nil      -- shared header buffer
M.header_win = nil      -- shared header window
M.prev_win = nil        -- Window to return to when exiting terminal mode

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

--- Setup the plugin with user options
---@param opts table|nil Configuration options
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Handle quit commands - clean up before Neovim checks for running jobs
  vim.api.nvim_create_autocmd("QuitPre", {
    callback = function()
      if next(M.agents) ~= nil then
        force_cleanup()
      end
    end,
    desc = "Close agent terminals before quit check",
  })

  -- Also handle VimLeavePre as a fallback
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      force_cleanup()
    end,
    desc = "Close agent terminals before exiting Neovim",
  })
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

--- Resolve command to run for an agent name
---@param agent_name string
---@param command string|nil
---@return string
local function resolve_command(agent_name, command)
  if command ~= nil and command ~= "" then
    return command
  end

  if type(agent_name) == "string" and agent_name:lower() == "cursor" then
    if vim.fn.executable("cursor-agent") == 1 then
      return "cursor-agent"
    end
    if vim.fn.executable("cursor") == 1 then
      return "cursor"
    end
  end

  local map = M.config.named_commands
  if type(map) == "table" then
    local by_exact = map[agent_name]
    if type(by_exact) == "string" and by_exact ~= "" then
      return by_exact
    end

    local by_lower = map[agent_name:lower()]
    if type(by_lower) == "string" and by_lower ~= "" then
      return by_lower
    end
  end

  return M.config.command
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

--- Update the header with current agent info
local function update_header()
  if M.header_buf == nil or not vim.api.nvim_buf_is_valid(M.header_buf) then
    return
  end

  local agent_names = get_agent_names()
  local count = #agent_names
  local current = M.current_agent or "none"

  -- Build agent list string
  local agent_list = ""
  if count > 1 then
    agent_list = " (" .. table.concat(agent_names, ", ") .. ")"
  end

  local lines = {
    "Agent: " .. current .. agent_list,
    "<C-\\><C-n> return to editor | <C-\\><C-s> scroll mode (i to resume)",
    "<C-\\><C-a> cycle agents | :AgentList to see all",
  }

  vim.api.nvim_set_option_value("modifiable", true, { buf = M.header_buf })
  vim.api.nvim_buf_set_lines(M.header_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = M.header_buf })
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
  vim.api.nvim_win_set_buf(M.win, agent.buf)
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

--- Create the window layout (header + terminal area)
local function create_window_layout()
  -- Remember the current window to return to later
  M.prev_win = vim.api.nvim_get_current_win()

  -- Create a vertical split on the right
  vim.cmd("botright vsplit")
  local main_win = vim.api.nvim_get_current_win()

  -- Set the width
  vim.api.nvim_win_set_width(main_win, get_width())

  -- Create the header buffer
  M.header_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.header_buf })
  vim.api.nvim_win_set_buf(main_win, M.header_buf)
  M.header_win = main_win

  -- Set header window options
  vim.api.nvim_set_option_value("number", false, { win = M.header_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.header_win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M.header_win })
  vim.api.nvim_set_option_value("winfixheight", true, { win = M.header_win })

  -- Create a horizontal split below for the terminal
  vim.cmd("belowright split")
  M.win = vim.api.nvim_get_current_win()

  -- Resize header to 3 lines
  vim.api.nvim_win_set_height(M.header_win, 3)

  -- Set terminal window options
  vim.api.nvim_set_option_value("number", false, { win = M.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M.win })
end

--- Create a new agent
---@param name string Agent name
---@param cmd string Command to run
local function create_agent(name, cmd)
  -- Create a new buffer for the terminal
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options before starting terminal
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })

  -- Store agent before starting terminal (so on_exit can find it)
  M.agents[name] = {
    buf = buf,
    job_id = nil,
    scroll_mode = false,
    command = cmd,
  }

  -- Show buffer in window and switch to it before starting terminal
  -- (termopen runs in the current window, so we must be in M.win)
  vim.api.nvim_win_set_buf(M.win, buf)
  vim.api.nvim_set_current_win(M.win)

  -- Start the terminal with the AI agent
  local job_id = vim.fn.termopen(cmd, {
    on_exit = function()
      if M.agents[name] then
        M.agents[name].job_id = nil
      end
      M.close(name)
    end,
  })

  M.agents[name].job_id = job_id

  -- Set buffer name for identification
  vim.api.nvim_buf_set_name(buf, "agent:" .. name)

  -- Auto-enter insert mode when entering this buffer (unless in scroll mode)
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      local agent = M.agents[name]
      if agent and not agent.scroll_mode then
        vim.cmd("startinsert")
      end
    end,
    desc = "Auto-enter terminal mode when focusing agent window",
  })

  -- Add keymap to exit terminal mode and return to previous window
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-n>", "", {
    noremap = true,
    callback = function()
      vim.cmd("stopinsert")
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = false
      end
      if M.prev_win and vim.api.nvim_win_is_valid(M.prev_win) then
        vim.api.nvim_set_current_win(M.prev_win)
      end
    end,
  })

  -- Add keymap to enter scroll mode (stay in agent window)
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-s>", "", {
    noremap = true,
    callback = function()
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = true
      end
      vim.cmd("stopinsert")
    end,
  })

  -- Add keymap to exit scroll mode and resume terminal interaction
  vim.api.nvim_buf_set_keymap(buf, "n", "i", "", {
    noremap = true,
    callback = function()
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = false
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

  return buf
end

--- Open an AI agent in a right-side split
---@param name string|nil Agent name (defaults to "AIAgent")
---@param command string|nil Command to run (defaults to config.command or name-based default)
function M.open(name, command)
  -- Default name and command
  local agent_name = name or "AIAgent"
  local cmd = resolve_command(agent_name, command)

  -- If agent already exists, switch to it
  if M.agents[agent_name] then
    if not M.is_open() then
      -- Window was closed but agent still exists, recreate window
      create_window_layout()
    end
    M.switch(agent_name)
    return
  end

  -- Create window layout if not open
  if not M.is_open() then
    create_window_layout()
  end

  -- Create the new agent
  create_agent(agent_name, cmd)
  M.current_agent = agent_name

  -- Update header and enter insert mode
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
      local cmd = agent and agent.command or "?"
      table.insert(lines, name .. marker .. " (" .. cmd .. ")")
    end
    vim.notify("Agents:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
  end
end

--- Toggle the AI agent window
---@param name string|nil Agent name (defaults to "AIAgent")
---@param command string|nil Optional command to run (defaults to config.command or name-based default)
function M.toggle(name, command)
  local agent_name = name or "AIAgent"

  -- If this specific agent is open and visible, close it
  if M.is_open() and M.current_agent == agent_name then
    M.close(agent_name)
  else
    M.open(agent_name, command)
  end
end

return M
